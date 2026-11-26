import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Callback used to pause choreography between scripted beats.
typedef SizzleSleep = Future<void> Function(Duration duration);

/// Error raised when an `fterm` HTTP automation request fails or returns
/// `ok: false`.
final class FtermDriverException implements Exception {
  /// HTTP status code returned by the driver, or `0` on transport failure.
  final int statusCode;

  /// Machine-readable error code returned by `fterm`, if available.
  final String code;

  /// Human-readable diagnostic message.
  final String message;

  /// Optional structured error details (for example GLSL compile diagnostics).
  final Map<String, Object?>? details;

  /// Creates an [FtermDriverException].
  const FtermDriverException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.details,
  });

  @override
  String toString() => 'FtermDriverException($statusCode $code): $message';
}

/// Error raised when an OBS WebSocket v5 request fails or disconnects.
final class ObsWebSocketException implements Exception {
  /// Machine-readable OBS status code or transport identifier.
  final int code;

  /// Human-readable failure message.
  final String message;

  /// Creates an [ObsWebSocketException].
  const ObsWebSocketException({required this.code, required this.message});

  @override
  String toString() => 'ObsWebSocketException($code): $message';
}

/// Persisted `fterm` automation driver connection settings read from
/// `settings.json`.
final class PersistedFtermDriverConfig {
  /// Loopback port (`1..65535`).
  final int port;

  /// Persisted Bearer token.
  final String password;

  /// Creates a [PersistedFtermDriverConfig].
  const PersistedFtermDriverConfig({
    required this.port,
    required this.password,
  });
}

/// Recording mode for [SizzleDirector].
enum SizzleRecordingMode {
  /// Single master recording with embedded OBS chapter markers per Act.
  master('master'),

  /// Separate `.mkv`/recording take file per Act for Blender VSE assembly.
  takes('takes');

  /// CLI wire name.
  final String wireName;

  const SizzleRecordingMode(this.wireName);

  /// Parses [raw] into a [SizzleRecordingMode], or returns `null` if invalid.
  static SizzleRecordingMode? tryParse(String raw) => switch (raw.trim()) {
    'master' => master,
    'takes' => takes,
    _ => null,
  };
}

/// Resolved CLI configuration for `tool/sizzle.dart`.
final class SizzleConfig {
  /// Loopback `fterm` automation driver host.
  final String ftermHost;

  /// Loopback `fterm` automation driver port.
  final int ftermPort;

  /// Bearer authentication token for `fterm`.
  final String ftermToken;

  /// Whether OBS WebSocket v5 orchestration is enabled.
  final bool useObs;

  /// OBS WebSocket v5 endpoint URI (`ws://127.0.0.1:4455` by default).
  final Uri obsUri;

  /// Optional OBS WebSocket v5 password.
  final String? obsPassword;

  /// Optional OBS text source name for lower-third overlay badges.
  final String? obsOverlayInput;

  /// Optional OBS scene name paired with [obsOverlayInput] visibility toggles.
  final String? obsOverlayScene;

  /// OBS scene created/selected for capturing the automated `fterm` window.
  final String obsScene;

  /// OBS `window_capture` input name created/updated inside [obsScene].
  final String obsWindowInput;

  /// OBS `ffmpeg_source` input name playing the lower-octave intro audio bed
  /// prior to Act 2's live 3D spatial audio reveal.
  final String obsIntroAudioInput;

  /// Whether to synthesize/play the lower-octave intro audio bed in OBS.
  final bool useIntroBed;

  /// Optional explicit path to a pre-rendered intro audio bed `.wav`/`.ogg`.
  final String? introBedPath;

  /// Lower-right badge shown on the `flutter_gpu` terminal tab right after
  /// closing the Act 1 shader editor.
  final String devBadge;

  /// Native Win32 window title assigned via `--window-title` so OBS captures
  /// the stage instance without colliding with an everyday `fterm` session.
  final String windowTitle;

  /// Recording layout (`master` single file with chapters, or per-Act `takes`).
  final SizzleRecordingMode mode;

  /// Ordered subset of Acts (`1..4`) to execute during the shoot.
  final Set<int> acts;

  /// Output directory for renamed master or per-Act recordings.
  final String outputDir;

  /// Output filename stem for `master` mode.
  final String masterName;

  /// Capture stage width in physical pixels (default `1920`).
  final int stageWidth;

  /// Capture stage height in physical pixels (default `1080`).
  final int stageHeight;

  /// Split-screen width in physical pixels for Act 3 (default `960`).
  final int splitWidth;

  /// Terminal font size applied during recording (default `18.0`).
  final double fontSize;

  /// Working directory for Tab 1 (dev scrollback).
  final String devCwd;

  /// Tab 1 title.
  final String devTitle;

  /// Shell command executed in Tab 1 during pre-roll.
  final String devCommand;

  /// Regex awaited in Tab 1 after [devCommand] runs.
  final String devWaitPattern;

  /// Working directory for Tab 2 (`roguetui_fx` / `ESC _ S` showcase).
  final String fxCwd;

  /// Tab 2 title.
  final String fxTitle;

  /// Optional command executed in Tab 2 during pre-roll (for example launching
  /// `termui_cast` wrapping `roguetui_fx`).
  final String? fxCommand;

  /// Regex awaited in Tab 2 after [fxCommand] starts.
  final String fxWaitPattern;

  /// Optional shell prompt regex awaited right after spawning a tab.
  final String promptPattern;

  /// Built-in background shader preset wire name used in Act 1 (default
  /// `wallpaper_wave`). Ignored when [shaderPath] is set.
  final String shaderPreset;

  /// Optional custom `.glsl` shader path for Act 1 instead of [shaderPreset].
  final String? shaderPath;

  /// Optional custom `.glsl` background shader applied behind terminal text
  /// after closing the Act 1 shader editor (for example `damask rose.glsl`).
  final String? bgShaderPath;

  /// Background opacity (`0.0..1.0`) applied to shaders so background art shows
  /// through clearly behind terminal text (default `0.70`).
  final double backgroundOpacity;

  /// Ordered foreground shader preset wire names applied after closing the
  /// shader editor in Act 1 (default `['scanline_overlay', 'phosphor_glow']`).
  final List<String> foregroundPresets;

  /// Anchored prefix inside the Act 1 shader preceding [patchOldValue].
  final String patchPrefix;

  /// Initial constant token present in the shader before Act 1 live typing.
  final String patchOldValue;

  /// Final constant token typed character-by-character in Act 1 when
  /// [patchSteps] is empty.
  final String patchNewValue;

  /// Optional ordered constant values stepped through in Act 1 with a pause
  /// between each value (for example `['1.0', '2.0', '3.0', '4.0']` for the
  /// kaleidoscope iteration loop).
  final List<String> patchSteps;

  /// Delay between consecutive [patchSteps] transitions in milliseconds.
  final int patchStepDelayMs;

  /// Optional key sequence written to Tab 2 in Act 2 to trigger `ESC _ S`
  /// effects or start 3D audio playback (skipped when `null`).
  final String? fxTriggerKey;

  /// Ordered WASD / navigation keys written to Tab 2 in Act 2 after
  /// [fxTriggerKey] (for example orbiting a 3D audio source around the
  /// listener).
  final List<String> fxMoveKeys;

  /// Delay between consecutive [fxMoveKeys] keypresses in milliseconds.
  final int fxMoveDelayMs;

  /// Optional quit key written to Tab 2 at the end of Act 2 (for example `'q'`
  /// to stop audio playback cleanly before the outro).
  final String? fxQuitKey;

  /// Working directory for Act 0 (`glass.exe` opening fire title card).
  final String glassCwd;

  /// Command executed in Act 0 (`.\build\glass.exe` when auto-discovered).
  final String? glassCommand;

  /// Hold duration for Act 0 (`glass.exe`) in milliseconds (default `3800`).
  final int glassDurationMs;

  /// Working directory for Act 5 (`shader_text_arcade.exe`).
  final String arcadeCwd;

  /// Command executed in Act 5 (`.\build\text_arcade\bundle\bin\shader_text_arcade.exe`).
  final String? arcadeCommand;

  /// Visible TUI button label searched via `/v1/screen/find` and clicked in
  /// Act 2.
  final String fxButtonText;

  /// Sequence of keys written to Tab 2 during Act 3 split-screen movement.
  final List<String> act3Keys;

  /// Whether to restore `fterm`'s original window bounds, UI settings, and
  /// shaders in `finally`.
  final bool restoreOnExit;

  /// Whether to launch a fresh `fterm` desktop process with automation flags
  /// before connecting.
  final bool launchFterm;

  /// Optional explicit path to the `fterm` desktop executable (implies
  /// [launchFterm]).
  final String? ftermBin;

  /// Whether to leave a spawned `fterm` process running after the shoot ends.
  final bool keepFterm;

  /// Whether to print usage help and exit without running.
  final bool showHelp;

  /// Creates a [SizzleConfig].
  const SizzleConfig({
    this.ftermHost = '127.0.0.1',
    this.ftermPort = 9911,
    this.ftermToken = '',
    this.useObs = true,
    required this.obsUri,
    this.obsPassword,
    this.obsOverlayInput = 'sizzle_badge',
    this.obsOverlayScene = 'fterm_sizzle',
    this.obsScene = 'fterm_sizzle',
    this.obsWindowInput = 'fterm_window',
    this.obsIntroAudioInput = 'sizzle_intro_bed',
    this.useIntroBed = true,
    this.introBedPath,
    this.devBadge = 'driven via built-in HTTP API',
    this.windowTitle = 'fterm-sizzle',
    this.mode = SizzleRecordingMode.master,
    this.acts = const <int>{1, 2, 3, 4},
    this.outputDir = 'build/promo_takes',
    this.masterName = 'fterm_v070_master',
    this.stageWidth = 1920,
    this.stageHeight = 1080,
    this.splitWidth = 960,
    this.fontSize = 18.0,
    this.devCwd = '.',
    this.devTitle = 'flutter_gpu',
    this.devCommand = 'git show --stat',
    this.devWaitPattern = 'files? changed',
    this.fxCwd = '.',
    this.fxTitle = 'roguetui_fx',
    this.fxCommand,
    this.fxWaitPattern = 'HP|Dungeon|roguetui',
    this.promptPattern = 'PS |>|\\\$|❯|➜|→|»|λ|[\uE000-\uF8FF]',
    this.shaderPreset = 'wallpaper_wave',
    this.shaderPath,
    this.bgShaderPath,
    this.backgroundOpacity = 0.70,
    this.foregroundPresets = const <String>[
      'scanline_overlay',
      'phosphor_glow',
    ],
    this.patchPrefix = 'uParams0.x : ',
    this.patchOldValue = '0.35',
    this.patchNewValue = '1.85',
    this.patchSteps = const <String>[],
    this.patchStepDelayMs = 3000,
    this.fxTriggerKey,
    this.fxMoveKeys = const <String>[],
    this.fxMoveDelayMs = 160,
    this.fxQuitKey,
    this.glassCwd = '.',
    this.glassCommand,
    this.glassDurationMs = 3800,
    this.arcadeCwd = '.',
    this.arcadeCommand,
    this.fxButtonText = '[ Cast ]',
    this.act3Keys = const <String>['d', 'd', 'w', 'd', ' ', 'd', 's', 'd'],
    this.restoreOnExit = true,
    this.launchFterm = false,
    this.ftermBin,
    this.keepFterm = false,
    this.showHelp = false,
  });

  /// Base loopback URI for the `fterm` HTTP automation driver.
  Uri get ftermBaseUri => Uri(scheme: 'http', host: ftermHost, port: ftermPort);

