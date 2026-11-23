import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:termui/ui/shader_animation_mode.dart';

export 'package:termui/ui/shader_animation_mode.dart' show ShaderAnimationMode;

/// Pipeline stage where a terminal fragment shader pass executes.
enum TerminalShaderStage {
  /// Executes behind the terminal canvas (e.g. procedural or wallpaper effects).
  background,

  /// Executes over the rendered terminal frame via `iChannel0`.
  foreground,
}

/// Recommended pipeline stage for a shader inferred from an optional
/// `// @fterm-stage: bg | fg | both` comment directive or static GLSL analysis.
enum ShaderStageHint {
  /// Designed to render behind the terminal canvas (e.g. standalone generator
  /// or wallpaper shader that ignores `iChannel0`).
  background('BG'),

  /// Designed to post-process the rendered terminal frame (e.g. samples
  /// cursor/focus uniforms or chains over `iChannel0`).
  foreground('FG'),

  /// Suitable for either background or foreground chains (e.g. explicitly
  /// tagged `both` / `any`, or samples both `iChannel0` and `iChannel1`).
  any('Any');

  /// Compact badge label displayed in settings UIs.
  final String shortLabel;

  const ShaderStageHint(this.shortLabel);
}

/// Active GPU shader compilation and execution backend.
enum ShaderBackendKind {
  /// Desktop Impeller backend backed by `package:flutter_gpu` and `impellerc`.
  flutterGpu('flutter_gpu'),

  /// Flutter Web backend backed by an `OffscreenCanvas` WebGL2 context.
  webGl2('webgl2'),

  /// No-op fallback when GPU shaders are unavailable or explicitly disabled.
  disabled('disabled');

  /// Canonical JSON and wire identifier for this backend kind.
  final String wireName;

  const ShaderBackendKind(this.wireName);

  /// Parses [raw] from its [wireName] (or enum [name]), returning `null` if
  /// unrecognized.
  static ShaderBackendKind? tryFromWireName(Object? raw) => switch (raw) {
    'flutter_gpu' || 'flutterGpu' => flutterGpu,
    'webgl2' || 'webGl2' => webGl2,
    'disabled' => disabled,
    _ => null,
  };
}

/// Built-in Ghostty-compatible terminal fragment shader presets.
enum TerminalShaderPreset {
  /// No built-in preset selected.
  none('none'),

  /// Animated ambient wave and wallpaper tint pass for the background stage.
  wallpaperWave('wallpaper_wave'),

  /// Soft cursor halo and smooth cursor-motion trail for the foreground stage.
  cursorGlow('cursor_glow'),

  /// Static horizontal scanline and vignette overlay for the foreground stage.
  scanlineOverlay('scanline_overlay'),

  /// Timothy Lottes-inspired CRT curvature, scanline, and aperture mask pass.
  crtLottes('crt_lottes'),

  /// Persistent phosphor afterglow and bloom pass using `iPrevFrame`.
  phosphorGlow('phosphor_glow'),

  /// Clean-room retro CRT phosphor pass with barrel curvature, cell-scaled
  /// HiDPI scanlines, and luminance-preserving phosphor tinting.
  retroPhosphor('retro_phosphor');

  /// Canonical JSON and wire identifier for this preset.
  final String wireName;

  const TerminalShaderPreset(this.wireName);

  /// Parses [raw] from its [wireName] (or enum [name]), returning [fallback]
  /// if unrecognized.
  static TerminalShaderPreset fromWireName(
    Object? raw, {
    TerminalShaderPreset fallback = TerminalShaderPreset.none,
  }) => switch (raw) {
    'none' => none,
    'wallpaper_wave' || 'wallpaperWave' => wallpaperWave,
    'cursor_glow' || 'cursorGlow' => cursorGlow,
    'scanline_overlay' || 'scanlineOverlay' => scanlineOverlay,
    'crt_lottes' || 'crtLottes' => crtLottes,
    'phosphor_glow' || 'phosphorGlow' => phosphorGlow,
    'retro_phosphor' || 'retroPhosphor' => retroPhosphor,
    _ => fallback,
  };
}

