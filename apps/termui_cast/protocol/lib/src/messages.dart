import 'dart:typed_data';

import 'buffer_frame_codec.dart';
import 'models.dart';

/// Wire frame exchanged over binary WebSocket channels across caster, server, and client.
sealed class CastMessage {
  /// Creates a protocol message.
  const CastMessage();
}

/// Initial bearer-token authentication frame sent immediately upon connection.
final class AuthFrame extends CastMessage {
  /// Role claimed by the connecting peer.
  final CastRole role;

  /// Bearer token secret (empty when connecting to unauthenticated loopback).
  final String token;

  /// Creates an authentication handshake frame.
  const AuthFrame({required this.role, required this.token});
}

/// Server acknowledgment confirming successful peer authentication.
final class AuthAcceptedFrame extends CastMessage {
  /// Authenticated peer role.
  final CastRole role;

  /// Creates an authentication acceptance frame.
  const AuthAcceptedFrame({required this.role});
}

/// Caster registration announcing a live PTY session to the relay server.
final class RegisterSessionFrame extends CastMessage {
  /// Required byte length of [resumeToken] (`16` bytes / `128` bits).
  static const int resumeTokenByteLength = 16;

  static final Uint8List _zeroResumeToken = Uint8List(
    resumeTokenByteLength,
  ).asUnmodifiableView();

  /// Unique identifier assigned to the session.
  final SessionId sessionId;

  /// Display title for client tabs and menus.
  final String title;

  /// Initial PTY column count.
  final int cols;

  /// Initial PTY row count.
  final int rows;

  final Uint8List? _resumeToken;

  /// 16-byte token proving session ownership across caster reconnect takeovers.
  Uint8List get resumeToken => _resumeToken ?? _zeroResumeToken;

  /// Creates a session registration frame.
  const RegisterSessionFrame({
    required this.sessionId,
    required this.title,
    required this.cols,
    required this.rows,
    Uint8List? resumeToken,
  }) : _resumeToken = resumeToken;
}

/// Broadcast snapshot of all currently live sessions on the relay server.
final class SessionDirectoryFrame extends CastMessage {
  /// Active sessions available for client subscription.
  final List<SessionSummary> sessions;

  /// Creates a session directory broadcast frame.
  const SessionDirectoryFrame({required this.sessions});
}

/// Client request to subscribe to live buffer updates for [sessionId].
final class SubscribeSessionFrame extends CastMessage {
  /// Target session to observe.
  final SessionId sessionId;

  /// Optional initial viewport width requested by the subscribing client (`0` to omit).
  final int cols;

  /// Optional initial viewport height requested by the subscribing client (`0` to omit).
  final int rows;

  /// Creates a session subscription request.
  const SubscribeSessionFrame({
    required this.sessionId,
    this.cols = 0,
    this.rows = 0,
  });
}

/// Client request to stop receiving buffer updates for [sessionId].
final class UnsubscribeSessionFrame extends CastMessage {
  /// Target session to leave.
  final SessionId sessionId;

  /// Creates a session unsubscription request.
  const UnsubscribeSessionFrame({required this.sessionId});
}

/// Server notification informing a caster of its active viewer count.
final class SubscriberCountFrame extends CastMessage {
  /// Target session whose viewer count changed.
  final SessionId sessionId;

  /// Current number of subscribed clients.
  final int subscriberCount;

  /// Creates a subscriber count update frame.
  const SubscriberCountFrame({
    required this.sessionId,
    required this.subscriberCount,
  });
}

/// Request asking a caster to emit an immediate [BufferSnapshotFrame] keyframe.
final class RequestKeyframeFrame extends CastMessage {
  /// Session whose full buffer state is requested.
  final SessionId sessionId;

  /// Creates a keyframe request frame.
  const RequestKeyframeFrame({required this.sessionId});
}

/// Full buffer keyframe message carrying a [BufferSnapshot].
final class BufferSnapshotFrame extends CastMessage {
  /// Full authoritative terminal buffer state.
  final BufferSnapshot snapshot;

  /// Creates a buffer snapshot message.
  const BufferSnapshotFrame({required this.snapshot});
}

/// Incremental cell-run message carrying a [BufferDelta].
final class BufferDeltaFrame extends CastMessage {
  /// Sequenced cell-run delta.
  final BufferDelta delta;