  /// Parses CLI [args], environment variables, and optional persisted
  /// `settings.json` fallback into a [SizzleConfig].
  ///
  /// Throws [FormatException] on unknown flags or invalid numeric values.
  factory SizzleConfig.parseArgs(
    List<String> args, {
    Map<String, String>? environment,
    PersistedFtermDriverConfig? persistedConfig,
  }) {
    final env = environment ?? Platform.environment;
    final flags = _parseFlagMap(args);
    if (flags.containsKey('help')) {
      return SizzleConfig(
        obsUri: Uri.parse('ws://127.0.0.1:4455'),
        showHelp: true,
      );
    }

    final persisted =
        persistedConfig ?? readPersistedFtermDriverConfig(environment: env);
    final port = _parsePositiveInt(
      flags['port'],
      flag: '--port',
      fallback: persisted?.port ?? 9911,
      max: 65535,
    );
    final ftermBin = _nonEmpty(flags['fterm-bin']);
    final launchFterm = flags.containsKey('launch-fterm') || ftermBin != null;
    final token =
        _nonEmpty(flags['token']) ??
        _nonEmpty(env['FTERM_AUTOMATION_TOKEN']) ??
        persisted?.password ??
        (launchFterm ? generateEphemeralAutomationToken() : '');
    final modeRaw = flags['mode'] ?? 'master';
    final mode = SizzleRecordingMode.tryParse(modeRaw);
    if (mode == null) {
      throw FormatException(
        'Invalid --mode "$modeRaw": expected "master" or "takes".',
      );
    }
    final acts = _parseActs(flags['acts']);
    final obsUri = Uri.parse(
      _nonEmpty(flags['obs-url']) ??
          _nonEmpty(env['OBS_WEBSOCKET_URL']) ??
          'ws://127.0.0.1:4455',
    );
    final act3Raw = _nonEmpty(flags['act3-keys']);
    final fgRaw = _nonEmpty(flags['fg-presets']);
    final patchStepsRaw = _nonEmpty(flags['patch-steps']);
    final fxMoveRaw = _nonEmpty(flags['fx-move-keys']);

    final explicitShaderOverride =
        flags.containsKey('shader-path') || flags.containsKey('shader-preset');
    final autoKaleidoscope = explicitShaderOverride
        ? null
        : _resolveUserShaderPath('kaliedoscope.glsl', environment: env);
    final autoDamaskRose = flags.containsKey('bg-shader-path')
        ? null
        : _resolveUserShaderPath('damask rose.glsl', environment: env);
    final autoAudioDemo = flags.containsKey('fx-command')
        ? null
        : _resolveLocalDemo(
            windowsRelPath: r'build\audio.exe\bundle\bin\main.exe',
            posixRelPath: 'build/audio.exe/bundle/bin/main.exe',
            workingDir: Directory.current.path,
          );
    final autoGlassDemo = flags.containsKey('glass-command')
        ? null
        : _resolveLocalDemo(
            windowsRelPath: r'build\glass.exe',
            posixRelPath: 'build/glass.exe',
            workingDir: Directory.current.path,
          );
    final autoArcadeDemo = flags.containsKey('arcade-command')
        ? null
        : _resolveLocalDemo(
            windowsRelPath:
                r'build\text_arcade\bundle\bin\shader_text_arcade.exe',
            posixRelPath: 'build/text_arcade/bundle/bin/shader_text_arcade.exe',
            workingDir: Directory.current.path,
          );

    final useKaleidoscopeDefaults =
        autoKaleidoscope != null &&
        !flags.containsKey('patch-prefix') &&
        !flags.containsKey('patch-old') &&
        !flags.containsKey('patch-new') &&
        !flags.containsKey('patch-steps');
    final resolvedPatchSteps = patchStepsRaw != null
        ? <String>[
            for (final item in patchStepsRaw.split(','))
              if (item.trim().isNotEmpty) item.trim(),
          ]
        : useKaleidoscopeDefaults
        ? const <String>['0', '1', '4']
        : const <String>[];
    final resolvedFxMoveKeys = fxMoveRaw != null
        ? <String>[
            for (final item in fxMoveRaw.split(','))
              if (item.isNotEmpty) item,
          ]
        : autoAudioDemo != null
        ? defaultAudioOrbitKeys
        : const <String>[];

    final resolvedObsScene = _nonEmpty(flags['obs-scene']) ?? 'fterm_sizzle';
    return SizzleConfig(
      ftermHost: _nonEmpty(flags['host']) ?? '127.0.0.1',
      ftermPort: port,
      ftermToken: token,
      useObs: !flags.containsKey('no-obs'),
      obsUri: obsUri,
      obsPassword:
          _nonEmpty(flags['obs-password']) ??
          _nonEmpty(env['OBS_WEBSOCKET_PASSWORD']),
      obsOverlayInput: _nonEmpty(flags['obs-overlay-input']) ?? 'sizzle_badge',
      obsOverlayScene:
          _nonEmpty(flags['obs-overlay-scene']) ?? resolvedObsScene,
      obsScene: resolvedObsScene,
      obsWindowInput: _nonEmpty(flags['obs-window-input']) ?? 'fterm_window',
      obsIntroAudioInput:
          _nonEmpty(flags['obs-intro-audio-input']) ?? 'sizzle_intro_bed',
      useIntroBed: !flags.containsKey('no-intro-bed'),
      introBedPath: _nonEmpty(flags['intro-bed']),
      devBadge: _nonEmpty(flags['dev-badge']) ?? 'driven via built-in HTTP API',
      windowTitle: _nonEmpty(flags['window-title']) ?? 'fterm-sizzle',
      mode: mode,
      acts: acts,
      outputDir: _nonEmpty(flags['out-dir']) ?? 'build/promo_takes',
      masterName: _nonEmpty(flags['master-name']) ?? 'fterm_v070_master',
      stageWidth: _parsePositiveInt(
        flags['stage-width'],
        flag: '--stage-width',
        fallback: 1920,
      ),
      stageHeight: _parsePositiveInt(
        flags['stage-height'],
        flag: '--stage-height',
        fallback: 1080,
      ),
      splitWidth: _parsePositiveInt(
        flags['split-width'],
        flag: '--split-width',
        fallback: 960,
      ),
      fontSize: _parsePositiveDouble(
        flags['font-size'],
        flag: '--font-size',
        fallback: 18.0,
      ),
      devCwd: _nonEmpty(flags['dev-cwd']) ?? Directory.current.path,
      devTitle: _nonEmpty(flags['dev-title']) ?? 'flutter_gpu',
      devCommand: _nonEmpty(flags['dev-command']) ?? 'git show --stat',
      devWaitPattern: _nonEmpty(flags['dev-wait']) ?? 'files? changed',
      fxCwd:
          _nonEmpty(flags['fx-cwd']) ??
          autoAudioDemo?.cwd ??
          Directory.current.path,
      fxTitle:
          _nonEmpty(flags['fx-title']) ??
          (autoAudioDemo != null ? '3d_audio' : 'roguetui_fx'),
      fxCommand: _nonEmpty(flags['fx-command']) ?? autoAudioDemo?.command,
      fxWaitPattern:
          _nonEmpty(flags['fx-wait']) ??
          (autoAudioDemo != null
              ? '3D SPATIAL AUDIO GRID'
              : 'HP|Dungeon|roguetui'),
      promptPattern:
          _nonEmpty(flags['prompt-pattern']) ??
          'PS |>|\\\$|❯|➜|→|»|λ|[\uE000-\uF8FF]',
      shaderPreset: _nonEmpty(flags['shader-preset']) ?? 'wallpaper_wave',
      shaderPath: _nonEmpty(flags['shader-path']) ?? autoKaleidoscope,
      bgShaderPath: _nonEmpty(flags['bg-shader-path']) ?? autoDamaskRose,
      backgroundOpacity: _parseUnitDouble(
        flags['bg-opacity'],
        flag: '--bg-opacity',
        fallback: 0.70,
      ),
      foregroundPresets: fgRaw == null
          ? const <String>['scanline_overlay', 'phosphor_glow']
          : <String>[
              for (final item in fgRaw.split(','))
                if (item.trim().isNotEmpty) item.trim(),
            ],
      patchPrefix:
          flags['patch-prefix'] ??
          (useKaleidoscopeDefaults ? '#define ITS ' : 'uParams0.x : '),
      patchOldValue:
          _nonEmpty(flags['patch-old']) ??
          (useKaleidoscopeDefaults ? '0' : '0.35'),
      patchNewValue: _nonEmpty(flags['patch-new']) ?? '1.85',
      patchSteps: resolvedPatchSteps,
      patchStepDelayMs: _parsePositiveInt(
        flags['patch-step-delay-ms'],
        flag: '--patch-step-delay-ms',
        fallback: 3000,
      ),
      fxTriggerKey:
          flags['fx-trigger-key'] ?? (autoAudioDemo != null ? '1' : null),
      fxMoveKeys: resolvedFxMoveKeys,
      fxMoveDelayMs: _parsePositiveInt(
        flags['fx-move-delay-ms'],
        flag: '--fx-move-delay-ms',
        fallback: 160,
      ),
      fxQuitKey: flags['fx-quit-key'] ?? (autoAudioDemo != null ? 'q' : null),
      glassCwd:
          _nonEmpty(flags['glass-cwd']) ??
          autoGlassDemo?.cwd ??
          Directory.current.path,
      glassCommand: _nonEmpty(flags['glass-command']) ?? autoGlassDemo?.command,
      glassDurationMs: _parsePositiveInt(
        flags['glass-duration-ms'],
        flag: '--glass-duration-ms',
        fallback: 3800,
      ),
      arcadeCwd:
          _nonEmpty(flags['arcade-cwd']) ??
          autoArcadeDemo?.cwd ??
          Directory.current.path,
      arcadeCommand:
          _nonEmpty(flags['arcade-command']) ?? autoArcadeDemo?.command,
      fxButtonText: _nonEmpty(flags['fx-button']) ?? '[ Cast ]',
      act3Keys: act3Raw == null
          ? const <String>['d', 'd', 'w', 'd', ' ', 'd', 's', 'd']
          : act3Raw.split(','),
      restoreOnExit: !flags.containsKey('no-restore'),
      launchFterm: launchFterm,
      ftermBin: ftermBin,
      keepFterm: flags.containsKey('keep-fterm'),
    );
  }

  /// Default 3D spatial orbit WASD sequence for the `termui_audio` grid demo:
  /// sweeps left, up-left, across to far right, down-right, and back around
  /// the blue `X` listener so stereo panning and distance attenuation shine.
  static const List<String> defaultAudioOrbitKeys = <String>[
    'a',
    'a',
    'a',
    'a',
    'a',
    'a',
    'w',
    'w',
    'w',
    'd',
    'd',
    'd',
    'd',
    'd',
    'd',
    'd',
    'd',
    'd',
    'd',
    'd',
    'd',
    's',
    's',
    's',
    's',
    's',
    's',
    'a',
    'a',
    'a',
    'a',
    'a',
    'a',
    'a',
    'a',
    'a',
    'a',
    'w',
    'w',
    'w',
    'd',
    'd',
    'd',
    'd',
  ];

  /// CLI usage summary printed on `--help`.
  static const String usage = '''
Usage: dart run tool/sizzle.dart [options]

Coordinates fterm's loopback HTTP Automation Driver (v1) and OBS WebSocket v5
to capture a repeatable 1920x1080 sizzle reel.

Connection & Auth:
  --launch-fterm             Spawn fterm with --automation-driver --automation-allow-pty
  --fterm-bin <path>         Explicit fterm executable path (implies --launch-fterm)
  --keep-fterm               Leave a spawned fterm process running after exit
  --host <host>              fterm host (127.0.0.1 or localhost; default 127.0.0.1)
  --port <port>              fterm automation port (default: settings.json or 9911)
  --token <token>            Bearer token (prefer FTERM_AUTOMATION_TOKEN or settings.json)
  --no-obs                   Rehearse fterm choreography without connecting to OBS
  --obs-url <ws-url>         OBS WebSocket v5 URI (default: ws://127.0.0.1:4455)
  --obs-password <secret>    OBS password (prefer OBS_WEBSOCKET_PASSWORD env var)
  --obs-overlay-input <name> Optional OBS Text source name for lower-third badges
  --obs-overlay-scene <name> Optional OBS Scene name for toggling overlay visibility

Recording & Stage:
  --mode <master|takes>      Single file with chapters, or per-Act clips (default: master)
  --acts <1,2,3,4>           Comma-separated Acts to shoot (default: 1,2,3,4)
  --out-dir <dir>            Destination directory for renamed clips (default: build/promo_takes)
  --master-name <stem>       Filename stem in master mode (default: fterm_v070_master)
  --stage-width <px>         Full stage physical width (default: 1920)
  --stage-height <px>        Full stage physical height (default: 1080)
  --split-width <px>         Act 3 left-half physical width (default: 960)
  --font-size <pt>           Terminal font size during capture (default: 18)
  --no-restore               Keep capture bounds/UI/shaders after script exits

Scene & Demo Customization:
  --dev-cwd <dir>            Tab 1 working directory (default: current directory)
  --dev-title <title>        Tab 1 pinned title (default: flutter_gpu)
  --dev-command <cmd>        Tab 1 pre-roll command (default: git show --stat)
  --dev-wait <regex>         Tab 1 post-command screen regex (default: files? changed)
  --fx-cwd <dir>             Tab 2 working directory (default: current directory)
  --fx-title <title>         Tab 2 pinned title (default: roguetui_fx)
  --fx-command <cmd>         Optional Tab 2 pre-roll command (e.g. termui_cast ...)
  --fx-wait <regex>          Tab 2 post-command screen regex (default: HP|Dungeon|roguetui)
  --fx-trigger-key <text>    Optional key sequence written to Tab 2 in Act 2
  --fx-button <label>        TUI button label clicked via /v1/screen/find (default: [ Cast ])
  --act3-keys <csv>          Comma-separated keys sent during Act 3 split view
  --shader-preset <name>     Act 1 built-in preset (default: wallpaper_wave)
  --shader-path <path>       Act 1 custom .glsl file path (overrides --shader-preset)
  --fg-presets <csv>         Foreground presets after Act 1 (default: scanline_overlay,phosphor_glow)
  --patch-prefix <text>      Anchored prefix for Act 1 live edit (default: "uParams0.x : ")
  --patch-old <text>         Initial value replaced in Act 1 (default: 0.35)
  --patch-new <text>         New value typed character-by-character (default: 1.85)
  -h, --help                 Show this help message
''';
}

/// Reads persisted `fterm.automation.v1` `{port, password}` from desktop
/// `settings.json`, returning `null` if unavailable or malformed.
PersistedFtermDriverConfig? readPersistedFtermDriverConfig({
  Map<String, String>? environment,
  bool? isWindows,
}) {
  final settingsPath = _resolveDesktopSettingsPath(
    environment: environment ?? Platform.environment,
    isWindows: isWindows ?? Platform.isWindows,
  );
  if (settingsPath == null) return null;
  final file = File(settingsPath);
  if (!file.existsSync()) return null;
  try {
    final Object? decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<Object?, Object?>) return null;
    final Object? rawEntry = decoded['fterm.automation.v1'];
    final Map<Object?, Object?>? configMap = switch (rawEntry) {
      final String rawJson => _tryDecodeMap(rawJson),
      final Map<Object?, Object?> map => map,
      _ => null,
    };
    if (configMap == null) return null;
    final port = configMap['port'];
    final password = configMap['password'];
    if (port is! num || password is! String || password.trim().isEmpty) {
      return null;
    }
    final intPort = port.toInt();
    if (intPort < 1 || intPort > 65535) return null;
    return PersistedFtermDriverConfig(port: intPort, password: password.trim());
  } on Object {
    return null;
  }
}

