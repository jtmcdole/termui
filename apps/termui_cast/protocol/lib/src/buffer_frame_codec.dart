import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:characters/characters.dart';
import 'package:termui/termui.dart';

import 'deflate_raw.dart';
import 'messages.dart';
import 'models.dart';

/// Exception thrown when a binary cast wire frame violates bounds or format invariants.
base class ProtocolFormatException extends FormatException {
  /// Creates a protocol format exception with diagnostic [message].
  const ProtocolFormatException(super.message);
}

/// Exception thrown when a `0x09`, `0x0A`, or `0x11` frame header and [sessionId]
/// are valid, but its variable tail or compressed body fails to inflate or decode.
final class CorruptSessionFrameException extends ProtocolFormatException {
  /// Session whose frame tail failed to inflate or decode.
  final SessionId sessionId;

  /// Creates a per-session corrupt frame exception for [sessionId].
  const CorruptSessionFrameException(this.sessionId, super.message);
}

/// Exception thrown when an inbound `0x19` (`AudioFrame`) header and [sessionId]
/// are valid, but its compressed tail or audio payload fails validation or inflation.
final class CorruptAudioFrameException extends ProtocolFormatException {
  /// Session whose audio frame payload was corrupt or oversized.
  final SessionId sessionId;

  /// Creates a per-session corrupt audio frame exception for [sessionId].
  const CorruptAudioFrameException(this.sessionId, super.message);
}

final int _traceEncodeId = Tracer.registerString('BufferFrameCodec.encode');
final int _traceDecodeId = Tracer.registerString('BufferFrameCodec.decode');
final int _traceApplyDeltaId = Tracer.registerString(
  'BufferFrameCodec.applyDelta',
);

T _traceCodecSpan<T>(int traceId, T Function() body) {
  if (!Tracer.isEnabled) return body();
  Tracer.record(traceId, Phase.begin, .compositor);
  try {
    return body();
  } finally {
    Tracer.record(traceId, Phase.end, .compositor);
  }
}

const int _compressionRaw = 0x00;
const int _compressionDeflateRaw = 0x01;

const int _tagAuth = 0x01;
const int _tagAuthAccepted = 0x02;
const int _tagRegisterSession = 0x03;
const int _tagSessionDirectory = 0x04;
const int _tagSubscribeSession = 0x05;
const int _tagUnsubscribeSession = 0x06;
const int _tagSubscriberCount = 0x07;
const int _tagRequestKeyframe = 0x08;
const int _tagBufferSnapshot = 0x09;
const int _tagBufferDelta = 0x0A;
const int _tagInput = 0x0B;
const int _tagResize = 0x0C;
const int _tagSessionClosed = 0x0D;
const int _tagError = 0x0E;
const int _tagClipboard = 0x0F;
const int _tagRequestScrollback = 0x10;
const int _tagScrollbackChunk = 0x11;
const int _tagFileUploadStart = 0x12;
const int _tagFileUploadChunk = 0x13;
const int _tagFileUploadEnd = 0x14;
const int _tagFileUploadAck = 0x15;
const int _tagRenameSession = 0x16;
const int _tagShellTitle = 0x17;
const int _tagBell = 0x18;
const int _tagAudio = 0x19;
const int _tagAudioWaveformReply = 0x1A;
const int _tagKittyImageChunk = 0x1B;
const int _tagShader = 0x1C;
const int _tagSpawnSession = 0x1D;

const int _capFlagShaderFrames = 0x01;
const int _registerFlagAllowSpawn = 0x01;

const int _shaderKindDefine = 0;
const int _shaderKindRegion = 1;
const int _shaderKindTransforms = 2;
const int _shaderKindSet = 3;
const int _shaderKindUniform = 4;
const int _shaderKindReset = 5;

const int _maxShaderIdBytes = 64;
const int _maxShaderRectsPerRegion = 32;
const Set<String> _validShaderStages = {'bg', 'fg', 'post'};
const Set<String> _validShaderResetTargets = {
  'all',
  'regions',
  'xforms',
  'pane',
};
final RegExp _shaderIdPattern = RegExp(r'^[A-Za-z0-9_.-]{1,64}$');

const int _renameFlagClearPin = 0x01;
const int _summaryFlagUserPinned = 0x01;
const int _summaryFlagAllowSpawn = 0x02;
const int _summaryFlagsMask = _summaryFlagUserPinned | _summaryFlagAllowSpawn;

const int _audioKindTone = 0;
const int _audioKindClip = 1;
const int _audioKindStop = 2;
const int _audioKindUpdate = 3;
const int _audioKindBus = 4;
const int _audioKindStream = 5;
const int _audioKindWaveQuery = 6;
const int _streamOpOpen = 0;
const int _streamOpChunk = 1;
const int _streamOpEnd = 2;
const int _maxStreamBufferingMicros = 60_000_000;
const int _maxStreamSampleRate = 384000;
const int _busOpCreate = 0;
const int _busOpDestroy = 1;
const int _busOpVol = 2;
const int _busOpAttach = 3;
const int _busOpParam = 4;
const int _busOpFade = 5;
const int _maxAudioFilterId = 11;
const int _maxAudioParamId = 66;
const int _audioUpdateFlagVolume = 0x0001;
const int _audioUpdateFlagPan = 0x0002;
const int _audioUpdateFlagSeek = 0x0004;
const int _audioUpdateFlagPaused = 0x0008;
const int _audioUpdateFlagSpeed = 0x0010;
const int _audioUpdateFlagPreservePitch = 0x0020;
const int _audioUpdateFlagFadeVolume = 0x0040;
const int _audioUpdateFlagFadeSpeed = 0x0080;
const int _audioUpdateFlagScheduleStop = 0x0100;
const int _audioUpdateFlagsMask = 0x01FF;
const int _maxAudioSeekMicros = 86_400_000_000;
const double _minAudioSpeed = 0.125;
const double _maxAudioSpeed = 8.0;
const int _maxAudioWaveformBytes = 32;
const int _maxAudioFormatBytes = 16;
const int _audioTailHeaderOverhead = 128;
const int _maxAudioTailBytes =
    CastAudioPayload.maxClipBytes + _audioTailHeaderOverhead;
const Set<String> _validAudioWaveforms = {
  'sine',
  'square',
  'saw',
  'triangle',
  'bounce',
  'jaws',
  'humps',
  'fsquare',
  'fsaw',
};
const Set<String> _validAudioFormats = {'wav', 'ogg', 'mp3'};

const int _maxSessionIdBytes = 128;
const int _maxErrorCodeBytes = 256;
const int _maxTitleBytes = 512;
const int _maxTokenOrErrorBytes = 4096;
const int _maxClipboardBytes = 1_048_576;
const int _maxKittyImagesPerFrame = 1024;
const int _maxKittyImageDimension = 8192;
const int _maxKittyImageTotalPixels = 16_777_216;
const int _maxKittyImageGridSpan = 512;
const int _maxKittyChunkCount = 256;
const int _minPngBytes = 24;
const int _auxFlagUnderlineColors = 0x01;
const int _auxFlagUriRuns = 0x02;

final RegExp _disallowedTitleChars = RegExp(
  r'[\x00-\x1F\x7F-\x9F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]',
);

final List<String> _asciiTable = List<String>.generate(
  128,
  String.fromCharCode,
  growable: false,
);

/// Header summary extracted from a raw binary snapshot or delta frame on the relay fast path.
typedef RelayBufferFrameInfo = ({bool isSnapshot, int seq, int cols, int rows});

/// Maximum user-perceived grapheme cluster count accepted when naming or renaming a tab.
const int maxSessionTitleGraphemes = 64;

/// Validation result returned by [validateSessionTitle].
typedef SessionTitleValidation = ({String? title, String? error});

/// Trims and validates a user-supplied session [input] against UI grapheme and wire bounds.
SessionTitleValidation validateSessionTitle(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    return (title: null, error: 'Tab name cannot be empty.');
  }
  if (_disallowedTitleChars.hasMatch(trimmed)) {
    return (
      title: null,
      error: 'Tab name contains unsupported control characters.',
    );
  }
  if (trimmed.characters.length > maxSessionTitleGraphemes) {
    return (
      title: null,
      error: 'Tab name must be $maxSessionTitleGraphemes characters or fewer.',
    );
  }
  if (utf8.encode(trimmed).length > BufferFrameCodec.maxTitleBytes) {
    return (
      title: null,
      error: 'Tab name exceeds ${BufferFrameCodec.maxTitleBytes} UTF-8 bytes.',
    );
  }
  return (title: trimmed, error: null);
}

/// Binary wire codec for [CastMessage] frames and 1D [Buffer] delta application.
abstract final class BufferFrameCodec {
  /// Current binary wire protocol version byte.
  static const int protocolVersion = 8;

  /// Maximum uncompressed/compressed audio clip payload size (`2 MiB`).
  static const int maxAudioPayloadBytes = CastAudioPayload.maxClipBytes;

  /// Minimum uncompressed tail byte length before `deflate-raw` compression is attempted.
  static const int minCompressTailBytes = 512;

  /// Maximum allowed UTF-8 byte length for a session title.
  static const int maxTitleBytes = _maxTitleBytes;

  /// Maximum decoded or wire byte size for a single chunked Kitty image (`16 MiB`).
  static const int maxKittyImageBytes = 16 * 1024 * 1024;

  /// Maximum wire payload bytes per [KittyImageChunkFrame] (`512 KiB`).
  static const int maxKittyChunkBytes = 524_288;

  /// Maximum total wire frame bytes permitted for a `0x1C` [ShaderFrame] (`64 KiB`).
  static const int maxShaderFrameBytes = CastShaderPayload.maxWireBytes;

  /// Compresses raw Kitty image bytes with `deflate-raw` level 1.
  static Uint8List compressKittyBytes(Uint8List rawBytes) =>
      compressDeflateRawLevel1(rawBytes);

  /// Inflates a `deflate-raw` Kitty image buffer strictly bounded to [expectedBytes].
  static Uint8List inflateKittyBytes(
    Uint8List compressed, {
    required int expectedBytes,
  }) {
    if (expectedBytes <= 0 || expectedBytes > maxKittyImageBytes) {
      throw ProtocolFormatException(
        'Invalid expected Kitty inflated length: $expectedBytes',
      );
    }
    final Uint8List inflated;
    try {
      inflated = const ZLibDecoder().decodeBytes(
        compressed,
        raw: true,
        throwOnError: true,
        maxOutputSize: expectedBytes,
      );
    } on Object catch (e) {
      throw ProtocolFormatException('Failed to inflate Kitty image: $e');
    }
    if (inflated.length != expectedBytes) {
      throw ProtocolFormatException(
        'Inflated Kitty length ${inflated.length} != expected $expectedBytes',
      );
    }
    return inflated;
  }

  /// Validates that [bytes] has a valid PNG signature and matching `IHDR` dimensions.
  static void validateKittyPngHeader(
    Uint8List bytes,
    int expectedWidth,
    int expectedHeight,
  ) => _validatePngIhdrSlice(
    bytes,
    0,
    bytes.length,
    expectedWidth,
    expectedHeight,
  );

  /// Validates that [title] is trimmed, non-empty, `<= 512` UTF-8 bytes, and free of control or bidi override characters.
  static void validateTitle(String title) {
    _encodeValidatedTitle(title);
  }

  /// Maximum allowed binary WebSocket payload size (`4 MiB`).
  static const int maxFrameBytes = 4_194_304;

  /// Maximum allowed client input payload size (`64 KiB`).
  static const int maxInputBytes = 64 * 1024;

  /// Maximum allowed terminal grid width in columns.
  static const int maxGridCols = 400;

  /// Maximum allowed terminal grid height in rows.
  static const int maxGridRows = 200;

  /// Maximum allowed scrollback rows per [ScrollbackChunkFrame].
  static const int maxScrollbackChunkRows = ScrollbackChunkFrame.maxChunkRows;

  /// Encodes [message] into a discrete binary WebSocket frame.
  static Uint8List encode(CastMessage message) =>
      _traceCodecSpan(_traceEncodeId, () => _encodeImpl(message));

  static Uint8List _encodeImpl(CastMessage message) {
    final writer = _FrameWriter()..writeUint8(protocolVersion);
    switch (message) {
      case AuthFrame(:final role, :final token):
        writer
          ..writeUint8(_tagAuth)
          ..writeUint8(_encodeRole(role))
          ..writeString16(token, maxBytes: _maxTokenOrErrorBytes);
      case AuthAcceptedFrame(:final role, :final shaderFrames):
        writer
          ..writeUint8(_tagAuthAccepted)
          ..writeUint8(_encodeRole(role));
        if (shaderFrames) {
          writer.writeUint8(_capFlagShaderFrames);
        }
      case RegisterSessionFrame frame:
        _encodeRegister(writer, frame);
      case SessionDirectoryFrame(:final sessions):
        _encodeDirectory(writer, sessions);
      case SubscribeSessionFrame(
        :final sessionId,
        :final cols,
        :final rows,
        :final shaderFrames,
      ):
        if (cols != 0 || rows != 0) _checkGridDims(cols, rows);
        writer
          ..writeUint8(_tagSubscribeSession)
          ..writeSessionId(sessionId)
          ..writeUint16(cols)
          ..writeUint16(rows);
        if (shaderFrames) {
          writer.writeUint8(_capFlagShaderFrames);
        }
      case UnsubscribeSessionFrame(:final sessionId):
        writer
          ..writeUint8(_tagUnsubscribeSession)
          ..writeSessionId(sessionId);
      case SubscriberCountFrame(:final sessionId, :final subscriberCount):
        writer
          ..writeUint8(_tagSubscriberCount)
          ..writeSessionId(sessionId)
          ..writeUint32(subscriberCount);
      case RequestKeyframeFrame(:final sessionId):
        writer
          ..writeUint8(_tagRequestKeyframe)
          ..writeSessionId(sessionId);
      case BufferSnapshotFrame(:final snapshot):
        _encodeSnapshot(writer, snapshot);
      case BufferDeltaFrame(:final delta):
        _encodeDelta(writer, delta);
      case InputFrame(:final sessionId, :final data):
        if (data.length > maxInputBytes) {
          throw ProtocolFormatException(
            'InputFrame payload exceeds $maxInputBytes bytes: ${data.length}',
          );
        }
        writer
          ..writeUint8(_tagInput)
          ..writeSessionId(sessionId)
          ..writeBytes32(data);
      case ResizeFrame(:final sessionId, :final cols, :final rows):
        _checkGridDims(cols, rows);
        writer
          ..writeUint8(_tagResize)
          ..writeSessionId(sessionId)
          ..writeUint16(cols)
          ..writeUint16(rows);
      case SessionClosedFrame(:final sessionId, :final reason, :final exitCode):
        writer
          ..writeUint8(_tagSessionClosed)
          ..writeSessionId(sessionId)
          ..writeUint8(reason.code)
          ..writeInt32(exitCode);
      case RenameSessionFrame(:final sessionId, :final title, :final clearPin):
        _encodeRenameSession(writer, sessionId, title, clearPin);
      case ShellTitleFrame(:final sessionId, :final title):
        _encodeShellTitle(writer, sessionId, title);
      case BellFrame(:final sessionId):
        writer
          ..writeUint8(_tagBell)
          ..writeSessionId(sessionId);
      case AudioFrame frame:
        _encodeAudio(writer, frame);
      case ErrorFrame(:final code, :final message):
        writer
          ..writeUint8(_tagError)
          ..writeString16(code, maxBytes: _maxErrorCodeBytes)
          ..writeString16(message, maxBytes: _maxTokenOrErrorBytes);
      case ClipboardFrame frame:
        _encodeClipboard(writer, frame);
      case RequestScrollbackFrame frame:
        _encodeRequestScrollback(writer, frame);
      case ScrollbackChunkFrame frame:
        _encodeScrollbackChunk(writer, frame);
      case FileUploadStartFrame frame:
        _encodeFileUploadStart(writer, frame);
      case FileUploadChunkFrame frame:
        _encodeFileUploadChunk(writer, frame);
      case FileUploadEndFrame frame:
        _encodeFileUploadEnd(writer, frame);
      case FileUploadAckFrame frame:
        _encodeFileUploadAck(writer, frame);
      case AudioWaveformReplyFrame(
        :final sessionId,
        :final requestId,
        :final samples,
      ):
        _encodeAudioWaveformReply(writer, sessionId, requestId, samples);
      case KittyImageChunkFrame frame:
        _encodeKittyImageChunk(writer, frame);
      case ShaderFrame frame:
        _encodeShaderFrame(writer, frame);
      case SpawnSessionFrame(:final sessionId):
        writer
          ..writeUint8(_tagSpawnSession)
          ..writeSessionId(sessionId);
    }
    final bytes = writer.takeBytes();
    if (message is ShaderFrame && bytes.length > maxShaderFrameBytes) {
      throw ProtocolFormatException(
        'Encoded ShaderFrame exceeds $maxShaderFrameBytes bytes: ${bytes.length}',
      );
    }
    if (bytes.length > maxFrameBytes) {
      throw ProtocolFormatException(
        'Encoded frame exceeds $maxFrameBytes bytes: ${bytes.length}',
      );
    }
    return bytes;
  }

  /// Decodes a binary WebSocket [frame] into a typed [CastMessage].
  static CastMessage decode(Uint8List frame) =>
      _traceCodecSpan(_traceDecodeId, () => _decodeImpl(frame));

  static CastMessage _decodeImpl(Uint8List frame) {
    if (frame.length > maxFrameBytes) {
      throw ProtocolFormatException(
        'Incoming frame exceeds $maxFrameBytes bytes: ${frame.length}',
      );
    }
    final reader = _FrameReader(frame);
    final version = reader.readUint8();
    if (version != protocolVersion) {
      throw ProtocolFormatException('Unsupported wire version: $version');
    }
    final tag = reader.readUint8();
    final message = _decodeByTag(reader, tag);
    if (!reader.isAtEnd) {
      throw const ProtocolFormatException('Trailing bytes after frame body');
    }
    return message;
  }

  /// Inspects whether [frame] is a valid snapshot or delta for [expectedSession]
  /// without materializing cell arrays on the stateless relay server.
  static RelayBufferFrameInfo? inspectRelayBufferFrame(
    Uint8List frame, {
    required SessionId expectedSession,
  }) {
    if (frame.length < 2 || frame[0] != protocolVersion) return null;
    final tag = frame[1];
    if (tag != _tagBufferSnapshot && tag != _tagBufferDelta) return null;
    if (frame.length > maxFrameBytes) {
      throw ProtocolFormatException(
        'Relay buffer frame exceeds $maxFrameBytes bytes: ${frame.length}',
      );
    }
    final reader = _FrameReader(frame)..skip(2);
    if (reader.readSessionId() != expectedSession) return null;
    final seq = reader.readUint53();
    final isSnapshot = tag == _tagBufferSnapshot;
    if (!isSnapshot) {
      _checkDeltaSeqOrder(reader.readUint53(), seq);
    }
    final cols = reader.readUint16();
    final rows = reader.readUint16();
    _checkGridDims(cols, rows);
    // Validate cursor+modes (7 bytes), scrollback window (20 bytes), wrappedRows, and payload.
    reader.skip(7);
    reader.readScrollbackWindow();
    reader.skipWrappedRows(rows);
    _inspectRelayBufferTail(
      reader,
      isSnapshot: isSnapshot,
      totalCells: cols * rows,
    );
    return (isSnapshot: isSnapshot, seq: seq, cols: cols, rows: rows);
  }

  /// Validates the header and tail bounds of a raw `0x11` [ScrollbackChunkFrame]
  /// for [expectedSession] in a single pass and returns its `requestId` and byte
  /// offset, or `null` when [frame] does not belong to [expectedSession].
  static ({int requestId, int requestIdOffset})? inspectRelayScrollbackChunk(
    Uint8List frame, {
    required SessionId expectedSession,
  }) => _inspectScrollbackChunkHeader(frame, expectedSession: expectedSession);

  /// Rewrites `requestId` at [requestIdOffset] in a validated `0x11`
  /// [ScrollbackChunkFrame], mutating [frame] directly when [inPlace] is
  /// `true` or returning a copy otherwise.
  static Uint8List patchScrollbackChunkRequestId(
    Uint8List frame, {
    required int requestIdOffset,
    required int newRequestId,
    bool inPlace = false,
  }) {
    _checkUint32(newRequestId, 'newRequestId');
    final target = inPlace ? frame : Uint8List.fromList(frame);
    ByteData.sublistView(target).setUint32(requestIdOffset, newRequestId, .big);
    return target;
  }

