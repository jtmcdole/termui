import 'dart:convert';
import 'dart:typed_data';

import 'package:termui/termui.dart';

import 'zlib_decoder_stub.dart' if (dart.library.io) 'zlib_decoder_io.dart';

final class _PayloadTooLargeException implements Exception {
  const _PayloadTooLargeException();
}

final class _InvalidPayloadException implements Exception {
  const _InvalidPayloadException();
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
  final String action;
  final int format;
  final int width;
  final int height;
  final int? cols;
  final int? rows;
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
    required this.action,
    required this.format,
    required this.width,
    required this.height,
    required this.cols,
    required this.rows,
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
  static const int _maxDimension = 4096;
  static const int _maxTotalPixels = 4_194_304;
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
  final void Function(int cols, int rows, int imageId, bool advanceCursor)
  onPlaceVirtual;

  /// Callback returning the live terminal cell dimensions in pixels `(width, height)`.
  final (int width, int height) Function() cellPixelSize;

  final Map<int, _PendingUpload> _pendingUploads = {};
  int _totalPendingBase64 = 0;
  int? _lastActiveUploadId;
  int _nextAutoId = 0x80000001;

  /// Creates a [KittyApcHandler] bound to a scoped [registry].
  KittyApcHandler({
    required this.registry,
    required this.onReply,
    required this.onPlaceVirtual,
    required this.cellPixelSize,
  });