/// Stateless loopback HTTP client for `fterm`'s `v1` Automation Driver API.
final class FtermDriverClient {
  /// Base URI (`http://127.0.0.1:<port>`).
  final Uri baseUri;

  /// Bearer authentication token.
  final String token;

  final HttpClient _httpClient;
  final bool _ownsHttpClient;
  final SizzleSleep _sleep;
  final math.Random _random;

  /// Creates an [FtermDriverClient].
  FtermDriverClient({
    required this.baseUri,
    required this.token,
    HttpClient? httpClient,
    SizzleSleep? sleep,
    math.Random? random,
  }) : _httpClient = httpClient ?? HttpClient(),
       _ownsHttpClient = httpClient == null,
       _sleep = sleep ?? Future<void>.delayed,
       _random = random ?? math.Random();

  /// Sends an authenticated `GET` request to [path] and returns `result`.
  Future<Map<String, Object?>> get(
    String path, {
    Map<String, String>? queryParameters,
  }) async {
    final uri = baseUri.replace(path: path, queryParameters: queryParameters);
    final request = await _httpClient.getUrl(uri);
    _applyCommonHeaders(request);
    final response = await request.close();
    return _decodeEnvelope(response);
  }

  /// Sends an authenticated `POST` JSON request to [path] and returns `result`.
  Future<Map<String, Object?>> post(
    String path,
    Map<String, Object?> body,
  ) async {
    final uri = baseUri.replace(path: path);
    final request = await _httpClient.postUrl(uri);
    _applyCommonHeaders(request);
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close();
    return _decodeEnvelope(response);
  }

  /// Types [command] into [paneId] at a human cadence with optional jitter,
  /// optionally finishing with `\r`.
  Future<void> typeHuman(
    String paneId,
    String command, {
    int delayMs = 38,
    int minJitterMs = -10,
    int maxJitterMs = 15,
    bool enter = true,
  }) async {
    final span = math.max(1, maxJitterMs - minJitterMs + 1);
    for (final rune in command.runes) {
      await post('/v1/pty/write', <String, Object?>{
        'paneId': paneId,
        'text': String.fromCharCode(rune),
      });
      final jitter = minJitterMs + _random.nextInt(span);
      final waitMs = math.max(1, delayMs + jitter);
      await _sleep(Duration(milliseconds: waitMs));
    }
    if (enter) {
      await post('/v1/pty/write', <String, Object?>{
        'paneId': paneId,
        'text': '\r',
      });
    }
  }

  /// Polls `POST /v1/screen/find` with [regex] until a match appears on
  /// [paneId] or [timeout] expires.
  ///
  /// When [timeout] expires, fetches `GET /v1/screen` and includes the visible
  /// non-empty lines in the [TimeoutException] message for diagnostics.
  Future<Map<String, Object?>> waitForScreen(
    String paneId,
    String regex, {
    Duration timeout = const Duration(seconds: 12),
    Duration pollInterval = const Duration(milliseconds: 80),
  }) async {
    final stopwatch = Stopwatch()..start();
    while (true) {
      final result = await post('/v1/screen/find', <String, Object?>{
        'paneId': paneId,
        'regex': regex,
      });
      final matches = result['matches'];
      if (matches is List<Object?> && matches.isNotEmpty) {
        final first = matches.first;
        if (first is Map<Object?, Object?>) {
          return _asStringMap(first);
        }
      }
      if (stopwatch.elapsed >= timeout) {
        final screenDump = await _formatScreenDiagnostics(paneId);
        throw TimeoutException(
          'Pattern "$regex" did not appear on pane "$paneId" within '
          '${timeout.inMilliseconds}ms.\n$screenDump',
        );
      }
      await _sleep(pollInterval);
    }
  }

  Future<String> _formatScreenDiagnostics(String paneId) async {
    try {
      final screen = await get(
        '/v1/screen',
        queryParameters: <String, String>{'paneId': paneId},
      );
      final cols = screen['cols'];
      final rows = screen['rows'];
      final cursor = screen['cursor'];
      final linesRaw = screen['lines'];
      final lines = linesRaw is List<Object?>
          ? linesRaw.whereType<String>().toList()
          : const <String>[];
      final nonEmpty = <String>[
        for (var i = 0; i < lines.length; i++)
          if (lines[i].trimRight().isNotEmpty)
            '  [${i.toString().padLeft(2, '0')}] ${lines[i].trimRight()}',
      ];
      final body = nonEmpty.isEmpty
          ? '  (screen is blank — shell may still be starting)'
          : nonEmpty.join('\n');
      return 'Visible screen on "$paneId" (${cols}x$rows, cursor: $cursor):\n'
          '$body';
    } on Object catch (error) {
      return 'Could not fetch /v1/screen for "$paneId": $error';
    }
  }

  /// Animates a GLSL constant edit character-by-character via anchored
  /// `find`/`replace`, suppressing compilation until the final character so
  /// intermediate floats do not trigger `422 shader_compile_error`.
  Future<Map<String, Object?>> livePatchConstant({
    required String prefix,
    required String oldVal,
    required String newVal,
    Duration keystrokeDelay = const Duration(milliseconds: 65),
  }) async {
    if (newVal.isEmpty) {
      throw ArgumentError.value(newVal, 'newVal', 'must not be empty');
    }
    var current = '$prefix$oldVal';
    Map<String, Object?> lastResult = const <String, Object?>{};
    for (var i = 1; i <= newVal.length; i++) {
      final next = '$prefix${newVal.substring(0, i)}';
      final isFinalChar = i == newVal.length;
      lastResult = await post('/v1/shader/editor', <String, Object?>{
        'open': false,
        'find': current,
        'replace': next,
        'awaitCompile': isFinalChar,
      });
      current = next;
      if (!isFinalChar && keystrokeDelay > Duration.zero) {
        await _sleep(keystrokeDelay);
      }
    }
    return lastResult;
  }

  /// Drives a smooth Lissajous `iMouse` sweep across [paneId] via
  /// `/v1/input/pointer` without moving the OS cursor, always clearing pointer
  /// state on exit.
  Future<void> sweepShaderPointer(
    String paneId, {
    Duration duration = const Duration(milliseconds: 2400),
    Duration stepInterval = const Duration(milliseconds: 16),
    int? fixedSteps,
  }) async {
    try {
      if (fixedSteps != null) {
        await _sweepFixedSteps(paneId, fixedSteps, stepInterval);
        return;
      }
      final stopwatch = Stopwatch()..start();
      while (stopwatch.elapsed < duration) {
        final t = stopwatch.elapsedMilliseconds / 1000.0;
        await _sendLissajousStep(paneId, t);
        await _sleep(stepInterval);
      }
    } finally {
      await post('/v1/input/pointer', <String, Object?>{
        'paneId': paneId,
        'clear': true,
      });
    }
  }

  Future<void> _sweepFixedSteps(
    String paneId,
    int steps,
    Duration stepInterval,
  ) async {
    final stepSeconds = stepInterval.inMilliseconds / 1000.0;
    for (var i = 0; i < steps; i++) {
      await _sendLissajousStep(paneId, i * stepSeconds);
      await _sleep(stepInterval);
    }
  }

  Future<void> _sendLissajousStep(String paneId, double tSeconds) {
    final x = (0.5 + 0.35 * math.sin(tSeconds * 2.2)).clamp(0.0, 1.0);
    final y = (0.5 + 0.30 * math.sin(tSeconds * 4.4)).clamp(0.0, 1.0);
    return post('/v1/input/pointer', <String, Object?>{
      'paneId': paneId,
      'x': x,
      'y': y,
      'pressed': false,
    });
  }

  /// Closes the underlying [HttpClient] if owned by this instance.
  void close() {
    if (_ownsHttpClient) {
      _httpClient.close(force: true);
    }
  }

  void _applyCommonHeaders(HttpClientRequest request) {
    request.headers.set(
      HttpHeaders.hostHeader,
      '${baseUri.host}:${baseUri.port}',
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }

  Future<Map<String, Object?>> _decodeEnvelope(
    HttpClientResponse response,
  ) async {
    final raw = await utf8.decoder.bind(response).join();
    final Object? decoded = raw.isEmpty ? null : jsonDecode(raw);
    if (decoded is! Map<Object?, Object?>) {
      throw FtermDriverException(
        statusCode: response.statusCode,
        code: 'invalid_response',
        message: 'Expected JSON object response, got: $raw',
      );
    }
    final map = _asStringMap(decoded);
    if (response.statusCode == 200 && map['ok'] == true) {
      final result = map['result'];
      if (result is Map<Object?, Object?>) {
        return _asStringMap(result);
      }
      return const <String, Object?>{};
    }
    final error = map['error'];
    if (error is Map<Object?, Object?>) {
      final errMap = _asStringMap(error);
      final details = errMap['details'];
      throw FtermDriverException(
        statusCode: response.statusCode,
        code: '${errMap['code'] ?? 'unknown_error'}',
        message: '${errMap['message'] ?? 'Request failed.'}',
        details: details is Map<Object?, Object?>
            ? _asStringMap(details)
            : null,
      );
    }
    throw FtermDriverException(
      statusCode: response.statusCode,
      code: 'http_error',
      message: raw,
    );
  }
}

/// Abstract OBS capture controller shared by live [ObsWebSocketClient] and
/// rehearsal [NoopObsController].
abstract interface class ObsController {
  /// Ensures [sceneName] contains a Windows Graphics Capture `window_capture`
  /// input ([inputName]) locked strictly to [windowTitle], fits it onto the
  /// [stageWidth]x[stageHeight] canvas, and selects [sceneName] as Program.
  Future<void> ensureWindowCaptureScene({
    required String sceneName,
    required String inputName,
    required String windowTitle,
    required int stageWidth,
    required int stageHeight,
  });

  /// Ensures an OBS `ffmpeg_source` audio input ([inputName]) exists in
  /// [sceneName] pointing at [filePath], configured for recording output only
  /// (no desktop monitor echo) and initially stopped.
  Future<void> ensureIntroAudioSource({
    required String sceneName,
    required String inputName,
    required String filePath,
  });

  /// Restarts the prepared intro audio bed at full configured volume.
  Future<void> startIntroAudioBed();

  /// Smoothly fades out and stops the intro audio bed over [duration].
  Future<void> fadeOutIntroAudioBed({
    Duration duration = const Duration(milliseconds: 800),
  });

  /// Immediately stops the intro audio bed if active.
  Future<void> stopIntroAudioBed();

  /// Starts OBS recording and waits until `OBS_WEBSOCKET_OUTPUT_STARTED`.
  Future<void> startRecord();

  /// Stops OBS recording, waits until `OBS_WEBSOCKET_OUTPUT_STOPPED`, and
  /// returns the written file path when reported by OBS.
  Future<String?> stopRecord();

  /// Pauses active recording.
  Future<void> pauseRecord();

  /// Resumes a paused recording.
  Future<void> resumeRecord();

  /// Inserts a chapter marker into the active recording (OBS 30.2+).
  Future<void> createRecordChapter(String chapterName);

  /// Updates an optional lower-third text overlay source and reveals it.
  Future<void> setOverlayBadge(String text);

  /// Clears and hides the optional lower-third text overlay source.
  Future<void> clearOverlayBadge();

  /// Closes any open OBS WebSocket connection.
  Future<void> close();
}

/// Rehearsal implementation of [ObsController] used when `--no-obs` is active.
final class NoopObsController implements ObsController {
  final void Function(String line)? _log;

  /// Creates a [NoopObsController].
  const NoopObsController({this._log});

  void _emit(String line) {
    if (_log case final logFn?) {
      logFn(line);
    } else {
      stdout.writeln(line);
    }
  }

  @override
  Future<void> ensureWindowCaptureScene({
    required String sceneName,
    required String inputName,
    required String windowTitle,
    required int stageWidth,
    required int stageHeight,
  }) async => _emit(
    '[obs:noop] EnsureScene("$sceneName", input="$inputName", '
    'windowTitle="$windowTitle", ${stageWidth}x$stageHeight)',
  );

  @override
  Future<void> ensureIntroAudioSource({
    required String sceneName,
    required String inputName,
    required String filePath,
  }) async => _emit(
    '[obs:noop] EnsureIntroAudio("$sceneName", input="$inputName", file="$filePath")',
  );

  @override
  Future<void> startIntroAudioBed() async =>
      _emit('[obs:noop] StartIntroAudioBed');

  @override
  Future<void> fadeOutIntroAudioBed({
    Duration duration = const Duration(milliseconds: 800),
  }) async =>
      _emit('[obs:noop] FadeOutIntroAudioBed(${duration.inMilliseconds}ms)');

  @override
  Future<void> stopIntroAudioBed() async =>
      _emit('[obs:noop] StopIntroAudioBed');

  @override
  Future<void> startRecord() async => _emit('[obs:noop] StartRecord');

  @override
  Future<String?> stopRecord() async {
    _emit('[obs:noop] StopRecord');
    return null;
  }

  @override
  Future<void> pauseRecord() async => _emit('[obs:noop] PauseRecord');