  /// Validates the uncompressed header of a raw `0x11` [ScrollbackChunkFrame]
  /// for [expectedSession] and returns its `requestId`, or `null` when [frame]
  /// does not belong to [expectedSession].
  static int? inspectRelayScrollbackChunkRequestId(
    Uint8List frame, {
    required SessionId expectedSession,
  }) => inspectRelayScrollbackChunk(
    frame,
    expectedSession: expectedSession,
  )?.requestId;

  /// Validates a raw `0x11` [ScrollbackChunkFrame] for [expectedSession] and
  /// returns a copy with `requestId` rewritten to [newRequestId] without
  /// inflating or re-compressing the scrollback rows, or `null` when [frame]
  /// does not belong to [expectedSession].
  static Uint8List? rewriteScrollbackChunkRequestId(
    Uint8List frame, {
    required SessionId expectedSession,
    required int newRequestId,
  }) {
    _checkUint32(newRequestId, 'newRequestId');
    final info = _inspectScrollbackChunkHeader(
      frame,
      expectedSession: expectedSession,
    );
    if (info == null) return null;
    return patchScrollbackChunkRequestId(
      frame,
      requestIdOffset: info.requestIdOffset,
      newRequestId: newRequestId,
    );
  }

  /// Validates the header and length bounds of a raw `0x18` [BellFrame]
  /// for [expectedSession] without full [CastMessage] allocation.
  static bool inspectRelayBellFrame(
    Uint8List frame, {
    required SessionId expectedSession,
  }) {
    if (frame.length < 2 ||
        frame[0] != protocolVersion ||
        frame[1] != _tagBell) {
      return false;
    }
    if (frame.length > maxFrameBytes) {
      throw ProtocolFormatException(
        'Relay bell frame exceeds $maxFrameBytes bytes: ${frame.length}',
      );
    }
    final reader = _FrameReader(frame)..skip(2);
    if (reader.readSessionId() != expectedSession) return false;
    if (!reader.isAtEnd) {
      throw const ProtocolFormatException('Trailing bytes after BellFrame');
    }
    return true;
  }

  /// Validates the header and `<= 2 MiB + header` compression envelope of a raw
  /// `0x19` [AudioFrame] for [expectedSession] without inflating compressed data.
  static bool inspectRelayAudioFrame(
    Uint8List frame, {
    required SessionId expectedSession,
  }) {
    if (frame.length < 2 ||
        frame[0] != protocolVersion ||
        frame[1] != _tagAudio) {
      return false;
    }
    if (frame.length > maxFrameBytes) {
      throw ProtocolFormatException(
        'Relay audio frame exceeds $maxFrameBytes bytes: ${frame.length}',
      );
    }
    final reader = _FrameReader(frame)..skip(2);
    final sessionId = reader.readSessionId();
    if (sessionId != expectedSession) return false;
    try {
      _inspectRelayAudioTail(reader);
    } on CorruptAudioFrameException {
      rethrow;
    } on ProtocolFormatException catch (e) {
      throw CorruptAudioFrameException(sessionId, e.message);
    }
    return true;
  }

  /// Validates the header and slice bounds of a raw `0x1B` [KittyImageChunkFrame]
  /// for [expectedSession] in O(1) without copying chunk bytes.
  static bool inspectRelayKittyChunkFrame(
    Uint8List frame, {
    required SessionId expectedSession,
  }) {
    if (frame.length < 2 ||
        frame[0] != protocolVersion ||
        frame[1] != _tagKittyImageChunk) {
      return false;
    }
    if (frame.length > maxFrameBytes) {
      throw ProtocolFormatException(
        'Relay Kitty chunk frame exceeds $maxFrameBytes bytes: ${frame.length}',
      );
    }
    final reader = _FrameReader(frame)..skip(2);
    if (reader.readSessionId() != expectedSession) return false;
    _readValidatedKittyChunkHeader(reader);
    if (!reader.isAtEnd) {
      throw const ProtocolFormatException(
        'Trailing bytes after KittyImageChunkFrame',
      );
    }
    return true;
  }

  /// Validates the header, `<= 64 KiB` byte budget, and typed payload bounds of
  /// a raw `0x1C` [ShaderFrame] for [expectedSession] on the relay fast path.
  static bool inspectRelayShaderFrame(
    Uint8List frame, {
    required SessionId expectedSession,
  }) {
    if (frame.length < 2 ||
        frame[0] != protocolVersion ||
        frame[1] != _tagShader) {
      return false;
    }
    if (frame.length > maxShaderFrameBytes) {
      throw ProtocolFormatException(
        'Relay ShaderFrame exceeds $maxShaderFrameBytes bytes: ${frame.length}',
      );
    }
    final reader = _FrameReader(frame)..skip(2);
    final sessionId = reader.readSessionId();
    if (sessionId != expectedSession) return false;
    try {
      _decodeShaderPayload(reader);
      if (!reader.isAtEnd) {
        throw const ProtocolFormatException('Trailing bytes after ShaderFrame');
      }
    } on ProtocolFormatException catch (e) {
      throw CorruptSessionFrameException(sessionId, e.message);
    }
    return true;
  }

  /// Applies [delta] to [buffer] via `setRange` when `(baseSeq, cols, rows)` match.
  ///
  /// Returns `false` without mutating [buffer] when [currentSeq] does not match
  /// [BufferDelta.baseSeq] or when dimensions differ.
  static bool applyDelta({
    required Buffer buffer,
    required int currentSeq,
    required BufferDelta delta,
  }) => _traceCodecSpan(
    _traceApplyDeltaId,
    () => _applyDeltaImpl(buffer: buffer, currentSeq: currentSeq, delta: delta),
  );

  static bool _applyDeltaImpl({
    required Buffer buffer,
    required int currentSeq,
    required BufferDelta delta,
  }) {
    if (delta.baseSeq != currentSeq ||
        delta.cols != buffer.width ||
        delta.rows != buffer.height) {
      return false;
    }
    _validateCellRuns(delta.runs, buffer.characters.length);
    for (final run in delta.runs) {
      final start = run.startIndex;
      final len = run.characters.length;
      final end = start + len;
      buffer.characters.setRange(start, end, run.characters);
      buffer.attributes.setRange(start * 3, end * 3, run.attributes);
      applyCellAuxToBuffer(
        buffer,
        start,
        len,
        underlineColors: run.underlineColors,
        uriRuns: run.uriRuns,
      );
    }
    return true;
  }
}

void _validateCellRuns(List<CellRun> runs, int totalCells) {
  var nextMinStart = 0;
  for (final run in runs) {
    final len = run.characters.length;
    if (len == 0 ||
        run.startIndex < nextMinStart ||
        run.startIndex + len > totalCells ||
        run.attributes.length != len * 3) {
      throw ProtocolFormatException(
        'Invalid CellRun at ${run.startIndex} (len $len) for grid $totalCells',
      );
    }
    _validateSpanAux(len, run.underlineColors, run.uriRuns);
    nextMinStart = run.startIndex + len;
  }
}

void _validateSpanAux(
  int cellCount,
  Map<int, int>? underlineColors,
  List<UriRun>? uriRuns,
) {
  if (underlineColors != null) {
    _validateSpanUnderlineColors(cellCount, underlineColors);
  }
  if (uriRuns != null && uriRuns.isNotEmpty) {
    _validateSpanUriRuns(cellCount, uriRuns);
  }
}

void _validateSpanUnderlineColors(
  int cellCount,
  Map<int, int> underlineColors,
) {
  for (final entry in underlineColors.entries) {
    if (entry.key < 0 || entry.key >= cellCount) {
      throw ProtocolFormatException(
        'Out-of-bounds underlineColor index ${entry.key} for span $cellCount',
      );
    }
  }
}

void _validateSpanUriRuns(int cellCount, List<UriRun> uriRuns) {
  var nextMinStart = 0;
  for (final run in uriRuns) {
    if (run.length <= 0 ||
        run.start < nextMinStart ||
        run.start + run.length > cellCount) {
      throw ProtocolFormatException(
        'Invalid UriRun start=${run.start} len=${run.length} for span $cellCount',
      );
    }
    final sanitized = sanitizeOsc8Uri(run.uri);
    final byteLen = utf8.encode(sanitized).length;
    if (byteLen == 0 || byteLen > maxOsc8UriBytes) {
      throw ProtocolFormatException(
        'Invalid OSC 8 URI byte length: $byteLen (max $maxOsc8UriBytes)',
      );
    }
    nextMinStart = run.start + run.length;
  }
}

CastMessage _decodeByTag(_FrameReader reader, int tag) {
  return switch (tag) {
    _tagAuth => AuthFrame(
      role: _decodeRole(reader.readUint8()),
      token: reader.readString16(maxBytes: _maxTokenOrErrorBytes),
    ),
    _tagAuthAccepted => _decodeAuthAccepted(reader),
    _tagRegisterSession => _decodeRegister(reader),
    _tagSessionDirectory => _decodeDirectory(reader),
    _tagSubscribeSession => _decodeSubscribe(reader),
    _tagUnsubscribeSession => UnsubscribeSessionFrame(
      sessionId: reader.readSessionId(),
    ),
    _tagSubscriberCount => SubscriberCountFrame(
      sessionId: reader.readSessionId(),
      subscriberCount: reader.readUint32(),
    ),
    _tagRequestKeyframe => RequestKeyframeFrame(
      sessionId: reader.readSessionId(),
    ),
    _tagBufferSnapshot => BufferSnapshotFrame(
      snapshot: _decodeSnapshot(reader),
    ),
    _tagBufferDelta => BufferDeltaFrame(delta: _decodeDelta(reader)),
    _tagInput => InputFrame(
      sessionId: reader.readSessionId(),
      data: reader.readBytes32(maxBytes: BufferFrameCodec.maxInputBytes),
    ),
    _tagResize => _decodeResize(reader),
    _tagSessionClosed => SessionClosedFrame(
      sessionId: reader.readSessionId(),
      reason: _decodeCloseReason(reader.readUint8()),
      exitCode: reader.readInt32(),
    ),
    _tagRenameSession => _decodeRenameSession(reader),
    _tagShellTitle => _decodeShellTitle(reader),
    _tagBell => BellFrame(sessionId: reader.readSessionId()),
    _tagAudio => _decodeAudio(reader),
    _tagError => ErrorFrame(
      code: reader.readString16(maxBytes: _maxErrorCodeBytes),
      message: reader.readString16(maxBytes: _maxTokenOrErrorBytes),
    ),
    _tagClipboard => _decodeClipboard(reader),
    _tagRequestScrollback => _decodeRequestScrollback(reader),
    _tagScrollbackChunk => _decodeScrollbackChunk(reader),
    _tagFileUploadStart => _decodeFileUploadStart(reader),
    _tagFileUploadChunk => _decodeFileUploadChunk(reader),
    _tagFileUploadEnd => _decodeFileUploadEnd(reader),
    _tagFileUploadAck => _decodeFileUploadAck(reader),
    _tagAudioWaveformReply => _decodeAudioWaveformReply(reader),
    _tagKittyImageChunk => _decodeKittyImageChunk(reader),
    _tagShader => _decodeShaderFrame(reader),
    _tagSpawnSession => SpawnSessionFrame(sessionId: reader.readSessionId()),
    _ => throw ProtocolFormatException('Unknown frame tag: $tag'),
  };
}

int _encodeRole(CastRole role) => switch (role) {
  .caster => 0,
  .client => 1,
};

CastRole _decodeRole(int raw) => switch (raw) {
  0 => .caster,
  1 => .client,
  _ => throw ProtocolFormatException('Invalid CastRole byte: $raw'),
};

SessionCloseReason _decodeCloseReason(int raw) => switch (raw) {
  0 => .exited,
  1 => .disconnected,
  _ => throw ProtocolFormatException('Invalid SessionCloseReason byte: $raw'),
};

void _encodeRenameSession(
  _FrameWriter writer,
  SessionId sessionId,
  String title,
  bool clearPin,
) {
  final encoded = (!clearPin || title.isNotEmpty)
      ? _encodeValidatedTitle(title)
      : Uint8List(0);
  writer
    ..writeUint8(_tagRenameSession)
    ..writeSessionId(sessionId)
    ..writeUint8(clearPin ? _renameFlagClearPin : 0)
    ..writeUint16(encoded.length)
    ..writeRawBytes(encoded);
}

RenameSessionFrame _decodeRenameSession(_FrameReader reader) {
  final sessionId = reader.readSessionId();
  final rawFlags = reader.readUint8();
  if ((rawFlags & ~_renameFlagClearPin) != 0) {
    throw ProtocolFormatException(
      'Invalid RenameSessionFrame flags byte: $rawFlags',
    );
  }
  final clearPin = (rawFlags & _renameFlagClearPin) != 0;
  final title = reader.readString16(maxBytes: _maxTitleBytes);
  if (!clearPin || title.isNotEmpty) {
    _validateTitleText(title);
  }
  return RenameSessionFrame(
    sessionId: sessionId,
    title: title,
    clearPin: clearPin,
  );
}

void _encodeShellTitle(_FrameWriter writer, SessionId sessionId, String title) {
  final clean = sanitizeShellTitle(title);
  writer
    ..writeUint8(_tagShellTitle)
    ..writeSessionId(sessionId)
    ..writeString16(clean, maxBytes: _maxTitleBytes);
}

ShellTitleFrame _decodeShellTitle(_FrameReader reader) {
  final sessionId = reader.readSessionId();
  final title = reader.readString16(maxBytes: _maxTitleBytes);
  if (_disallowedTitleChars.hasMatch(title) || title != title.trim()) {
    throw const ProtocolFormatException(
      'Shell title contains control, bidi, or leading/trailing whitespace',
    );
  }
  return ShellTitleFrame(sessionId: sessionId, title: title);
}

void _encodeAudio(_FrameWriter writer, AudioFrame frame) {
  final tailWriter = _FrameWriter();
  _writeAudioPayload(tailWriter, frame.payload);
  final rawTail = tailWriter.takeBytes();
  if (rawTail.length > _maxAudioTailBytes) {
    throw ProtocolFormatException(
      'AudioFrame tail exceeds $_maxAudioTailBytes bytes: ${rawTail.length}',
    );
  }
  writer
    ..writeUint8(_tagAudio)
    ..writeSessionId(frame.sessionId);
  if (frame.payload is CastStreamAudioPayload) {
    writer
      ..writeUint8(_compressionRaw)
      ..writeRawBytes(rawTail);
  } else {
    _writeCompressibleAudioTail(writer, rawTail);
  }
}

void _writeCompressibleAudioTail(_FrameWriter writer, Uint8List rawTail) {
  if (rawTail.length >= BufferFrameCodec.minCompressTailBytes) {
    final compressed = compressDeflateRawLevel1(rawTail);
    if (compressed.length < rawTail.length) {
      writer
        ..writeUint8(_compressionDeflateRaw)
        ..writeUint32(rawTail.length)
        ..writeRawBytes(compressed);
      return;
    }
  }
  writer
    ..writeUint8(_compressionRaw)
    ..writeRawBytes(rawTail);
}

void _writeAudioPayload(_FrameWriter tail, CastAudioPayload payload) {
  switch (payload) {
    case CastToneAudioPayload():
      _writeToneAudio(tail, payload);
    case CastClipAudioPayload():
      _writeClipAudio(tail, payload);
    case CastStopAudioPayload():
      _writeStopAudio(tail, payload);
    case CastUpdateAudioPayload():
      _writeUpdateAudio(tail, payload);
    case CastBusAudioPayload():
      _writeBusAudio(tail, payload);
    case CastStreamAudioPayload():
      _writeStreamAudio(tail, payload);
    case CastWaveformQueryAudioPayload():
      _writeWaveQueryAudio(tail, payload);
  }
}

void _validatePositiveWaveQueryId(int requestId) {
  if (requestId <= 0 || requestId > 0x7FFFFFFF) {
    throw ProtocolFormatException(
      'Invalid audio waveform requestId: $requestId',
    );
  }
}

void _writeWaveQueryAudio(
  _FrameWriter tail,
  CastWaveformQueryAudioPayload query,
) {
  _validatePositiveWaveQueryId(query.requestId);
  tail
    ..writeUint8(_audioKindWaveQuery)
    ..writeUint32(query.requestId);
}

void _encodeAudioWaveformReply(
  _FrameWriter writer,
  SessionId sessionId,
  int requestId,
  Float32List samples,
) {
  _validatePositiveWaveQueryId(requestId);
  if (samples.length != AudioWaveformReplyFrame.sampleCount) {
    throw ProtocolFormatException(
      'AudioWaveformReplyFrame requires ${AudioWaveformReplyFrame.sampleCount} samples, got ${samples.length}',
    );
  }
  final payload = Uint8List(AudioWaveformReplyFrame.payloadByteLength);
  final view = ByteData.sublistView(payload);
  for (var i = 0; i < AudioWaveformReplyFrame.sampleCount; i++) {
    final sample = samples[i];
    if (!sample.isFinite) {
      throw ProtocolFormatException(
        'AudioWaveformReplyFrame contains non-finite sample at $i',
      );
    }
    view.setFloat32(i * 4, sample, .little);
  }
  writer
    ..writeUint8(_tagAudioWaveformReply)
    ..writeSessionId(sessionId)
    ..writeUint32(requestId)
    ..writeRawBytes(payload);
}

AudioWaveformReplyFrame _decodeAudioWaveformReply(_FrameReader reader) {
  final sessionId = reader.readSessionId();
  final requestId = reader.readUint32();
  _validatePositiveWaveQueryId(requestId);
  final raw = reader.readFixedBytes(AudioWaveformReplyFrame.payloadByteLength);
  final view = ByteData.sublistView(raw);
  final samples = Float32List(AudioWaveformReplyFrame.sampleCount);
  for (var i = 0; i < AudioWaveformReplyFrame.sampleCount; i++) {
    final sample = view.getFloat32(i * 4, .little);
    if (!sample.isFinite) {
      throw ProtocolFormatException(
        'AudioWaveformReplyFrame contains non-finite sample at $i',
      );
    }
    samples[i] = sample;
  }
  return AudioWaveformReplyFrame(
    sessionId: sessionId,
    requestId: requestId,
    samples: samples,
  );
}

void _validateKittyImageDimensions({
  required int imageId,
  required int pixelWidth,
  required int pixelHeight,
  required int gridCols,
  required int gridRows,
}) {
  if (imageId <= 0 || imageId > 0xFFFFFFFF) {
    throw ProtocolFormatException('Invalid Kitty imageId: $imageId');
  }
  if (pixelWidth <= 0 ||
      pixelWidth > _maxKittyImageDimension ||
      pixelHeight <= 0 ||
      pixelHeight > _maxKittyImageDimension ||
      pixelWidth * pixelHeight > _maxKittyImageTotalPixels) {
    throw ProtocolFormatException(
      'Invalid Kitty image dimensions: ${pixelWidth}x$pixelHeight',
    );
  }
  if (gridCols <= 0 ||
      gridCols > _maxKittyImageGridSpan ||
      gridRows <= 0 ||
      gridRows > _maxKittyImageGridSpan) {
    throw ProtocolFormatException(
      'Invalid Kitty grid span: ${gridCols}x$gridRows',
    );
  }
}

KittyChunkEncoding _decodeKittyChunkEncoding(int raw) => switch (raw) {
  0 => .raw,
  1 => .deflateRaw,
  _ => throw ProtocolFormatException('Invalid KittyChunkEncoding byte: $raw'),
};

void _validateKittyChunkMetadata({
  required int imageId,
  required int version,
  required int pixelWidth,
  required int pixelHeight,
  required int gridCols,
  required int gridRows,
  required int format,
  required KittyChunkEncoding encoding,
  required int totalDecodedBytes,
  required int totalWireBytes,
  required int chunkIndex,
  required int chunkCount,
  required int dataLength,
}) {
  _validateKittyImageDimensions(
    imageId: imageId,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
    gridCols: gridCols,
    gridRows: gridRows,
  );
  _checkUint32(version, 'kittyChunk.version');
  _validateKittyChunkFormatAndSizes(
    format: format,
    encoding: encoding,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
    totalDecodedBytes: totalDecodedBytes,
    totalWireBytes: totalWireBytes,
  );
  _validateKittyChunkSliceBounds(
    totalWireBytes: totalWireBytes,
    chunkIndex: chunkIndex,
    chunkCount: chunkCount,
    dataLength: dataLength,
  );
}

