import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'manifest_utils.dart';
import 'update_models.dart';

/// Default 200 MiB uncompressed output budget for Windows `.zip` extraction.
const int kDefaultMaxZipUncompressedBytes = 200 * 1024 * 1024;

/// Default 250 MiB uncompressed stream budget for macOS/Linux `.tar.gz` inspection.
const int kDefaultMaxTarUncompressedBytes = 250 * 1024 * 1024;

/// Required files that must exist inside a staged Windows `fterm` directory.
const List<String> kRequiredWindowsStagedFiles = [
  'fterm.exe',
  'flutter_windows.dll',
  'data/icudtl.dat',
];

/// Verifies that [filePath] has exact byte length [expectedSize] and lowercase
/// SHA-256 digest [expectedSha256Hex].
Future<void> verifyFileSizeAndSha256({
  required String filePath,
  required int expectedSize,
  required String expectedSha256Hex,
}) async {
  final file = File(filePath);
  final stat = await file.stat();
  if (stat.type != FileSystemEntityType.file) {
    throw UpdateException('Downloaded archive not found at "$filePath".');
  }
  if (stat.size != expectedSize) {
    throw UpdateException(
      'Archive size mismatch: expected $expectedSize bytes, got ${stat.size}.',
    );
  }
  final digest = await sha256.bind(file.openRead()).first;
  final actualHex = digest.toString().toLowerCase();
  if (actualHex != expectedSha256Hex.toLowerCase()) {
    throw UpdateException(
      'Archive SHA-256 mismatch: expected $expectedSha256Hex, got $actualHex.',
    );
  }
}

/// Extracts a Windows `.zip` archive from its Central Directory in pure Dart,
/// enforcing path normalization, zero symlinks, and [maxUncompressedBytes].
///
/// Returns the validated bundle manifest entries (from `.fterm-files.json` when
/// present, or the top-level extracted entries otherwise).
List<String> extractAndValidateWindowsZip({
  required String zipPath,
  required String outputDirPath,
  int maxUncompressedBytes = kDefaultMaxZipUncompressedBytes,
}) {
  final input = InputFileStream(zipPath);
  try {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(
        input,
        verify: true,
        throwOnError: true,
      );
    } on Object catch (e) {
      throw UpdateException('Corrupt Windows update .zip archive: $e');
    }
    final budget = _ExtractionBudget(maxUncompressedBytes);
    for (final entry in archive) {
      _extractSingleZipEntry(entry, outputDirPath, budget);
    }
  } finally {
    input.closeSync();
  }
  _verifyRequiredFilesExist(outputDirPath, kRequiredWindowsStagedFiles);
  return readOrSynthesizeBundleManifest(outputDirPath);
}

void _extractSingleZipEntry(
  ArchiveFile entry,
  String outputDirPath,
  _ExtractionBudget budget,
) {
  if (_isZipSymlink(entry) || entry.isHardLink) {
    throw UpdateException(
      'Windows update archive contains forbidden link entry "${entry.name}".',
    );
  }
  final normalized = _normalizeZipEntryPath(entry.name);
  if (normalized == null) return;
  final targetPath = p.joinAll([outputDirPath, ...normalized.split('/')]);
  if (!entry.isFile) {
    Directory(targetPath).createSync(recursive: true);
    return;
  }
  if (entry.size < 0) {
    throw UpdateException('Negative zip entry size for "$normalized".');
  }
  budget.reserveDeclared(entry.size, normalized);
  File(targetPath).parent.createSync(recursive: true);
  final out = _BoundedFileOutputStream(File(targetPath), budget, normalized);
  try {
    entry.writeContent(out, freeMemory: true);
    out.flush();
  } on UpdateException {
    rethrow;
  } on Object catch (e) {
    throw UpdateException('Failed extracting "$normalized": $e');
  } finally {
    out.closeSync();
  }
}

bool _isZipSymlink(ArchiveFile entry) =>
    entry.isSymbolicLink || (entry.mode & 0xF000) == 0xA000;

