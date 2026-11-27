import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:termui/termui.dart';

import 'kitty_medium_stub.dart' if (dart.library.io) 'kitty_medium_io.dart';
import 'zlib_decoder_stub.dart' if (dart.library.io) 'zlib_decoder_io.dart';

final class _PayloadTooLargeException implements Exception {
  const _PayloadTooLargeException();
}

final class _InvalidPayloadException implements Exception {
  const _InvalidPayloadException();
}

final class _MediumNotFoundException implements Exception {
  const _MediumNotFoundException();
}

final class _UnsupportedMediumException implements Exception {
  const _UnsupportedMediumException();
}

final class _BoundedByteSink extends ByteConversionSinkBase {
  final int maxBytes;
  final BytesBuilder _builder = BytesBuilder(copy: false);

  _BoundedByteSink(this.maxBytes);

  @override
  void add(List<int> chunk) {
    if (_builder.length + chunk.length > maxBytes) {
      _builder.clear();
      throw const _PayloadTooLargeException();
    }
    _builder.add(chunk);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}

final class _CountingByteSink extends ByteConversionSinkBase {
  final int maxBytes;
  int _length = 0;

  _CountingByteSink(this.maxBytes);

  @override
  void add(List<int> chunk) {
    _length += chunk.length;
    if (_length > maxBytes) {
      throw const _PayloadTooLargeException();
    }
  }

  @override
  void close() {}
}

final class _PendingUpload {
  final int imageId;
  final int explicitNumber;
  final String action;
  final String medium;
  final int format;
  final int width;
  final int height;
  final int? cols;
  final int? rows;
  final int dataOffset;
  final int? dataSize;
  final bool compressed;
  final int quiet;
  final bool advanceCursor;
  final bool virtual;
  final int placementId;
  final bool hasAddressableId;
  final String? replyPrefix;
  final String? validationError;
  final StringBuffer base64Data = StringBuffer();
  int byteCount = 0;
  bool overflowed = false;

  _PendingUpload({
    required this.imageId,
    required this.explicitNumber,
    required this.action,
    required this.medium,
    required this.format,
    required this.width,
    required this.height,
    required this.cols,
    required this.rows,
    required this.dataOffset,
    required this.dataSize,
    required this.compressed,
    required this.quiet,
    required this.advanceCursor,
    required this.virtual,
    required this.placementId,
    required this.hasAddressableId,
    required this.replyPrefix,
    required this.validationError,
  });
}

/// Handles Kitty Graphics `APC` commands (`ESC _ G ... ST`) for [VirtualTerminal].
final class KittyApcHandler {
  static const int _maxConcurrentUploads = 16;
  static const int _maxBase64PerUpload = 16 * 1024 * 1024;
  static const int _maxTotalPendingBase64 = 32 * 1024 * 1024;
  static const int _maxInflatedBytes = 16 * 1024 * 1024;
  static const int _maxDimension = 8192;
  static const int _maxTotalPixels = 16_777_216;
  static const List<int> _pngSignature = [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  ];
  static final RegExp _whitespaceRegex = RegExp(r'\s+');

  /// Scoped [KittyImageRegistry] owned by the enclosing [VirtualTerminal].
  final KittyImageRegistry registry;

  /// Callback invoked to send terminal escape sequence replies to the client.
  final void Function(String reply)? onReply;

  /// Callback invoked when a direct graphic placement writes cells at the cursor.
  final void Function(
    int cols,
    int rows,
    int imageId,
    bool advanceCursor,
    int placementId,
  )
  onPlaceVirtual;

  /// Callback invoked when `a=d` deletes visible placements on the active screen.
  /// When `imageId` is `null`, all Kitty placeholder cells are cleared;
  /// otherwise only placements matching `imageId` (and optional `placementId`)
  /// are cleared.
  final void Function(int? imageId, {int? placementId, bool directOnly})?
  onClearPlacements;

  /// Callback returning the live terminal cell dimensions in pixels `(width, height)`.
  final (int width, int height) Function() cellPixelSize;

  /// Whether local filesystem (`t=t`) and POSIX shared-memory (`t=s`)
  /// transmission media are enabled. Defaults to `false`.
  final bool allowLocalMedia;

  final Map<int, _PendingUpload> _pendingUploads = {};
  final Set<(int imageId, int placementId, bool isVirtual)> _placements = {};
  final Map<int, int> _imageNumberToId = {};
  int _totalPendingBase64 = 0;
  int? _lastActiveUploadId;
  int _nextAutoId = 0x80000001;

  /// Creates a [KittyApcHandler] bound to a scoped [registry].
  KittyApcHandler({
    required this.registry,
    required this.onReply,
    required this.onPlaceVirtual,
    required this.cellPixelSize,
    this.onClearPlacements,
    this.allowLocalMedia = false,
  });