void _validateKittyChunkFormatAndSizes({
  required int format,
  required KittyChunkEncoding encoding,
  required int pixelWidth,
  required int pixelHeight,
  required int totalDecodedBytes,
  required int totalWireBytes,
}) {
  if (format == 32) {
    final expected = pixelWidth * pixelHeight * 4;
    if (totalDecodedBytes != expected) {
      throw ProtocolFormatException(
        'RGBA32 Kitty totalDecodedBytes $totalDecodedBytes != $expected',
      );
    }
  } else if (format == 100) {
    if (totalDecodedBytes < _minPngBytes ||
        totalDecodedBytes > BufferFrameCodec.maxKittyImageBytes) {
      throw ProtocolFormatException(
        'PNG Kitty totalDecodedBytes out of range: $totalDecodedBytes',
      );
    }
  } else {
    throw ProtocolFormatException('Unsupported Kitty image format: $format');
  }
  if (totalWireBytes <= 0 ||
      totalWireBytes > BufferFrameCodec.maxKittyImageBytes) {
    throw ProtocolFormatException(
      'Kitty totalWireBytes out of range: $totalWireBytes',
    );
  }
  if (encoding == .raw && totalWireBytes != totalDecodedBytes) {
    throw ProtocolFormatException(
      'Raw Kitty totalWireBytes $totalWireBytes != $totalDecodedBytes',
    );
  }
}

void _validateKittyChunkSliceBounds({
  required int totalWireBytes,
  required int chunkIndex,
  required int chunkCount,
  required int dataLength,
}) {
  final minChunks =
      (totalWireBytes + BufferFrameCodec.maxKittyChunkBytes - 1) ~/
      BufferFrameCodec.maxKittyChunkBytes;
  final maxChunks = totalWireBytes < _maxKittyChunkCount
      ? totalWireBytes
      : _maxKittyChunkCount;
  if (chunkCount <= 0 ||
      chunkCount > _maxKittyChunkCount ||
      chunkCount < minChunks ||
      chunkCount > maxChunks) {
    throw ProtocolFormatException(
      'Invalid Kitty chunkCount=$chunkCount for totalWireBytes=$totalWireBytes',
    );
  }
  if (chunkIndex < 0 || chunkIndex >= chunkCount) {
    throw ProtocolFormatException(
      'Invalid Kitty chunkIndex=$chunkIndex for chunkCount=$chunkCount',
    );
  }
  if (dataLength <= 0 ||
      dataLength > BufferFrameCodec.maxKittyChunkBytes ||
      dataLength > totalWireBytes) {
    throw ProtocolFormatException(
      'Invalid Kitty chunk dataLength=$dataLength for totalWireBytes=$totalWireBytes',
    );
  }
  final maxRemainingBytes =
      (chunkCount - 1) * BufferFrameCodec.maxKittyChunkBytes;
  if (dataLength > totalWireBytes - (chunkCount - 1) ||
      dataLength < totalWireBytes - maxRemainingBytes) {
    throw ProtocolFormatException(
      'Kitty chunk dataLength=$dataLength incompatible with totalWireBytes=$totalWireBytes across $chunkCount chunks',
    );
  }
}

void _encodeKittyImageChunk(_FrameWriter writer, KittyImageChunkFrame frame) {
  _validateKittyChunkMetadata(
    imageId: frame.imageId,
    version: frame.version,
    pixelWidth: frame.pixelWidth,
    pixelHeight: frame.pixelHeight,
    gridCols: frame.gridCols,
    gridRows: frame.gridRows,
    format: frame.format,
    encoding: frame.encoding,
    totalDecodedBytes: frame.totalDecodedBytes,
    totalWireBytes: frame.totalWireBytes,
    chunkIndex: frame.chunkIndex,
    chunkCount: frame.chunkCount,
    dataLength: frame.data.length,
  );
  if (frame.chunkIndex == 0 && frame.format == 100 && frame.encoding == .raw) {
    _validatePngIhdrSlice(
      frame.data,
      0,
      frame.data.length,
      frame.pixelWidth,
      frame.pixelHeight,
    );
  }
  writer
    ..writeUint8(_tagKittyImageChunk)
    ..writeSessionId(frame.sessionId)
    ..writeUint32(frame.imageId)
    ..writeUint32(frame.version)
    ..writeUint16(frame.pixelWidth)
    ..writeUint16(frame.pixelHeight)
    ..writeUint16(frame.gridCols)
    ..writeUint16(frame.gridRows)
    ..writeUint8(frame.format)
    ..writeUint8(frame.encoding.code)
    ..writeUint32(frame.totalDecodedBytes)
    ..writeUint32(frame.totalWireBytes)
    ..writeUint16(frame.chunkIndex)
    ..writeUint16(frame.chunkCount)
    ..writeBytes32(frame.data);
}

({
  int imageId,
  int version,
  int pixelWidth,
  int pixelHeight,
  int gridCols,
  int gridRows,
  int format,
  KittyChunkEncoding encoding,
  int totalDecodedBytes,
  int totalWireBytes,
  int chunkIndex,
  int chunkCount,
  int dataOffset,
  int dataLength,
})
_readValidatedKittyChunkHeader(_FrameReader reader) {
  final imageId = reader.readUint32();
  final version = reader.readUint32();
  final pixelWidth = reader.readUint16();
  final pixelHeight = reader.readUint16();
  final gridCols = reader.readUint16();
  final gridRows = reader.readUint16();
  final format = reader.readUint8();
  final encoding = _decodeKittyChunkEncoding(reader.readUint8());
  final totalDecodedBytes = reader.readUint32();
  final totalWireBytes = reader.readUint32();
  final chunkIndex = reader.readUint16();
  final chunkCount = reader.readUint16();
  final dataLength = reader.readUint32();
  _validateKittyChunkMetadata(
    imageId: imageId,
    version: version,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
    gridCols: gridCols,
    gridRows: gridRows,
    format: format,
    encoding: encoding,
    totalDecodedBytes: totalDecodedBytes,
    totalWireBytes: totalWireBytes,
    chunkIndex: chunkIndex,
    chunkCount: chunkCount,
    dataLength: dataLength,
  );
  reader._require(dataLength);
  final dataOffset = reader._offset;
  if (chunkIndex == 0 && format == 100 && encoding == .raw) {
    _validatePngIhdrSlice(
      reader._bytes,
      dataOffset,
      dataLength,
      pixelWidth,
      pixelHeight,
    );
  }
  reader._offset += dataLength;
  return (
    imageId: imageId,
    version: version,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
    gridCols: gridCols,
    gridRows: gridRows,
    format: format,
    encoding: encoding,
    totalDecodedBytes: totalDecodedBytes,
    totalWireBytes: totalWireBytes,
    chunkIndex: chunkIndex,
    chunkCount: chunkCount,
    dataOffset: dataOffset,
    dataLength: dataLength,
  );
}

KittyImageChunkFrame _decodeKittyImageChunk(_FrameReader reader) {
  final sessionId = reader.readSessionId();
  try {
    final h = _readValidatedKittyChunkHeader(reader);
    if (!reader.isAtEnd) {
      throw const ProtocolFormatException('Trailing bytes after frame body');
    }
    final data = Uint8List.fromList(
      Uint8List.sublistView(
        reader._bytes,
        h.dataOffset,
        h.dataOffset + h.dataLength,
      ),
    );
    return KittyImageChunkFrame(
      sessionId: sessionId,
      imageId: h.imageId,
      version: h.version,
      pixelWidth: h.pixelWidth,
      pixelHeight: h.pixelHeight,
      gridCols: h.gridCols,
      gridRows: h.gridRows,
      format: h.format,
      encoding: h.encoding,
      totalDecodedBytes: h.totalDecodedBytes,
      totalWireBytes: h.totalWireBytes,
      chunkIndex: h.chunkIndex,
      chunkCount: h.chunkCount,
      data: data,
    );
  } on ProtocolFormatException catch (e) {
    throw CorruptSessionFrameException(sessionId, e.message);
  }
}

void _writeToneAudio(_FrameWriter tail, CastToneAudioPayload tone) {
  if (!_validAudioWaveforms.contains(tone.waveform)) {
    throw ProtocolFormatException(
      'Unsupported audio waveform: ${tone.waveform}',
    );
  }
  _validateAudioToneNumbers(
    frequencyHz: tone.frequencyHz,
    durationMicros: tone.duration.inMicroseconds,
    volume: tone.volume,
    pan: tone.pan,
  );
  if (tone.busId case final busId?) {
    _validatePositiveAudioId(busId, label: 'busId');
  }
  tail
    ..writeUint8(_audioKindTone)
    ..writeString16(tone.waveform, maxBytes: _maxAudioWaveformBytes)
    ..writeFloat64(tone.frequencyHz)
    ..writeUint53(tone.duration.inMicroseconds)
    ..writeFloat64(tone.volume)
    ..writeFloat64(tone.pan)
    ..writeUint32(tone.busId ?? 0);
}

void _writeClipAudio(_FrameWriter tail, CastClipAudioPayload clip) {
  _validatePositiveAudioId(clip.clipId);
  if (clip.busId case final busId?) {
    _validatePositiveAudioId(busId, label: 'busId');
  }
  if (clip.streamId case final streamId?) {
    _validatePositiveAudioId(streamId, label: 'streamId');
    if (clip.format.isNotEmpty && !_validAudioFormats.contains(clip.format)) {
      throw ProtocolFormatException('Unsupported audio format: ${clip.format}');
    }
    if (clip.bytes.isNotEmpty) {
      throw ProtocolFormatException(
        'Stream clip must have 0 inline bytes, got ${clip.bytes.length}',
      );
    }
  } else {
    if (!_validAudioFormats.contains(clip.format)) {
      throw ProtocolFormatException('Unsupported audio format: ${clip.format}');
    }
    if (clip.bytes.isEmpty ||
        clip.bytes.length > CastAudioPayload.maxClipBytes) {
      throw ProtocolFormatException(
        'Invalid audio clip byte length: ${clip.bytes.length}',
      );
    }
  }
  _validateAudioGainAndPan(volume: clip.volume, pan: clip.pan);
  _validateAudioDurationMicros(
    clip.startOffset.inMicroseconds,
    label: 'startOffset',
  );
  tail
    ..writeUint8(_audioKindClip)
    ..writeUint32(clip.clipId)
    ..writeString16(clip.format, maxBytes: _maxAudioFormatBytes)
    ..writeFloat64(clip.volume)
    ..writeFloat64(clip.pan)
    ..writeUint8(clip.loop ? 1 : 0)
    ..writeUint53(clip.startOffset.inMicroseconds)
    ..writeUint32(clip.busId ?? 0)
    ..writeUint32(clip.streamId ?? 0)
    ..writeBytes32(clip.bytes);
}

void _writeStopAudio(_FrameWriter tail, CastStopAudioPayload stop) {
  final clipId = stop.clipId;
  if (clipId != null) {
    _validatePositiveAudioId(clipId);
  }
  tail
    ..writeUint8(_audioKindStop)
    ..writeUint8(clipId == null ? 0 : 1);
  if (clipId != null) {
    tail.writeUint32(clipId);
  }
}

int _computeAndValidateUpdateFlags(CastUpdateAudioPayload update) {
  _validatePositiveAudioId(update.clipId);
  if ((update.fadeVolumeTarget == null) !=
      (update.fadeVolumeDuration == null)) {
    throw const ProtocolFormatException(
      'fadeVolumeTarget and fadeVolumeDuration must both be set or null',
    );
  }
  if ((update.fadeSpeedTarget == null) != (update.fadeSpeedDuration == null)) {
    throw const ProtocolFormatException(
      'fadeSpeedTarget and fadeSpeedDuration must both be set or null',
    );
  }
  final flags =
      (update.volume != null ? _audioUpdateFlagVolume : 0) |
      (update.pan != null ? _audioUpdateFlagPan : 0) |
      (update.seekPosition != null ? _audioUpdateFlagSeek : 0) |
      (update.paused != null ? _audioUpdateFlagPaused : 0) |
      (update.speed != null ? _audioUpdateFlagSpeed : 0) |
      (update.preservePitch != null ? _audioUpdateFlagPreservePitch : 0) |
      (update.fadeVolumeTarget != null ? _audioUpdateFlagFadeVolume : 0) |
      (update.fadeSpeedTarget != null ? _audioUpdateFlagFadeSpeed : 0) |
      (update.scheduleStopDuration != null ? _audioUpdateFlagScheduleStop : 0);
  if (flags == 0) {
    throw const ProtocolFormatException(
      'CastUpdateAudioPayload requires at least one update field',
    );
  }
  _validateAudioGainAndPan(
    volume: update.volume ?? 1.0,
    pan: update.pan ?? 0.0,
  );
  _validateOptionalUpdateTransport(update);
  return flags;
}

void _validateOptionalUpdateTransport(CastUpdateAudioPayload update) {
  if (update.seekPosition case final seek?) {
    _validateAudioDurationMicros(seek.inMicroseconds, label: 'seekPosition');
  }
  if (update.speed case final speed?) {
    _validateAudioSpeed(speed);
  }
  if (update.fadeVolumeTarget case final target?) {
    _validateAudioGainAndPan(volume: target, pan: 0.0);
    _validateAudioDurationMicros(
      update.fadeVolumeDuration!.inMicroseconds,
      label: 'fadeVolumeDuration',
    );
  }
  if (update.fadeSpeedTarget case final target?) {
    _validateAudioSpeed(target);
    _validateAudioDurationMicros(
      update.fadeSpeedDuration!.inMicroseconds,
      label: 'fadeSpeedDuration',
    );
  }
  if (update.scheduleStopDuration case final stopDur?) {
    _validateAudioDurationMicros(
      stopDur.inMicroseconds,
      label: 'scheduleStopDuration',
    );
  }
}

void _writeUpdateAudio(_FrameWriter tail, CastUpdateAudioPayload update) {
  final flags = _computeAndValidateUpdateFlags(update);
  tail
    ..writeUint8(_audioKindUpdate)
    ..writeUint32(update.clipId)
    ..writeUint16(flags);
  if (update.volume case final volume?) tail.writeFloat64(volume);
  if (update.pan case final pan?) tail.writeFloat64(pan);
  if (update.seekPosition case final seek?) {
    tail.writeUint53(seek.inMicroseconds);
  }
  if (update.paused case final paused?) tail.writeUint8(paused ? 1 : 0);
  if (update.speed case final speed?) tail.writeFloat64(speed);
  if (update.preservePitch case final pp?) tail.writeUint8(pp ? 1 : 0);
  if (update.fadeVolumeTarget case final target?) {
    tail
      ..writeFloat64(target)
      ..writeUint53(update.fadeVolumeDuration!.inMicroseconds);
  }
  if (update.fadeSpeedTarget case final target?) {
    tail
      ..writeFloat64(target)
      ..writeUint53(update.fadeSpeedDuration!.inMicroseconds);
  }
  if (update.scheduleStopDuration case final stopDur?) {
    tail.writeUint53(stopDur.inMicroseconds);
  }
}

AudioFrame _decodeAudio(_FrameReader reader) {
  final sessionId = reader.readSessionId();
  try {
    final tailReader = _readAudioTailReader(reader);
    final payload = _readAudioPayload(tailReader);
    if (!tailReader.isAtEnd) {
      throw const ProtocolFormatException('Trailing bytes after audio body');
    }
    return AudioFrame(sessionId: sessionId, payload: payload);
  } on CorruptAudioFrameException {
    rethrow;
  } on ProtocolFormatException catch (e) {
    throw CorruptAudioFrameException(sessionId, e.message);
  }
}

_FrameReader _readAudioTailReader(_FrameReader reader) {
  final flag = reader.readUint8();
  if (flag == _compressionRaw) {
    final rem = reader.remainingBytes;
    if (rem <= 0 || rem > _maxAudioTailBytes) {
      throw ProtocolFormatException('Invalid raw audio tail length: $rem');
    }
    return _FrameReader(reader.readRemainingBytes());
  }
  if (flag != _compressionDeflateRaw) {
    throw ProtocolFormatException('Invalid audio compression flag: $flag');
  }
  final uncompressedLen = reader.readUint32();
  if (uncompressedLen <= 0 || uncompressedLen > _maxAudioTailBytes) {
    throw ProtocolFormatException(
      'Invalid uncompressed audio tail length: $uncompressedLen',
    );
  }
  final compressed = reader.readRemainingBytes();
  if (compressed.isEmpty || compressed.length > _maxAudioTailBytes) {
    throw ProtocolFormatException(
      'Invalid compressed audio tail length: ${compressed.length}',
    );
  }
  final Uint8List inflated;
  try {
    inflated = const ZLibDecoder().decodeBytes(
      compressed,
      raw: true,
      throwOnError: true,
      maxOutputSize: uncompressedLen,
    );
  } on Object catch (e) {
    throw ProtocolFormatException('Failed to inflate audio tail: $e');
  }
  if (inflated.length != uncompressedLen ||
      inflated.length > _maxAudioTailBytes) {
    throw ProtocolFormatException(
      'Inflated audio tail length ${inflated.length} != expected $uncompressedLen',
    );
  }
  return _FrameReader(inflated);
}

void _inspectRelayAudioTail(_FrameReader reader) {
  final flag = reader.readUint8();
  if (flag == _compressionRaw) {
    final rem = reader.remainingBytes;
    if (rem <= 0 || rem > _maxAudioTailBytes) {
      throw ProtocolFormatException('Invalid raw audio tail length: $rem');
    }
    _skipAudioPayload(reader);
    if (!reader.isAtEnd) {
      throw const ProtocolFormatException('Trailing bytes after audio body');
    }
    return;
  }
  if (flag != _compressionDeflateRaw) {
    throw ProtocolFormatException('Invalid audio compression flag: $flag');
  }
  final uncompressedLen = reader.readUint32();
  if (uncompressedLen <= 0 || uncompressedLen > _maxAudioTailBytes) {
    throw ProtocolFormatException(
      'Invalid uncompressed audio tail length: $uncompressedLen',
    );
  }
  final compressedLen = reader.remainingBytes;
  if (compressedLen <= 0 || compressedLen > _maxAudioTailBytes) {
    throw ProtocolFormatException(
      'Invalid compressed audio tail length: $compressedLen',
    );
  }
}

const Map<String, int> _busOpCodes = {
  'create': _busOpCreate,
  'destroy': _busOpDestroy,
  'vol': _busOpVol,
  'attach': _busOpAttach,
  'param': _busOpParam,
  'fade': _busOpFade,
};

void _validateBusFilterId(int? filterId) {
  if (filterId == null || filterId < 0 || filterId > _maxAudioFilterId) {
    throw ProtocolFormatException('Invalid audio bus filterId: $filterId');
  }
}

void _validateBusParamId(int? paramId) {
  if (paramId == null || paramId < 0 || paramId > _maxAudioParamId) {
    throw ProtocolFormatException('Invalid audio bus paramId: $paramId');
  }
}

void _validateBusFiniteValue(double? value) {
  if (value == null || !value.isFinite) {
    throw ProtocolFormatException('Invalid audio bus value: $value');
  }
}

void _writeBusAudio(_FrameWriter tail, CastBusAudioPayload bus) {
  _validatePositiveAudioId(bus.busId, label: 'busId');
  final opCode = _busOpCodes[bus.op];
  if (opCode == null) {
    throw ProtocolFormatException('Unsupported audio bus op: ${bus.op}');
  }
  tail
    ..writeUint8(_audioKindBus)
    ..writeUint8(opCode)
    ..writeUint32(bus.busId);
  switch (opCode) {
    case _busOpCreate || _busOpDestroy:
      if (bus.filterId != null ||
          bus.paramId != null ||
          bus.value != null ||
          bus.duration != null) {
        throw ProtocolFormatException(
          'Unexpected fields on audio bus ${bus.op}',
        );
      }
    case _busOpVol:
      if (bus.filterId != null || bus.paramId != null || bus.duration != null) {
        throw const ProtocolFormatException(
          'Unexpected fields on audio bus vol',
        );
      }
      _validateBusFiniteValue(bus.value);
      _validateAudioGainAndPan(volume: bus.value!, pan: 0.0);
      tail.writeFloat64(bus.value!);
    case _busOpAttach:
      if (bus.paramId != null || bus.value != null || bus.duration != null) {
        throw const ProtocolFormatException(
          'Unexpected fields on audio bus attach',
        );
      }
      _validateBusFilterId(bus.filterId);
      tail.writeUint8(bus.filterId!);
    case _busOpParam:
      if (bus.duration != null) {
        throw const ProtocolFormatException(
          'Unexpected duration on audio bus param',
        );
      }
      _validateBusFilterId(bus.filterId);
      _validateBusParamId(bus.paramId);
      _validateBusFiniteValue(bus.value);
      tail
        ..writeUint8(bus.filterId!)
        ..writeUint16(bus.paramId!)
        ..writeFloat64(bus.value!);
    case _busOpFade:
      _validateBusFilterId(bus.filterId);
      _validateBusParamId(bus.paramId);
      _validateBusFiniteValue(bus.value);
      final dur = bus.duration;
      if (dur == null) {
        throw const ProtocolFormatException(
          'Missing duration on audio bus fade',
        );
      }
      _validateAudioDurationMicros(
        dur.inMicroseconds,
        label: 'busFadeDuration',
      );
      tail
        ..writeUint8(bus.filterId!)
        ..writeUint16(bus.paramId!)
        ..writeFloat64(bus.value!)
        ..writeUint53(dur.inMicroseconds);
  }
}

