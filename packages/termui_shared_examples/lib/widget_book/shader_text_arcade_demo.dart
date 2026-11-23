import 'dart:math' as math;
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;

import 'example_base.dart';

/// Interactive showcase scenes inside the Shader Text Arcade.
enum ShaderArcadeScene {
  /// Scene 1: Dragging fire over hidden golden runes (`one_ring`).
  oneRing(1, 'One Ring', 'Dragging Fire Over Hidden Golden Runes'),

  /// Scene 2: Black Hole spaghettification & Top-Down Hurricane (`vortex`).
  vortext(2, 'Vortext', 'Black Hole & Top-Down Hurricane Physics'),

  /// Scene 3: 2-stage cryo freeze & crystal shatter (`ice_frost`).
  frostShatter(3, 'Frost', 'Cryo Freeze & Crystal Shatter'),

  /// Scene 4: Glowing glass neon marquee & chromatic tear (`neon_pulse`, `glitch_tear`).
  neonGlitch(4, 'Neon/Glitch', 'Neon Glass Glow & Glitch Tear Burst'),

  /// Scene 5: Anvil typing forge with per-character welding sparks (`forge_spark`).
  forge(5, 'Forge', 'Anvil Typing Forge & Welding Sparks');

  /// 1-based hotkey number (`1`–`5`).
  final int number;

  /// Compact tab label shown in the clickable top tab bar.
  final String tabLabel;

  /// Descriptive subtitle for the active stage.
  final String subtitle;

  const ShaderArcadeScene(this.number, this.tabLabel, this.subtitle);
}

/// Gravity / fluid mode for Scene 2 (`Vortext`).
enum VortextMode {
  /// Keplerian inward spiral with radial spaghettification and permanent swallow.
  blackHole('Black Hole'),

  /// Top-down counter-clockwise hurricane dragging letters around the calm eye.
  hurricane('Hurricane');

  /// Human-readable label shown in the stage HUD.
  final String label;

  const VortextMode(this.label);
}

/// Lifecycle stage for Scene 3 (`Frost & Shatter`).
enum FrostPhase {
  /// Clear unfrozen headline (`frostIntensity == 0.0`).
  warm('WARM'),

  /// Frost crystals actively creeping across the headline (`0.0 -> 1.25`).
  freezing('FREEZING'),

  /// Solid ice crystal shell with brittle cryo shiver waiting for shatter.
  frozen('FROZEN'),

  /// Frozen letters exploding into tumbling icy shards under gravity.
  shattering('SHATTERING');

  /// Compact uppercase label for the Scene 3 status readout.
  final String label;

  const FrostPhase(this.label);
}

final class _CharGridPos {
  final int col;
  final int row;

  const _CharGridPos(this.col, this.row);
}

final class _VortexParticle {
  final int homeCol;
  final int homeRow;
  double posX;
  double posY;
  double velX = 0.0;
  double velY = 0.0;
  double bandRadius;
  double phaseOffset;
  bool swallowed = false;
  double dx = 0.0;
  double dy = 0.0;
  double scaleX = 1.0;
  double scaleY = 1.0;
  double rot = 0.0;
  double alpha = 1.0;
  int zLayer = 0;

  double nextDx = 0.0;
  double nextDy = 0.0;
  double nextScaleX = 1.0;
  double nextScaleY = 1.0;
  double nextRot = 0.0;
  double nextAlpha = 1.0;

  _VortexParticle({
    required this.homeCol,
    required this.homeRow,
    required this.bandRadius,
    required this.phaseOffset,
  }) : posX = homeCol.toDouble(),
       posY = homeRow.toDouble();
}

final class _FrostShard {
  double dx = 0.0;
  double dy = 0.0;
  double vx = 0.0;
  double vy = 0.0;
  double rot = 0.0;
  double vRot = 0.0;
  double scale = 1.0;
  double alpha = 1.0;
}

List<_CharGridPos> _measureNonSpacePositions(String text) {
  final positions = <_CharGridPos>[];
  final lines = text.split('\n');
  for (var row = 0; row < lines.length; row++) {
    var col = 0;
    for (final grapheme in lines[row].characters) {
      final w = graphemeWidth(grapheme);
      if (w <= 0) continue;
      if (grapheme != ' ') {
        positions.add(_CharGridPos(col, row));
      }
      col += w;
    }
  }
  return positions;
}

List<({int col, String grapheme})> _measureLineNonSpaceGlyphs(String line) {
  final glyphs = <({int col, String grapheme})>[];
  var col = 0;
  for (final grapheme in line.characters) {
    final w = graphemeWidth(grapheme);
    if (w <= 0) continue;
    if (grapheme != ' ') {
      glyphs.add((col: col, grapheme: grapheme));
    }
    col += w;
  }
  return glyphs;
}

/// State and 25 Hz physics controller for [ShaderTextArcadeWidget].
final class ShaderTextArcadeController {
  /// Default 25 Hz physics step duration (`40 ms`), smoothed to 120–240 Hz on GPU.
  static const double defaultStepSec = 0.04;

  /// Background and cold-text color of the Scene 1 hammered-gold band so cold
  /// text stays 100% invisible until fire passes over it.
  static const Color oneRingBandBackground = Color(28, 22, 14);

  /// Scene 1 hidden Elvish inscription inside the dark-gold band (every line
  /// `<= 30` cells so nothing clips inside [oneRingContentWidth]).
  static const String ringVerse =
      'One Ring to rule them all,\n'
      'One Ring to find them,\n'
      'One Ring to bring them all,\n'
      'and in the darkness bind them.';

  /// Fixed content width (in cells) of Scene 1's One Ring band text block.
  static const int oneRingContentWidth = 34;

  /// Stage-local left column of Scene 1's One Ring text block inside the border.
  static const int oneRingBandTextLeft = 5;

  /// Stage-local top row of Scene 1's One Ring text block inside the border.
  static const int oneRingBandTextTop = 5;

  /// Total text rows inside Scene 1's One Ring band (4 verse + 1 gap + 1 prompt).
  static const int oneRingBandRows = 6;

  /// Scene 2 crisp monospace code stanza pulled into the vortex.
  static const String vortextStanza =
      'const gravity = 9.81; // event horizon\n'
      'while (orbit > 0) spiralInward(glyph);\n'
      'light.bend(spacetime, singularity);\n'
      'return photonRing.radiate(vortex);';

  /// Stage-local left column of Scene 2's padded `arcade_vortex` shader region.
  static const int vortexRegionLeft = 1;

  /// Stage-local top row of Scene 2's padded `arcade_vortex` shader region.
  static const int vortexRegionTop = 1;

  /// Total cell width of Scene 2's padded `arcade_vortex` shader region.
  static const int vortexRegionCols = 46;

  /// Total cell height of Scene 2's padded `arcade_vortex` shader region.
  static const int vortexRegionRows = 10;

  /// Stanza `(0, 0)` horizontal cell offset inside `arcade_vortex`.
  static const double vortexStanzaOffsetX = 4.0;

  /// Stanza `(0, 0)` vertical cell offset inside `arcade_vortex`.
  static const double vortexStanzaOffsetY = 3.0;

  /// Scene 3 frozen headline shattered by `Space`.
  static const String frostHeadline = 'ABSOLUTE ZERO // CRYO LOCK';

  /// Scene 3 ANSI fallback subtitle rendered beneath [frostHeadline].
  static const String frostSubtitle = 'SUB-ZERO THERMAL CHAMBER // PRESS SPACE';

  /// Scene 4 glowing neon marquee text.
  static const String neonMarquee = 'CYBERDECK SIGNAL // OVERDRIVE';

  /// Scene 4 glitching telemetry block.
  static const String glitchStatusBlock =
      'SYS.LINK : SYNCED   PKT.LOSS : 0.00%\n'
      'SHADER.IO: ACTIVE   GPU.HZ   : 120.0\n'
      'CHROMA.TX: LOCKED   BUFFER   : CLEAN';

  /// Default phrase typed letter-by-letter during Scene 5 Auto-Strike.
  static const String forgeAutoPhrase = 'STRIKE THE ANVIL';

  /// Fixed interior width (in cells) of Scene 5's anvil forge shader region.
  static const int forgeRegionCols = 44;

  /// Fixed interior height (in cells) of Scene 5's anvil forge shader region.
  static const int forgeRegionRows = 5;

  /// Row index (`0`-based from top) of the forge input line inside the region.
  static const int forgePromptRow = 2;

  /// Left cell padding before `"> "` inside Scene 5's forge shader region.
  static const int forgePromptLeftPad = 2;

  static const double _blackHoleHorizonRadius = 0.75;
  static const double _frostTargetIntensity = 1.25;
  static const double _frostRampDurationSec = 1.4;
  static const double _forgeAutoIntervalSec = 0.18;
  static const double _oneRingHeatRadius = 2.5;
  static const double _oneRingWarmThreshold = 0.08;
  static const double _oneRingLatchThreshold = 0.40;

  final math.Random _rng = math.Random(1337);
  final List<void Function()> _listeners = <void Function()>[];

  late final List<_CharGridPos> _vortextPositions;
  late final List<_VortexParticle> _vortexParticles;
  late final List<({int col, String grapheme})> _frostGlyphs;
  late final List<_FrostShard> _frostShards;
  late final List<_CharGridPos> _glitchPositions;

  int _vortextMaxCol = 38;
  bool _gpuShadersSupported;

  /// Whether the host terminal confirmed GPU shader & transform capabilities.
  bool get gpuShadersSupported => _gpuShadersSupported;

  /// Updates whether GPU shaders are supported by the host terminal.
  void setGpuShadersSupported(bool supported) {
    if (_gpuShadersSupported == supported) return;
    _gpuShadersSupported = supported;
    _notify();
  }

  /// Currently displayed arcade scene.
  ShaderArcadeScene activeScene = ShaderArcadeScene.oneRing;

  /// Accumulated simulation time in seconds.
  double simTimeSec = 0.0;

  /// Rolling keyframe epoch used to derive unique `CellTween.animationId` values.
  int keyframeEpoch = 1;

  // --- Scene 1: One Ring ---

  /// Whether the automatic sweeping figure-8 flame torch is active.
  bool autoTorch = true;

  /// Whether pointer hover ignites runes without holding the mouse button.
  bool hoverIgnite = true;

  /// Whether typing directly edits the golden prompt line.
  bool isEditingRingPrompt = false;

  /// Editable golden prompt text inside the One Ring region.
  String ringPrompt = 'speak friend and enter...';

  double _ringPulseSec = 0.0;
  double _ringResetSec = 0.0;
  final Float64List _ringCellHeat = Float64List(
    oneRingContentWidth * oneRingBandRows,
  );
  final List<bool> _ringCellLatched = List<bool>.filled(
    oneRingContentWidth * oneRingBandRows,
    false,
  );
  double _ansiTorchX = -10.0;
  double _ansiTorchY = -10.0;
  bool _ansiPointerDragging = false;
  double _ansiPointerActiveSec = 0.0;

  // --- Scene 2: Vortext ---

  /// Active vortex physics mode (`blackHole` or `hurricane`).
  VortextMode vortextMode = VortextMode.blackHole;

  /// Whether Vortext physics pull is actively stepping.
  bool vortextRunning = true;

  /// Normalized Y-up vortex center X (`[0..1]`).
  double vortexCenterU = 0.5;

  /// Normalized Y-up vortex center Y (`[0..1]`).
  double vortexCenterV = 0.5;

  bool _vortextHasMoved = false;
  double _blackHoleFlare = 0.0;

  // --- Scene 3: Frost & Shatter ---