  @override
  Future<void> resumeRecord() async => _emit('[obs:noop] ResumeRecord');

  @override
  Future<void> createRecordChapter(String chapterName) async =>
      _emit('[obs:noop] CreateRecordChapter("$chapterName")');

  @override
  Future<void> setOverlayBadge(String text) async =>
      _emit('[obs:noop] OverlayBadge("$text")');

  @override
  Future<void> clearOverlayBadge() async =>
      _emit('[obs:noop] ClearOverlayBadge');

  @override
  Future<void> close() async {}
}

/// Minimal zero-extra-dependency OBS WebSocket v5 client built on `dart:io`
/// [WebSocket] and `package:crypto`.
final class ObsWebSocketClient implements ObsController {
  static const int _opHello = 0;
  static const int _opIdentify = 1;
  static const int _opIdentified = 2;
  static const int _opEvent = 5;
  static const int _opRequest = 6;
  static const int _opRequestResponse = 7;

  /// `Outputs` event bitmask (`1 << 6`) required for `RecordStateChanged`.
  static const int _outputsEventSubscription = 1 << 6;

  final WebSocket _socket;
  final String? _overlayInput;
  final String? _overlayScene;
  final Duration _requestTimeout;
  final void Function(String line) _log;

  final Map<String, Completer<Map<String, Object?>>> _pendingRequests =
      <String, Completer<Map<String, Object?>>>{};
  final List<_RecordStateWaiter> _recordWaiters = <_RecordStateWaiter>[];
  StreamSubscription<Object?>? _subscription;
  int _nextRequestId = 0;
  bool _closed = false;
  String? _introAudioInput;
  bool _introAudioPlaying = false;

  ObsWebSocketClient._(
    this._socket, {
    this._overlayInput,
    this._overlayScene,
    required this._requestTimeout,
    required this._log,
  });

  /// Connects and completes the OBS WebSocket v5 `Hello` / `Identify` /
  /// `Identified` handshake.
  static Future<ObsWebSocketClient> connect(
    Uri uri, {
    String? password,
    String? overlayInput,
    String? overlayScene,
    Duration requestTimeout = const Duration(seconds: 10),
    void Function(String line)? log,
  }) async {
    final socket = await WebSocket.connect(uri.toString());
    final client = ObsWebSocketClient._(
      socket,
      overlayInput: overlayInput,
      overlayScene: overlayScene,
      requestTimeout: requestTimeout,
      log: log ?? stdout.writeln,
    );
    await client._handshake(password: password);
    return client;
  }

  /// Computes the OBS WebSocket v5 SHA-256 authentication string from
  /// [password], [salt], and [challenge].
  static String computeAuthString({
    required String password,
    required String salt,
    required String challenge,
  }) {
    final secretHash = base64Encode(
      sha256.convert(utf8.encode('$password$salt')).bytes,
    );
    return base64Encode(
      sha256.convert(utf8.encode('$secretHash$challenge')).bytes,
    );
  }

  /// Sends a raw OBS WebSocket v5 request (`op: 6`) and returns `responseData`.
  Future<Map<String, Object?>> call(
    String requestType, [
    Map<String, Object?>? requestData,
  ]) async {
    if (_closed) {
      throw const ObsWebSocketException(
        code: -1,
        message: 'OBS WebSocket connection is closed.',
      );
    }
    final requestId = 'sizzle-${++_nextRequestId}';
    final completer = Completer<Map<String, Object?>>();
    _pendingRequests[requestId] = completer;
    _send(<String, Object?>{
      'op': _opRequest,
      'd': <String, Object?>{
        'requestType': requestType,
        'requestId': requestId,
        'requestData': ?requestData,
      },
    });
    try {
      return await completer.future.timeout(_requestTimeout);
    } finally {
      _pendingRequests.remove(requestId);
    }
  }

  @override
  Future<void> startRecord() async {
    final started = _expectRecordState('OBS_WEBSOCKET_OUTPUT_STARTED');
    await call('StartRecord');
    await started.timeout(_requestTimeout);
  }

  @override
  Future<String?> stopRecord() async {
    final stopped = _expectRecordState('OBS_WEBSOCKET_OUTPUT_STOPPED');
    final response = await call('StopRecord');
    final eventData = await stopped.timeout(_requestTimeout);
    final fromResponse = response['outputPath'];
    if (fromResponse is String && fromResponse.isNotEmpty) {
      return fromResponse;
    }
    final fromEvent = eventData['outputPath'];
    return fromEvent is String && fromEvent.isNotEmpty ? fromEvent : null;
  }

  @override
  Future<void> ensureWindowCaptureScene({
    required String sceneName,
    required String inputName,
    required String windowTitle,
    required int stageWidth,
    required int stageHeight,
  }) async {
    await _ensureSceneExists(sceneName);
    final sceneItemId = await _ensureWindowCaptureInput(
      sceneName: sceneName,
      inputName: inputName,
      windowTitle: windowTitle,
    );
    final windowTarget = await _resolveObsWindowTarget(
      inputName: inputName,
      windowTitle: windowTitle,
    );
    await call('SetInputSettings', <String, Object?>{
      'inputName': inputName,
      'inputSettings': <String, Object?>{
        'window': windowTarget,
        'method': 2, // Modern Windows Graphics Capture (WGC)
        'priority': 1, // Window title must match
        'cursor': true,
        'client_area': false,
      },
      'overlay': true,
    });
    if (sceneItemId != null) {
      await call('SetSceneItemTransform', <String, Object?>{
        'sceneName': sceneName,
        'sceneItemId': sceneItemId,
        'sceneItemTransform': <String, Object?>{
          'positionX': 0.0,
          'positionY': 0.0,
          'alignment': 5, // Top-left
          'boundsType': 'OBS_BOUNDS_SCALE_INNER',
          'boundsAlignment': 0, // Center within stage bounds
          'boundsWidth': stageWidth.toDouble(),
          'boundsHeight': stageHeight.toDouble(),
        },
      });
    }
    if (_overlayInput case final badgeInput? when badgeInput.isNotEmpty) {
      await _ensureOverlayBadgeInput(
        sceneName: _overlayScene ?? sceneName,
        inputName: badgeInput,
        stageWidth: stageWidth,
        stageHeight: stageHeight,
      );
    }
    await call('SetCurrentProgramScene', <String, Object?>{
      'sceneName': sceneName,
    });
    _log(
      '[obs] Scene "$sceneName" capturing "$windowTarget" '
      '(priority=title-exact, WGC)',
    );
  }

  Future<void> _ensureOverlayBadgeInput({
    required String sceneName,
    required String inputName,
    required int stageWidth,
    required int stageHeight,
  }) async {
    int? sceneItemId;
    try {
      final existing = await call('GetSceneItemId', <String, Object?>{
        'sceneName': sceneName,
        'sourceName': inputName,
      });
      if (existing['sceneItemId'] case final num id) {
        sceneItemId = id.toInt();
      }
    } on ObsWebSocketException {
      // Not yet in this scene.
    }

    final badgeStyleSettings = <String, Object?>{
      'text': '',
      'font': const <String, Object?>{
        'face': 'Segoe UI',
        'size': 55,
        'flags': 1, // Bold
      },
      'color': 0xFFFFFF,
      'opacity': 100,
      'align': 'right',
      'valign': 'bottom',
      'antialiasing': true,
      'bk_color': 0x18120E, // Dark slate pill (BGR)
      'bk_opacity': 72,
      'outline': true,
      'outline_color': 0x000000,
      'outline_opacity': 85,
      'outline_size': 2,
    };

    if (sceneItemId == null) {
      var inputExists = false;
      try {
        final inputs = await call('GetInputList', const <String, Object?>{
          'inputKind': 'text_gdiplus_v3',
        });
        if (inputs['inputs'] case final List<Object?> list) {
          for (final entry in list) {
            if (entry is Map<Object?, Object?> &&
                entry['inputName'] == inputName) {
              inputExists = true;
              break;
            }
          }
        }
      } on ObsWebSocketException {
        // Ignore and attempt CreateInput directly.
      }
      if (inputExists) {
        final attached = await call('CreateSceneItem', <String, Object?>{
          'sceneName': sceneName,
          'sourceName': inputName,
          'sceneItemEnabled': false,
        });
        if (attached['sceneItemId'] case final num id) {
          sceneItemId = id.toInt();
        }
      } else {
        final created = await call('CreateInput', <String, Object?>{
          'sceneName': sceneName,
          'inputName': inputName,
          'inputKind': 'text_gdiplus_v3',
          'inputSettings': badgeStyleSettings,
          'sceneItemEnabled': false,
        });
        if (created['sceneItemId'] case final num id) {
          sceneItemId = id.toInt();
        }
      }
    }

    await call('SetInputSettings', <String, Object?>{
      'inputName': inputName,
      'inputSettings': badgeStyleSettings,
      'overlay': true,
    });

    if (sceneItemId != null) {
      await call('SetSceneItemTransform', <String, Object?>{
        'sceneName': sceneName,
        'sceneItemId': sceneItemId,
        'sceneItemTransform': <String, Object?>{
          'positionX': (stageWidth - 40).toDouble(),
          'positionY': (stageHeight - 36).toDouble(),
          'alignment': 10, // Bottom-right (OBS_ALIGN_RIGHT | OBS_ALIGN_BOTTOM)
          'boundsType': 'OBS_BOUNDS_NONE',
        },
      });
      await call('SetSceneItemEnabled', <String, Object?>{
        'sceneName': sceneName,
        'sceneItemId': sceneItemId,
        'sceneItemEnabled': false,
      });
    }
  }

  @override
  Future<void> ensureIntroAudioSource({
    required String sceneName,
    required String inputName,
    required String filePath,
  }) async {
    _introAudioInput = inputName;
    final mediaSettings = <String, Object?>{
      'local_file': filePath,
      'is_local_file': true,
      'looping': true,
      'restart_on_activate': false,
      'close_when_inactive': false,
    };

    var attachedToScene = false;
    try {
      await call('GetSceneItemId', <String, Object?>{
        'sceneName': sceneName,
        'sourceName': inputName,
      });
      attachedToScene = true;
    } on ObsWebSocketException {
      // Not yet in scene.
    }

    if (!attachedToScene) {
      var inputExists = false;
      try {
        final inputs = await call('GetInputList', const <String, Object?>{
          'inputKind': 'ffmpeg_source',
        });
        if (inputs['inputs'] case final List<Object?> list) {
          for (final entry in list) {
            if (entry is Map<Object?, Object?> &&
                entry['inputName'] == inputName) {
              inputExists = true;
              break;
            }
          }
        }
      } on ObsWebSocketException {
        // Attempt CreateInput directly below.
      }
      if (inputExists) {
        await call('CreateSceneItem', <String, Object?>{
          'sceneName': sceneName,
          'sourceName': inputName,
          'sceneItemEnabled': true,
        });
      } else {
        await call('CreateInput', <String, Object?>{
          'sceneName': sceneName,
          'inputName': inputName,
          'inputKind': 'ffmpeg_source',
          'inputSettings': mediaSettings,
          'sceneItemEnabled': true,
        });
      }
    }

    await call('SetInputSettings', <String, Object?>{
      'inputName': inputName,
      'inputSettings': mediaSettings,
      'overlay': true,
    });
    // Record straight to Track 1 without desktop monitor echo into WASAPI.
    await call('SetInputAudioMonitorType', <String, Object?>{
      'inputName': inputName,
      'monitorType': 'OBS_MONITORING_TYPE_NONE',
    });
    await call('SetInputMute', <String, Object?>{
      'inputName': inputName,
      'inputMuted': false,
    });
    await call('SetInputVolume', <String, Object?>{
      'inputName': inputName,
      'inputVolumeMul': 1.0,
    });
    await call('SetInputAudioTracks', <String, Object?>{
      'inputName': inputName,
      'inputAudioTracks': const <String, Object?>{'1': true},
    });
    await call('TriggerMediaInputAction', <String, Object?>{
      'inputName': inputName,
      'mediaAction': 'OBS_WEBSOCKET_MEDIA_INPUT_ACTION_STOP',
    });
    _introAudioPlaying = false;
    _log('[obs] Intro audio bed "$inputName" armed ($filePath)');
  }

  @override
  Future<void> startIntroAudioBed() async {
    final inputName = _introAudioInput;
    if (inputName == null || inputName.isEmpty) return;
    await call('SetInputVolume', <String, Object?>{
      'inputName': inputName,
      'inputVolumeMul': 1.0,
    });
    await call('TriggerMediaInputAction', <String, Object?>{
      'inputName': inputName,
      'mediaAction': 'OBS_WEBSOCKET_MEDIA_INPUT_ACTION_RESTART',
    });
    _introAudioPlaying = true;
  }

  @override
  Future<void> fadeOutIntroAudioBed({
    Duration duration = const Duration(milliseconds: 800),
  }) async {
    final inputName = _introAudioInput;
    if (!_introAudioPlaying || inputName == null || inputName.isEmpty) return;
    const steps = 12;
    final stepMs = math.max(15, duration.inMilliseconds ~/ steps);
    for (var i = steps - 1; i >= 0; i--) {
      final level = (i / steps) * (i / steps);
      await call('SetInputVolume', <String, Object?>{
        'inputName': inputName,
        'inputVolumeMul': level,
      });
      if (i > 0) {
        await Future<void>.delayed(Duration(milliseconds: stepMs));
      }
    }
    await stopIntroAudioBed();
  }