  /// Clears all pending chunked uploads, placements, and wipes [registry].
  void reset() {
    _pendingUploads.clear();
    _placements.clear();
    _imageNumberToId.clear();
    _totalPendingBase64 = 0;
    _lastActiveUploadId = null;
    registry.clearImages();
  }

  /// Handles an APC payload starting with `G` or `_G`.
  void handleApc(String payload) {
    if (!payload.startsWith('G') && !payload.startsWith('_G')) return;
    final clean = payload.startsWith('_G') ? payload.substring(1) : payload;
    final semiIdx = clean.indexOf(';');
    final controlPart = semiIdx >= 0
        ? clean.substring(1, semiIdx)
        : clean.substring(1);
    final dataPart = semiIdx >= 0 ? clean.substring(semiIdx + 1) : '';

    final control = _parseControlPart(controlPart);
    final explicitId = _parsePositiveId(control['i']);
    final explicitNumber = _parsePositiveId(control['I']);
    final candidate = !control.containsKey('a')
        ? _resolveActiveContinuation(control)
        : null;
    final pendingContinuation =
        candidate != null &&
            _canContinueWithoutAction(
              candidate,
              control,
              explicitId,
              explicitNumber,
            )
        ? candidate
        : null;
    final action = pendingContinuation?.action ?? (control['a'] ?? 't');
    final quiet = int.tryParse(control['q'] ?? '0') ?? 0;

    switch (action) {
      case 'q':
        _handleQuery(control, dataPart, quiet, pendingContinuation);
      case 't' || 'T':
        _handleTransmit(action, control, dataPart, quiet);
      case 'p':
        _handlePlace(control, quiet);
      case 'd':
        _handleDelete(control);
      default:
        final prefix = _resolveReplyPrefix(
          explicitId,
          _parsePositiveId(control['I']),
          placementId: _parsePositiveId(control['p']),
          isQuery: true,
        );
        _replyError(prefix, quiet, 'EINVAL:unsupported action');
    }
  }

  _PendingUpload? _resolveActiveContinuation(Map<String, String> control) {
    final explicitId = _parsePositiveId(control['i']);
    if (explicitId > 0) return _pendingUploads[explicitId];
    final lastId = _lastActiveUploadId;
    return lastId != null ? _pendingUploads[lastId] : null;
  }