  /// Clears all pending chunked uploads and wipes [registry].
  void reset() {
    _pendingUploads.clear();
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
    final pendingContinuation =
        !control.containsKey('a') && !_hasNewUploadMetadata(control)
        ? _resolveActiveContinuation(control)
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

  static int _parsePositiveId(String? raw) {
    final parsed = int.tryParse(raw ?? '');
    if (parsed == null || parsed <= 0) return 0;
    return parsed & 0xFFFFFFFF;
  }

  static String? _resolveReplyPrefix(int explicitId, int explicitNumber) {
    if (explicitId > 0) return 'i=$explicitId';
    if (explicitNumber > 0) return 'I=$explicitNumber';
    return null;
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

  static bool _isDirectMedium(Map<String, String> control) =>
      switch (control['t']) {
        null || 'd' => true,
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

  static String? _resolveValidationError(
    Map<String, String> control,
    int format,
  ) {
    if (!_isDirectMedium(control)) {
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
      control.containsKey('c') ||
      control.containsKey('r') ||
      control.containsKey('U') ||
      control.containsKey('p');

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
      final replyPrefix = _resolveReplyPrefix(explicitId, explicitNumber);
      final format = _parseFormat(control);
      final validationError = _resolveValidationError(control, format);
      if (validationError != null) {
        _replyError(replyPrefix, quiet, validationError);
        return;
      }
      _verifyQueryBytes(
        replyPrefix,
        quiet,
        dataPart,
        compressed: control['o'] == 'z',
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
      compressed: pending.compressed,
    );
  }

  void _verifyQueryBytes(
    String? replyPrefix,
    int quiet,
    String base64Payload, {
    required bool compressed,
  }) {
    try {
      final decoded = _decodeBase64Payload(base64Payload);
      if (compressed && decoded.isNotEmpty) {
        _validateZlibBytes(decoded);
      }
      _replyOk(replyPrefix, quiet);
    } on _PayloadTooLargeException {
      _replyError(replyPrefix, quiet, 'EFBIG:payload too large');
    } on Object {
      _replyError(replyPrefix, quiet, 'EINVAL:invalid payload');
    }
  }

  void _handleDelete(Map<String, String> control) {
    final deleteTarget = control['d'] ?? 'a';
    final imageId = _parsePositiveId(control['i']);
    if (deleteTarget == 'a' || deleteTarget == 'A') {
      reset();
      return;
    }
    if (imageId > 0) {
      registry.unregisterImage(imageId);
      _removePendingUpload(imageId);
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

  static bool _canContinueExisting(
    _PendingUpload? existing,
    String action,
    Map<String, String> control,
    int explicitId,
  ) {
    if (existing == null || _hasNewUploadMetadata(control)) return false;
    final hasExplicitAction = control.containsKey('a');
    if (explicitId > 0) {
      return explicitId == existing.imageId &&
          existing.hasAddressableId &&
          (!hasExplicitAction || existing.action == action);
    }
    final explicitNumber = _parsePositiveId(control['I']);
    if (explicitNumber > 0 && existing.replyPrefix != 'I=$explicitNumber') {
      return false;
    }
    return !hasExplicitAction || existing.action == action;
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
    final hasAddressableId = explicitId > 0;
    final imageId = hasAddressableId ? explicitId : _allocateAutoId();
    _removePendingUpload(imageId);
    _evictOldestUploadIfNeeded();

    final format = _parseFormat(control);
    final parsedCols = int.tryParse(control['c'] ?? '');
    final parsedRows = int.tryParse(control['r'] ?? '');
    final created = _PendingUpload(
      imageId: imageId,
      action: action,
      format: format,
      width: int.tryParse(control['s'] ?? '0') ?? 0,
      height: int.tryParse(control['v'] ?? '0') ?? 0,
      cols: (parsedCols != null && parsedCols > 0) ? parsedCols : null,
      rows: (parsedRows != null && parsedRows > 0) ? parsedRows : null,
      compressed: control['o'] == 'z',
      quiet: quiet,
      advanceCursor: (int.tryParse(control['C'] ?? '0') ?? 0) != 1,
      virtual: (int.tryParse(control['U'] ?? '0') ?? 0) == 1,
      placementId: int.tryParse(control['p'] ?? '0') ?? 0,
      hasAddressableId: hasAddressableId,
      replyPrefix: _resolveReplyPrefix(explicitId, explicitNumber),
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
      if (pending.action == 'T' && !pending.virtual) {
        onPlaceVirtual(
          imageData.gridCols,
          imageData.gridRows,
          pending.imageId,
          pending.advanceCursor,
        );
      }
      _replyOk(pending.replyPrefix, quiet);
    } on _PayloadTooLargeException {
      _replyError(pending.replyPrefix, quiet, 'EFBIG:payload too large');
    } on Object {
      _replyError(pending.replyPrefix, quiet, 'EINVAL:invalid payload');
    }
  }

  static Uint8List _decodePayloadBytes(_PendingUpload pending) {
    final decoded = _decodeBase64Payload(pending.base64Data.toString());
    return pending.compressed ? _inflateZlibBytes(decoded) : decoded;
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

  (int cols, int rows) _resolveUploadGrid(
    _PendingUpload pending,
    int pixelWidth,
    int pixelHeight,
  ) {
    final (cellW, cellH) = cellPixelSize();
    final maxSpan = kittyDiacritics.length;
    return (
      (pending.cols ?? ((pixelWidth + cellW - 1) ~/ cellW)).clamp(1, maxSpan),
      (pending.rows ?? ((pixelHeight + cellH - 1) ~/ cellH)).clamp(1, maxSpan),
    );
  }

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

  void _handlePlace(Map<String, String> control, int quiet) {
    final imageId = _parsePositiveId(control['i']);
    final replyPrefix = _resolveReplyPrefix(
      imageId,
      _parsePositiveId(control['I']),
    );
    final data = registry.lookupImage(imageId);
    if (data == null) {
      _replyError(replyPrefix, quiet, 'ENOENT:image not found');
      return;
    }

    final parsedCols = int.tryParse(control['c'] ?? '');
    final parsedRows = int.tryParse(control['r'] ?? '');
    final cols = (parsedCols != null && parsedCols > 0)
        ? parsedCols
        : data.gridCols;
    final rows = (parsedRows != null && parsedRows > 0)
        ? parsedRows
        : data.gridRows;
    final isVirtual = (int.tryParse(control['U'] ?? '0') ?? 0) == 1;
    if (isVirtual) {
      if (cols != data.gridCols || rows != data.gridRows) {
        registry.registerImage(
          data.copyWith(
            gridCols: cols,
            gridRows: rows,
            version: data.version + 1,
          ),
        );
      }
      _replyOk(replyPrefix, quiet);
      return;
    }

    final advanceCursor = (int.tryParse(control['C'] ?? '0') ?? 0) != 1;
    onPlaceVirtual(cols, rows, imageId, advanceCursor);
    _replyOk(replyPrefix, quiet);
  }
}