  /// Current Scene 3 stage (`warm`, `freezing`, `frozen`, or `shattering`).
  FrostPhase frostPhase = FrostPhase.warm;

  /// Current frost shader intensity (`uParams0.x`: `0.0` warm -> `1.25` frozen).
  double frostIntensity = 0.0;

  /// Whether Scene 3 crystal shards are actively exploding.
  bool get frostShattered => frostPhase == FrostPhase.shattering;

  double _frostElapsedSec = 0.0;

  // --- Scene 4: Neon & Glitch ---

  /// Remaining chromatic glitch burst duration in seconds.
  double glitchBurstSec = 0.0;

  int _glitchSeed = 1;

  // --- Scene 5: Anvil Typing Forge ---

  /// Interactive anvil forge text line for Scene 5.
  String forgePrompt = forgeAutoPhrase;

  /// Normalized Y-up origin X of the latest per-character forge spark (`uParams0.x`).
  double strikeOriginU = 0.5;

  /// Normalized Y-up origin Y of the latest per-character forge spark (`uParams0.y`).
  double strikeOriginV = 0.5;

  /// Current manual forge strike pulse age in seconds (`0.0` = idle/cursor auto).
  double strikeAgeSec = 0.0;

  /// Manual forge strike intensity (`uParams0.w`).
  double strikeIntensity = 1.25;

  /// Whether Scene 5 auto-strikes [forgeAutoPhrase] letter-by-letter.
  bool forgeAutoStrike = false;

  /// Non-space character index inside `"> $forgePrompt"` that was most recently
  /// struck (receives the single-letter recoil bounce).
  int lastStruckCharIndex = -1;

  /// Monotonic animation ID bumped strictly when a new character is struck.
  int forgeStrikeAnimId = 1;

  double _forgeAutoAccumSec = 0.0;
  int _forgeAutoNextIndex = 0;
  final List<double> _forgeCharAges = <double>[];

  /// Read-only view of per-character strike heat ages (seconds since strike,
  /// capped at `1.0`) for each grapheme in [forgePrompt].
  List<double> get forgeCharAges => List<double>.unmodifiable(_forgeCharAges);

  /// Strike heat age in seconds for grapheme [index] in [forgePrompt].
  double forgeCharAgeAt(int index) =>
      (index >= 0 && index < _forgeCharAges.length)
      ? _forgeCharAges[index]
      : 1.0;

  /// Creates a [ShaderTextArcadeController] with initialized particle tables.
  ShaderTextArcadeController({
    ShaderArcadeScene initialScene = ShaderArcadeScene.oneRing,
    bool gpuShadersSupported = false,
  }) : activeScene = initialScene,
       _gpuShadersSupported = gpuShadersSupported {
    _vortextPositions = _measureNonSpacePositions(vortextStanza);
    _vortextMaxCol = _maxColOf(_vortextPositions);
    _vortexParticles = _createVortexParticles();

    _frostGlyphs = _measureLineNonSpaceGlyphs(frostHeadline);
    _frostShards = List<_FrostShard>.generate(
      _frostGlyphs.length,
      (_) => _FrostShard(),
    );

    _glitchPositions = _measureNonSpacePositions(glitchStatusBlock);
    _forgeCharAges.addAll(
      List<double>.filled(forgePrompt.characters.length, 1.0),
    );
  }

  /// Number of letters permanently swallowed by the Black Hole since last reset.
  int get swallowedParticleCount {
    var count = 0;
    for (final p in _vortexParticles) {
      if (p.swallowed) count++;
    }
    return count;
  }

  /// Total number of letter particles in Scene 2 (`Vortext`).
  int get totalVortexParticleCount => _vortexParticles.length;

  /// Registers a change listener notified on state or physics updates.
  void addListener(void Function() listener) => _listeners.add(listener);

  /// Removes a previously registered listener.
  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// Clears all listeners cleanly.
  void dispose() => _listeners.clear();

  void _notify() {
    for (final listener in [..._listeners]) {
      listener();
    }
  }

  static int _maxColOf(List<_CharGridPos> positions) {
    var maxCol = 1;
    for (final p in positions) {
      if (p.col > maxCol) maxCol = p.col;
    }
    return maxCol;
  }

  double _vortexCenterStanzaX() =>
      vortexCenterU * vortexRegionCols - vortexStanzaOffsetX;

  double _vortexCenterStanzaY() =>
      (1.0 - vortexCenterV) * vortexRegionRows - vortexStanzaOffsetY;

  List<_VortexParticle> _createVortexParticles() {
    final cx = _vortexCenterStanzaX();
    final cy = _vortexCenterStanzaY();
    return [
      for (var i = 0; i < _vortextPositions.length; i++)
        _initVortexParticle(_vortextPositions[i], cx, cy, i),
    ];
  }

  _VortexParticle _initVortexParticle(
    _CharGridPos pos,
    double cx,
    double cy,
    int index,
  ) {
    final dx = pos.col - cx;
    final dy = (pos.row - cy) * 2.0;
    final r = math.max(1.2, math.sqrt(dx * dx + dy * dy));
    final band = 3.2 + (r % 9.5);
    return _VortexParticle(
      homeCol: pos.col,
      homeRow: pos.row,
      bandRadius: band,
      phaseOffset: (index * 0.37) % (math.pi * 2.0),
    );
  }

  /// Switches to [scene] and notifies listeners.
  void selectScene(ShaderArcadeScene scene) {
    if (activeScene == scene) return;
    activeScene = scene;
    isEditingRingPrompt = false;
    _notify();
  }

  /// Advances to the next scene, wrapping around from Scene 5 to Scene 1.
  void nextScene() {
    const scenes = ShaderArcadeScene.values;
    selectScene(scenes[(activeScene.index + 1) % scenes.length]);
  }

  /// Moves to the previous scene, wrapping around from Scene 1 to Scene 5.
  void previousScene() {
    const scenes = ShaderArcadeScene.values;
    selectScene(
      scenes[(activeScene.index - 1 + scenes.length) % scenes.length],
    );
  }

  /// Toggles the Scene 1 automatic sweeping torch.
  void toggleAutoTorch() {
    autoTorch = !autoTorch;
    _notify();
  }

  /// Toggles Scene 1 hover-ignite vs click-drag-only mode.
  void toggleHoverIgnite() {
    hoverIgnite = !hoverIgnite;
    _notify();
  }

  /// Toggles Scene 2 between [VortextMode.blackHole] and [VortextMode.hurricane].
  void toggleVortextMode() {
    vortextMode = vortextMode == VortextMode.blackHole
        ? VortextMode.hurricane
        : VortextMode.blackHole;
    _resetVortexParticles(notify: false);
    vortextRunning = true;
    _notify();
  }

  /// Toggles Scene 2 physics pull vs paused state.
  void toggleVortextRunning() {
    vortextRunning = !vortextRunning;
    _notify();
  }

  /// Advances Scene 3 through `warm -> freezing -> frozen -> shattering -> warm`.
  void advanceFrostCycle() {
    switch (frostPhase) {
      case FrostPhase.warm:
        frostPhase = FrostPhase.freezing;
        frostIntensity = 0.05;
        _frostElapsedSec = 0.0;
        _notify();
      case FrostPhase.freezing:
        if (frostIntensity >= 0.75) {
          triggerFrostShatter();
        } else {
          frostIntensity = _frostTargetIntensity;
          frostPhase = FrostPhase.frozen;
          _notify();
        }
      case FrostPhase.frozen:
        triggerFrostShatter();
      case FrostPhase.shattering:
        _resetFrost();
    }
  }

  /// Triggers Scene 3 crystal shatter physics explosion immediately.
  void triggerFrostShatter() {
    frostPhase = FrostPhase.shattering;
    frostIntensity = math.max(frostIntensity, 1.0);
    _frostElapsedSec = 0.0;
    keyframeEpoch = (keyframeEpoch + 1) & 0xFF;
    final center = _frostShards.length * 0.5;
    for (var i = 0; i < _frostShards.length; i++) {
      final offset = i - center;
      final spread = offset * 1.45 + (_rng.nextDouble() - 0.5) * 6.5;
      _frostShards[i]
        ..dx = 0.0
        ..dy = 0.0
        ..vx = spread
        ..vy = -8.0 - _rng.nextDouble() * 9.0
        ..rot = 0.0
        ..vRot = (_rng.nextDouble() - 0.5) * 14.0
        ..scale = 0.75 + _rng.nextDouble() * 0.65
        ..alpha = 1.0;
    }
    _notify();
  }

  /// Triggers Scene 4 chromatic tear & horizontal slice jitter burst.
  void triggerGlitchBurst() {
    glitchBurstSec = 1.15;
    _glitchSeed = (_glitchSeed + 1) & 0xFFFF;
    keyframeEpoch = (keyframeEpoch + 1) & 0xFF;
    _notify();
  }

  /// Toggles letter-by-letter auto-strike of [forgeAutoPhrase] in Scene 5.
  void toggleForgeAutoStrike() {
    if (forgeAutoStrike) {
      forgeAutoStrike = false;
      _notify();
      return;
    }
    forgeAutoStrike = true;
    forgePrompt = '';
    _forgeCharAges.clear();
    _forgeAutoNextIndex = 0;
    _forgeAutoAccumSec = 0.0;
    _strikeNextAutoCharacter(notify: true);
  }

  /// Triggers a tight per-character forge spark burst centered on ([u], [v])
  /// or on the last character of [forgePrompt].
  void triggerForgeStrike({double? u, double? v, int? struckCharIndex}) {
    final (cellU, cellV, nonSpaceIdx) = _lastForgeCharMetrics();
    strikeOriginU = (u ?? cellU).clamp(0.02, 0.98);
    strikeOriginV = (v ?? cellV).clamp(0.08, 0.92);
    strikeAgeSec = 0.001;
    strikeIntensity = 1.35;
    lastStruckCharIndex = struckCharIndex ?? nonSpaceIdx;
    forgeStrikeAnimId = (forgeStrikeAnimId % 0x7FFF) + 1;
    keyframeEpoch = (keyframeEpoch + 1) & 0xFF;
    _notify();
  }

  (double, double, int) _lastForgeCharMetrics() {
    final fullLine = '> $forgePrompt';
    var col = forgePromptLeftPad;
    var lastCol = forgePromptLeftPad + 1;
    var nonSpaceCount = 0;
    for (final grapheme in fullLine.characters) {
      final w = graphemeWidth(grapheme);
      if (w <= 0) continue;
      lastCol = col;
      if (grapheme != ' ') nonSpaceCount++;
      col += w;
    }
    final u = (lastCol + 0.5) / forgeRegionCols;
    final v = 1.0 - (forgePromptRow + 0.5) / forgeRegionRows;
    return (u, v, nonSpaceCount - 1);
  }

  /// Resets the currently active scene to its clean initial state.
  void resetActiveScene() {
    switch (activeScene) {
      case ShaderArcadeScene.oneRing:
        ringPrompt = 'speak friend and enter...';
        isEditingRingPrompt = false;
        _ringPulseSec = 0.0;
        _ringResetSec = 0.16;
        _resetOneRingAnsiHeat();
      case ShaderArcadeScene.vortext:
        vortexCenterU = 0.5;
        vortexCenterV = 0.5;
        _resetVortexParticles(notify: false);
      case ShaderArcadeScene.frostShatter:
        _resetFrost(notify: false);
      case ShaderArcadeScene.neonGlitch:
        glitchBurstSec = 0.0;
      case ShaderArcadeScene.forge:
        forgePrompt = '';
        _forgeCharAges.clear();
        forgeAutoStrike = false;
        _forgeAutoAccumSec = 0.0;
        _forgeAutoNextIndex = 0;
        strikeAgeSec = 0.0;
        lastStruckCharIndex = -1;
    }
    _notify();
  }