/// Declarative description of a single shader pass in a background or
/// foreground chain.
final class ShaderPassSpec {
  /// Number of user float parameters packed into `uParams0` and `uParams1`.
  static const int paramCount = 8;

  /// Stable identifier used to cache compiled shader pipelines and ping-pong
  /// textures across frames.
  final String id;

  /// Pipeline stage where this pass executes.
  final TerminalShaderStage stage;

  /// Optional built-in shader preset.
  final TerminalShaderPreset? preset;

  /// Optional local filesystem path to a custom `.glsl` file.
  final String? customSourcePath;

  /// Optional inline Ghostty Shadertoy GLSL source (used on Web or CLI).
  final String? inlineGlsl;

  /// Whether this pass samples `iPrevFrame` and requires a persistent
  /// ping-pong texture.
  final bool usesPrevFrame;

  /// Eight user float parameters mapped to `uParams0` (0..3) and `uParams1`
  /// (4..7).
  final Float32List params;

  /// Creates a shader pass specification with normalized 8-float [params].
  ShaderPassSpec({
    required this.id,
    required this.stage,
    this.preset,
    this.customSourcePath,
    this.inlineGlsl,
    this.usesPrevFrame = false,
    Float32List? params,
  }) : params = _normalizeFloatList(params, paramCount);

  /// Returns a copy of this specification with specified fields replaced.
  ShaderPassSpec copyWith({
    String? id,
    TerminalShaderStage? stage,
    TerminalShaderPreset? preset,
    String? customSourcePath,
    String? inlineGlsl,
    bool? usesPrevFrame,
    Float32List? params,
  }) => ShaderPassSpec(
    id: id ?? this.id,
    stage: stage ?? this.stage,
    preset: preset ?? this.preset,
    customSourcePath: customSourcePath ?? this.customSourcePath,
    inlineGlsl: inlineGlsl ?? this.inlineGlsl,
    usesPrevFrame: usesPrevFrame ?? this.usesPrevFrame,
    params: params ?? this.params,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShaderPassSpec &&
          other.id == id &&
          other.stage == stage &&
          other.preset == preset &&
          other.customSourcePath == customSourcePath &&
          other.inlineGlsl == inlineGlsl &&
          other.usesPrevFrame == usesPrevFrame &&
          _floatListEquals(other.params, params);

  @override
  int get hashCode => Object.hash(
    id,
    stage,
    preset,
    customSourcePath,
    inlineGlsl,
    usesPrevFrame,
    Object.hashAll(params),
  );
}

/// Complete shader and wallpaper configuration attached to a terminal surface.
final class TerminalShaderConfig {
  /// Empty configuration with no shader passes or wallpaper image.
  static const TerminalShaderConfig empty = TerminalShaderConfig();

  /// Ordered shader passes executed behind the terminal canvas.
  final List<ShaderPassSpec> backgroundPasses;

  /// Ordered post-processing shader passes executed over the terminal frame.
  final List<ShaderPassSpec> foregroundPasses;

  /// Policy controlling when `iTime` advances.
  final ShaderAnimationMode animationMode;

  /// Opacity applied to default background cells (`0.0..1.0`).
  final double backgroundOpacity;

  /// Optional wallpaper image exposed as `iChannel1` and drawn behind the
  /// terminal canvas.
  final ui.Image? backgroundImage;

  /// Master enable toggle for shader rendering.
  final bool enabled;

  /// Creates a terminal shader configuration.
  const TerminalShaderConfig({
    this.backgroundPasses = const <ShaderPassSpec>[],
    this.foregroundPasses = const <ShaderPassSpec>[],
    this.animationMode = ShaderAnimationMode.focused,
    this.backgroundOpacity = 1.0,
    this.backgroundImage,
    this.enabled = true,
  });

