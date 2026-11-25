import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_flutter/termui_flutter.dart'
    show ShaderAnimationMode, ShaderBackendKind;

import 'input/key_chord.dart';
import 'settings_storage_stub.dart'
    if (dart.library.js_interop) 'settings_storage_web.dart'
    if (dart.library.io) 'settings_storage_io.dart'
    as impl;
import 'workspace/split_tree_model.dart';

/// Storage key used to persist [CastWorkspaceSettings] on Web and desktop.
const String castSettingsStorageKey = 'termui_cast.settings.v1';

/// Storage key used to persist `fterm`-specific UI and audio preferences.
const String ftermPreferencesStorageKey = 'fterm.preferences.v1';

/// Storage key used to persist relay connection credentials (`0600` on POSIX,
/// tab-scoped `window.sessionStorage` on Web).
const String ftermRelayCredentialsStorageKey = 'fterm.relay_credentials.v1';

/// Storage key used to persist Web tab and split layout state in
/// `window.sessionStorage` across same-tab reloads (ignored on desktop).
const String ftermWebWorkspaceResumeStorageKey =
    'fterm.web_workspace_resume.v1';

/// Key-value storage seam for persisting `fterm` settings, relay credentials,
/// and Web workspace resume state.
///
/// On Web, preferences use `window.localStorage`, while
/// [ftermRelayCredentialsStorageKey] and [ftermWebWorkspaceResumeStorageKey]
/// route to tab-scoped `window.sessionStorage` (and never persist to
/// `localStorage`). Native desktop uses `~/.config/fterm/settings.json` (or
/// `%APPDATA%\fterm\settings.json`), and `flutter test` uses an isolated no-op
/// store.
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

/// Default platform [SettingsStorage] (preferences in `window.localStorage` and
/// relay credentials / layout resume in `window.sessionStorage` on Web;
/// `~/.config/fterm/settings.json` or `%APPDATA%\fterm\settings.json` on native
/// desktop).
SettingsStorage get defaultSettingsStorage => impl.platformSettingsStorage;

/// Cadence for checking GitHub `fterm-v*` releases on desktop builds.
enum UpdateCheckMode {
  /// Check only when the user clicks **Check for Updates**.
  manual,

  /// Check automatically once every 24 hours and on user request.
  daily,
}

/// Security trust policy governing CLI `ESC _ S` artistic shaders and
/// per-cell transforms on a local or remote `fterm` pane.
enum CliShaderPolicy {
  /// Block all CLI shaders, scoped regions, and per-cell transforms.
  disabled('disabled'),

  /// Allow built-in host presets and pane-clipped cell transforms; reject custom GLSL.
  presetsAndTransforms('presets_and_transforms'),

  /// Allow built-in presets and pane-clipped transforms; prompt once per custom GLSL SHA-256.
  promptCustomGlsl('prompt_custom_glsl'),

  /// Auto-trust custom GLSL shaders without prompting (intended for local dev panes).
  allowLocalCustomGlsl('allow_local_custom_glsl');

  /// Canonical JSON and wire identifier.
  final String wireName;

  const CliShaderPolicy(this.wireName);

  /// Parses [raw] from its [wireName] (or enum [name]), returning [fallback] if unrecognized.
  static CliShaderPolicy fromWireName(
    Object? raw, {
    required CliShaderPolicy fallback,
  }) => switch (raw) {
    'disabled' => disabled,
    'presets_and_transforms' || 'presetsAndTransforms' => presetsAndTransforms,
    'prompt_custom_glsl' || 'promptCustomGlsl' => promptCustomGlsl,
    'allow_local_custom_glsl' || 'allowLocalCustomGlsl' => allowLocalCustomGlsl,
    _ => fallback,
  };
}

/// Controls how CLI full-pane `a=set` shaders combine with user Settings shaders.
enum CliFullPaneShaderMode {
  /// Default: CLI full-pane passes run before user shaders (CRT/bloom builds on top).
  cliBeforeUser('cli_before_user'),

  /// CLI full-pane chain replaces the user full-pane chain while active.
  cliReplacesUser('cli_replaces_user'),

  /// Prompt the user when both CLI `a=set` and user Settings shaders are active.
  askOnConflict('ask_on_conflict');

  /// Canonical JSON and wire identifier.
  final String wireName;

  const CliFullPaneShaderMode(this.wireName);

  /// Parses [raw] from its [wireName] (or enum [name]), returning [fallback] if unrecognized.
  static CliFullPaneShaderMode fromWireName(
    Object? raw, {
    CliFullPaneShaderMode fallback = CliFullPaneShaderMode.cliBeforeUser,
  }) => switch (raw) {
    'cli_before_user' || 'cliBeforeUser' => cliBeforeUser,
    'cli_replaces_user' || 'cliReplacesUser' => cliReplacesUser,
    'ask_on_conflict' || 'askOnConflict' => askOnConflict,
    _ => fallback,
  };
}

/// Preferred GPU adapter policy read at native Windows startup before the
/// Flutter Impeller engine selects a DXGI adapter.
enum GpuDriverPreference {
  /// Use the operating system / driver default adapter (`NoPreference`).
  auto('auto'),

  /// Prefer a discrete / high-performance GPU (`HighPerformancePreference`).
  highPerformance('highPerformance'),

  /// Prefer an integrated / power-saving GPU (`LowPowerPreference`).
  powerSaving('powerSaving');

  /// Canonical JSON wire identifier (matched by `apps/fterm/windows/runner/main.cpp`).
  final String wireName;

  const GpuDriverPreference(this.wireName);

