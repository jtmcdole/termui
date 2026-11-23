import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:termui/termui.dart';

/// Maximum UTF-8 byte length permitted for a single `OSC 8` hyperlink URI on the wire.
const int maxOsc8UriBytes = 2048;

/// Maximum UTF-8 byte length permitted for a session or shell title on the wire.
const int maxSessionTitleBytes = 512;

final RegExp _disallowedShellTitleChars = RegExp(
  r'[\x00-\x1F\x7F-\x9F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]',
);

/// Strips C0, DEL, C1, and Unicode bidi control characters from [raw],
/// trims surrounding whitespace, and truncates on a valid UTF-8 codepoint
/// boundary at `<= 512` UTF-8 bytes without leaving trailing whitespace.
String sanitizeShellTitle(String raw) {
  final stripped = raw.replaceAll(_disallowedShellTitleChars, '').trim();
  if (stripped.isEmpty) return '';
  if (stripped.length <= maxSessionTitleBytes ~/ 3) return stripped;
  final encoded = utf8.encode(stripped);
  if (encoded.length <= maxSessionTitleBytes) return stripped;
  var end = maxSessionTitleBytes;
  while (end > 0 && (encoded[end] & 0xC0) == 0x80) {
    end--;
  }
  if (end <= 0) return '';
  return utf8
      .decode(Uint8List.sublistView(encoded, 0, end), allowMalformed: true)
      .trim();
}

bool _hasOsc8ControlChars(String value) {
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit <= 0x1F || (unit >= 0x7F && unit <= 0x9F)) return true;
  }
  return false;
}

/// Sanitizes [raw] via [sanitizeOsc8Uri] and truncates on a valid UTF-8 codepoint
/// boundary so the result never exceeds [maxOsc8UriBytes] UTF-8 bytes.
String clampOsc8Uri(String raw) {
  if (raw.isEmpty) return '';
  final sanitized = _hasOsc8ControlChars(raw) ? sanitizeOsc8Uri(raw) : raw;
  if (sanitized.isEmpty) return '';
  if (sanitized.length <= maxOsc8UriBytes ~/ 3) return sanitized;
  final encoded = utf8.encode(sanitized);
  if (encoded.length <= maxOsc8UriBytes) return sanitized;
  var end = maxOsc8UriBytes;
  while (end > 0 && (encoded[end] & 0xC0) == 0x80) {
    end--;
  }
  return end <= 0
      ? ''
      : utf8.decode(
          Uint8List.sublistView(encoded, 0, end),
          allowMalformed: true,
        );
}

/// Contiguous relative cell span `[start, start + length)` sharing an `OSC 8` `uri`.
typedef UriRun = ({int start, int length, String uri});

/// Wire payload synchronizing a single Kitty Graphics (`APC G`) image entry.
final class KittyImagePayload {
  /// Wire header overhead in bytes excluding [bytes] (`4+2+2+2+2+4+1+4 = 21`).
  static const int wireHeaderBytes = 21;

  /// Unique 32-bit Kitty image identifier (`1..0xFFFFFFFF`).
  final int imageId;

  /// Source image width in pixels.
  final int pixelWidth;

  /// Source image height in pixels.
  final int pixelHeight;

  /// Target placement width in terminal columns.
  final int gridCols;

  /// Target placement height in terminal rows.
  final int gridRows;

  /// Monotonic per-image mutation version counter.
  final int version;

  /// Pixel payload format (`32` = RGBA8888, `100` = PNG).
  final int format;

  /// Raw RGBA8888 or PNG byte buffer.
  final Uint8List bytes;

  /// Creates an immutable Kitty image wire payload.
  const KittyImagePayload({
    required this.imageId,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.gridCols,
    required this.gridRows,
    this.version = 0,
    this.format = 32,
    required this.bytes,
  });

  /// Converts a `termui` [KittyImageData] descriptor into a [KittyImagePayload].
  factory KittyImagePayload.fromImageData(KittyImageData data) =>
      KittyImagePayload(
        imageId: data.imageId & 0xFFFFFFFF,
        pixelWidth: data.pixelWidth,
        pixelHeight: data.pixelHeight,
        gridCols: data.gridCols,
        gridRows: data.gridRows,
        version: data.version,
        format: data.format,
        bytes: data.rgbaPixels,
      );

  /// Materializes a `termui` [KittyImageData] descriptor from this payload.
  KittyImageData toImageData() => KittyImageData(
    imageId: imageId & 0xFFFFFFFF,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
    rgbaPixels: bytes,
    gridCols: gridCols,
    gridRows: gridRows,
    version: version,
    format: format,
  );

  /// Uncompressed wire byte count occupied by this entry inside a frame tail.
  int get wireByteLength => wireHeaderBytes + bytes.length;

  /// Uncompressed wire byte count that [data] would occupy inside a frame tail.
  static int estimateWireBytes(KittyImageData data) =>
      wireHeaderBytes + data.rgbaPixels.length;
}

/// Extracts non-zero SGR 58 underline colors from [buffer] across `[start, start + length)`,
/// keyed by relative index `0 ..< length`, or `null` when none are set.
Map<int, int>? extractBufferUnderlineColors(
  Buffer buffer,
  int start,
  int length,
) {
  if (!buffer.hasUnderlineColors || length <= 0) return null;
  Map<int, int>? result;
  for (var rel = 0; rel < length; rel++) {
    final color = buffer.getUnderlineColorAt(start + rel);
    if (color != 0) {
      (result ??= <int, int>{})[rel] = color;
    }
  }
  return result;
}