  void _resetVortexParticles({bool notify = true}) {
    _vortextHasMoved = false;
    _blackHoleFlare = 0.0;
    final cx = _vortexCenterStanzaX();
    final cy = _vortexCenterStanzaY();
    for (var i = 0; i < _vortexParticles.length; i++) {
      final pos = _vortextPositions[i];
      final dx = pos.col - cx;
      final dy = (pos.row - cy) * 2.0;
      final r = math.max(1.2, math.sqrt(dx * dx + dy * dy));
      _vortexParticles[i]
        ..posX = pos.col.toDouble()
        ..posY = pos.row.toDouble()
        ..velX = 0.0
        ..velY = 0.0
        ..bandRadius = 3.2 + (r % 9.5)
        ..phaseOffset = (i * 0.37) % (math.pi * 2.0)
        ..swallowed = false
        ..dx = 0.0
        ..dy = 0.0
        ..scaleX = 1.0
        ..scaleY = 1.0
        ..rot = 0.0
        ..alpha = 1.0
        ..zLayer = 0
        ..nextDx = 0.0
        ..nextDy = 0.0
        ..nextScaleX = 1.0
        ..nextScaleY = 1.0
        ..nextRot = 0.0
        ..nextAlpha = 1.0;
    }
    if (notify) _notify();
  }

  void _resetFrost({bool notify = true}) {
    frostPhase = FrostPhase.warm;
    frostIntensity = 0.0;
    _frostElapsedSec = 0.0;
    for (final shard in _frostShards) {
      shard
        ..dx = 0.0
        ..dy = 0.0
        ..vx = 0.0
        ..vy = 0.0
        ..rot = 0.0
        ..vRot = 0.0
        ..scale = 1.0
        ..alpha = 1.0;
    }
    if (notify) _notify();
  }

  /// Handles keyboard input for scene navigation and per-scene controls.
  ///
  /// Returns `true` when the key event was consumed.
  bool handleKeyEvent(ui.KeyEvent event) {
    if (activeScene == ShaderArcadeScene.oneRing && isEditingRingPrompt) {
      return _handleRingPromptTyping(event);
    }
    if (_handleSceneSwitchKey(event)) return true;
    return switch (activeScene) {
      ShaderArcadeScene.oneRing => _handleOneRingKey(event),
      ShaderArcadeScene.vortext => _handleVortextKey(event),
      ShaderArcadeScene.frostShatter => _handleFrostKey(event),
      ShaderArcadeScene.neonGlitch => _handleNeonGlitchKey(event),
      ShaderArcadeScene.forge => _handleForgeKey(event),
    };
  }

  bool _handleSceneSwitchKey(ui.KeyEvent event) => switch (event.key) {
    '1' => _selectAndConsume(ShaderArcadeScene.oneRing),
    '2' => _selectAndConsume(ShaderArcadeScene.vortext),
    '3' => _selectAndConsume(ShaderArcadeScene.frostShatter),
    '4' => _selectAndConsume(ShaderArcadeScene.neonGlitch),
    '5' => _selectAndConsume(ShaderArcadeScene.forge),
    '[' => _runAndConsume(previousScene),
    ']' => _runAndConsume(nextScene),
    _ => false,
  };

  bool _selectAndConsume(ShaderArcadeScene scene) {
    selectScene(scene);
    return true;
  }

  bool _runAndConsume(void Function() action) {
    action();
    return true;
  }

  bool _handleOneRingKey(ui.KeyEvent event) {
    if (event.type == ui.KeyType.enter || event.key == '\n') {
      isEditingRingPrompt = true;
      _notify();
      return true;
    }
    return switch (event.key) {
      'a' || 'A' => _runAndConsume(toggleAutoTorch),
      'h' || 'H' => _runAndConsume(toggleHoverIgnite),
      'r' || 'R' => _runAndConsume(resetActiveScene),
      ' ' => _runAndConsume(() {
        _ringPulseSec = 0.65;
        _notify();
      }),
      _ => false,
    };
  }

  bool _handleRingPromptTyping(ui.KeyEvent event) {
    if (event.type == ui.KeyType.enter ||
        event.type == ui.KeyType.escape ||
        event.key == '\n') {
      isEditingRingPrompt = false;
      _notify();
      return true;
    }
    if (event.type == ui.KeyType.backspace) {
      if (ringPrompt.characters.isNotEmpty) {
        ringPrompt = ringPrompt.characters.skipLast(1).toString();
        _notify();
      }
      return true;
    }
    if (_isPrintableInput(event) && ringPrompt.characters.length < 30) {
      ringPrompt = '$ringPrompt${event.key}';
      _notify();
      return true;
    }
    return false;
  }

  bool _handleVortextKey(ui.KeyEvent event) => switch (event.key) {
    ' ' => _runAndConsume(toggleVortextRunning),
    'm' || 'M' => _runAndConsume(toggleVortextMode),
    'r' || 'R' => _runAndConsume(resetActiveScene),
    _ => false,
  };

  bool _handleFrostKey(ui.KeyEvent event) => switch (event.key) {
    ' ' => _runAndConsume(advanceFrostCycle),
    'r' || 'R' => _runAndConsume(resetActiveScene),
    _ => false,
  };

  bool _handleNeonGlitchKey(ui.KeyEvent event) => switch (event.key) {
    ' ' => _runAndConsume(triggerGlitchBurst),
    'r' || 'R' => _runAndConsume(resetActiveScene),
    _ => false,
  };

  bool _handleForgeKey(ui.KeyEvent event) {
    if (event.key == ' ' || event.key == 'a' || event.key == 'A') {
      toggleForgeAutoStrike();
      return true;
    }
    if (event.key == 'r' || event.key == 'R') {
      resetActiveScene();
      return true;
    }
    if (event.type == ui.KeyType.backspace) {
      forgeAutoStrike = false;
      if (forgePrompt.characters.isNotEmpty) {
        forgePrompt = forgePrompt.characters.skipLast(1).toString();
        if (_forgeCharAges.isNotEmpty) _forgeCharAges.removeLast();
      }
      triggerForgeStrike();
      return true;
    }
    if (_isPrintableInput(event) &&
        event.key != 'q' &&
        event.key != 'Q' &&
        forgePrompt.characters.length < 36) {
      forgeAutoStrike = false;
      forgePrompt = '$forgePrompt${event.key}';
      _forgeCharAges.add(event.key == ' ' ? 1.0 : 0.0);
      triggerForgeStrike();
      return true;
    }
    return false;
  }

  static bool _isPrintableInput(ui.KeyEvent event) {
    if (event.type != ui.KeyType.character) return false;
    if (event.modifiers.contains(ui.Modifier.control) ||
        event.modifiers.contains(ui.Modifier.alt)) {
      return false;
    }
    final chars = event.key.characters;
    return chars.length == 1 && event.key.codeUnitAt(0) >= 0x20;
  }

  /// Handles pointer interaction inside the active scene's primary stage.
  void handleStagePointer(
    ui.MouseEvent event,
    int localX,
    int localY,
    int width,
    int height,
  ) {
    switch (activeScene) {
      case ShaderArcadeScene.oneRing:
        _handleOneRingPointer(event, localX, localY);
      case ShaderArcadeScene.vortext:
        _handleVortextPointer(event, localX, localY);
      case ShaderArcadeScene.frostShatter:
        if (event.type == ui.MouseEventType.press) advanceFrostCycle();
      case ShaderArcadeScene.neonGlitch:
        if (event.type == ui.MouseEventType.press) triggerGlitchBurst();
      case ShaderArcadeScene.forge:
        // Mouse events never trigger forge sparks; only typing / auto-strike do.
        break;
    }
  }

  void _handleOneRingPointer(ui.MouseEvent event, int localX, int localY) {
    final isPressOrDrag =
        event.type == ui.MouseEventType.press ||
        event.type == ui.MouseEventType.drag;
    if (isPressOrDrag && autoTorch) {
      // Pause Auto-Torch so pointer fire is the single live flame.
      autoTorch = false;
    }
    final bandX = (localX - oneRingBandTextLeft).toDouble();
    final bandY = (localY - oneRingBandTextTop).toDouble();
    if (isPressOrDrag) {
      _ansiPointerDragging = true;
      _ansiTorchX = bandX;
      _ansiTorchY = bandY;
      _ansiPointerActiveSec = 0.40;
      _applyOneRingHeat(bandX, bandY, radius: _oneRingHeatRadius, amount: 0.24);
      _notify();
      return;
    }
    if (event.type == ui.MouseEventType.release) {
      _ansiPointerDragging = false;
      return;
    }
    if (event.type == ui.MouseEventType.move && hoverIgnite) {
      _ansiTorchX = bandX;
      _ansiTorchY = bandY;
      _ansiPointerActiveSec = 0.28;
      _applyOneRingHeat(bandX, bandY, radius: _oneRingHeatRadius, amount: 0.16);
      _notify();
    }
  }

  void _handleVortextPointer(ui.MouseEvent event, int localX, int localY) {
    if (event.type == ui.MouseEventType.press ||
        event.type == ui.MouseEventType.drag) {
      final regionU = (localX - vortexRegionLeft) / (vortexRegionCols - 1);
      final regionV = 1.0 - (localY - vortexRegionTop) / (vortexRegionRows - 1);
      vortexCenterU = regionU.clamp(0.06, 0.94);
      vortexCenterV = regionV.clamp(0.08, 0.92);
      _notify();
    }
  }

  /// Advances active scene physics by [dtSec] seconds (default 25 Hz / `40 ms`).
  void stepPhysics([double dtSec = defaultStepSec]) {
    final dt = dtSec.clamp(0.005, 0.1);
    simTimeSec += dt;
    keyframeEpoch = (keyframeEpoch + 1) & 0xFF;

    switch (activeScene) {
      case ShaderArcadeScene.oneRing:
        _stepOneRing(dt);
      case ShaderArcadeScene.vortext:
        _stepVortext(dt);
      case ShaderArcadeScene.frostShatter:
        _stepFrost(dt);
      case ShaderArcadeScene.neonGlitch:
        _stepNeonGlitch(dt);
      case ShaderArcadeScene.forge:
        _stepForge(dt);
    }
    _notify();
  }

  void _stepOneRing(double dt) {
    if (_ringPulseSec > 0.0) {
      _ringPulseSec = math.max(0.0, _ringPulseSec - dt);
    }
    if (_ringResetSec > 0.0) {
      _ringResetSec = math.max(0.0, _ringResetSec - dt);
    }
    if (_ansiPointerActiveSec > 0.0) {
      _ansiPointerActiveSec = math.max(0.0, _ansiPointerActiveSec - dt);
    }
    _coolUnlatchedOneRingCells(dt);
    _heatActiveOneRingTorch(dt);
  }

  void _resetOneRingAnsiHeat() {
    _ringCellHeat.fillRange(0, _ringCellHeat.length, 0.0);
    _ringCellLatched.fillRange(0, _ringCellLatched.length, false);
    _ansiPointerDragging = false;
    _ansiPointerActiveSec = 0.0;
  }

  void _coolUnlatchedOneRingCells(double dt) {
    final decay = 0.55 * dt;
    for (var i = 0; i < _ringCellHeat.length; i++) {
      if (!_ringCellLatched[i] && _ringCellHeat[i] > 0.0) {
        _ringCellHeat[i] = math.max(0.0, _ringCellHeat[i] - decay);
      }
    }
  }