  @override
  Future<void> stopIntroAudioBed() async {
    final inputName = _introAudioInput;
    if (inputName == null || inputName.isEmpty) return;
    _introAudioPlaying = false;
    try {
      await call('TriggerMediaInputAction', <String, Object?>{
        'inputName': inputName,
        'mediaAction': 'OBS_WEBSOCKET_MEDIA_INPUT_ACTION_STOP',
      });
    } on ObsWebSocketException {
      // Best-effort cleanup.
    }
  }

  Future<void> _ensureSceneExists(String sceneName) async {
    final list = await call('GetSceneList');
    final scenes = list['scenes'];
    if (scenes is List<Object?>) {
      for (final entry in scenes) {
        if (entry is Map<Object?, Object?> && entry['sceneName'] == sceneName) {
          return;
        }
      }
    }
    await call('CreateScene', <String, Object?>{'sceneName': sceneName});
  }

  Future<int?> _ensureWindowCaptureInput({
    required String sceneName,
    required String inputName,
    required String windowTitle,
  }) async {
    try {
      final existing = await call('GetSceneItemId', <String, Object?>{
        'sceneName': sceneName,
        'sourceName': inputName,
      });
      if (existing['sceneItemId'] case final num id) {
        return id.toInt();
      }
    } on ObsWebSocketException {
      // Not yet in this scene; check whether the input exists globally.
    }

    final inputs = await call('GetInputList', const <String, Object?>{
      'inputKind': 'window_capture',
    });
    var inputExists = false;
    if (inputs['inputs'] case final List<Object?> list) {
      for (final entry in list) {
        if (entry is Map<Object?, Object?> && entry['inputName'] == inputName) {
          inputExists = true;
          break;
        }
      }
    }

    if (inputExists) {
      final attached = await call('CreateSceneItem', <String, Object?>{
        'sceneName': sceneName,
        'sourceName': inputName,
        'sceneItemEnabled': true,
      });
      final id = attached['sceneItemId'];
      return id is num ? id.toInt() : null;
    }

    final created = await call('CreateInput', <String, Object?>{
      'sceneName': sceneName,
      'inputName': inputName,
      'inputKind': 'window_capture',
      'inputSettings': <String, Object?>{
        'window': '$windowTitle:FLUTTER_RUNNER_WIN32_WINDOW:fterm.exe',
        'method': 2,
        'priority': 1,
        'cursor': true,
        'client_area': false,
      },
      'sceneItemEnabled': true,
    });
    final id = created['sceneItemId'];
    return id is num ? id.toInt() : null;
  }

  Future<String> _resolveObsWindowTarget({
    required String inputName,
    required String windowTitle,
  }) async {
    final fallback = '$windowTitle:FLUTTER_RUNNER_WIN32_WINDOW:fterm.exe';
    try {
      final props = await call(
        'GetInputPropertiesListPropertyItems',
        <String, Object?>{'inputName': inputName, 'propertyName': 'window'},
      );
      final items = props['propertyItems'];
      if (items is List<Object?>) {
        final expectedPrefix = '${windowTitle.toLowerCase()}:';
        for (final entry in items) {
          if (entry is! Map<Object?, Object?>) continue;
          final rawVal = entry['itemValue'];
          if (rawVal is String &&
              rawVal.toLowerCase().startsWith(expectedPrefix)) {
            return rawVal;
          }
        }
      }
    } on ObsWebSocketException {
      // Fall back to canonical Win32 Flutter runner window identifier.
    }
    return fallback;
  }

  @override
  Future<void> pauseRecord() async {
    await call('PauseRecord');
  }

  @override
  Future<void> resumeRecord() async {
    await call('ResumeRecord');
  }

  @override
  Future<void> createRecordChapter(String chapterName) async {
    try {
      await call('CreateRecordChapter', <String, Object?>{
        'chapterName': chapterName,
      });
    } on ObsWebSocketException catch (error) {
      // OBS < 30.2 or non-chapter containers reject CreateRecordChapter.
      _log('[obs] CreateRecordChapter skipped: $error');
    }
  }

  @override
  Future<void> setOverlayBadge(String text) async {
    final input = _overlayInput;
    if (input == null || input.isEmpty) return;
    final padded = text.split('\n').map((line) => ' $line ').join('\n');
    await call('SetInputSettings', <String, Object?>{
      'inputName': input,
      'inputSettings': <String, Object?>{'text': padded},
      'overlay': true,
    });
    await _setOverlayItemEnabled(true);
  }

  @override
  Future<void> clearOverlayBadge() async {
    final input = _overlayInput;
    if (input == null || input.isEmpty) return;
    await _setOverlayItemEnabled(false);
    await call('SetInputSettings', <String, Object?>{
      'inputName': input,
      'inputSettings': <String, Object?>{'text': ''},
      'overlay': true,
    });
  }