/// Extracts non-zero SGR 58 underline colors from [slice] clamped to [maxLength],
/// or `null` when none are set.
Map<int, int>? extractSliceUnderlineColors(Uint32List? slice, int maxLength) {
  if (slice == null || slice.isEmpty || maxLength <= 0) return null;
  final limit = min(slice.length, maxLength);
  Map<int, int>? result;
  for (var rel = 0; rel < limit; rel++) {
    final color = slice[rel];
    if (color != 0) {
      (result ??= <int, int>{})[rel] = color;
    }
  }
  return result;
}

/// Extracts contiguous sanitized `OSC 8` [UriRun] spans from [buffer] across
/// `[start, start + length)`, or `null` when none are set.
List<UriRun>? extractBufferUriRuns(Buffer buffer, int start, int length) {
  if (!buffer.hasUris || length <= 0) return null;
  return _collectUriRuns(length, (rel) => buffer.getUriAt(start + rel));
}

/// Extracts contiguous sanitized `OSC 8` [UriRun] spans from [slice] clamped to
/// [maxLength], or `null` when none are set.
List<UriRun>? extractSliceUriRuns(List<String?>? slice, int maxLength) {
  if (slice == null || slice.isEmpty || maxLength <= 0) return null;
  final limit = min(slice.length, maxLength);
  return _collectUriRuns(limit, (rel) => slice[rel]);
}

List<UriRun>? _collectUriRuns(int limit, String? Function(int rel) uriAt) {
  List<UriRun>? runs;
  var rel = 0;
  while (rel < limit) {
    final raw = uriAt(rel);
    final current = (raw == null || raw.isEmpty) ? '' : clampOsc8Uri(raw);
    if (current.isEmpty) {
      rel++;
      continue;
    }
    final runStart = rel;
    rel = _advanceMatchingUriRun(rel + 1, limit, raw, current, uriAt);
    (runs ??= <UriRun>[]).add((
      start: runStart,
      length: rel - runStart,
      uri: current,
    ));
  }
  return runs;
}

int _advanceMatchingUriRun(
  int startRel,
  int limit,
  String? raw,
  String current,
  String? Function(int rel) uriAt,
) {
  var rel = startRel;
  while (rel < limit) {
    final nextRaw = uriAt(rel);
    if (identical(nextRaw, raw) || nextRaw == raw) {
      rel++;
      continue;
    }
    final next = (nextRaw == null || nextRaw.isEmpty)
        ? ''
        : clampOsc8Uri(nextRaw);
    if (next != current) break;
    rel++;
  }
  return rel;
}

/// Applies optional sparse [underlineColors] and [uriRuns] onto [buffer] across
/// `[start, start + length)` after clearing any stale auxiliary values in that span.
void applyCellAuxToBuffer(
  Buffer buffer,
  int start,
  int length, {
  Map<int, int>? underlineColors,
  List<UriRun>? uriRuns,
}) {
  if (length <= 0) return;
  buffer.clearCellAuxRange(start, start + length);
  if (underlineColors != null) {
    _applySpanUnderlineColors(buffer, start, length, underlineColors);
  }
  if (uriRuns != null) {
    _applySpanUriRuns(buffer, start, length, uriRuns);
  }
}

void _applySpanUnderlineColors(
  Buffer buffer,
  int start,
  int length,
  Map<int, int> underlineColors,
) {
  for (final entry in underlineColors.entries) {
    if (entry.key >= 0 && entry.key < length && entry.value != 0) {
      buffer.setUnderlineColorAt(start + entry.key, entry.value);
    }
  }
}

void _applySpanUriRuns(
  Buffer buffer,
  int start,
  int length,
  List<UriRun> uriRuns,
) {
  for (final run in uriRuns) {
    final clean = clampOsc8Uri(run.uri);
    if (clean.isEmpty || run.start < 0 || run.length <= 0) continue;
    final endRel = min(length, run.start + run.length);
    for (var rel = run.start; rel < endRel; rel++) {
      buffer.setUriAt(start + rel, clean);
    }
  }
}

/// HTTP response header carrying the active relay server revision identifier.
const String castRevisionHeader = 'x-cast-revision';

/// Typed identifier for a live cast session.
extension type const SessionId(String value) {
  /// Whether this identifier is `1..128` printable ASCII characters (`0x21..0x7E`)
  /// free of path separators (`/`, `\`) and relative path segments (`.`, `..`).
  bool get isValid {
    if (value.isEmpty || value.length > 128) return false;
    if (value == '.' || value.contains('..')) return false;
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      if (unit < 0x21 || unit > 0x7E || unit == 0x2F || unit == 0x5C) {
        return false;
      }
    }
    return true;
  }
}

/// Parses and validates a WebSocket (`ws://`, `wss://`), `https://`, or bare
/// host relay endpoint [raw] with a non-empty host.
///
/// `https://` inputs are upgraded to `wss://`, `#fragment` components are
/// stripped, bare hosts without `://` default to `ws://` for loopback hosts
/// (`localhost`, `127.0.0.1`, `::1`) and `wss://` otherwise, and `http://` or
/// nested-scheme inputs such as `ws://https://...` throw [FormatException].
///
/// When [normalizeCasterPath] is `true`, `/v1/caster` suffixes are rewritten to
/// `/v1/client`. When [defaultPath] is non-null and the resolved path is empty
/// or `/`, it is replaced with [defaultPath].
Uri parseCastWebSocketUri(
  String raw, {
  String? defaultPath,
  bool normalizeCasterPath = false,
}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || _containsWhitespace(trimmed)) {
    throw FormatException(
      'Expected ws://, wss://, https://, or host URL with a non-empty host, got "$raw".',
    );
  }
  final hasExplicitScheme = trimmed.contains('://');
  final parsed = hasExplicitScheme
      ? Uri.tryParse(trimmed)
      : Uri.tryParse('wss://$trimmed');
  if (parsed == null) {
    throw FormatException(
      'Expected ws://, wss://, https://, or host URL with a non-empty host, got "$raw".',
    );
  }
  final scheme = _resolveRelayScheme(
    parsed,
    hasExplicitScheme: hasExplicitScheme,
    raw: raw,
  );
  final effectiveInput = hasExplicitScheme ? trimmed : 'wss://$trimmed';
  if (parsed.userInfo.isNotEmpty ||
      parsed.host.isEmpty ||
      parsed.path.startsWith('//') ||
      _hasInvalidAuthority(effectiveInput)) {
    throw FormatException(
      'Expected ws://, wss://, https://, or host URL with a non-empty host and no userinfo, got "$raw".',
    );
  }
  final nextPath = _resolveRelayPath(
    parsed.path,
    defaultPath: defaultPath,
    normalizeCasterPath: normalizeCasterPath,
  );
  return parsed.replace(scheme: scheme, path: nextPath).removeFragment();
}