CastAudioPayload _readAudioPayload(_FrameReader tail) {
  final kind = tail.readUint8();
  return switch (kind) {
    _audioKindTone => _readToneAudio(tail),
    _audioKindClip => _readClipAudio(tail),
    _audioKindStop => _readStopAudio(tail),
    _audioKindUpdate => _readUpdateAudio(tail),
    _audioKindBus => _readBusAudio(tail),
    _audioKindStream => _readStreamAudio(tail),
    _audioKindWaveQuery => _readWaveQueryAudio(tail),
    _ => throw ProtocolFormatException('Unknown audio payload kind: $kind'),
  };
}

CastWaveformQueryAudioPayload _readWaveQueryAudio(_FrameReader tail) {
  final requestId = tail.readUint32();
  _validatePositiveWaveQueryId(requestId);
  return CastWaveformQueryAudioPayload(requestId: requestId);
}

void _skipAudioPayload(_FrameReader reader) {
  final kind = reader.readUint8();
  switch (kind) {
    case _audioKindTone:
      _readToneAudio(reader);
    case _audioKindClip:
      _skipClipAudio(reader);
    case _audioKindStop:
      _readStopAudio(reader);
    case _audioKindUpdate:
      _readUpdateAudio(reader);
    case _audioKindBus:
      _readBusAudio(reader);
    case _audioKindStream:
      _skipStreamAudio(reader);
    case _audioKindWaveQuery:
      _readWaveQueryAudio(reader);
    default:
      reader.skip(reader.remainingBytes);
  }
}

CastToneAudioPayload _readToneAudio(_FrameReader tail) {
  final waveform = tail.readString16(maxBytes: _maxAudioWaveformBytes);
  if (!_validAudioWaveforms.contains(waveform)) {
    throw ProtocolFormatException('Unsupported audio waveform: $waveform');
  }
  final frequencyHz = tail.readFloat64();
  final durationMicros = tail.readUint53();
  final volume = tail.readFloat64();
  final pan = tail.readFloat64();
  _validateAudioToneNumbers(
    frequencyHz: frequencyHz,
    durationMicros: durationMicros,
    volume: volume,
    pan: pan,
  );
  final rawBusId = tail.readUint32();
  return CastToneAudioPayload(
    waveform: waveform,
    frequencyHz: frequencyHz,
    duration: Duration(microseconds: durationMicros),
    volume: volume,
    pan: pan,
    busId: rawBusId == 0 ? null : rawBusId,
  );
}

({
  int clipId,
  String format,
  double volume,
  double pan,
  bool loop,
  Duration startOffset,
  int? busId,
  int? streamId,
  int byteLen,
})
_readValidatedClipHeader(_FrameReader tail) {
  final clipId = tail.readUint32();
  _validatePositiveAudioId(clipId);
  final format = tail.readString16(maxBytes: _maxAudioFormatBytes);
  final volume = tail.readFloat64();
  final pan = tail.readFloat64();
  _validateAudioGainAndPan(volume: volume, pan: pan);
  final rawLoop = tail.readUint8();
  if (rawLoop != 0 && rawLoop != 1) {
    throw ProtocolFormatException('Invalid audio loop flag: $rawLoop');
  }
  final startOffsetMicros = tail.readUint53();
  _validateAudioDurationMicros(startOffsetMicros, label: 'startOffset');
  final rawBusId = tail.readUint32();
  final rawStreamId = tail.readUint32();
  final byteLen = tail.readUint32();
  _validateClipFormatAndLength(
    format: format,
    streamId: rawStreamId,
    byteLen: byteLen,
  );
  return (
    clipId: clipId,
    format: format,
    volume: volume,
    pan: pan,
    loop: rawLoop == 1,
    startOffset: Duration(microseconds: startOffsetMicros),
    busId: rawBusId == 0 ? null : rawBusId,
    streamId: rawStreamId == 0 ? null : rawStreamId,
    byteLen: byteLen,
  );
}

void _validateClipFormatAndLength({
  required String format,
  required int streamId,
  required int byteLen,
}) {
  if (streamId == 0) {
    if (!_validAudioFormats.contains(format)) {
      throw ProtocolFormatException('Unsupported audio format: $format');
    }
    if (byteLen == 0 || byteLen > CastAudioPayload.maxClipBytes) {
      throw ProtocolFormatException('Invalid audio clip byte length: $byteLen');
    }
    return;
  }
  if (format.isNotEmpty && !_validAudioFormats.contains(format)) {
    throw ProtocolFormatException('Unsupported audio format: $format');
  }
  if (byteLen != 0) {
    throw ProtocolFormatException(
      'Stream clip must have 0 inline bytes, got $byteLen',
    );
  }
}

CastClipAudioPayload _readClipAudio(_FrameReader tail) {
  final header = _readValidatedClipHeader(tail);
  final bytes = tail.readFixedBytes(header.byteLen);
  return CastClipAudioPayload(
    clipId: header.clipId,
    format: header.format,
    bytes: bytes,
    volume: header.volume,
    pan: header.pan,
    loop: header.loop,
    startOffset: header.startOffset,
    busId: header.busId,
    streamId: header.streamId,
  );
}

CastBusAudioPayload _readBusAudio(_FrameReader tail) {
  final opCode = tail.readUint8();
  final busId = tail.readUint32();
  _validatePositiveAudioId(busId, label: 'busId');
  switch (opCode) {
    case _busOpCreate:
      return CastBusAudioPayload(op: 'create', busId: busId);
    case _busOpDestroy:
      return CastBusAudioPayload(op: 'destroy', busId: busId);
    case _busOpVol:
      final vol = tail.readFloat64();
      _validateBusFiniteValue(vol);
      _validateAudioGainAndPan(volume: vol, pan: 0.0);
      return CastBusAudioPayload(op: 'vol', busId: busId, value: vol);
    case _busOpAttach:
      final filterId = tail.readUint8();
      _validateBusFilterId(filterId);
      return CastBusAudioPayload(
        op: 'attach',
        busId: busId,
        filterId: filterId,
      );
    case _busOpParam:
      final filterId = tail.readUint8();
      _validateBusFilterId(filterId);
      final paramId = tail.readUint16();
      _validateBusParamId(paramId);
      final value = tail.readFloat64();
      _validateBusFiniteValue(value);
      return CastBusAudioPayload(
        op: 'param',
        busId: busId,
        filterId: filterId,
        paramId: paramId,
        value: value,
      );
    case _busOpFade:
      final filterId = tail.readUint8();
      _validateBusFilterId(filterId);
      final paramId = tail.readUint16();
      _validateBusParamId(paramId);
      final value = tail.readFloat64();
      _validateBusFiniteValue(value);
      final duration = _readAudioDuration(tail, 'busFadeDuration');
      return CastBusAudioPayload(
        op: 'fade',
        busId: busId,
        filterId: filterId,
        paramId: paramId,
        value: value,
        duration: duration,
      );
    default:
      throw ProtocolFormatException('Unknown audio bus op code: $opCode');
  }
}

void _skipClipAudio(_FrameReader reader) {
  final header = _readValidatedClipHeader(reader);
  reader.skip(header.byteLen);
}

const Map<String, int> _streamOpCodes = {
  'open': _streamOpOpen,
  'chunk': _streamOpChunk,
  'end': _streamOpEnd,
};

void _writeStreamAudio(_FrameWriter tail, CastStreamAudioPayload stream) {
  _validatePositiveAudioId(stream.streamId, label: 'streamId');
  final opCode = _streamOpCodes[stream.op];
  if (opCode == null) {
    throw ProtocolFormatException('Unsupported audio stream op: ${stream.op}');
  }
  tail
    ..writeUint8(_audioKindStream)
    ..writeUint8(opCode)
    ..writeUint32(stream.streamId);
  switch (opCode) {
    case _streamOpOpen:
      _writeStreamOpenFields(tail, stream);
    case _streamOpChunk:
      _writeStreamChunkFields(tail, stream);
    case _streamOpEnd:
      _writeStreamEndFields(tail, stream);
  }
}

void _writeStreamOpenFields(_FrameWriter tail, CastStreamAudioPayload stream) {
  if (stream.seq != null || stream.chunkBytes != null) {
    throw const ProtocolFormatException(
      'Unexpected fields on audio stream open',
    );
  }
  final maxBuf = stream.maxBufferSize;
  final rel = stream.releaseConsumed;
  final bufTime = stream.bufferingTimeNeeds;
  final sr = stream.sampleRate;
  final ch = stream.channels;
  if (maxBuf == null ||
      maxBuf <= 0 ||
      maxBuf > CastStreamAudioPayload.maxStreamBufferBytes ||
      rel == null ||
      bufTime == null ||
      bufTime.inMicroseconds < 0 ||
      bufTime.inMicroseconds > _maxStreamBufferingMicros ||
      sr == null ||
      sr <= 0 ||
      sr > _maxStreamSampleRate ||
      (ch != 1 && ch != 2)) {
    throw const ProtocolFormatException('Invalid audio stream open parameters');
  }
  tail
    ..writeUint32(maxBuf)
    ..writeUint8(rel ? 1 : 0)
    ..writeUint53(bufTime.inMicroseconds)
    ..writeUint32(sr)
    ..writeUint8(ch!);
}

void _writeStreamChunkFields(_FrameWriter tail, CastStreamAudioPayload stream) {
  if (stream.maxBufferSize != null ||
      stream.releaseConsumed != null ||
      stream.bufferingTimeNeeds != null ||
      stream.sampleRate != null ||
      stream.channels != null) {
    throw const ProtocolFormatException(
      'Unexpected open fields on audio stream chunk',
    );
  }
  final seq = stream.seq;
  final bytes = stream.chunkBytes;
  if (seq == null ||
      seq < 0 ||
      seq > 0xFFFFFFFF ||
      bytes == null ||
      bytes.isEmpty ||
      bytes.length > CastAudioPayload.maxClipBytes) {
    throw const ProtocolFormatException('Invalid audio stream chunk payload');
  }
  tail
    ..writeUint32(seq)
    ..writeBytes32(bytes);
}

void _writeStreamEndFields(_FrameWriter tail, CastStreamAudioPayload stream) {
  if (stream.maxBufferSize != null ||
      stream.releaseConsumed != null ||
      stream.bufferingTimeNeeds != null ||
      stream.sampleRate != null ||
      stream.channels != null ||
      stream.chunkBytes != null) {
    throw const ProtocolFormatException(
      'Unexpected fields on audio stream end',
    );
  }
  final seq = stream.seq;
  if (seq != null && (seq < 0 || seq > 0xFFFFFFFF)) {
    throw ProtocolFormatException('Invalid audio stream end seq: $seq');
  }
  tail.writeUint8(seq != null ? 1 : 0);
  if (seq != null) {
    tail.writeUint32(seq);
  }
}

CastStreamAudioPayload _readStreamAudio(_FrameReader tail) {
  final opCode = tail.readUint8();
  final streamId = tail.readUint32();
  _validatePositiveAudioId(streamId, label: 'streamId');
  return switch (opCode) {
    _streamOpOpen => _readStreamOpenPayload(tail, streamId),
    _streamOpChunk => _readStreamChunkPayload(tail, streamId),
    _streamOpEnd => _readStreamEndPayload(tail, streamId),
    _ => throw ProtocolFormatException('Unknown audio stream op code: $opCode'),
  };
}

CastStreamAudioPayload _readStreamOpenPayload(_FrameReader tail, int streamId) {
  final maxBuf = tail.readUint32();
  if (maxBuf <= 0 || maxBuf > CastStreamAudioPayload.maxStreamBufferBytes) {
    throw ProtocolFormatException('Invalid stream maxBufferSize: $maxBuf');
  }
  final rel = _readAudioBoolByte(tail, 'releaseConsumed');
  final bufMicros = tail.readUint53();
  if (bufMicros < 0 || bufMicros > _maxStreamBufferingMicros) {
    throw ProtocolFormatException(
      'Invalid stream buffering micros: $bufMicros',
    );
  }
  final sr = tail.readUint32();
  if (sr <= 0 || sr > _maxStreamSampleRate) {
    throw ProtocolFormatException('Invalid stream sampleRate: $sr');
  }
  final ch = tail.readUint8();
  if (ch != 1 && ch != 2) {
    throw ProtocolFormatException('Invalid stream channels: $ch');
  }
  return CastStreamAudioPayload(
    op: 'open',
    streamId: streamId,
    maxBufferSize: maxBuf,
    releaseConsumed: rel,
    bufferingTimeNeeds: Duration(microseconds: bufMicros),
    sampleRate: sr,
    channels: ch,
  );
}

({int seq, int byteLen}) _readValidatedStreamChunkHeader(_FrameReader tail) {
  final seq = tail.readUint32();
  final byteLen = tail.readUint32();
  if (byteLen == 0 || byteLen > CastAudioPayload.maxClipBytes) {
    throw ProtocolFormatException('Invalid stream chunk byte length: $byteLen');
  }
  return (seq: seq, byteLen: byteLen);
}

CastStreamAudioPayload _readStreamChunkPayload(
  _FrameReader tail,
  int streamId,
) {
  final header = _readValidatedStreamChunkHeader(tail);
  final bytes = tail.readFixedBytes(header.byteLen);
  return CastStreamAudioPayload(
    op: 'chunk',
    streamId: streamId,
    seq: header.seq,
    chunkBytes: bytes,
  );
}

CastStreamAudioPayload _readStreamEndPayload(_FrameReader tail, int streamId) {
  final hasSeq = _readAudioBoolByte(tail, 'hasSeq');
  final seq = hasSeq ? tail.readUint32() : null;
  return CastStreamAudioPayload(op: 'end', streamId: streamId, seq: seq);
}

void _skipStreamAudio(_FrameReader reader) {
  final opCode = reader.readUint8();
  final streamId = reader.readUint32();
  _validatePositiveAudioId(streamId, label: 'streamId');
  switch (opCode) {
    case _streamOpOpen:
      _readStreamOpenPayload(reader, streamId);
    case _streamOpChunk:
      final header = _readValidatedStreamChunkHeader(reader);
      reader.skip(header.byteLen);
    case _streamOpEnd:
      _readStreamEndPayload(reader, streamId);
    default:
      throw ProtocolFormatException('Unknown audio stream op code: $opCode');
  }
}

CastStopAudioPayload _readStopAudio(_FrameReader tail) {
  final rawHasId = tail.readUint8();
  if (rawHasId != 0 && rawHasId != 1) {
    throw ProtocolFormatException('Invalid audio stop hasClipId: $rawHasId');
  }
  if (rawHasId == 0) {
    return const CastStopAudioPayload();
  }
  final clipId = tail.readUint32();
  _validatePositiveAudioId(clipId);
  return CastStopAudioPayload(clipId: clipId);
}

bool _readAudioBoolByte(_FrameReader tail, String label) {
  final raw = tail.readUint8();
  if (raw != 0 && raw != 1) {
    throw ProtocolFormatException('Invalid audio $label byte: $raw');
  }
  return raw == 1;
}

Duration _readAudioDuration(_FrameReader tail, String label) {
  final micros = tail.readUint53();
  _validateAudioDurationMicros(micros, label: label);
  return Duration(microseconds: micros);
}

CastUpdateAudioPayload _readUpdateAudio(_FrameReader tail) {
  final clipId = tail.readUint32();
  _validatePositiveAudioId(clipId);
  final flags = tail.readUint16();
  if (flags == 0 || (flags & ~_audioUpdateFlagsMask) != 0) {
    throw ProtocolFormatException('Invalid audio update flags: $flags');
  }
  final volume = (flags & _audioUpdateFlagVolume) != 0
      ? tail.readFloat64()
      : null;
  final pan = (flags & _audioUpdateFlagPan) != 0 ? tail.readFloat64() : null;
  _validateAudioGainAndPan(volume: volume ?? 1.0, pan: pan ?? 0.0);
  final seekPosition = (flags & _audioUpdateFlagSeek) != 0
      ? _readAudioDuration(tail, 'seekPosition')
      : null;
  final paused = (flags & _audioUpdateFlagPaused) != 0
      ? _readAudioBoolByte(tail, 'paused')
      : null;
  final speed = (flags & _audioUpdateFlagSpeed) != 0
      ? tail.readFloat64()
      : null;
  if (speed != null) _validateAudioSpeed(speed);
  final preservePitch = (flags & _audioUpdateFlagPreservePitch) != 0
      ? _readAudioBoolByte(tail, 'preservePitch')
      : null;
  double? fadeVolumeTarget;
  Duration? fadeVolumeDuration;
  if ((flags & _audioUpdateFlagFadeVolume) != 0) {
    fadeVolumeTarget = tail.readFloat64();
    _validateAudioGainAndPan(volume: fadeVolumeTarget, pan: 0.0);
    fadeVolumeDuration = _readAudioDuration(tail, 'fadeVolumeDuration');
  }
  double? fadeSpeedTarget;
  Duration? fadeSpeedDuration;
  if ((flags & _audioUpdateFlagFadeSpeed) != 0) {
    fadeSpeedTarget = tail.readFloat64();
    _validateAudioSpeed(fadeSpeedTarget);
    fadeSpeedDuration = _readAudioDuration(tail, 'fadeSpeedDuration');
  }
  final scheduleStopDuration = (flags & _audioUpdateFlagScheduleStop) != 0
      ? _readAudioDuration(tail, 'scheduleStopDuration')
      : null;
  return CastUpdateAudioPayload(
    clipId: clipId,
    volume: volume,
    pan: pan,
    seekPosition: seekPosition,
    paused: paused,
    speed: speed,
    preservePitch: preservePitch,
    fadeVolumeTarget: fadeVolumeTarget,
    fadeVolumeDuration: fadeVolumeDuration,
    fadeSpeedTarget: fadeSpeedTarget,
    fadeSpeedDuration: fadeSpeedDuration,
    scheduleStopDuration: scheduleStopDuration,
  );
}

void _validatePositiveAudioId(int clipId, {String label = 'clipId'}) {
  if (clipId <= 0 || clipId > 0xFFFFFFFF) {
    throw ProtocolFormatException('Invalid audio $label: $clipId');
  }
}

void _validateAudioDurationMicros(int micros, {required String label}) {
  if (micros < 0 || micros > _maxAudioSeekMicros) {
    throw ProtocolFormatException('Invalid audio $label micros: $micros');
  }
}

void _validateAudioSpeed(double speed) {
  if (!speed.isFinite || speed < _minAudioSpeed || speed > _maxAudioSpeed) {
    throw ProtocolFormatException('Invalid audio speed: $speed');
  }
}

void _validateAudioGainAndPan({required double volume, required double pan}) {
  if (!volume.isFinite || volume < 0.0 || volume > 1.0) {
    throw ProtocolFormatException('Invalid audio volume: $volume');
  }
  if (!pan.isFinite || pan < -1.0 || pan > 1.0) {
    throw ProtocolFormatException('Invalid audio pan: $pan');
  }
}

const double _minAudioFrequencyHz = 1.0;
const double _maxAudioFrequencyHz = 24000.0;
const int _maxAudioDurationMicros = 60000000;

void _validateAudioToneNumbers({
  required double frequencyHz,
  required int durationMicros,
  required double volume,
  required double pan,
}) {
  if (!frequencyHz.isFinite ||
      frequencyHz < _minAudioFrequencyHz ||
      frequencyHz > _maxAudioFrequencyHz) {
    throw ProtocolFormatException('Invalid audio frequencyHz: $frequencyHz');
  }
  if (durationMicros < 0 || durationMicros > _maxAudioDurationMicros) {
    throw ProtocolFormatException(
      'Invalid audio durationMicros: $durationMicros',
    );
  }
  _validateAudioGainAndPan(volume: volume, pan: pan);
}

