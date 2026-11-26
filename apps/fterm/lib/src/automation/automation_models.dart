import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show Listenable, listEquals;

/// Coordinate unit space for native window bounds requests.
enum WindowBoundsUnits {
  /// Physical device pixels (default).
  physical('physical'),

  /// DPI-scaled logical pixels.
  logical('logical');

  /// Canonical JSON and method-channel wire identifier.
  final String wireName;

  const WindowBoundsUnits(this.wireName);

  /// Parses [raw] from its [wireName], or returns `null` when unrecognized.
  static WindowBoundsUnits? tryFromWireName(Object? raw) => switch (raw) {
    'physical' => .physical,
    'logical' => .logical,
    _ => null,
  };
}

/// Immutable rectangular window geometry in either physical or logical units.
final class WindowBoundsRect {
  /// Zero-origin, zero-sized rectangle.
  static const WindowBoundsRect zero = WindowBoundsRect(
    x: 0,
    y: 0,
    width: 0,
    height: 0,
  );

  /// Left edge coordinate.
  final double x;

  /// Top edge coordinate.
  final double y;

  /// Non-negative rectangle width.
  final double width;

  /// Non-negative rectangle height.
  final double height;

  /// Creates an immutable [WindowBoundsRect].
  const WindowBoundsRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  /// Parses a [WindowBoundsRect] from a JSON or method-channel map, returning
  /// `null` when any coordinate is missing, non-finite, or negative for size.
  static WindowBoundsRect? tryFromMap(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    final x = _tryFiniteDouble(raw['x']);
    final y = _tryFiniteDouble(raw['y']);
    final width = _tryFiniteDouble(raw['width']);
    final height = _tryFiniteDouble(raw['height']);
    if (x == null || y == null || width == null || height == null) return null;
    if (width < 0 || height < 0) return null;
    return WindowBoundsRect(x: x, y: y, width: width, height: height);
  }

  /// Serializes this rectangle as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WindowBoundsRect &&
          other.x == x &&
          other.y == y &&
          other.width == width &&
          other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() =>
      'WindowBoundsRect(x: $x, y: $y, width: $width, height: $height)';
}

/// Immutable snapshot of native desktop window geometry and chrome flags.
final class WindowBoundsSnapshot {
  /// Placeholder returned on platforms without native window bounds support.
  static const WindowBoundsSnapshot unsupported = WindowBoundsSnapshot(
    supported: false,
  );

  /// Whether native window bounds inspection and mutation are supported.
  final bool supported;

  /// Visible window frame in physical pixels, or `null` when unsupported.
  final WindowBoundsRect? physical;

  /// Visible window frame in logical pixels, or `null` when unsupported.
  final WindowBoundsRect? logical;

  /// Current window device pixel ratio (`dpi / 96.0`).
  final double dpr;

  /// Whether the native window is pinned above non-topmost windows.
  final bool alwaysOnTop;

  /// Whether Windows 11 rounded corners are suppressed for crisp capture edges.
  final bool squareCorners;

  /// Creates an immutable [WindowBoundsSnapshot].
  const WindowBoundsSnapshot({
    required this.supported,
    this.physical,
    this.logical,
    this.dpr = 1.0,
    this.alwaysOnTop = false,
    this.squareCorners = false,
  });

  /// Parses a [WindowBoundsSnapshot] returned by `MethodChannel('fterm/window')`.
  factory WindowBoundsSnapshot.fromChannelMap(Map<Object?, Object?>? map) {
    if (map == null || map['supported'] != true) return unsupported;
    final physical = WindowBoundsRect.tryFromMap(map['physical']);
    final logical = WindowBoundsRect.tryFromMap(map['logical']);
    if (physical == null && logical == null) return unsupported;
    final rawDpr = _tryFiniteDouble(map['dpr']);
    final dpr = (rawDpr != null && rawDpr > 0) ? rawDpr : 1.0;
    return WindowBoundsSnapshot(
      supported: true,
      physical: physical,
      logical: logical,
      dpr: dpr,
      alwaysOnTop: map['alwaysOnTop'] == true,
      squareCorners: map['squareCorners'] == true,
    );
  }