  static Map<String, String> _parseControlPart(String control) {
    final map = <String, String>{};
    if (control.isEmpty) return map;
    for (final pair in control.split(',')) {
      final eq = pair.indexOf('=');
      if (eq > 0) {
        map[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
      }
    }
    return map;
  }

  static int? _parseOptionalPositiveInt(String? raw) {
    final parsed = int.tryParse(raw ?? '');
    return (parsed != null && parsed > 0) ? parsed : null;
  }

  static int _parsePositiveId(String? raw) {
    final parsed = int.tryParse(raw ?? '');
    if (parsed == null || parsed <= 0 || parsed > 0xFFFFFFFF) return 0;
    return parsed;
  }

  static bool _isOutOfRangeUint32(String? raw) {
    if (raw == null) return false;
    final parsed = int.tryParse(raw);
    return parsed == null || parsed < 0 || parsed > 0xFFFFFFFF;
  }

  static String? _resolveReplyPrefix(
    int imageId,
    int explicitNumber, {
    int placementId = 0,
    bool isQuery = false,
  }) {
    final String? base;
    if (explicitNumber > 0) {
      base = isQuery
          ? 'I=$explicitNumber'
          : (imageId > 0
                ? 'i=$imageId,I=$explicitNumber'
                : 'I=$explicitNumber');
    } else if (imageId > 0) {
      base = 'i=$imageId';
    } else {
      return null;
    }
    return placementId > 0 ? '$base,p=$placementId' : base;
  }

  int _allocateAutoId() {
    final id = _nextAutoId & 0xFFFFFFFF;
    _nextAutoId = ((_nextAutoId + 1) & 0x7FFFFFFF) | 0x80000000;
    return id == 0 ? 0x80000001 : id;
  }

  void _replyOk(String? replyPrefix, int quiet) {
    if (quiet == 0 && replyPrefix != null) {
      onReply?.call('\x1b_G$replyPrefix;OK\x1b\\');
    }
  }

  void _replyError(String? replyPrefix, int quiet, String errorMessage) {
    if (quiet < 2 && replyPrefix != null) {
      onReply?.call('\x1b_G$replyPrefix;$errorMessage\x1b\\');
    }
  }

  static String _parseMedium(Map<String, String> control) =>
      control['t'] ?? 'd';

  bool _isSupportedMedium(Map<String, String> control) =>
      switch (_parseMedium(control)) {
        'd' => true,
        final medium => allowLocalMedia && platformSupportsKittyMedium(medium),
      };

  /// Returns whether [format] is a supported Kitty Graphics `f=` transmission code:
  /// [KittyImageData.formatRgb24] (`24`), [KittyImageData.formatRgba32] (`32`),
  /// or [KittyImageData.formatPng] (`100`).
  static bool _isSupportedFormat(int format) => switch (format) {
    KittyImageData.formatRgb24 ||
    KittyImageData.formatRgba32 ||
    KittyImageData.formatPng => true,
    _ => false,
  };

  static bool _isSupportedCompression(String? compression) =>
      compression == null ||
      (compression == 'z' && platformZlibDecoder != null);

  static int _parseFormat(Map<String, String> control) {
    final raw = control['f'];
    if (raw == null) return KittyImageData.formatRgba32;
    return int.tryParse(raw) ?? -1;
  }

  String? _resolveValidationError(Map<String, String> control, int format) {
    if (_isOutOfRangeUint32(control['i']) ||
        _isOutOfRangeUint32(control['I'])) {
      return 'EINVAL:invalid id';
    }
    if (_parsePositiveId(control['i']) > 0 &&
        _parsePositiveId(control['I']) > 0) {
      return 'EINVAL:cannot specify both i and I';
    }
    if (!_isSupportedMedium(control)) {
      return 'EINVAL:unsupported transmission medium';
    }
    if (!_isSupportedFormat(format)) {
      return 'EINVAL:unsupported format';
    }
    if (!_isSupportedCompression(control['o'])) {
      return 'EINVAL:unsupported compression';
    }
    return null;
  }

  static bool _hasNewUploadMetadata(Map<String, String> control) =>
      control.containsKey('s') ||
      control.containsKey('v') ||
      control.containsKey('f') ||
      control.containsKey('t') ||
      control.containsKey('o') ||
      control.containsKey('O') ||
      control.containsKey('S') ||
      control.containsKey('c') ||
      control.containsKey('r') ||
      control.containsKey('U') ||
      control.containsKey('p');

  static int? _parseDataSize(String? raw) {
    if (raw == null) return null;
    final parsed = int.tryParse(raw);
    if (parsed == null) return -1;
    // Per Kitty spec, S=0 means read the entire payload (same as omitted).
    return parsed == 0 ? null : parsed;
  }

  static int _parseDataOffset(String? raw) {
    if (raw == null) return 0;
    return int.tryParse(raw) ?? -1;
  }

  static Uint8List _decodeBase64Payload(String raw) {
    final cleaned = raw.replaceAll(_whitespaceRegex, '');
    if (cleaned.isEmpty) return Uint8List(0);
    if (cleaned.length % 4 == 1) throw const _InvalidPayloadException();
    return base64.decode(base64.normalize(cleaned));
  }

  static Uint8List _inflateZlibBytes(Uint8List compressed) {
    final decoder = platformZlibDecoder;
    if (decoder == null) throw const _InvalidPayloadException();
    final outSink = _BoundedByteSink(_maxInflatedBytes);
    decoder.startChunkedConversion(outSink)
      ..add(compressed)
      ..close();
    return outSink.takeBytes();
  }

  static void _validateZlibBytes(Uint8List compressed) {
    final decoder = platformZlibDecoder;
    if (decoder == null) throw const _InvalidPayloadException();
    final outSink = _CountingByteSink(_maxInflatedBytes);
    decoder.startChunkedConversion(outSink)
      ..add(compressed)
      ..close();
  }

  void _handleQuery(
    Map<String, String> control,
    String dataPart,
    int quiet,
    _PendingUpload? pendingContinuation,
  ) {
    final isMore = (int.tryParse(control['m'] ?? '0') ?? 0) == 1;
    final explicitId = _parsePositiveId(control['i']);
    final explicitNumber = _parsePositiveId(control['I']);
    final existing = pendingContinuation ?? _resolveActiveContinuation(control);
    final canContinue = _canContinueExisting(
      existing,
      'q',
      control,
      explicitId,
    );

    if (!isMore && !canContinue) {
      final replyPrefix = _resolveReplyPrefix(
        explicitId,
        explicitNumber,
        placementId: _parsePositiveId(control['p']),
        isQuery: true,
      );
      final format = _parseFormat(control);
      final validationError = _resolveValidationError(control, format);
      if (validationError != null) {
        _replyError(replyPrefix, quiet, validationError);
        return;
      }
      final dataSize = _parseDataSize(control['S']);
      final dataOffset = _parseDataOffset(control['O']);
      _verifyQueryBytes(
        replyPrefix,
        quiet,
        dataPart,
        medium: _parseMedium(control),
        compressed: control['o'] == 'z',
        dataOffset: dataOffset,
        dataSize: dataSize,
      );
      return;
    }

    final pending = _obtainPendingUpload('q', control, quiet);
    final chunk = _bufferUploadChunk(pending, control, dataPart, quiet);
    if (chunk.isMore) return;

    _finalizeQuery(pending, chunk.effectiveQuiet);
  }

  void _finalizeQuery(_PendingUpload pending, int quiet) {
    if (pending.validationError != null) {
      _replyError(pending.replyPrefix, quiet, pending.validationError!);
      return;
    }
    if (pending.overflowed) {
      _replyError(pending.replyPrefix, quiet, 'EFBIG:payload too large');
      return;
    }
    _verifyQueryBytes(
      pending.replyPrefix,
      quiet,
      pending.base64Data.toString(),
      medium: pending.medium,
      compressed: pending.compressed,
      dataOffset: pending.dataOffset,
      dataSize: pending.dataSize,
    );
  }

  static Uint8List _readMediumBytes(
    String medium,
    Uint8List decoded, {
    required int dataOffset,
    required int? dataSize,
    required bool unlink,
  }) {
    if (medium == 'd') return decoded;
    return switch (readPlatformKittyMedium(
      medium,
      decoded,
      maxBytes: _maxInflatedBytes,
      offset: dataOffset,
      size: dataSize,
      unlink: unlink,
    )) {
      KittyMediumReadOk(:final bytes) => bytes,
      KittyMediumReadNotFound() => throw const _MediumNotFoundException(),
      KittyMediumReadTooLarge() => throw const _PayloadTooLargeException(),
      KittyMediumReadInvalid() => throw const _InvalidPayloadException(),
      KittyMediumReadUnsupported() => throw const _UnsupportedMediumException(),
    };
  }

  void _replyPayloadError(String? replyPrefix, int quiet, Object error) {
    final message = switch (error) {
      _MediumNotFoundException() => 'ENOENT:file not found',
      _UnsupportedMediumException() => 'EINVAL:unsupported transmission medium',
      _PayloadTooLargeException() => 'EFBIG:payload too large',
      _ => 'EINVAL:invalid payload',
    };
    _replyError(replyPrefix, quiet, message);
  }

  void _verifyQueryBytes(
    String? replyPrefix,
    int quiet,
    String base64Payload, {
    required String medium,
    required bool compressed,
    required int dataOffset,
    required int? dataSize,
  }) {
    try {
      final decoded = _decodeBase64Payload(base64Payload);
      final payloadBytes = _readMediumBytes(
        medium,
        decoded,
        dataOffset: dataOffset,
        dataSize: dataSize,
        unlink: false,
      );
      if (compressed && payloadBytes.isNotEmpty) {
        _validateZlibBytes(payloadBytes);
      }
      _replyOk(replyPrefix, quiet);
    } on Exception catch (e) {
      _replyPayloadError(replyPrefix, quiet, e);
    }
  }

  bool _hasRemainingPlacements(int imageId) {
    for (final entry in _placements) {
      if (entry.$1 == imageId) return true;
    }
    return false;
  }

  bool _hasOtherPlacement(int imageId, int placementId, bool isVirtual) {
    for (final entry in _placements) {
      if (entry.$1 != imageId) continue;
      if (entry.$2 != placementId || entry.$3 != isVirtual) return true;
    }
    return false;
  }

  void _deleteImagePlacements(
    int imageId, {
    required int placementId,
    required bool freeData,
  }) {
    var clearedDirect = false;
    final toRemove = <(int, int, bool)>[];
    for (final entry in _placements) {
      if (entry.$1 != imageId) continue;
      if (placementId > 0 && entry.$2 != placementId) continue;
      toRemove.add(entry);
      if (!entry.$3) clearedDirect = true;
    }
    _placements.removeAll(toRemove);
    final clearLegacyUntracked =
        placementId == 0 &&
        toRemove.isEmpty &&
        !_hasRemainingPlacements(imageId);
    if (clearedDirect || clearLegacyUntracked) {
      onClearPlacements?.call(
        imageId,
        placementId: placementId > 0 ? placementId : null,
      );
    }
    if (freeData && !_hasRemainingPlacements(imageId)) {
      registry.unregisterImage(imageId);
      _removePendingUpload(imageId);
      _imageNumberToId.removeWhere((_, id) => id == imageId);
    }
  }

  void _evictUnreferencedImages({required bool hasVirtual}) {
    if (!hasVirtual) {
      registry.clearImages();
      _imageNumberToId.clear();
      return;
    }
    final toEvict = [
      for (final id in registry.registeredImageIds)
        if (!_hasRemainingPlacements(id)) id,
    ];
    for (final id in toEvict) {
      registry.unregisterImage(id);
      _imageNumberToId.removeWhere((_, mapped) => mapped == id);
    }
  }

  void _deleteAllDirectPlacements({required bool freeData}) {
    var hasVirtual = false;
    final toRemove = <(int, int, bool)>[];
    for (final entry in _placements) {
      if (entry.$3) {
        hasVirtual = true;
      } else {
        toRemove.add(entry);
      }
    }
    _placements.removeAll(toRemove);
    onClearPlacements?.call(null, directOnly: hasVirtual);
    if (freeData) {
      _evictUnreferencedImages(hasVirtual: hasVirtual);
    }
  }

  void _deleteImageRange(int minId, int maxId, {required bool freeData}) {
    if (minId <= 0 || maxId < minId) return;
    final targets = [
      for (final id in registry.registeredImageIds)
        if (id >= minId && id <= maxId) id,
    ];
    for (final id in targets) {
      _deleteImagePlacements(id, placementId: 0, freeData: freeData);
    }
  }

  void _handleDelete(Map<String, String> control) {
    final deleteTarget = control['d'] ?? 'a';
    final imageId = _parsePositiveId(control['i']);
    final placementId = _parsePositiveId(control['p']);
    switch (deleteTarget) {
      case 'a' || 'A':
        _deleteAllDirectPlacements(freeData: deleteTarget == 'A');
      case 'i' || 'I':
        if (imageId > 0) {
          _deleteImagePlacements(
            imageId,
            placementId: placementId,
            freeData: deleteTarget == 'I',
          );
        }
      case 'n' || 'N':
        final number = _parsePositiveId(control['I']);
        final mappedId = number > 0 ? _imageNumberToId[number] : null;
        if (mappedId != null) {
          _deleteImagePlacements(
            mappedId,
            placementId: placementId,
            freeData: deleteTarget == 'N',
          );
        }
      case 'r' || 'R':
        _deleteImageRange(
          _parsePositiveId(control['x']),
          _parsePositiveId(control['y']),
          freeData: deleteTarget == 'R',
        );
      default:
        break;
    }
  }

  _PendingUpload? _removePendingUpload(int imageId) {
    if (_lastActiveUploadId == imageId) {
      _lastActiveUploadId = null;
    }
    final removed = _pendingUploads.remove(imageId);
    if (removed != null) {
      _totalPendingBase64 -= removed.byteCount;
    }
    return removed;
  }

  void _evictOldestUploadIfNeeded() {
    while (_pendingUploads.length >= _maxConcurrentUploads) {
      final oldestKey = _pendingUploads.keys.first;
      _removePendingUpload(oldestKey);
    }
  }

  void _evictUnreachableAnonymousUploads() {
    final staleIds = [
      for (final entry in _pendingUploads.entries)
        if (!entry.value.hasAddressableId) entry.key,
    ];
    for (final id in staleIds) {
      _removePendingUpload(id);
    }
  }

  static bool _hasConflictingUploadMetadata(
    _PendingUpload existing,
    Map<String, String> control,
  ) {
    if (control.containsKey('f') && _parseFormat(control) != existing.format) {
      return true;
    }
    if (control.containsKey('t') && _parseMedium(control) != existing.medium) {
      return true;
    }
    if (control.containsKey('s') &&
        (int.tryParse(control['s'] ?? '') ?? -1) != existing.width) {
      return true;
    }
    if (control.containsKey('v') &&
        (int.tryParse(control['v'] ?? '') ?? -1) != existing.height) {
      return true;
    }
    if (control.containsKey('o') &&
        (control['o'] == 'z') != existing.compressed) {
      return true;
    }
    return false;
  }

  static bool _canContinueWithoutAction(
    _PendingUpload candidate,
    Map<String, String> control,
    int explicitId,
    int explicitNumber,
  ) {
    if (!_hasNewUploadMetadata(control)) return true;
    if (!control.containsKey('m') || candidate.action == 'q') return false;
    final matchesId =
        explicitId > 0 &&
        candidate.hasAddressableId &&
        explicitId == candidate.imageId;
    final matchesNumber =
        explicitNumber > 0 && explicitNumber == candidate.explicitNumber;
    if (!matchesId && !matchesNumber) return false;
    return !_hasConflictingUploadMetadata(candidate, control);
  }

  static bool _matchesContinuationMetadata(
    _PendingUpload existing,
    Map<String, String> control,
  ) => control.containsKey('m')
      ? !_hasConflictingUploadMetadata(existing, control)
      : !_hasNewUploadMetadata(control);

  static bool _canContinueExisting(
    _PendingUpload? existing,
    String action,
    Map<String, String> control,
    int explicitId,
  ) {
    if (existing == null || existing.action != action) return false;
    if (explicitId > 0) {
      if (explicitId != existing.imageId || !existing.hasAddressableId) {
        return false;
      }
      return _matchesContinuationMetadata(existing, control);
    }
    final explicitNumber = _parsePositiveId(control['I']);
    if (explicitNumber > 0) {
      return existing.explicitNumber == explicitNumber &&
          _matchesContinuationMetadata(existing, control);
    }
    if (_hasNewUploadMetadata(control)) return false;
    return !control.containsKey('a') || !existing.hasAddressableId;
  }

  _PendingUpload _obtainPendingUpload(
    String action,
    Map<String, String> control,
    int quiet,
  ) {
    final existing = _resolveActiveContinuation(control);
    final explicitId = _parsePositiveId(control['i']);
    if (_canContinueExisting(existing, action, control, explicitId)) {
      return existing!;
    }
    _evictUnreachableAnonymousUploads();

    final explicitNumber = _parsePositiveId(control['I']);
    final placementId = _parsePositiveId(control['p']);
    final hasAddressableId = explicitId > 0;
    final imageId = hasAddressableId ? explicitId : _allocateAutoId();
    _removePendingUpload(imageId);
    _evictOldestUploadIfNeeded();

    final format = _parseFormat(control);
    final created = _PendingUpload(
      imageId: imageId,
      explicitNumber: explicitNumber,
      action: action,
      medium: _parseMedium(control),
      format: format,
      width: int.tryParse(control['s'] ?? '0') ?? 0,
      height: int.tryParse(control['v'] ?? '0') ?? 0,
      cols: _parseOptionalPositiveInt(control['c']),
      rows: _parseOptionalPositiveInt(control['r']),
      dataOffset: _parseDataOffset(control['O']),
      dataSize: _parseDataSize(control['S']),
      compressed: control['o'] == 'z',
      quiet: quiet,
      advanceCursor: (int.tryParse(control['C'] ?? '0') ?? 0) != 1,
      virtual: (int.tryParse(control['U'] ?? '0') ?? 0) == 1,
      placementId: placementId,
      hasAddressableId: hasAddressableId,
      replyPrefix: _resolveReplyPrefix(
        hasAddressableId || explicitNumber > 0 ? imageId : 0,
        explicitNumber,
        placementId: placementId,
        isQuery: action == 'q',
      ),
      validationError: _resolveValidationError(control, format),
    );
    _pendingUploads[imageId] = created;
    return created;
  }

  void _appendChunk(_PendingUpload pending, String dataPart) {
    if (pending.validationError != null ||
        pending.overflowed ||
        dataPart.isEmpty) {
      return;
    }
    final nextUploadBytes = pending.byteCount + dataPart.length;
    final nextTotalBytes = _totalPendingBase64 + dataPart.length;
    if (nextUploadBytes > _maxBase64PerUpload ||
        nextTotalBytes > _maxTotalPendingBase64) {
      _totalPendingBase64 -= pending.byteCount;
      pending.byteCount = 0;
      pending.base64Data.clear();
      pending.overflowed = true;
      return;
    }
    pending.base64Data.write(dataPart);
    pending.byteCount = nextUploadBytes;
    _totalPendingBase64 = nextTotalBytes;
  }

  ({bool isMore, int effectiveQuiet}) _bufferUploadChunk(
    _PendingUpload pending,
    Map<String, String> control,
    String dataPart,
    int quiet,
  ) {
    final isMore = (int.tryParse(control['m'] ?? '0') ?? 0) == 1;
    if (isMore) {
      _lastActiveUploadId = pending.imageId;
    }
    _appendChunk(pending, dataPart);
    if (!isMore) {
      _removePendingUpload(pending.imageId);
    }
    return (
      isMore: isMore,
      effectiveQuiet: control.containsKey('q') ? quiet : pending.quiet,
    );
  }

  void _handleTransmit(
    String action,
    Map<String, String> control,
    String dataPart,
    int quiet,
  ) {
    final pending = _obtainPendingUpload(action, control, quiet);
    final chunk = _bufferUploadChunk(pending, control, dataPart, quiet);
    if (chunk.isMore) return;

    _finalizeUpload(pending, chunk.effectiveQuiet);
  }

  void _finalizeUpload(_PendingUpload pending, int quiet) {
    if (pending.validationError != null) {
      _replyError(pending.replyPrefix, quiet, pending.validationError!);
      return;
    }
    if (pending.overflowed) {
      _replyError(pending.replyPrefix, quiet, 'EFBIG:payload too large');
      return;
    }

    try {
      final rawBytes = _decodePayloadBytes(pending);
      final existing = registry.lookupImage(pending.imageId);
      final rawData = _buildImageData(pending, rawBytes);
      final imageData = existing != null
          ? rawData.copyWith(version: existing.version + 1)
          : rawData;
      registry.registerImage(imageData);
      if (pending.explicitNumber > 0) {
        _imageNumberToId[pending.explicitNumber] = pending.imageId;
      }
      if (pending.action == 'T' || pending.virtual) {
        _placements.add((
          pending.imageId,
          pending.placementId,
          pending.virtual,
        ));
      }
      if (pending.action == 'T' && !pending.virtual) {
        onPlaceVirtual(
          imageData.gridCols,
          imageData.gridRows,
          pending.imageId,
          pending.advanceCursor,
          pending.placementId,
        );
      }
      _replyOk(pending.replyPrefix, quiet);
    } on Exception catch (e) {
      _replyPayloadError(pending.replyPrefix, quiet, e);
    }
  }

  static Uint8List _decodePayloadBytes(_PendingUpload pending) {
    final decoded = _decodeBase64Payload(pending.base64Data.toString());
    final payloadBytes = _readMediumBytes(
      pending.medium,
      decoded,
      dataOffset: pending.dataOffset,
      dataSize: pending.dataSize,
      unlink: true,
    );
    return pending.compressed ? _inflateZlibBytes(payloadBytes) : payloadBytes;
  }

  KittyImageData _buildImageData(_PendingUpload pending, Uint8List rawBytes) =>
      switch (pending.format) {
        KittyImageData.formatPng => _buildPngImageData(pending, rawBytes),
        KittyImageData.formatRgb24 => _buildRgb24ImageData(pending, rawBytes),
        KittyImageData.formatRgba32 => _buildRgba32ImageData(pending, rawBytes),
        _ => throw const _InvalidPayloadException(),
      };

  static bool _isValidDimensions(int width, int height) =>
      width > 0 &&
      height > 0 &&
      width <= _maxDimension &&
      height <= _maxDimension &&
      width * height <= _maxTotalPixels;

  (int cols, int rows) _resolvePlacementGrid(
    int? reqCols,
    int? reqRows,
    int pixelWidth,
    int pixelHeight,
  ) {
    final (rawCellW, rawCellH) = cellPixelSize();
    final cellW = math.max(1, rawCellW);
    final cellH = math.max(1, rawCellH);
    final maxSpan = kittyDiacritics.length;
    if (reqCols != null && reqRows != null) {
      return (reqCols.clamp(1, maxSpan), reqRows.clamp(1, maxSpan));
    }
    if (reqCols != null) {
      final cols = reqCols.clamp(1, maxSpan);
      final rows = ((cols * cellW * pixelHeight) / (pixelWidth * cellH))
          .round()
          .clamp(1, maxSpan);
      return (cols, rows);
    }
    if (reqRows != null) {
      final rows = reqRows.clamp(1, maxSpan);
      final cols = ((rows * cellH * pixelWidth) / (pixelHeight * cellW))
          .round()
          .clamp(1, maxSpan);
      return (cols, rows);
    }
    return (
      ((pixelWidth + cellW - 1) ~/ cellW).clamp(1, maxSpan),
      ((pixelHeight + cellH - 1) ~/ cellH).clamp(1, maxSpan),
    );
  }

  (int cols, int rows) _resolveUploadGrid(
    _PendingUpload pending,
    int pixelWidth,
    int pixelHeight,
  ) => _resolvePlacementGrid(
    pending.cols,
    pending.rows,
    pixelWidth,
    pixelHeight,
  );

  KittyImageData _buildPngImageData(
    _PendingUpload pending,
    Uint8List rawBytes,
  ) {
    final (ihdrWidth, ihdrHeight) = _extractPngDimensions(rawBytes);
    if (!_isValidDimensions(ihdrWidth, ihdrHeight)) {
      throw const _InvalidPayloadException();
    }
    if ((pending.width > 0 && pending.width != ihdrWidth) ||
        (pending.height > 0 && pending.height != ihdrHeight)) {
      throw const _InvalidPayloadException();
    }
    final (cols, rows) = _resolveUploadGrid(pending, ihdrWidth, ihdrHeight);
    return KittyImageData.fromPng(
      imageId: pending.imageId,
      pixelWidth: ihdrWidth,
      pixelHeight: ihdrHeight,
      pngBytes: rawBytes,
      gridCols: cols,
      gridRows: rows,
    );
  }

  static (int width, int height) _extractPngDimensions(Uint8List bytes) {
    if (bytes.length < 24 || !_hasValidPngIhdrMagic(bytes)) {
      throw const _InvalidPayloadException();
    }
    final view = ByteData.sublistView(bytes);
    if (view.getUint32(8) != 13) {
      throw const _InvalidPayloadException();
    }
    return (view.getUint32(16), view.getUint32(20));
  }

  static bool _hasValidPngIhdrMagic(Uint8List bytes) {
    for (var i = 0; i < _pngSignature.length; i++) {
      if (bytes[i] != _pngSignature[i]) return false;
    }
    return bytes[12] == 0x49 &&
        bytes[13] == 0x48 &&
        bytes[14] == 0x44 &&
        bytes[15] == 0x52;
  }

  KittyImageData _buildRgb24ImageData(
    _PendingUpload pending,
    Uint8List rawBytes,
  ) {
    if (!_isValidDimensions(pending.width, pending.height)) {
      throw const _InvalidPayloadException();
    }
    final totalPixels = pending.width * pending.height;
    if (rawBytes.length < totalPixels * 3) {
      throw const _InvalidPayloadException();
    }
    final rgba = _convertRgb24ToRgba32(rawBytes, totalPixels);
    final (cols, rows) = _resolveUploadGrid(
      pending,
      pending.width,
      pending.height,
    );
    return KittyImageData(
      imageId: pending.imageId,
      pixelWidth: pending.width,
      pixelHeight: pending.height,
      rgbaPixels: rgba,
      gridCols: cols,
      gridRows: rows,
      format: KittyImageData.formatRgba32,
    );
  }

  KittyImageData _buildRgba32ImageData(
    _PendingUpload pending,
    Uint8List rawBytes,
  ) {
    if (!_isValidDimensions(pending.width, pending.height)) {
      throw const _InvalidPayloadException();
    }
    final expectedBytes = pending.width * pending.height * 4;
    if (rawBytes.length < expectedBytes) {
      throw const _InvalidPayloadException();
    }
    final pixels = rawBytes.length == expectedBytes
        ? rawBytes
        : Uint8List.sublistView(rawBytes, 0, expectedBytes);
    final (cols, rows) = _resolveUploadGrid(
      pending,
      pending.width,
      pending.height,
    );
    return KittyImageData(
      imageId: pending.imageId,
      pixelWidth: pending.width,
      pixelHeight: pending.height,
      rgbaPixels: pixels,
      gridCols: cols,
      gridRows: rows,
      format: KittyImageData.formatRgba32,
    );
  }

  static Uint8List _convertRgb24ToRgba32(Uint8List rgb, int totalPixels) {
    final rgba = Uint8List(totalPixels * 4);
    var src = 0;
    var dst = 0;
    for (var i = 0; i < totalPixels; i++) {
      rgba[dst] = rgb[src];
      rgba[dst + 1] = rgb[src + 1];
      rgba[dst + 2] = rgb[src + 2];
      rgba[dst + 3] = 255;
      src += 3;
      dst += 4;
    }
    return rgba;
  }

  int _resolveTargetImageId(int explicitId, int explicitNumber) {
    if (explicitId > 0) return explicitId;
    if (explicitNumber > 0) return _imageNumberToId[explicitNumber] ?? 0;
    return 0;
  }

  void _handlePlace(Map<String, String> control, int quiet) {
    final explicitId = _parsePositiveId(control['i']);
    final explicitNumber = _parsePositiveId(control['I']);
    final placementId = _parsePositiveId(control['p']);
    if (explicitId > 0 && explicitNumber > 0) {
      final errPrefix = _resolveReplyPrefix(
        explicitId,
        0,
        placementId: placementId,
      );
      _replyError(errPrefix, quiet, 'EINVAL:cannot specify both i and I');
      return;
    }
    final imageId = _resolveTargetImageId(explicitId, explicitNumber);
    final replyPrefix = _resolveReplyPrefix(
      imageId,
      explicitNumber,
      placementId: placementId,
    );
    final data = imageId > 0 ? registry.lookupImage(imageId) : null;
    if (data == null) {
      _replyError(replyPrefix, quiet, 'ENOENT:image not found');
      return;
    }

    final reqCols = _parseOptionalPositiveInt(control['c']);
    final reqRows = _parseOptionalPositiveInt(control['r']);
    final (cols, rows) = (reqCols != null || reqRows != null)
        ? _resolvePlacementGrid(
            reqCols,
            reqRows,
            data.pixelWidth,
            data.pixelHeight,
          )
        : (data.gridCols, data.gridRows);
    final isVirtual = (int.tryParse(control['U'] ?? '0') ?? 0) == 1;
    if ((cols != data.gridCols || rows != data.gridRows) &&
        !_hasOtherPlacement(imageId, placementId, isVirtual)) {
      registry.registerImage(data.copyWith(gridCols: cols, gridRows: rows));
    }
    _placements.add((imageId, placementId, isVirtual));
    if (!isVirtual) {
      final advanceCursor = (int.tryParse(control['C'] ?? '0') ?? 0) != 1;
      onPlaceVirtual(cols, rows, imageId, advanceCursor, placementId);
    }
    _replyOk(replyPrefix, quiet);
  }
}