  /// Whether no shader passes or wallpaper are active.
  bool get isEmpty =>
      !enabled ||
      (backgroundPasses.isEmpty &&
          foregroundPasses.isEmpty &&
          backgroundImage == null);

  /// Whether the background stage has at least one pass or a wallpaper image.
  bool get hasBackgroundStage =>
      enabled && (backgroundPasses.isEmpty == false || backgroundImage != null);

  /// Whether the foreground stage has at least one post-processing pass.
  bool get hasForegroundStage => enabled && foregroundPasses.isNotEmpty;

  /// Returns a copy of this configuration with specified fields replaced.
  TerminalShaderConfig copyWith({
    List<ShaderPassSpec>? backgroundPasses,
    List<ShaderPassSpec>? foregroundPasses,
    ShaderAnimationMode? animationMode,
    double? backgroundOpacity,
    ui.Image? backgroundImage,
    bool clearBackgroundImage = false,
    bool? enabled,
  }) => TerminalShaderConfig(
    backgroundPasses: backgroundPasses == null
        ? this.backgroundPasses
        : List<ShaderPassSpec>.unmodifiable(backgroundPasses),
    foregroundPasses: foregroundPasses == null
        ? this.foregroundPasses
        : List<ShaderPassSpec>.unmodifiable(foregroundPasses),
    animationMode: animationMode ?? this.animationMode,
    backgroundOpacity: _clampFinite(
      backgroundOpacity,
      min: 0.0,
      max: 1.0,
      fallback: this.backgroundOpacity.isFinite ? this.backgroundOpacity : 1.0,
    ),
    backgroundImage: clearBackgroundImage
        ? null
        : (backgroundImage ?? this.backgroundImage),
    enabled: enabled ?? this.enabled,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalShaderConfig &&
          other.animationMode == animationMode &&
          other.backgroundOpacity == backgroundOpacity &&
          other.backgroundImage == backgroundImage &&
          other.enabled == enabled &&
          _passListEquals(other.backgroundPasses, backgroundPasses) &&
          _passListEquals(other.foregroundPasses, foregroundPasses);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(backgroundPasses),
    Object.hashAll(foregroundPasses),
    animationMode,
    backgroundOpacity,
    backgroundImage,
    enabled,
  );
}

/// Per-frame uniform payload matching Ghostty's verbatim `shadertoy_prefix.glsl`
/// plus Kitty/`fterm` extensions.
final class TerminalShaderUniforms {
  /// Ghostty `CURSORSTYLE_BLOCK` constant (`0`).
  static const int cursorStyleBlock = 0;

  /// Ghostty `CURSORSTYLE_BAR` constant (`1`).
  static const int cursorStyleBar = 1;

  /// Ghostty `CURSORSTYLE_UNDERLINE` constant (`2`).
  static const int cursorStyleUnderline = 2;

  /// Ghostty `CURSORSTYLE_BLOCK_HOLLOW` constant (`3`).
  static const int cursorStyleBlockHollow = 3;

  /// Number of entries in the 256-color ANSI palette table.
  static const int paletteLength = 256;

  /// Render target physical width in pixels (`iResolution.x`).
  final double width;

  /// Render target physical height in pixels (`iResolution.y`).
  final double height;

  /// Elapsed shader time in seconds (`iTime`).
  final double timeSeconds;

  /// Frame delta in seconds (`iTimeDelta`).
  final double deltaSeconds;

  /// Monotonic rendered frame counter (`iFrame`).
  final int frameIndex;

  /// Estimated frame rate in frames per second (`iFrameRate`).
  final double frameRate;

  /// Current cursor bounding box packed as Ghostty `(left, bottomY, width,
  /// height)` in Y-up physical pixels (`iCurrentCursor`).
  final Float32List currentCursorXywh;