  /// Serializes this snapshot as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'supported': supported,
    if (physical case final rect?) 'physical': rect.toJson(),
    if (logical case final rect?) 'logical': rect.toJson(),
    'dpr': dpr,
    'alwaysOnTop': alwaysOnTop,
    'squareCorners': squareCorners,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WindowBoundsSnapshot &&
          other.supported == supported &&
          other.physical == physical &&
          other.logical == logical &&
          other.dpr == dpr &&
          other.alwaysOnTop == alwaysOnTop &&
          other.squareCorners == squareCorners;

  @override
  int get hashCode => Object.hash(
    supported,
    physical,
    logical,
    dpr,
    alwaysOnTop,
    squareCorners,
  );

  @override
  String toString() =>
      'WindowBoundsSnapshot(supported: $supported, physical: $physical, '
      'logical: $logical, dpr: $dpr, alwaysOnTop: $alwaysOnTop, '
      'squareCorners: $squareCorners)';
}

/// Immutable request to update native window placement, size, and flags.
final class WindowBoundsRequest {
  /// Optional target left coordinate in [units].
  final double? x;

  /// Optional target top coordinate in [units].
  final double? y;

  /// Optional positive target width in [units].
  final double? width;

  /// Optional positive target height in [units].
  final double? height;

  /// Coordinate unit space for [x], [y], [width], and [height].
  final WindowBoundsUnits units;

  /// Optional override suppressing rounded corners on Windows 11.
  final bool? squareCorners;

  /// Optional override pinning or unpinning topmost Z-order.
  final bool? alwaysOnTop;

  /// Optional request to activate and bring the window to the foreground.
  final bool? focus;

  /// Creates an immutable [WindowBoundsRequest].
  const WindowBoundsRequest({
    this.x,
    this.y,
    this.width,
    this.height,
    this.units = .physical,
    this.squareCorners,
    this.alwaysOnTop,
    this.focus,
  });

  /// Parses and validates a [WindowBoundsRequest] from JSON [map].
  ///
  /// Throws [FormatException] when numeric fields are non-finite, [width] or
  /// [height] is not positive, boolean flags have invalid types, or [units] is
  /// unrecognized.
  factory WindowBoundsRequest.fromJson(Map<Object?, Object?> map) {
    final x = _parseOptionalFiniteDouble(map, 'x');
    final y = _parseOptionalFiniteDouble(map, 'y');
    final width = _parseOptionalPositiveDouble(map, 'width');
    final height = _parseOptionalPositiveDouble(map, 'height');
    final units = _parseUnits(map['units']);
    final squareCorners = _parseOptionalBool(map, 'squareCorners');
    final alwaysOnTop = _parseOptionalBool(map, 'alwaysOnTop');
    final focus = _parseOptionalBool(map, 'focus');
    return WindowBoundsRequest(
      x: x,
      y: y,
      width: width,
      height: height,
      units: units,
      squareCorners: squareCorners,
      alwaysOnTop: alwaysOnTop,
      focus: focus,
    );
  }

  /// Whether this request updates window dimensions.
  bool get hasSizeChange => width != null || height != null;

  /// Whether this request updates window position.
  bool get hasPositionChange => x != null || y != null;

  /// Whether no mutation fields were supplied.
  bool get isEmpty =>
      x == null &&
      y == null &&
      width == null &&
      height == null &&
      squareCorners == null &&
      alwaysOnTop == null &&
      focus == null;