  void _heatActiveOneRingTorch(double dt) {
    if (_ringPulseSec > 0.0) {
      _applyOneRingHeat(
        (oneRingContentWidth - 1) * 0.5,
        (oneRingBandRows - 1) * 0.5,
        radius: 6.5,
        amount: 2.6 * dt,
      );
      return;
    }
    final torch = ansiOneRingTorchPosition;
    if (torch == null) return;
    _applyOneRingHeat(
      torch.x,
      torch.y,
      radius: _oneRingHeatRadius,
      amount: 2.5 * dt,
    );
  }

  void _applyOneRingHeat(
    double tx,
    double ty, {
    required double radius,
    required double amount,
  }) {
    final minCol = math.max(0, (tx - radius).floor());
    final maxCol = math.min(oneRingContentWidth - 1, (tx + radius).ceil());
    final minRow = math.max(0, (ty - radius).floor());
    final maxRow = math.min(oneRingBandRows - 1, (ty + radius).ceil());
    for (var row = minRow; row <= maxRow; row++) {
      final dy = row - ty;
      for (var col = minCol; col <= maxCol; col++) {
        final dx = col - tx;
        final dist = math.sqrt(dx * dx + dy * dy);
        if (dist > radius) continue;
        final idx = row * oneRingContentWidth + col;
        final next = math.min(
          1.0,
          _ringCellHeat[idx] + (1.0 - dist / radius) * amount,
        );
        _ringCellHeat[idx] = next;
        if (next >= _oneRingLatchThreshold) {
          _ringCellLatched[idx] = true;
          _ringCellHeat[idx] = 1.0;
        }
      }
    }
  }

  /// Current ANSI fallback heat (`[0.0 .. 1.0]`) for One Ring band cell ([col], [row]).
  double oneRingCellHeat(int col, int row) {
    if (col < 0 ||
        col >= oneRingContentWidth ||
        row < 0 ||
        row >= oneRingBandRows) {
      return 0.0;
    }
    return _ringCellHeat[row * oneRingContentWidth + col];
  }

  /// Whether One Ring band cell ([col], [row]) has permanently latched in ANSI fallback mode.
  bool oneRingCellLatched(int col, int row) {
    if (col < 0 ||
        col >= oneRingContentWidth ||
        row < 0 ||
        row >= oneRingBandRows) {
      return false;
    }
    return _ringCellLatched[row * oneRingContentWidth + col];
  }

  /// Whether at least one cell in the One Ring band is latched in ANSI fallback mode.
  bool get hasAnyLatchedOneRingRune => _ringCellLatched.any((v) => v);

  /// Current active ANSI torch coordinate in band-local `(col, row)` space, or `null` when idle.
  ({double x, double y})? get ansiOneRingTorchPosition {
    if (_ringPulseSec > 0.0) {
      return (
        x: (oneRingContentWidth - 1) * 0.5,
        y: (oneRingBandRows - 1) * 0.5,
      );
    }
    if (autoTorch) {
      final u = 0.5 + 0.34 * math.sin(simTimeSec * 1.15);
      final v = 0.5 + 0.28 * math.sin(simTimeSec * 2.3);
      return (
        x: u * (oneRingContentWidth - 1),
        y: (1.0 - v) * (oneRingBandRows - 1),
      );
    }
    if (_ansiPointerDragging || _ansiPointerActiveSec > 0.0) {
      return (x: _ansiTorchX, y: _ansiTorchY);
    }
    return null;
  }

  /// Number of shattering crystal letter shards in Scene 3 (`Frost & Shatter`).
  int get frostShardCount => _frostShards.length;

  /// Read-only snapshot of Scene 3 shard [index] for ANSI fallback grid painting.
  ({int col, String grapheme, double dx, double dy, double alpha})
  frostShardSnapshot(int index) {
    final glyph = _frostGlyphs[index];
    final shard = _frostShards[index];
    return (
      col: glyph.col,
      grapheme: glyph.grapheme,
      dx: shard.dx,
      dy: shard.dy,
      alpha: shard.alpha,
    );
  }

  /// Hot-metal -> cooled-metal ANSI/GPU style curve for Scene 5 (`Forge`) characters.
  static Style forgeStyleForAge(double ageSec) {
    if (ageSec < 0.10) {
      return const Style(
        foreground: Color(255, 252, 235),
        modifiers: Modifier.bold,
      );
    }
    if (ageSec < 0.24) {
      return const Style(
        foreground: Color(255, 200, 48),
        modifiers: Modifier.bold,
      );
    }
    if (ageSec < 0.42) {
      return const Style(foreground: Color(220, 128, 36));
    }
    return const Style(foreground: Color(210, 218, 228));
  }

  /// Returns the ANSI fallback style for a One Ring cell, or `null` when cold/hidden.
  static Style? oneRingAnsiStyle({
    required bool latched,
    required double heat,
    required int col,
    required int row,
    required double timeSec,
  }) {
    if (latched) {
      final wave =
          math.sin(timeSec * 11.5 + col * 1.7 + row * 3.1) +
          0.5 * math.sin(timeSec * 23.0 - col * 2.9 + row * 1.3);
      if (wave > 1.25) {
        return const Style(
          foreground: Color(255, 245, 185),
          background: oneRingBandBackground,
          modifiers: Modifier.bold,
        );
      }
      if (wave > -0.15) {
        return const Style(
          foreground: Color(255, 195, 38),
          background: oneRingBandBackground,
          modifiers: Modifier.bold,
        );
      }
      return const Style(
        foreground: Color(220, 88, 12),
        background: oneRingBandBackground,
      );
    }
    if (heat >= _oneRingWarmThreshold) {
      return const Style(
        foreground: Color(135, 45, 12),
        background: oneRingBandBackground,
      );
    }
    return null;
  }

  /// Returns the ANSI fallback freeze style sweeping inward from left/right edges.
  static Style frostAnsiStyle({
    required double progress,
    required int col,
    required int lineWidth,
    required bool frozen,
    required double timeSec,
  }) {
    final half = math.max(1.0, (lineWidth - 1) * 0.5);
    final edgeDist = 1.0 - ((col - half).abs() / half).clamp(0.0, 1.0);
    final localFreeze = ((progress * 1.45) - edgeDist * 0.45).clamp(0.0, 1.0);
    if (localFreeze < 0.25) {
      return const Style(foreground: Color(225, 232, 242));
    }
    if (localFreeze < 0.70) {
      return const Style(foreground: Color(135, 215, 255));
    }
    final glintTick = (timeSec * 12.0).floor();
    final isGlint =
        (frozen || localFreeze >= 0.85) &&
        ((col * 13 + glintTick * 7) % 11 == 0);
    if (isGlint) {
      return const Style(
        foreground: Color(255, 255, 255),
        modifiers: Modifier.bold,
      );
    }
    return const Style(
      foreground: Color(215, 250, 255),
      modifiers: Modifier.bold,
    );
  }

  /// Returns the cooling ANSI style for a shattering Scene 3 crystal shard.
  static Style frostShardAnsiStyle(double alpha) {
    if (alpha >= 0.65) {
      return const Style(
        foreground: Color(215, 250, 255),
        modifiers: Modifier.bold,
      );
    }
    if (alpha >= 0.35) {
      return const Style(foreground: Color(120, 205, 250));
    }
    return const Style(
      foreground: Color(92, 118, 140),
      modifiers: Modifier.dim,
    );
  }

  void _stepVortext(double dt) {
    if (_blackHoleFlare > 0.0) {
      _blackHoleFlare = math.max(0.0, _blackHoleFlare - dt * 2.2);
    }
    if (!vortextRunning) return;
    _vortextHasMoved = true;
    final bhX = _vortexCenterStanzaX();
    final bhY = _vortexCenterStanzaY();
    if (vortextMode == VortextMode.blackHole) {
      _stepBlackHole(dt, bhX, bhY);
    } else {
      _stepHurricane(dt, bhX, bhY);
    }
  }

  void _stepBlackHole(double dt, double bhX, double bhY) {
    const tweenDt = defaultStepSec * 1.35;
    const maxSpeed = 14.0;
    final maxR = math.max(8.0, _vortextMaxCol * 0.6);
    final drag = math.exp(-2.2 * dt);

    for (final p in _vortexParticles) {
      if (p.swallowed) {
        _assignSwallowedPose(p, bhX, bhY);
        continue;
      }
      final ax = bhX - p.posX;
      final ay = (bhY - p.posY) * 2.0;
      final r = math.sqrt(ax * ax + ay * ay);
      if (r <= _blackHoleHorizonRadius) {
        _swallowParticle(p, bhX, bhY);
        continue;
      }
      final inX = ax / r;
      final inY = ay / r;
      final grav = 4.5 + 14.0 / (r + 1.5);
      final swirl = 10.0 / math.pow(r + 1.8, 0.75);
      final accelX = inX * grav - inY * swirl;
      final accelY = (inY * grav + inX * swirl) * 0.5;
      p.velX = (p.velX + accelX * dt) * drag;
      p.velY = (p.velY + accelY * dt) * drag;
      _clampAspectVelocity(p, maxSpeed);
      p.posX += p.velX * dt;
      p.posY += p.velY * dt;

      final postR = _aspectDistance(bhX, bhY, p.posX, p.posY);
      if (postR <= _blackHoleHorizonRadius) {
        _swallowParticle(p, bhX, bhY);
        continue;
      }
      _assignBlackHolePose(p, bhX, bhY, maxR, p.posX, p.posY, postR, false);
      final nextX = p.posX + p.velX * tweenDt;
      final nextY = p.posY + p.velY * tweenDt;
      final nextR = _aspectDistance(bhX, bhY, nextX, nextY);
      if (nextR <= _blackHoleHorizonRadius) {
        p
          ..nextDx = bhX - p.homeCol
          ..nextDy = bhY - p.homeRow
          ..nextScaleX = 0.0
          ..nextScaleY = 0.0
          ..nextRot = p.rot
          ..nextAlpha = 0.0;
      } else {
        _assignBlackHolePose(p, bhX, bhY, maxR, nextX, nextY, nextR, true);
      }
    }
  }

  void _swallowParticle(_VortexParticle p, double bhX, double bhY) {
    p
      ..swallowed = true
      ..posX = bhX
      ..posY = bhY
      ..velX = 0.0
      ..velY = 0.0;
    _blackHoleFlare = math.min(1.0, _blackHoleFlare + 0.45);
    _assignSwallowedPose(p, bhX, bhY);
  }

  static double _aspectDistance(double x0, double y0, double x1, double y1) {
    final dx = x0 - x1;
    final dy = (y0 - y1) * 2.0;
    return math.sqrt(dx * dx + dy * dy);
  }

  static void _clampAspectVelocity(_VortexParticle p, double maxSpeed) {
    final speed = math.sqrt(p.velX * p.velX + (p.velY * 2.0) * (p.velY * 2.0));
    if (speed <= maxSpeed || speed <= 1e-6) return;
    final scale = maxSpeed / speed;
    p.velX *= scale;
    p.velY *= scale;
  }

  static void _assignSwallowedPose(_VortexParticle p, double bhX, double bhY) {
    final dx = bhX - p.homeCol;
    final dy = bhY - p.homeRow;
    p
      ..dx = dx
      ..dy = dy
      ..scaleX = 0.0
      ..scaleY = 0.0
      ..alpha = 0.0
      ..zLayer = 2
      ..nextDx = dx
      ..nextDy = dy
      ..nextScaleX = 0.0
      ..nextScaleY = 0.0
      ..nextRot = p.rot
      ..nextAlpha = 0.0;
  }