bool _containsWhitespace(String value) {
  for (var i = 0; i < value.length; i++) {
    if (value.codeUnitAt(i) <= 0x20) return true;
  }
  return false;
}

String _resolveRelayScheme(
  Uri parsed, {
  required bool hasExplicitScheme,
  required String raw,
}) {
  if (!hasExplicitScheme) {
    return _isLoopbackHost(parsed.host) ? 'ws' : 'wss';
  }
  return switch (parsed.scheme) {
    'ws' => 'ws',
    'wss' || 'https' => 'wss',
    _ => throw FormatException(
      'Expected ws://, wss://, https://, or host URL with a non-empty host, got "$raw".',
    ),
  };
}

bool _isLoopbackHost(String host) {
  final lower = host.toLowerCase();
  return lower == 'localhost' || lower == '127.0.0.1' || lower == '::1';
}

bool _hasInvalidAuthority(String uriText) {
  final schemeSep = uriText.indexOf('://');
  if (schemeSep < 0) return true;
  final afterScheme = uriText.substring(schemeSep + 3);
  final slash = afterScheme.indexOf('/');
  final query = afterScheme.indexOf('?');
  final frag = afterScheme.indexOf('#');
  var end = afterScheme.length;
  for (final idx in [slash, query, frag]) {
    if (idx >= 0 && idx < end) end = idx;
  }
  final authority = afterScheme.substring(0, end);
  return authority.isEmpty || authority.endsWith(':');
}

String _resolveRelayPath(
  String path, {
  required String? defaultPath,
  required bool normalizeCasterPath,
}) {
  var nextPath = path;
  if (normalizeCasterPath) {
    if (nextPath == '/v1/caster') {
      nextPath = '/v1/client';
    } else if (nextPath.endsWith('/v1/caster')) {
      nextPath =
          '${nextPath.substring(0, nextPath.length - '/v1/caster'.length)}/v1/client';
    }
  }
  if (defaultPath != null && (nextPath.isEmpty || nextPath == '/')) {
    return defaultPath;
  }
  return nextPath;
}

/// Peer role authenticating with the relay server.
enum CastRole {
  /// Producer CLI streaming authoritative PTY buffers.
  caster,

  /// Viewer client rendering buffers and sending input or resize intent.
  client,
}

/// Reason a cast session ended and left the live directory.
enum SessionCloseReason {
  /// Child process exited or caster stopped cleanly.
  exited(0),

  /// Caster WebSocket dropped or timed out without a clean close frame.
  disconnected(1);

  /// Wire discriminant byte (`0` or `1`).
  final int code;

  const SessionCloseReason(this.code);
}

/// Lifecycle status reported by a caster in a `FileUploadAckFrame`.
enum FileUploadStatus {
  /// Caster staged the `.part` file and is ready to receive chunks at `nextOffset`.
  ready,

  /// Caster wrote a chunk and confirmed cumulative byte progress at `nextOffset`.
  chunkAck,

  /// Caster verified the SHA-256 digest, renamed the file, and injected the path.
  completed,

  /// Upload was rejected or failed validation; `message` carries the reason.
  rejected,
}

/// Directory metadata describing an active cast session.
final class SessionSummary {
  /// Unique identifier of the session.
  final SessionId id;

  /// Human-readable session label shown in client tabs.
  final String title;

  /// Current PTY width in columns.
  final int cols;

  /// Current PTY height in rows.
  final int rows;

  /// Number of currently subscribed viewer clients.
  final int subscriberCount;

  /// Whether [title] was explicitly pinned by a user rename rather than live shell `OSC 0`/`OSC 2`.
  final bool isUserPinned;

