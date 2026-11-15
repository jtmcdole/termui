import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';

import 'settings_storage_stub.dart'
    if (dart.library.js_interop) 'settings_storage_web.dart'
    if (dart.library.io) 'settings_storage_io.dart'
    as impl;

/// Storage key used to persist [CastWorkspaceSettings] on Web and desktop.
const String castSettingsStorageKey = 'termui_cast.settings.v1';

/// Storage key used to persist `fterm`-specific UI and audio preferences.
const String ftermPreferencesStorageKey = 'fterm.preferences.v1';

/// Storage key used to persist relay connection credentials (`0600` on POSIX).
const String ftermRelayCredentialsStorageKey = 'fterm.relay_credentials.v1';

/// Key-value storage seam for persisting `fterm` settings and relay credentials
/// (backed by `window.localStorage` on Web, `~/.config/fterm/settings.json` on
/// native desktop, and an isolated no-op store under `flutter test`).
abstract interface class SettingsStorage {
  /// Reads the raw string stored at [key], or `null` if unset or unavailable.
  String? getItem(String key);

  /// Stores [value] at [key] (ignoring storage quota or privacy-mode errors).
  void setItem(String key, String value);
}

/// Optional [SettingsStorage] extension supporting multi-key coalesced writes,
/// cache invalidation on external reload, and awaiting pending async flushes.
abstract interface class BatchSettingsStorage implements SettingsStorage {
  /// Atomically applies all key/value [entries] in one persistence write.
  void setItems(Map<String, String> entries);

  /// Clears any in-memory cached entries so subsequent reads reload from backing store.
  void invalidateCache();

  /// Awaits completion of any in-flight asynchronous disk persistence.
  Future<void> flush();
}

/// Default platform [SettingsStorage] (`window.localStorage` on Web,
/// `~/.config/fterm/settings.json` or `%APPDATA%\fterm\settings.json` on native
/// desktop).
SettingsStorage get defaultSettingsStorage => impl.platformSettingsStorage;

/// App-level `fterm` audio, font-size, shell, and tab-bar preferences stored
/// alongside [CastWorkspaceSettings].
final class FtermPreferences {
  /// Default unmuted audio volume in `[0.0, 1.0]`.
  static const double defaultAudioVolume = 0.7;

  /// Default terminal cell font size in logical pixels.
  static const double defaultFontSize = 13.0;

  /// Minimum clamped terminal cell font size in logical pixels.
  static const double minFontSize = 6.0;

  /// Maximum clamped terminal cell font size in logical pixels.
  static const double maxFontSize = 72.0;

  /// Default value for [FtermPreferences].
  static const FtermPreferences defaults = FtermPreferences();

  /// Whether terminal `BEL` and `APC` audio output is muted.
  final bool audioMuted;

  /// Output audio volume scalar clamped to `[0.0, 1.0]`.
  final double audioVolume;

  /// Whether the 28px Flutter tab bar auto-hides when only one tab is open.
  final bool autoHideSingleTab;

  /// Whether macOS Option+key emits `Alt+key` instead of dead-key composition.
  final bool macosOptionAsAlt;

  /// Optional user-configured terminal font size clamped to
  /// `[minFontSize, maxFontSize]`, or `null` to use widget/default sizing.
  final double? fontSize;

  /// Optional explicit local shell executable override (trimmed; empty/blank
  /// normalizes to `null` to use `$SHELL` / platform default).
  final String? shellExecutable;

  /// Optional explicit arguments forwarded to [shellExecutable] (unmodifiable
  /// list of non-empty strings).
  final List<String> shellArguments;

  /// Whether POSIX local shells launch as login shells (`-l`) when
  /// [shellArguments] is empty.
  final bool loginShell;

  /// Creates immutable [FtermPreferences].
  const FtermPreferences({
    this.audioMuted = false,
    this.audioVolume = defaultAudioVolume,
    this.autoHideSingleTab = false,
    this.macosOptionAsAlt = false,
    this.fontSize,
    this.shellExecutable,
    this.shellArguments = const [],
    this.loginShell = true,
  });

  /// Returns [fontSize] (or [fallback] when unset), clamped to
  /// `[minFontSize, maxFontSize]`.
  double effectiveFontSize([double fallback = defaultFontSize]) =>
      (fontSize ?? fallback).clamp(minFontSize, maxFontSize).toDouble();