  static void _assignBlackHolePose(
    _VortexParticle p,
    double bhX,
    double bhY,
    double maxR,
    double posX,
    double posY,
    double r,
    bool isNext,
  ) {
    final dx = posX - p.homeCol;
    final dy = posY - p.homeRow;
    final proximity = 1.0 - (r / maxR).clamp(0.0, 1.0);
    final sx = (1.0 + 1.4 * proximity * proximity).clamp(1.0, 2.4);
    final sy = (1.0 - 0.65 * proximity).clamp(0.35, 1.0);
    final rot = math.atan2(bhY - posY, bhX - posX);
    final alpha = ((r - _blackHoleHorizonRadius) / 1.8).clamp(0.15, 1.0);
    if (isNext) {
      p
        ..nextDx = dx
        ..nextDy = dy
        ..nextScaleX = sx
        ..nextScaleY = sy
        ..nextRot = rot
        ..nextAlpha = alpha;
    } else {
      p
        ..dx = dx
        ..dy = dy
        ..scaleX = sx
        ..scaleY = sy
        ..rot = rot
        ..alpha = alpha
        ..zLayer = 2;
    }
  }

  void _stepHurricane(double dt, double bhX, double bhY) {
    const tweenDt = defaultStepSec * 1.35;
    const maxSpeed = 16.0;
    final blend = math.min(1.0, dt * 4.5);

    for (final p in _vortexParticles) {
      final ax = bhX - p.posX;
      final ay = (bhY - p.posY) * 2.0;
      final r = math.max(0.25, math.sqrt(ax * ax + ay * ay));
      final inX = ax / r;
      final inY = ay / r;
      final targetR =
          p.bandRadius + math.sin(simTimeSec * 1.4 + p.phaseOffset) * 0.75;
      final radialPull = (r - targetR).clamp(-8.0, 8.0) * 2.8;
      final windSpeed = 14.0 / math.pow(r * 0.22 + 0.75, 0.55);
      final desiredVx = inX * radialPull - inY * windSpeed;
      final desiredVy = (inY * radialPull + inX * windSpeed) * 0.5;
      p.velX += (desiredVx - p.velX) * blend;
      p.velY += (desiredVy - p.velY) * blend;
      _clampAspectVelocity(p, maxSpeed);
      p.posX += p.velX * dt;
      p.posY += p.velY * dt;

      final rot = math.atan2(p.velY, p.velX);
      _assignHurricanePose(p, p.posX, p.posY, rot, false);
      _assignHurricanePose(
        p,
        p.posX + p.velX * tweenDt,
        p.posY + p.velY * tweenDt,
        rot,
        true,
      );
    }
  }

  static void _assignHurricanePose(
    _VortexParticle p,
    double posX,
    double posY,
    double rot,
    bool isNext,
  ) {
    final dx = posX - p.homeCol;
    final dy = posY - p.homeRow;
    if (isNext) {
      p
        ..nextDx = dx
        ..nextDy = dy
        ..nextScaleX = 1.08
        ..nextScaleY = 0.92
        ..nextRot = rot
        ..nextAlpha = 1.0;
    } else {
      p
        ..dx = dx
        ..dy = dy
        ..scaleX = 1.08
        ..scaleY = 0.92
        ..rot = rot
        ..alpha = 1.0
        ..zLayer = 2;
    }
  }

  void _stepFrost(double dt) {
    switch (frostPhase) {
      case FrostPhase.warm:
      case FrostPhase.frozen:
        return;
      case FrostPhase.freezing:
        final step = (_frostTargetIntensity / _frostRampDurationSec) * dt;
        frostIntensity = (frostIntensity + step).clamp(
          0.0,
          _frostTargetIntensity,
        );
        if (frostIntensity >= _frostTargetIntensity) {
          frostPhase = FrostPhase.frozen;
        }
      case FrostPhase.shattering:
        _stepFrostShards(dt);
    }
  }

  void _stepFrostShards(double dt) {
    const gravity = 30.0;
    _frostElapsedSec += dt;
    // Keep frost glaze visible briefly on the region, then fade cleanly out.
    frostIntensity = (_frostTargetIntensity * (1.0 - _frostElapsedSec / 0.55))
        .clamp(0.0, _frostTargetIntensity);
    for (final shard in _frostShards) {
      shard
        ..dx += shard.vx * dt
        ..dy += shard.vy * dt + 0.5 * gravity * dt * dt
        ..vy += gravity * dt
        ..rot += shard.vRot * dt
        ..alpha = (1.0 - _frostElapsedSec / 2.0).clamp(0.0, 1.0);
    }
    if (_frostElapsedSec >= 2.0) {
      _resetFrost(notify: false);
    }
  }

  void _stepNeonGlitch(double dt) {
    if (glitchBurstSec > 0.0) {
      glitchBurstSec = math.max(0.0, glitchBurstSec - dt);
      _glitchSeed = (_glitchSeed + 7) & 0xFFFF;
    }
  }

  void _stepForge(double dt) {
    for (var i = 0; i < _forgeCharAges.length; i++) {
      if (_forgeCharAges[i] < 1.0) {
        _forgeCharAges[i] = math.min(1.0, _forgeCharAges[i] + dt);
      }
    }
    if (strikeAgeSec > 0.0) {
      strikeAgeSec += dt;
      if (strikeAgeSec >= 0.58) {
        strikeAgeSec = 0.0;
      }
    }
    if (!forgeAutoStrike) return;
    _forgeAutoAccumSec += dt;
    if (_forgeAutoAccumSec < _forgeAutoIntervalSec) return;
    _forgeAutoAccumSec -= _forgeAutoIntervalSec;
    _strikeNextAutoCharacter(notify: false);
  }

  void _strikeNextAutoCharacter({required bool notify}) {
    final chars = forgeAutoPhrase.characters.toList();
    if (_forgeAutoNextIndex >= chars.length) {
      forgeAutoStrike = false;
      if (notify) _notify();
      return;
    }
    final ch = chars[_forgeAutoNextIndex];
    _forgeAutoNextIndex++;
    forgePrompt = '$forgePrompt$ch';
    _forgeCharAges.add(ch == ' ' ? 1.0 : 0.0);
    if (ch != ' ') {
      final (cellU, cellV, nonSpaceIdx) = _lastForgeCharMetrics();
      strikeOriginU = cellU.clamp(0.02, 0.98);
      strikeOriginV = cellV.clamp(0.08, 0.92);
      strikeAgeSec = 0.001;
      strikeIntensity = 1.35;
      lastStruckCharIndex = nonSpaceIdx;
      forgeStrikeAnimId = (forgeStrikeAnimId % 0x7FFF) + 1;
    }
    if (notify) _notify();
  }

  // --- Shader Uniform Builders (`uParams0` + `uParams1`) ---

  /// Returns `uParams0..1` for Scene 1 (`one_ring`).
  Float32List oneRingParams() {
    final resetFlag = _ringResetSec > 0.0 ? 1.0 : 0.0;
    final editFlag = isEditingRingPrompt ? 1.0 : 0.0;
    if (_ringPulseSec > 0.0) {
      final power = (0.8 + _ringPulseSec * 1.1).clamp(0.6, 1.5);
      return Float32List.fromList([
        0.5,
        0.5,
        0.34,
        power,
        resetFlag,
        editFlag,
        0,
        0,
      ]);
    }
    if (autoTorch) {
      final u = 0.5 + 0.34 * math.sin(simTimeSec * 1.15);
      final v = 0.5 + 0.28 * math.sin(simTimeSec * 2.3);
      return Float32List.fromList([u, v, 0.20, 1.0, resetFlag, editFlag, 0, 0]);
    }
    return Float32List.fromList([
      0.0,
      0.0,
      0.20,
      hoverIgnite ? 0.85 : 0.0,
      resetFlag,
      editFlag,
      0,
      0,
    ]);
  }

  /// Returns `uParams0..1` for Scene 2 (`vortex`).
  Float32List vortexParams() {
    final baseIntensity = vortextRunning ? 1.20 : 0.90;
    final intensity = vortextMode == VortextMode.blackHole
        ? baseIntensity + _blackHoleFlare * 0.75
        : baseIntensity;
    return Float32List.fromList([
      vortexCenterU,
      vortexCenterV,
      intensity,
      vortextMode == VortextMode.hurricane ? 1.0 : 0.0,
      0,
      0,
      0,
      0,
    ]);
  }

  /// Returns `uParams0..1` for Scene 3 (`ice_frost`).
  Float32List frostParams() =>
      Float32List.fromList([frostIntensity, 0, 0, 0, 0, 0, 0, 0]);