  /// Parses [raw] from its [wireName] (or shorthand), falling back to [auto].
  static GpuDriverPreference fromWireName(Object? raw) => switch (raw) {
    'highPerformance' || 'high_performance' || 'high' => highPerformance,
    'powerSaving' || 'power_saving' || 'low' => powerSaving,
    _ => auto,
  };
}

/// Policy governing how unhandled `Meta`/`Cmd` key chords are dispatched
/// relative to the host browser or operating system.
enum FtermMetaKeyMode {
  /// Pass through on Web and macOS; claim on Linux/Windows desktop when Kitty
  /// keyboard protocol is active.
  auto('auto'),

  /// Always pass unhandled `Meta`/`Cmd` chords through to the host OS/browser.
  passThrough('passThrough'),

  /// Claim unhandled `Meta`/`Cmd` chords whenever Kitty keyboard protocol is
  /// active (still passing through in legacy mode).
  kitty('kitty');

  /// Canonical JSON wire identifier.
  final String wireName;

  const FtermMetaKeyMode(this.wireName);

  /// Parses [raw] from its [wireName] (or snake_case alias), falling back to
  /// [auto].
  static FtermMetaKeyMode fromWireName(Object? raw) => switch (raw) {
    'passThrough' || 'pass_through' => .passThrough,
    'kitty' => .kitty,
    _ => .auto,
  };
}