  /// Serializes this request for JSON responses or `MethodChannel('fterm/window')`.
  Map<String, Object?> toJson() => <String, Object?>{
    'x': ?x,
    'y': ?y,
    'width': ?width,
    'height': ?height,
    'units': units.wireName,
    'squareCorners': ?squareCorners,
    'alwaysOnTop': ?alwaysOnTop,
    'focus': ?focus,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WindowBoundsRequest &&
          other.x == x &&
          other.y == y &&
          other.width == width &&
          other.height == height &&
          other.units == units &&
          other.squareCorners == squareCorners &&
          other.alwaysOnTop == alwaysOnTop &&
          other.focus == focus;

  @override
  int get hashCode => Object.hash(
    x,
    y,
    width,
    height,
    units,
    squareCorners,
    alwaysOnTop,
    focus,
  );

  @override
  String toString() =>
      'WindowBoundsRequest(x: $x, y: $y, width: $width, height: $height, '
      'units: ${units.wireName}, squareCorners: $squareCorners, '
      'alwaysOnTop: $alwaysOnTop, focus: $focus)';
}

/// Persisted desktop-only configuration for the loopback HTTP automation driver.
///
/// Only [port] and [password] persist in private desktop settings; runtime
/// toggles (`enabled` and `allowPty`) intentionally reset to `false` on normal
/// startup.
final class AutomationDriverConfig {
  /// Default loopback TCP port (`127.0.0.1:9911`).
  static const int defaultPort = 9911;

  /// Minimum valid TCP port number.
  static const int minPort = 1;

  /// Maximum valid TCP port number.
  static const int maxPort = 65535;

  /// Unambiguous lowercase alphanumeric alphabet (omitting `0`, `1`, `i`, `l`,
  /// and `o`) used by [generatePassword].
  static const String passwordAlphabet = 'abcdefghjkmnpqrstuvwxyz23456789';

  /// Number of hyphen-separated groups in generated passwords.
  static const int passwordGroupCount = 4;

  /// Characters per group in generated passwords.
  static const int passwordGroupLength = 5;

  /// Loopback TCP port (`1..65535`).
  final int port;

  /// Persisted Bearer authentication password (empty if not yet generated).
  final String password;

  /// Creates an [AutomationDriverConfig], throwing [RangeError] if [port] is
  /// outside `[minPort, maxPort]`.
  AutomationDriverConfig({this.port = defaultPort, this.password = ''}) {
    if (!isValidPort(port)) {
      throw RangeError.range(port, minPort, maxPort, 'port');
    }
  }

  /// Returns `true` when [port] lies within `[minPort, maxPort]`.
  static bool isValidPort(int port) => port >= minPort && port <= maxPort;

  /// Generates a cryptographically secure `xxxxx-xxxxx-xxxxx-xxxxx` password
  /// using [Random.secure] (or [random] in deterministic tests).
  static String generatePassword({Random? random}) {
    final rng = random ?? Random.secure();
    final alphabetLength = passwordAlphabet.length;
    final groups = <String>[
      for (var g = 0; g < passwordGroupCount; g++)
        String.fromCharCodes(<int>[
          for (var i = 0; i < passwordGroupLength; i++)
            passwordAlphabet.codeUnitAt(rng.nextInt(alphabetLength)),
        ]),
    ];
    return groups.join('-');
  }

  /// Whether [password] contains a non-blank token.
  bool get hasPassword => password.trim().isNotEmpty;

  /// Returns a copy with overridden [port] and/or [password].
  AutomationDriverConfig copyWith({int? port, String? password}) =>
      AutomationDriverConfig(
        port: port ?? this.port,
        password: password ?? this.password,
      );

  /// Decodes an [AutomationDriverConfig] from a JSON object [map], falling
  /// back to [defaultPort] when `port` is missing or out of range.
  factory AutomationDriverConfig.fromJson(Map<Object?, Object?> map) {
    final rawPort = map['port'];
    final parsedPort = switch (rawPort) {
      final int value when isValidPort(value) => value,
      final double value
          when value.isFinite &&
              value == value.truncateToDouble() &&
              isValidPort(value.toInt()) =>
        value.toInt(),
      _ => defaultPort,
    };
    final rawPassword = map['password'];
    final parsedPassword = switch (rawPassword) {
      final String value => value.trim(),
      _ => '',
    };
    return AutomationDriverConfig(port: parsedPort, password: parsedPassword);
  }