  /// Previous cursor bounding box packed as Ghostty `(left, bottomY, width,
  /// height)` in Y-up physical pixels (`iPreviousCursor`).
  final Float32List previousCursorXywh;

  /// Current cursor ARGB color (`iCurrentCursorColor` / `iCursorColor`).
  final int currentCursorArgb;

  /// Previous cursor ARGB color (`iPreviousCursorColor`).
  final int previousCursorArgb;

  /// Active cursor style constant (`0..3`, `iCurrentCursorStyle`).
  final int currentCursorStyle;

  /// `iTime` timestamp when the cursor last moved or changed style
  /// (`iTimeCursorChange`).
  final double timeCursorChange;

  /// Whether the terminal cursor is currently visible (`iCursorVisible`).
  final bool cursorVisible;

  /// Whether the terminal pane currently holds keyboard focus (`iFocus`).
  final bool isFocused;

  /// `iTime` timestamp when focus last changed (`iTimeFocus`).
  final double timeFocusChange;

  /// Default terminal foreground ARGB color (`iForegroundColor`).
  final int foregroundArgb;

  /// Default terminal background ARGB color (`iBackgroundColor`).
  final int backgroundArgb;

  /// Full 256-color terminal palette in `0xAARRGGBB` format (`iPalette[256]`).
  final Uint32List palette256Argb;

  /// Scoped effect region bounds in physical pixels (`iRegionRect`).
  final ui.Rect regionRect;

  /// Physical cell width and height in pixels (`iCellSize`).
  final ui.Size cellSize;

  /// Eight user floats packed into `uParams0` (0..3) and `uParams1` (4..7).
  final Float32List params;

  /// Shadertoy pointer state `(x, y, clickX, clickY)` (`iMouse`).
  final Float32List mouseXyzw;

  /// Shadertoy date vector `(year, month, day, secondsSinceMidnight)`
  /// (`iDate`).
  final Float32List dateYmdSec;

  /// Flattened `vec3[4]` channel resolutions (`12` floats for
  /// `iChannelResolution[0..3]`).
  final Float32List channelResolutions;

  static final Float32List _zeroFloat4 = Float32List(4);
  static final Float32List _zeroParams = Float32List(ShaderPassSpec.paramCount);
  static final Float32List _zeroChannels = Float32List(12);
  static final Uint32List _zeroPalette256 = Uint32List(paletteLength);

  /// Creates a per-frame shader uniform payload, defensively copying all typed
  /// list inputs to canonical lengths.
  TerminalShaderUniforms({
    required this.width,
    required this.height,
    this.timeSeconds = 0.0,
    this.deltaSeconds = 0.0,
    this.frameIndex = 0,
    this.frameRate = 60.0,
    Float32List? currentCursorXywh,
    Float32List? previousCursorXywh,
    this.currentCursorArgb = 0xFFFFFFFF,
    this.previousCursorArgb = 0xFFFFFFFF,
    this.currentCursorStyle = cursorStyleBlock,
    this.timeCursorChange = 0.0,
    this.cursorVisible = true,
    this.isFocused = true,
    this.timeFocusChange = 0.0,
    this.foregroundArgb = 0xFFE6EDF3,
    this.backgroundArgb = 0xFF0D1117,
    Uint32List? palette256Argb,
    ui.Rect? regionRect,
    this.cellSize = const ui.Size(8.0, 16.0),
    Float32List? params,
    Float32List? mouseXyzw,
    Float32List? dateYmdSec,
    Float32List? channelResolutions,
  }) : currentCursorXywh = _normalizeFloatList(currentCursorXywh, 4),
       previousCursorXywh = _normalizeFloatList(previousCursorXywh, 4),
       palette256Argb = _normalizePalette(palette256Argb),
       regionRect = regionRect ?? ui.Rect.fromLTWH(0.0, 0.0, width, height),
       params = _normalizeFloatList(params, ShaderPassSpec.paramCount),
       mouseXyzw = _normalizeFloatList(mouseXyzw, 4),
       dateYmdSec = _normalizeFloatList(dateYmdSec, 4),
       channelResolutions = _normalizeFloatList(channelResolutions, 12);