void _validateTitleText(String title) {
  if (title.isEmpty || title != title.trim()) {
    throw const ProtocolFormatException(
      'Session title must be trimmed and non-empty',
    );
  }
  if (_disallowedTitleChars.hasMatch(title)) {
    throw const ProtocolFormatException(
      'Session title contains control or bidi override characters',
    );
  }
}

Uint8List _encodeValidatedTitle(String title) {
  _validateTitleText(title);
  final encoded = utf8.encode(title);
  if (encoded.length > _maxTitleBytes) {
    throw ProtocolFormatException(
      'Session title exceeds $_maxTitleBytes UTF-8 bytes: ${encoded.length}',
    );
  }
  return encoded;
}

void _checkDeltaSeqOrder(int baseSeq, int seq) {
  if (baseSeq >= seq) {
    throw ProtocolFormatException(
      'Delta baseSeq $baseSeq must precede seq $seq',
    );
  }
}

void _checkGridDims(int cols, int rows) {
  if (cols <= 0 ||
      cols > BufferFrameCodec.maxGridCols ||
      rows <= 0 ||
      rows > BufferFrameCodec.maxGridRows) {
    throw ProtocolFormatException(
      'Grid dimensions out of range: ${cols}x$rows',
    );
  }
}

void _encodeRegister(_FrameWriter writer, RegisterSessionFrame frame) {
  _checkGridDims(frame.cols, frame.rows);
  writer
    ..writeUint8(_tagRegisterSession)
    ..writeSessionId(frame.sessionId)
    ..writeTitle(frame.title)
    ..writeUint16(frame.cols)
    ..writeUint16(frame.rows)
    ..writeFixedBytes(
      frame.resumeToken,
      expectedLength: RegisterSessionFrame.resumeTokenByteLength,
      label: 'resumeToken',
    );
  if (frame.allowSpawn) {
    writer.writeUint8(_registerFlagAllowSpawn);
  }
}

RegisterSessionFrame _decodeRegister(_FrameReader reader) {
  final sessionId = reader.readSessionId();
  final title = reader.readTitle();
  final cols = reader.readUint16();
  final rows = reader.readUint16();
  _checkGridDims(cols, rows);
  final resumeToken = reader.readFixedBytes(
    RegisterSessionFrame.resumeTokenByteLength,
  );
  final registerFlags = _readOptionalRegisterFlags(reader);
  return RegisterSessionFrame(
    sessionId: sessionId,
    title: title,
    cols: cols,
    rows: rows,
    resumeToken: resumeToken,
    allowSpawn: (registerFlags & _registerFlagAllowSpawn) != 0,
  );
}

int _readOptionalRegisterFlags(_FrameReader reader) {
  if (reader.isAtEnd) return 0;
  final flags = reader.readUint8();
  if ((flags & ~_registerFlagAllowSpawn) != 0) {
    throw ProtocolFormatException(
      'Invalid RegisterSessionFrame flags byte: $flags',
    );
  }
  return flags;
}

AuthAcceptedFrame _decodeAuthAccepted(_FrameReader reader) {
  final role = _decodeRole(reader.readUint8());
  final capFlags = _readOptionalCapFlags(reader, 'AuthAcceptedFrame');
  return AuthAcceptedFrame(
    role: role,
    shaderFrames: (capFlags & _capFlagShaderFrames) != 0,
  );
}

SubscribeSessionFrame _decodeSubscribe(_FrameReader reader) {
  final sessionId = reader.readSessionId();
  final cols = reader.readUint16();
  final rows = reader.readUint16();
  if (cols != 0 || rows != 0) _checkGridDims(cols, rows);
  final capFlags = _readOptionalCapFlags(reader, 'SubscribeSessionFrame');
  return SubscribeSessionFrame(
    sessionId: sessionId,
    cols: cols,
    rows: rows,
    shaderFrames: (capFlags & _capFlagShaderFrames) != 0,
  );
}

int _readOptionalCapFlags(_FrameReader reader, String frameName) {
  if (reader.isAtEnd) return 0;
  final capFlags = reader.readUint8();
  if ((capFlags & ~_capFlagShaderFrames) != 0) {
    throw ProtocolFormatException(
      'Invalid $frameName capability flags byte: $capFlags',
    );
  }
  return capFlags;
}

void _validateShaderId(String id, String label) {
  if (!_shaderIdPattern.hasMatch(id)) {
    throw ProtocolFormatException('Invalid shader $label: "$id"');
  }
}

void _writeFloat32Array(_FrameWriter writer, Float32List values) {
  if (values.length != ShaderRegion.paramCount) {
    throw ProtocolFormatException(
      'Expected ${ShaderRegion.paramCount} shader params, got ${values.length}',
    );
  }
  final buf = Uint8List(ShaderRegion.paramCount * 4);
  final view = ByteData.sublistView(buf);
  for (var i = 0; i < ShaderRegion.paramCount; i++) {
    final v = values[i];
    if (!v.isFinite) {
      throw ProtocolFormatException('Non-finite shader param at $i: $v');
    }
    view.setFloat32(
      i * 4,
      v
          .clamp(ShaderRegion.minParamValue, ShaderRegion.maxParamValue)
          .toDouble(),
      Endian.little,
    );
  }
  writer.writeRawBytes(buf);
}

Float32List _readFloat32Array(_FrameReader reader) {
  final raw = reader.readFixedBytes(ShaderRegion.paramCount * 4);
  final view = ByteData.sublistView(raw);
  final out = Float32List(ShaderRegion.paramCount);
  for (var i = 0; i < ShaderRegion.paramCount; i++) {
    final v = view.getFloat32(i * 4, Endian.little);
    if (!v.isFinite) {
      throw ProtocolFormatException('Non-finite decoded shader param at $i');
    }
    out[i] = v
        .clamp(ShaderRegion.minParamValue, ShaderRegion.maxParamValue)
        .toDouble();
  }
  return out;
}

void _encodeShaderFrame(_FrameWriter writer, ShaderFrame frame) {
  writer
    ..writeUint8(_tagShader)
    ..writeSessionId(frame.sessionId);
  switch (frame.payload) {
    case CastDefineShaderPayload():
      _encodeDefineShader(writer, frame.payload as CastDefineShaderPayload);
    case CastRegionShaderPayload():
      _encodeRegionShader(writer, frame.payload as CastRegionShaderPayload);
    case CastTransformsShaderPayload():
      _encodeTransformsShader(
        writer,
        frame.payload as CastTransformsShaderPayload,
      );
    case CastSetShaderPayload():
      _encodeSetShader(writer, frame.payload as CastSetShaderPayload);
    case CastUniformShaderPayload():
      _encodeUniformShader(writer, frame.payload as CastUniformShaderPayload);
    case CastResetShaderPayload():
      _encodeResetShader(writer, frame.payload as CastResetShaderPayload);
  }
}

void _encodeDefineShader(_FrameWriter writer, CastDefineShaderPayload payload) {
  _validateShaderId(payload.id, 'id');
  final srcBytes = utf8.encode(payload.glslSource);
  if (srcBytes.isEmpty ||
      srcBytes.length > CastShaderPayload.maxGlslBytes ||
      payload.glslSource.contains('\x00')) {
    throw ProtocolFormatException(
      'Invalid CLI GLSL byte length: ${srcBytes.length}',
    );
  }
  writer
    ..writeUint8(_shaderKindDefine)
    ..writeString16(payload.id, maxBytes: _maxShaderIdBytes)
    ..writeUint8(payload.persist ? 1 : 0)
    ..writeUint16(srcBytes.length)
    ..writeRawBytes(srcBytes);
}

void _encodeRegionShader(_FrameWriter writer, CastRegionShaderPayload payload) {
  _validateShaderId(payload.id, 'id');
  if (payload.remove) {
    writer
      ..writeUint8(_shaderKindRegion)
      ..writeString16(payload.id, maxBytes: _maxShaderIdBytes)
      ..writeUint8(1);
    return;
  }
  final region = payload.region;
  if (region == null ||
      region.id != payload.id ||
      region.sourceRects.isEmpty ||
      region.sourceRects.length > _maxShaderRectsPerRegion) {
    throw ProtocolFormatException(
      'Invalid CastRegionShaderPayload for "${payload.id}"',
    );
  }
  _validateShaderId(region.shaderId, 'shaderId');
  final pad = region.padding.clamped();
  writer
    ..writeUint8(_shaderKindRegion)
    ..writeString16(payload.id, maxBytes: _maxShaderIdBytes)
    ..writeUint8(0)
    ..writeString16(region.shaderId, maxBytes: _maxShaderIdBytes)
    ..writeUint8(region.stage.code)
    ..writeInt32(region.zIndex)
    ..writeUint8(region.persist ? 1 : 0)
    ..writeUint8(pad.top)
    ..writeUint8(pad.right)
    ..writeUint8(pad.bottom)
    ..writeUint8(pad.left)
    ..writeUint8(region.sourceRects.length);
  for (final rect in region.sourceRects) {
    if (rect.x < 0 ||
        rect.y < 0 ||
        rect.width <= 0 ||
        rect.height <= 0 ||
        rect.x > 0xFFFF ||
        rect.y > 0xFFFF ||
        rect.width > 0xFFFF ||
        rect.height > 0xFFFF) {
      throw ProtocolFormatException('Invalid ShaderRegion rect: $rect');
    }
    writer
      ..writeUint16(rect.x)
      ..writeUint16(rect.y)
      ..writeUint16(rect.width)
      ..writeUint16(rect.height);
  }
  _writeFloat32Array(writer, region.params);
}

void _encodeTransformsShader(
  _FrameWriter writer,
  CastTransformsShaderPayload payload,
) {
  final packed = CellTransformCodec.packBatch(payload.entries);
  if (packed.length > CastShaderPayload.maxWireBytes - 64) {
    throw ProtocolFormatException(
      'CastTransformsShaderPayload exceeds single-frame 64 KiB cap: ${packed.length} bytes',
    );
  }
  writer
    ..writeUint8(_shaderKindTransforms)
    ..writeUint8(payload.replace ? 1 : 0)
    ..writeUint16(payload.entries.length)
    ..writeRawBytes(packed);
}

void _encodeSetShader(_FrameWriter writer, CastSetShaderPayload payload) {
  if (!_validShaderStages.contains(payload.stage)) {
    throw ProtocolFormatException('Invalid shader stage: ${payload.stage}');
  }
  if (!payload.clear) {
    final hasPreset = payload.presetId != null;
    final hasShader = payload.shaderId != null;
    if (!hasPreset && !hasShader) {
      throw const ProtocolFormatException(
        'CastSetShaderPayload requires presetId or shaderId when clear is false',
      );
    }
    if (hasPreset) _validateShaderId(payload.presetId!, 'presetId');
    if (hasShader) _validateShaderId(payload.shaderId!, 'shaderId');
  }
  writer
    ..writeUint8(_shaderKindSet)
    ..writeString16(payload.stage, maxBytes: 16)
    ..writeUint8(payload.clear ? 1 : 0)
    ..writeString16(payload.presetId ?? '', maxBytes: _maxShaderIdBytes)
    ..writeString16(payload.shaderId ?? '', maxBytes: _maxShaderIdBytes);
  _writeFloat32Array(writer, payload.params);
}

void _encodeUniformShader(
  _FrameWriter writer,
  CastUniformShaderPayload payload,
) {
  if (payload.id != null) _validateShaderId(payload.id!, 'id');
  if (payload.paramMask <= 0 || payload.paramMask > 0xFF) {
    throw ProtocolFormatException(
      'Invalid CastUniformShaderPayload paramMask: ${payload.paramMask}',
    );
  }
  writer
    ..writeUint8(_shaderKindUniform)
    ..writeString16(payload.id ?? '', maxBytes: _maxShaderIdBytes)
    ..writeUint8(payload.paramMask);
  _writeFloat32Array(writer, payload.params);
}

void _encodeResetShader(_FrameWriter writer, CastResetShaderPayload payload) {
  if (!_validShaderResetTargets.contains(payload.target)) {
    throw ProtocolFormatException(
      'Invalid CastResetShaderPayload target: ${payload.target}',
    );
  }
  writer
    ..writeUint8(_shaderKindReset)
    ..writeString16(payload.target, maxBytes: 16);
}

ShaderFrame _decodeShaderFrame(_FrameReader reader) {
  if (reader._bytes.length > BufferFrameCodec.maxShaderFrameBytes) {
    throw ProtocolFormatException(
      'ShaderFrame exceeds ${BufferFrameCodec.maxShaderFrameBytes} bytes: ${reader._bytes.length}',
    );
  }
  final sessionId = reader.readSessionId();
  try {
    final payload = _decodeShaderPayload(reader);
    if (!reader.isAtEnd) {
      throw const ProtocolFormatException('Trailing bytes after ShaderFrame');
    }
    return ShaderFrame(sessionId: sessionId, payload: payload);
  } on ProtocolFormatException catch (e) {
    throw CorruptSessionFrameException(sessionId, e.message);
  }
}

CastShaderPayload _decodeShaderPayload(_FrameReader reader) {
  final kind = reader.readUint8();
  return switch (kind) {
    _shaderKindDefine => _decodeDefineShader(reader),
    _shaderKindRegion => _decodeRegionShader(reader),
    _shaderKindTransforms => _decodeTransformsShader(reader),
    _shaderKindSet => _decodeSetShader(reader),
    _shaderKindUniform => _decodeUniformShader(reader),
    _shaderKindReset => _decodeResetShader(reader),
    _ => throw ProtocolFormatException('Unknown ShaderFrame kind: $kind'),
  };
}

CastDefineShaderPayload _decodeDefineShader(_FrameReader reader) {
  final id = reader.readString16(maxBytes: _maxShaderIdBytes);
  _validateShaderId(id, 'id');
  final persist = _readAudioBoolByte(reader, 'shader.persist');
  final glsl = reader.readString16(maxBytes: CastShaderPayload.maxGlslBytes);
  if (glsl.isEmpty || glsl.contains('\x00')) {
    throw const ProtocolFormatException('Invalid CLI GLSL source payload');
  }
  return CastDefineShaderPayload(id: id, glslSource: glsl, persist: persist);
}

CastRegionShaderPayload _decodeRegionShader(_FrameReader reader) {
  final id = reader.readString16(maxBytes: _maxShaderIdBytes);
  _validateShaderId(id, 'id');
  final remove = _readAudioBoolByte(reader, 'shader.regionRemove');
  if (remove) {
    return CastRegionShaderPayload(id: id, remove: true);
  }
  final shaderId = reader.readString16(maxBytes: _maxShaderIdBytes);
  _validateShaderId(shaderId, 'shaderId');
  final stageCode = reader.readUint8();
  final stage = ShaderRegionStage.fromCode(stageCode);
  if (stage == null) {
    throw ProtocolFormatException('Invalid ShaderRegionStage code: $stageCode');
  }
  final zIndex = reader.readInt32();
  final persist = _readAudioBoolByte(reader, 'shader.regionPersist');
  final padTop = reader.readUint8();
  final padRight = reader.readUint8();
  final padBottom = reader.readUint8();
  final padLeft = reader.readUint8();
  if (padTop > CellPadding.maxPadding ||
      padRight > CellPadding.maxPadding ||
      padBottom > CellPadding.maxPadding ||
      padLeft > CellPadding.maxPadding) {
    throw ProtocolFormatException(
      'ShaderRegion padding exceeds ${CellPadding.maxPadding}',
    );
  }
  final rectCount = reader.readUint8();
  if (rectCount == 0 || rectCount > _maxShaderRectsPerRegion) {
    throw ProtocolFormatException('Invalid ShaderRegion rectCount: $rectCount');
  }
  final rects = <Rect>[];
  for (var i = 0; i < rectCount; i++) {
    final x = reader.readUint16();
    final y = reader.readUint16();
    final w = reader.readUint16();
    final h = reader.readUint16();
    if (w == 0 || h == 0) {
      throw ProtocolFormatException('Empty ShaderRegion rect at $i');
    }
    rects.add(Rect(x, y, w, h));
  }
  final params = _readFloat32Array(reader);
  return CastRegionShaderPayload(
    id: id,
    region: ShaderRegion(
      id: id,
      shaderId: shaderId,
      sourceRects: rects,
      padding: CellPadding(
        top: padTop,
        right: padRight,
        bottom: padBottom,
        left: padLeft,
      ),
      stage: stage,
      zIndex: zIndex,
      persist: persist,
      params: params,
    ),
  );
}

CastTransformsShaderPayload _decodeTransformsShader(_FrameReader reader) {
  final replace = _readAudioBoolByte(reader, 'shader.xformsReplace');
  final count = reader.readUint16();
  final byteLen = count * CellTransformCodec.strideBytes;
  if (byteLen > CastShaderPayload.maxWireBytes) {
    throw ProtocolFormatException(
      'Shader transform batch exceeds 64 KiB: $byteLen bytes',
    );
  }
  final raw = reader.readFixedBytes(byteLen);
  final List<CellTransformEntry> entries;
  try {
    entries = CellTransformCodec.unpackBatch(raw);
  } on FormatException catch (e) {
    throw ProtocolFormatException('Invalid packed transforms: ${e.message}');
  }
  return CastTransformsShaderPayload(entries: entries, replace: replace);
}

CastSetShaderPayload _decodeSetShader(_FrameReader reader) {
  final stage = reader.readString16(maxBytes: 16);
  if (!_validShaderStages.contains(stage)) {
    throw ProtocolFormatException('Invalid shader stage: $stage');
  }
  final clear = _readAudioBoolByte(reader, 'shader.setClear');
  final rawPreset = reader.readString16(maxBytes: _maxShaderIdBytes);
  final rawShader = reader.readString16(maxBytes: _maxShaderIdBytes);
  final presetId = rawPreset.isEmpty ? null : rawPreset;
  final shaderId = rawShader.isEmpty ? null : rawShader;
  if (!clear) {
    if (presetId == null && shaderId == null) {
      throw const ProtocolFormatException(
        'CastSetShaderPayload missing presetId and shaderId',
      );
    }
    if (presetId != null) _validateShaderId(presetId, 'presetId');
    if (shaderId != null) _validateShaderId(shaderId, 'shaderId');
  }
  final params = _readFloat32Array(reader);
  return CastSetShaderPayload(
    stage: stage,
    presetId: presetId,
    shaderId: shaderId,
    params: params,
    clear: clear,
  );
}

CastUniformShaderPayload _decodeUniformShader(_FrameReader reader) {
  final rawId = reader.readString16(maxBytes: _maxShaderIdBytes);
  final id = rawId.isEmpty ? null : rawId;
  if (id != null) _validateShaderId(id, 'id');
  final paramMask = reader.readUint8();
  if (paramMask == 0) {
    throw const ProtocolFormatException('CastUniformShaderPayload mask is 0');
  }
  final params = _readFloat32Array(reader);
  return CastUniformShaderPayload(id: id, paramMask: paramMask, params: params);
}

CastResetShaderPayload _decodeResetShader(_FrameReader reader) {
  final target = reader.readString16(maxBytes: 16);
  if (!_validShaderResetTargets.contains(target)) {
    throw ProtocolFormatException('Invalid shader reset target: $target');
  }
  return CastResetShaderPayload(target: target);
}

ResizeFrame _decodeResize(_FrameReader reader) {
  final sessionId = reader.readSessionId();
  final cols = reader.readUint16();
  final rows = reader.readUint16();
  _checkGridDims(cols, rows);
  return ResizeFrame(sessionId: sessionId, cols: cols, rows: rows);
}

void _encodeClipboard(_FrameWriter writer, ClipboardFrame frame) {
  if (frame.readBlocked && frame.text.isNotEmpty) {
    throw const ProtocolFormatException(
      'ClipboardFrame cannot carry non-empty text when readBlocked is true',
    );
  }
  writer
    ..writeUint8(_tagClipboard)
    ..writeSessionId(frame.sessionId)
    ..writeUint8(frame.readBlocked ? 1 : 0)
    ..writeString32(frame.text, maxBytes: _maxClipboardBytes);
}