  /// Decodes an [AutomationDriverConfig] from a JSON string [raw], returning
  /// `null` when [raw] is null, blank, malformed, or not a JSON object.
  static AutomationDriverConfig? tryFromJsonString(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<Object?, Object?>) return null;
      return AutomationDriverConfig.fromJson(decoded);
    } on Object {
      return null;
    }
  }

  /// Serializes this configuration as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'port': port,
    'password': password,
  };

  /// Serializes this configuration as a JSON string.
  String toJsonString() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutomationDriverConfig &&
          other.port == port &&
          other.password == password;

  @override
  int get hashCode => Object.hash(port, password);

  @override
  String toString() =>
      'AutomationDriverConfig(port: $port, hasPassword: $hasPassword)';
}

/// Immutable parsed HTTP request passed from [AutomationHttpServerBackend] to
/// an [AutomationRequestHandler].
final class AutomationHttpRequest {
  /// Uppercase HTTP method (`GET`, `POST`, etc.).
  final String method;

  /// Request URL path (for example `/v1/state`).
  final String path;

  /// Parsed URL query parameters.
  final Map<String, String> queryParameters;

  /// Decoded JSON object body for `POST` requests, or `null` for `GET`.
  final Map<String, Object?>? body;

  /// Creates an immutable [AutomationHttpRequest].
  const AutomationHttpRequest({
    required this.method,
    required this.path,
    this.queryParameters = const {},
    this.body,
  });
}

/// Immutable JSON HTTP response emitted by the automation driver.
final class AutomationHttpResponse {
  /// HTTP status code (`200`, `400`, `401`, `403`, `404`, `405`, `409`, `413`,
  /// `415`, `422`, `500`).
  final int statusCode;

  /// JSON response envelope (`{"ok": true, "result": ...}` or
  /// `{"ok": false, "error": {"code": ..., "message": ...}}`).
  final Map<String, Object?> body;

  /// Creates an [AutomationHttpResponse] with explicit [statusCode] and [body].
  const AutomationHttpResponse({required this.statusCode, required this.body});

  /// Creates a success response wrapping [result].
  factory AutomationHttpResponse.ok(
    Map<String, Object?> result, {
    int statusCode = 200,
  }) => AutomationHttpResponse(
    statusCode: statusCode,
    body: <String, Object?>{'ok': true, 'result': result},
  );

  /// Creates a structured error response with [code], [message], and optional
  /// [details].
  factory AutomationHttpResponse.error({
    required int statusCode,
    required String code,
    required String message,
    Map<String, Object?>? details,
  }) => AutomationHttpResponse(
    statusCode: statusCode,
    body: <String, Object?>{
      'ok': false,
      'error': <String, Object?>{
        'code': code,
        'message': message,
        'details': ?details,
      },
    },
  );

  /// Whether the response envelope indicates success (`ok == true`).
  bool get isOk => body['ok'] == true;

  /// Encodes [body] as a JSON string.
  String toJsonString() => jsonEncode(body);
}

/// Handler invoked by [AutomationHttpServerBackend] after security checks pass.
typedef AutomationRequestHandler = Future<AutomationHttpResponse> Function(
  AutomationHttpRequest request,
);

/// Platform bridge for inspecting and updating native desktop window bounds.
abstract interface class AutomationWindowBridge {
  /// Returns current native window bounds, or [WindowBoundsSnapshot.unsupported].
  Future<WindowBoundsSnapshot> getBounds();

  /// Applies [request] to the native window and returns the updated snapshot.
  Future<WindowBoundsSnapshot> setBounds(WindowBoundsRequest request);
}