  /// Returns a copy with overridden preference fields.
  FtermPreferences copyWith({
    bool? audioMuted,
    double? audioVolume,
    bool? autoHideSingleTab,
    bool? macosOptionAsAlt,
    double? fontSize,
    bool clearFontSize = false,
    String? shellExecutable,
    bool clearShellExecutable = false,
    List<String>? shellArguments,
    bool? loginShell,
  }) => FtermPreferences(
    audioMuted: audioMuted ?? this.audioMuted,
    audioVolume: (audioVolume ?? this.audioVolume).clamp(0.0, 1.0).toDouble(),
    autoHideSingleTab: autoHideSingleTab ?? this.autoHideSingleTab,
    macosOptionAsAlt: macosOptionAsAlt ?? this.macosOptionAsAlt,
    fontSize: clearFontSize
        ? null
        : _normalizeFontSize(fontSize ?? this.fontSize),
    shellExecutable: clearShellExecutable
        ? null
        : _normalizeShellExecutable(shellExecutable ?? this.shellExecutable),
    shellArguments: _normalizeShellArguments(
      shellArguments ?? this.shellArguments,
    ),
    loginShell: loginShell ?? this.loginShell,
  );

  /// Decodes [FtermPreferences] from JSON string [raw], returning [defaults] on
  /// null or malformed input.
  factory FtermPreferences.fromJsonString(String? raw) {
    if (raw == null || raw.trim().isEmpty) return defaults;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<Object?, Object?>) return defaults;
      return FtermPreferences(
        audioMuted: decoded['audioMuted'] == true,
        audioVolume: _parseAudioVolume(decoded['audioVolume']),
        autoHideSingleTab: decoded['autoHideSingleTab'] == true,
        macosOptionAsAlt: decoded['macosOptionAsAlt'] == true,
        fontSize: _parseFontSize(decoded['fontSize']),
        shellExecutable: _parseShellExecutable(decoded['shellExecutable']),
        shellArguments: _parseShellArguments(decoded['shellArguments']),
        loginShell: _parseBool(decoded['loginShell'], fallback: true),
      );
    } on Object {
      return defaults;
    }
  }

  static double _parseAudioVolume(Object? raw) => switch (raw) {
    final num value when value.isFinite =>
      value.toDouble().clamp(0.0, 1.0).toDouble(),
    _ => defaultAudioVolume,
  };

  static double? _parseFontSize(Object? raw) => switch (raw) {
    final num value when value.isFinite => _normalizeFontSize(value.toDouble()),
    _ => null,
  };

  static double? _normalizeFontSize(double? value) =>
      value == null || value.isNaN
      ? null
      : value.clamp(minFontSize, maxFontSize).toDouble();

  static String? _parseShellExecutable(Object? raw) => switch (raw) {
    final String value => _normalizeShellExecutable(value),
    _ => null,
  };

  static String? _normalizeShellExecutable(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static List<String> _parseShellArguments(Object? raw) => switch (raw) {
    final List<Object?> items => _normalizeShellArguments(<String>[
      for (final item in items)
        if (item case final String value) value,
    ]),
    _ => const [],
  };

  static List<String> _normalizeShellArguments(List<String> arguments) {
    final filtered = <String>[
      for (final arg in arguments)
        if (arg.isNotEmpty) arg,
    ];
    return filtered.isEmpty ? const [] : List<String>.unmodifiable(filtered);
  }

  static bool _parseBool(Object? raw, {required bool fallback}) =>
      switch (raw) {
        final bool value => value,
        _ => fallback,
      };

  /// Serializes this preference set as a JSON object string.
  String toJsonString() => jsonEncode(<String, Object?>{
    'audioMuted': audioMuted,
    'audioVolume': audioVolume,
    'autoHideSingleTab': autoHideSingleTab,
    'macosOptionAsAlt': macosOptionAsAlt,
    'fontSize': ?fontSize,
    'shellExecutable': ?shellExecutable,
    if (shellArguments.isNotEmpty) 'shellArguments': shellArguments,
    'loginShell': loginShell,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FtermPreferences &&
          other.audioMuted == audioMuted &&
          other.audioVolume == audioVolume &&
          other.autoHideSingleTab == autoHideSingleTab &&
          other.macosOptionAsAlt == macosOptionAsAlt &&
          other.fontSize == fontSize &&
          other.shellExecutable == shellExecutable &&
          listEquals(other.shellArguments, shellArguments) &&
          other.loginShell == loginShell;

  @override
  int get hashCode => Object.hash(
    audioMuted,
    audioVolume,
    autoHideSingleTab,
    macosOptionAsAlt,
    fontSize,
    shellExecutable,
    Object.hashAll(shellArguments),
    loginShell,
  );
}

/// Relay connection credentials persisted on `0600` desktop storage when the
/// user connects to a relay from the UI or configures caster sharing.
final class RelayCredentials {
  /// Empty credentials placeholder.
  static const RelayCredentials empty = RelayCredentials();

  /// Saved `/v1/client` WebSocket URL string, if configured.
  final String serverUrl;

  /// Saved viewer bearer token.
  final String clientToken;

  /// Saved caster bearer token used when publishing local shells.
  final String casterToken;

  /// Creates an immutable [RelayCredentials] value.
  const RelayCredentials({
    this.serverUrl = '',
    this.clientToken = '',
    this.casterToken = '',
  });

  /// Whether all credential fields are empty.
  bool get isEmpty =>
      serverUrl.isEmpty && clientToken.isEmpty && casterToken.isEmpty;

  /// Decodes [RelayCredentials] from JSON string [raw], returning [empty] when
  /// missing or malformed.
  factory RelayCredentials.fromJsonString(String? raw) {
    if (raw == null || raw.trim().isEmpty) return empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<Object?, Object?>) return empty;
      return RelayCredentials(
        serverUrl: decoded['serverUrl'] is String
            ? decoded['serverUrl']! as String
            : '',
        clientToken: decoded['clientToken'] is String
            ? decoded['clientToken']! as String
            : '',
        casterToken: decoded['casterToken'] is String
            ? decoded['casterToken']! as String
            : '',
      );
    } on Object {
      return empty;
    }
  }

  /// Serializes these relay credentials as a JSON object string.
  String toJsonString() => jsonEncode(<String, Object?>{
    'serverUrl': serverUrl,
    'clientToken': clientToken,
    'casterToken': casterToken,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RelayCredentials &&
          other.serverUrl == serverUrl &&
          other.clientToken == clientToken &&
          other.casterToken == casterToken;

  @override
  int get hashCode => Object.hash(serverUrl, clientToken, casterToken);
}

/// Writes [entries] in one coalesced batch when [storage] supports
/// [BatchSettingsStorage], falling back to sequential [SettingsStorage.setItem].
void saveStoredBatch(SettingsStorage storage, Map<String, String> entries) {
  if (entries.isEmpty) return;
  if (entries.length == 1) {
    final entry = entries.entries.first;
    storage.setItem(entry.key, entry.value);
    return;
  }
  if (storage case final BatchSettingsStorage batch) {
    batch.setItems(entries);
    return;
  }
  for (final MapEntry(:key, :value) in entries.entries) {
    storage.setItem(key, value);
  }
}

/// Loads [CastWorkspaceSettings] from [storage] (falling back to
/// [defaultDockPosition] when no stored settings exist or JSON is malformed).
CastWorkspaceSettings loadStoredSettings(
  SettingsStorage storage, {
  DockPosition defaultDockPosition = .top,
}) => CastWorkspaceSettings.fromJsonString(
  storage.getItem(castSettingsStorageKey),
  defaultDockPosition: defaultDockPosition,
);

/// Writes [settings] as JSON to [storage] under [castSettingsStorageKey].
void saveStoredSettings(
  SettingsStorage storage,
  CastWorkspaceSettings settings,
) => storage.setItem(castSettingsStorageKey, settings.toJsonString());

/// Loads [FtermPreferences] from [storage].
FtermPreferences loadStoredPreferences(SettingsStorage storage) =>
    FtermPreferences.fromJsonString(
      storage.getItem(ftermPreferencesStorageKey),
    );

/// Writes [preferences] as JSON to [storage].
void saveStoredPreferences(
  SettingsStorage storage,
  FtermPreferences preferences,
) => storage.setItem(ftermPreferencesStorageKey, preferences.toJsonString());

/// Loads [RelayCredentials] from [storage].
RelayCredentials loadStoredRelayCredentials(SettingsStorage storage) =>
    RelayCredentials.fromJsonString(
      storage.getItem(ftermRelayCredentialsStorageKey),
    );

/// Writes [credentials] as JSON to [storage] (`0600` POSIX file on desktop).
void saveStoredRelayCredentials(
  SettingsStorage storage,
  RelayCredentials credentials,
) => storage.setItem(
  ftermRelayCredentialsStorageKey,
  credentials.toJsonString(),
);

/// Coalesces rapid [CastWorkspaceSettings] and [FtermPreferences] mutations:
/// persists immediately when idle, or coalesces rapid updates into one trailing
/// write per [cooldown] window.
final class ThrottledSettingsSaver {
  final SettingsStorage _storage;

  /// Minimum interval between consecutive throttled writes.
  final Duration cooldown;

  late final _ThrottledWriteChannel<CastWorkspaceSettings> _settingsChannel =
      _ThrottledWriteChannel<CastWorkspaceSettings>(
        (next) => saveStoredSettings(_storage, next),
        cooldown,
      );
  late final _ThrottledWriteChannel<FtermPreferences> _preferencesChannel =
      _ThrottledWriteChannel<FtermPreferences>(
        (next) => saveStoredPreferences(_storage, next),
        cooldown,
      );
  bool _disposed = false;

  /// Creates a throttled settings saver writing to [_storage].
  ThrottledSettingsSaver(
    this._storage, {
    this.cooldown = const Duration(milliseconds: 200),
  });

  /// Persists [next] workspace settings immediately when idle, or queues it as
  /// the latest trailing value when a cooldown window is active.
  void save(CastWorkspaceSettings next) {
    if (_disposed) return;
    _settingsChannel.save(next);
  }

  /// Persists [next] preferences immediately when idle, or queues it as the
  /// latest trailing value when a cooldown window is active.
  void savePreferences(FtermPreferences next) {
    if (_disposed) return;
    _preferencesChannel.save(next);
  }

  /// Cancels any pending trailing writes and clears active cooldown windows.
  void cancelPending() {
    _settingsChannel.cancelPending();
    _preferencesChannel.cancelPending();
  }

  /// Cancels active cooldown timers and writes pending updates synchronously
  /// while leaving this saver active for subsequent saves, coalescing multiple
  /// dirty channels into one write.
  void flush() {
    final pendingSettings = _settingsChannel.takePending();
    final pendingPreferences = _preferencesChannel.takePending();
    final batch = <String, String>{
      if (pendingSettings != null)
        castSettingsStorageKey: pendingSettings.toJsonString(),
      if (pendingPreferences != null)
        ftermPreferencesStorageKey: pendingPreferences.toJsonString(),
    };
    if (batch.isNotEmpty) {
      saveStoredBatch(_storage, batch);
    }
  }

  /// Flushes pending writes and awaits any in-flight async storage flush.
  Future<void> flushAsync() async {
    flush();
    if (_storage case final BatchSettingsStorage batch) {
      await batch.flush();
    }
  }

  /// Cancels active timers and flushes any pending updates synchronously.
  void dispose() {
    _disposed = true;
    flush();
  }
}

final class _ThrottledWriteChannel<T> {
  final void Function(T value) _write;
  final Duration _cooldown;
  Timer? _cooldownTimer;
  T? _pending;

  _ThrottledWriteChannel(this._write, this._cooldown);

  void save(T next) {
    if (_cooldownTimer == null) {
      _write(next);
      _pending = null;
      _cooldownTimer = Timer(_cooldown, _onCooldownDone);
    } else {
      _pending = next;
    }
  }

  void _onCooldownDone() {
    _cooldownTimer = null;
    final latest = _pending;
    _pending = null;
    if (latest == null) return;
    _write(latest);
    _cooldownTimer = Timer(_cooldown, _onCooldownDone);
  }

  void cancelPending() {
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    _pending = null;
  }

  T? takePending() {
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    final pending = _pending;
    _pending = null;
    return pending;
  }
}