  /// Returns `uParams0..1` for Scene 4 (`neon_pulse`).
  Float32List neonParams() {
    final boost = glitchBurstSec > 0.0 ? 0.45 : 0.0;
    return Float32List.fromList([
      2.6 + boost * 1.8,
      1.18 + boost,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
  }

  /// Returns `uParams0..1` for Scene 4 (`glitch_tear`).
  Float32List glitchParams() {
    final strength = glitchBurstSec > 0.0
        ? (1.35 + glitchBurstSec * 1.05)
        : 0.45;
    return Float32List.fromList([strength, 0, 0, 0, 0, 0, 0, 0]);
  }

  /// Returns `uParams0..1` for Scene 5 (`forge_spark`).
  Float32List forgeParams() => Float32List.fromList([
    strikeOriginU,
    strikeOriginV,
    strikeAgeSec,
    strikeIntensity,
    0,
    0,
    0,
    0,
  ]);

  // --- Per-Character CellTransform Builders ---

  /// Per-character transform builder for Scene 2 (`Vortext`).
  CellTransform? vortextTransformForChar(int index, String _, int animId) {
    if (!_vortextHasMoved || index < 0 || index >= _vortexParticles.length) {
      return null;
    }
    final p = _vortexParticles[index];
    if (p.swallowed) {
      return CellTransform(
        dx: p.dx,
        dy: p.dy,
        scaleX: 0.0,
        scaleY: 0.0,
        rotationRad: p.rot,
        alpha: 0.0,
        zLayer: p.zLayer,
      );
    }
    return CellTransform(
      dx: p.dx,
      dy: p.dy,
      scaleX: p.scaleX,
      scaleY: p.scaleY,
      rotationRad: p.rot,
      alpha: p.alpha,
      zLayer: p.zLayer,
      tween: CellTween(
        animationId: animId,
        endDx: p.nextDx,
        endDy: p.nextDy,
        endScaleX: p.nextScaleX,
        endScaleY: p.nextScaleY,
        endRotationRad: p.nextRot,
        endAlpha: p.nextAlpha,
        durationSec: defaultStepSec * 1.35,
        easing: CellTweenEasing.linear,
        fromCurrent: true,
      ),
    );
  }

  /// Per-character transform builder for Scene 3 (`Frost & Shatter`).
  CellTransform? frostTransformForChar(int index, String _, int animId) {
    if (index < 0 || index >= _frostShards.length) return null;
    if (frostPhase == FrostPhase.frozen) {
      // High-frequency brittle cryo shiver (±0.08 cell tremor) when frozen solid.
      final phase = simTimeSec * 46.0 + index * 2.13;
      final shiverX = math.sin(phase) * 0.08;
      final shiverY = math.cos(phase * 1.37) * 0.06;
      return CellTransform(
        dx: shiverX,
        dy: shiverY,
        rotationRad: math.sin(phase * 0.9) * 0.025,
        zLayer: 1,
      );
    }
    if (frostPhase != FrostPhase.shattering) return null;
    const gravity = 30.0;
    const tweenDt = defaultStepSec * 1.35;
    final s = _frostShards[index];
    final nextDx = s.dx + s.vx * tweenDt;
    final nextDy = s.dy + s.vy * tweenDt + 0.5 * gravity * tweenDt * tweenDt;
    final nextRot = s.rot + s.vRot * tweenDt;
    final nextAlpha = (1.0 - (_frostElapsedSec + tweenDt) / 2.0).clamp(
      0.0,
      1.0,
    );
    return CellTransform(
      dx: s.dx,
      dy: s.dy,
      scaleX: s.scale,
      scaleY: s.scale,
      rotationRad: s.rot,
      alpha: s.alpha,
      zLayer: 2,
      tween: CellTween(
        animationId: animId,
        endDx: nextDx,
        endDy: nextDy,
        endScaleX: s.scale,
        endScaleY: s.scale,
        endRotationRad: nextRot,
        endAlpha: nextAlpha,
        durationSec: tweenDt,
        easing: CellTweenEasing.linear,
        fromCurrent: true,
        clearOnFinish: nextAlpha <= 0.01,
      ),
    );
  }

  /// Per-character horizontal slice jitter builder for Scene 4 (`Neon & Glitch`).
  CellTransform? glitchTransformForChar(int index, String _, int animId) {
    if (glitchBurstSec <= 0.0 ||
        index < 0 ||
        index >= _glitchPositions.length) {
      return null;
    }
    final pos = _glitchPositions[index];
    final hash = ((pos.row * 73 + _glitchSeed * 31) % 100) / 100.0;
    final burstScale = (glitchBurstSec / 1.15).clamp(0.0, 1.0);
    final sliceShift = (hash - 0.5) * 4.2 * burstScale;
    final yJitter = (((pos.col + _glitchSeed) % 5) - 2) * 0.14 * burstScale;
    return CellTransform(
      dx: sliceShift,
      dy: yJitter,
      scaleX: 1.0 + 0.18 * burstScale,
      zLayer: 1,
      tween: CellTween(
        animationId: animId,
        endDx: sliceShift * 0.35,
        endDy: 0.0,
        endScaleX: 1.0,
        durationSec: defaultStepSec * 1.4,
        easing: CellTweenEasing.easeOut,
        fromCurrent: true,
      ),
    );
  }

  /// Single-character crisp anvil recoil bounce for Scene 5 (`Forge`).
  CellTransform? forgeTransformForChar(int index, String _, int animId) {
    if (strikeAgeSec <= 0.0 ||
        strikeAgeSec >= 0.25 ||
        index != lastStruckCharIndex) {
      return null;
    }
    return CellTransform(
      dy: -0.15,
      scaleX: 1.22,
      scaleY: 1.22,
      zLayer: 2,
      tween: CellTween(
        animationId: animId,
        endDy: 0.0,
        endScaleX: 1.0,
        endScaleY: 1.0,
        durationSec: 0.14,
        easing: CellTweenEasing.easeOut,
        fromCurrent: false,
        clearOnFinish: true,
      ),
    );
  }
}

/// Reusable interactive 5-scene Shader Text Arcade widget.
final class ShaderTextArcadeWidget extends StatefulWidget {
  /// Controller driving scene selection, shader params, and 25 Hz cell physics.
  final ShaderTextArcadeController controller;

  /// Optional callback invoked when the user clicks inside the arcade.
  final void Function()? onInteract;

  /// Creates a [ShaderTextArcadeWidget].
  const ShaderTextArcadeWidget({
    super.key,
    required this.controller,
    this.onInteract,
  });

  @override
  State<ShaderTextArcadeWidget> createState() => _ShaderTextArcadeWidgetState();
}

final class _ShaderTextArcadeWidgetState extends State<ShaderTextArcadeWidget> {
  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(ShaderTextArcadeWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    return Column([
      _ArcadeTabBar(
        activeScene: ctrl.activeScene,
        gpuShadersSupported: ctrl.gpuShadersSupported,
        onSelect: (scene) {
          widget.onInteract?.call();
          ctrl.selectScene(scene);
        },
      ),
      const SizedBox(height: 1),
      Expanded(
        child: _PointerStage(
          onPointer: (event, localX, localY, width, height) {
            widget.onInteract?.call();
            ctrl.handleStagePointer(event, localX, localY, width, height);
          },
          child: _buildActiveScene(ctrl),
        ),
      ),
      const SizedBox(height: 1),
      _buildControlHintBar(ctrl),
    ], crossAxisAlignment: CrossAxisAlignment.stretch);
  }

  Widget _buildActiveScene(ShaderTextArcadeController ctrl) =>
      switch (ctrl.activeScene) {
        ShaderArcadeScene.oneRing => _buildOneRingScene(ctrl),
        ShaderArcadeScene.vortext => _buildVortextScene(ctrl),
        ShaderArcadeScene.frostShatter => _buildFrostScene(ctrl),
        ShaderArcadeScene.neonGlitch => _buildNeonGlitchScene(ctrl),
        ShaderArcadeScene.forge => _buildForgeScene(ctrl),
      };

  Widget _buildOneRingScene(ShaderTextArcadeController ctrl) {
    final torchStatus = ctrl.autoTorch
        ? 'AUTO-TORCH [A]'
        : (ctrl.hoverIgnite ? 'HOVER-IGNITE [H]' : 'DRAG-ONLY [H]');
    const bandBg = ShaderTextArcadeController.oneRingBandBackground;
    final bandInterior = ctrl.gpuShadersSupported
        ? _buildOneRingGpuInterior(ctrl)
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            child: _OneRingAnsiBand(controller: ctrl),
          );

    return Column([
      Text(
        'One Ring — Drag fire across the gold band ($torchStatus)',
        style: const Style(
          foreground: Color(255, 198, 88),
          modifiers: Modifier.bold,
        ),
        wrap: false,
      ),
      const SizedBox(height: 2),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        // Outer golden border sits OUTSIDE ShaderRegionWidget so border box
        // characters never enter iChannel0.a and never catch fire.
        child: DecoratedBox(
          decoration: const BoxDecoration(
            backgroundColor: bandBg,
            border: Border.all(
              Style(foreground: Color(172, 128, 48), background: bandBg),
            ),
          ),
          child: bandInterior,
        ),
      ),
    ], crossAxisAlignment: CrossAxisAlignment.start);
  }

  Widget _buildOneRingGpuInterior(ShaderTextArcadeController ctrl) {
    final cursor = ctrl.isEditingRingPrompt ? '▌' : '';
    const bandBg = ShaderTextArcadeController.oneRingBandBackground;
    // Cold runes use fg == bg so they are 100% invisible until fire passes
    // over them while iChannel0.a still carries crisp glyph alpha masks.
    const hiddenStyle = Style(foreground: bandBg, background: bandBg);
    final promptStyle = ctrl.isEditingRingPrompt
        ? const Style(
            foreground: Color(240, 186, 78),
            background: bandBg,
            modifiers: Modifier.bold,
          )
        : hiddenStyle;

    return ShaderRegionWidget(
      id: 'arcade_one_ring',
      shader: const ShaderRef.preset('one_ring'),
      stage: ShaderRegionStage.overGlyphs,
      padding: CellPadding.zero,
      persist: true,
      params: ctrl.oneRingParams(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        child: SizedBox(
          width: ShaderTextArcadeController.oneRingContentWidth,
          child: Column([
            for (final line in ShaderTextArcadeController.ringVerse.split('\n'))
              Text(line, style: hiddenStyle, wrap: false),
            const SizedBox(height: 1),
            Text(
              '> ${ctrl.ringPrompt}$cursor',
              style: promptStyle,
              wrap: false,
            ),
          ], crossAxisAlignment: CrossAxisAlignment.start),
        ),
      ),
    );
  }