  /// Creates a buffer delta message.
  const BufferDeltaFrame({required this.delta});
}

/// Encoded terminal input bytes sent from a client to the active PTY.
final class InputFrame extends CastMessage {
  /// Target session receiving the input bytes.
  final SessionId sessionId;

  /// Raw UTF-8 or VT escape sequence bytes to write to the PTY.
  final Uint8List data;

  /// Creates a client input frame.
  const InputFrame({required this.sessionId, required this.data});
}

/// Viewport resize intent sent from a client to a session's PTY.
final class ResizeFrame extends CastMessage {
  /// Target session to resize.
  final SessionId sessionId;

  /// Requested terminal width in columns.
  final int cols;

  /// Requested terminal height in rows.
  final int rows;

  /// Creates a terminal resize frame.
  const ResizeFrame({
    required this.sessionId,
    required this.cols,
    required this.rows,
  });
}

/// Notification that a cast session's child process exited or disconnected.
final class SessionClosedFrame extends CastMessage {
  /// Identifier of the closed session.
  final SessionId sessionId;

  /// Reason the session ended (`exited` vs. `disconnected`).
  final SessionCloseReason reason;

  /// Child process exit code when [reason] is [SessionCloseReason.exited], or `-1` on signal termination or disconnect (inspect [reason] to distinguish exit from disconnect).
  final int exitCode;

  /// Creates a session closed notification frame.
  const SessionClosedFrame({
    required this.sessionId,
    required this.exitCode,
    this.reason = .exited,
  });
}

/// Client request or relay notification updating the display title of [sessionId].
final class RenameSessionFrame extends CastMessage {
  /// Maximum UTF-8 byte length allowed for a session title.
  static const int maxTitleBytes = BufferFrameCodec.maxTitleBytes;

  /// Target session whose title is being updated.
  final SessionId sessionId;

  /// Validated trimmed session title (`1..512` UTF-8 bytes, or `''` when [clearPin] is `true`).
  final String title;

  /// Whether to clear an explicit user-pinned tab title and revert to live shell titles.
  final bool clearPin;

  /// Creates a session rename frame.
  const RenameSessionFrame({
    required this.sessionId,
    required this.title,
    this.clearPin = false,
  });
}

/// Caster notification reporting the live shell title (`OSC 0`/`OSC 2`) for [sessionId].
final class ShellTitleFrame extends CastMessage {
  /// Maximum UTF-8 byte length allowed for [title].
  static const int maxTitleBytes = BufferFrameCodec.maxTitleBytes;

  /// Source session whose shell title changed.
  final SessionId sessionId;

  /// Sanitized shell title (`0..512` UTF-8 bytes; empty reverts to the initial title).
  final String title;

  /// Creates a shell title notification frame.
  const ShellTitleFrame({required this.sessionId, required this.title});
}

/// Caster notification signaling a terminal bell (`BEL`, `0x07`) event.
final class BellFrame extends CastMessage {
  /// Source session that emitted `BEL`.
  final SessionId sessionId;

  /// Creates a terminal bell notification frame.
  const BellFrame({required this.sessionId});
}

/// Caster notification carrying a decoded `ESC _ A` terminal audio [payload].
final class AudioFrame extends CastMessage {
  /// Source session that emitted the audio command.
  final SessionId sessionId;

  /// Wire-serializable tone, clip, or stop audio payload.
  final CastAudioPayload payload;

  /// Creates a terminal audio notification frame.
  const AudioFrame({required this.sessionId, required this.payload});
}

/// Structured protocol or authorization error sent prior to closing or rejecting work.
final class ErrorFrame extends CastMessage {
  /// Short machine-readable error code.
  final String code;

  /// Human-readable diagnostic description.
  final String message;

  /// Creates an error frame.
  const ErrorFrame({required this.code, required this.message});
}

/// Clipboard synchronization or blocked-read alert sent from a caster to subscribed clients.
final class ClipboardFrame extends CastMessage {
  /// Session that emitted the `OSC 52` sequence.
  final SessionId sessionId;

  /// Decoded clipboard text when [readBlocked] is `false`.
  final String text;

  /// Whether a remote application attempted to read the clipboard (`OSC 52 ; ?`), which was blocked.
  final bool readBlocked;

