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

final class _PlacementParams {
  final int srcX;
  final int srcY;
  final int srcWidth;
  final int srcHeight;
  final int cellOffsetX;
  final int cellOffsetY;
  final int zIndex;
  final int parentImageId;
  final int parentPlacementId;
  final int relCols;
  final int relRows;

  const _PlacementParams({
    this.srcX = 0,
    this.srcY = 0,
    this.srcWidth = 0,
    this.srcHeight = 0,
    this.cellOffsetX = 0,
    this.cellOffsetY = 0,
    this.zIndex = 0,
    this.parentImageId = 0,
    this.parentPlacementId = 0,
    this.relCols = 0,
    this.relRows = 0,
  });
}

final class _FrameUploadParams {
  final int targetFrame;
  final int baseFrame;
  final int dstX;
  final int dstY;
  final bool replace;
  final int bgColor;
  final int? gapMs;

  const _FrameUploadParams({
    required this.targetFrame,
    required this.baseFrame,
    required this.dstX,
    required this.dstY,
    required this.replace,
    required this.bgColor,
    required this.gapMs,
  });
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
  final _PlacementParams? placementParams;
  final _FrameUploadParams? frameParams;
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
    this.placementParams,
    this.frameParams,
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
  static const int _maxRelativeChainDepth = 64;
  static const int _minInt32 = -0x80000000;
  static const int _maxInt32 = 0x7FFFFFFF;
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

  /// Optional callback returning the live terminal cursor coordinates `(col, row)`.
  final (int col, int row) Function()? cursorPosition;

  /// Optional callback returning the live terminal viewport size `(cols, rows)`.
  final (int cols, int rows) Function()? viewportSize;

  /// Optional callback returning whether the alternate screen buffer is active.
  final bool Function()? isAltScreen;

  /// Optional callback resolving pending right-margin wrap before reading
  /// [cursorPosition] for a direct placement that advances the cursor.
  final void Function()? resolvePendingWrap;

  /// Optional callback invoked when a layered (`z != 0`) or relative (`P > 0`)
  /// direct placement advances the cursor (`C=0`).
  final void Function(int cols, int rows)? onAdvanceCursor;

  /// Optional callback invoked when `a=d` deletes placeholder cells matching
  /// cursor/column/row/z-index filters.
  final void Function({int? col, int? row, int? zIndex})? onClearPlacementsAt;

  /// Whether local filesystem (`t=t`) transmission media is enabled.
  /// Defaults to `false`.
  bool allowLocalMedia;

  /// Whether POSIX shared-memory (`t=s`) transmission media is enabled.
  /// Defaults to [allowLocalMedia].
  bool allowLocalShm;

  /// Whether local regular-file (`t=f`, non-unlinking) transmission media is enabled.
  /// Defaults to `false`.
  bool allowLocalFiles;

  final Map<int, _PendingUpload> _pendingUploads = {};
  final Map<int, int> _imageNumberToId = {};
  int _totalPendingBase64 = 0;
  int? _lastActiveUploadId;
  int _nextAutoId = 0x80000001;
  int _frameVersionCounter = 1;

  /// Creates a [KittyApcHandler] bound to a scoped [registry].
  KittyApcHandler({
    required this.registry,
    required this.onReply,
    required this.onPlaceVirtual,
    required this.cellPixelSize,
    this.onClearPlacements,
    this.cursorPosition,
    this.viewportSize,
    this.isAltScreen,
    this.resolvePendingWrap,
    this.onAdvanceCursor,
    this.onClearPlacementsAt,
    this.allowLocalMedia = false,
    bool? allowLocalShm,
    this.allowLocalFiles = false,
  }) : allowLocalShm = allowLocalShm ?? allowLocalMedia;

  /// Clears all pending chunked uploads, placements, and wipes [registry].
  void reset() {
    _pendingUploads.clear();
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
      case 'f':
        _handleAnimationFrame(control, dataPart, quiet);
      case 'a':
        _handleAnimationControl(control, quiet);
      case 'c':
        _handleAnimationCompose(control, quiet);
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

  static int _parseSignedInt32(String? raw) {
    if (raw == null) return 0;
    final parsed = int.tryParse(raw);
    if (parsed == null) return 0;
    return parsed.clamp(_minInt32, _maxInt32);
  }

  static int _parseNonNegativeInt(String? raw) {
    if (raw == null) return 0;
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 0) return 0;
    return parsed;
  }