ClipboardFrame _decodeClipboard(_FrameReader reader) {
  final sessionId = reader.readSessionId();
  final rawFlag = reader.readUint8();
  if (rawFlag != 0 && rawFlag != 1) {
    throw ProtocolFormatException(
      'Invalid ClipboardFrame readBlocked byte: $rawFlag',
    );
  }
  final readBlocked = rawFlag == 1;
  final text = reader.readString32(maxBytes: _maxClipboardBytes);
  if (readBlocked && text.isNotEmpty) {
    throw const ProtocolFormatException(
      'ClipboardFrame cannot carry non-empty text when readBlocked is true',
    );
  }
  return ClipboardFrame(
    sessionId: sessionId,
    readBlocked: readBlocked,
    text: text,
  );
}

void _encodeDirectory(_FrameWriter writer, List<SessionSummary> sessions) {
  if (sessions.length > 4096) {
    throw ProtocolFormatException('Too many sessions: ${sessions.length}');
  }
  writer
    ..writeUint8(_tagSessionDirectory)
    ..writeUint16(sessions.length);
  for (final session in sessions) {
    _checkGridDims(session.cols, session.rows);
    final flags =
        (session.isUserPinned ? _summaryFlagUserPinned : 0) |
        (session.allowSpawn ? _summaryFlagAllowSpawn : 0);
    writer
      ..writeSessionId(session.id)
      ..writeTitle(session.title)
      ..writeUint16(session.cols)
      ..writeUint16(session.rows)
      ..writeUint32(session.subscriberCount)
      ..writeUint8(flags);
  }
}

SessionDirectoryFrame _decodeDirectory(_FrameReader reader) {
  final count = reader.readUint16();
  if (count > 4096) {
    throw ProtocolFormatException('Directory count exceeds cap: $count');
  }
  final sessions = <SessionSummary>[];
  for (var i = 0; i < count; i++) {
    final id = reader.readSessionId();
    final title = reader.readTitle();
    final cols = reader.readUint16();
    final rows = reader.readUint16();
    _checkGridDims(cols, rows);
    final subscriberCount = reader.readUint32();
    final rawFlags = reader.readUint8();
    if ((rawFlags & ~_summaryFlagsMask) != 0) {
      throw ProtocolFormatException(
        'Invalid SessionSummary flags byte: $rawFlags',
      );
    }
    sessions.add(
      SessionSummary(
        id: id,
        title: title,
        cols: cols,
        rows: rows,
        subscriberCount: subscriberCount,
        isUserPinned: (rawFlags & _summaryFlagUserPinned) != 0,
        allowSpawn: (rawFlags & _summaryFlagAllowSpawn) != 0,
      ),
    );
  }
  return SessionDirectoryFrame(sessions: sessions);
}

void _writeCompressibleTail(
  _FrameWriter writer,
  void Function(_FrameWriter tailWriter) encodeTail,
) {
  final tailWriter = _FrameWriter();
  encodeTail(tailWriter);
  final rawTail = tailWriter.takeBytes();
  if (rawTail.length > BufferFrameCodec.maxFrameBytes) {
    throw ProtocolFormatException(
      'Uncompressed frame tail exceeds ${BufferFrameCodec.maxFrameBytes} bytes: ${rawTail.length}',
    );
  }
  if (rawTail.length >= BufferFrameCodec.minCompressTailBytes) {
    final compressed = compressDeflateRawLevel1(rawTail);
    if (compressed.length < rawTail.length) {
      writer
        ..writeUint8(_compressionDeflateRaw)
        ..writeUint32(rawTail.length)
        ..writeRawBytes(compressed);
      return;
    }
  }
  writer
    ..writeUint8(_compressionRaw)
    ..writeRawBytes(rawTail);
}

_FrameReader _readTailReader(_FrameReader reader) {
  final flag = reader.readUint8();
  if (flag == _compressionRaw) {
    return _FrameReader(reader.readRemainingBytes());
  }
  if (flag != _compressionDeflateRaw) {
    throw ProtocolFormatException('Invalid compression flag: $flag');
  }
  final uncompressedLen = reader.readUint32();
  if (uncompressedLen <= 0 ||
      uncompressedLen > BufferFrameCodec.maxFrameBytes) {
    throw ProtocolFormatException(
      'Invalid uncompressed tail length: $uncompressedLen',
    );
  }
  final compressed = reader.readRemainingBytes();
  if (compressed.isEmpty) {
    throw const ProtocolFormatException('Empty compressed tail payload');
  }
  final Uint8List inflated;
  try {
    inflated = const ZLibDecoder().decodeBytes(
      compressed,
      raw: true,
      throwOnError: true,
      maxOutputSize: uncompressedLen,
    );
  } on Object catch (e) {
    throw ProtocolFormatException('Failed to inflate compressed tail: $e');
  }
  if (inflated.length != uncompressedLen) {
    throw ProtocolFormatException(
      'Inflated tail length ${inflated.length} != expected $uncompressedLen',
    );
  }
  return _FrameReader(inflated);
}

T _decodeSessionTail<T>(
  _FrameReader reader,
  SessionId sessionId,
  T Function(_FrameReader tailReader) decodeTail,
) {
  try {
    final tailReader = _readTailReader(reader);
    final result = decodeTail(tailReader);
    if (!tailReader.isAtEnd) {
      throw const ProtocolFormatException('Trailing bytes after frame body');
    }
    return result;
  } on CorruptSessionFrameException {
    rethrow;
  } on ProtocolFormatException catch (e) {
    throw CorruptSessionFrameException(sessionId, e.message);
  }
}

void _inspectRelayBufferTail(
  _FrameReader reader, {
  required bool isSnapshot,
  required int totalCells,
}) {
  final flag = reader.readUint8();
  if (flag == _compressionRaw) {
    if (isSnapshot) {
      reader._skipCellSpan(totalCells);
      _skipSnapshotKittyTrailer(reader);
    } else {
      _skipDeltaRuns(reader, totalCells);
      _skipDeltaKittyTrailer(reader);
    }
    if (!reader.isAtEnd) {
      throw const ProtocolFormatException(
        'Trailing bytes in relay buffer frame',
      );
    }
    return;
  }
  if (flag != _compressionDeflateRaw) {
    throw ProtocolFormatException('Invalid compression flag: $flag');
  }
  final uncompressedLen = reader.readUint32();
  final minBytes = isSnapshot ? totalCells * 13 + 3 : 9;
  if (uncompressedLen < minBytes ||
      uncompressedLen > BufferFrameCodec.maxFrameBytes) {
    throw ProtocolFormatException(
      'Invalid compressed buffer tail length: $uncompressedLen',
    );
  }
  if (reader.isAtEnd) {
    throw const ProtocolFormatException('Empty compressed buffer tail');
  }
}

typedef _ScrollbackHeaderInfo = ({int requestId, int requestIdOffset});

_ScrollbackHeaderInfo? _inspectScrollbackChunkHeader(
  Uint8List frame, {
  required SessionId expectedSession,
}) {
  if (frame.length < 2 ||
      frame[0] != BufferFrameCodec.protocolVersion ||
      frame[1] != _tagScrollbackChunk) {
    return null;
  }
  if (frame.length > BufferFrameCodec.maxFrameBytes) {
    throw ProtocolFormatException(
      'Scrollback chunk frame exceeds ${BufferFrameCodec.maxFrameBytes} bytes: ${frame.length}',
    );
  }
  final reader = _FrameReader(frame)..skip(2);
  if (reader.readSessionId() != expectedSession) return null;
  final requestIdOffset = reader.offset;
  final requestId = reader.readUint32();
  reader.readUint32(); // clearSeq
  reader.readUint53(); // startLine
  final rowCount = reader.readUint16();
  if (rowCount > BufferFrameCodec.maxScrollbackChunkRows) {
    throw ProtocolFormatException(
      'Scrollback chunk row count exceeds cap: $rowCount',
    );
  }
  _inspectRelayScrollbackTail(reader, rowCount);
  return (requestId: requestId, requestIdOffset: requestIdOffset);
}

void _inspectRelayScrollbackTail(_FrameReader reader, int rowCount) {
  final flag = reader.readUint8();
  if (flag == _compressionRaw) {
    _skipScrollbackRows(reader, rowCount);
    if (!reader.isAtEnd) {
      throw const ProtocolFormatException('Trailing bytes after frame body');
    }
    return;
  }
  if (flag != _compressionDeflateRaw) {
    throw ProtocolFormatException('Invalid compression flag: $flag');
  }
  final uncompressedLen = reader.readUint32();
  final minBytes = rowCount * 4;
  if (uncompressedLen <= 0 ||
      uncompressedLen < minBytes ||
      uncompressedLen > BufferFrameCodec.maxFrameBytes) {
    throw ProtocolFormatException(
      'Invalid compressed scrollback tail length: $uncompressedLen',
    );
  }
  if (reader.isAtEnd) {
    throw const ProtocolFormatException('Empty compressed scrollback tail');
  }
}

void _validateKittyPayload(KittyImagePayload payload) {
  final w = payload.pixelWidth;
  final h = payload.pixelHeight;
  _validateKittyImageDimensions(
    imageId: payload.imageId,
    pixelWidth: w,
    pixelHeight: h,
    gridCols: payload.gridCols,
    gridRows: payload.gridRows,
  );
  _checkUint32(payload.version, 'kittyImage.version');
  _validateKittyPayloadFormatBytes(payload.format, w, h, payload.bytes.length);
  if (payload.format == 100) {
    _validatePngIhdrSlice(payload.bytes, 0, payload.bytes.length, w, h);
  }
}

const List<int> _pngMagicBytes = [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
];

void _validatePngIhdrSlice(
  Uint8List bytes,
  int offset,
  int length,
  int expectedWidth,
  int expectedHeight,
) {
  if (length < _minPngBytes || offset < 0 || offset + 24 > bytes.length) {
    throw ProtocolFormatException('PNG Kitty byte length $length < 24');
  }
  if (!_matchesPngIhdrMagic(bytes, offset)) {
    throw const ProtocolFormatException('Invalid PNG Kitty signature or IHDR');
  }
  final view = ByteData.sublistView(bytes, offset, offset + 24);
  final ihdrLen = view.getUint32(8);
  final ihdrW = view.getUint32(16);
  final ihdrH = view.getUint32(20);
  if (ihdrLen != 13 || ihdrW != expectedWidth || ihdrH != expectedHeight) {
    throw ProtocolFormatException(
      'PNG Kitty IHDR ${ihdrW}x$ihdrH (len $ihdrLen) != ${expectedWidth}x$expectedHeight',
    );
  }
}

bool _matchesPngIhdrMagic(Uint8List bytes, int offset) {
  for (var i = 0; i < _pngMagicBytes.length; i++) {
    if (bytes[offset + i] != _pngMagicBytes[i]) return false;
  }
  return bytes[offset + 12] == 0x49 &&
      bytes[offset + 13] == 0x48 &&
      bytes[offset + 14] == 0x44 &&
      bytes[offset + 15] == 0x52;
}

void _validateKittyPayloadFormatBytes(int format, int w, int h, int byteLen) {
  if (byteLen <= 0 || byteLen > BufferFrameCodec.maxFrameBytes) {
    throw ProtocolFormatException('Invalid Kitty byte length: $byteLen');
  }
  if (format == 32) {
    if (byteLen != w * h * 4) {
      throw ProtocolFormatException(
        'RGBA32 Kitty byte length $byteLen != ${w * h * 4}',
      );
    }
    return;
  }
  if (format == 100) {
    if (byteLen < _minPngBytes) {
      throw ProtocolFormatException('PNG Kitty byte length $byteLen < 24');
    }
    return;
  }
  throw ProtocolFormatException('Unsupported Kitty image format: $format');
}

void _writeSnapshotKittyTrailer(
  _FrameWriter tail,
  List<KittyImagePayload>? images,
) {
  final list = images ?? const <KittyImagePayload>[];
  if (list.length > _maxKittyImagesPerFrame) {
    throw ProtocolFormatException(
      'Snapshot kittyImages count exceeds cap: ${list.length}',
    );
  }
  tail.writeUint16(list.length);
  for (final img in list) {
    tail.writeKittyPayload(img);
  }
}

void _skipSnapshotKittyTrailer(_FrameReader tail) {
  final count = tail.readUint16();
  if (count > _maxKittyImagesPerFrame) {
    throw ProtocolFormatException('Snapshot kittyImages count $count > cap');
  }
  for (var i = 0; i < count; i++) {
    tail._skipKittyPayload();
  }
}

List<KittyImagePayload>? _readSnapshotKittyTrailer(_FrameReader tail) {
  final count = tail.readUint16();
  if (count > _maxKittyImagesPerFrame) {
    throw ProtocolFormatException('Snapshot kittyImages count $count > cap');
  }
  if (count == 0) return null;
  return [for (var i = 0; i < count; i++) tail.readKittyPayload()];
}

void _writeDeltaKittyTrailer(_FrameWriter tail, BufferDelta delta) {
  final removals = delta.kittyRemovals ?? const <int>[];
  final upserts = delta.kittyUpserts ?? const <KittyImagePayload>[];
  if (removals.length > _maxKittyImagesPerFrame ||
      upserts.length > _maxKittyImagesPerFrame) {
    throw const ProtocolFormatException('Delta Kitty trailer count > cap');
  }
  tail
    ..writeUint8(delta.clearKittyImages ? 1 : 0)
    ..writeUint16(removals.length);
  for (final id in removals) {
    if (id <= 0 || id > 0xFFFFFFFF) {
      throw ProtocolFormatException('Invalid Kitty removal imageId: $id');
    }
    tail.writeUint32(id);
  }
  tail.writeUint16(upserts.length);
  for (final img in upserts) {
    tail.writeKittyPayload(img);
  }
}

void _skipDeltaKittyTrailer(_FrameReader tail) {
  final rawClear = tail.readUint8();
  if (rawClear != 0 && rawClear != 1) {
    throw ProtocolFormatException(
      'Invalid delta clearKittyImages byte: $rawClear',
    );
  }
  final removalCount = tail.readUint16();
  if (removalCount > _maxKittyImagesPerFrame) {
    throw ProtocolFormatException(
      'Delta kittyRemovals count $removalCount > cap',
    );
  }
  for (var i = 0; i < removalCount; i++) {
    if (tail.readUint32() == 0) {
      throw const ProtocolFormatException('Zero Kitty removal imageId');
    }
  }
  final upsertCount = tail.readUint16();
  if (upsertCount > _maxKittyImagesPerFrame) {
    throw ProtocolFormatException(
      'Delta kittyUpserts count $upsertCount > cap',
    );
  }
  for (var i = 0; i < upsertCount; i++) {
    tail._skipKittyPayload();
  }
}

({
  bool clearKittyImages,
  List<int>? kittyRemovals,
  List<KittyImagePayload>? kittyUpserts,
})
_readDeltaKittyTrailer(_FrameReader tail) {
  final rawClear = tail.readUint8();
  if (rawClear != 0 && rawClear != 1) {
    throw ProtocolFormatException(
      'Invalid delta clearKittyImages byte: $rawClear',
    );
  }
  final removalCount = tail.readUint16();
  if (removalCount > _maxKittyImagesPerFrame) {
    throw ProtocolFormatException(
      'Delta kittyRemovals count $removalCount > cap',
    );
  }
  List<int>? removals;
  if (removalCount > 0) {
    removals = <int>[];
    for (var i = 0; i < removalCount; i++) {
      final id = tail.readUint32();
      if (id == 0) {
        throw const ProtocolFormatException('Zero Kitty removal imageId');
      }
      removals.add(id);
    }
  }
  final upsertCount = tail.readUint16();
  if (upsertCount > _maxKittyImagesPerFrame) {
    throw ProtocolFormatException(
      'Delta kittyUpserts count $upsertCount > cap',
    );
  }
  final upserts = upsertCount == 0
      ? null
      : [for (var i = 0; i < upsertCount; i++) tail.readKittyPayload()];
  return (
    clearKittyImages: rawClear == 1,
    kittyRemovals: removals,
    kittyUpserts: upserts,
  );
}

void _encodeSnapshot(_FrameWriter writer, BufferSnapshot snapshot) {
  _checkGridDims(snapshot.cols, snapshot.rows);
  final expectedCells = snapshot.cols * snapshot.rows;
  if (snapshot.characters.length != expectedCells ||
      snapshot.attributes.length != expectedCells * 3) {
    throw ProtocolFormatException(
      'Snapshot array length mismatch for ${snapshot.cols}x${snapshot.rows}',
    );
  }
  _validateSpanAux(expectedCells, snapshot.underlineColors, snapshot.uriRuns);
  writer
    ..writeUint8(_tagBufferSnapshot)
    ..writeSessionId(snapshot.sessionId)
    ..writeUint53(snapshot.seq)
    ..writeUint16(snapshot.cols)
    ..writeUint16(snapshot.rows)
    ..writeCursorAndModes(snapshot.cursor, snapshot.modes)
    ..writeScrollbackWindow(snapshot.scrollback)
    ..writeWrappedRows(snapshot.wrappedRows, snapshot.rows);
  _writeCompressibleTail(writer, (tail) {
    tail.writeCellSpan(
      snapshot.characters,
      snapshot.attributes,
      underlineColors: snapshot.underlineColors,
      uriRuns: snapshot.uriRuns,
    );
    _writeSnapshotKittyTrailer(tail, snapshot.kittyImages);
  });
}

BufferSnapshot _decodeSnapshot(_FrameReader reader) {
  final sessionId = reader.readSessionId();
  final seq = reader.readUint53();
  final cols = reader.readUint16();
  final rows = reader.readUint16();
  _checkGridDims(cols, rows);
  final (cursor, modes) = reader.readCursorAndModes();
  final scrollback = reader.readScrollbackWindow();
  final wrappedRows = reader.readWrappedRows(rows);
  final (span, kittyImages) = _decodeSessionTail(
    reader,
    sessionId,
    (tail) => (tail.readCellSpan(cols * rows), _readSnapshotKittyTrailer(tail)),
  );
  return BufferSnapshot(
    sessionId: sessionId,
    seq: seq,
    cols: cols,
    rows: rows,
    cursor: cursor,
    modes: modes,
    scrollback: scrollback,
    wrappedRows: wrappedRows,
    characters: span.characters,
    attributes: span.attributes,
    underlineColors: span.underlineColors,
    uriRuns: span.uriRuns,
    kittyImages: kittyImages,
  );
}

void _encodeDelta(_FrameWriter writer, BufferDelta delta) {
  _checkDeltaSeqOrder(delta.baseSeq, delta.seq);
  _checkGridDims(delta.cols, delta.rows);
  final totalCells = delta.cols * delta.rows;
  _validateCellRuns(delta.runs, totalCells);
  writer
    ..writeUint8(_tagBufferDelta)
    ..writeSessionId(delta.sessionId)
    ..writeUint53(delta.seq)
    ..writeUint53(delta.baseSeq)
    ..writeUint16(delta.cols)
    ..writeUint16(delta.rows)
    ..writeCursorAndModes(delta.cursor, delta.modes)
    ..writeScrollbackWindow(delta.scrollback)
    ..writeWrappedRows(delta.wrappedRows, delta.rows);
  _writeCompressibleTail(writer, (tail) {
    tail.writeUint32(delta.runs.length);
    for (final run in delta.runs) {
      tail
        ..writeUint32(run.startIndex)
        ..writeUint32(run.characters.length)
        ..writeCellSpan(
          run.characters,
          run.attributes,
          underlineColors: run.underlineColors,
          uriRuns: run.uriRuns,
        );
    }
    _writeDeltaKittyTrailer(tail, delta);
  });
}

void _skipDeltaRuns(_FrameReader reader, int totalCells) {
  final runCount = reader.readUint32();
  if (runCount > totalCells) {
    throw ProtocolFormatException('Delta runCount $runCount > $totalCells');
  }
  var nextMinStart = 0;
  for (var i = 0; i < runCount; i++) {
    final startIndex = reader.readUint32();
    final len = reader.readUint32();
    if (len == 0 ||
        startIndex < nextMinStart ||
        startIndex + len > totalCells) {
      throw ProtocolFormatException(
        'Invalid or overlapping CellRun: start=$startIndex len=$len',
      );
    }
    nextMinStart = startIndex + len;
    reader._skipCellSpan(len);
  }
}