/// App-level `fterm` audio, font-size, shell, tab-bar, and auto-update
/// preferences stored alongside [CastWorkspaceSettings].
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

  /// Cadence for GitHub release update discovery (`manual` default).
  final UpdateCheckMode updateCheckMode;

  /// Whether pre-release tags (`fterm-vX.Y.Z-rc.N`) are eligible for updates.
  final bool includePrereleases;

  /// UTC timestamp of the most recent completed release check, if any.
  final DateTime? lastUpdateCheckUtc;

  /// Optional release version string skipped by the user for automatic prompts.
  final String? skippedUpdateVersion;

  /// Latest application version whose What's New modal the user has viewed.
  final String? lastSeenWhatsNewVersion;

  /// HTTP `ETag` from the latest successful `git/matching-refs/tags/fterm-v`
  /// query.
  final String? lastReleaseTagEtag;

  /// Cached `fterm-v*` tag names paired with [lastReleaseTagEtag] so `304`
  /// responses remain comparable across restarts and portable copies.
  final List<String> cachedReleaseTags;

  /// Optional path or storage key for the user's background wallpaper image.
  final String? backgroundImagePath;

  /// Ordered list of background fragment shader paths or preset identifiers.
  final List<String> backgroundShaderPaths;

  /// Ordered list of foreground post-process shader paths or preset identifiers.
  final List<String> foregroundShaderPaths;

  /// Policy controlling when time-varying fragment shaders advance `iTime`.
  final ShaderAnimationMode shaderAnimationMode;

  /// Optional runtime override for the active shader backend (`null` uses
  /// platform auto-selection).
  final ShaderBackendKind? shaderBackendOverride;

  /// Optional serialized JSON payload storing custom shader profile parameters.
  final String? customShaderProfileJson;

  /// Whether the in-app FPS and frame-timing performance HUD is visible.
  final bool showPerfHud;

  /// Preferred GPU adapter policy read by native desktop launchers on startup.
  final GpuDriverPreference gpuDriverPreference;

  /// Optional maximum ambient shader tick rate (`null` = uncapped, or positive
  /// FPS such as `120`, `60`, or `30`).
  final int? maxShaderFps;

  /// Trust policy for CLI `ESC _ S` shaders and transforms on local panes.
  final CliShaderPolicy localCliShaderPolicy;

  /// Trust policy for CLI `ESC _ S` shaders and transforms on remote `termui_cast` panes.
  final CliShaderPolicy remoteCliShaderPolicy;

  /// Composition mode when a CLI `a=set` full-pane shader coexists with user shaders.
  final CliFullPaneShaderMode cliFullPaneShaderMode;

  /// Persisted lowercase SHA-256 hex digests of user-trusted custom CLI GLSL sources.
  final Set<String> trustedCliShaderHashes;

  /// Policy controlling unhandled `Meta`/`Cmd` shortcut passthrough vs. Kitty
  /// forwarding.
  final FtermMetaKeyMode metaKeyMode;

  /// User-configured key chords always passed through to the host OS or browser
  /// ahead of `fterm` shortcuts and terminal input.
  final List<KeyChord> passthroughShortcuts;

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
    this.updateCheckMode = UpdateCheckMode.manual,
    this.includePrereleases = false,
    this.lastUpdateCheckUtc,
    this.skippedUpdateVersion,
    this.lastSeenWhatsNewVersion,
    this.lastReleaseTagEtag,
    this.cachedReleaseTags = const [],
    this.backgroundImagePath,
    this.backgroundShaderPaths = const [],
    this.foregroundShaderPaths = const [],
    this.shaderAnimationMode = ShaderAnimationMode.focused,
    this.shaderBackendOverride,
    this.customShaderProfileJson,
    this.showPerfHud = false,
    this.gpuDriverPreference = GpuDriverPreference.auto,
    this.maxShaderFps,
    this.localCliShaderPolicy = CliShaderPolicy.promptCustomGlsl,
    this.remoteCliShaderPolicy = CliShaderPolicy.disabled,
    this.cliFullPaneShaderMode = CliFullPaneShaderMode.cliBeforeUser,
    this.trustedCliShaderHashes = const <String>{},
    this.metaKeyMode = .auto,
    this.passthroughShortcuts = const [],
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
    UpdateCheckMode? updateCheckMode,
    bool? includePrereleases,
    DateTime? lastUpdateCheckUtc,
    bool clearLastUpdateCheckUtc = false,
    String? skippedUpdateVersion,
    bool clearSkippedUpdateVersion = false,
    String? lastSeenWhatsNewVersion,
    bool clearLastSeenWhatsNewVersion = false,
    String? lastReleaseTagEtag,
    bool clearLastReleaseTagEtag = false,
    List<String>? cachedReleaseTags,
    String? backgroundImagePath,
    bool clearBackgroundImagePath = false,
    List<String>? backgroundShaderPaths,
    List<String>? foregroundShaderPaths,
    ShaderAnimationMode? shaderAnimationMode,
    ShaderBackendKind? shaderBackendOverride,
    bool clearShaderBackendOverride = false,
    String? customShaderProfileJson,
    bool clearCustomShaderProfileJson = false,
    bool? showPerfHud,
    GpuDriverPreference? gpuDriverPreference,
    int? maxShaderFps,
    bool clearMaxShaderFps = false,
    CliShaderPolicy? localCliShaderPolicy,
    CliShaderPolicy? remoteCliShaderPolicy,
    CliFullPaneShaderMode? cliFullPaneShaderMode,
    Set<String>? trustedCliShaderHashes,
    FtermMetaKeyMode? metaKeyMode,
    List<KeyChord>? passthroughShortcuts,
  }) => FtermPreferences(
    audioMuted: audioMuted ?? this.audioMuted,
    audioVolume: (audioVolume ?? this.audioVolume).clamp(0.0, 1.0).toDouble(),
    autoHideSingleTab: autoHideSingleTab ?? this.autoHideSingleTab,
    macosOptionAsAlt: macosOptionAsAlt ?? this.macosOptionAsAlt,
    fontSize: _resolveOptionalField<double>(
      clear: clearFontSize,
      next: fontSize ?? this.fontSize,
      normalize: _normalizeFontSize,
    ),
    shellExecutable: _resolveOptionalField<String>(
      clear: clearShellExecutable,
      next: shellExecutable ?? this.shellExecutable,
      normalize: _normalizeOptionalText,
    ),
    shellArguments: _normalizeNonEmptyStrings(
      shellArguments ?? this.shellArguments,
    ),
    loginShell: loginShell ?? this.loginShell,
    updateCheckMode: updateCheckMode ?? this.updateCheckMode,
    includePrereleases: includePrereleases ?? this.includePrereleases,
    lastUpdateCheckUtc: _resolveOptionalField<DateTime>(
      clear: clearLastUpdateCheckUtc,
      next: lastUpdateCheckUtc ?? this.lastUpdateCheckUtc,
      normalize: (dt) => dt?.toUtc(),
    ),
    skippedUpdateVersion: _resolveOptionalField<String>(
      clear: clearSkippedUpdateVersion,
      next: skippedUpdateVersion ?? this.skippedUpdateVersion,
      normalize: _normalizeOptionalText,
    ),
    lastSeenWhatsNewVersion: _resolveOptionalField<String>(
      clear: clearLastSeenWhatsNewVersion,
      next: lastSeenWhatsNewVersion ?? this.lastSeenWhatsNewVersion,
      normalize: _normalizeOptionalText,
    ),
    lastReleaseTagEtag: _resolveOptionalField<String>(
      clear: clearLastReleaseTagEtag,
      next: lastReleaseTagEtag ?? this.lastReleaseTagEtag,
      normalize: _normalizeOptionalText,
    ),
    cachedReleaseTags: _normalizeTrimmedStrings(
      cachedReleaseTags ?? this.cachedReleaseTags,
    ),
    backgroundImagePath: _resolveOptionalField<String>(
      clear: clearBackgroundImagePath,
      next: backgroundImagePath ?? this.backgroundImagePath,
      normalize: _normalizeOptionalText,
    ),
    backgroundShaderPaths: _normalizeTrimmedStrings(
      backgroundShaderPaths ?? this.backgroundShaderPaths,
    ),
    foregroundShaderPaths: _normalizeTrimmedStrings(
      foregroundShaderPaths ?? this.foregroundShaderPaths,
    ),
    shaderAnimationMode: shaderAnimationMode ?? this.shaderAnimationMode,
    shaderBackendOverride: clearShaderBackendOverride
        ? null
        : (shaderBackendOverride ?? this.shaderBackendOverride),
    customShaderProfileJson: _resolveOptionalField<String>(
      clear: clearCustomShaderProfileJson,
      next: customShaderProfileJson ?? this.customShaderProfileJson,
      normalize: _normalizeOptionalText,
    ),
    showPerfHud: showPerfHud ?? this.showPerfHud,
    gpuDriverPreference: gpuDriverPreference ?? this.gpuDriverPreference,
    maxShaderFps: _resolveOptionalField<int>(
      clear: clearMaxShaderFps,
      next: maxShaderFps ?? this.maxShaderFps,
      normalize: _normalizeMaxShaderFps,
    ),
    localCliShaderPolicy: localCliShaderPolicy ?? this.localCliShaderPolicy,
    remoteCliShaderPolicy: remoteCliShaderPolicy ?? this.remoteCliShaderPolicy,
    cliFullPaneShaderMode: cliFullPaneShaderMode ?? this.cliFullPaneShaderMode,
    trustedCliShaderHashes: _normalizeHashes(
      trustedCliShaderHashes ?? this.trustedCliShaderHashes,
    ),
    metaKeyMode: metaKeyMode ?? this.metaKeyMode,
    passthroughShortcuts: _normalizePassthroughShortcuts(
      passthroughShortcuts ?? this.passthroughShortcuts,
    ),
  );

  static T? _resolveOptionalField<T>({
    required bool clear,
    required T? next,
    required T? Function(T? value) normalize,
  }) => clear ? null : normalize(next);

  /// Decodes [FtermPreferences] from JSON string [raw], returning [defaults] on
  /// null or malformed input.
  factory FtermPreferences.fromJsonString(String? raw) {
    if (raw == null || raw.trim().isEmpty) return defaults;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<Object?, Object?>) return defaults;
      return _decodePreferencesMap(decoded);
    } on Object {
      return defaults;
    }
  }

  static FtermPreferences _decodePreferencesMap(
    Map<Object?, Object?> decoded,
  ) => FtermPreferences(
    audioMuted: decoded['audioMuted'] == true,
    audioVolume: _parseAudioVolume(decoded['audioVolume']),
    autoHideSingleTab: decoded['autoHideSingleTab'] == true,
    macosOptionAsAlt: decoded['macosOptionAsAlt'] == true,
    fontSize: _parseFontSize(decoded['fontSize']),
    shellExecutable: _parseOptionalText(decoded['shellExecutable']),
    shellArguments: _parseStringList(decoded['shellArguments'], trim: false),
    loginShell: _parseBool(decoded['loginShell'], fallback: true),
    updateCheckMode: _parseUpdateCheckMode(decoded['updateCheckMode']),
    includePrereleases: decoded['includePrereleases'] == true,
    lastUpdateCheckUtc: _parseUtcDateTime(decoded['lastUpdateCheckUtc']),
    skippedUpdateVersion: _parseOptionalText(decoded['skippedUpdateVersion']),
    lastSeenWhatsNewVersion: _parseOptionalText(
      decoded['lastSeenWhatsNewVersion'],
    ),
    lastReleaseTagEtag: _parseOptionalText(decoded['lastReleaseTagEtag']),
    cachedReleaseTags: _parseStringList(
      decoded['cachedReleaseTags'],
      trim: true,
    ),
    backgroundImagePath: _parseOptionalText(decoded['backgroundImagePath']),
    backgroundShaderPaths: _parseStringList(
      decoded['backgroundShaderPaths'],
      trim: true,
    ),
    foregroundShaderPaths: _parseStringList(
      decoded['foregroundShaderPaths'],
      trim: true,
    ),
    shaderAnimationMode: ShaderAnimationMode.fromWireName(
      decoded['shaderAnimationMode'],
    ),
    shaderBackendOverride: ShaderBackendKind.tryFromWireName(
      decoded['shaderBackendOverride'],
    ),
    customShaderProfileJson: _parseOptionalText(
      decoded['customShaderProfileJson'],
    ),
    showPerfHud: decoded['showPerfHud'] == true,
    gpuDriverPreference: GpuDriverPreference.fromWireName(
      decoded['gpuDriverPreference'],
    ),
    maxShaderFps: _parseMaxShaderFps(decoded['maxShaderFps']),
    localCliShaderPolicy: CliShaderPolicy.fromWireName(
      decoded['localCliShaderPolicy'],
      fallback: CliShaderPolicy.promptCustomGlsl,
    ),
    remoteCliShaderPolicy: CliShaderPolicy.fromWireName(
      decoded['remoteCliShaderPolicy'],
      fallback: CliShaderPolicy.disabled,
    ),
    cliFullPaneShaderMode: CliFullPaneShaderMode.fromWireName(
      decoded['cliFullPaneShaderMode'],
      fallback: CliFullPaneShaderMode.cliBeforeUser,
    ),
    trustedCliShaderHashes: _parseHashSet(decoded['trustedCliShaderHashes']),
    metaKeyMode: FtermMetaKeyMode.fromWireName(decoded['metaKeyMode']),
    passthroughShortcuts: _parsePassthroughShortcuts(
      decoded['passthroughShortcuts'],
    ),
  );

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

  static int? _parseMaxShaderFps(Object? raw) => switch (raw) {
    final num value when value.isFinite => _normalizeMaxShaderFps(
      value.round(),
    ),
    _ => null,
  };

  static int? _normalizeMaxShaderFps(int? value) =>
      value == null || value <= 0 ? null : value.clamp(15, 240);

  static String? _parseOptionalText(Object? raw) => switch (raw) {
    final String value => _normalizeOptionalText(value),
    _ => null,
  };

  static String? _normalizeOptionalText(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static UpdateCheckMode _parseUpdateCheckMode(Object? raw) => switch (raw) {
    'daily' => UpdateCheckMode.daily,
    _ => UpdateCheckMode.manual,
  };

  static DateTime? _parseUtcDateTime(Object? raw) => switch (raw) {
    final String value => DateTime.tryParse(value.trim())?.toUtc(),
    _ => null,
  };

  static List<String> _parseStringList(Object? raw, {required bool trim}) =>
      switch (raw) {
        final List<Object?> items =>
          trim
              ? _normalizeTrimmedStrings(_extractStrings(items))
              : _normalizeNonEmptyStrings(_extractStrings(items)),
        _ => const [],
      };

  static List<String> _extractStrings(List<Object?> items) => <String>[
    for (final item in items)
      if (item case final String value) value,
  ];

  static List<String> _normalizeNonEmptyStrings(List<String> values) {
    final filtered = <String>[
      for (final item in values)
        if (item.isNotEmpty) item,
    ];
    return filtered.isEmpty ? const [] : List<String>.unmodifiable(filtered);
  }

  static List<String> _normalizeTrimmedStrings(List<String> values) {
    final filtered = <String>[
      for (final item in values)
        if (item.trim() case final trimmed when trimmed.isNotEmpty) trimmed,
    ];
    return filtered.isEmpty ? const [] : List<String>.unmodifiable(filtered);
  }

  static final RegExp _sha256Pattern = RegExp(r'^[a-fA-F0-9]{64}$');

  static Set<String> _parseHashSet(Object? raw) => switch (raw) {
    final List<Object?> items => _normalizeHashes(_extractStrings(items)),
    _ => const <String>{},
  };

  static Set<String> _normalizeHashes(Iterable<String> hashes) {
    final normalized = <String>{
      for (final item in hashes)
        if (item.trim().toLowerCase() case final clean
            when _sha256Pattern.hasMatch(clean))
          clean,
    };
    return normalized.isEmpty
        ? const <String>{}
        : Set<String>.unmodifiable(normalized);
  }

  static List<KeyChord> _parsePassthroughShortcuts(Object? raw) {
    if (raw is! List<Object?>) return const [];
    final chords = KeyChord.parseAll(_extractStrings(raw)).chords;
    return chords.isEmpty ? const [] : List<KeyChord>.unmodifiable(chords);
  }

  static List<KeyChord> _normalizePassthroughShortcuts(List<KeyChord> chords) {
    if (chords.isEmpty) return const [];
    final seen = <KeyChord>{};
    final unique = <KeyChord>[
      for (final chord in chords)
        if (seen.add(chord)) chord,
    ];
    return List<KeyChord>.unmodifiable(unique);
  }

  static bool _parseBool(Object? raw, {required bool fallback}) =>
      switch (raw) {
        final bool value => value,
        _ => fallback,
      };

  DateTime? get _normalizedCheckUtc => lastUpdateCheckUtc?.toUtc();

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
    'updateCheckMode': updateCheckMode.name,
    'includePrereleases': includePrereleases,
    if (_normalizedCheckUtc case final checkUtc?)
      'lastUpdateCheckUtc': checkUtc.toIso8601String(),
    'skippedUpdateVersion': ?skippedUpdateVersion,
    'lastSeenWhatsNewVersion': ?lastSeenWhatsNewVersion,
    'lastReleaseTagEtag': ?lastReleaseTagEtag,
    if (cachedReleaseTags.isNotEmpty) 'cachedReleaseTags': cachedReleaseTags,
    'backgroundImagePath': ?backgroundImagePath,
    if (backgroundShaderPaths.isNotEmpty)
      'backgroundShaderPaths': backgroundShaderPaths,
    if (foregroundShaderPaths.isNotEmpty)
      'foregroundShaderPaths': foregroundShaderPaths,
    'shaderAnimationMode': shaderAnimationMode.wireName,
    if (shaderBackendOverride case final backendOverride?)
      'shaderBackendOverride': backendOverride.wireName,
    'customShaderProfileJson': ?customShaderProfileJson,
    if (showPerfHud) 'showPerfHud': true,
    if (gpuDriverPreference != GpuDriverPreference.auto)
      'gpuDriverPreference': gpuDriverPreference.wireName,
    'maxShaderFps': ?maxShaderFps,
    'localCliShaderPolicy': localCliShaderPolicy.wireName,
    'remoteCliShaderPolicy': remoteCliShaderPolicy.wireName,
    'cliFullPaneShaderMode': cliFullPaneShaderMode.wireName,
    if (trustedCliShaderHashes.isNotEmpty)
      'trustedCliShaderHashes': [...trustedCliShaderHashes]..sort(),
    'metaKeyMode': metaKeyMode.wireName,
    'passthroughShortcuts': [
      for (final chord in passthroughShortcuts) chord.toCanonicalString(),
    ],
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
          other.loginShell == loginShell &&
          other.updateCheckMode == updateCheckMode &&
          other.includePrereleases == includePrereleases &&
          other._normalizedCheckUtc == _normalizedCheckUtc &&
          other.skippedUpdateVersion == skippedUpdateVersion &&
          other.lastSeenWhatsNewVersion == lastSeenWhatsNewVersion &&
          other.lastReleaseTagEtag == lastReleaseTagEtag &&
          listEquals(other.cachedReleaseTags, cachedReleaseTags) &&
          other.backgroundImagePath == backgroundImagePath &&
          listEquals(other.backgroundShaderPaths, backgroundShaderPaths) &&
          listEquals(other.foregroundShaderPaths, foregroundShaderPaths) &&
          other.shaderAnimationMode == shaderAnimationMode &&
          other.shaderBackendOverride == shaderBackendOverride &&
          other.customShaderProfileJson == customShaderProfileJson &&
          other.showPerfHud == showPerfHud &&
          other.gpuDriverPreference == gpuDriverPreference &&
          other.maxShaderFps == maxShaderFps &&
          other.localCliShaderPolicy == localCliShaderPolicy &&
          other.remoteCliShaderPolicy == remoteCliShaderPolicy &&
          other.cliFullPaneShaderMode == cliFullPaneShaderMode &&
          setEquals(other.trustedCliShaderHashes, trustedCliShaderHashes) &&
          other.metaKeyMode == metaKeyMode &&
          listEquals(other.passthroughShortcuts, passthroughShortcuts);

  @override
  int get hashCode => Object.hashAll(<Object?>[
    audioMuted,
    audioVolume,
    autoHideSingleTab,
    macosOptionAsAlt,
    fontSize,
    shellExecutable,
    Object.hashAll(shellArguments),
    loginShell,
    updateCheckMode,
    includePrereleases,
    _normalizedCheckUtc,
    skippedUpdateVersion,
    lastSeenWhatsNewVersion,
    lastReleaseTagEtag,
    Object.hashAll(cachedReleaseTags),
    backgroundImagePath,
    Object.hashAll(backgroundShaderPaths),
    Object.hashAll(foregroundShaderPaths),
    shaderAnimationMode,
    shaderBackendOverride,
    customShaderProfileJson,
    showPerfHud,
    gpuDriverPreference,
    maxShaderFps,
    localCliShaderPolicy,
    remoteCliShaderPolicy,
    cliFullPaneShaderMode,
    Object.hashAllUnordered(trustedCliShaderHashes),
    metaKeyMode,
    Object.hashAll(passthroughShortcuts),
  ]);
}