  /// Creates a zero-copy per-frame uniform payload reusing already-normalized
  /// typed lists owned by the host.
  ///
  /// Any input whose length matches its canonical size is stored by reference
  /// (preserving [identical] checks for palette pre-packing caches); mismatched
  /// lengths fall back to defensive normalization.
  TerminalShaderUniforms.raw({
    required this.width,
    required this.height,
    this.timeSeconds = 0.0,
    this.deltaSeconds = 0.0,
    this.frameIndex = 0,
    this.frameRate = 60.0,
    Float32List? currentCursorXywh,
    Float32List? previousCursorXywh,
    this.currentCursorArgb = 0xFFFFFFFF,
    this.previousCursorArgb = 0xFFFFFFFF,
    this.currentCursorStyle = cursorStyleBlock,
    this.timeCursorChange = 0.0,
    this.cursorVisible = true,
    this.isFocused = true,
    this.timeFocusChange = 0.0,
    this.foregroundArgb = 0xFFE6EDF3,
    this.backgroundArgb = 0xFF0D1117,
    Uint32List? palette256Argb,
    ui.Rect? regionRect,
    this.cellSize = const ui.Size(8.0, 16.0),
    Float32List? params,
    Float32List? mouseXyzw,
    Float32List? dateYmdSec,
    Float32List? channelResolutions,
  }) : currentCursorXywh = _reuseOrNormalizeFloatList(
         currentCursorXywh,
         4,
         _zeroFloat4,
       ),
       previousCursorXywh = _reuseOrNormalizeFloatList(
         previousCursorXywh,
         4,
         _zeroFloat4,
       ),
       palette256Argb = _reuseOrNormalizePalette(palette256Argb),
       regionRect = regionRect ?? ui.Rect.fromLTWH(0.0, 0.0, width, height),
       params = _reuseOrNormalizeFloatList(
         params,
         ShaderPassSpec.paramCount,
         _zeroParams,
       ),
       mouseXyzw = _reuseOrNormalizeFloatList(mouseXyzw, 4, _zeroFloat4),
       dateYmdSec = _reuseOrNormalizeFloatList(dateYmdSec, 4, _zeroFloat4),
       channelResolutions = _reuseOrNormalizeFloatList(
         channelResolutions,
         12,
         _zeroChannels,
       );
}

Float32List _reuseOrNormalizeFloatList(
  Float32List? source,
  int length,
  Float32List fallbackZero,
) {
  if (source == null) return fallbackZero;
  if (source.length == length) return source;
  return _normalizeFloatList(source, length);
}

Uint32List _reuseOrNormalizePalette(Uint32List? source) {
  if (source == null) return TerminalShaderUniforms._zeroPalette256;
  if (source.length == TerminalShaderUniforms.paletteLength) return source;
  return _normalizePalette(source);
}

Float32List _normalizeFloatList(Float32List? source, int length) {
  final copy = Float32List(length);
  if (source == null) return copy;
  final count = source.length < length ? source.length : length;
  for (var i = 0; i < count; i++) {
    copy[i] = source[i];
  }
  return copy;
}

Uint32List _normalizePalette(Uint32List? source) {
  final copy = Uint32List(TerminalShaderUniforms.paletteLength);
  if (source == null) return copy;
  final count = source.length < copy.length ? source.length : copy.length;
  for (var i = 0; i < count; i++) {
    copy[i] = source[i];
  }
  return copy;
}

bool _floatListEquals(Float32List a, Float32List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _passListEquals(List<ShaderPassSpec> a, List<ShaderPassSpec> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

double _clampFinite(
  double? value, {
  required double min,
  required double max,
  required double fallback,
}) => value == null || !value.isFinite ? fallback : value.clamp(min, max);