List<CellRun> _readDeltaRuns(_FrameReader reader, int totalCells) {
  final runCount = reader.readUint32();
  if (runCount > totalCells) {
    throw ProtocolFormatException('Delta runCount $runCount > $totalCells');
  }
  final runs = <CellRun>[];
  var nextMinStart = 0;
  for (var i = 0; i < runCount; i++) {
    final startIndex = reader.readUint32();
    final len = reader.readUint32();
    if (len == 0 ||
        startIndex < nextMinStart ||
        startIndex + len > totalCells) {
      throw ProtocolFormatException(
        'Invalid or overlapping CellRun: start=$startIndex len=$len',
      );
    }
    nextMinStart = startIndex + len;
    final span = reader.readCellSpan(len);
    runs.add(
      CellRun(
        startIndex: startIndex,
        characters: span.characters,
        attributes: span.attributes,
        underlineColors: span.underlineColors,
        uriRuns: span.uriRuns,
      ),
    );
  }
  return runs;
}

BufferDelta _decodeDelta(_FrameReader reader) {
  final sessionId = reader.readSessionId();
  final seq = reader.readUint53();
  final baseSeq = reader.readUint53();
  _checkDeltaSeqOrder(baseSeq, seq);
  final cols = reader.readUint16();
  final rows = reader.readUint16();
  _checkGridDims(cols, rows);
  final totalCells = cols * rows;
  final (cursor, modes) = reader.readCursorAndModes();
  final scrollback = reader.readScrollbackWindow();
  final wrappedRows = reader.readWrappedRows(rows);
  final (runs, kittyTrailer) = _decodeSessionTail(
    reader,
    sessionId,
    (tail) => (_readDeltaRuns(tail, totalCells), _readDeltaKittyTrailer(tail)),
  );
  return BufferDelta(
    sessionId: sessionId,
    seq: seq,
    baseSeq: baseSeq,
    cols: cols,
    rows: rows,
    cursor: cursor,
    modes: modes,
    scrollback: scrollback,
    wrappedRows: wrappedRows,
    runs: runs,
    clearKittyImages: kittyTrailer.clearKittyImages,
    kittyRemovals: kittyTrailer.kittyRemovals,
    kittyUpserts: kittyTrailer.kittyUpserts,
  );
}

void _checkUint32(int value, String label) {
  if (value < 0 || value > 0xFFFFFFFF) {
    throw ProtocolFormatException('Out-of-range $label: $value');
  }
}

void _encodeRequestScrollback(
  _FrameWriter writer,
  RequestScrollbackFrame frame,
) {
  _checkUint32(frame.requestId, 'requestId');
  _checkUint32(frame.clearSeq, 'clearSeq');
  if (frame.count <= 0 ||
      frame.count > BufferFrameCodec.maxScrollbackChunkRows) {
    throw ProtocolFormatException(
      'Invalid scrollback request count: ${frame.count}',
    );
  }
  writer
    ..writeUint8(_tagRequestScrollback)
    ..writeSessionId(frame.sessionId)
    ..writeUint32(frame.requestId)
    ..writeUint32(frame.clearSeq)
    ..writeUint53(frame.startLine)
    ..writeUint16(frame.count);
}

RequestScrollbackFrame _decodeRequestScrollback(_FrameReader reader) {
  final sessionId = reader.readSessionId();
  final requestId = reader.readUint32();
  final clearSeq = reader.readUint32();
  final startLine = reader.readUint53();
  final count = reader.readUint16();
  if (count <= 0 || count > BufferFrameCodec.maxScrollbackChunkRows) {
    throw ProtocolFormatException('Invalid scrollback request count: $count');
  }
  return RequestScrollbackFrame(
    sessionId: sessionId,
    requestId: requestId,
    clearSeq: clearSeq,
    startLine: startLine,
    count: count,
  );
}

void _encodeScrollbackChunk(_FrameWriter writer, ScrollbackChunkFrame frame) {
  _checkUint32(frame.requestId, 'requestId');
  _checkUint32(frame.clearSeq, 'clearSeq');
  if (frame.rows.length > BufferFrameCodec.maxScrollbackChunkRows) {
    throw ProtocolFormatException(
      'Scrollback chunk row count exceeds cap: ${frame.rows.length}',
    );
  }
  for (final row in frame.rows) {
    final cellCount = row.characters.length;
    if (cellCount > BufferFrameCodec.maxGridCols ||
        row.attributes.length != cellCount * 3) {
      throw ProtocolFormatException(
        'Invalid scrollback row cells=$cellCount (attrs=${row.attributes.length})',
      );
    }
    _validateSpanAux(cellCount, row.underlineColors, row.uriRuns);
  }
  writer
    ..writeUint8(_tagScrollbackChunk)
    ..writeSessionId(frame.sessionId)
    ..writeUint32(frame.requestId)
    ..writeUint32(frame.clearSeq)
    ..writeUint53(frame.startLine)
    ..writeUint16(frame.rows.length);
  _writeCompressibleTail(writer, (tail) {
    for (final row in frame.rows) {
      tail
        ..writeUint8(row.isWrapped ? 1 : 0)
        ..writeUint16(row.characters.length)
        ..writeCellSpan(
          row.characters,
          row.attributes,
          underlineColors: row.underlineColors,
          uriRuns: row.uriRuns,
        );
    }
  });
}

void _skipScrollbackRows(_FrameReader reader, int rowCount) {
  for (var i = 0; i < rowCount; i++) {
    final rawFlags = reader.readUint8();
    if (rawFlags != 0 && rawFlags != 1) {
      throw ProtocolFormatException(
        'Invalid scrollback row flags byte: $rawFlags',
      );
    }
    final cellCount = reader.readUint16();
    if (cellCount > BufferFrameCodec.maxGridCols) {
      throw ProtocolFormatException(
        'Scrollback row cells $cellCount > ${BufferFrameCodec.maxGridCols}',
      );
    }
    reader._skipCellSpan(cellCount);
  }
}

List<EncodedScrollbackRow> _readScrollbackRows(
  _FrameReader reader,
  int rowCount,
) {
  final rows = <EncodedScrollbackRow>[];
  for (var i = 0; i < rowCount; i++) {
    final rawFlags = reader.readUint8();
    if (rawFlags != 0 && rawFlags != 1) {
      throw ProtocolFormatException(
        'Invalid scrollback row flags byte: $rawFlags',
      );
    }
    final cellCount = reader.readUint16();
    if (cellCount > BufferFrameCodec.maxGridCols) {
      throw ProtocolFormatException(
        'Scrollback row cells $cellCount > ${BufferFrameCodec.maxGridCols}',
      );
    }
    final span = reader.readCellSpan(cellCount);
    rows.add(
      EncodedScrollbackRow(
        isWrapped: rawFlags == 1,
        characters: span.characters,
        attributes: span.attributes,
        underlineColors: span.underlineColors,
        uriRuns: span.uriRuns,
      ),
    );
  }
  return rows;
}

ScrollbackChunkFrame _decodeScrollbackChunk(_FrameReader reader) {
  final sessionId = reader.readSessionId();
  final requestId = reader.readUint32();
  final clearSeq = reader.readUint32();
  final startLine = reader.readUint53();
  final rowCount = reader.readUint16();
  if (rowCount > BufferFrameCodec.maxScrollbackChunkRows) {
    throw ProtocolFormatException(
      'Scrollback chunk row count exceeds cap: $rowCount',
    );
  }
  final rows = _decodeSessionTail(
    reader,
    sessionId,
    (tail) => _readScrollbackRows(tail, rowCount),
  );
  return ScrollbackChunkFrame(
    sessionId: sessionId,
    requestId: requestId,
    clearSeq: clearSeq,
    startLine: startLine,
    rows: rows,
  );
}

void _validateUploadFileName(String fileName) {
  if (fileName.isEmpty || fileName == '.' || fileName == '..') {
    throw ProtocolFormatException('Invalid upload fileName: "$fileName"');
  }
  for (var i = 0; i < fileName.length; i++) {
    final unit = fileName.codeUnitAt(i);
    if (unit <= 0x1F ||
        (unit >= 0x7F && unit <= 0x9F) ||
        unit == 0x2F ||
        unit == 0x5C) {
      throw ProtocolFormatException(
        'Invalid character in upload fileName: "$fileName"',
      );
    }
  }
}

void _encodeFileUploadStart(_FrameWriter writer, FileUploadStartFrame frame) {
  _checkUint32(frame.transferId, 'transferId');
  _validateUploadFileName(frame.fileName);
  writer
    ..writeUint8(_tagFileUploadStart)
    ..writeSessionId(frame.sessionId)
    ..writeUint32(frame.transferId)
    ..writeString16(
      frame.fileName,
      maxBytes: FileUploadStartFrame.maxFileNameBytes,
    )
    ..writeUint53(frame.totalBytes);
}

FileUploadStartFrame _decodeFileUploadStart(_FrameReader reader) {
  final sessionId = reader.readSessionId();
  final transferId = reader.readUint32();
  final fileName = reader.readString16(
    maxBytes: FileUploadStartFrame.maxFileNameBytes,
  );
  _validateUploadFileName(fileName);
  final totalBytes = reader.readUint53();
  return FileUploadStartFrame(
    sessionId: sessionId,
    transferId: transferId,
    fileName: fileName,
    totalBytes: totalBytes,
  );
}

void _encodeFileUploadChunk(_FrameWriter writer, FileUploadChunkFrame frame) {
  _checkUint32(frame.transferId, 'transferId');
  if (frame.data.isEmpty ||
      frame.data.length > FileUploadChunkFrame.maxChunkBytes) {
    throw ProtocolFormatException(
      'Invalid upload chunk byte length: ${frame.data.length}',
    );
  }
  writer
    ..writeUint8(_tagFileUploadChunk)
    ..writeSessionId(frame.sessionId)
    ..writeUint32(frame.transferId)
    ..writeUint53(frame.offset)
    ..writeBytes32(frame.data);
}

FileUploadChunkFrame _decodeFileUploadChunk(_FrameReader reader) {
  final sessionId = reader.readSessionId();
  final transferId = reader.readUint32();
  final offset = reader.readUint53();
  final data = reader.readBytes32(maxBytes: FileUploadChunkFrame.maxChunkBytes);
  if (data.isEmpty) {
    throw ProtocolFormatException(
      'Invalid upload chunk byte length: ${data.length}',
    );
  }
  return FileUploadChunkFrame(
    sessionId: sessionId,
    transferId: transferId,
    offset: offset,
    data: data,
  );
}

void _checkUploadEndSha256(Uint8List sha256, {required bool aborted}) {
  final expectedLen = aborted ? 0 : FileUploadEndFrame.sha256ByteLength;
  if (sha256.length != expectedLen) {
    throw ProtocolFormatException(
      'Invalid FileUploadEndFrame sha256 length ${sha256.length} (expected $expectedLen)',
    );
  }
}

void _encodeFileUploadEnd(_FrameWriter writer, FileUploadEndFrame frame) {
  _checkUint32(frame.transferId, 'transferId');
  _checkUploadEndSha256(frame.sha256, aborted: frame.aborted);
  writer
    ..writeUint8(_tagFileUploadEnd)
    ..writeSessionId(frame.sessionId)
    ..writeUint32(frame.transferId)
    ..writeUint8(frame.aborted ? 1 : 0)
    ..writeBytes32(frame.sha256);
}

FileUploadEndFrame _decodeFileUploadEnd(_FrameReader reader) {
  final sessionId = reader.readSessionId();
  final transferId = reader.readUint32();
  final rawAborted = reader.readUint8();
  if (rawAborted != 0 && rawAborted != 1) {
    throw ProtocolFormatException(
      'Invalid FileUploadEndFrame aborted byte: $rawAborted',
    );
  }
  final aborted = rawAborted == 1;
  final sha256 = reader.readBytes32(
    maxBytes: FileUploadEndFrame.sha256ByteLength,
  );
  _checkUploadEndSha256(sha256, aborted: aborted);
  return FileUploadEndFrame(
    sessionId: sessionId,
    transferId: transferId,
    sha256: sha256,
    aborted: aborted,
  );
}

int _encodeUploadStatus(FileUploadStatus status) => switch (status) {
  .ready => 0,
  .chunkAck => 1,
  .completed => 2,
  .rejected => 3,
};

FileUploadStatus _decodeUploadStatus(int raw) => switch (raw) {
  0 => .ready,
  1 => .chunkAck,
  2 => .completed,
  3 => .rejected,
  _ => throw ProtocolFormatException('Invalid FileUploadStatus byte: $raw'),
};

void _encodeFileUploadAck(_FrameWriter writer, FileUploadAckFrame frame) {
  _checkUint32(frame.transferId, 'transferId');
  writer
    ..writeUint8(_tagFileUploadAck)
    ..writeSessionId(frame.sessionId)
    ..writeUint32(frame.transferId)
    ..writeUint8(_encodeUploadStatus(frame.status))
    ..writeUint53(frame.nextOffset)
    ..writeString16(frame.message, maxBytes: _maxTokenOrErrorBytes);
}

FileUploadAckFrame _decodeFileUploadAck(_FrameReader reader) {
  final sessionId = reader.readSessionId();
  final transferId = reader.readUint32();
  final status = _decodeUploadStatus(reader.readUint8());
  final nextOffset = reader.readUint53();
  final message = reader.readString16(maxBytes: _maxTokenOrErrorBytes);
  return FileUploadAckFrame(
    sessionId: sessionId,
    transferId: transferId,
    status: status,
    nextOffset: nextOffset,
    message: message,
  );
}

final class _FrameWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void writeUint8(int value) => _builder.addByte(value & 0xFF);

  void writeUint16(int value) {
    _builder
      ..addByte((value >> 8) & 0xFF)
      ..addByte(value & 0xFF);
  }

  void writeUint32(int value) {
    _builder
      ..addByte((value >> 24) & 0xFF)
      ..addByte((value >> 16) & 0xFF)
      ..addByte((value >> 8) & 0xFF)
      ..addByte(value & 0xFF);
  }

  void writeInt32(int value) => writeUint32(value);

  void writeFloat64(double value) {
    final scratch = ByteData(8)..setFloat64(0, value, .big);
    _builder.add(scratch.buffer.asUint8List());
  }

  void writeUint53(int value) {
    if (value < 0 || value > 0x1FFFFFFFFFFFFF) {
      throw ProtocolFormatException('Out-of-range sequence number: $value');
    }
    writeUint32(value ~/ 0x100000000);
    writeUint32(value.remainder(0x100000000));
  }

  void writeSessionId(SessionId id) {
    if (!id.isValid) {
      throw ProtocolFormatException('Invalid SessionId: "${id.value}"');
    }
    writeString16(id.value, maxBytes: _maxSessionIdBytes);
  }

  void writeTitle(String title) {
    final encoded = _encodeValidatedTitle(title);
    writeUint16(encoded.length);
    _builder.add(encoded);
  }

  void writeFixedBytes(
    Uint8List bytes, {
    required int expectedLength,
    required String label,
  }) {
    if (bytes.length != expectedLength) {
      throw ProtocolFormatException(
        'Invalid $label byte length ${bytes.length} (expected $expectedLength)',
      );
    }
    _builder.add(bytes);
  }

  void writeString16(String value, {required int maxBytes}) {
    final encoded = utf8.encode(value);
    if (encoded.length > maxBytes) {
      throw ProtocolFormatException(
        'String exceeds $maxBytes UTF-8 bytes: ${encoded.length}',
      );
    }
    writeUint16(encoded.length);
    _builder.add(encoded);
  }

  void writeString32(String value, {required int maxBytes}) {
    final encoded = utf8.encode(value);
    if (encoded.length > maxBytes) {
      throw ProtocolFormatException(
        'String exceeds $maxBytes UTF-8 bytes: ${encoded.length}',
      );
    }
    writeUint32(encoded.length);
    _builder.add(encoded);
  }

  void writeBytes32(Uint8List data) {
    if (data.length > BufferFrameCodec.maxFrameBytes) {
      throw ProtocolFormatException('Byte payload too large: ${data.length}');
    }
    writeUint32(data.length);
    _builder.add(data);
  }

  void writeCursorAndModes(CursorState cursor, TerminalModes modes) {
    final yClamped = cursor.y.clamp(0, 0x1FFF);
    final shapeBits = (cursor.shape.index & 0x7) << 13;
    writeUint16(cursor.x.clamp(0, 0xFFFF));
    writeUint16(yClamped | shapeBits);
    final flags =
        (cursor.visible ? 1 : 0) |
        (modes.mouseTracking ? 2 : 0) |
        (modes.sgrMouse ? 4 : 0) |
        (modes.bracketedPaste ? 8 : 0) |
        (modes.altScreen ? 16 : 0) |
        (modes.appCursorKeys ? 32 : 0) |
        (modes.alternateScroll ? 64 : 0) |
        (modes.focusReporting ? 128 : 0) |
        (modes.sgrPixelsMouse ? 256 : 0);
    writeUint16(flags);
    writeUint8(modes.kittyKeyboardFlags.clamp(0, 0xFF));
  }

  void writeScrollbackWindow(ScrollbackWindow window) {
    _checkUint32(window.clearSeq, 'scrollback.clearSeq');
    if (window.oldestLine < 0 || window.oldestLine > window.totalLines) {
      throw ProtocolFormatException(
        'Invalid scrollback window: oldest=${window.oldestLine}, total=${window.totalLines}',
      );
    }
    writeUint32(window.clearSeq);
    writeUint53(window.oldestLine);
    writeUint53(window.totalLines);
  }

  void writeWrappedRows(Uint8List wrappedRows, int rows) {
    final expectedBytes = wrappedRowsByteLength(rows);
    if (wrappedRows.length != expectedBytes) {
      throw ProtocolFormatException(
        'Invalid wrappedRows byte length ${wrappedRows.length} for $rows rows (expected $expectedBytes)',
      );
    }
    final remBits = rows & 7;
    if (remBits != 0 && (wrappedRows[expectedBytes - 1] >> remBits) != 0) {
      throw ProtocolFormatException(
        'Non-zero unused high bits in wrappedRows for $rows rows',
      );
    }
    _builder.add(wrappedRows);
  }

  void writeCellSpan(
    List<String> characters,
    Uint32List attributes, {
    Map<int, int>? underlineColors,
    List<UriRun>? uriRuns,
  }) {
    for (var i = 0; i < characters.length; i++) {
      _writeGrapheme(characters[i]);
    }
    final attrBytes = Uint8List(attributes.length * 4);
    final view = ByteData.sublistView(attrBytes);
    for (var i = 0; i < attributes.length; i++) {
      view.setUint32(i * 4, attributes[i], .big);
    }
    _builder.add(attrBytes);
    _writeCellSpanAuxTrailer(characters.length, underlineColors, uriRuns);
  }

  void _writeCellSpanAuxTrailer(
    int cellCount,
    Map<int, int>? underlineColors,
    List<UriRun>? uriRuns,
  ) {
    _validateSpanAux(cellCount, underlineColors, uriRuns);
    final ulKeys = _sortedNonZeroUnderlineKeys(underlineColors);
    final hasUl = ulKeys.isNotEmpty;
    final hasUri = uriRuns != null && uriRuns.isNotEmpty;
    final auxFlags =
        (hasUl ? _auxFlagUnderlineColors : 0) | (hasUri ? _auxFlagUriRuns : 0);
    writeUint8(auxFlags);
    if (hasUl) {
      writeUint32(ulKeys.length);
      for (final idx in ulKeys) {
        writeUint32(idx);
        writeUint32(underlineColors![idx]!);
      }
    }
    if (hasUri) {
      _writeDeduplicatedUriRuns(uriRuns);
    }
  }

  static List<int> _sortedNonZeroUnderlineKeys(Map<int, int>? underlineColors) {
    if (underlineColors == null || underlineColors.isEmpty) return const [];
    final keys = <int>[
      for (final entry in underlineColors.entries)
        if (entry.value != 0) entry.key,
    ];
    keys.sort();
    return keys;
  }

  void _writeDeduplicatedUriRuns(List<UriRun> runs) {
    final uriToIndex = <String, int>{};
    final tableBytes = <Uint8List>[];
    final indexedRuns = <({int start, int length, int uriIndex})>[
      for (final run in runs)
        (
          start: run.start,
          length: run.length,
          uriIndex: _internSanitizedUri(run.uri, uriToIndex, tableBytes),
        ),
    ];
    writeUint32(tableBytes.length);
    for (final encoded in tableBytes) {
      writeUint16(encoded.length);
      _builder.add(encoded);
    }
    writeUint32(indexedRuns.length);
    for (final entry in indexedRuns) {
      writeUint32(entry.start);
      writeUint32(entry.length);
      writeUint32(entry.uriIndex);
    }
  }

  static int _internSanitizedUri(
    String raw,
    Map<String, int> uriToIndex,
    List<Uint8List> tableBytes,
  ) {
    final cached = uriToIndex[raw];
    if (cached != null) return cached;
    final sanitized = _hasOsc8ControlCodeUnit(raw) ? clampOsc8Uri(raw) : raw;
    final existing = sanitized == raw ? null : uriToIndex[sanitized];
    if (existing != null) {
      uriToIndex[raw] = existing;
      return existing;
    }
    final encoded = utf8.encode(sanitized);
    final clampedBytes = encoded.length <= maxOsc8UriBytes
        ? encoded
        : utf8.encode(clampOsc8Uri(sanitized));
    final idx = tableBytes.length;
    tableBytes.add(clampedBytes);
    uriToIndex[sanitized] = idx;
    uriToIndex[raw] = idx;
    return idx;
  }

  void writeKittyPayload(KittyImagePayload payload) {
    _validateKittyPayload(payload);
    writeUint32(payload.imageId);
    writeUint16(payload.pixelWidth);
    writeUint16(payload.pixelHeight);
    writeUint16(payload.gridCols);
    writeUint16(payload.gridRows);
    writeUint32(payload.version);
    writeUint8(payload.format);
    writeBytes32(payload.bytes);
  }

  void _writeGrapheme(String grapheme) {
    if (grapheme.isEmpty) {
      _builder.addByte(0);
      return;
    }
    if (grapheme.length == 1) {
      final code = grapheme.codeUnitAt(0);
      if (code < 0x80) {
        if (code <= 0x1F || code == 0x7F) {
          _builder.addByte(0);
          return;
        }
        _builder
          ..addByte(1)
          ..addByte(code);
        return;
      }
    }
    final clean = _stripControlCodeUnits(grapheme);
    if (clean.isEmpty) {
      _builder.addByte(0);
      return;
    }
    final utf8Bytes = utf8.encode(clean);
    if (utf8Bytes.length < 0xFF) {
      _builder
        ..addByte(utf8Bytes.length)
        ..add(utf8Bytes);
      return;
    }
    if (utf8Bytes.length > 0xFFFF) {
      throw ProtocolFormatException('Cell grapheme exceeds 64 KiB');
    }
    _builder.addByte(0xFF);
    writeUint16(utf8Bytes.length);
    _builder.add(utf8Bytes);
  }

  static bool _hasOsc8ControlCodeUnit(String text) {
    for (var i = 0; i < text.length; i++) {
      final u = text.codeUnitAt(i);
      if (u <= 0x1F || (u >= 0x7F && u <= 0x9F)) return true;
    }
    return false;
  }

  static String _stripControlCodeUnits(String grapheme) {
    var hasControl = false;
    for (var i = 0; i < grapheme.length; i++) {
      final u = grapheme.codeUnitAt(i);
      if (u <= 0x1F || (u >= 0x7F && u <= 0x9F)) {
        hasControl = true;
        break;
      }
    }
    if (!hasControl) return grapheme;
    final sb = StringBuffer();
    for (var i = 0; i < grapheme.length; i++) {
      final u = grapheme.codeUnitAt(i);
      if (u > 0x1F && (u < 0x7F || u > 0x9F)) {
        sb.writeCharCode(u);
      }
    }
    return sb.toString();
  }

  void writeRawBytes(Uint8List bytes) => _builder.add(bytes);

  Uint8List takeBytes() => _builder.takeBytes();
}