/// No-op [AutomationWindowBridge] returning [WindowBoundsSnapshot.unsupported].
final class UnsupportedAutomationWindowBridge
    implements AutomationWindowBridge {
  /// Creates a const [UnsupportedAutomationWindowBridge].
  const UnsupportedAutomationWindowBridge();

  @override
  Future<WindowBoundsSnapshot> getBounds() async =>
      WindowBoundsSnapshot.unsupported;

  @override
  Future<WindowBoundsSnapshot> setBounds(WindowBoundsRequest request) async =>
      WindowBoundsSnapshot.unsupported;
}

/// Platform-neutral loopback HTTP server backend for the automation driver.
abstract interface class AutomationHttpServerBackend {
  /// Whether this host platform supports binding a local loopback HTTP server.
  bool get isSupported;

  /// Whether the server is currently listening for connections.
  bool get isRunning;

  /// Active bound loopback TCP port while running, or `null` when stopped.
  int? get boundPort;

  /// Binds `127.0.0.1:[port]` and begins serving authenticated requests.
  Future<void> start({
    required int port,
    required String password,
    required bool allowPty,
    required AutomationRequestHandler onRequest,
  });

  /// Stops serving and closes the underlying loopback socket.
  Future<void> stop();

  /// Replaces the active Bearer token live without restarting the server.
  void updatePassword(String password);

  /// Updates whether PTY-scoped endpoints are allowed without restarting.
  void updateAllowPty(bool allowPty);
}

/// Observable presentation contract for Automation Settings and status chrome.
abstract interface class AutomationDriverViewModel implements Listenable {
  /// Whether the automation driver is supported on this platform (desktop only).
  bool get isSupported;

  /// Whether the loopback HTTP server is currently listening.
  bool get isRunning;

  /// Configured loopback TCP port (`1..65535`).
  int get port;

  /// Active Bearer token (persisted password or ephemeral env override).
  String get password;

  /// Whether PTY-scoped automation endpoints are enabled.
  bool get allowPty;

  /// Whether [password] is currently overridden by `FTERM_AUTOMATION_TOKEN`.
  bool get hasEphemeralTokenOverride;

  /// Most recent server start/bind error message, or `null` when healthy.
  String? get lastError;

  /// Enables or disables the loopback HTTP server, returning the running state.
  Future<bool> setEnabled(bool enabled);

  /// Updates the configured loopback [port] (`1..65535`).
  void setPort(int port);

  /// Enables or disables PTY-scoped endpoints.
  void setAllowPty(bool allowPty);

  /// Generates, persists, and immediately activates a fresh Bearer password.
  String regeneratePassword();
}

/// Hook forwarding normalized `[0..1]` pointer positions to mounted pane shader
/// `iMouse` uniforms without moving the OS cursor.
abstract interface class AutomationPointerDispatcher {
  /// Injects normalized `[0..1]` coordinates into [paneId]'s shader `iMouse`,
  /// returning `true` when the target pane surface is mounted.
  bool injectPointer({
    required String paneId,
    required double x,
    required double y,
    bool pressed = false,
  });

  /// Clears injected shader pointer state on [paneId], returning `true` when
  /// the target pane surface is mounted.
  bool clearPointer({required String paneId});
}

/// A single literal or regex match inside a visible terminal screen buffer.
final class AutomationScreenMatch {
  /// Zero-based row index.
  final int row;

  /// Zero-based inclusive starting cell column.
  final int col;

  /// Zero-based exclusive ending cell column (spanning any trailing
  /// continuation cell of a final wide glyph).
  final int endCol;

  /// Matched visible text.
  final String text;

  /// Normalized `[0..1]` horizontal center coordinate of the matched span.
  final double x;

  /// Normalized `[0..1]` vertical center coordinate of the matched row.
  final double y;

  /// Creates an immutable [AutomationScreenMatch].
  const AutomationScreenMatch({
    required this.row,
    required this.col,
    required this.endCol,
    required this.text,
    required this.x,
    required this.y,
  });