String? _normalizeZipEntryPath(String rawName) {
  final trimmed = rawName.replaceAll(r'\', '/').trim();
  if (trimmed.isEmpty || trimmed == '.' || trimmed == './') return null;
  final stripped = trimmed.startsWith('./') ? trimmed.substring(2) : trimmed;
  if (stripped.isEmpty) return null;
  return normalizeSafeRelativePath(stripped);
}

void _verifyRequiredFilesExist(String rootPath, List<String> requiredRelPaths) {
  for (final rel in requiredRelPaths) {
    final full = p.joinAll([rootPath, ...rel.split('/')]);
    if (FileSystemEntity.typeSync(full, followLinks: false) !=
        FileSystemEntityType.file) {
      throw UpdateException(
        'Staged update bundle is missing required file "$rel".',
      );
    }
  }
}

/// Reads `.fterm-files.json` in [bundleRoot] when present, or synthesizes a
/// sorted manifest from top-level entries inside [bundleRoot].
List<String> readOrSynthesizeBundleManifest(String bundleRoot) {
  final manifestFile = File(p.join(bundleRoot, kFtermManifestFileName));
  if (FileSystemEntity.typeSync(manifestFile.path, followLinks: false) ==
      FileSystemEntityType.file) {
    return parseManifestJson(manifestFile.readAsStringSync());
  }
  final entries = <String>[
    for (final entity in Directory(bundleRoot).listSync(followLinks: false))
      normalizeSafeRelativePath(p.basename(entity.path)),
  ];
  if (entries.isEmpty) {
    throw const UpdateException('Staged update bundle directory is empty.');
  }
  return deduplicateAndPruneAncestors(entries);
}

final class _ExtractionBudget {
  final int maxBytes;
  int _writtenBytes = 0;

  _ExtractionBudget(this.maxBytes);

  void reserveDeclared(int declaredSize, String label) {
    if (_writtenBytes + declaredSize > maxBytes) {
      throw UpdateException(
        'Archive exceeds uncompressed limit ($maxBytes bytes) at "$label".',
      );
    }
  }

  void addWritten(int delta, String label) {
    _writtenBytes += delta;
    if (_writtenBytes > maxBytes) {
      throw UpdateException(
        'Archive decompression exceeded $maxBytes bytes at "$label".',
      );
    }
  }
}

final class _BoundedFileOutputStream extends OutputFileStream {
  final _ExtractionBudget _budget;
  final String _label;

  _BoundedFileOutputStream(File file, this._budget, this._label)
    : super.withFileHandle(FileHandle(file.path, mode: FileAccess.write));

  @override
  void writeByte(int value) {
    _budget.addWritten(1, _label);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (count <= 0) return;
    _budget.addWritten(count, _label);
    super.writeBytes(bytes, length: count);
  }

  @override
  void writeRange(Uint8List bytes, int start, int end) {
    final count = end - start;
    if (count <= 0) return;
    _budget.addWritten(count, _label);
    super.writeRange(bytes, start, end);
  }
}

/// Scans `.tar.gz` 512-byte USTAR/PAX/GNU blocks prior to invoking system `tar`
/// to enforce [maxUncompressedBytes] and reject path traversal, hardlinks,
/// device/FIFO nodes, and symlinks resolving outside the staging root.
Future<void> inspectTarGzStream({
  required String tarGzPath,
  int maxUncompressedBytes = kDefaultMaxTarUncompressedBytes,
}) async {
  final scanner = _TarStreamValidator(maxUncompressedBytes);
  try {
    await for (final chunk in File(
      tarGzPath,
    ).openRead().transform(gzip.decoder)) {
      scanner.addChunk(chunk);
    }
  } on UpdateException {
    rethrow;
  } on Object catch (e) {
    throw UpdateException('Invalid .tar.gz stream: $e');
  }
  scanner.finish();
}

final class _TarStreamValidator {
  static const int _blockSize = 512;
  final int _maxBytes;
  final BytesBuilder _carry = BytesBuilder(copy: false);
  final BytesBuilder _metaAccumulator = BytesBuilder(copy: false);
  final Map<String, String> _symlinks = {};

  int _totalDecompressedBytes = 0;
  int _skipPayloadBytes = 0;
  int _metaRemainingBytes = 0;
  int _metaPaddingBytes = 0;
  int _activeMetaType = 0;
  String? _pendingPathOverride;
  String? _pendingLinkOverride;
  int _seenEntryCount = 0;

  _TarStreamValidator(this._maxBytes);

  void addChunk(List<int> chunk) {
    _totalDecompressedBytes += chunk.length;
    if (_totalDecompressedBytes > _maxBytes) {
      throw UpdateException(
        'Tar archive exceeds uncompressed cap ($_maxBytes bytes).',
      );
    }
    _carry.add(chunk);
    _drainBuffer();
  }

  void _drainBuffer() {
    final bytes = _carry.takeBytes();
    var offset = 0;
    while (offset < bytes.length) {
      final consumed = _consumeStep(bytes, offset);
      if (consumed == 0) break;
      offset += consumed;
    }
    if (offset < bytes.length) {
      _carry.add(Uint8List.sublistView(bytes, offset));
    }
  }

  int _consumeStep(Uint8List bytes, int offset) {
    final avail = bytes.length - offset;
    if (_skipPayloadBytes > 0) {
      final step = avail < _skipPayloadBytes ? avail : _skipPayloadBytes;
      _skipPayloadBytes -= step;
      return step;
    }
    if (_metaRemainingBytes > 0) {
      return _consumeMetaPayload(bytes, offset, avail);
    }
    if (avail < _blockSize) return 0;
    _inspectHeaderBlock(
      Uint8List.sublistView(bytes, offset, offset + _blockSize),
    );
    return _blockSize;
  }

  int _consumeMetaPayload(Uint8List bytes, int offset, int avail) {
    final step = avail < _metaRemainingBytes ? avail : _metaRemainingBytes;
    _metaAccumulator.add(Uint8List.sublistView(bytes, offset, offset + step));
    _metaRemainingBytes -= step;
    if (_metaRemainingBytes == 0) {
      _applyMetadataPayload(_activeMetaType, _metaAccumulator.takeBytes());
      _skipPayloadBytes = _metaPaddingBytes;
      _metaPaddingBytes = 0;
    }
    return step;
  }

  void _inspectHeaderBlock(Uint8List block) {
    if (_isAllZeroBlock(block)) return;
    final size = _parseTarSize(block, 124, 12);
    if (size < 0 || size > _maxBytes) {
      throw UpdateException('Tar entry size out of bounds ($size).');
    }
    final padded = ((size + _blockSize - 1) ~/ _blockSize) * _blockSize;
    final typeFlag = block[156];

    if (_isMetadataTypeFlag(typeFlag)) {
      if (size > 64 * 1024) {
        throw const UpdateException('Tar extended metadata header too large.');
      }
      _activeMetaType = typeFlag;
      _metaRemainingBytes = size;
      _metaPaddingBytes = padded - size;
      return;
    }

    final rawName = _pendingPathOverride ?? _readUstarPath(block);
    final rawLink = _pendingLinkOverride ?? _readNullTermUtf8(block, 157, 100);
    _pendingPathOverride = null;
    _pendingLinkOverride = null;
    _validateTarEntry(typeFlag: typeFlag, rawName: rawName, rawLink: rawLink);
    _skipPayloadBytes = padded;
  }

  static bool _isMetadataTypeFlag(int flag) =>
      flag == 0x78 /* 'x' PAX */ ||
      flag == 0x4C /* 'L' GNU LongName */ ||
      flag == 0x4B /* 'K' GNU LongLink */;

  void _applyMetadataPayload(int typeFlag, Uint8List payload) {
    if (typeFlag == 0x4C) {
      _pendingPathOverride = _readNullTermUtf8(payload, 0, payload.length);
    } else if (typeFlag == 0x4B) {
      _pendingLinkOverride = _readNullTermUtf8(payload, 0, payload.length);
    } else if (typeFlag == 0x78) {
      _parsePaxRecords(payload);
    }
  }

  void _parsePaxRecords(Uint8List payload) {
    final text = utf8.decode(payload, allowMalformed: false);
    var cursor = 0;
    while (cursor < text.length) {
      final spaceIdx = text.indexOf(' ', cursor);
      if (spaceIdx <= cursor) {
        throw const UpdateException('Malformed PAX header record.');
      }
      final recLen = int.tryParse(text.substring(cursor, spaceIdx));
      if (recLen == null || recLen <= 0 || cursor + recLen > text.length) {
        throw const UpdateException('Out-of-bounds PAX header record length.');
      }
      final recordBody = text.substring(spaceIdx + 1, cursor + recLen - 1);
      final eqIdx = recordBody.indexOf('=');
      if (eqIdx > 0) {
        final key = recordBody.substring(0, eqIdx);
        final val = recordBody.substring(eqIdx + 1);
        if (key == 'path') _pendingPathOverride = val;
        if (key == 'linkpath') _pendingLinkOverride = val;
      }
      cursor += recLen;
    }
  }

  void _validateTarEntry({
    required int typeFlag,
    required String rawName,
    required String rawLink,
  }) {
    if (typeFlag == 0x31 /* '1' hardlink */ ) {
      throw UpdateException(
        'Tar archive contains forbidden hardlink "$rawName".',
      );
    }
    final isRegular = typeFlag == 0 || typeFlag == 0x30 /* '0' */;
    final isDir = typeFlag == 0x35 /* '5' */;
    final isSymlink = typeFlag == 0x32 /* '2' */;
    if (!isRegular && !isDir && !isSymlink) {
      throw UpdateException(
        'Tar archive contains unsupported entry type ($typeFlag) at "$rawName".',
      );
    }
    final cleanPath = _normalizeTarEntryPath(rawName);
    if (cleanPath == null) return;
    _seenEntryCount += 1;
    _verifyNoEscapingSymlinkPrefix(cleanPath);
    if (isSymlink) {
      _registerAndValidateInternalSymlink(cleanPath, rawLink);
    }
  }

  String? _normalizeTarEntryPath(String rawName) {
    if (rawName.isEmpty) {
      throw const UpdateException('Tar archive contains empty entry name.');
    }
    if (rawName.startsWith('/') || rawName.startsWith(r'\')) {
      throw UpdateException('Tar entry has absolute path "$rawName".');
    }
    var trimmed = rawName;
    if (trimmed == '.' || trimmed == './') return null;
    if (trimmed.startsWith('./')) {
      trimmed = trimmed.substring(2);
    }
    if (trimmed.isEmpty) return null;
    return normalizeSafeRelativePath(trimmed);
  }

  void _registerAndValidateInternalSymlink(String entryPath, String rawLink) {
    if (rawLink.isEmpty ||
        rawLink.startsWith('/') ||
        rawLink.startsWith(r'\') ||
        rawLink.contains(':')) {
      throw UpdateException(
        'Tar symlink "$entryPath" points to forbidden target "$rawLink".',
      );
    }
    final parentSegs = entryPath.split('/')..removeLast();
    final resolved = _resolveRelativeTarget(parentSegs, rawLink, entryPath);
    _symlinks[entryPath] = resolved.join('/');
    _resolveThroughRecordedSymlinks(entryPath);
  }

  static List<String> _resolveRelativeTarget(
    List<String> baseSegments,
    String rawLink,
    String entryPath,
  ) {
    final stack = List<String>.of(baseSegments);
    for (final seg in rawLink.replaceAll(r'\', '/').split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (stack.isEmpty) {
          throw UpdateException(
            'Tar symlink "$entryPath" -> "$rawLink" escapes staging root.',
          );
        }
        stack.removeLast();
      } else {
        stack.add(seg);
      }
    }
    return stack;
  }

  void _verifyNoEscapingSymlinkPrefix(String entryPath) {
    if (_symlinks.isEmpty) return;
    _resolveThroughRecordedSymlinks(entryPath);
  }

  void _resolveThroughRecordedSymlinks(String path) {
    var current = path;
    for (var hop = 0; hop < 16; hop++) {
      final rewritten = _rewriteFirstSymlinkSegment(current);
      if (rewritten == null) return;
      current = rewritten;
    }
    throw UpdateException('Tar symlink loop or excessive depth at "$path".');
  }

  String? _rewriteFirstSymlinkSegment(String path) {
    final segs = path.split('/');
    for (var i = 0; i < segs.length; i++) {
      final prefix = segs.sublist(0, i + 1).join('/');
      final target = _symlinks[prefix];
      if (target != null) {
        final tail = segs.sublist(i + 1);
        final joined = [if (target.isNotEmpty) target, ...tail].join('/');
        return joined;
      }
    }
    return null;
  }

  void finish() {
    if (_carry.length != 0 ||
        _skipPayloadBytes != 0 ||
        _metaRemainingBytes != 0) {
      throw const UpdateException('Truncated .tar.gz archive stream.');
    }
    if (_seenEntryCount == 0) {
      throw const UpdateException('Tar archive contains no bundle entries.');
    }
  }

  static bool _isAllZeroBlock(Uint8List block) {
    for (var i = 0; i < block.length; i++) {
      if (block[i] != 0) return false;
    }
    return true;
  }

  static String _readUstarPath(Uint8List block) {
    final name = _readNullTermUtf8(block, 0, 100);
    final prefix = _readNullTermUtf8(block, 345, 155);
    return prefix.isEmpty ? name : '$prefix/$name';
  }

  static String _readNullTermUtf8(Uint8List buf, int start, int maxLen) {
    var end = start;
    final limit = start + maxLen;
    while (end < limit && buf[end] != 0) {
      end += 1;
    }
    return utf8.decode(Uint8List.sublistView(buf, start, end));
  }

  static int _parseTarSize(Uint8List block, int offset, int length) {
    final first = block[offset];
    if ((first & 0x80) != 0) {
      return _parseBase256Size(block, offset, length);
    }
    final raw = _readNullTermUtf8(block, offset, length).trim();
    if (raw.isEmpty) return 0;
    final parsed = int.tryParse(raw, radix: 8);
    if (parsed == null) {
      throw UpdateException('Invalid octal tar size field "$raw".');
    }
    return parsed;
  }

  static int _parseBase256Size(Uint8List block, int offset, int length) {
    if ((block[offset] & 0x40) != 0) return -1;
    var value = block[offset] & 0x3F;
    for (var i = 1; i < length; i++) {
      if (value > 0x7FFFFFFFFFFFFF) return 0x7FFFFFFFFFFFFFFF;
      value = (value << 8) | block[offset + i];
    }
    return value;
  }
}