final class _FrameReader {
  final Uint8List _bytes;
  final ByteData _view;
  int _offset = 0;

  _FrameReader(this._bytes) : _view = ByteData.sublistView(_bytes);

  int get offset => _offset;

  int get remainingBytes => _bytes.length - _offset;

  bool get isAtEnd => _offset == _bytes.length;

  Uint8List readRemainingBytes() {
    final rem = _bytes.length - _offset;
    final slice = Uint8List.sublistView(_bytes, _offset, _bytes.length);
    _offset += rem;
    return slice;
  }

  void skip(int count) {
    _require(count);
    _offset += count;
  }

  int readUint8() {
    _require(1);
    return _bytes[_offset++];
  }

  int readUint16() {
    _require(2);
    final v = _view.getUint16(_offset, .big);
    _offset += 2;
    return v;
  }

  int readUint32() {
    _require(4);
    final v = _view.getUint32(_offset, .big);
    _offset += 4;
    return v;
  }

  int readInt32() {
    _require(4);
    final v = _view.getInt32(_offset, .big);
    _offset += 4;
    return v;
  }

  double readFloat64() {
    _require(8);
    final v = _view.getFloat64(_offset, .big);
    _offset += 8;
    return v;
  }

  int readUint53() {
    _require(8);
    final hi = _view.getUint32(_offset, .big);
    final lo = _view.getUint32(_offset + 4, .big);
    _offset += 8;
    if (hi > 0x1FFFFF) {
      throw ProtocolFormatException(
        'Sequence exceeds 53-bit integer precision',
      );
    }
    return hi * 0x100000000 + lo;
  }

  SessionId readSessionId() {
    final id = SessionId(readString16(maxBytes: _maxSessionIdBytes));
    if (!id.isValid) {
      throw ProtocolFormatException('Invalid decoded SessionId: "${id.value}"');
    }
    return id;
  }

  String readTitle() {
    final title = readString16(maxBytes: _maxTitleBytes);
    _validateTitleText(title);
    return title;
  }

  Uint8List readFixedBytes(int byteLen) {
    _require(byteLen);
    final slice = Uint8List.fromList(
      Uint8List.sublistView(_bytes, _offset, _offset + byteLen),
    );
    _offset += byteLen;
    return slice;
  }

  String readString16({required int maxBytes}) {
    final byteLen = readUint16();
    if (byteLen > maxBytes) {
      throw ProtocolFormatException(
        'Decoded string exceeds $maxBytes UTF-8 bytes: $byteLen',
      );
    }
    return _decodeUtf8(byteLen);
  }

  String readString32({required int maxBytes}) {
    final byteLen = readUint32();
    if (byteLen > maxBytes) {
      throw ProtocolFormatException(
        'Decoded string exceeds $maxBytes UTF-8 bytes: $byteLen',
      );
    }
    return _decodeUtf8(byteLen);
  }

  Uint8List readBytes32({int maxBytes = BufferFrameCodec.maxFrameBytes}) {
    final byteLen = readUint32();
    if (byteLen > maxBytes) {
      throw ProtocolFormatException(
        'Decoded byte slice exceeds $maxBytes bytes: $byteLen',
      );
    }
    _require(byteLen);
    final slice = Uint8List.fromList(
      Uint8List.sublistView(_bytes, _offset, _offset + byteLen),
    );
    _offset += byteLen;
    return slice;
  }

  (CursorState, TerminalModes) readCursorAndModes() {
    final x = readUint16();
    final rawY = readUint16();
    final flags = readUint16();
    final kittyKeyboardFlags = readUint8();
    final y = rawY & 0x1FFF;
    final shapeIndex = (rawY >> 13) & 0x7;
    final shape = shapeIndex < CursorShape.values.length
        ? CursorShape.values[shapeIndex]
        : CursorShape.defaultShape;
    return (
      CursorState(x: x, y: y, visible: (flags & 1) != 0, shape: shape),
      TerminalModes(
        mouseTracking: (flags & 2) != 0,
        sgrMouse: (flags & 4) != 0,
        bracketedPaste: (flags & 8) != 0,
        altScreen: (flags & 16) != 0,
        appCursorKeys: (flags & 32) != 0,
        alternateScroll: (flags & 64) != 0,
        focusReporting: (flags & 128) != 0,
        sgrPixelsMouse: (flags & 256) != 0,
        kittyKeyboardFlags: kittyKeyboardFlags,
      ),
    );
  }

  ScrollbackWindow readScrollbackWindow() {
    final clearSeq = readUint32();
    final oldestLine = readUint53();
    final totalLines = readUint53();
    if (oldestLine > totalLines) {
      throw ProtocolFormatException(
        'Invalid scrollback window: oldest $oldestLine > total $totalLines',
      );
    }
    return ScrollbackWindow(
      clearSeq: clearSeq,
      oldestLine: oldestLine,
      totalLines: totalLines,
    );
  }

  Uint8List readWrappedRows(int rows) {
    final wrapBytes = wrappedRowsByteLength(rows);
    _require(wrapBytes);
    _checkWrappedRowsHighBits(rows, wrapBytes);
    final slice = Uint8List.fromList(
      Uint8List.sublistView(_bytes, _offset, _offset + wrapBytes),
    );
    _offset += wrapBytes;
    return slice;
  }

  void skipWrappedRows(int rows) {
    final wrapBytes = wrappedRowsByteLength(rows);
    _require(wrapBytes);
    _checkWrappedRowsHighBits(rows, wrapBytes);
    _offset += wrapBytes;
  }

  void _checkWrappedRowsHighBits(int rows, int wrapBytes) {
    final remBits = rows & 7;
    if (remBits != 0 && (_bytes[_offset + wrapBytes - 1] >> remBits) != 0) {
      throw ProtocolFormatException(
        'Non-zero unused high bits in wrappedRows for $rows rows',
      );
    }
  }

  void _skipCellSpan(int cellCount) {
    if (cellCount < 0) {
      throw ProtocolFormatException('Negative cellCount: $cellCount');
    }
    _require(cellCount * 13 + 1);
    for (var i = 0; i < cellCount; i++) {
      _skipGrapheme();
    }
    final attrBytes = cellCount * 12;
    _require(attrBytes);
    _offset += attrBytes;
    _skipCellSpanAuxTrailer(cellCount);
  }

  void _skipCellSpanAuxTrailer(int cellCount) {
    final auxFlags = readUint8();
    if ((auxFlags & ~(_auxFlagUnderlineColors | _auxFlagUriRuns)) != 0) {
      throw ProtocolFormatException('Invalid cell span auxFlags: $auxFlags');
    }
    if ((auxFlags & _auxFlagUnderlineColors) != 0) {
      _skipUnderlineColorsMap(cellCount);
    }
    if ((auxFlags & _auxFlagUriRuns) != 0) {
      _skipDeduplicatedUriRuns(cellCount);
    }
  }

  void _skipUnderlineColorsMap(int cellCount) {
    final count = readUint32();
    if (count == 0 || count > cellCount) {
      throw ProtocolFormatException(
        'Invalid underlineColors count $count for span $cellCount',
      );
    }
    _require(count * 8);
    var prevIdx = -1;
    for (var i = 0; i < count; i++) {
      final idx = readUint32();
      final color = readUint32();
      if (idx <= prevIdx || idx >= cellCount || color == 0) {
        throw ProtocolFormatException(
          'Invalid underlineColor entry idx=$idx color=$color',
        );
      }
      prevIdx = idx;
    }
  }

  void _skipDeduplicatedUriRuns(int cellCount) {
    final tableCount = readUint32();
    if (tableCount == 0 || tableCount > cellCount) {
      throw ProtocolFormatException(
        'Invalid URI table count $tableCount for span $cellCount',
      );
    }
    for (var i = 0; i < tableCount; i++) {
      _readValidatedOsc8Uri();
    }
    final runCount = readUint32();
    if (runCount == 0 || runCount > cellCount) {
      throw ProtocolFormatException(
        'Invalid UriRun count $runCount for span $cellCount',
      );
    }
    _require(runCount * 12);
    var nextMinStart = 0;
    for (var i = 0; i < runCount; i++) {
      final start = readUint32();
      final length = readUint32();
      final uriIdx = readUint32();
      if (length == 0 ||
          start < nextMinStart ||
          start + length > cellCount ||
          uriIdx >= tableCount) {
        throw ProtocolFormatException(
          'Invalid decoded UriRun start=$start len=$length uriIdx=$uriIdx',
        );
      }
      nextMinStart = start + length;
    }
  }

  ({
    List<String> characters,
    Uint32List attributes,
    Map<int, int>? underlineColors,
    List<UriRun>? uriRuns,
  })
  readCellSpan(int cellCount) {
    if (cellCount < 0) {
      throw ProtocolFormatException('Negative cellCount: $cellCount');
    }
    _require(cellCount * 13 + 1);
    final characters = List<String>.filled(cellCount, ' ');
    for (var i = 0; i < cellCount; i++) {
      characters[i] = _readGrapheme();
    }
    final attrWords = cellCount * 3;
    _require(attrWords * 4);
    final attributes = Uint32List(attrWords);
    for (var i = 0; i < attrWords; i++) {
      attributes[i] = _view.getUint32(_offset + i * 4, .big);
    }
    _offset += attrWords * 4;
    final (underlineColors, uriRuns) = _readCellSpanAuxTrailer(cellCount);
    return (
      characters: characters,
      attributes: attributes,
      underlineColors: underlineColors,
      uriRuns: uriRuns,
    );
  }

  (Map<int, int>?, List<UriRun>?) _readCellSpanAuxTrailer(int cellCount) {
    final auxFlags = readUint8();
    if ((auxFlags & ~(_auxFlagUnderlineColors | _auxFlagUriRuns)) != 0) {
      throw ProtocolFormatException('Invalid cell span auxFlags: $auxFlags');
    }
    final underlineColors = (auxFlags & _auxFlagUnderlineColors) != 0
        ? _readUnderlineColorsMap(cellCount)
        : null;
    final uriRuns = (auxFlags & _auxFlagUriRuns) != 0
        ? _readDeduplicatedUriRuns(cellCount)
        : null;
    return (underlineColors, uriRuns);
  }

  Map<int, int> _readUnderlineColorsMap(int cellCount) {
    final count = readUint32();
    if (count == 0 || count > cellCount) {
      throw ProtocolFormatException(
        'Invalid underlineColors count $count for span $cellCount',
      );
    }
    _require(count * 8);
    final map = <int, int>{};
    var prevIdx = -1;
    for (var i = 0; i < count; i++) {
      final idx = readUint32();
      final color = readUint32();
      if (idx <= prevIdx || idx >= cellCount || color == 0) {
        throw ProtocolFormatException(
          'Invalid underlineColor entry idx=$idx color=$color',
        );
      }
      prevIdx = idx;
      map[idx] = color;
    }
    return map;
  }

  List<UriRun> _readDeduplicatedUriRuns(int cellCount) {
    final tableCount = readUint32();
    if (tableCount == 0 || tableCount > cellCount) {
      throw ProtocolFormatException(
        'Invalid URI table count $tableCount for span $cellCount',
      );
    }
    final table = <String>[
      for (var i = 0; i < tableCount; i++) _readValidatedOsc8Uri(),
    ];
    final runCount = readUint32();
    if (runCount == 0 || runCount > cellCount) {
      throw ProtocolFormatException(
        'Invalid UriRun count $runCount for span $cellCount',
      );
    }
    _require(runCount * 12);
    final runs = <UriRun>[];
    var nextMinStart = 0;
    for (var i = 0; i < runCount; i++) {
      final start = readUint32();
      final length = readUint32();
      final uriIdx = readUint32();
      if (length == 0 ||
          start < nextMinStart ||
          start + length > cellCount ||
          uriIdx >= tableCount) {
        throw ProtocolFormatException(
          'Invalid decoded UriRun start=$start len=$length uriIdx=$uriIdx',
        );
      }
      nextMinStart = start + length;
      runs.add((start: start, length: length, uri: table[uriIdx]));
    }
    return runs;
  }

  String _readValidatedOsc8Uri() {
    final byteLen = readUint16();
    if (byteLen == 0 || byteLen > maxOsc8UriBytes) {
      throw ProtocolFormatException('Invalid OSC 8 URI byte length: $byteLen');
    }
    final text = _decodeUtf8(byteLen);
    for (var i = 0; i < text.length; i++) {
      final u = text.codeUnitAt(i);
      if (u <= 0x1F || (u >= 0x7F && u <= 0x9F)) {
        throw const ProtocolFormatException(
          'Control character in decoded OSC 8 URI',
        );
      }
    }
    return text;
  }

  void _skipKittyPayload() {
    final header = _readValidatedKittyHeader();
    _require(header.byteLen);
    if (header.format == 100) {
      _validatePngIhdrSlice(
        _bytes,
        _offset,
        header.byteLen,
        header.pixelWidth,
        header.pixelHeight,
      );
    }
    _offset += header.byteLen;
  }

  KittyImagePayload readKittyPayload() {
    final header = _readValidatedKittyHeader();
    final bytes = readFixedBytes(header.byteLen);
    if (header.format == 100) {
      _validatePngIhdrSlice(
        bytes,
        0,
        bytes.length,
        header.pixelWidth,
        header.pixelHeight,
      );
    }
    return KittyImagePayload(
      imageId: header.imageId,
      pixelWidth: header.pixelWidth,
      pixelHeight: header.pixelHeight,
      gridCols: header.gridCols,
      gridRows: header.gridRows,
      version: header.version,
      format: header.format,
      bytes: bytes,
    );
  }

  ({
    int imageId,
    int pixelWidth,
    int pixelHeight,
    int gridCols,
    int gridRows,
    int version,
    int format,
    int byteLen,
  })
  _readValidatedKittyHeader() {
    final imageId = readUint32();
    final pixelWidth = readUint16();
    final pixelHeight = readUint16();
    final gridCols = readUint16();
    final gridRows = readUint16();
    final version = readUint32();
    final format = readUint8();
    final byteLen = readUint32();
    if (imageId == 0 ||
        pixelWidth == 0 ||
        pixelWidth > _maxKittyImageDimension ||
        pixelHeight == 0 ||
        pixelHeight > _maxKittyImageDimension ||
        pixelWidth * pixelHeight > _maxKittyImageTotalPixels ||
        gridCols == 0 ||
        gridCols > _maxKittyImageGridSpan ||
        gridRows == 0 ||
        gridRows > _maxKittyImageGridSpan) {
      throw ProtocolFormatException(
        'Invalid decoded Kitty header id=$imageId ${pixelWidth}x$pixelHeight',
      );
    }
    _validateKittyPayloadFormatBytes(format, pixelWidth, pixelHeight, byteLen);
    return (
      imageId: imageId,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      gridCols: gridCols,
      gridRows: gridRows,
      version: version,
      format: format,
      byteLen: byteLen,
    );
  }

  void _skipGrapheme() {
    final lenMarker = readUint8();
    if (lenMarker == 0) return;
    final byteLen = lenMarker == 0xFF ? readUint16() : lenMarker;
    if (byteLen == 0) return;
    if (byteLen == 1) {
      _readAsciiGraphemeByte();
      return;
    }
    _require(byteLen);
    final end = _offset + byteLen;
    for (var i = _offset; i < end; i++) {
      final b = _bytes[i];
      if (b >= 0x80) {
        _readMultiByteGrapheme(byteLen);
        return;
      }
      if (b <= 0x1F || b == 0x7F) {
        throw ProtocolFormatException('Control code unit in cell grapheme: $b');
      }
    }
    _offset = end;
  }

  String _readGrapheme() {
    final lenMarker = readUint8();
    if (lenMarker == 0) return '';
    final byteLen = lenMarker == 0xFF ? readUint16() : lenMarker;
    if (byteLen == 0) return '';
    if (byteLen == 1) {
      return _asciiTable[_readAsciiGraphemeByte()];
    }
    return _readMultiByteGrapheme(byteLen);
  }

  int _readAsciiGraphemeByte() {
    _require(1);
    final b = _bytes[_offset++];
    if (b <= 0x1F || b >= 0x7F) {
      throw ProtocolFormatException('Invalid single-byte grapheme: $b');
    }
    return b;
  }

  String _readMultiByteGrapheme(int byteLen) {
    final text = _decodeUtf8(byteLen);
    for (var i = 0; i < text.length; i++) {
      final codeUnit = text.codeUnitAt(i);
      if (codeUnit <= 0x1F || (codeUnit >= 0x7F && codeUnit <= 0x9F)) {
        throw ProtocolFormatException(
          'Control code unit in cell grapheme: $codeUnit',
        );
      }
    }
    return text;
  }

  String _decodeUtf8(int byteLen) {
    _require(byteLen);
    final String text;
    try {
      text = utf8.decode(
        Uint8List.sublistView(_bytes, _offset, _offset + byteLen),
      );
    } on FormatException catch (e) {
      throw ProtocolFormatException('Invalid UTF-8 payload: ${e.message}');
    }
    _offset += byteLen;
    return text;
  }

  void _require(int byteCount) {
    if (byteCount < 0 || _offset + byteCount > _bytes.length) {
      throw ProtocolFormatException(
        'Truncated frame at offset $_offset (need $byteCount, len ${_bytes.length})',
      );
    }
  }
}