/// Relay connection credentials persisted in `0600` desktop storage (or
/// tab-scoped `window.sessionStorage` on Web, scoped to the matching relay URL)
/// when the user connects to a relay from the UI or configures caster sharing.
final class RelayCredentials {
  /// Empty credentials placeholder.
  static const RelayCredentials empty = RelayCredentials();

  /// Saved `/v1/client` WebSocket URL string, if configured.
  final String serverUrl;

  /// Saved viewer bearer token.
  final String clientToken;

  /// Saved caster bearer token used when publishing local shells.
  final String casterToken;

  /// Saved Cloud Run IAP service account email (`gcloud` signing mode).
  final String iapServiceAccount;

  /// Saved Cloud Run IAP service account JSON key file path (local signing mode).
  final String iapKeyFilePath;

  /// Optional custom `gcloud` executable path override for IAP signing.
  final String gcloudPath;

  /// Creates an immutable [RelayCredentials] value.
  const RelayCredentials({
    this.serverUrl = '',
    this.clientToken = '',
    this.casterToken = '',
    this.iapServiceAccount = '',
    this.iapKeyFilePath = '',
    this.gcloudPath = '',
  });

  /// Whether all credential fields are empty.
  bool get isEmpty =>
      serverUrl.isEmpty &&
      clientToken.isEmpty &&
      casterToken.isEmpty &&
      iapServiceAccount.isEmpty &&
      iapKeyFilePath.isEmpty &&
      gcloudPath.isEmpty;