  Widget _buildVortextScene(ShaderTextArcadeController ctrl) {
    if (!ctrl.gpuShadersSupported) {
      return _buildVortextAnsiFallback(ctrl);
    }
    final status = ctrl.vortextRunning ? 'PULLING' : 'PAUSED';
    final swallowReadout = ctrl.vortextMode == VortextMode.blackHole
        ? '  Swallowed: ${ctrl.swallowedParticleCount}/${ctrl.totalVortexParticleCount}'
        : '  (Drag to steer eye)';
    final baseAid = (ctrl.keyframeEpoch * 128) & 0xFFFF;
    return Column([
      Text(
        'Vortext — ${ctrl.vortextMode.label} [$status]$swallowReadout',
        style: const Style(
          foreground: Color(192, 148, 255),
          modifiers: Modifier.bold,
        ),
        wrap: false,
      ),
      const SizedBox(height: 2),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: ShaderRegionWidget(
          id: 'arcade_vortex',
          shader: const ShaderRef.preset('vortex'),
          stage: ShaderRegionStage.underGlyphs,
          padding: const CellPadding.all(2),
          params: ctrl.vortexParams(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            child: TweenText(
              ShaderTextArcadeController.vortextStanza,
              wrap: false,
              style: const Style(
                foreground: Color(236, 240, 255),
                modifiers: Modifier.bold,
              ),
              perCharacter: true,
              animationId: baseAid,
              characterTransform: ctrl.vortextTransformForChar,
            ),
          ),
        ),
      ),
    ], crossAxisAlignment: CrossAxisAlignment.start);
  }

  Widget _buildVortextAnsiFallback(ShaderTextArcadeController ctrl) {
    return Column([
      Text(
        'Vortext — ${ctrl.vortextMode.label} [ANSI Fallback]',
        style: const Style(
          foreground: Color(192, 148, 255),
          modifiers: Modifier.bold,
        ),
        wrap: false,
      ),
      const SizedBox(height: 1),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 2),
        child: DecoratedBox(
          decoration: BoxDecoration(
            backgroundColor: Color(40, 30, 16),
            border: Border.all(
              Style(
                foreground: Color(224, 168, 56),
                background: Color(40, 30, 16),
              ),
            ),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 2, vertical: 0),
            child: Text(
              'ANSI Fallback: Sub-pixel Black Hole & Hurricane VFX require a GPU shader host (run inside fterm).',
              style: Style(
                foreground: Color(255, 210, 96),
                background: Color(40, 30, 16),
                modifiers: Modifier.bold,
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 1),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column([
          for (final line in ShaderTextArcadeController.vortextStanza.split(
            '\n',
          ))
            Text(
              line,
              style: const Style(
                foreground: Color(220, 228, 245),
                modifiers: Modifier.bold,
              ),
              wrap: false,
            ),
        ], crossAxisAlignment: CrossAxisAlignment.start),
      ),
    ], crossAxisAlignment: CrossAxisAlignment.start);
  }

  Widget _buildFrostScene(ShaderTextArcadeController ctrl) {
    final frostPct = (ctrl.frostIntensity * 100 / 1.25).round().clamp(0, 100);
    final statusText = switch (ctrl.frostPhase) {
      FrostPhase.warm => 'WARM',
      FrostPhase.freezing => 'FREEZING $frostPct%',
      FrostPhase.frozen => 'FROZEN - Press Space to Shatter!',
      FrostPhase.shattering => 'SHATTERING',
    };
    if (!ctrl.gpuShadersSupported) {
      return Column([
        Text(
          '[Space] Freeze -> Shatter (Status: $statusText)',
          style: const Style(
            foreground: Color(128, 224, 255),
            modifiers: Modifier.bold,
          ),
          wrap: false,
        ),
        const SizedBox(height: 1),
        Expanded(child: _FrostAnsiStage(controller: ctrl)),
      ], crossAxisAlignment: CrossAxisAlignment.stretch);
    }
    final headlineColor = switch (ctrl.frostPhase) {
      FrostPhase.warm => const Color(245, 248, 255),
      FrostPhase.freezing => const Color(196, 240, 255),
      FrostPhase.frozen => const Color(172, 236, 255),
      FrostPhase.shattering => const Color(214, 248, 255),
    };
    final baseAid = (ctrl.keyframeEpoch * 64) & 0xFFFF;
    return Column([
      Text(
        '[Space] Freeze -> Shatter (Status: $statusText)',
        style: const Style(
          foreground: Color(128, 224, 255),
          modifiers: Modifier.bold,
        ),
        wrap: false,
      ),
      const SizedBox(height: 2),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: ShaderRegionWidget(
          id: 'arcade_ice_frost',
          shader: const ShaderRef.preset('ice_frost'),
          stage: ShaderRegionStage.overGlyphs,
          padding: const CellPadding.all(2),
          params: ctrl.frostParams(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            child: TweenText(
              ShaderTextArcadeController.frostHeadline,
              wrap: false,
              style: Style(foreground: headlineColor, modifiers: Modifier.bold),
              perCharacter: true,
              animationId: baseAid,
              characterTransform: ctrl.frostTransformForChar,
            ),
          ),
        ),
      ),
    ], crossAxisAlignment: CrossAxisAlignment.start);
  }

  Widget _buildNeonGlitchScene(ShaderTextArcadeController ctrl) {
    final burstLabel = ctrl.glitchBurstSec > 0.0 ? 'BURST ACTIVE!' : 'STANDBY';
    final baseAid = (ctrl.keyframeEpoch * 96) & 0xFFFF;
    final gpuEnabled = ctrl.gpuShadersSupported;
    return Column([
      Text(
        'Neon & Glitch — Signal status: $burstLabel',
        style: const Style(
          foreground: Color(255, 108, 224),
          modifiers: Modifier.bold,
        ),
        wrap: false,
      ),
      const SizedBox(height: 1),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: ShaderRegionWidget(
          id: 'arcade_neon_pulse',
          shader: const ShaderRef.preset('neon_pulse'),
          stage: ShaderRegionStage.overGlyphs,
          padding: const CellPadding.all(2),
          params: ctrl.neonParams(),
          enabled: gpuEnabled,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            child: Text(
              ShaderTextArcadeController.neonMarquee,
              style: Style(
                foreground: Color(236, 250, 255),
                modifiers: Modifier.bold,
              ),
              wrap: false,
            ),
          ),
        ),
      ),
      const SizedBox(height: 2),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: ShaderRegionWidget(
          id: 'arcade_glitch_tear',
          shader: const ShaderRef.preset('glitch_tear'),
          stage: ShaderRegionStage.overGlyphs,
          padding: const CellPadding.all(1),
          params: ctrl.glitchParams(),
          enabled: gpuEnabled,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            child: TweenText(
              ShaderTextArcadeController.glitchStatusBlock,
              wrap: false,
              style: const Style(
                foreground: Color(255, 148, 232),
                modifiers: Modifier.bold,
              ),
              perCharacter: true,
              animationId: baseAid,
              characterTransform: gpuEnabled
                  ? ctrl.glitchTransformForChar
                  : null,
            ),
          ),
        ),
      ),
    ], crossAxisAlignment: CrossAxisAlignment.start);
  }

  Widget _buildForgeScene(ShaderTextArcadeController ctrl) {
    final autoLabel = ctrl.forgeAutoStrike ? 'AUTO-STRIKING' : 'READY';
    return Column([
      Text(
        'Anvil Typing Forge [$autoLabel] — Type letters or press [Space]/[A] to auto-strike',
        style: const Style(
          foreground: Color(255, 196, 98),
          modifiers: Modifier.bold,
        ),
        wrap: false,
      ),
      const SizedBox(height: 2),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            border: Border.all(Style(foreground: Color(216, 146, 48))),
          ),
          child: ShaderRegionWidget(
            id: 'arcade_forge_spark',
            shader: const ShaderRef.preset('forge_spark'),
            stage: ShaderRegionStage.overGlyphs,
            padding: CellPadding.zero,
            params: ctrl.forgeParams(),
            enabled: ctrl.gpuShadersSupported,
            child: SizedBox(
              width: ShaderTextArcadeController.forgeRegionCols,
              height: ShaderTextArcadeController.forgeRegionRows,
              child: Padding(
                padding: const EdgeInsets.only(
                  left: ShaderTextArcadeController.forgePromptLeftPad,
                  top: ShaderTextArcadeController.forgePromptRow,
                ),
                child: _ForgeLineWidget(controller: ctrl),
              ),
            ),
          ),
        ),
      ),
    ], crossAxisAlignment: CrossAxisAlignment.start);
  }

  Widget _buildControlHintBar(ShaderTextArcadeController ctrl) {
    final hint = switch (ctrl.activeScene) {
      ShaderArcadeScene.oneRing =>
        ctrl.isEditingRingPrompt
            ? 'Typing prompt: [Enter/Esc] Done  [Backspace] Delete'
            : '[Drag] Paint Fire  [A] Auto-Torch  [H] Hover-Ignite  [Enter] Type  [R] Reset',
      ShaderArcadeScene.vortext =>
        '[Space] Pull/Pause  [M] Black Hole/Hurricane  [Drag] Move Center  [R] Reset',
      ShaderArcadeScene.frostShatter =>
        '[Space/Click] Freeze -> Shatter -> Reset  [R] Warm Reset  [1-5 / []] Switch Scene',
      ShaderArcadeScene.neonGlitch =>
        '[Space/Click] Trigger Glitch Burst  [R] Calm  [1-5 / []] Switch Scene',
      ShaderArcadeScene.forge =>
        '[Type] Strike Character Sparks  [Space/A] Auto-Strike Phrase  [R] Clear Line',
    };
    return SizedBox(
      height: 1,
      child: Text(
        hint,
        style: const Style(foreground: CharmColors.smoke),
        wrap: false,
      ),
    );
  }
}

final class _ArcadeTabBar extends Widget {
  final ShaderArcadeScene activeScene;
  final bool gpuShadersSupported;
  final void Function(ShaderArcadeScene scene) onSelect;

  const _ArcadeTabBar({
    required this.activeScene,
    required this.gpuShadersSupported,
    required this.onSelect,
  });

  @override
  int getIntrinsicHeight(int width) => 1;

  @override
  Element createElement() => _ArcadeTabBarElement(this);
}

final class _ArcadeTabBarElement extends Element
    implements MouseEventHandlerWithArea {
  final List<({int startX, int endX, ShaderArcadeScene scene})> _tabBounds = [];

  _ArcadeTabBarElement(_ArcadeTabBar super.widget);

  @override
  Size performLayout(BoxConstraints constraints) =>
      constraints.constrain(Size(constraints.maxWidth, 1));

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final tabBar = widget as _ArcadeTabBar;
    _tabBounds.clear();
    if (size.width <= 0 || size.height <= 0) return;

    var x = 0;
    for (final scene in ShaderArcadeScene.values) {
      final label = ' ${scene.number}:${scene.tabLabel} ';
      final labelW = measureStringWidth(label);
      if (x + labelW > size.width) break;
      final isActive = scene == tabBar.activeScene;
      final style = isActive
          ? const Style(
              foreground: CharmColors.pepper,
              background: CharmColors.charple,
              modifiers: Modifier.bold,
            )
          : const Style(
              foreground: CharmColors.salt,
              background: CharmColors.bbq,
            );
      buffer.writeString(offset.dx + x, offset.dy, label, style);
      _tabBounds.add((startX: x, endX: x + labelW, scene: scene));
      x += labelW + 1;
    }
    _paintModeChip(buffer, offset, x, tabBar.gpuShadersSupported);
  }

  void _paintModeChip(Buffer buffer, Offset offset, int usedX, bool isGpu) {
    final fullLabel = isGpu ? ' [GPU] ' : ' [ANSI Fallback] ';
    final compactLabel = isGpu ? '[GPU]' : '[ANSI]';
    final style = isGpu
        ? const Style(
            foreground: Color(80, 248, 196),
            background: Color(14, 48, 40),
            modifiers: Modifier.bold,
          )
        : const Style(
            foreground: Color(255, 198, 72),
            background: Color(58, 36, 12),
            modifiers: Modifier.bold,
          );
    final remaining = size.width - usedX;
    final label = remaining >= measureStringWidth(fullLabel)
        ? fullLabel
        : (remaining >= measureStringWidth(compactLabel) ? compactLabel : null);
    if (label == null) return;
    final chipX = math.max(usedX, size.width - measureStringWidth(label));
    buffer.writeString(offset.dx + chipX, offset.dy, label, style);
  }

  @override
  void handleMouseEvent(
    ui.MouseEvent event,
    int localX,
    int localY,
    Rect area,
  ) {
    if (event.type != ui.MouseEventType.press) return;
    for (final tab in _tabBounds) {
      if (localX >= tab.startX && localX < tab.endX) {
        (widget as _ArcadeTabBar).onSelect(tab.scene);
        return;
      }
    }
  }
}

final class _OneRingAnsiBand extends Widget {
  final ShaderTextArcadeController controller;

  const _OneRingAnsiBand({required this.controller});

  @override
  int getIntrinsicWidth(int height) =>
      ShaderTextArcadeController.oneRingContentWidth;

  @override
  int getIntrinsicHeight(int width) =>
      ShaderTextArcadeController.oneRingBandRows;

  @override
  Element createElement() => _OneRingAnsiBandElement(this);
}

final class _OneRingAnsiBandElement extends Element {
  _OneRingAnsiBandElement(_OneRingAnsiBand super.widget);

  @override
  Size performLayout(BoxConstraints constraints) => constraints.constrain(
    const Size(
      ShaderTextArcadeController.oneRingContentWidth,
      ShaderTextArcadeController.oneRingBandRows,
    ),
  );

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final ctrl = (widget as _OneRingAnsiBand).controller;
    const bandBg = ShaderTextArcadeController.oneRingBandBackground;
    const blankStyle = Style(foreground: bandBg, background: bandBg);
    final rows = _buildBandLines(ctrl);
    final blankRow = ' ' * size.width;
    final revealedGrid = List<bool>.filled(size.width * size.height, false);