  static int _parseUint32(String? raw) {
    if (raw == null) return 0;
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 0) return 0;
    return parsed > 0xFFFFFFFF ? 0xFFFFFFFF : parsed;
  }

  static int _parseOneBasedCoord(String? raw) {
    final parsed = int.tryParse(raw ?? '1') ?? 1;
    return math.max(1, parsed) - 1;
  }

  static _PlacementParams _parsePlacementParams(Map<String, String> control) =>
      _PlacementParams(
        srcX: _parseNonNegativeInt(control['x']),
        srcY: _parseNonNegativeInt(control['y']),
        srcWidth: _parseNonNegativeInt(control['w']),
        srcHeight: _parseNonNegativeInt(control['h']),
        cellOffsetX: _parseNonNegativeInt(control['X']),
        cellOffsetY: _parseNonNegativeInt(control['Y']),
        zIndex: _parseSignedInt32(control['z']),
        parentImageId: _parsePositiveId(control['P']),
        parentPlacementId: _parsePositiveId(control['Q']),
        relCols: _parseSignedInt32(control['H']),
        relRows: _parseSignedInt32(control['V']),
      );

  static _FrameUploadParams _parseFrameUploadParams(
    Map<String, String> control,
  ) => _FrameUploadParams(
    targetFrame: _parsePositiveId(control['r']),
    baseFrame: _parsePositiveId(control['c']),
    dstX: _parseNonNegativeInt(control['x']),
    dstY: _parseNonNegativeInt(control['y']),
    replace: (int.tryParse(control['X'] ?? '0') ?? 0) == 1,
    bgColor: _parseUint32(control['Y']),
    gapMs: control.containsKey('z') ? _parseSignedInt32(control['z']) : null,
  );

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
        't' => allowLocalMedia && platformSupportsKittyMedium('t'),
        's' => allowLocalShm && platformSupportsKittyMedium('s'),
        'f' => allowLocalFiles && platformSupportsKittyMedium('f'),
        _ => false,
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

  String? _resolveValidationError(
    Map<String, String> control,
    int format, {
    String action = 't',
  }) {
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
    if (action == 'T' &&
        (_isOutOfRangeUint32(control['P']) ||
            _isOutOfRangeUint32(control['Q']))) {
      return 'EINVAL:invalid parent id';
    }
    if (action == 'f') {
      return _resolveFrameValidationError(control);
    }
    return null;
  }

  static String? _resolveFrameValidationError(Map<String, String> control) {
    final compRaw = control['X'];
    if (compRaw != null && compRaw != '0' && compRaw != '1') {
      return 'EINVAL:invalid composition mode';
    }
    if (_isNegativeInt(control['x']) || _isNegativeInt(control['y'])) {
      return 'EINVAL:invalid frame geometry';
    }
    if (_isOutOfRangeUint32(control['r']) ||
        _isOutOfRangeUint32(control['c'])) {
      return 'EINVAL:invalid frame number';
    }
    return null;
  }

  static bool _isNegativeInt(String? raw) {
    if (raw == null) return false;
    final parsed = int.tryParse(raw);
    return parsed == null || parsed < 0;
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
      control.containsKey('p') ||
      control.containsKey('x') ||
      control.containsKey('y') ||
      control.containsKey('w') ||
      control.containsKey('h') ||
      control.containsKey('X') ||
      control.containsKey('Y') ||
      control.containsKey('z') ||
      control.containsKey('P') ||
      control.containsKey('Q') ||
      control.containsKey('H') ||
      control.containsKey('V');

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
    bool Function(Uint8List bytes)? shouldUnlink,
  }) {
    if (medium == 'd') return decoded;
    return switch (readPlatformKittyMedium(
      medium,
      decoded,
      maxBytes: _maxInflatedBytes,
      offset: dataOffset,
      size: dataSize,
      unlink: unlink,
      shouldUnlink: shouldUnlink,
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
    final masked = imageId & 0xFFFFFFFF;
    for (final p in registry.allPlacements) {
      if ((p.imageId & 0xFFFFFFFF) == masked) return true;
    }
    return false;
  }

  bool _hasOtherPlacement(int imageId, int placementId, bool isVirtual) {
    final maskedImg = imageId & 0xFFFFFFFF;
    final maskedPlc = placementId & 0xFFFFFFFF;
    for (final p in registry.allPlacements) {
      if ((p.imageId & 0xFFFFFFFF) != maskedImg) continue;
      if ((p.placementId & 0xFFFFFFFF) != maskedPlc ||
          p.isVirtual != isVirtual) {
        return true;
      }
    }
    return false;
  }

  Set<int> _cascadeRemoveRelativePlacements(Set<(int, int)> initialRemoved) {
    final affectedImages = <int>{for (final key in initialRemoved) key.$1};
    var frontier = initialRemoved;
    while (frontier.isNotEmpty) {
      final children = <KittyPlacement>[
        for (final p in registry.allPlacements)
          if (p.isRelative &&
              frontier.contains((
                p.parentImageId & 0xFFFFFFFF,
                p.parentPlacementId & 0xFFFFFFFF,
              )))
            p,
      ];
      if (children.isEmpty) break;
      final nextFrontier = <(int, int)>{};
      for (final child in children) {
        registry.removePlacement(child.imageId, child.placementId);
        final key = (
          child.imageId & 0xFFFFFFFF,
          child.placementId & 0xFFFFFFFF,
        );
        nextFrontier.add(key);
        affectedImages.add(key.$1);
      }
      frontier = nextFrontier;
    }
    return affectedImages;
  }

  void _evictImagesWithoutPlacements(Iterable<int> imageIds) {
    for (final id in imageIds) {
      if (_hasRemainingPlacements(id)) continue;
      registry.unregisterImage(id);
      _removePendingUpload(id);
      _imageNumberToId.removeWhere((_, mapped) => mapped == id);
    }
  }

  void _deleteImagePlacements(
    int imageId, {
    required int placementId,
    required bool freeData,
  }) {
    final maskedImg = imageId & 0xFFFFFFFF;
    final maskedPlc = placementId & 0xFFFFFFFF;
    var clearedDirect = false;
    final removedKeys = <(int, int)>{};
    for (final p in registry.allPlacements) {
      if ((p.imageId & 0xFFFFFFFF) != maskedImg) continue;
      if (placementId > 0 && (p.placementId & 0xFFFFFFFF) != maskedPlc) {
        continue;
      }
      removedKeys.add((p.imageId & 0xFFFFFFFF, p.placementId & 0xFFFFFFFF));
      if (!p.isVirtual) clearedDirect = true;
    }
    registry.removePlacement(imageId, placementId > 0 ? placementId : null);
    final affected = _cascadeRemoveRelativePlacements(removedKeys)
      ..add(maskedImg);
    final clearLegacyUntracked =
        placementId == 0 &&
        removedKeys.isEmpty &&
        !_hasRemainingPlacements(imageId);
    if (clearedDirect || clearLegacyUntracked) {
      onClearPlacements?.call(
        imageId,
        placementId: placementId > 0 ? placementId : null,
      );
    }
    if (freeData) {
      _evictImagesWithoutPlacements(affected);
    }
  }

  void _evictUnreferencedImages({required bool hasVirtual}) {
    if (!hasVirtual && !registry.hasPlacements) {
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
    final activeAlt = isAltScreen?.call() ?? false;
    var hasVirtual = false;
    final removedKeys = <(int, int)>{};
    for (final p in registry.allPlacements) {
      if (p.isVirtual) {
        hasVirtual = true;
      } else if (p.isAltScreen == activeAlt) {
        removedKeys.add((p.imageId & 0xFFFFFFFF, p.placementId & 0xFFFFFFFF));
      }
    }
    registry.removePlacementsWhere(
      (p) => !p.isVirtual && p.isAltScreen == activeAlt,
    );
    _cascadeRemoveRelativePlacements(removedKeys);
    onClearPlacements?.call(null, directOnly: true);
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

  (int col, int row)? _resolvePlacementOrigin(KittyPlacement placement) {
    var col = placement.isRelative ? placement.relCols : placement.gridCol;
    var row = placement.isRelative ? placement.relRows : placement.gridRow;
    var current = placement;
    for (
      var depth = 0;
      depth < _maxRelativeChainDepth && current.isRelative;
      depth++
    ) {
      final parent = registry.lookupPlacement(
        current.parentImageId,
        current.parentPlacementId,
      );
      if (parent == null) return null;
      col += parent.isRelative ? parent.relCols : parent.gridCol;
      row += parent.isRelative ? parent.relRows : parent.gridRow;
      current = parent;
    }
    return current.isRelative ? null : (col, row);
  }

  bool _placementContainsPoint(KittyPlacement placement, int col, int row) {
    final origin = _resolvePlacementOrigin(placement);
    if (origin == null) return false;
    return col >= origin.$1 &&
        col < origin.$1 + placement.cols &&
        row >= origin.$2 &&
        row < origin.$2 + placement.rows;
  }

  bool _placementContainsCol(KittyPlacement placement, int col) {
    final origin = _resolvePlacementOrigin(placement);
    if (origin == null) return false;
    return col >= origin.$1 && col < origin.$1 + placement.cols;
  }

  bool _placementContainsRow(KittyPlacement placement, int row) {
    final origin = _resolvePlacementOrigin(placement);
    if (origin == null) return false;
    return row >= origin.$2 && row < origin.$2 + placement.rows;
  }

  void _deleteByFilter(
    bool Function(KittyPlacement placement) predicate, {
    required bool freeData,
    int? clearCol,
    int? clearRow,
    int? clearZIndex,
  }) {
    final activeAlt = isAltScreen?.call() ?? false;
    final matched = [
      for (final p in registry.allPlacements)
        if (!p.isVirtual && p.isAltScreen == activeAlt && predicate(p)) p,
    ];
    final removedKeys = <(int, int)>{};
    for (final p in matched) {
      registry.removePlacement(p.imageId, p.placementId);
      removedKeys.add((p.imageId & 0xFFFFFFFF, p.placementId & 0xFFFFFFFF));
      if (p.zIndex == 0 && !p.isRelative) {
        onClearPlacements?.call(
          p.imageId,
          placementId: p.placementId,
          directOnly: true,
        );
      }
    }
    final affected = _cascadeRemoveRelativePlacements(removedKeys);
    onClearPlacementsAt?.call(
      col: clearCol,
      row: clearRow,
      zIndex: clearZIndex,
    );
    if (freeData && affected.isNotEmpty) {
      _evictImagesWithoutPlacements(affected);
    }
  }

  void _deleteAnimationFrames(Map<String, String> control) {
    final explicitId = _parsePositiveId(control['i']);
    final explicitNumber = _parsePositiveId(control['I']);
    if (!control.containsKey('i') && !control.containsKey('I')) {
      registry.clearAnimations();
      return;
    }
    final targetId = _resolveTargetImageId(explicitId, explicitNumber);
    if (targetId > 0) {
      registry.removeAnimationFrames(targetId);
    }
  }

  void _handleDelete(Map<String, String> control) {
    final target = control['d'] ?? 'a';
    final freeData = target == target.toUpperCase();
    final imageId = _parsePositiveId(control['i']);
    final placementId = _parsePositiveId(control['p']);
    switch (target) {
      case 'a' || 'A':
        _deleteAllDirectPlacements(freeData: freeData);
      case 'i' || 'I':
        if (imageId > 0) {
          _deleteImagePlacements(
            imageId,
            placementId: placementId,
            freeData: freeData,
          );
        }
      case 'n' || 'N':
        final number = _parsePositiveId(control['I']);
        final mappedId = number > 0 ? _imageNumberToId[number] : null;
        if (mappedId != null) {
          _deleteImagePlacements(
            mappedId,
            placementId: placementId,
            freeData: freeData,
          );
        }
      case 'r' || 'R':
        _deleteImageRange(
          _parsePositiveId(control['x']),
          _parsePositiveId(control['y']),
          freeData: freeData,
        );
      case 'c' || 'C':
        final (col, row) = cursorPosition?.call() ?? (0, 0);
        _deleteByFilter(
          (p) => _placementContainsPoint(p, col, row),
          freeData: freeData,
          clearCol: col,
          clearRow: row,
        );
      case 'p' || 'P':
        final col = _parseOneBasedCoord(control['x']);
        final row = _parseOneBasedCoord(control['y']);
        _deleteByFilter(
          (p) => _placementContainsPoint(p, col, row),
          freeData: freeData,
          clearCol: col,
          clearRow: row,
        );
      case 'q' || 'Q':
        final col = _parseOneBasedCoord(control['x']);
        final row = _parseOneBasedCoord(control['y']);
        final z = _parseSignedInt32(control['z']);
        _deleteByFilter(
          (p) => p.zIndex == z && _placementContainsPoint(p, col, row),
          freeData: freeData,
          clearCol: col,
          clearRow: row,
          clearZIndex: z,
        );
      case 'x' || 'X':
        final col = _parseOneBasedCoord(control['x']);
        _deleteByFilter(
          (p) => _placementContainsCol(p, col),
          freeData: freeData,
          clearCol: col,
        );
      case 'y' || 'Y':
        final row = _parseOneBasedCoord(control['y']);
        _deleteByFilter(
          (p) => _placementContainsRow(p, row),
          freeData: freeData,
          clearRow: row,
        );
      case 'z' || 'Z':
        final z = _parseSignedInt32(control['z']);
        _deleteByFilter(
          (p) => p.zIndex == z,
          freeData: freeData,
          clearZIndex: z,
        );
      case 'f' || 'F':
        _deleteAnimationFrames(control);
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
    if (existing.action == 'f' &&
        control.containsKey('r') &&
        _parsePositiveId(control['r']) !=
            (existing.frameParams?.targetFrame ?? 0)) {
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
    return !_hasNewUploadMetadata(control);
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
    final mappedFrameId = action == 'f' && explicitId == 0 && explicitNumber > 0
        ? (_imageNumberToId[explicitNumber] ?? 0)
        : 0;
    final hasAddressableId = explicitId > 0;
    final imageId = hasAddressableId
        ? explicitId
        : (mappedFrameId > 0 ? mappedFrameId : _allocateAutoId());
    _removePendingUpload(imageId);
    _evictOldestUploadIfNeeded();

    final format = _parseFormat(control);
    var validationError = _resolveValidationError(
      control,
      format,
      action: action,
    );
    if (action == 'f' &&
        validationError == null &&
        explicitId == 0 &&
        explicitNumber > 0 &&
        mappedFrameId == 0) {
      validationError = 'ENOENT:image not found';
    }
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
        hasAddressableId ||
                explicitNumber > 0 && (action != 'f' || mappedFrameId > 0)
            ? imageId
            : 0,
        explicitNumber,
        placementId: action == 'f' ? 0 : placementId,
        isQuery: action == 'q',
      ),
      validationError: validationError,
      placementParams: action == 'T' ? _parsePlacementParams(control) : null,
      frameParams: action == 'f' ? _parseFrameUploadParams(control) : null,
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

  String? _commitUploadedImage(
    _PendingUpload pending,
    KittyImageData imageData,
  ) {
    if (pending.action == 'T') {
      final built = _validateAndBuildPlacement(
        data: imageData,
        placementId: pending.placementId,
        isVirtual: pending.virtual,
        advanceCursor: pending.advanceCursor,
        reqCols: pending.cols,
        reqRows: pending.rows,
        params: pending.placementParams ?? const _PlacementParams(),
      );
      if (built.error != null) return built.error;
      final placement = built.placement!;
      final finalImage =
          (placement.cols != imageData.gridCols ||
              placement.rows != imageData.gridRows)
          ? imageData.copyWith(
              gridCols: placement.cols,
              gridRows: placement.rows,
            )
          : imageData;
      registry.registerImage(finalImage);
      if (pending.explicitNumber > 0) {
        _imageNumberToId[pending.explicitNumber] = pending.imageId;
      }
      _applyPlacement(placement, advanceCursor: pending.advanceCursor);
      return null;
    }

    registry.registerImage(imageData);
    if (pending.explicitNumber > 0) {
      _imageNumberToId[pending.explicitNumber] = pending.imageId;
    }
    if (pending.virtual) {
      _applyPlacement(
        KittyPlacement(
          imageId: pending.imageId,
          placementId: pending.placementId,
          isVirtual: true,
          isAltScreen: isAltScreen?.call() ?? false,
          cols: imageData.gridCols,
          rows: imageData.gridRows,
        ),
        advanceCursor: false,
      );
    }
    return null;
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
      final rawData = _decodeAndBuildImageData(pending);
      final existing = registry.lookupImage(pending.imageId);
      final imageData = existing != null
          ? rawData.copyWith(version: existing.version + 1)
          : rawData;
      final commitError = _commitUploadedImage(pending, imageData);
      if (commitError != null) {
        _replyError(pending.replyPrefix, quiet, commitError);
        return;
      }
      _replyOk(pending.replyPrefix, quiet);
    } on Exception catch (e) {
      _replyPayloadError(pending.replyPrefix, quiet, e);
    }
  }

  KittyImageData _decodeAndBuildImageData(_PendingUpload pending) {
    final decoded = _decodeBase64Payload(pending.base64Data.toString());
    if (pending.medium == 'd') {
      final rawBytes = pending.compressed
          ? _inflateZlibBytes(decoded)
          : decoded;
      return _buildImageData(pending, rawBytes);
    }
    if (pending.medium == 'f') {
      final payloadBytes = _readMediumBytes(
        pending.medium,
        decoded,
        dataOffset: pending.dataOffset,
        dataSize: pending.dataSize,
        unlink: false,
      );
      final rawBytes = pending.compressed
          ? _inflateZlibBytes(payloadBytes)
          : payloadBytes;
      return _buildImageData(pending, rawBytes);
    }
    late final KittyImageData built;
    _readMediumBytes(
      pending.medium,
      decoded,
      dataOffset: pending.dataOffset,
      dataSize: pending.dataSize,
      unlink: true,
      shouldUnlink: (payloadBytes) {
        final rawBytes = pending.compressed
            ? _inflateZlibBytes(payloadBytes)
            : payloadBytes;
        built = _buildImageData(pending, rawBytes);
        return true;
      },
    );
    return built;
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

  bool _createsRelativeCycle(
    int imageId,
    int placementId,
    int parentImageId,
    int parentPlacementId,
  ) {
    final visited = <(int, int)>{
      (imageId & 0xFFFFFFFF, placementId & 0xFFFFFFFF),
    };
    var curImage = parentImageId & 0xFFFFFFFF;
    var curPlacement = parentPlacementId & 0xFFFFFFFF;
    for (var depth = 0; depth < _maxRelativeChainDepth; depth++) {
      final curKey = (curImage, curPlacement);
      if (visited.contains(curKey)) return true;
      visited.add(curKey);
      final parent = registry.lookupPlacement(curImage, curPlacement);
      if (parent == null || !parent.isRelative) return false;
      curImage = parent.parentImageId & 0xFFFFFFFF;
      curPlacement = parent.parentPlacementId & 0xFFFFFFFF;
    }
    return true;
  }

  ({int col, int row, String? error}) _resolveRelativeAnchor({
    required int imageId,
    required int placementId,
    required _PlacementParams params,
    required bool currentAlt,
  }) {
    if (_createsRelativeCycle(
      imageId,
      placementId,
      params.parentImageId,
      params.parentPlacementId,
    )) {
      return (col: 0, row: 0, error: 'EINVAL:relative placement cycle');
    }
    final parent = registry.lookupPlacement(
      params.parentImageId,
      params.parentPlacementId,
    );
    if (parent == null || parent.isAltScreen != currentAlt) {
      return (col: 0, row: 0, error: 'ENOENT:parent placement not found');
    }
    if (parent.isVirtual) {
      return (
        col: 0,
        row: 0,
        error: 'EINVAL:cannot place relative to virtual placement',
      );
    }
    final origin = _resolvePlacementOrigin(parent);
    return (
      col: (origin?.$1 ?? parent.gridCol) + params.relCols,
      row: (origin?.$2 ?? parent.gridRow) + params.relRows,
      error: null,
    );
  }

  (int col, int row) _resolveDirectAnchor({required bool advanceCursor}) {
    if (advanceCursor && resolvePendingWrap != null) {
      resolvePendingWrap!();
    }
    final (curCol, curRow) = cursorPosition?.call() ?? (0, 0);
    final vpCols = viewportSize?.call().$1;
    if (vpCols != null && vpCols > 0 && curCol >= vpCols) {
      if (resolvePendingWrap != null || !advanceCursor) {
        return (vpCols - 1, curRow);
      }
      return (0, curRow + 1);
    }
    return (curCol, curRow);
  }

  ({KittyPlacement? placement, String? error}) _validateAndBuildPlacement({
    required KittyImageData data,
    required int placementId,
    required bool isVirtual,
    required bool advanceCursor,
    required int? reqCols,
    required int? reqRows,
    required _PlacementParams params,
  }) {
    final currentAlt = isAltScreen?.call() ?? false;
    var gridCol = 0;
    var gridRow = 0;
    if (params.parentImageId > 0) {
      final anchor = _resolveRelativeAnchor(
        imageId: data.imageId,
        placementId: placementId,
        params: params,
        currentAlt: currentAlt,
      );
      if (anchor.error != null) {
        return (placement: null, error: anchor.error);
      }
      gridCol = anchor.col;
      gridRow = anchor.row;
    } else if (!isVirtual) {
      (gridCol, gridRow) = _resolveDirectAnchor(advanceCursor: advanceCursor);
    }

    final srcX = params.srcX.clamp(0, data.pixelWidth);
    final srcY = params.srcY.clamp(0, data.pixelHeight);
    final remW = math.max(0, data.pixelWidth - srcX);
    final remH = math.max(0, data.pixelHeight - srcY);
    final srcWidth = params.srcWidth > 0 ? math.min(params.srcWidth, remW) : 0;
    final srcHeight = params.srcHeight > 0
        ? math.min(params.srcHeight, remH)
        : 0;

    final (rawCellW, rawCellH) = cellPixelSize();
    final cellW = math.max(1, rawCellW);
    final cellH = math.max(1, rawCellH);
    final cellOffsetX = params.cellOffsetX.clamp(0, cellW - 1);
    final cellOffsetY = params.cellOffsetY.clamp(0, cellH - 1);

    final effW = srcWidth > 0 ? srcWidth : math.max(1, remW);
    final effH = srcHeight > 0 ? srcHeight : math.max(1, remH);
    final hasCrop = srcX > 0 || srcY > 0 || srcWidth > 0 || srcHeight > 0;
    final (cols, rows) = (reqCols != null || reqRows != null || hasCrop)
        ? _resolvePlacementGrid(reqCols, reqRows, effW, effH)
        : (data.gridCols, data.gridRows);

    return (
      placement: KittyPlacement(
        imageId: data.imageId,
        placementId: placementId,
        isVirtual: isVirtual,
        isAltScreen: currentAlt,
        gridCol: gridCol,
        gridRow: gridRow,
        cols: cols,
        rows: rows,
        srcX: srcX,
        srcY: srcY,
        srcWidth: srcWidth,
        srcHeight: srcHeight,
        cellOffsetX: cellOffsetX,
        cellOffsetY: cellOffsetY,
        zIndex: params.zIndex,
        parentImageId: params.parentImageId,
        parentPlacementId: params.parentPlacementId,
        relCols: params.relCols,
        relRows: params.relRows,
      ),
      error: null,
    );
  }

  void _applyPlacement(
    KittyPlacement placement, {
    required bool advanceCursor,
  }) {
    final existing = registry.lookupPlacement(
      placement.imageId,
      placement.placementId,
    );
    final hadDirectPlaceholder =
        existing != null &&
        !existing.isVirtual &&
        !existing.isRelative &&
        existing.zIndex == 0;
    final becomesNonPlaceholder =
        placement.isVirtual || placement.isRelative || placement.zIndex != 0;
    if (hadDirectPlaceholder && becomesNonPlaceholder) {
      onClearPlacements?.call(
        existing.imageId,
        placementId: existing.placementId,
        directOnly: true,
      );
    }
    registry.registerPlacement(placement);
    if (placement.isVirtual) return;
    if (placement.zIndex != 0 || placement.isRelative) {
      if (advanceCursor) {
        onAdvanceCursor?.call(placement.cols, placement.rows);
      }
      return;
    }
    onPlaceVirtual(
      placement.cols,
      placement.rows,
      placement.imageId,
      advanceCursor,
      placement.placementId,
    );
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
    if (_isOutOfRangeUint32(control['P']) ||
        _isOutOfRangeUint32(control['Q'])) {
      _replyError(replyPrefix, quiet, 'EINVAL:invalid parent id');
      return;
    }
    final data = imageId > 0 ? registry.lookupImage(imageId) : null;
    if (data == null) {
      _replyError(replyPrefix, quiet, 'ENOENT:image not found');
      return;
    }

    final isVirtual = (int.tryParse(control['U'] ?? '0') ?? 0) == 1;
    final advanceCursor = (int.tryParse(control['C'] ?? '0') ?? 0) != 1;
    final built = _validateAndBuildPlacement(
      data: data,
      placementId: placementId,
      isVirtual: isVirtual,
      advanceCursor: advanceCursor,
      reqCols: _parseOptionalPositiveInt(control['c']),
      reqRows: _parseOptionalPositiveInt(control['r']),
      params: _parsePlacementParams(control),
    );
    if (built.error != null) {
      _replyError(replyPrefix, quiet, built.error!);
      return;
    }
    final placement = built.placement!;
    if ((placement.cols != data.gridCols || placement.rows != data.gridRows) &&
        !_hasOtherPlacement(imageId, placementId, isVirtual)) {
      registry.registerImage(
        data.copyWith(gridCols: placement.cols, gridRows: placement.rows),
      );
    }
    _applyPlacement(placement, advanceCursor: advanceCursor);
    _replyOk(replyPrefix, quiet);
  }

  KittyAnimationFrame? _lookupAnimationFrame(int imageId, int frameNumber) {
    final anim = registry.lookupAnimation(imageId);
    if (anim != null) {
      final idx = anim.indexOfFrame(frameNumber);
      return idx >= 0 ? anim.frames[idx] : null;
    }
    if (frameNumber == 1) {
      final root = registry.lookupImage(imageId);
      if (root != null) {
        return KittyAnimationFrame(frameNumber: 1, imageData: root);
      }
    }
    return null;
  }

  int _resolveNextFrameNumber(int imageId) {
    final anim = registry.lookupAnimation(imageId);
    if (anim == null || anim.frames.isEmpty) return 2;
    return anim.frames.last.frameNumber + 1;
  }

  void _handleAnimationFrame(
    Map<String, String> control,
    String dataPart,
    int quiet,
  ) {
    final pending = _obtainPendingUpload('f', control, quiet);
    final chunk = _bufferUploadChunk(pending, control, dataPart, quiet);
    if (chunk.isMore) return;
    _finalizeAnimationFrame(pending, chunk.effectiveQuiet);
  }

  bool _exceedsAnimationBudget({
    required int imageId,
    required int targetNum,
    required int projectedBytes,
    required KittyAnimationFrame? existingTarget,
  }) {
    final anim = registry.lookupAnimation(imageId);
    if (existingTarget == null) {
      final currentFrames = anim != null ? anim.frames.length : 1;
      if (currentFrames >= KittyImageRegistry.maxFramesPerImage) {
        return true;
      }
    }
    final existingBytes = existingTarget == null
        ? 0
        : existingTarget.imageData.rgbaPixels.length;
    final byteDelta = projectedBytes - existingBytes;
    if (byteDelta > 0 &&
        registry.totalAnimationBytes + byteDelta >
            KittyImageRegistry.maxAnimationBytes) {
      return true;
    }
    return false;
  }

  KittyImageData? _decodeAndBuildAnimationFrame({
    required KittyImageData root,
    required KittyAnimationFrame? existingTarget,
    required KittyAnimationFrame? baseFrame,
    required _PendingUpload pending,
    required _FrameUploadParams params,
    required int targetNum,
  }) {
    final decoded = _decodeBase64Payload(pending.base64Data.toString());
    if (pending.medium == 'd') {
      final raw = pending.compressed ? _inflateZlibBytes(decoded) : decoded;
      return _buildAnimationFrameData(
        root: root,
        existingTarget: existingTarget,
        baseFrame: baseFrame,
        pending: pending,
        params: params,
        rawBytes: raw,
      );
    }
    if (pending.medium == 'f') {
      final payloadBytes = _readMediumBytes(
        pending.medium,
        decoded,
        dataOffset: pending.dataOffset,
        dataSize: pending.dataSize,
        unlink: false,
      );
      final raw = pending.compressed
          ? _inflateZlibBytes(payloadBytes)
          : payloadBytes;
      return _buildAnimationFrameData(
        root: root,
        existingTarget: existingTarget,
        baseFrame: baseFrame,
        pending: pending,
        params: params,
        rawBytes: raw,
      );
    }
    KittyImageData? built;
    _readMediumBytes(
      pending.medium,
      decoded,
      dataOffset: pending.dataOffset,
      dataSize: pending.dataSize,
      unlink: true,
      shouldUnlink: (payloadBytes) {
        final raw = pending.compressed
            ? _inflateZlibBytes(payloadBytes)
            : payloadBytes;
        final candidate = _buildAnimationFrameData(
          root: root,
          existingTarget: existingTarget,
          baseFrame: baseFrame,
          pending: pending,
          params: params,
          rawBytes: raw,
        );
        if (_exceedsAnimationBudget(
          imageId: pending.imageId,
          targetNum: targetNum,
          projectedBytes: candidate.rgbaPixels.length,
          existingTarget: existingTarget,
        )) {
          return false;
        }
        built = candidate;
        return true;
      },
    );
    return built;
  }

  static Uint8List _initFrameCanvas(
    KittyImageData root,
    KittyAnimationFrame? existingTarget,
    KittyAnimationFrame? baseFrame,
    int bgColor,
  ) {
    final template = baseFrame ?? existingTarget;
    if (template != null) {
      final data = template.imageData;
      if (data.format != KittyImageData.formatRgba32 ||
          data.rgbaPixels.length < root.pixelWidth * root.pixelHeight * 4) {
        throw const _InvalidPayloadException();
      }
      return Uint8List.fromList(
        data.rgbaPixels.sublist(0, root.pixelWidth * root.pixelHeight * 4),
      );
    }
    final canvas = Uint8List(root.pixelWidth * root.pixelHeight * 4);
    if (bgColor != 0) {
      final r = (bgColor >>> 24) & 0xFF;
      final g = (bgColor >>> 16) & 0xFF;
      final b = (bgColor >>> 8) & 0xFF;
      final a = bgColor & 0xFF;
      for (var i = 0; i < canvas.length; i += 4) {
        canvas[i] = r;
        canvas[i + 1] = g;
        canvas[i + 2] = b;
        canvas[i + 3] = a;
      }
    }
    return canvas;
  }

  static void _alphaBlendPixel(
    Uint8List src,
    int sOff,
    Uint8List dst,
    int dOff,
  ) {
    final sA = src[sOff + 3];
    if (sA == 0) return;
    if (sA == 255) {
      dst[dOff] = src[sOff];
      dst[dOff + 1] = src[sOff + 1];
      dst[dOff + 2] = src[sOff + 2];
      dst[dOff + 3] = 255;
      return;
    }
    final invA = 255 - sA;
    final effDstA = (dst[dOff + 3] * invA) ~/ 255;
    final outA = sA + effDstA;
    if (outA == 0) return;
    dst[dOff] = (src[sOff] * sA + dst[dOff] * effDstA) ~/ outA;
    dst[dOff + 1] = (src[sOff + 1] * sA + dst[dOff + 1] * effDstA) ~/ outA;
    dst[dOff + 2] = (src[sOff + 2] * sA + dst[dOff + 2] * effDstA) ~/ outA;
    dst[dOff + 3] = outA;
  }

  static void _blitFramePatch({
    required Uint8List canvas,
    required int canvasW,
    required int canvasH,
    required Uint8List patchRgba,
    required int patchW,
    required int patchH,
    required int dstX,
    required int dstY,
    required bool replace,
  }) {
    if (dstX < 0 || dstY < 0 || dstX >= canvasW || dstY >= canvasH) {
      throw const _InvalidPayloadException();
    }
    final copyW = math.min(patchW, canvasW - dstX);
    final copyH = math.min(patchH, canvasH - dstY);
    for (var row = 0; row < copyH; row++) {
      var sOff = row * patchW * 4;
      var dOff = ((dstY + row) * canvasW + dstX) * 4;
      for (var col = 0; col < copyW; col++, sOff += 4, dOff += 4) {
        if (replace) {
          canvas[dOff] = patchRgba[sOff];
          canvas[dOff + 1] = patchRgba[sOff + 1];
          canvas[dOff + 2] = patchRgba[sOff + 2];
          canvas[dOff + 3] = patchRgba[sOff + 3];
        } else {
          _alphaBlendPixel(patchRgba, sOff, canvas, dOff);
        }
      }
    }
  }

  KittyImageData _buildPngAnimationFrame(
    KittyImageData root,
    _PendingUpload pending,
    Uint8List rawBytes,
  ) {
    final (ihdrW, ihdrH) = _extractPngDimensions(rawBytes);
    if (!_isValidDimensions(ihdrW, ihdrH) ||
        ihdrW != root.pixelWidth ||
        ihdrH != root.pixelHeight) {
      throw const _InvalidPayloadException();
    }
    if ((pending.width > 0 && pending.width != ihdrW) ||
        (pending.height > 0 && pending.height != ihdrH)) {
      throw const _InvalidPayloadException();
    }
    return KittyImageData.fromPng(
      imageId: root.imageId,
      pixelWidth: ihdrW,
      pixelHeight: ihdrH,
      pngBytes: rawBytes,
      gridCols: root.gridCols,
      gridRows: root.gridRows,
      version: ++_frameVersionCounter,
    );
  }

  static Uint8List _decodeFramePatchRgba(
    int format,
    Uint8List rawBytes,
    int patchW,
    int patchH,
  ) {
    if (!_isValidDimensions(patchW, patchH)) {
      throw const _InvalidPayloadException();
    }
    if (format == KittyImageData.formatRgb24) {
      if (rawBytes.length < patchW * patchH * 3) {
        throw const _InvalidPayloadException();
      }
      return _convertRgb24ToRgba32(rawBytes, patchW * patchH);
    }
    if (format == KittyImageData.formatRgba32) {
      if (rawBytes.length < patchW * patchH * 4) {
        throw const _InvalidPayloadException();
      }
      return rawBytes;
    }
    throw const _InvalidPayloadException();
  }

  KittyImageData _buildAnimationFrameData({
    required KittyImageData root,
    required KittyAnimationFrame? existingTarget,
    required KittyAnimationFrame? baseFrame,
    required _PendingUpload pending,
    required _FrameUploadParams params,
    required Uint8List rawBytes,
  }) {
    final isFullPngFrame =
        pending.format == KittyImageData.formatPng &&
        rawBytes.isNotEmpty &&
        baseFrame == null &&
        (existingTarget == null || params.replace) &&
        params.dstX == 0 &&
        params.dstY == 0;
    if (isFullPngFrame) {
      return _buildPngAnimationFrame(root, pending, rawBytes);
    }

    final canvas = _initFrameCanvas(
      root,
      existingTarget,
      baseFrame,
      params.bgColor,
    );
    if (rawBytes.isNotEmpty) {
      final patchW = pending.width > 0 ? pending.width : root.pixelWidth;
      final patchH = pending.height > 0 ? pending.height : root.pixelHeight;
      final patchRgba = _decodeFramePatchRgba(
        pending.format,
        rawBytes,
        patchW,
        patchH,
      );
      _blitFramePatch(
        canvas: canvas,
        canvasW: root.pixelWidth,
        canvasH: root.pixelHeight,
        patchRgba: patchRgba,
        patchW: patchW,
        patchH: patchH,
        dstX: params.dstX,
        dstY: params.dstY,
        replace: params.replace,
      );
    }
    return KittyImageData(
      imageId: root.imageId,
      pixelWidth: root.pixelWidth,
      pixelHeight: root.pixelHeight,
      rgbaPixels: canvas,
      gridCols: root.gridCols,
      gridRows: root.gridRows,
      version: ++_frameVersionCounter,
      format: KittyImageData.formatRgba32,
    );
  }

  void _finalizeAnimationFrame(_PendingUpload pending, int quiet) {
    if (pending.validationError != null) {
      _replyError(pending.replyPrefix, quiet, pending.validationError!);
      return;
    }
    if (pending.overflowed) {
      _replyError(pending.replyPrefix, quiet, 'EFBIG:payload too large');
      return;
    }
    final root = registry.lookupImage(pending.imageId);
    if (root == null) {
      _replyError(pending.replyPrefix, quiet, 'ENOENT:image not found');
      return;
    }
    final params =
        pending.frameParams ??
        const _FrameUploadParams(
          targetFrame: 0,
          baseFrame: 0,
          dstX: 0,
          dstY: 0,
          replace: false,
          bgColor: 0,
          gapMs: null,
        );
    final baseFrame = params.baseFrame > 0
        ? _lookupAnimationFrame(pending.imageId, params.baseFrame)
        : null;
    if (params.baseFrame > 0 && baseFrame == null) {
      _replyError(pending.replyPrefix, quiet, 'ENOENT:base frame not found');
      return;
    }
    final targetNum = params.targetFrame > 0
        ? params.targetFrame
        : _resolveNextFrameNumber(pending.imageId);
    final existingTarget = _lookupAnimationFrame(pending.imageId, targetNum);
    final precheckBytes = pending.format == 100
        ? 0
        : root.pixelWidth * root.pixelHeight * 4;
    if (_exceedsAnimationBudget(
      imageId: pending.imageId,
      targetNum: targetNum,
      projectedBytes: precheckBytes,
      existingTarget: existingTarget,
    )) {
      _replyError(
        pending.replyPrefix,
        quiet,
        'EFBIG:animation frame limit exceeded',
      );
      return;
    }

    try {
      final frameData = _decodeAndBuildAnimationFrame(
        root: root,
        existingTarget: existingTarget,
        baseFrame: baseFrame,
        pending: pending,
        params: params,
        targetNum: targetNum,
      );
      if (frameData == null) {
        _replyError(
          pending.replyPrefix,
          quiet,
          'EFBIG:animation frame limit exceeded',
        );
        return;
      }
      final frame = KittyAnimationFrame(
        frameNumber: targetNum,
        imageData: frameData,
        gapMs: params.gapMs ?? existingTarget?.gapMs ?? 0,
      );
      if (!registry.registerAnimationFrame(pending.imageId, frame)) {
        _replyError(
          pending.replyPrefix,
          quiet,
          'EFBIG:animation frame limit exceeded',
        );
        return;
      }
      final okPrefix = pending.replyPrefix != null
          ? '${pending.replyPrefix},r=$targetNum'
          : null;
      _replyOk(okPrefix, quiet);
    } on Exception catch (e) {
      _replyPayloadError(pending.replyPrefix, quiet, e);
    }
  }

  static ({KittyAnimationPlayback? playback, String? error})
  _parseAnimationState(String? raw) => switch (raw) {
    null || '0' => (playback: null, error: null),
    '1' => (playback: KittyAnimationPlayback.stopped, error: null),
    '2' => (playback: KittyAnimationPlayback.loading, error: null),
    '3' => (playback: KittyAnimationPlayback.running, error: null),
    _ => (playback: null, error: 'EINVAL:invalid animation state'),
  };

  static ({int? loopCount, String? error}) _parseAnimationLoops(String? raw) {
    if (raw == null) return (loopCount: null, error: null);
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 0) {
      return (loopCount: null, error: 'EINVAL:invalid loop count');
    }
    if (parsed == 0) return (loopCount: null, error: null);
    return (loopCount: parsed - 1, error: null);
  }

  String? _validateControlFrameRefs(
    int imageId,
    int? currentFrameNumber,
    int? frameGapNumber,
  ) {
    if (currentFrameNumber != null &&
        _lookupAnimationFrame(imageId, currentFrameNumber) == null) {
      return 'ENOENT:frame not found';
    }
    if (frameGapNumber != null &&
        _lookupAnimationFrame(imageId, frameGapNumber) == null) {
      return 'ENOENT:frame not found';
    }
    return null;
  }

  void _handleAnimationControl(Map<String, String> control, int quiet) {
    final explicitId = _parsePositiveId(control['i']);
    final explicitNumber = _parsePositiveId(control['I']);
    if (explicitId > 0 && explicitNumber > 0) {
      _replyError(
        _resolveReplyPrefix(explicitId, 0),
        quiet,
        'EINVAL:cannot specify both i and I',
      );
      return;
    }
    final imageId = _resolveTargetImageId(explicitId, explicitNumber);
    final replyPrefix = _resolveReplyPrefix(imageId, explicitNumber);
    if (imageId <= 0 || registry.lookupImage(imageId) == null) {
      _replyError(replyPrefix, quiet, 'ENOENT:image not found');
      return;
    }
    final stateResult = _parseAnimationState(control['s']);
    if (stateResult.error != null) {
      _replyError(replyPrefix, quiet, stateResult.error!);
      return;
    }
    final loopResult = _parseAnimationLoops(control['v']);
    if (loopResult.error != null) {
      _replyError(replyPrefix, quiet, loopResult.error!);
      return;
    }
    final frameGapMs = control.containsKey('z')
        ? _parseSignedInt32(control['z'])
        : null;
    final frameGapNumber =
        _parseOptionalPositiveInt(control['r']) ??
        (frameGapMs != null ? 1 : null);
    final currentFrameNumber = _parseOptionalPositiveInt(control['c']);
    final frameErr = _validateControlFrameRefs(
      imageId,
      currentFrameNumber,
      frameGapNumber,
    );
    if (frameErr != null) {
      _replyError(replyPrefix, quiet, frameErr);
      return;
    }
    registry.setAnimationPlayback(
      imageId,
      playback: stateResult.playback,
      loopCount: loopResult.loopCount,
      currentFrameNumber: currentFrameNumber,
      frameGapNumber: frameGapNumber,
      frameGapMs: frameGapMs,
    );
    _replyOk(replyPrefix, quiet);
  }

  static bool _isValidRgbaFrameData(KittyImageData data) =>
      data.format == KittyImageData.formatRgba32 &&
      data.pixelWidth > 0 &&
      data.pixelHeight > 0 &&
      data.rgbaPixels.length >= data.pixelWidth * data.pixelHeight * 4;

  static ({
    int srcX,
    int srcY,
    int dstX,
    int dstY,
    int? width,
    int? height,
    bool replace,
    String? error,
  })
  _validateComposeParams(
    Map<String, String> control,
    KittyImageData srcData,
    KittyImageData dstData,
  ) {
    final compRaw = control['C'];
    if (compRaw != null && compRaw != '0' && compRaw != '1') {
      return (
        srcX: 0,
        srcY: 0,
        dstX: 0,
        dstY: 0,
        width: null,
        height: null,
        replace: false,
        error: 'EINVAL:invalid composition mode',
      );
    }
    if (_isNegativeInt(control['x']) ||
        _isNegativeInt(control['y']) ||
        _isNegativeInt(control['X']) ||
        _isNegativeInt(control['Y']) ||
        _isNegativeInt(control['w']) ||
        _isNegativeInt(control['h'])) {
      return (
        srcX: 0,
        srcY: 0,
        dstX: 0,
        dstY: 0,
        width: null,
        height: null,
        replace: false,
        error: 'EINVAL:invalid composition geometry',
      );
    }
    final srcX = _parseNonNegativeInt(control['X']);
    final srcY = _parseNonNegativeInt(control['Y']);
    final dstX = _parseNonNegativeInt(control['x']);
    final dstY = _parseNonNegativeInt(control['y']);
    final width = _parseOptionalPositiveInt(control['w']);
    final height = _parseOptionalPositiveInt(control['h']);
    final copyW = math.min(
      width ?? srcData.pixelWidth,
      math.min(srcData.pixelWidth - srcX, dstData.pixelWidth - dstX),
    );
    final copyH = math.min(
      height ?? srcData.pixelHeight,
      math.min(srcData.pixelHeight - srcY, dstData.pixelHeight - dstY),
    );
    if (!_isValidRgbaFrameData(srcData) ||
        !_isValidRgbaFrameData(dstData) ||
        copyW <= 0 ||
        copyH <= 0) {
      return (
        srcX: 0,
        srcY: 0,
        dstX: 0,
        dstY: 0,
        width: null,
        height: null,
        replace: false,
        error: 'EINVAL:invalid composition geometry',
      );
    }
    return (
      srcX: srcX,
      srcY: srcY,
      dstX: dstX,
      dstY: dstY,
      width: width,
      height: height,
      replace: compRaw == '1',
      error: null,
    );
  }

  void _handleAnimationCompose(Map<String, String> control, int quiet) {
    final explicitId = _parsePositiveId(control['i']);
    final explicitNumber = _parsePositiveId(control['I']);
    if (explicitId > 0 && explicitNumber > 0) {
      _replyError(
        _resolveReplyPrefix(explicitId, 0),
        quiet,
        'EINVAL:cannot specify both i and I',
      );
      return;
    }
    final imageId = _resolveTargetImageId(explicitId, explicitNumber);
    final replyPrefix = _resolveReplyPrefix(imageId, explicitNumber);
    if (imageId <= 0 || registry.lookupImage(imageId) == null) {
      _replyError(replyPrefix, quiet, 'ENOENT:image not found');
      return;
    }
    final srcFrameNum = _parsePositiveId(control['r']);
    final dstFrameNum = _parsePositiveId(control['c']);
    if (srcFrameNum == 0 || dstFrameNum == 0) {
      _replyError(replyPrefix, quiet, 'EINVAL:invalid frame number');
      return;
    }
    final srcFrame = _lookupAnimationFrame(imageId, srcFrameNum);
    final dstFrame = _lookupAnimationFrame(imageId, dstFrameNum);
    if (srcFrame == null || dstFrame == null) {
      _replyError(replyPrefix, quiet, 'ENOENT:frame not found');
      return;
    }
    final validated = _validateComposeParams(
      control,
      srcFrame.imageData,
      dstFrame.imageData,
    );
    if (validated.error != null) {
      _replyError(replyPrefix, quiet, validated.error!);
      return;
    }
    final ok = registry.composeAnimationFrame(
      imageId,
      sourceFrameNumber: srcFrameNum,
      destFrameNumber: dstFrameNum,
      srcX: validated.srcX,
      srcY: validated.srcY,
      dstX: validated.dstX,
      dstY: validated.dstY,
      width: validated.width,
      height: validated.height,
      replace: validated.replace,
    );
    if (!ok) {
      _replyError(replyPrefix, quiet, 'EFBIG:animation frame limit exceeded');
      return;
    }
    _replyOk(replyPrefix, quiet);
  }
}
