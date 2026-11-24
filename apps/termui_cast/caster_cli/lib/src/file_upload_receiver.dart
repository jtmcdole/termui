import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

/// Stages, verifies, and finalizes browser-to-host file uploads for a cast session.
final class FileUploadReceiver {
  /// Default maximum size per uploaded file (`256 MiB`).
  static const int defaultMaxUploadBytes = 256 * 1024 * 1024;

  /// Default cumulative maximum uploaded bytes permitted per session (`1 GiB`).
  static const int defaultMaxSessionUploadBytes = 1024 * 1024 * 1024;

  /// Default maximum number of completed uploaded files permitted per session.
  static const int defaultMaxSessionUploadFiles = 256;

  /// Maximum collision-suffix `(N)` attempts when resolving destination filename.
  static const int maxCollisionSuffixAttempts = 1000;

  static const int _maxSanitizedFileNameBytes = 200;

  static final Random _secureRandom = Random.secure();

  static final RegExp _forbiddenFileNameChars = RegExp(
    r'[\x00-\x1F\x7F-\x9F<>:"/\\|?*&%!^;`$]',
  );
  static final RegExp _trailingDotsOrSpaces = RegExp(r'[. ]+$');
  static final RegExp _windowsReservedName = RegExp(
    r'^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[0-9]|LPT[0-9])(\..*)?$',
    caseSensitive: false,
  );
  static final RegExp _posixSafeUnquoted = RegExp(r'^[A-Za-z0-9_./:@+-]+$');
  static final RegExp _windowsSafeUnquoted = RegExp(r'^[A-Za-z0-9_./:\\+-]+$');

  /// Session owning this upload receiver.
  final SessionId sessionId;

  /// Whether incoming file uploads are permitted for this session.
  final bool enabled;

  /// Maximum allowed size in bytes for a single uploaded file.
  final int maxUploadBytes;

  /// Maximum cumulative uploaded bytes permitted across the lifetime of this session.
  final int maxSessionUploadBytes;

  /// Maximum completed file count permitted across the lifetime of this session.
  final int maxSessionUploadFiles;

  final Directory? _customUploadDir;
  Directory? _autoUploadRoot;
  _ActiveUploadState? _active;
  bool _sweptStaleParts = false;
  int _totalUploadedBytes = 0;
  int _totalUploadedFiles = 0;

  /// Cumulative bytes written by completed uploads in this session.
  int get totalUploadedBytes => _totalUploadedBytes;

  /// Number of completed uploads finalized in this session.
  int get totalUploadedFiles => _totalUploadedFiles;

  /// Destination directory on the caster host where completed files are placed.
  ///
  /// When no custom `uploadDir` is supplied, a per-instance `termui_cast_uploads_*`
  /// directory under [Directory.systemTemp] is materialized lazily on the first
  /// enabled [handleStart] call.
  Directory get uploadDir {
    final custom = _customUploadDir;
    if (custom != null) return custom;
    final autoRoot = _autoUploadRoot;
    if (autoRoot != null) {
      return Directory(p.join(autoRoot.path, sessionId.value));
    }
    return _fallbackUploadDirectoryForSession(sessionId);
  }

  /// Whether an upload transfer is currently in progress.
  bool get hasActiveUploads => _active != null;

  /// Creates a file upload receiver for [sessionId].
  FileUploadReceiver({
    required this.sessionId,
    Directory? uploadDir,
    this.enabled = true,
    this.maxUploadBytes = defaultMaxUploadBytes,
    this.maxSessionUploadBytes = defaultMaxSessionUploadBytes,
    this.maxSessionUploadFiles = defaultMaxSessionUploadFiles,
  }) : _customUploadDir = uploadDir;

  static Directory _fallbackUploadDirectoryForSession(SessionId sessionId) =>
      Directory(
        p.join(
          Directory.systemTemp.path,
          'termui_cast_uploads',
          sessionId.value,
        ),
      );