    for (var row = 0; row < size.height; row++) {
      buffer.writeString(offset.dx, offset.dy + row, blankRow, blankStyle);
      if (row >= rows.length) continue;
      _paintBandRow(buffer, offset, ctrl, row, rows[row], revealedGrid);
    }
    _paintTorchIndicator(buffer, offset, ctrl, revealedGrid);
  }

  List<String> _buildBandLines(ShaderTextArcadeController ctrl) {
    final cursor = ctrl.isEditingRingPrompt ? '▌' : '';
    return [
      ...ShaderTextArcadeController.ringVerse.split('\n'),
      '',
      '> ${ctrl.ringPrompt}$cursor',
    ];
  }

  void _paintBandRow(
    Buffer buffer,
    Offset offset,
    ShaderTextArcadeController ctrl,
    int row,
    String line,
    List<bool> revealedGrid,
  ) {
    const bandBg = ShaderTextArcadeController.oneRingBandBackground;
    const editStyle = Style(
      foreground: Color(240, 186, 78),
      background: bandBg,
      modifiers: Modifier.bold,
    );
    var col = 0;
    for (final grapheme in line.characters) {
      final w = graphemeWidth(grapheme);
      if (w <= 0) continue;
      if (col + w > size.width) break;
      if (row == 5 && ctrl.isEditingRingPrompt) {
        buffer.writeString(
          offset.dx + col,
          offset.dy + row,
          grapheme,
          editStyle,
        );
        revealedGrid[row * size.width + col] = true;
      } else if (grapheme != ' ') {
        final style = ShaderTextArcadeController.oneRingAnsiStyle(
          latched: ctrl.oneRingCellLatched(col, row),
          heat: ctrl.oneRingCellHeat(col, row),
          col: col,
          row: row,
          timeSec: ctrl.simTimeSec,
        );
        if (style != null) {
          buffer.writeString(offset.dx + col, offset.dy + row, grapheme, style);
          revealedGrid[row * size.width + col] = true;
        }
      }
      col += w;
    }
  }

  void _paintTorchIndicator(
    Buffer buffer,
    Offset offset,
    ShaderTextArcadeController ctrl,
    List<bool> revealedGrid,
  ) {
    final torch = ctrl.ansiOneRingTorchPosition;
    if (torch == null) return;
    final col = torch.x.round();
    final row = torch.y.round();
    if (col < 0 || col >= size.width || row < 0 || row >= size.height) return;
    if (revealedGrid[row * size.width + col]) return;
    final glyph = (ctrl.simTimeSec * 12.0).floor().isEven ? '*' : '~';
    const emberStyle = Style(
      foreground: Color(255, 148, 36),
      background: ShaderTextArcadeController.oneRingBandBackground,
      modifiers: Modifier.bold,
    );
    buffer.writeString(offset.dx + col, offset.dy + row, glyph, emberStyle);
  }
}

final class _FrostAnsiStage extends Widget {
  final ShaderTextArcadeController controller;

  const _FrostAnsiStage({required this.controller});

  @override
  int getIntrinsicHeight(int width) => 8;

  @override
  Element createElement() => _FrostAnsiStageElement(this);
}

final class _FrostAnsiStageElement extends Element {
  _FrostAnsiStageElement(_FrostAnsiStage super.widget);

  @override
  Size performLayout(BoxConstraints constraints) => constraints.constrain(
    Size(constraints.maxWidth, math.max(1, constraints.maxHeight)),
  );

  @override
  void performPaint(Buffer buffer, Offset offset) {
    if (size.width <= 0 || size.height <= 0) return;
    final ctrl = (widget as _FrostAnsiStage).controller;
    final homeX = math.min(4, math.max(0, size.width - 1));
    final homeY = math.min(4, math.max(0, size.height ~/ 3));

    if (ctrl.frostPhase == FrostPhase.shattering) {
      _paintShatteringShards(buffer, offset, ctrl, homeX, homeY);
      return;
    }
    final progress = (ctrl.frostIntensity / 1.25).clamp(0.0, 1.0);
    final isFrozen = ctrl.frostPhase == FrostPhase.frozen;
    _paintFrostLine(
      buffer,
      offset,
      ShaderTextArcadeController.frostHeadline,
      homeX,
      homeY,
      progress,
      isFrozen,
      ctrl.simTimeSec,
    );
    if (homeY + 2 < size.height) {
      _paintFrostLine(
        buffer,
        offset,
        ShaderTextArcadeController.frostSubtitle,
        homeX,
        homeY + 2,
        progress,
        isFrozen,
        ctrl.simTimeSec,
      );
    }
    if (isFrozen) {
      _paintFrozenCryoShimmer(buffer, offset, homeX, homeY, ctrl.simTimeSec);
    }
  }

  void _paintFrostLine(
    Buffer buffer,
    Offset offset,
    String text,
    int startX,
    int y,
    double progress,
    bool isFrozen,
    double timeSec,
  ) {
    if (y < 0 || y >= size.height) return;
    final lineWidth = measureStringWidth(text);
    var col = 0;
    for (final grapheme in text.characters) {
      final w = graphemeWidth(grapheme);
      if (w <= 0) continue;
      final x = startX + col;
      if (x + w > size.width) break;
      final style = ShaderTextArcadeController.frostAnsiStyle(
        progress: progress,
        col: col,
        lineWidth: lineWidth,
        frozen: isFrozen,
        timeSec: timeSec,
      );
      buffer.writeString(offset.dx + x, offset.dy + y, grapheme, style);
      col += w;
    }
  }

  void _paintFrozenCryoShimmer(
    Buffer buffer,
    Offset offset,
    int homeX,
    int homeY,
    double timeSec,
  ) {
    final headlineW = measureStringWidth(
      ShaderTextArcadeController.frostHeadline,
    );
    final tick = (timeSec * 8.0).floor();
    const sparkleStyle = Style(
      foreground: Color(175, 238, 255),
      modifiers: Modifier.bold,
    );
    const dimIceStyle = Style(foreground: Color(110, 196, 240));
    for (var i = 0; i < headlineW; i += 4) {
      final col = homeX + ((i + tick) % headlineW);
      final aboveY = homeY - 1;
      final belowY = homeY + 1;
      final glyph = ((i + tick) & 1) == 0 ? '·' : '*';
      final style = ((i + tick) % 3 == 0) ? sparkleStyle : dimIceStyle;
      if (aboveY >= 0 && col < size.width) {
        buffer.writeString(offset.dx + col, offset.dy + aboveY, glyph, style);
      }
      if (belowY < size.height && col < size.width) {
        buffer.writeString(offset.dx + col, offset.dy + belowY, glyph, style);
      }
    }
  }

  void _paintShatteringShards(
    Buffer buffer,
    Offset offset,
    ShaderTextArcadeController ctrl,
    int homeX,
    int homeY,
  ) {
    for (var i = 0; i < ctrl.frostShardCount; i++) {
      final shard = ctrl.frostShardSnapshot(i);
      if (shard.alpha <= 0.05) continue;
      final x = homeX + shard.col + shard.dx.round();
      final y = homeY + shard.dy.round();
      if (x < 0 || x >= size.width || y < 0 || y >= size.height) continue;
      final bx = offset.dx + x;
      final by = offset.dy + y;
      if (!buffer.isCellValid(bx, by)) continue;
      final style = ShaderTextArcadeController.frostShardAnsiStyle(shard.alpha);
      buffer.writeString(bx, by, shard.grapheme, style);
    }
  }
}

final class _ForgeLineWidget extends Widget {
  final ShaderTextArcadeController controller;

  const _ForgeLineWidget({required this.controller});

  @override
  int getIntrinsicWidth(int height) =>
      ShaderTextArcadeController.forgeRegionCols -
      ShaderTextArcadeController.forgePromptLeftPad;

  @override
  int getIntrinsicHeight(int width) => 1;

  @override
  Element createElement() => _ForgeLineWidgetElement(this);
}

final class _ForgeLineWidgetElement extends Element {
  _ForgeLineWidgetElement(_ForgeLineWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) =>
      constraints.constrain(Size(constraints.maxWidth, 1));

  @override
  void performPaint(Buffer buffer, Offset offset) {
    if (size.width <= 0 || size.height <= 0) return;
    final ctrl = (widget as _ForgeLineWidget).controller;
    const promptStyle = Style(
      foreground: Color(216, 146, 48),
      modifiers: Modifier.bold,
    );
    buffer.writeString(offset.dx, offset.dy, '>', promptStyle);
    _applyGpuTransform(buffer, ctrl, offset.dx, offset.dy, 0, '>');
    if (size.width <= 1) return;
    buffer.writeString(offset.dx + 1, offset.dy, ' ', promptStyle);

    var x = 2;
    var nonSpaceIdx = 1;
    var charIndex = 0;
    for (final grapheme in ctrl.forgePrompt.characters) {
      final w = graphemeWidth(grapheme);
      if (w <= 0) {
        charIndex++;
        continue;
      }
      if (x + w > size.width) break;
      final style = ShaderTextArcadeController.forgeStyleForAge(
        ctrl.forgeCharAgeAt(charIndex),
      );
      buffer.writeString(offset.dx + x, offset.dy, grapheme, style);
      if (grapheme != ' ') {
        _applyGpuTransform(
          buffer,
          ctrl,
          offset.dx + x,
          offset.dy,
          nonSpaceIdx,
          grapheme,
        );
        nonSpaceIdx++;
      }
      x += w;
      charIndex++;
    }
  }

  void _applyGpuTransform(
    Buffer buffer,
    ShaderTextArcadeController ctrl,
    int x,
    int y,
    int nonSpaceIdx,
    String grapheme,
  ) {
    if (!ctrl.gpuShadersSupported) return;
    final xf = ctrl.forgeTransformForChar(
      nonSpaceIdx,
      grapheme,
      ctrl.forgeStrikeAnimId,
    );
    if (xf != null) buffer.setCellTransform(x, y, xf);
  }
}

final class _PointerStage extends Widget {
  final Widget child;
  final void Function(
    ui.MouseEvent event,
    int localX,
    int localY,
    int width,
    int height,
  )
  onPointer;

  const _PointerStage({required this.child, required this.onPointer});

  @override
  Element createElement() => _PointerStageElement(this);
}

final class _PointerStageElement extends SingleChildElement
    implements MouseEventHandlerWithArea {
  _PointerStageElement(_PointerStage super.widget);

  @override
  Widget? get childWidget => (widget as _PointerStage).child;

  @override
  Size performLayout(BoxConstraints constraints) {
    if (childElement != null) {
      childElement!.layout(constraints);
      childElement!.relativeOffset = Offset.zero;
    }
    return constraints.constrain(
      Size(constraints.maxWidth, constraints.maxHeight),
    );
  }

  @override
  void handleMouseEvent(
    ui.MouseEvent event,
    int localX,
    int localY,
    Rect area,
  ) {
    (widget as _PointerStage).onPointer(
      event,
      localX,
      localY,
      area.width,
      area.height,
    );
  }
}

/// WidgetBook adapter hosting [ShaderTextArcadeWidget].
final class ShaderTextArcadeExample extends WidgetBookExample {
  /// Backing controller exposed for tests and direct inspection.
  final ShaderTextArcadeController controller = ShaderTextArcadeController();

  /// Updates whether GPU shader support has been confirmed by the terminal host.
  void setGpuShadersSupported(bool supported) {
    controller.setGpuShadersSupported(supported);
  }

  int _tickAccumMs = 0;

  @override
  bool get requiresTick => true;

  @override
  bool get wantsMouseHoverRebuild => true;

  @override
  Map<String, String> get helpBindings => const {
    '1-5 / []': 'Switch Scene',
    'Space': 'Action / Freeze / Burst',
    'A / H / M': 'Torch / Hover / Vortex Mode',
    'R': 'Reset Scene',
  };

  @override
  bool tick(Duration duration) {
    final stepMs = duration.inMilliseconds;
    final clampedDeltaMs = (stepMs > 0 && stepMs <= 100) ? stepMs : 16;
    _tickAccumMs += clampedDeltaMs;
    if (_tickAccumMs < 40) return false;
    _tickAccumMs = 0;
    controller.stepPhysics(ShaderTextArcadeController.defaultStepSec);
    return true;
  }

  @override
  bool handleKeyEvent(ui.KeyEvent event) => controller.handleKeyEvent(event);

  @override
  void handleMouseEvent(
    ui.MouseEvent event,
    int localX,
    int localY,
    int width,
    int height,
  ) {
    if (localY <= 1) return;
    controller.handleStagePointer(
      event,
      localX,
      localY - 2,
      width,
      math.max(1, height - 3),
    );
  }

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) => ShaderTextArcadeWidget(controller: controller);
}