  Future<void> _setOverlayItemEnabled(bool enabled) async {
    final scene = _overlayScene;
    final input = _overlayInput;
    if (scene == null || scene.isEmpty || input == null || input.isEmpty) {
      return;
    }
    final item = await call('GetSceneItemId', <String, Object?>{
      'sceneName': scene,
      'sourceName': input,
    });
    final sceneItemId = item['sceneItemId'];
    if (sceneItemId is! num) return;
    await call('SetSceneItemEnabled', <String, Object?>{
      'sceneName': scene,
      'sceneItemId': sceneItemId.toInt(),
      'sceneItemEnabled': enabled,
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    await _socket.close();
    _failPending(
      const ObsWebSocketException(
        code: -1,
        message: 'OBS WebSocket closed before response arrived.',
      ),
    );
  }

  Future<void> _handshake({String? password}) async {
    final identified = Completer<void>();
    _subscription = _socket.listen(
      (raw) => _handleFrame(
        raw,
        password: password,
        identifiedCompleter: identified,
      ),
      onError: (Object error) {
        final wrapped = ObsWebSocketException(code: -1, message: '$error');
        if (!identified.isCompleted) identified.completeError(wrapped);
        _failPending(wrapped);
      },
      onDone: () {
        const closedErr = ObsWebSocketException(
          code: -1,
          message: 'OBS WebSocket disconnected.',
        );
        if (!identified.isCompleted) identified.completeError(closedErr);
        _failPending(closedErr);
      },
    );
    await identified.future.timeout(_requestTimeout);
  }

  void _handleFrame(
    Object? raw, {
    required String? password,
    required Completer<void> identifiedCompleter,
  }) {
    if (raw is! String) return;
    final decoded = _tryDecodeMap(raw);
    if (decoded == null) return;
    final op = decoded['op'];
    final data = decoded['d'];
    if (op is! num || data is! Map<Object?, Object?>) return;
    final payload = _asStringMap(data);
    switch (op.toInt()) {
      case _opHello:
        _handleHello(payload, password: password);
      case _opIdentified:
        if (!identifiedCompleter.isCompleted) identifiedCompleter.complete();
      case _opEvent:
        _handleEvent(payload);
      case _opRequestResponse:
        _handleRequestResponse(payload);
    }
  }

  void _handleHello(Map<String, Object?> hello, {String? password}) {
    final authObj = hello['authentication'];
    String? authReply;
    if (authObj is Map<Object?, Object?>) {
      final salt = authObj['salt'];
      final challenge = authObj['challenge'];
      if (salt is String && challenge is String) {
        authReply = computeAuthString(
          password: password ?? '',
          salt: salt,
          challenge: challenge,
        );
      }
    }
    _send(<String, Object?>{
      'op': _opIdentify,
      'd': <String, Object?>{
        'rpcVersion': 1,
        'eventSubscriptions': _outputsEventSubscription,
        'authentication': ?authReply,
      },
    });
  }

  void _handleEvent(Map<String, Object?> event) {
    if (event['eventType'] != 'RecordStateChanged') return;
    final eventData = event['eventData'];
    if (eventData is! Map<Object?, Object?>) return;
    final map = _asStringMap(eventData);
    final outputState = map['outputState'];
    if (outputState is! String) return;
    for (var i = _recordWaiters.length - 1; i >= 0; i--) {
      final waiter = _recordWaiters[i];
      if (waiter.expectedState == outputState) {
        _recordWaiters.removeAt(i);
        if (!waiter.completer.isCompleted) {
          waiter.completer.complete(map);
        }
      }
    }
  }

  void _handleRequestResponse(Map<String, Object?> response) {
    final requestId = response['requestId'];
    if (requestId is! String) return;
    final completer = _pendingRequests.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    final statusObj = response['requestStatus'];
    final status = statusObj is Map<Object?, Object?>
        ? _asStringMap(statusObj)
        : const <String, Object?>{};
    if (status['result'] == true) {
      final data = response['responseData'];
      completer.complete(
        data is Map<Object?, Object?>
            ? _asStringMap(data)
            : const <String, Object?>{},
      );
      return;
    }
    final code = status['code'] is num ? (status['code']! as num).toInt() : -1;
    final comment = '${status['comment'] ?? 'OBS request failed.'}';
    completer.completeError(
      ObsWebSocketException(code: code, message: comment),
    );
  }

  Future<Map<String, Object?>> _expectRecordState(String expectedState) {
    final completer = Completer<Map<String, Object?>>();
    _recordWaiters.add(_RecordStateWaiter(expectedState, completer));
    return completer.future;
  }

  void _send(Map<String, Object?> frame) => _socket.add(jsonEncode(frame));

  void _failPending(ObsWebSocketException error) {
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pendingRequests.clear();
    for (final waiter in _recordWaiters) {
      if (!waiter.completer.isCompleted) waiter.completer.completeError(error);
    }
    _recordWaiters.clear();
  }
}

final class _RecordStateWaiter {
  final String expectedState;
  final Completer<Map<String, Object?>> completer;

  const _RecordStateWaiter(this.expectedState, this.completer);
}

final class _SavedFtermState {
  final Map<String, Object?>? bounds;
  final Map<String, Object?>? ui;
  final Map<String, Object?>? shader;

  const _SavedFtermState({this.bounds, this.ui, this.shader});
}

final class _PreRollHandles {
  final String devTabId;
  final String devPaneId;
  final String? glassTabId;
  final String? glassPaneId;
  final String? arcadeTabId;
  final String? arcadePaneId;
  final String? fxTabId;
  final String? fxPaneId;
  final String? editorTabId;
  final String? editorPaneId;
  final String activeShaderEntry;
  final bool hasIntroAudioBed;

  const _PreRollHandles({
    required this.devTabId,
    required this.devPaneId,
    required this.activeShaderEntry,
    this.glassTabId,
    this.glassPaneId,
    this.arcadeTabId,
    this.arcadePaneId,
    this.fxTabId,
    this.fxPaneId,
    this.editorTabId,
    this.editorPaneId,
    this.hasIntroAudioBed = false,
  });
}

/// Orchestrates the 4-Act `fterm` sizzle reel across [FtermDriverClient] and
/// [ObsController].
final class SizzleDirector {
  /// Resolved shoot configuration.
  final SizzleConfig config;

  /// Loopback `fterm` HTTP driver client.
  final FtermDriverClient fterm;

  /// OBS capture controller (live or no-op).
  final ObsController obs;

  final SizzleSleep _sleep;
  final void Function(String line) _log;

  /// Creates a [SizzleDirector].
  SizzleDirector({
    required this.config,
    required this.fterm,
    required this.obs,
    SizzleSleep? sleep,
    void Function(String line)? log,
  }) : _sleep = sleep ?? Future<void>.delayed,
       _log = log ?? stdout.writeln;

  /// Runs pre-roll, executes the selected Acts in `master` or `takes` mode,
  /// renames output clips, and restores original `fterm` state on exit.
  Future<List<String>> run() async {
    final saved = config.restoreOnExit ? await _captureOriginalState() : null;
    final producedFiles = <String>[];
    try {
      final handles = await _preRoll();
      if (config.mode == SizzleRecordingMode.master) {
        final masterFile = await _shootMaster(handles);
        if (masterFile != null) producedFiles.add(masterFile);
      } else {
        producedFiles.addAll(await _shootSeparateTakes(handles));
      }
      return producedFiles;
    } finally {
      if (saved != null) {
        await _restoreOriginalState(saved);
      }
    }
  }

  Future<_SavedFtermState> _captureOriginalState() async {
    final bounds = await fterm.get('/v1/window/bounds');
    final ui = await fterm.get('/v1/ui');
    final shader = await fterm.get('/v1/shader');
    return _SavedFtermState(bounds: bounds, ui: ui, shader: shader);
  }

  Future<void> _restoreOriginalState(_SavedFtermState saved) async {
    try {
      if (saved.ui case final ui?) {
        await fterm.post('/v1/ui', <String, Object?>{
          if (ui['fontSize'] case final num size) 'fontSize': size.toDouble(),
          if (ui['theme'] case final String theme) 'theme': theme,
          if (ui['perfHud'] case final bool hud) 'perfHud': hud,
          'overlay': 'none',
        });
      }
      if (saved.shader case final shader?) {
        await fterm.post('/v1/shader', <String, Object?>{
          if (shader['background'] case final List<Object?> bg)
            'background': bg.whereType<String>().toList(),
          if (shader['foreground'] case final List<Object?> fg)
            'foreground': fg.whereType<String>().toList(),
          if (shader['backgroundOpacity'] case final num op)
            'backgroundOpacity': op.toDouble(),
        });
      }
      if (saved.bounds case final bounds? when bounds['supported'] == true) {
        final phys = bounds['physical'];
        if (phys is Map<Object?, Object?>) {
          await fterm.post('/v1/window/bounds', <String, Object?>{
            'x': phys['x'],
            'y': phys['y'],
            'width': phys['width'],
            'height': phys['height'],
            'units': 'physical',
            'alwaysOnTop': bounds['alwaysOnTop'] == true,
            'squareCorners': bounds['squareCorners'] == true,
          });
        }
      }
    } on Object catch (error) {
      _log('[sizzle] Warning: failed to restore original fterm state: $error');
    }
  }

  Future<_PreRollHandles> _preRoll() async {
    _log(
      '[sizzle] Pre-roll: snapping ${config.stageWidth}x${config.stageHeight} stage',
    );
    await fterm.post('/v1/window/bounds', <String, Object?>{
      'x': 0,
      'y': 0,
      'width': config.stageWidth,
      'height': config.stageHeight,
      'units': 'physical',
      'squareCorners': true,
      'alwaysOnTop': true,
      'focus': true,
    });
    await obs.ensureWindowCaptureScene(
      sceneName: config.obsScene,
      inputName: config.obsWindowInput,
      windowTitle: config.windowTitle,
      stageWidth: config.stageWidth,
      stageHeight: config.stageHeight,
    );
    var hasIntroAudioBed = false;
    final startsOnAudioAct = config.acts.isNotEmpty && config.acts.first == 2;
    if (config.useIntroBed && !startsOnAudioAct) {
      final bedPath = await _prepareIntroAudioBedFile();
      if (bedPath != null) {
        await obs.ensureIntroAudioSource(
          sceneName: config.obsScene,
          inputName: config.obsIntroAudioInput,
          filePath: bedPath,
        );
        hasIntroAudioBed = true;
      }
    }
    await _sleep(const Duration(milliseconds: 600));
    await fterm.post('/v1/ui', <String, Object?>{
      'fontSize': config.fontSize,
      'perfHud': false,
      'overlay': 'none',
    });
    await fterm.post('/v1/shader', <String, Object?>{
      'clear': true,
      'backgroundOpacity': config.backgroundOpacity,
    });

    final devTab = await _prepareDevTab();
    final glassTab = config.acts.contains(0) ? await _prepareGlassTab() : null;
    final arcadeTab = config.acts.contains(5)
        ? await _prepareArcadeTab()
        : null;
    final fxTab = config.acts.contains(2) || config.acts.contains(3)
        ? await _prepareFxTab()
        : null;

    await fterm.post('/v1/tabs/select', <String, Object?>{
      'tabId': devTab.tabId,
    });
    final shaderEntry =
        config.bgShaderPath ?? config.shaderPath ?? config.shaderPreset;
    String? editorTabId;
    String? editorPaneId;
    if (config.acts.contains(1)) {
      final editor = await fterm.post('/v1/shader/editor', <String, Object?>{
        'open': true,
        if (config.shaderPath case final path?)
          'path': path
        else
          'preset': config.shaderPreset,
        'previewMode': 'bg',
        'composition': 'solo',
        'awaitCompile': true,
      });
      editorPaneId = editor['paneId'] as String?;
      final tabsState = await fterm.get('/v1/tabs');
      editorTabId = tabsState['activeTabId'] as String?;
      await _prepareLiveEditEditorBuffer(editor);
      await _sleep(const Duration(milliseconds: 300));
    }

    // Pre-position the opening act's tab before StartRecord so frame 0 has no
    // tab-switch flash.
    if (config.acts.isNotEmpty) {
      final firstAct = config.acts.first;
      if (firstAct == 0 && glassTab != null) {
        await fterm.post('/v1/tabs/select', <String, Object?>{
          'tabId': glassTab.tabId,
        });
        await _sleep(const Duration(milliseconds: 250));
      } else if (firstAct == 5 && arcadeTab != null) {
        await fterm.post('/v1/tabs/select', <String, Object?>{
          'tabId': arcadeTab.tabId,
        });
        await _sleep(const Duration(milliseconds: 250));
      } else if (firstAct == 2 && fxTab != null) {
        await fterm.post('/v1/tabs/select', <String, Object?>{
          'tabId': fxTab.tabId,
        });
        await _sleep(const Duration(milliseconds: 250));
      }
    }

    return _PreRollHandles(
      devTabId: devTab.tabId,
      devPaneId: devTab.paneId,
      glassTabId: glassTab?.tabId,
      glassPaneId: glassTab?.paneId,
      arcadeTabId: arcadeTab?.tabId,
      arcadePaneId: arcadeTab?.paneId,
      fxTabId: fxTab?.tabId,
      fxPaneId: fxTab?.paneId,
      editorTabId: editorTabId,
      editorPaneId: editorPaneId,
      activeShaderEntry: shaderEntry,
      hasIntroAudioBed: hasIntroAudioBed,
    );
  }

  Future<String?> _prepareIntroAudioBedFile() async {
    if (config.introBedPath case final explicit?) {
      final file = File(explicit);
      return file.existsSync() ? file.absolute.path : null;
    }
    final sourceAsset = _resolveRepoAsset(
      windowsRelPath:
          r'packages\termui_audio\example\assets\VoxelRevolution.ogg',
      posixRelPath: 'packages/termui_audio/example/assets/VoxelRevolution.ogg',
      workingDir: Directory.current.path,
    );
    if (sourceAsset == null) return null;
    final outDir = Directory(config.outputDir);
    await outDir.create(recursive: true);
    final bedFile = File(p.join(outDir.path, 'intro_bed.wav')).absolute;
    if (bedFile.existsSync() &&
        bedFile.lengthSync() > 1024 &&
        bedFile.lastModifiedSync().isAfter(sourceAsset.lastModifiedSync())) {
      return bedFile.path;
    }
    try {
      final result = await Process.run('ffmpeg', <String>[
        '-y',
        '-v',
        'error',
        '-i',
        sourceAsset.path,
        '-t',
        '60',
        '-af',
        'asetrate=48000*0.5,aresample=48000,lowpass=f=500,'
            'aecho=0.8:0.88:60:0.35,volume=0.22,afade=t=in:st=0:d=1.0',
        bedFile.path,
      ]);
      if (result.exitCode == 0 && bedFile.existsSync()) {
        _log('[sizzle] Generated lower-octave intro bed: ${bedFile.path}');
        return bedFile.path;
      }
      _log(
        '[sizzle] Warning: ffmpeg failed generating intro_bed.wav: ${result.stderr}',
      );
    } on ProcessException {
      _log(
        '[sizzle] Warning: ffmpeg not found on PATH; skipping intro audio bed.',
      );
    }
    return null;
  }

  Future<({String tabId, String paneId})> _prepareDevTab() async {
    final spawned = await fterm.post('/v1/tabs/spawn', <String, Object?>{
      'title': config.devTitle,
      'cwd': config.devCwd,
    });
    final tabId = spawned['tabId']! as String;
    final paneId = spawned['paneId']! as String;
    await fterm.waitForScreen(paneId, config.promptPattern);
    await _sleep(const Duration(milliseconds: 150));
    await fterm.post('/v1/pty/write', <String, Object?>{
      'paneId': paneId,
      'text': '${config.devCommand}\r',
    });
    await fterm.waitForScreen(paneId, config.devWaitPattern);
    return (tabId: tabId, paneId: paneId);
  }

  Future<({String tabId, String paneId})> _prepareGlassTab() async {
    final spawned = await fterm.post('/v1/tabs/spawn', <String, Object?>{
      'title': 'termui_glass',
      'cwd': config.glassCwd,
    });
    final tabId = spawned['tabId']! as String;
    final paneId = spawned['paneId']! as String;
    await fterm.waitForScreen(paneId, config.promptPattern);
    await _sleep(const Duration(milliseconds: 150));
    if (config.glassCommand case final cmd?) {
      await fterm.post('/v1/pty/write', <String, Object?>{
        'paneId': paneId,
        'text': '$cmd\r',
      });
      await fterm.waitForScreen(
        paneId,
        r'[▀▄█▓▒░]',
        timeout: const Duration(seconds: 15),
      );
    }
    return (tabId: tabId, paneId: paneId);
  }

  Future<({String tabId, String paneId})> _prepareArcadeTab() async {
    final spawned = await fterm.post('/v1/tabs/spawn', <String, Object?>{
      'title': 'text_arcade',
      'cwd': config.arcadeCwd,
    });
    final tabId = spawned['tabId']! as String;
    final paneId = spawned['paneId']! as String;
    await fterm.waitForScreen(paneId, config.promptPattern);
    await _sleep(const Duration(milliseconds: 150));
    if (config.arcadeCommand case final cmd?) {
      await fterm.post('/v1/pty/write', <String, Object?>{
        'paneId': paneId,
        'text': '$cmd\r',
      });
      await fterm.waitForScreen(
        paneId,
        'One Ring',
        timeout: const Duration(seconds: 15),
      );
    }
    return (tabId: tabId, paneId: paneId);
  }

  Future<({String tabId, String paneId})> _prepareFxTab() async {
    final spawned = await fterm.post('/v1/tabs/spawn', <String, Object?>{
      'title': config.fxTitle,
      'cwd': config.fxCwd,
    });
    final tabId = spawned['tabId']! as String;
    final paneId = spawned['paneId']! as String;
    await fterm.waitForScreen(paneId, config.promptPattern);
    await _sleep(const Duration(milliseconds: 150));
    if (config.fxCommand case final cmd?) {
      await fterm.post('/v1/pty/write', <String, Object?>{
        'paneId': paneId,
        'text': '$cmd\r',
      });
      await fterm.waitForScreen(
        paneId,
        config.fxWaitPattern,
        timeout: const Duration(seconds: 25),
      );
    }
    return (tabId: tabId, paneId: paneId);
  }

  Future<String?> _shootMaster(_PreRollHandles handles) async {
    _log('[sizzle] Recording master take...');
    await obs.startRecord();
    if (handles.hasIntroAudioBed) {
      await obs.startIntroAudioBed();
    }
    try {
      for (final act in config.acts) {
        await _runActByNumber(act, handles);
      }
    } finally {
      await obs.stopIntroAudioBed();
      await obs.clearOverlayBadge();
    }
    final rawPath = await obs.stopRecord();
    await _quitFxAppIfRunning(handles);
    return _moveRecordingIfPresent(rawPath, config.masterName);
  }

  Future<List<String>> _shootSeparateTakes(_PreRollHandles handles) async {
    final files = <String>[];
    for (final act in config.acts) {
      final stem = _chapterNameForAct(act);
      _log('[sizzle] Recording take "$stem"...');
      await obs.startRecord();
      try {
        await _runActByNumber(act, handles);
      } finally {
        await obs.stopIntroAudioBed();
        await obs.clearOverlayBadge();
      }
      final rawPath = await obs.stopRecord();
      final saved = await _moveRecordingIfPresent(rawPath, stem);
      if (saved != null) files.add(saved);
    }
    await _quitFxAppIfRunning(handles);
    return files;
  }

  Future<void> _quitFxAppIfRunning(_PreRollHandles handles) async {
    final fxPaneId = handles.fxPaneId;
    final quitKey = config.fxQuitKey;
    if (fxPaneId == null || quitKey == null || quitKey.isEmpty) return;
    try {
      await fterm.post('/v1/pty/write', <String, Object?>{
        'paneId': fxPaneId,
        'text': quitKey,
      });
    } on Object {
      // Ignore if the pane already exited.
    }
  }

  static String _chapterNameForAct(int act) => switch (act) {
    0 => '00_termui_glass_fire',
    1 => '01_live_glsl_editor',
    2 => '02_esc_s_and_3d_audio',
    3 => '03_webgl2_relay_split',
    4 => '04_outro',
    5 => '05_shader_text_arcade',
    _ => 'act_$act',
  };

  Future<void> _runActByNumber(int act, _PreRollHandles handles) =>
      switch (act) {
        0 => _runAct0Glass(handles),
        1 => _runAct1(handles),
        2 => _runAct2(handles),
        3 => _runAct3(handles),
        4 => _runAct4(handles),
        5 => _runAct5Arcade(handles),
        _ => Future<void>.value(),
      };

  Future<void> _runAct0Glass(_PreRollHandles handles) async {
    await obs.createRecordChapter('00_termui_glass_fire');
    await obs.setOverlayBadge('termui for expressive tui');
    await fterm.post('/v1/ui', <String, Object?>{'perfHud': false});
    if (handles.glassTabId case final glassTabId?) {
      await fterm.post('/v1/tabs/select', <String, Object?>{
        'tabId': glassTabId,
      });
    }
    await _sleep(Duration(milliseconds: config.glassDurationMs));
    if (handles.glassPaneId case final glassPaneId?) {
      await fterm.post('/v1/pty/write', <String, Object?>{
        'paneId': glassPaneId,
        'text': 'q',
      });
      await _sleep(const Duration(milliseconds: 250));
    }
  }

  Future<void> _runAct5Arcade(_PreRollHandles handles) async {
    await obs.createRecordChapter('05_shader_text_arcade');
    await obs.setOverlayBadge(
      'tui provided custom shaders\ntui controlled text animations',
    );
    await fterm.post('/v1/ui', <String, Object?>{'perfHud': false});
    if (handles.arcadeTabId case final arcadeTabId?) {
      await fterm.post('/v1/tabs/select', <String, Object?>{
        'tabId': arcadeTabId,
      });
    }
    await _sleep(const Duration(milliseconds: 450));

    final paneId = handles.arcadePaneId;
    if (paneId == null) return;

    // 1. One Ring — sweeping fire reveals hidden golden runes.
    await fterm.post('/v1/pty/write', <String, Object?>{
      'paneId': paneId,
      'text': '1',
    });
    await _sleep(const Duration(milliseconds: 300));
    await fterm.post('/v1/pty/write', <String, Object?>{
      'paneId': paneId,
      'text': ' ',
    });
    await _sleep(const Duration(milliseconds: 2800));

    // 2. Vortext — Black Hole spaghettification, then Top-Down Hurricane.
    await fterm.post('/v1/pty/write', <String, Object?>{
      'paneId': paneId,
      'text': '2',
    });
    await _sleep(const Duration(milliseconds: 2400));
    await fterm.post('/v1/pty/write', <String, Object?>{
      'paneId': paneId,
      'text': 'm',
    });
    await _sleep(const Duration(milliseconds: 2200));

    // 4. Neon & Glitch — glowing marquee + chromatic tear bursts.
    await fterm.post('/v1/pty/write', <String, Object?>{
      'paneId': paneId,
      'text': '4',
    });
    await _sleep(const Duration(milliseconds: 600));
    await fterm.post('/v1/pty/write', <String, Object?>{
      'paneId': paneId,
      'text': ' ',
    });
    await _sleep(const Duration(milliseconds: 1000));
    await fterm.post('/v1/pty/write', <String, Object?>{
      'paneId': paneId,
      'text': ' ',
    });
    await _sleep(const Duration(milliseconds: 1200));

    // 5. Forge — anvil typing forge with per-character welding sparks.
    await fterm.post('/v1/pty/write', <String, Object?>{
      'paneId': paneId,
      'text': '5',
    });
    await _sleep(const Duration(milliseconds: 400));
    await fterm.post('/v1/pty/write', <String, Object?>{
      'paneId': paneId,
      'text': ' ',
    });
    await _sleep(const Duration(milliseconds: 3600));

    await fterm.post('/v1/pty/write', <String, Object?>{
      'paneId': paneId,
      'text': 'q',
    });
    await _sleep(const Duration(milliseconds: 250));
  }

  Future<void> _runAct1(_PreRollHandles handles) async {
    await obs.createRecordChapter('01_live_glsl_editor');
    await obs.setOverlayBadge('live shader editing');
    if (handles.editorTabId case final editorTabId?) {
      await fterm.post('/v1/tabs/select', <String, Object?>{
        'tabId': editorTabId,
      });
    }
    await _sleep(const Duration(milliseconds: 900));

    if (config.patchSteps.length >= 2) {
      final stepDelay = Duration(milliseconds: config.patchStepDelayMs);
      for (var i = 0; i < config.patchSteps.length - 1; i++) {
        await fterm.livePatchConstant(
          prefix: config.patchPrefix,
          oldVal: config.patchSteps[i],
          newVal: config.patchSteps[i + 1],
          keystrokeDelay: const Duration(milliseconds: 70),
        );
        await _sleep(stepDelay);
      }
    } else {
      await fterm.livePatchConstant(
        prefix: config.patchPrefix,
        oldVal: config.patchOldValue,
        newVal: config.patchNewValue,
        keystrokeDelay: const Duration(milliseconds: 70),
      );
      await _sleep(const Duration(milliseconds: 600));
    }

    if (handles.editorPaneId case final editorPaneId?) {
      if (config.patchSteps.length < 2) {
        await fterm.sweepShaderPointer(
          editorPaneId,
          duration: const Duration(milliseconds: 2500),
        );
      }
      await fterm.post('/v1/tabs/close', <String, Object?>{
        'paneId': editorPaneId,
        'force': true,
      });
    }
    await fterm.post('/v1/tabs/select', <String, Object?>{
      'tabId': handles.devTabId,
    });
    await obs.setOverlayBadge(config.devBadge);
    await fterm.post('/v1/shader', <String, Object?>{
      'background': <String>[handles.activeShaderEntry],
      'foreground': config.foregroundPresets,
      'backgroundOpacity': config.backgroundOpacity,
    });
    await _sleep(const Duration(milliseconds: 1800));
  }

  Future<void> _prepareLiveEditEditorBuffer(
    Map<String, Object?> openedEditor,
  ) async {
    if (config.patchSteps.length < 2) return;
    final firstVal = config.patchSteps.first;
    if (config.patchPrefix == '#define ITS ') {
      final state = await fterm.get('/v1/shader/editor');
      final rawSource = state['source'];
      if (rawSource is String && !rawSource.contains('#define ITS ')) {
        final patched = injectHighlightedItsDefine(
          rawSource,
          initialValue: firstVal,
        );
        if (patched != null) {
          await fterm.post('/v1/shader/editor', <String, Object?>{
            'open': false,
            'source': patched,
            'awaitCompile': true,
          });
          return;
        }
      }
    }
    if (config.patchOldValue != firstVal) {
      await fterm.post('/v1/shader/editor', <String, Object?>{
        'open': false,
        'find': '${config.patchPrefix}${config.patchOldValue}',
        'replace': '${config.patchPrefix}$firstVal',
        'awaitCompile': true,
      });
    }
  }

  Future<void> _runAct2(_PreRollHandles handles) async {
    await obs.createRecordChapter('02_esc_s_and_3d_audio');
    await obs.setOverlayBadge('tui driven 3D spatial audio');
    await fterm.post('/v1/ui', <String, Object?>{'perfHud': false});
    if (handles.fxTabId case final fxTabId?) {
      await fterm.post('/v1/tabs/select', <String, Object?>{'tabId': fxTabId});
    }
    await obs.fadeOutIntroAudioBed(duration: const Duration(milliseconds: 800));
    await _sleep(const Duration(milliseconds: 200));

    final fxPaneId = handles.fxPaneId;
    if (fxPaneId != null) {
      if (config.fxTriggerKey case final key? when key.isNotEmpty) {
        await fterm.post('/v1/pty/write', <String, Object?>{
          'paneId': fxPaneId,
          'text': key,
        });
        await _sleep(const Duration(milliseconds: 700));
      }
      if (config.fxMoveKeys.isNotEmpty) {
        final stepDelay = Duration(milliseconds: config.fxMoveDelayMs);
        for (final key in config.fxMoveKeys) {
          await fterm.post('/v1/pty/write', <String, Object?>{
            'paneId': fxPaneId,
            'text': key,
          });
          await _sleep(stepDelay);
        }
        await _sleep(const Duration(milliseconds: 800));
      } else {
        final hit = await fterm.post('/v1/screen/find', <String, Object?>{
          'paneId': fxPaneId,
          'text': config.fxButtonText,
        });
        final matches = hit['matches'];
        if (matches is List<Object?> && matches.isNotEmpty) {
          final first = matches.first;
          if (first is Map<Object?, Object?>) {
            await fterm.post('/v1/input/mouse', <String, Object?>{
              'paneId': fxPaneId,
              'action': 'click',
              'x': first['x'],
              'y': first['y'],
            });
          }
        }
        await _sleep(const Duration(milliseconds: 3200));
      }
      // Keep the 3D audio TUI live into Act 4 when Act 4 follows so the About
      // overlay opens cleanly over the running TUI with zero shell teardown
      // flash; _quitFxAppIfRunning stops it after obs.stopRecord().
      final actsList = config.acts.toList();
      final act2Idx = actsList.indexOf(2);
      final act4Follows = act2Idx >= 0 && actsList.indexOf(4) > act2Idx;
      if (!act4Follows) {
        if (config.fxQuitKey case final quitKey? when quitKey.isNotEmpty) {
          await fterm.post('/v1/pty/write', <String, Object?>{
            'paneId': fxPaneId,
            'text': quitKey,
          });
          await _sleep(const Duration(milliseconds: 300));
        }
      }
    }
  }

  Future<void> _runAct3(_PreRollHandles handles) async {
    await obs.createRecordChapter('03_webgl2_relay_split');
    await obs.setOverlayBadge(
      'Live 0x1C Cast -> WebGL2 Browser (*BYO bastion)',
    );
    await fterm.post('/v1/window/bounds', <String, Object?>{
      'x': 0,
      'y': 0,
      'width': config.splitWidth,
      'height': config.stageHeight,
      'units': 'physical',
      'squareCorners': true,
    });
    if (handles.fxPaneId case final fxPaneId?) {
      for (final key in config.act3Keys) {
        await fterm.post('/v1/pty/write', <String, Object?>{
          'paneId': fxPaneId,
          'text': key,
        });
        await _sleep(const Duration(milliseconds: 450));
      }
    }
    await _sleep(const Duration(milliseconds: 1800));
  }

  Future<void> _runAct4(_PreRollHandles handles) async {
    await obs.createRecordChapter('04_outro');
    await obs.setOverlayBadge('built with flutter, dart, and termui');
    await fterm.post('/v1/window/bounds', <String, Object?>{
      'x': 0,
      'y': 0,
      'width': config.stageWidth,
      'height': config.stageHeight,
      'units': 'physical',
    });
    await fterm.post('/v1/ui', <String, Object?>{
      'perfHud': false,
      'overlay': 'about',
    });
    if (handles.fxPaneId case final fxPaneId?
        when config.fxMoveKeys.isNotEmpty && config.acts.contains(2)) {
      // Hold warmly over live 3D music, then smoothly fade BGM volume down
      // (-0.05 per '-' keypress across 20 steps = 1.2s) before stopping.
      await _sleep(const Duration(milliseconds: 2800));
      for (var i = 0; i < 20; i++) {
        await fterm.post('/v1/pty/write', <String, Object?>{
          'paneId': fxPaneId,
          'text': '-',
        });
        await _sleep(const Duration(milliseconds: 60));
      }
    } else {
      await _sleep(const Duration(milliseconds: 4000));
    }
  }

  Future<String?> _moveRecordingIfPresent(String? rawPath, String stem) async {
    if (rawPath == null || rawPath.isEmpty) return null;
    final source = File(rawPath);
    if (!source.existsSync()) return rawPath;
    final ext = p.extension(rawPath);
    final outDir = Directory(config.outputDir);
    await outDir.create(recursive: true);
    final destination = p.join(
      outDir.path,
      '$stem${ext.isEmpty ? '.mkv' : ext}',
    );
    try {
      await source.rename(destination);
    } on FileSystemException {
      await source.copy(destination);
      await source.delete();
    }
    _log('[sizzle] Saved recording: $destination');
    return destination;
  }
}

/// Rewrites a kaleidoscope-style `for (float i = 0.0; i < 4.0; i++)` shader
/// in-memory to hoist the iteration count into a visually highlighted top-level
/// `#define ITS <initialValue>` callout block.
///
/// Returns `null` if the shader does not contain the expected loop header.
String? injectHighlightedItsDefine(
  String source, {
  required String initialValue,
}) {
  final loopPattern = RegExp(
    r'for\s*\(\s*float\s+i\s*=\s*0\.0\s*;\s*i\s*<\s*[0-9.]+\s*;\s*i\+\+\s*\)',
  );
  if (!loopPattern.hasMatch(source)) return null;
  final rewrittenBody = source.replaceFirst(
    loopPattern,
    'for (float i = 0.0; i < float(ITS); i++)',
  );
  final hasStageDirective = source.contains('@fterm-stage:');
  final header = <String>[
    if (!hasStageDirective) '// @fterm-stage: bg',
    '// vvvvvv live edit vvvvvv',
    '#define ITS $initialValue',
    '//         ^^^',
    '',
  ].join('\n');
  return '$header$rewrittenBody';
}

/// Generates a cryptographically secure ephemeral Bearer token for scripted
/// `--launch-fterm` sessions.
String generateEphemeralAutomationToken({math.Random? random}) {
  const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
  final rng = random ?? math.Random.secure();
  final groups = <String>[
    for (var g = 0; g < 4; g++)
      String.fromCharCodes(<int>[
        for (var i = 0; i < 5; i++)
          alphabet.codeUnitAt(rng.nextInt(alphabet.length)),
      ]),
  ];
  return groups.join('-');
}

/// Builds the child environment for a detached `fterm` process launched via
/// `--launch-fterm`.
///
/// Strips parent terminal and prompt session variables (`TERM`, `WT_*`,
/// `POSH_*`, etc.) so the spawned GUI window starts with the same clean
/// console/ConPTY environment as a normal desktop launch, and injects the
/// ephemeral `FTERM_AUTOMATION_TOKEN`.
Map<String, String> buildFtermLaunchEnvironment(
  Map<String, String> parentEnvironment, {
  required String token,
}) {
  const strippedKeys = <String>{
    'TERM',
    'TERM_PROGRAM',
    'TERM_PROGRAM_VERSION',
    'WT_SESSION',
    'WT_PROFILE_ID',
    'POSH_SESSION_ID',
    'POSH_CURSOR_LINE',
    'POSH_CURSOR_COLUMN',
    'POSH_SHELL',
    'POSH_SHELL_VERSION',
  };
  return <String, String>{
    for (final MapEntry(:key, :value) in parentEnvironment.entries)
      if (!strippedKeys.contains(key.toUpperCase())) key: value,
    'FTERM_AUTOMATION_TOKEN': token,
  };
}

/// Builds the CLI flags passed to a spawned `fterm` process.
///
/// The Bearer token is never passed on the command line; supply it via the
/// child process `FTERM_AUTOMATION_TOKEN` environment variable instead.
List<String> buildFtermLaunchArgs(SizzleConfig config) => <String>[
  '--automation-driver',
  '--automation-allow-pty',
  '--automation-port=${config.ftermPort}',
  '--window-title=${config.windowTitle}',
];

/// Resolves the desktop `fterm` executable path from [explicitPath] or standard
/// Flutter build output directories under [workingDir].
///
/// Throws [FileSystemException] if no built binary is found.
String resolveFtermExecutablePath({
  String? explicitPath,
  String? workingDir,
  bool? isWindows,
  bool? isMacOS,
}) {
  if (explicitPath != null && explicitPath.trim().isNotEmpty) {
    final file = File(explicitPath.trim());
    if (!file.existsSync()) {
      throw FileSystemException(
        'Specified --fterm-bin executable does not exist.',
        file.path,
      );
    }
    return file.absolute.path;
  }
  final root = workingDir ?? Directory.current.path;
  final windows = isWindows ?? Platform.isWindows;
  final macOs = isMacOS ?? Platform.isMacOS;
  final relativeCandidates = windows
      ? const <String>[
          r'build\windows\x64\runner\Release\fterm.exe',
          r'build\windows\x64\runner\Profile\fterm.exe',
          r'build\windows\x64\runner\Debug\fterm.exe',
          r'apps\fterm\build\windows\x64\runner\Release\fterm.exe',
          r'apps\fterm\build\windows\x64\runner\Profile\fterm.exe',
          r'apps\fterm\build\windows\x64\runner\Debug\fterm.exe',
        ]
      : macOs
      ? const <String>[
          'build/macos/Build/Products/Release/fterm.app/Contents/MacOS/fterm',
          'build/macos/Build/Products/Profile/fterm.app/Contents/MacOS/fterm',
          'build/macos/Build/Products/Debug/fterm.app/Contents/MacOS/fterm',
          'apps/fterm/build/macos/Build/Products/Release/fterm.app/Contents/MacOS/fterm',
          'apps/fterm/build/macos/Build/Products/Debug/fterm.app/Contents/MacOS/fterm',
        ]
      : const <String>[
          'build/linux/x64/release/bundle/fterm',
          'build/linux/x64/profile/bundle/fterm',
          'build/linux/x64/debug/bundle/fterm',
          'apps/fterm/build/linux/x64/release/bundle/fterm',
          'apps/fterm/build/linux/x64/debug/bundle/fterm',
        ];
  for (final rel in relativeCandidates) {
    final candidate = File(p.join(root, rel));
    if (candidate.existsSync()) return candidate.absolute.path;
  }
  throw FileSystemException(
    'Could not locate a built fterm executable. Build one first (e.g. '
    '`flutter build windows --debug`) or pass `--fterm-bin <path>`.',
    root,
  );
}

/// Polls `GET /v1/state` on [client] until `fterm`'s automation driver accepts
/// requests, [timeout] expires, or [processExitCode] completes early.
Future<void> waitForFtermDriverReady(
  FtermDriverClient client, {
  Duration timeout = const Duration(seconds: 15),
  Duration pollInterval = const Duration(milliseconds: 150),
  SizzleSleep sleep = Future<void>.delayed,
  Future<int>? processExitCode,
}) async {
  int? exitedWith;
  if (processExitCode != null) {
    unawaited(processExitCode.then((code) => exitedWith = code));
  }
  final stopwatch = Stopwatch()..start();
  while (true) {
    if (exitedWith case final code?) {
      throw ProcessException(
        'fterm',
        const <String>[],
        'Spawned fterm process exited before automation driver became ready.',
        code,
      );
    }
    try {
      await client.get('/v1/state');
      return;
    } on SocketException {
      // Driver has not bound the loopback socket yet.
    } on HttpException {
      // Transient startup socket reset.
    } on FtermDriverException catch (error) {
      if (error.statusCode != 503) rethrow;
    }
    if (stopwatch.elapsed >= timeout) {
      throw TimeoutException(
        'Timed out after ${timeout.inMilliseconds}ms waiting for fterm '
        'automation driver at ${client.baseUri}.',
      );
    }
    await sleep(pollInterval);
  }
}

/// Entry point for `dart run tool/sizzle.dart`.
Future<void> main(List<String> args) async {
  final SizzleConfig config;
  try {
    config = SizzleConfig.parseArgs(args);
  } on FormatException catch (error) {
    stderr.writeln('sizzle: ${error.message}');
    stderr.writeln(SizzleConfig.usage);
    exitCode = 64;
    return;
  }
  if (config.showHelp) {
    stdout.write(SizzleConfig.usage);
    return;
  }
  if (config.ftermToken.isEmpty) {
    stderr.writeln(
      'sizzle: missing Bearer token. Set FTERM_AUTOMATION_TOKEN, enable the '
      'driver once so settings.json persists a password, pass --launch-fterm, '
      'or pass --token.',
    );
    exitCode = 64;
    return;
  }

  final fterm = FtermDriverClient(
    baseUri: config.ftermBaseUri,
    token: config.ftermToken,
  );
  ObsController obs = const NoopObsController();
  Process? spawnedFterm;
  try {
    if (config.launchFterm) {
      final executable = resolveFtermExecutablePath(
        explicitPath: config.ftermBin,
      );
      final launchArgs = buildFtermLaunchArgs(config);
      stdout.writeln(
        '[sizzle] Launching fterm: $executable ${launchArgs.join(' ')}',
      );
      final spawned = await Process.start(
        executable,
        launchArgs,
        environment: buildFtermLaunchEnvironment(
          Platform.environment,
          token: config.ftermToken,
        ),
        includeParentEnvironment: false,
      );
      spawnedFterm = spawned;
      unawaited(spawned.stdout.drain<void>());
      unawaited(spawned.stderr.drain<void>());
      await waitForFtermDriverReady(fterm, processExitCode: spawned.exitCode);
    }
    if (config.useObs) {
      obs = await ObsWebSocketClient.connect(
        config.obsUri,
        password: config.obsPassword,
        overlayInput: config.obsOverlayInput,
        overlayScene: config.obsOverlayScene,
      );
    }
    final director = SizzleDirector(config: config, fterm: fterm, obs: obs);
    final files = await director.run();
    stdout.writeln(
      files.isEmpty
          ? '[sizzle] Rehearsal complete.'
          : '[sizzle] Done (${files.length} file(s)): ${files.join(', ')}',
    );
  } on TimeoutException catch (error) {
    stderr.writeln('sizzle: ${error.message ?? error}');
    exitCode = 1;
  } on FtermDriverException catch (error) {
    stderr.writeln('sizzle: $error');
    exitCode = 1;
  } on ObsWebSocketException catch (error) {
    stderr.writeln('sizzle: $error');
    exitCode = 1;
  } on FileSystemException catch (error) {
    stderr.writeln('sizzle: ${error.message} (${error.path})');
    exitCode = 1;
  } on ProcessException catch (error) {
    stderr.writeln('sizzle: ${error.message} (exitCode=${error.errorCode})');
    exitCode = 1;
  } finally {
    await obs.close();
    fterm.close();
    if (spawnedFterm != null && !config.keepFterm) {
      if (config.restoreOnExit) {
        // Give fterm's ThrottledSettingsSaver (200ms cooldown) time to flush
        // restored preferences (such as fontSize and shader chain) to disk.
        await Future<void>.delayed(const Duration(milliseconds: 450));
      }
      spawnedFterm.kill();
    }
  }
}

Map<String, String> _parseFlagMap(List<String> args) {
  const boolFlags = <String>{
    'help',
    'no-obs',
    'no-restore',
    'no-intro-bed',
    'launch-fterm',
    'keep-fterm',
  };
  const valueFlags = <String>{
    'fterm-bin',
    'host',
    'port',
    'token',
    'obs-url',
    'obs-password',
    'obs-overlay-input',
    'obs-overlay-scene',
    'obs-scene',
    'obs-window-input',
    'obs-intro-audio-input',
    'intro-bed',
    'dev-badge',
    'window-title',
    'mode',
    'acts',
    'out-dir',
    'master-name',
    'stage-width',
    'stage-height',
    'split-width',
    'font-size',
    'dev-cwd',
    'dev-title',
    'dev-command',
    'dev-wait',
    'fx-cwd',
    'fx-title',
    'fx-command',
    'fx-wait',
    'fx-trigger-key',
    'fx-move-keys',
    'fx-move-delay-ms',
    'fx-quit-key',
    'glass-cwd',
    'glass-command',
    'glass-duration-ms',
    'arcade-cwd',
    'arcade-command',
    'fx-button',
    'act3-keys',
    'prompt-pattern',
    'shader-preset',
    'shader-path',
    'bg-shader-path',
    'bg-opacity',
    'fg-presets',
    'patch-prefix',
    'patch-old',
    'patch-new',
    'patch-steps',
    'patch-step-delay-ms',
  };
  final parsed = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '-h' || arg == '--help') {
      parsed['help'] = 'true';
      continue;
    }
    if (!arg.startsWith('--')) {
      throw FormatException('Unexpected positional argument "$arg".');
    }
    final body = arg.substring(2);
    final eq = body.indexOf('=');
    final key = eq >= 0 ? body.substring(0, eq) : body;
    if (boolFlags.contains(key)) {
      parsed[key] = 'true';
      continue;
    }
    if (!valueFlags.contains(key)) {
      throw FormatException('Unknown option "--$key".');
    }
    if (eq >= 0) {
      parsed[key] = body.substring(eq + 1);
      continue;
    }
    if (i + 1 >= args.length) {
      throw FormatException('Missing value for "--$key".');
    }
    parsed[key] = args[++i];
  }
  return parsed;
}

Set<int> _parseActs(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <int>{1, 2, 3, 4};
  final acts = <int>{};
  for (final part in raw.split(',')) {
    final n = int.tryParse(part.trim());
    if (n == null || n < 0 || n > 5) {
      throw FormatException('Invalid act "$part" in --acts (expected 0..5).');
    }
    acts.add(n);
  }
  return acts;
}

int _parsePositiveInt(
  String? raw, {
  required String flag,
  required int fallback,
  int? max,
}) {
  if (raw == null) return fallback;
  final parsed = int.tryParse(raw.trim());
  if (parsed == null || parsed <= 0 || (max != null && parsed > max)) {
    throw FormatException('Invalid value "$raw" for $flag.');
  }
  return parsed;
}

double _parsePositiveDouble(
  String? raw, {
  required String flag,
  required double fallback,
}) {
  if (raw == null) return fallback;
  final parsed = double.tryParse(raw.trim());
  if (parsed == null || !parsed.isFinite || parsed <= 0) {
    throw FormatException('Invalid value "$raw" for $flag.');
  }
  return parsed;
}

double _parseUnitDouble(
  String? raw, {
  required String flag,
  required double fallback,
}) {
  if (raw == null) return fallback;
  final parsed = double.tryParse(raw.trim());
  if (parsed == null || !parsed.isFinite || parsed < 0.0 || parsed > 1.0) {
    throw FormatException(
      'Invalid value "$raw" for $flag (expected 0.0..1.0).',
    );
  }
  return parsed;
}

String? _resolveUserShaderPath(
  String filename, {
  required Map<String, String> environment,
  bool? isWindows,
}) {
  final settingsPath = _resolveDesktopSettingsPath(
    environment: environment,
    isWindows: isWindows ?? Platform.isWindows,
  );
  if (settingsPath == null) return null;
  final candidate = File(p.join(p.dirname(settingsPath), 'shaders', filename));
  return candidate.existsSync() ? candidate.path : null;
}

File? _resolveRepoAsset({
  required String windowsRelPath,
  required String posixRelPath,
  required String workingDir,
  bool? isWindows,
}) {
  final windows = isWindows ?? Platform.isWindows;
  final relPath = windows ? windowsRelPath : posixRelPath;
  var dir = Directory(workingDir).absolute;
  for (var depth = 0; depth < 5; depth++) {
    final candidate = File(p.join(dir.path, relPath));
    if (candidate.existsSync()) return candidate.absolute;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

({String cwd, String command})? _resolveLocalDemo({
  required String windowsRelPath,
  required String posixRelPath,
  required String workingDir,
  bool? isWindows,
}) {
  final windows = isWindows ?? Platform.isWindows;
  final relPath = windows ? windowsRelPath : posixRelPath;
  var dir = Directory(workingDir).absolute;
  for (var depth = 0; depth < 5; depth++) {
    final candidate = File(p.join(dir.path, relPath));
    if (candidate.existsSync()) {
      return (cwd: dir.path, command: windows ? '.\\$relPath' : './$relPath');
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

String? _nonEmpty(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _resolveDesktopSettingsPath({
  required Map<String, String> environment,
  required bool isWindows,
}) {
  if (isWindows) {
    final appData = _nonEmpty(environment['APPDATA']);
    if (appData != null) {
      return p.windows.join(appData, 'fterm', 'settings.json');
    }
    final profile = _nonEmpty(environment['USERPROFILE']);
    if (profile != null) {
      return p.windows.join(
        profile,
        'AppData',
        'Roaming',
        'fterm',
        'settings.json',
      );
    }
    return null;
  }
  final home = _nonEmpty(environment['HOME']);
  return home == null
      ? null
      : p.posix.join(home, '.config', 'fterm', 'settings.json');
}

Map<String, Object?> _asStringMap(Map<Object?, Object?> raw) =>
    <String, Object?>{
      for (final MapEntry(:key, :value) in raw.entries)
        if (key is String) key: value,
    };

Map<Object?, Object?>? _tryDecodeMap(String raw) {
  try {
    final Object? decoded = jsonDecode(raw);
    return decoded is Map<Object?, Object?> ? decoded : null;
  } on Object {
    return null;
  }
}