  /// Serializes this match as a JSON object.
  Map<String, Object?> toJson() => <String, Object?>{
    'row': row,
    'col': col,
    'endCol': endCol,
    'text': text,
    'x': x,
    'y': y,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutomationScreenMatch &&
          other.row == row &&
          other.col == col &&
          other.endCol == endCol &&
          other.text == text &&
          other.x == x &&
          other.y == y;

  @override
  int get hashCode => Object.hash(row, col, endCol, text, x, y);

  @override
  String toString() =>
      'AutomationScreenMatch(row: $row, col: $col, endCol: $endCol, '
      'text: "$text", x: $x, y: $y)';
}

/// Immutable snapshot of a visible pane display buffer and cursor state.
final class AutomationScreenSnapshot {
  /// Identifier of the inspected pane.
  final String paneId;

  /// Visible terminal width in character cells.
  final int cols;

  /// Visible terminal height in character cells.
  final int rows;

  /// Zero-based cursor column.
  final int cursorCol;

  /// Zero-based cursor row.
  final int cursorRow;

  /// Whether the terminal cursor is currently visible.
  final bool cursorVisible;

  /// Visible screen rows as plain text strings.
  final List<String> lines;

  /// Creates an immutable [AutomationScreenSnapshot].
  AutomationScreenSnapshot({
    required this.paneId,
    required this.cols,
    required this.rows,
    required this.cursorCol,
    required this.cursorRow,
    required this.cursorVisible,
    required List<String> lines,
  }) : lines = List<String>.unmodifiable(lines);

  /// Serializes this snapshot to match `GET /v1/screen`.
  Map<String, Object?> toJson() => <String, Object?>{
    'paneId': paneId,
    'cols': cols,
    'rows': rows,
    'cursor': <String, Object?>{
      'col': cursorCol,
      'row': cursorRow,
      'visible': cursorVisible,
    },
    'lines': lines,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutomationScreenSnapshot &&
          other.paneId == paneId &&
          other.cols == cols &&
          other.rows == rows &&
          other.cursorCol == cursorCol &&
          other.cursorRow == cursorRow &&
          other.cursorVisible == cursorVisible &&
          listEquals(other.lines, lines);

  @override
  int get hashCode => Object.hash(
    paneId,
    cols,
    rows,
    cursorCol,
    cursorRow,
    cursorVisible,
    Object.hashAll(lines),
  );
}

/// Outcome of writing raw bytes to a workspace pane via automation.
enum AutomationPtyWriteResult {
  /// Bytes were written to an active PTY pane.
  ok,

  /// Target PTY pane exists, but its process has already exited.
  exited,

  /// Target pane is a shader editor pane rather than a PTY pane.
  editorPane,

  /// No pane exists with the requested identifier.
  notFound,
}

double? _tryFiniteDouble(Object? raw) => switch (raw) {
  final num value when value.isFinite => value.toDouble(),
  _ => null,
};

double? _parseOptionalFiniteDouble(Map<Object?, Object?> map, String key) {
  final raw = map[key];
  if (raw == null) return null;
  final value = _tryFiniteDouble(raw);
  if (value == null) {
    throw FormatException('Field "$key" must be a finite number.');
  }
  return value;
}

double? _parseOptionalPositiveDouble(Map<Object?, Object?> map, String key) {
  final value = _parseOptionalFiniteDouble(map, key);
  if (value != null && value <= 0) {
    throw FormatException('Field "$key" must be greater than zero.');
  }
  return value;
}

bool? _parseOptionalBool(Map<Object?, Object?> map, String key) {
  final raw = map[key];
  return switch (raw) {
    null => null,
    final bool value => value,
    _ => throw FormatException('Field "$key" must be a boolean.'),
  };
}

WindowBoundsUnits _parseUnits(Object? raw) {
  if (raw == null) return .physical;
  final parsed = WindowBoundsUnits.tryFromWireName(raw);
  if (parsed == null) {
    throw FormatException(
      'Field "units" must be "physical" or "logical" (got "$raw").',
    );
  }
  return parsed;
}