  /// Creates a clipboard synchronization or blocked-read notification frame.
  const ClipboardFrame({
    required this.sessionId,
    this.text = '',
    this.readBlocked = false,
  });
}

/// Viewer request asking the caster for a slice of retained primary-screen scrollback.
final class RequestScrollbackFrame extends CastMessage {
  /// Target session whose scrollback is requested.
  final SessionId sessionId;

  /// Client-assigned correlation identifier for unicast response matching.
  final int requestId;

  /// Expected [ScrollbackWindow.clearSeq] generation counter.
  final int clearSeq;

  /// Starting virtual line index in `[oldestLine .. totalLines)`.
  final int startLine;

  /// Number of scrollback lines requested (`1 .. ScrollbackChunkFrame.maxChunkRows`).
  final int count;

  /// Creates a scrollback slice request frame.
  const RequestScrollbackFrame({
    required this.sessionId,
    required this.requestId,
    required this.clearSeq,
    required this.startLine,
    required this.count,
  });
}

/// Caster response carrying up to [maxChunkRows] encoded scrollback rows.
final class ScrollbackChunkFrame extends CastMessage {
  /// Maximum number of scrollback rows allowed in a single wire chunk.
  static const int maxChunkRows = 128;

  /// Source session that produced these scrollback rows.
  final SessionId sessionId;

  /// Correlation identifier echoed from [RequestScrollbackFrame.requestId].
  final int requestId;

  /// Authoritative [ScrollbackWindow.clearSeq] generation counter of these rows.
  final int clearSeq;

  /// Virtual line index of `rows.first` (or clamped request start when `rows` is empty).
  final int startLine;

  /// Contiguous scrollback rows starting at [startLine] (`0 .. maxChunkRows`).
  final List<EncodedScrollbackRow> rows;

  /// Creates a scrollback chunk response frame.
  const ScrollbackChunkFrame({
    required this.sessionId,
    required this.requestId,
    required this.clearSeq,
    required this.startLine,
    required this.rows,
  });
}

/// Client request initiating a chunked file upload to [sessionId]'s host.
final class FileUploadStartFrame extends CastMessage {
  /// Maximum UTF-8 byte length allowed for [fileName].
  static const int maxFileNameBytes = 255;

  /// Target session receiving the uploaded file.
  final SessionId sessionId;

  /// Client-assigned correlation identifier for this file transfer (`uint32`).
  final int transferId;

  /// Sanitized base file name without directory separators (`1..255` UTF-8 bytes).
  final String fileName;

  /// Total size of the file in bytes (`0 .. 2^53 - 1`).
  final int totalBytes;

  /// Creates a file upload start frame.
  const FileUploadStartFrame({
    required this.sessionId,
    required this.transferId,
    required this.fileName,
    required this.totalBytes,
  });
}

/// Client frame carrying a contiguous byte slice of an active file upload.
final class FileUploadChunkFrame extends CastMessage {
  /// Maximum payload bytes allowed in a single upload chunk (`64 KiB`).
  static const int maxChunkBytes = 65536;

  /// Target session receiving the uploaded file chunk.
  final SessionId sessionId;

  /// Correlation identifier matching [FileUploadStartFrame.transferId].
  final int transferId;

  /// Zero-indexed starting byte offset of [data] within the file.
  final int offset;

  /// Raw file slice bytes (`1 .. maxChunkBytes`).
  final Uint8List data;

  /// Creates a file upload chunk frame.
  const FileUploadChunkFrame({
    required this.sessionId,
    required this.transferId,
    required this.offset,
    required this.data,
  });
}

/// Client frame completing or aborting an active file upload.
final class FileUploadEndFrame extends CastMessage {
  /// Required byte length of [sha256] when [aborted] is `false`.
  static const int sha256ByteLength = 32;

  /// Target session whose file upload is finishing or aborting.
  final SessionId sessionId;

  /// Correlation identifier matching [FileUploadStartFrame.transferId].
  final int transferId;

  /// Expected 32-byte SHA-256 digest of the complete file (empty when [aborted] is `true`).
  final Uint8List sha256;

  /// Whether the upload was cancelled or aborted before completion.
  final bool aborted;