  /// Decodes [RelayCredentials] from JSON string [raw], returning [empty] when
  /// missing or malformed.
  factory RelayCredentials.fromJsonString(String? raw) {
    if (raw == null || raw.trim().isEmpty) return empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<Object?, Object?>) return empty;
      return RelayCredentials(
        serverUrl: _readString(decoded['serverUrl']),
        clientToken: _readString(decoded['clientToken']),
        casterToken: _readString(decoded['casterToken']),
        iapServiceAccount: _readString(decoded['iapServiceAccount']),
        iapKeyFilePath: _readString(decoded['iapKeyFilePath']),
        gcloudPath: _readString(decoded['gcloudPath']),
      );
    } on Object {
      return empty;
    }
  }

  static String _readString(Object? raw) => raw is String ? raw : '';

  /// Serializes these relay credentials as a JSON object string.
  String toJsonString() => jsonEncode(<String, Object?>{
    'serverUrl': serverUrl,
    'clientToken': clientToken,
    'casterToken': casterToken,
    if (iapServiceAccount.isNotEmpty) 'iapServiceAccount': iapServiceAccount,
    if (iapKeyFilePath.isNotEmpty) 'iapKeyFilePath': iapKeyFilePath,
    if (gcloudPath.isNotEmpty) 'gcloudPath': gcloudPath,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RelayCredentials &&
          other.serverUrl == serverUrl &&
          other.clientToken == clientToken &&
          other.casterToken == casterToken &&
          other.iapServiceAccount == iapServiceAccount &&
          other.iapKeyFilePath == iapKeyFilePath &&
          other.gcloudPath == gcloudPath;

  @override
  int get hashCode => Object.hash(
    serverUrl,
    clientToken,
    casterToken,
    iapServiceAccount,
    iapKeyFilePath,
    gcloudPath,
  );
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

/// Writes [credentials] as JSON to [storage] (`0600` POSIX file on desktop,
/// tab-scoped `window.sessionStorage` on Web).
void saveStoredRelayCredentials(
  SettingsStorage storage,
  RelayCredentials credentials,
) => storage.setItem(
  ftermRelayCredentialsStorageKey,
  credentials.toJsonString(),
);

final class _LeafBudget {
  int remaining;

  _LeafBudget(this.remaining);

  bool consumeLeaf() {
    if (remaining <= 0) return false;
    remaining -= 1;
    return true;
  }
}

/// Serializable binary split-tree node persisted for Web workspace resume.
sealed class WebResumeSplitNode {
  static const int _maxDecodeDepth = 32;

  /// Maximum total leaf panes permitted when decoding a single tab split tree.
  static const int maxDecodedLeaves = 32;

  /// Creates an immutable resume split node.
  const WebResumeSplitNode();

  /// In-order list of remote session identifiers referenced by leaf panes.
  List<String> get sessionIds {
    final ids = <String>[];
    _collectSessionIds(this, ids);
    return List<String>.unmodifiable(ids);
  }

  /// Serializes this node as a JSON-compatible map.
  Map<String, Object?> toJsonMap();

  /// Decodes a [WebResumeSplitNode] from untrusted JSON [raw], returning `null`
  /// when malformed, exceeding maximum nesting depth, or exceeding
  /// [maxDecodedLeaves] total leaves.
  static WebResumeSplitNode? tryFromJson(Object? raw) =>
      _tryFromJson(raw, depth: 0, budget: _LeafBudget(maxDecodedLeaves));

  static WebResumeSplitNode? _tryFromJson(
    Object? raw, {
    required int depth,
    required _LeafBudget budget,
  }) {
    if (depth > _maxDecodeDepth || raw is! Map<Object?, Object?>) return null;
    return switch (raw['type']) {
      'leaf' => _decodeLeaf(raw['sessionId'], budget),
      'split' => _decodeSplit(raw, depth, budget),
      _ => null,
    };
  }

  static WebResumePaneLeaf? _decodeLeaf(
    Object? rawSessionId,
    _LeafBudget budget,
  ) {
    if (!budget.consumeLeaf() || rawSessionId is! String) return null;
    final trimmed = rawSessionId.trim();
    return trimmed.isEmpty ? null : WebResumePaneLeaf(trimmed);
  }

  static WebResumeSplitBranch? _decodeSplit(
    Map<Object?, Object?> raw,
    int depth,
    _LeafBudget budget,
  ) {
    final axis = switch (raw['axis']) {
      'horizontal' => SplitAxis.horizontal,
      'vertical' => SplitAxis.vertical,
      _ => null,
    };
    if (axis == null) return null;
    final first = _tryFromJson(raw['first'], depth: depth + 1, budget: budget);
    if (first == null) return null;
    final second = _tryFromJson(
      raw['second'],
      depth: depth + 1,
      budget: budget,
    );
    if (second == null) return null;
    final ratioRaw = raw['ratio'];
    final ratio = ratioRaw is num && ratioRaw.isFinite
        ? SplitTreeNode.clampRatio(ratioRaw.toDouble())
        : 0.5;
    return WebResumeSplitBranch(
      axis: axis,
      ratio: ratio,
      first: first,
      second: second,
    );
  }

  static void _collectSessionIds(WebResumeSplitNode node, List<String> out) {
    switch (node) {
      case WebResumePaneLeaf(:final sessionId):
        out.add(sessionId);
      case WebResumeSplitBranch(:final first, :final second):
        _collectSessionIds(first, out);
        _collectSessionIds(second, out);
    }
  }
}

/// Leaf pane entry in a [WebTabResumeState] referencing a remote [sessionId].
final class WebResumePaneLeaf extends WebResumeSplitNode {
  /// Remote relay session identifier displayed in this pane.
  final String sessionId;

  /// Creates an immutable leaf entry for [sessionId].
  const WebResumePaneLeaf(this.sessionId);

  @override
  Map<String, Object?> toJsonMap() => <String, Object?>{
    'type': 'leaf',
    'sessionId': sessionId,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WebResumePaneLeaf && other.sessionId == sessionId;

  @override
  int get hashCode => sessionId.hashCode;
}

/// Binary split container in a [WebTabResumeState].
final class WebResumeSplitBranch extends WebResumeSplitNode {
  /// Division axis (`horizontal` = left|right, `vertical` = top/bottom).
  final SplitAxis axis;

  /// Fraction of space allocated to [first] in `[0.1, 0.9]`.
  final double ratio;

  /// Left or top child subtree.
  final WebResumeSplitNode first;

  /// Right or bottom child subtree.
  final WebResumeSplitNode second;

  /// Creates an immutable split branch with clamped [ratio].
  WebResumeSplitBranch({
    required this.axis,
    double ratio = 0.5,
    required this.first,
    required this.second,
  }) : ratio = SplitTreeNode.clampRatio(ratio);

  @override
  Map<String, Object?> toJsonMap() => <String, Object?>{
    'type': 'split',
    'axis': axis.name,
    'ratio': ratio,
    'first': first.toJsonMap(),
    'second': second.toJsonMap(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WebResumeSplitBranch &&
          other.axis == axis &&
          other.ratio == ratio &&
          other.first == first &&
          other.second == second;

  @override
  int get hashCode => Object.hash(axis, ratio, first, second);
}

/// Persisted Web workspace tab layout state captured across same-tab reloads.
final class WebTabResumeState {
  /// Root split-tree layout node for this tab.
  final WebResumeSplitNode root;

  /// Zero-based index of the focused leaf pane within [root].
  final int focusedLeafIndex;

  /// Optional user-pinned custom tab title.
  final String? pinnedTitle;

  /// Creates an immutable [WebTabResumeState].
  const WebTabResumeState({
    required this.root,
    this.focusedLeafIndex = 0,
    this.pinnedTitle,
  });

  /// Ordered remote session identifiers referenced by this tab's leaf panes.
  List<String> get sessionIds => root.sessionIds;

  /// Decodes a [WebTabResumeState] from untrusted JSON [raw], returning `null`
  /// when malformed.
  static WebTabResumeState? tryFromJson(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    final root = WebResumeSplitNode.tryFromJson(raw['root']);
    if (root == null) return null;
    final focusRaw = raw['focusedLeafIndex'];
    final focusIdx = focusRaw is num && focusRaw.isFinite
        ? focusRaw.toInt().clamp(0, root.sessionIds.length - 1)
        : 0;
    final pinnedRaw = raw['pinnedTitle'];
    final pinned = pinnedRaw is String && pinnedRaw.trim().isNotEmpty
        ? pinnedRaw.trim()
        : null;
    return WebTabResumeState(
      root: root,
      focusedLeafIndex: focusIdx,
      pinnedTitle: pinned,
    );
  }

  /// Serializes this tab state as a JSON-compatible map.
  Map<String, Object?> toJsonMap() => <String, Object?>{
    'root': root.toJsonMap(),
    if (focusedLeafIndex != 0) 'focusedLeafIndex': focusedLeafIndex,
    'pinnedTitle': ?pinnedTitle,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WebTabResumeState &&
          other.root == root &&
          other.focusedLeafIndex == focusedLeafIndex &&
          other.pinnedTitle == pinnedTitle;

  @override
  int get hashCode => Object.hash(root, focusedLeafIndex, pinnedTitle);
}

/// Tab-scoped snapshot of open remote sessions, split trees, active tab, and
/// dismissed remote sessions persisted in `window.sessionStorage` on Web.
final class WebWorkspaceResumeSnapshot {
  /// Empty snapshot placeholder.
  static const WebWorkspaceResumeSnapshot empty = WebWorkspaceResumeSnapshot();

  /// Maximum number of tabs decoded from an untrusted resume snapshot.
  static const int maxDecodedTabs = 64;

  /// Relay `/v1/client` WebSocket URL string this snapshot was captured from.
  final String serverUrl;

  /// Ordered open tabs and their binary split layouts.
  final List<WebTabResumeState> tabs;

  /// Active tab index (`0` when [tabs] is empty).
  final int activeTabIndex;

  /// Remote session identifiers explicitly closed by the user.
  final Set<String> dismissedSessionIds;

  /// Creates an immutable [WebWorkspaceResumeSnapshot].
  const WebWorkspaceResumeSnapshot({
    this.serverUrl = '',
    this.tabs = const <WebTabResumeState>[],
    this.activeTabIndex = 0,
    this.dismissedSessionIds = const <String>{},
  });

  /// Whether no tabs or dismissed sessions are recorded.
  bool get isEmpty => tabs.isEmpty && dismissedSessionIds.isEmpty;

  /// Decodes [WebWorkspaceResumeSnapshot] from JSON string [raw], returning
  /// [empty] when missing or malformed.
  factory WebWorkspaceResumeSnapshot.fromJsonString(String? raw) {
    if (raw == null || raw.trim().isEmpty) return empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<Object?, Object?>) return empty;
      return _decodeSnapshotMap(decoded);
    } on Object {
      return empty;
    }
  }

  static WebWorkspaceResumeSnapshot _decodeSnapshotMap(
    Map<Object?, Object?> decoded,
  ) {
    final parsedTabs = _parseTabs(decoded['tabs']);
    final dismissed = _parseDismissedIds(decoded['dismissedSessionIds']);
    if (parsedTabs.isEmpty && dismissed.isEmpty) return empty;
    final serverUrl = switch (decoded['serverUrl']) {
      final String value => value.trim(),
      _ => '',
    };
    return WebWorkspaceResumeSnapshot(
      serverUrl: serverUrl,
      tabs: List<WebTabResumeState>.unmodifiable(parsedTabs),
      activeTabIndex: _parseActiveTabIndex(
        decoded['activeTabIndex'],
        parsedTabs.length,
      ),
      dismissedSessionIds: Set<String>.unmodifiable(dismissed),
    );
  }

  static List<WebTabResumeState> _parseTabs(Object? raw) {
    if (raw is! List<Object?>) return const <WebTabResumeState>[];
    final parsed = <WebTabResumeState>[];
    for (final entry in raw) {
      if (parsed.length >= maxDecodedTabs) break;
      final tab = WebTabResumeState.tryFromJson(entry);
      if (tab != null) {
        parsed.add(tab);
      }
    }
    return parsed;
  }

  static Set<String> _parseDismissedIds(Object? raw) => switch (raw) {
    final List<Object?> items => <String>{
      for (final entry in items)
        if (entry is String && entry.trim().isNotEmpty) entry.trim(),
    },
    _ => const <String>{},
  };

  static int _parseActiveTabIndex(Object? raw, int tabCount) {
    if (tabCount <= 0) return 0;
    return raw is num && raw.isFinite ? raw.toInt().clamp(0, tabCount - 1) : 0;
  }

  /// Serializes this snapshot as a JSON object string.
  String toJsonString() => jsonEncode(<String, Object?>{
    if (serverUrl.isNotEmpty) 'serverUrl': serverUrl,
    'tabs': [for (final tab in tabs) tab.toJsonMap()],
    'activeTabIndex': tabs.isEmpty
        ? 0
        : activeTabIndex.clamp(0, tabs.length - 1),
    if (dismissedSessionIds.isNotEmpty)
      'dismissedSessionIds': [...dismissedSessionIds]..sort(),
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WebWorkspaceResumeSnapshot &&
          other.serverUrl == serverUrl &&
          listEquals(other.tabs, tabs) &&
          other.activeTabIndex == activeTabIndex &&
          setEquals(other.dismissedSessionIds, dismissedSessionIds);

  @override
  int get hashCode => Object.hash(
    serverUrl,
    Object.hashAll(tabs),
    activeTabIndex,
    Object.hashAllUnordered(dismissedSessionIds),
  );
}

/// Loads [WebWorkspaceResumeSnapshot] from [storage] (`window.sessionStorage`
/// on Web; returns [WebWorkspaceResumeSnapshot.empty] on desktop/missing data).
WebWorkspaceResumeSnapshot loadWebWorkspaceResumeSnapshot(
  SettingsStorage storage,
) => WebWorkspaceResumeSnapshot.fromJsonString(
  storage.getItem(ftermWebWorkspaceResumeStorageKey),
);

/// Writes [snapshot] as JSON to [storage] under
/// [ftermWebWorkspaceResumeStorageKey].
void saveWebWorkspaceResumeSnapshot(
  SettingsStorage storage,
  WebWorkspaceResumeSnapshot snapshot,
) =>
    storage.setItem(ftermWebWorkspaceResumeStorageKey, snapshot.toJsonString());

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