  /// Creates an immutable session directory entry.
  const SessionSummary({
    required this.id,
    required this.title,
    required this.cols,
    required this.rows,
    this.subscriberCount = 0,
    this.isUserPinned = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionSummary &&
          other.id == id &&
          other.title == title &&
          other.cols == cols &&
          other.rows == rows &&
          other.subscriberCount == subscriberCount &&
          other.isUserPinned == isUserPinned;

  @override
  int get hashCode =>
      Object.hash(id, title, cols, rows, subscriberCount, isUserPinned);
}

/// Wire-serializable terminal audio payload carried inside an `AudioFrame` (`0x19`).
sealed class CastAudioPayload {
  /// Maximum decoded audio clip payload size allowed in bytes (`2 MiB`).
  static const int maxClipBytes = 2 * 1024 * 1024;

  /// Creates an immutable wire audio payload.
  const CastAudioPayload();
}

/// Synthetic waveform tone request carried over the cast wire protocol.
final class CastToneAudioPayload extends CastAudioPayload {
  /// Canonical waveform identifier (`'sine'`, `'square'`, `'saw'`, `'triangle'`, etc.).
  final String waveform;

  /// Tone frequency in Hertz (`> 0`).
  final double frequencyHz;

  /// Tone playback duration (`>= Duration.zero`).
  final Duration duration;

  /// Playback volume in `0.0 .. 1.0`.
  final double volume;

  /// Stereo pan in `-1.0 .. 1.0`.
  final double pan;

  /// Optional positive 32-bit mixing bus identifier (`1 .. 0xFFFFFFFF`).
  final int? busId;

  /// Creates a synthetic waveform tone payload.
  const CastToneAudioPayload({
    required this.waveform,
    required this.frequencyHz,
    required this.duration,
    this.volume = 0.8,
    this.pan = 0.0,
    this.busId,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CastToneAudioPayload &&
          other.waveform == waveform &&
          other.frequencyHz == frequencyHz &&
          other.duration == duration &&
          other.volume == volume &&
          other.pan == pan &&
          other.busId == busId;

  @override
  int get hashCode =>
      Object.hash(waveform, frequencyHz, duration, volume, pan, busId);
}

/// Audio clip playback payload carried over the cast wire protocol.
final class CastClipAudioPayload extends CastAudioPayload {
  /// Positive 32-bit clip identifier.
  final int clipId;

  /// Audio container format (`'wav'`, `'ogg'`, or `'mp3'`).
  final String format;

  /// Decoded audio container bytes (`1 .. maxClipBytes`).
  final Uint8List bytes;

  /// Playback volume in `0.0 .. 1.0`.
  final double volume;

  /// Stereo pan in `-1.0 .. 1.0`.
  final double pan;

  /// Whether clip playback loops until stopped.
  final bool loop;

  /// Initial playback start offset (`playSprite` start position).
  final Duration startOffset;

  /// Optional positive 32-bit mixing bus identifier (`1 .. 0xFFFFFFFF`).
  final int? busId;

  /// Optional positive 32-bit open buffer stream identifier (`1 .. 0xFFFFFFFF`).
  final int? streamId;

  /// Creates an audio clip playback payload.
  const CastClipAudioPayload({
    required this.clipId,
    required this.format,
    required this.bytes,
    this.volume = 1.0,
    this.pan = 0.0,
    this.loop = false,
    this.startOffset = Duration.zero,
    this.busId,
    this.streamId,
  });
}

/// Audio stop request carried over the cast wire protocol.
final class CastStopAudioPayload extends CastAudioPayload {
  /// Target 32-bit clip identifier to stop, or `null` to stop all active clips.
  final int? clipId;

  /// Creates an audio stop payload.
  const CastStopAudioPayload({this.clipId});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CastStopAudioPayload && other.clipId == clipId;

  @override
  int get hashCode => clipId.hashCode;
}

/// Live voice parameter and transport update carried over the cast wire protocol.
final class CastUpdateAudioPayload extends CastAudioPayload {
  /// Positive 32-bit clip identifier (`1 .. 0xFFFFFFFF`).
  final int clipId;

  /// Optional updated playback volume in `0.0 .. 1.0`.
  final double? volume;

  /// Optional updated stereo pan in `-1.0 .. 1.0`.
  final double? pan;

  /// Optional seek target position (`>= Duration.zero`).
  final Duration? seekPosition;

  /// Optional pause state (`true` pauses, `false` resumes).
  final bool? paused;

  /// Optional relative playback speed multiplier in `0.125 .. 8.0`.
  final double? speed;

  /// Optional pitch-preservation flag for speed changes.
  final bool? preservePitch;

  /// Optional volume fade target in `0.0 .. 1.0`, paired with [fadeVolumeDuration].
  final double? fadeVolumeTarget;

  /// Optional volume fade duration, paired with [fadeVolumeTarget].
  final Duration? fadeVolumeDuration;

  /// Optional speed fade target in `0.125 .. 8.0`, paired with [fadeSpeedDuration].
  final double? fadeSpeedTarget;

  /// Optional speed fade duration, paired with [fadeSpeedTarget].
  final Duration? fadeSpeedDuration;

  /// Optional scheduled stop delay (`>= Duration.zero`).
  final Duration? scheduleStopDuration;

  /// Creates a live voice update payload.
  const CastUpdateAudioPayload({
    required this.clipId,
    this.volume,
    this.pan,
    this.seekPosition,
    this.paused,
    this.speed,
    this.preservePitch,
    this.fadeVolumeTarget,
    this.fadeVolumeDuration,
    this.fadeSpeedTarget,
    this.fadeSpeedDuration,
    this.scheduleStopDuration,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CastUpdateAudioPayload &&
          other.clipId == clipId &&
          other.volume == volume &&
          other.pan == pan &&
          other.seekPosition == seekPosition &&
          other.paused == paused &&
          other.speed == speed &&
          other.preservePitch == preservePitch &&
          other.fadeVolumeTarget == fadeVolumeTarget &&
          other.fadeVolumeDuration == fadeVolumeDuration &&
          other.fadeSpeedTarget == fadeSpeedTarget &&
          other.fadeSpeedDuration == fadeSpeedDuration &&
          other.scheduleStopDuration == scheduleStopDuration;

  @override
  int get hashCode => Object.hashAll([
    clipId,
    volume,
    pan,
    seekPosition,
    paused,
    speed,
    preservePitch,
    fadeVolumeTarget,
    fadeVolumeDuration,
    fadeSpeedTarget,
    fadeSpeedDuration,
    scheduleStopDuration,
  ]);
}

/// Mixing bus lifecycle or DSP filter command carried over the cast wire protocol.
final class CastBusAudioPayload extends CastAudioPayload {
  /// Bus operation (`'create'`, `'destroy'`, `'vol'`, `'attach'`, `'param'`, or `'fade'`).
  final String op;

  /// Positive 32-bit bus identifier (`1 .. 0xFFFFFFFF`).
  final int busId;

  /// Optional DSP filter type index (`0 .. 11`) for `'attach'`, `'param'`, and `'fade'`.
  final int? filterId;

  /// Optional filter parameter index (`0 .. 66`) for `'param'` and `'fade'`.
  final int? paramId;

  /// Optional bus volume (`0.0 .. 1.0`) for `'vol'`, or filter parameter value for `'param'` / `'fade'`.
  final double? value;

  /// Optional fade duration (`>= Duration.zero`) for `'fade'`.
  final Duration? duration;

  /// Creates a mixing bus lifecycle or DSP filter payload.
  const CastBusAudioPayload({
    required this.op,
    required this.busId,
    this.filterId,
    this.paramId,
    this.value,
    this.duration,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CastBusAudioPayload &&
          other.op == op &&
          other.busId == busId &&
          other.filterId == filterId &&
          other.paramId == paramId &&
          other.value == value &&
          other.duration == duration;

  @override
  int get hashCode =>
      Object.hash(op, busId, filterId, paramId, value, duration);
}

/// Pass-through buffer stream lifecycle or chunk payload carried over the cast wire protocol.
final class CastStreamAudioPayload extends CastAudioPayload {
  /// Maximum compressed stream payload bytes (`16 MiB`).
  static const int maxStreamBytes = 16 * 1024 * 1024;

  /// Maximum decoded PCM stream buffer size allowed in bytes (`128 MiB`).
  static const int maxStreamBufferBytes = 128 * 1024 * 1024;

  /// Stream operation (`'open'`, `'chunk'`, or `'end'`).
  final String op;

  /// Positive 32-bit stream identifier (`1 .. 0xFFFFFFFF`).
  final int streamId;

  /// Monotonic chunk sequence number (`>= 0`) for `'chunk'` and optionally `'end'`.
  final int? seq;

  /// Maximum decoded PCM buffer size in bytes (`1 .. 128 MiB`) for `'open'`.
  final int? maxBufferSize;

  /// Whether consumed samples are released from the circular buffer (`'open'`).
  final bool? releaseConsumed;

  /// Target pre-playback buffering duration (`'open'`).
  final Duration? bufferingTimeNeeds;

  /// Sample rate in Hertz (`1 .. 384000`) for `'open'`.
  final int? sampleRate;

  /// Channel count (`1` mono or `2` stereo) for `'open'`.
  final int? channels;

  /// Raw audio chunk bytes for `'chunk'`.
  final Uint8List? chunkBytes;

  /// Creates a pass-through buffer stream wire payload.
  const CastStreamAudioPayload({
    required this.op,
    required this.streamId,
    this.seq,
    this.maxBufferSize,
    this.releaseConsumed,
    this.bufferingTimeNeeds,
    this.sampleRate,
    this.channels,
    this.chunkBytes,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CastStreamAudioPayload &&
          other.op == op &&
          other.streamId == streamId &&
          other.seq == seq &&
          other.maxBufferSize == maxBufferSize &&
          other.releaseConsumed == releaseConsumed &&
          other.bufferingTimeNeeds == bufferingTimeNeeds &&
          other.sampleRate == sampleRate &&
          other.channels == channels &&
          _bytesEqual(other.chunkBytes, chunkBytes);

  @override
  int get hashCode => Object.hash(
    op,
    streamId,
    seq,
    maxBufferSize,
    releaseConsumed,
    bufferingTimeNeeds,
    sampleRate,
    channels,
    chunkBytes == null ? null : Object.hashAll(chunkBytes!),
  );

  static bool _bytesEqual(Uint8List? a, Uint8List? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Host waveform capture query carried over the cast wire protocol (`0x19`).
final class CastWaveformQueryAudioPayload extends CastAudioPayload {
  /// Positive 31-bit query correlation identifier (`1 .. 0x7FFFFFFF`).
  final int requestId;

  /// Creates a waveform capture query payload.
  const CastWaveformQueryAudioPayload({required this.requestId});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CastWaveformQueryAudioPayload && other.requestId == requestId;

  @override
  int get hashCode => requestId.hashCode;
}

/// Visual cursor style set via `DECSCUSR` (`CSI Ps SP q`).
enum CursorShape {
  /// Terminal default cursor style (`Ps = 0`).
  defaultShape,

  /// Blinking block cursor (`Ps = 1`).
  blinkingBlock,

  /// Steady block cursor (`Ps = 2`).
  steadyBlock,

  /// Blinking underline cursor (`Ps = 3`).
  blinkingUnderline,

  /// Steady underline cursor (`Ps = 4`).
  steadyUnderline,

  /// Blinking vertical bar cursor (`Ps = 5`).
  blinkingBar,

  /// Steady vertical bar cursor (`Ps = 6`).
  steadyBar,
}

/// Zero-indexed cursor coordinates, visibility flag, and visual shape.
final class CursorState {
  /// Zero-indexed column position.
  final int x;

  /// Zero-indexed row position.
  final int y;

  /// Whether the terminal cursor should be drawn.
  final bool visible;

  /// Active `DECSCUSR` cursor shape.
  final CursorShape shape;

  /// Creates a cursor state snapshot.
  const CursorState({
    required this.x,
    required this.y,
    this.visible = true,
    this.shape = CursorShape.defaultShape,
  });

  /// Origin cursor at `(0, 0)` with visibility enabled and default shape.
  static const CursorState origin = CursorState(x: 0, y: 0);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CursorState &&
          other.x == x &&
          other.y == y &&
          other.visible == visible &&
          other.shape == shape;

  @override
  int get hashCode => Object.hash(x, y, visible, shape);
}

/// Terminal input reporting flags tracked alongside the screen grid.
final class TerminalModes {
  /// Whether DECSET mouse tracking (`1000`/`1002`/`1003`) is active.
  final bool mouseTracking;

  /// Whether SGR extended mouse encoding (`1006`) is active.
  final bool sgrMouse;

  /// Whether SGR-Pixels mouse encoding (`DECSET 1016`, `?1016h`) is active.
  final bool sgrPixelsMouse;

  /// Whether bracketed paste mode (`DECSET 2004`, `?2004h`) is active.
  final bool bracketedPaste;

  /// Whether the alternate screen buffer (`?47`/`?1047`/`?1049`) is active.
  final bool altScreen;

  /// Whether application cursor keys (`DECCKM`, `?1h`) are active.
  final bool appCursorKeys;

  /// Whether alternate scroll mode (`DECSET 1007`, `?1007h`) is active.
  final bool alternateScroll;

  /// Whether focus in/out reporting (`DECSET 1004`, `?1004h`) is active.
  final bool focusReporting;

  /// Active Kitty keyboard protocol progressive enhancement flags (`CSI > flags u`).
  final int kittyKeyboardFlags;

  /// Creates terminal mode flags.
  const TerminalModes({
    this.mouseTracking = false,
    this.sgrMouse = false,
    this.sgrPixelsMouse = false,
    this.bracketedPaste = false,
    this.altScreen = false,
    this.appCursorKeys = false,
    this.alternateScroll = true,
    this.focusReporting = false,
    this.kittyKeyboardFlags = 0,
  });

  /// Default inactive terminal modes.
  static const TerminalModes defaults = TerminalModes();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalModes &&
          other.mouseTracking == mouseTracking &&
          other.sgrMouse == sgrMouse &&
          other.sgrPixelsMouse == sgrPixelsMouse &&
          other.bracketedPaste == bracketedPaste &&
          other.altScreen == altScreen &&
          other.appCursorKeys == appCursorKeys &&
          other.alternateScroll == alternateScroll &&
          other.focusReporting == focusReporting &&
          other.kittyKeyboardFlags == kittyKeyboardFlags;

  @override
  int get hashCode => Object.hash(
    mouseTracking,
    sgrMouse,
    sgrPixelsMouse,
    bracketedPaste,
    altScreen,
    appCursorKeys,
    alternateScroll,
    focusReporting,
    kittyKeyboardFlags,
  );

  @override
  String toString() =>
      'TerminalModes(mouseTracking: $mouseTracking, sgrMouse: $sgrMouse, '
      'sgrPixelsMouse: $sgrPixelsMouse, bracketedPaste: $bracketedPaste, '
      'altScreen: $altScreen, appCursorKeys: $appCursorKeys, '
      'alternateScroll: $alternateScroll, focusReporting: $focusReporting, '
      'kittyKeyboardFlags: $kittyKeyboardFlags)';
}

/// Scrollback ring buffer window metadata attached to buffer keyframes and deltas.
final class ScrollbackWindow {
  /// Monotonic counter incremented when scrollback is cleared (`CSI 3 J` / `RIS`).
  final int clearSeq;

  /// Virtual line index of the oldest retained scrollback line (`<= totalLines`).
  final int oldestLine;

  /// Total number of lines evicted since session start or the last clear.
  final int totalLines;

  /// Creates scrollback window metadata.
  const ScrollbackWindow({
    required this.clearSeq,
    required this.oldestLine,
    required this.totalLines,
  });

  /// Empty initial scrollback window at `(clearSeq: 0, oldestLine: 0, totalLines: 0)`.
  static const ScrollbackWindow empty = ScrollbackWindow(
    clearSeq: 0,
    oldestLine: 0,
    totalLines: 0,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScrollbackWindow &&
          other.clearSeq == clearSeq &&
          other.oldestLine == oldestLine &&
          other.totalLines == totalLines;

  @override
  int get hashCode => Object.hash(clearSeq, oldestLine, totalLines);
}

/// Compact wire-encoded primary-screen scrollback row.
final class EncodedScrollbackRow {
  /// Whether this row began via right-margin auto-wrap from the preceding row.
  final bool isWrapped;

  /// Cell graphemes (trimmed of trailing default-styled blank spaces).
  final List<String> characters;

  /// Packed `[fg, bg, mod]` triples (`length == characters.length * 3`).
  final Uint32List attributes;

  /// Optional sparse non-zero SGR 58 underline colors keyed by column index.
  final Map<int, int>? underlineColors;

  /// Optional contiguous `OSC 8` hyperlink runs along this row.
  final List<UriRun>? uriRuns;

  /// Creates an encoded scrollback row.
  const EncodedScrollbackRow({
    required this.isWrapped,
    required this.characters,
    required this.attributes,
    this.underlineColors,
    this.uriRuns,
  });
}

/// Returns the byte length of the packed row-wrap bitset for [rows] grid rows.
int wrappedRowsByteLength(int rows) => rows <= 0 ? 0 : (rows + 7) >> 3;

/// Packs soft-wrap flags for `0 ..< rows` into a canonical little-bit-order bitset.
Uint8List packWrappedRows(int rows, bool Function(int row) isWrapped) {
  final packed = Uint8List(wrappedRowsByteLength(rows));
  for (var row = 0; row < rows; row++) {
    if (isWrapped(row)) {
      packed[row >> 3] |= 1 << (row & 7);
    }
  }
  return packed;
}

/// Reads whether `0`-indexed [row] is marked wrapped in [wrappedRows].
bool unpackWrappedRow(Uint8List wrappedRows, int rows, int row) {
  if (row < 0 || row >= rows) return false;
  final byteIndex = row >> 3;
  if (byteIndex >= wrappedRows.length) return false;
  return (wrappedRows[byteIndex] & (1 << (row & 7))) != 0;
}

/// Full keyframe of a session's authoritative [Buffer] at sequence [seq].
final class BufferSnapshot {
  /// Identifier of the session that produced this keyframe.
  final SessionId sessionId;

  /// Monotonically increasing frame sequence number.
  final int seq;

  /// Grid width in columns.
  final int cols;

  /// Grid height in rows.
  final int rows;

  /// Cursor coordinates and visibility at [seq].
  final CursorState cursor;

  /// Mouse and input modes active at [seq].
  final TerminalModes modes;

  /// Authoritative scrollback ring buffer window metadata at [seq].
  final ScrollbackWindow scrollback;

  /// Packed little-bit-order row soft-wrap bitset of length `wrappedRowsByteLength(rows)`.
  final Uint8List wrappedRows;

  /// Flat row-major grapheme list of length `cols * rows`.
  final List<String> characters;

  /// Flat `[fg, bg, mod, ...]` attribute words of length `cols * rows * 3`.
  final Uint32List attributes;

  /// Optional sparse non-zero SGR 58 underline colors keyed by cell index.
  final Map<int, int>? underlineColors;

  /// Optional contiguous `OSC 8` hyperlink runs across `0 ..< cols * rows`.
  final List<UriRun>? uriRuns;

  /// Optional active Kitty Graphics (`APC G`) texture payloads synced at [seq].
  final List<KittyImagePayload>? kittyImages;

  /// Creates a full buffer snapshot keyframe.
  BufferSnapshot({
    required this.sessionId,
    required this.seq,
    required this.cols,
    required this.rows,
    required this.cursor,
    required this.modes,
    this.scrollback = ScrollbackWindow.empty,
    Uint8List? wrappedRows,
    required this.characters,
    required this.attributes,
    this.underlineColors,
    this.uriRuns,
    this.kittyImages,
  }) : wrappedRows = wrappedRows ?? Uint8List(wrappedRowsByteLength(rows));

  /// Copies the current cell and auxiliary arrays of [buffer] into an immutable keyframe.
  factory BufferSnapshot.fromBuffer({
    required SessionId sessionId,
    required int seq,
    required Buffer buffer,
    required CursorState cursor,
    required TerminalModes modes,
    ScrollbackWindow scrollback = ScrollbackWindow.empty,
    Uint8List? wrappedRows,
    List<KittyImagePayload>? kittyImages,
  }) {
    final totalCells = buffer.width * buffer.height;
    return BufferSnapshot(
      sessionId: sessionId,
      seq: seq,
      cols: buffer.width,
      rows: buffer.height,
      cursor: cursor,
      modes: modes,
      scrollback: scrollback,
      wrappedRows: wrappedRows,
      characters: [...buffer.characters],
      attributes: Uint32List.fromList(buffer.attributes),
      underlineColors: extractBufferUnderlineColors(buffer, 0, totalCells),
      uriRuns: extractBufferUriRuns(buffer, 0, totalCells),
      kittyImages: kittyImages,
    );
  }

  /// Whether `0`-indexed [row] began via soft-wrap from the preceding row.
  bool isRowWrapped(int row) => unpackWrappedRow(wrappedRows, rows, row);

  /// Materializes a fresh [Buffer] populated from this keyframe.
  Buffer toBuffer() {
    final buffer = Buffer.blank(cols, rows);
    buffer.characters.setRange(0, characters.length, characters);
    buffer.attributes.setRange(0, attributes.length, attributes);
    applyCellAuxToBuffer(
      buffer,
      0,
      characters.length,
      underlineColors: underlineColors,
      uriRuns: uriRuns,
    );
    return buffer;
  }
}

/// Contiguous 1D span of modified cells inside a [BufferDelta].
final class CellRun {
  /// Zero-indexed starting cell offset in `0 ..< cols * rows`.
  final int startIndex;

  /// Updated grapheme cluster strings for this span.
  final List<String> characters;

  /// Updated `[fg, bg, mod]` triples of length `characters.length * 3`.
  final Uint32List attributes;

  /// Optional sparse non-zero SGR 58 underline colors keyed by relative span offset.
  final Map<int, int>? underlineColors;

  /// Optional contiguous `OSC 8` hyperlink runs keyed by relative span offset.
  final List<UriRun>? uriRuns;

  /// Creates a contiguous cell update run.
  const CellRun({
    required this.startIndex,
    required this.characters,
    required this.attributes,
    this.underlineColors,
    this.uriRuns,
  });
}

/// Incremental cell-run update advancing a session from [baseSeq] to [seq].
final class BufferDelta {
  /// Identifier of the session that produced this delta.
  final SessionId sessionId;

  /// Monotonically increasing sequence number of this frame.
  final int seq;

  /// Sequence number of the state this delta must be applied against.
  final int baseSeq;

  /// Expected grid width in columns.
  final int cols;

  /// Expected grid height in rows.
  final int rows;

  /// Updated cursor coordinates and visibility.
  final CursorState cursor;

  /// Updated terminal input modes.
  final TerminalModes modes;

  /// Authoritative scrollback ring buffer window metadata at [seq].
  final ScrollbackWindow scrollback;

  /// Packed little-bit-order row soft-wrap bitset of length `wrappedRowsByteLength(rows)`.
  final Uint8List wrappedRows;

  /// Ordered non-overlapping runs of modified cells.
  final List<CellRun> runs;

  /// Whether all previously registered Kitty images must be cleared before applying updates.
  final bool clearKittyImages;

  /// Optional 32-bit Kitty image IDs deleted since [baseSeq].
  final List<int>? kittyRemovals;

  /// Optional new or updated Kitty image entries uploaded since [baseSeq].
  final List<KittyImagePayload>? kittyUpserts;

  /// Creates a sequenced buffer delta frame.
  BufferDelta({
    required this.sessionId,
    required this.seq,
    required this.baseSeq,
    required this.cols,
    required this.rows,
    required this.cursor,
    required this.modes,
    this.scrollback = ScrollbackWindow.empty,
    Uint8List? wrappedRows,
    required this.runs,
    this.clearKittyImages = false,
    this.kittyRemovals,
    this.kittyUpserts,
  }) : wrappedRows = wrappedRows ?? Uint8List(wrappedRowsByteLength(rows));

  /// Whether `0`-indexed [row] began via soft-wrap from the preceding row.
  bool isRowWrapped(int row) => unpackWrappedRow(wrappedRows, rows, row);
}

/// Wire-serializable CLI artistic shader or cell-transform payload carried in `ShaderFrame` (`0x1C`).
sealed class CastShaderPayload {
  /// Maximum wire byte budget allowed for a single `0x1C` `ShaderFrame` (`64 KiB`).
  static const int maxWireBytes = 64 * 1024;

  /// Maximum decoded UTF-8 byte length for a custom CLI GLSL shader (`32 KiB`).
  static const int maxGlslBytes = 32 * 1024;

  /// Creates an immutable cast shader payload.
  const CastShaderPayload();
}

/// Custom CLI Ghostty Shadertoy GLSL shader definition (`kind = 0`).
final class CastDefineShaderPayload extends CastShaderPayload {
  /// Logical shader slot identifier (`1..64` ASCII identifier characters).
  final String id;

  /// UTF-8 GLSL fragment shader source (`1..32768` bytes).
  final String glslSource;

  /// Whether the shader requests previous-frame feedback (`persist=1`).
  final bool persist;

  /// Creates a custom GLSL shader definition payload.
  const CastDefineShaderPayload({
    required this.id,
    required this.glslSource,
    this.persist = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CastDefineShaderPayload &&
          other.id == id &&
          other.glslSource == glslSource &&
          other.persist == persist;

  @override
  int get hashCode => Object.hash(id, glslSource, persist);
}

/// Scoped [ShaderRegion] attach, update, or removal (`kind = 1`).
final class CastRegionShaderPayload extends CastShaderPayload {
  /// Logical region identifier.
  final String id;

  /// Region configuration when [remove] is `false`, or `null` when removing.
  final ShaderRegion? region;

  /// Whether this payload removes the region identified by [id].
  final bool remove;

  /// Creates a scoped shader region payload.
  const CastRegionShaderPayload({
    required this.id,
    this.region,
    this.remove = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CastRegionShaderPayload &&
          other.id == id &&
          other.region == region &&
          other.remove == remove;

  @override
  int get hashCode => Object.hash(id, region, remove);
}

/// Batched per-cell spatial transforms using the `64`-byte wire stride (`kind = 2`).
final class CastTransformsShaderPayload extends CastShaderPayload {
  /// Ordered cell transform updates (`transform == null` removes the transform).
  final List<CellTransformEntry> entries;

  /// Whether existing cell transforms should be cleared before applying [entries].
  final bool replace;

  /// Creates a batched per-cell transform payload.
  CastTransformsShaderPayload({
    required List<CellTransformEntry> entries,
    this.replace = false,
  }) : entries = List<CellTransformEntry>.unmodifiable(entries);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CastTransformsShaderPayload) return false;
    if (other.replace != replace || other.entries.length != entries.length) {
      return false;
    }
    for (var i = 0; i < entries.length; i++) {
      if (other.entries[i] != entries[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(replace, Object.hashAll(entries));
}

/// Full-pane CLI shader activation or clear (`kind = 3`).
final class CastSetShaderPayload extends CastShaderPayload {
  /// Target stage (`'bg'`, `'fg'`, or `'post'`).
  final String stage;

  /// Optional built-in preset identifier.
  final String? presetId;

  /// Optional CLI-defined custom GLSL shader identifier.
  final String? shaderId;

  /// Eight initial user uniform floats (`p0..p7`), clamped to `[-16.0, 16.0]`.
  final Float32List params;

  /// Whether this payload clears the CLI full-pane override for [stage].
  final bool clear;

  /// Creates a full-pane shader set or clear payload.
  CastSetShaderPayload({
    this.stage = 'post',
    this.presetId,
    this.shaderId,
    Float32List? params,
    this.clear = false,
  }) : params = ShaderRegion.sanitizeParams(params);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CastSetShaderPayload) return false;
    if (other.stage != stage ||
        other.presetId != presetId ||
        other.shaderId != shaderId ||
        other.clear != clear ||
        other.params.length != params.length) {
      return false;
    }
    for (var i = 0; i < params.length; i++) {
      if (other.params[i] != params[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(stage, presetId, shaderId, clear, Object.hashAll(params));
}

/// Live uniform update (`p0..p7`) without shader recompilation (`kind = 4`).
final class CastUniformShaderPayload extends CastShaderPayload {
  /// Target region/shader identifier, or `null` for the active full-pane shader.
  final String? id;

  /// Bitmask (`bit0..bit7`) indicating which `p0..p7` indices are updated.
  final int paramMask;

  /// Eight float slots (only slots with bits set in [paramMask] are active).
  final Float32List params;

  /// Creates a live uniform update payload.
  CastUniformShaderPayload({
    this.id,
    required this.paramMask,
    required Float32List params,
  }) : params = ShaderRegion.sanitizeParams(params);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CastUniformShaderPayload) return false;
    if (other.id != id ||
        other.paramMask != paramMask ||
        other.params.length != params.length) {
      return false;
    }
    for (var i = 0; i < params.length; i++) {
      if (other.params[i] != params[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(id, paramMask, Object.hashAll(params));
}

/// CLI shader/transform reset command (`kind = 5`).
final class CastResetShaderPayload extends CastShaderPayload {
  /// Target scope (`'all'`, `'regions'`, `'xforms'`, or `'pane'`).
  final String target;

  /// Creates a shader reset payload.
  const CastResetShaderPayload({this.target = 'all'});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CastResetShaderPayload && other.target == target;

  @override
  int get hashCode => target.hashCode;
}