  /// Creates a file upload completion or abort frame.
  const FileUploadEndFrame({
    required this.sessionId,
    required this.transferId,
    required this.sha256,
    this.aborted = false,
  });
}

/// Caster acknowledgment pacing chunked file uploads and reporting completion or errors.
final class FileUploadAckFrame extends CastMessage {
  /// Session that processed the upload frame.
  final SessionId sessionId;

  /// Correlation identifier echoed from the client's upload frames.
  final int transferId;

  /// Current status of the file transfer.
  final FileUploadStatus status;

  /// Cumulative byte offset confirmed written by the caster.
  final int nextOffset;

  /// Resolved host file path on [FileUploadStatus.completed], or diagnostic reason on [FileUploadStatus.rejected].
  final String message;

  /// Creates a file upload acknowledgment frame.
  const FileUploadAckFrame({
    required this.sessionId,
    required this.transferId,
    required this.status,
    required this.nextOffset,
    this.message = '',
  });
}

/// Client-to-caster reply carrying 256 IEEE-754 `Float32` waveform samples (`0x1A`).
final class AudioWaveformReplyFrame extends CastMessage {
  /// Required sample count (`256` floats = `1024` wire bytes).
  static const int sampleCount = 256;

  /// Required wire byte length of the little-endian `Float32` sample payload.
  static const int payloadByteLength = sampleCount * 4;

  /// Target session that issued the `a=wave` query.
  final SessionId sessionId;

  /// Correlation identifier echoed from [CastWaveformQueryAudioPayload.requestId].
  final int requestId;

  /// 256-element PCM waveform snapshot (`Float32List`).
  final Float32List samples;

  /// Creates an audio waveform reply frame.
  const AudioWaveformReplyFrame({
    required this.sessionId,
    required this.requestId,
    required this.samples,
  });
}

/// Wire byte encoding used by [KittyImageChunkFrame].
enum KittyChunkEncoding {
  /// Raw pixel bytes (`format == 32` RGBA8888 or `format == 100` PNG).
  raw(0),

  /// `deflate-raw` compressed payload bytes bounded to [KittyImageChunkFrame.totalDecodedBytes].
  deflateRaw(1);

  /// Wire discriminant byte (`0` or `1`).
  final int code;

  const KittyChunkEncoding(this.code);
}

/// Bounded wire chunk transferring large Kitty Graphics (`APC G`) textures (`0x1B`).
final class KittyImageChunkFrame extends CastMessage {
  /// Source session that owns this texture.
  final SessionId sessionId;

  /// Positive 32-bit Kitty image identifier (`1 .. 0xFFFFFFFF`).
  final int imageId;

  /// Monotonic per-image mutation version counter (`uint32`).
  final int version;

  /// Source image width in pixels (`1 .. 4096`).
  final int pixelWidth;

  /// Source image height in pixels (`1 .. 4096`).
  final int pixelHeight;

  /// Target placement width in terminal columns (`1 .. 512`).
  final int gridCols;

  /// Target placement height in terminal rows (`1 .. 512`).
  final int gridRows;

  /// Pixel format (`32` = RGBA8888, `100` = PNG).
  final int format;

  /// Wire compression encoding applied to the full reassembled payload.
  final KittyChunkEncoding encoding;

  /// Uncompressed decoded byte length (`pixelWidth * pixelHeight * 4` for RGBA32, or PNG byte length).
  final int totalDecodedBytes;

  /// Total concatenated wire payload bytes across all chunks (`1 .. 16 MiB`).
  final int totalWireBytes;

  /// Zero-indexed chunk ordinal (`0 .. chunkCount - 1`).
  final int chunkIndex;

  /// Total number of chunks composing this image transfer (`1 .. 256`).
  final int chunkCount;

  /// Slice of the wire payload (`1 .. BufferFrameCodec.maxKittyChunkBytes`).
  final Uint8List data;

  /// Creates a Kitty graphics image chunk frame.
  const KittyImageChunkFrame({
    required this.sessionId,
    required this.imageId,
    this.version = 0,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.gridCols,
    required this.gridRows,
    this.format = 32,
    this.encoding = KittyChunkEncoding.raw,
    required this.totalDecodedBytes,
    required this.totalWireBytes,
    required this.chunkIndex,
    required this.chunkCount,
    required this.data,
  });
}