  /// Sanitizes an untrusted [rawFileName] into a safe single-segment file name.
  static String sanitizeFileName(String rawFileName) {
    final lastSlash = max(
      rawFileName.lastIndexOf('/'),
      rawFileName.lastIndexOf(r'\'),
    );
    final base = lastSlash >= 0
        ? rawFileName.substring(lastSlash + 1)
        : rawFileName;
    var cleaned = base
        .replaceAll(_forbiddenFileNameChars, '_')
        .trim()
        .replaceAll(_trailingDotsOrSpaces, '')
        .trim();
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      return 'upload.bin';
    }
    cleaned = _truncateUtf8PreservingExtension(
      cleaned,
      _maxSanitizedFileNameBytes,
    ).trim().replaceAll(_trailingDotsOrSpaces, '').trim();
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      return 'upload.bin';
    }
    if (!_windowsReservedName.hasMatch(cleaned)) {
      return cleaned;
    }
    final prefixed = '_$cleaned';
    if (utf8.encode(prefixed).length <= _maxSanitizedFileNameBytes) {
      return prefixed;
    }
    final trimmedForPrefix = _truncateUtf8PreservingExtension(
      cleaned,
      _maxSanitizedFileNameBytes - 1,
    ).trim().replaceAll(_trailingDotsOrSpaces, '').trim();
    return trimmedForPrefix.isEmpty ? 'upload.bin' : '_$trimmedForPrefix';
  }

  static String _truncateUtf8PreservingExtension(String name, int maxBytes) {
    if (utf8.encode(name).length <= maxBytes) return name;
    final dotIndex = name.lastIndexOf('.');
    final hasExt = dotIndex > 0 && dotIndex < name.length - 1;
    final ext = hasExt ? name.substring(dotIndex) : '';
    final extBytes = utf8.encode(ext).length;
    final keptExt = extBytes <= 32 ? ext : '';
    final stemBudget = maxBytes - (keptExt.isEmpty ? 0 : extBytes);
    final stemSource = keptExt.isEmpty ? name : name.substring(0, dotIndex);
    final truncatedStem = _truncateUtf8(
      stemSource,
      stemBudget,
    ).replaceAll(_trailingDotsOrSpaces, '');
    return truncatedStem.isEmpty ? 'upload$keptExt' : '$truncatedStem$keptExt';
  }

  static String _truncateUtf8(String input, int maxBytes) {
    final builder = StringBuffer();
    var usedBytes = 0;
    for (final rune in input.runes) {
      final charStr = String.fromCharCode(rune);
      final charBytes = utf8.encode(charStr).length;
      if (usedBytes + charBytes > maxBytes) break;
      builder.write(charStr);
      usedBytes += charBytes;
    }
    return '$builder';
  }

  /// Formats [filePath] for safe shell injection into the active PTY.
  static String formatUploadedPathForPty(
    String filePath, {
    required bool isWindows,
    required bool bracketedPaste,
  }) {
    final token = isWindows
        ? (_windowsSafeUnquoted.hasMatch(filePath)
              ? filePath
              : '"${filePath.replaceAll('"', '""')}"')
        : (_posixSafeUnquoted.hasMatch(filePath)
              ? filePath
              : "'${filePath.replaceAll("'", r"'\''")}'");
    final payload = '$token ';
    return bracketedPaste ? '\x1b[200~$payload\x1b[201~' : payload;
  }

  static bool _isSymlinkPath(String rawPath) =>
      FileSystemEntity.typeSync(p.normalize(rawPath), followLinks: false) ==
      .link;

  void _prepareUploadDirectory() {
    if (_customUploadDir == null &&
        (_autoUploadRoot == null || !_autoUploadRoot!.existsSync())) {
      _autoUploadRoot = Directory.systemTemp.createTempSync(
        'termui_cast_uploads_',
      );
    }
    uploadDir.createSync(recursive: true);
    if (!_sweptStaleParts) {
      _sweptStaleParts = true;
      _sweepStalePartFiles();
    }
  }

  void _sweepStalePartFiles() {
    final prefix = '.upload-${sessionId.value}-';
    try {
      if (!uploadDir.existsSync()) return;
      for (final entity in uploadDir.listSync(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name.startsWith(prefix) && name.endsWith('.part')) {
          try {
            entity.deleteSync();
          } on Object catch (_) {}
        }
      }
    } on Object catch (_) {}
  }

  FileUploadAckFrame? _validateStartPreconditions(FileUploadStartFrame frame) {
    if (!enabled) {
      return _rejectedAck(
        frame.transferId,
        0,
        'File uploads are disabled on this caster (--no-upload).',
      );
    }
    if (frame.totalBytes < 0 || frame.totalBytes > maxUploadBytes) {
      return _rejectedAck(
        frame.transferId,
        0,
        'File size (${frame.totalBytes} B) exceeds caster limit ($maxUploadBytes B).',
      );
    }
    if (_totalUploadedFiles >= maxSessionUploadFiles) {
      return _rejectedAck(
        frame.transferId,
        0,
        'Session file upload count limit ($maxSessionUploadFiles) exceeded.',
      );
    }
    if (_totalUploadedBytes + frame.totalBytes > maxSessionUploadBytes) {
      return _rejectedAck(
        frame.transferId,
        0,
        'Cumulative session upload byte quota ($maxSessionUploadBytes B) exceeded.',
      );
    }
    if (_active != null && _active!.transferId != frame.transferId) {
      return _rejectedAck(
        frame.transferId,
        0,
        'Another file upload is already in progress for this session.',
      );
    }
    abortAll();
    if (_isSymlinkPath(uploadDir.path)) {
      return _rejectedAck(
        frame.transferId,
        0,
        'Refusing to use symlink upload directory.',
      );
    }
    return null;
  }

  static String _randomHexToken() {
    final buf = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buf.write(_secureRandom.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return '$buf';
  }

  String _nextStagingPartPath() => p.join(
    uploadDir.path,
    '.upload-${sessionId.value}-${_randomHexToken()}.part',
  );

  /// Handles [FileUploadStartFrame], creating a staging `.part` file exclusively.
  FileUploadAckFrame handleStart(FileUploadStartFrame frame) {
    final rejection = _validateStartPreconditions(frame);
    if (rejection != null) return rejection;
    try {
      _prepareUploadDirectory();
      if (_isSymlinkPath(uploadDir.path)) {
        return _rejectedAck(
          frame.transferId,
          0,
          'Refusing to use symlink upload directory.',
        );
      }
      final partPath = _nextStagingPartPath();
      if (_isSymlinkPath(partPath)) {
        return _rejectedAck(
          frame.transferId,
          0,
          'Refusing to open symlink staging file.',
        );
      }
      final partFile = File(partPath)..createSync(exclusive: true);
      final raf = partFile.openSync(mode: .writeOnly);
      return _activateStagingFile(frame, partFile, raf);
    } on Object catch (error) {
      abortAll();
      return _rejectedAck(
        frame.transferId,
        0,
        'Failed to open staging file: $error',
      );
    }
  }

  /// Async variant of [handleStart] creating `.part` exclusively without blocking.
  Future<FileUploadAckFrame> handleStartAsync(
    FileUploadStartFrame frame,
  ) async {
    final rejection = _validateStartPreconditions(frame);
    if (rejection != null) return rejection;
    try {
      _prepareUploadDirectory();
      if (_isSymlinkPath(uploadDir.path)) {
        return _rejectedAck(
          frame.transferId,
          0,
          'Refusing to use symlink upload directory.',
        );
      }
      final partPath = _nextStagingPartPath();
      if (_isSymlinkPath(partPath)) {
        return _rejectedAck(
          frame.transferId,
          0,
          'Refusing to open symlink staging file.',
        );
      }
      final partFile = await File(partPath).create(exclusive: true);
      final raf = await partFile.open(mode: .writeOnly);
      return _activateStagingFile(frame, partFile, raf);
    } on Object catch (error) {
      abortAll();
      return _rejectedAck(
        frame.transferId,
        0,
        'Failed to open staging file: $error',
      );
    }
  }

  FileUploadAckFrame _activateStagingFile(
    FileUploadStartFrame frame,
    File partFile,
    RandomAccessFile raf,
  ) {
    final digestSink = _DigestSink();
    final hashSink = sha256.startChunkedConversion(digestSink);
    _active = _ActiveUploadState(
      transferId: frame.transferId,
      sanitizedFileName: sanitizeFileName(frame.fileName),
      totalBytes: frame.totalBytes,
      partFile: partFile,
      raf: raf,
      digestSink: digestSink,
      hashSink: hashSink,
    );
    return FileUploadAckFrame(
      sessionId: sessionId,
      transferId: frame.transferId,
      status: .ready,
      nextOffset: 0,
    );
  }

  /// Appends [frame]'s bytes to the active `.part` file and updates the SHA-256 state.
  FileUploadAckFrame handleChunk(FileUploadChunkFrame frame) {
    final precheck = _validateChunkPreconditions(frame);
    if (precheck.rejection != null) return precheck.rejection!;
    final active = precheck.active!;
    final nextEnd = precheck.nextEnd;
    try {
      active.raf.writeFromSync(frame.data);
      active.hashSink.add(frame.data);
      active.bytesWritten = nextEnd;
      return FileUploadAckFrame(
        sessionId: sessionId,
        transferId: frame.transferId,
        status: .chunkAck,
        nextOffset: active.bytesWritten,
      );
    } on Object catch (error) {
      final written = active.bytesWritten;
      abortAll();
      return _rejectedAck(
        frame.transferId,
        written,
        'Disk write error during upload: $error',
      );
    }
  }

  /// Async variant of [handleChunk] writing payload chunks without blocking the isolate.
  Future<FileUploadAckFrame> handleChunkAsync(
    FileUploadChunkFrame frame,
  ) async {
    final precheck = _validateChunkPreconditions(frame);
    if (precheck.rejection != null) return precheck.rejection!;
    final active = precheck.active!;
    final nextEnd = precheck.nextEnd;
    try {
      await active.raf.writeFrom(frame.data);
      active.hashSink.add(frame.data);
      active.bytesWritten = nextEnd;
      return FileUploadAckFrame(
        sessionId: sessionId,
        transferId: frame.transferId,
        status: .chunkAck,
        nextOffset: active.bytesWritten,
      );
    } on Object catch (error) {
      final written = active.bytesWritten;
      abortAll();
      return _rejectedAck(
        frame.transferId,
        written,
        'Disk write error during upload: $error',
      );
    }
  }

  ({FileUploadAckFrame? rejection, _ActiveUploadState? active, int nextEnd})
  _validateChunkPreconditions(FileUploadChunkFrame frame) {
    final active = _active;
    if (active == null || active.transferId != frame.transferId) {
      return (
        rejection: _rejectedAck(
          frame.transferId,
          0,
          'Unknown or inactive upload transfer.',
        ),
        active: null,
        nextEnd: 0,
      );
    }
    final nextEnd = frame.offset + frame.data.length;
    if (frame.offset != active.bytesWritten || nextEnd > active.totalBytes) {
      final written = active.bytesWritten;
      abortAll();
      return (
        rejection: _rejectedAck(
          frame.transferId,
          written,
          'Out-of-order or overflowing upload chunk.',
        ),
        active: null,
        nextEnd: 0,
      );
    }
    return (rejection: null, active: active, nextEnd: nextEnd);
  }

  /// Async variant of [handleEnd] closing and renaming without blocking the isolate.
  Future<(FileUploadAckFrame ack, String? completedPath)> handleEndAsync(
    FileUploadEndFrame frame,
  ) async {
    final precheck = _validateEndPreconditions(frame);
    if (precheck.earlyResult != null) return precheck.earlyResult!;
    final active = precheck.active!;
    _active = null;
    try {
      await active.raf.close();
      active.hashSink.close();
      final actualBytes = active.digestSink.value?.bytes;
      if (actualBytes == null || !_bytesEqual(actualBytes, frame.sha256)) {
        _safeDeleteFile(active.partFile);
        return (
          _rejectedAck(
            active.transferId,
            active.bytesWritten,
            'SHA-256 digest mismatch.',
          ),
          null,
        );
      }
      final destinationPath = _resolveUniqueDestinationPath(
        active.sanitizedFileName,
      );
      await active.partFile.rename(destinationPath);
      _totalUploadedBytes += active.bytesWritten;
      _totalUploadedFiles += 1;
      return (
        FileUploadAckFrame(
          sessionId: sessionId,
          transferId: active.transferId,
          status: .completed,
          nextOffset: active.bytesWritten,
          message: destinationPath,
        ),
        destinationPath,
      );
    } on Object catch (error) {
      _safeDeleteFile(active.partFile);
      return (
        _rejectedAck(
          active.transferId,
          active.bytesWritten,
          'Failed to finalize uploaded file: $error',
        ),
        null,
      );
    }
  }

  /// Verifies the SHA-256 digest and renames the `.part` file, or cleans up on abort.
  (FileUploadAckFrame ack, String? completedPath) handleEnd(
    FileUploadEndFrame frame,
  ) {
    final precheck = _validateEndPreconditions(frame);
    if (precheck.earlyResult != null) return precheck.earlyResult!;
    return _finalizeActiveUpload(precheck.active!, frame.sha256);
  }

  ({(FileUploadAckFrame, String?)? earlyResult, _ActiveUploadState? active})
  _validateEndPreconditions(FileUploadEndFrame frame) {
    final active = _active;
    if (frame.aborted) {
      final written = active?.transferId == frame.transferId
          ? active!.bytesWritten
          : 0;
      if (active?.transferId == frame.transferId) {
        abortAll();
      }
      return (
        earlyResult: (
          _rejectedAck(frame.transferId, written, 'Upload cancelled.'),
          null,
        ),
        active: null,
      );
    }
    if (active == null || active.transferId != frame.transferId) {
      return (
        earlyResult: (
          _rejectedAck(
            frame.transferId,
            0,
            'Unknown or inactive upload transfer.',
          ),
          null,
        ),
        active: null,
      );
    }
    if (active.bytesWritten != active.totalBytes) {
      final written = active.bytesWritten;
      abortAll();
      return (
        earlyResult: (
          _rejectedAck(
            frame.transferId,
            written,
            'Incomplete upload: expected ${active.totalBytes} B, received $written B.',
          ),
          null,
        ),
        active: null,
      );
    }
    return (earlyResult: null, active: active);
  }

  (FileUploadAckFrame ack, String? completedPath) _finalizeActiveUpload(
    _ActiveUploadState active,
    Uint8List expectedSha256,
  ) {
    _active = null;
    try {
      active.raf.closeSync();
      active.hashSink.close();
      final actualBytes = active.digestSink.value?.bytes;
      if (actualBytes == null || !_bytesEqual(actualBytes, expectedSha256)) {
        _safeDeleteFile(active.partFile);
        return (
          _rejectedAck(
            active.transferId,
            active.bytesWritten,
            'SHA-256 digest mismatch.',
          ),
          null,
        );
      }
      final destinationPath = _resolveUniqueDestinationPath(
        active.sanitizedFileName,
      );
      active.partFile.renameSync(destinationPath);
      _totalUploadedBytes += active.bytesWritten;
      _totalUploadedFiles += 1;
      return (
        FileUploadAckFrame(
          sessionId: sessionId,
          transferId: active.transferId,
          status: .completed,
          nextOffset: active.bytesWritten,
          message: destinationPath,
        ),
        destinationPath,
      );
    } on Object catch (error) {
      _safeDeleteFile(active.partFile);
      return (
        _rejectedAck(
          active.transferId,
          active.bytesWritten,
          'Failed to finalize uploaded file: $error',
        ),
        null,
      );
    }
  }

  String _resolveUniqueDestinationPath(String sanitizedFileName) {
    final initial = p.join(uploadDir.path, sanitizedFileName);
    if (FileSystemEntity.typeSync(initial, followLinks: false) == .notFound) {
      return initial;
    }
    final dotIndex = sanitizedFileName.lastIndexOf('.');
    final hasExt = dotIndex > 0 && dotIndex < sanitizedFileName.length - 1;
    final stem = hasExt
        ? sanitizedFileName.substring(0, dotIndex)
        : sanitizedFileName;
    final ext = hasExt ? sanitizedFileName.substring(dotIndex) : '';
    for (var counter = 1; counter <= maxCollisionSuffixAttempts; counter++) {
      final candidate = p.join(uploadDir.path, '$stem ($counter)$ext');
      if (FileSystemEntity.typeSync(candidate, followLinks: false) ==
          .notFound) {
        return candidate;
      }
    }
    throw FileSystemException(
      'Exceeded $maxCollisionSuffixAttempts duplicate filename attempts',
      initial,
    );
  }

  /// Closes and deletes any in-flight `.part` file.
  void abortAll() {
    final active = _active;
    if (active == null) return;
    _active = null;
    try {
      active.raf.closeSync();
    } on Object catch (_) {}
    try {
      active.hashSink.close();
    } on Object catch (_) {}
    _safeDeleteFile(active.partFile);
  }

  /// Aborts any active upload and deletes the auto-created default temp
  /// directory if it is empty.
  void dispose() {
    abortAll();
    final autoRoot = _autoUploadRoot;
    if (autoRoot == null) return;
    _autoUploadRoot = null;
    try {
      final sessionDir = Directory(p.join(autoRoot.path, sessionId.value));
      if (sessionDir.existsSync() &&
          sessionDir.listSync(followLinks: false).isEmpty) {
        sessionDir.deleteSync();
      }
      if (autoRoot.existsSync() &&
          autoRoot.listSync(followLinks: false).isEmpty) {
        autoRoot.deleteSync();
      }
    } on Object catch (_) {}
  }

  static void _safeDeleteFile(File file) {
    try {
      if (file.existsSync()) {
        file.deleteSync();
      }
    } on Object catch (_) {}
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  FileUploadAckFrame _rejectedAck(
    int transferId,
    int nextOffset,
    String message,
  ) {
    return FileUploadAckFrame(
      sessionId: sessionId,
      transferId: transferId,
      status: .rejected,
      nextOffset: nextOffset,
      message: message,
    );
  }
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

final class _ActiveUploadState {
  final int transferId;
  final String sanitizedFileName;
  final int totalBytes;
  final File partFile;
  final RandomAccessFile raf;
  final _DigestSink digestSink;
  final ByteConversionSink hashSink;
  int bytesWritten = 0;

  _ActiveUploadState({
    required this.transferId,
    required this.sanitizedFileName,
    required this.totalBytes,
    required this.partFile,
    required this.raf,
    required this.digestSink,
    required this.hashSink,
  });
}
