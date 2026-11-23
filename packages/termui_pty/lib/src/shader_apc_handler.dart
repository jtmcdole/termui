import 'dart:convert';
import 'dart:typed_data';

import 'package:termui/termui.dart';

/// Scope cleared by an `ESC _ S a=reset` command or terminal reset lifecycle event.
enum ShaderResetTarget {
  /// Clear all CLI shader definitions, regions, transforms, and full-pane overrides.
  all('all'),

  /// Clear only active scoped [ShaderRegion] entries.
  regions('regions'),

  /// Clear only active [CellTransform] entries.
  xforms('xforms'),

  /// Clear only full-pane CLI shader overrides.
  pane('pane');

  /// Canonical wire target name.
  final String wireName;

  const ShaderResetTarget(this.wireName);

  /// Parses [raw] into a [ShaderResetTarget], returning `null` if invalid.
  static ShaderResetTarget? fromWireName(String? raw) {
    if (raw == null || raw.isEmpty) return all;
    return switch (raw.trim().toLowerCase()) {
      'all' => all,
      'regions' => regions,
      'xforms' => xforms,
      'pane' => pane,
      _ => null,
    };
  }
}

/// Decoded `ESC _ S ... ST` artistic shader or cell-transform APC event.
sealed class TerminalShaderApcEvent {
  /// Creates a terminal shader APC event.
  const TerminalShaderApcEvent();
}

/// Capability query decoded from `ESC _ S a=query ST`.
final class TerminalShaderQueryEvent extends TerminalShaderApcEvent {
  /// Creates a shader capability query event.
  const TerminalShaderQueryEvent();

  @override
  bool operator ==(Object other) => other is TerminalShaderQueryEvent;

  @override
  int get hashCode => runtimeType.hashCode;
}

/// Custom CLI GLSL shader definition decoded from `ESC _ S a=define,... ST`.
final class TerminalShaderDefineEvent extends TerminalShaderApcEvent {
  /// Logical shader slot identifier (`<= 64` identifier chars).
  final String id;

  /// UTF-8 Ghostty Shadertoy GLSL source (`<= 32 KiB`).
  final String glslSource;

  /// Whether the shader requests previous-frame feedback (`persist=1`).
  final bool persist;

  /// Creates a CLI GLSL shader definition event.
  const TerminalShaderDefineEvent({
    required this.id,
    required this.glslSource,
    this.persist = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalShaderDefineEvent &&
          other.id == id &&
          other.glslSource == glslSource &&
          other.persist == persist;

  @override
  int get hashCode => Object.hash(id, glslSource, persist);
}

/// Scoped [ShaderRegion] attach, update, or removal decoded from `a=region`.
final class TerminalShaderRegionEvent extends TerminalShaderApcEvent {
  /// Logical region identifier.
  final String id;

  /// Region configuration when [remove] is `false`, or `null` when removing.
  final ShaderRegion? region;

  /// Whether this event removes the region identified by [id].
  final bool remove;

  /// Creates a region attach/update or removal event.
  const TerminalShaderRegionEvent({
    required this.id,
    this.region,
    this.remove = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalShaderRegionEvent &&
          other.id == id &&
          other.region == region &&
          other.remove == remove;

  @override
  int get hashCode => Object.hash(id, region, remove);
}

/// Single (`a=xform`) or batched (`a=xforms`) per-cell transform update event.
final class TerminalShaderTransformBatchEvent extends TerminalShaderApcEvent {
  /// Ordered cell transform updates (`transform == null` removes the cell transform).
  final List<CellTransformEntry> entries;

  /// Whether existing cell transforms should be cleared before applying [entries].
  final bool replace;

  /// Creates a cell transform batch event.
  TerminalShaderTransformBatchEvent({
    required List<CellTransformEntry> entries,
    this.replace = false,
  }) : entries = List<CellTransformEntry>.unmodifiable(entries);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! TerminalShaderTransformBatchEvent) return false;
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

/// Full-pane CLI shader activation or clear decoded from `a=set`.
final class TerminalShaderSetEvent extends TerminalShaderApcEvent {
  /// Shader stage (`'bg'`, `'fg'`, or `'post'`).
  final String stage;

  /// Optional built-in preset identifier.
  final String? presetId;

  /// Optional CLI-defined custom GLSL shader identifier.
  final String? shaderId;

  /// Eight initial user uniform floats (`p0..p7`), clamped to `[-16.0, 16.0]`.
  final Float32List params;

  /// Whether this event clears the CLI full-pane override for [stage].
  final bool clear;

  /// Creates a full-pane shader activation or clear event.
  TerminalShaderSetEvent({
    this.stage = 'post',
    this.presetId,
    this.shaderId,
    Float32List? params,
    this.clear = false,
  }) : params = ShaderRegion.sanitizeParams(params);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! TerminalShaderSetEvent) return false;
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

/// Live uniform update (`p0..p7`) decoded from `a=uniform` without recompilation.
final class TerminalShaderUniformEvent extends TerminalShaderApcEvent {
  /// Target region/shader identifier, or `null` for the active full-pane shader.
  final String? id;

  /// Bitmask (`bit0..bit7`) indicating which `p0..p7` indices are updated.
  final int paramMask;

  /// Eight float slots (only slots with bits set in [paramMask] are active).
  final Float32List params;

  /// Creates a live shader uniform update event.
  TerminalShaderUniformEvent({
    this.id,
    required this.paramMask,
    required Float32List params,
  }) : params = ShaderRegion.sanitizeParams(params);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! TerminalShaderUniformEvent) return false;
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

/// Reset event decoded from `a=reset` or synthesized on `RIS`/`DECSTR`/exit.
final class TerminalResetShaderEvent extends TerminalShaderApcEvent {
  /// Which subset of CLI shader/transform state to clear.
  final ShaderResetTarget target;

  /// Whether this reset was synthesized specifically for exiting the alternate
  /// screen buffer (so host policies may preserve primary-screen shader
  /// definitions while clearing alt-screen state).
  final bool altScreenExit;

  /// Creates a shader reset event.
  const TerminalResetShaderEvent({
    this.target = ShaderResetTarget.all,
    this.altScreenExit = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalResetShaderEvent &&
          other.target == target &&
          other.altScreenExit == altScreenExit;

  @override
  int get hashCode => Object.hash(target, altScreenExit);
}

final class _PendingDefineUpload {
  final String id;
  final bool persist;
  final StringBuffer base64Data = StringBuffer();
  int charCount = 0;
  bool overflowed = false;

  _PendingDefineUpload({required this.id, required this.persist});
}

final class _PendingXformsUpload {
  final bool replace;
  final StringBuffer base64Data = StringBuffer();
  int charCount = 0;
  bool overflowed = false;

  _PendingXformsUpload({required this.replace});
}

/// Stateful pure-Dart parser and chunk assembler for `ESC _ S ... ST` APC commands.
///
/// Enforces all Step 3 bounds before emitting events:
/// - `<= 64 KiB` per APC wire frame
/// - `<= 32 KiB` decoded UTF-8 GLSL source per `a=define`
/// - `<= 16` live CLI shader slots per pane
/// - `<= 8` active [ShaderRegion] entries per pane
/// - `<= 4,096` live cell transforms (`64`-byte little-endian `a=xforms` stride)
/// - Finite numeric validation (rejects `NaN` / `Infinity` cleanly)
final class ShaderApcParser {
  /// Maximum decoded UTF-8 GLSL byte size (`32 KiB`).
  static const int maxGlslBytes = ShaderApcEncoder.maxGlslBytes;

  /// Maximum simultaneous defined CLI shader slots per pane.
  static const int maxSlots = 16;

  /// Maximum simultaneous active scoped regions per pane.
  static const int maxRegions = ShaderRegion.maxRegionsPerPane;

  /// Maximum simultaneous live cell transforms per pane.
  static const int maxTransforms = CellTransformCodec.maxLiveTransforms;

  /// Maximum characters/bytes accepted in a single APC wire frame (`64 KiB`).
  static const int maxWireFrameBytes = 64 * 1024;

  /// Maximum concurrent in-flight chunked `a=define` uploads.
  static const int maxPendingDefines = 4;

  /// Maximum `sourceRects` permitted in a single `a=region`.
  static const int maxRectsPerRegion = 32;

  static const int _maxDefineBase64Chars = ((maxGlslBytes + 2) ~/ 3) * 4;
  static const int _maxXformsRawBytes =
      maxTransforms * CellTransformCodec.strideBytes;
  static const int _maxXformsBase64Chars = ((_maxXformsRawBytes + 2) ~/ 3) * 4;

  static const Set<String> _validStages = {'bg', 'fg', 'post'};
  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_.-]{1,64}$');
  static final RegExp _whitespaceRegex = RegExp(r'\s+');

  /// Callback invoked whenever a validated shader APC event completes.
  final void Function(TerminalShaderApcEvent event)? onShaderEvent;

  final Map<String, _PendingDefineUpload> _pendingDefines = {};
  final Set<String> _definedSlots = {};
  final Set<String> _activeRegions = {};
  final Set<int> _liveTransformKeys = {};
  _PendingXformsUpload? _pendingXforms;

  /// Creates a stateful [ShaderApcParser].
  ShaderApcParser({this.onShaderEvent});

  /// Number of incomplete chunked `a=define` uploads currently buffered.
  int get pendingDefineCount => _pendingDefines.length;

  /// Number of currently tracked live CLI shader slots (`<= 16`).
  int get liveSlotCount => _definedSlots.length;

  /// Number of currently tracked active regions (`<= 8`).
  int get activeRegionCount => _activeRegions.length;

  /// Number of currently tracked live cell transforms (`<= 4,096`).
  int get liveTransformCount => _liveTransformKeys.length;

  /// Clears all pending uploads and tracked slot/region/transform counts.
  void reset() {
    _pendingDefines.clear();
    _definedSlots.clear();
    _activeRegions.clear();
    _liveTransformKeys.clear();
    _pendingXforms = null;
  }

  /// Parses an APC payload beginning with `S` or `_S`.
  void handleApc(String payload) {
    if (payload.length > maxWireFrameBytes) return;
    if (!payload.startsWith('S') && !payload.startsWith('_S')) return;
    final clean = payload.startsWith('_S') ? payload.substring(1) : payload;
    final semiIdx = clean.indexOf(';');
    final controlPart = semiIdx >= 0
        ? clean.substring(1, semiIdx)
        : clean.substring(1);
    final dataPart = semiIdx >= 0 ? clean.substring(semiIdx + 1) : '';
    final control = _parseControlPart(controlPart);
    final action = control['a'];
    if (action == null) return;
    switch (action) {
      case 'query':
        onShaderEvent?.call(const TerminalShaderQueryEvent());
      case 'caps':
        // Explicitly ignored on stdout so canonical TTY echo can never loop.
        break;
      case 'define':
        _handleDefine(control, dataPart);
      case 'region':
        _handleRegion(control);
      case 'xform':
        _handleSingleXform(control);
      case 'xforms':
        _handleBatchedXforms(control, dataPart);
      case 'set':
        _handleSet(control);
      case 'uniform':
        _handleUniform(control);
      case 'reset':
        _handleReset(control);
    }
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

  void _handleDefine(Map<String, String> control, String dataPart) {
    final id = control['id'];
    if (id == null || !_idPattern.hasMatch(id)) return;
    if (!_definedSlots.contains(id) && _definedSlots.length >= maxSlots) {
      _pendingDefines.remove(id);
      return;
    }
    final isMore = control['m'] == '1';
    var pending = _pendingDefines[id];
    if (pending == null) {
      if (_pendingDefines.length >= maxPendingDefines) {
        _pendingDefines.remove(_pendingDefines.keys.first);
      }
      final persist = _parseBool(control['persist']) ?? false;
      pending = _PendingDefineUpload(id: id, persist: persist);
      _pendingDefines[id] = pending;
    }
    _appendDefineChunk(pending, dataPart);
    if (isMore) return;
    _pendingDefines.remove(id);
    if (pending.overflowed) return;
    final decoded = _decodeUtf8Base64(
      pending.base64Data.toString(),
      maxBytes: maxGlslBytes,
    );
    if (decoded == null || decoded.isEmpty || decoded.contains('\x00')) return;
    _definedSlots.add(id);
    onShaderEvent?.call(
      TerminalShaderDefineEvent(
        id: id,
        glslSource: decoded,
        persist: pending.persist,
      ),
    );
  }

  void _appendDefineChunk(_PendingDefineUpload pending, String dataPart) {
    if (pending.overflowed || dataPart.isEmpty) return;
    final clean = dataPart.replaceAll(_whitespaceRegex, '');
    if (clean.isEmpty) return;
    final nextChars = pending.charCount + clean.length;
    if (nextChars > _maxDefineBase64Chars) {
      pending.base64Data.clear();
      pending.charCount = 0;
      pending.overflowed = true;
      return;
    }
    pending.base64Data.write(clean);
    pending.charCount = nextChars;
  }

  void _handleRegion(Map<String, String> control) {
    final id = control['id'];
    if (id == null || !_idPattern.hasMatch(id)) return;
    if (_parseBool(control['del']) == true) {
      _activeRegions.remove(id);
      onShaderEvent?.call(TerminalShaderRegionEvent(id: id, remove: true));
      return;
    }
    if (!_activeRegions.contains(id) && _activeRegions.length >= maxRegions) {
      return;
    }
    final shaderId = control['s'];
    if (shaderId == null || !_idPattern.hasMatch(shaderId)) return;
    final rects = _parseRects(control['rects']);
    if (rects == null || rects.isEmpty) return;
    final padding = _parsePadding(control['pad']);
    final stage = control.containsKey('stage')
        ? ShaderRegionStage.fromWireName(control['stage'])
        : ShaderRegionStage.overGlyphs;
    final zIndex = _parseOptionalInt(control['z'], -1000, 1000, fallback: 0);
    final persist = _parseOptionalBool(control['persist'], fallback: false);
    final paramsResult = _parseUniformParams(control);
    if (padding == null ||
        stage == null ||
        zIndex == null ||
        persist == null ||
        paramsResult == null) {
      return;
    }
    _activeRegions.add(id);
    onShaderEvent?.call(
      TerminalShaderRegionEvent(
        id: id,
        region: ShaderRegion(
          id: id,
          shaderId: shaderId,
          sourceRects: rects,
          padding: padding,
          stage: stage,
          zIndex: zIndex,
          persist: persist,
          params: paramsResult.params,
        ),
      ),
    );
  }

  void _handleSingleXform(Map<String, String> control) {
    final col = _parseRequiredInt(control['c'], 0, 0xFFFF);
    final row = _parseRequiredInt(control['r'], 0, 0xFFFF);
    if (col == null || row == null) return;
    final cellKey = (row << 16) | col;
    if (_parseBool(control['del']) == true) {
      _liveTransformKeys.remove(cellKey);
      onShaderEvent?.call(
        TerminalShaderTransformBatchEvent(
          entries: [(col: col, row: row, transform: null)],
        ),
      );
      return;
    }
    final transform = _parseSingleTransform(control);
    if (transform == null) return;
    if (transform.isIdentity) {
      _liveTransformKeys.remove(cellKey);
      onShaderEvent?.call(
        TerminalShaderTransformBatchEvent(
          entries: [(col: col, row: row, transform: null)],
        ),
      );
      return;
    }
    if (!_liveTransformKeys.contains(cellKey) &&
        _liveTransformKeys.length >= maxTransforms) {
      return;
    }
    _liveTransformKeys.add(cellKey);
    onShaderEvent?.call(
      TerminalShaderTransformBatchEvent(
        entries: [(col: col, row: row, transform: transform)],
      ),
    );
  }

  CellTransform? _parseSingleTransform(Map<String, String> control) {
    final dx = _parseOptionalFiniteDouble(control['dx'], fallback: 0.0);
    final dy = _parseOptionalFiniteDouble(control['dy'], fallback: 0.0);
    final sx = _parseOptionalFiniteDouble(control['sx'], fallback: 1.0);
    final sy = _parseOptionalFiniteDouble(control['sy'], fallback: 1.0);
    final rot = _parseOptionalFiniteDouble(control['rot'], fallback: 0.0);
    final alpha = _parseOptionalFiniteDouble(
      control['al'] ?? control['alpha'],
      fallback: 1.0,
    );
    final z = _parseOptionalInt(
      control['z'],
      CellTransform.minZLayer,
      CellTransform.maxZLayer,
      fallback: 0,
    );
    if (dx == null ||
        dy == null ||
        sx == null ||
        sy == null ||
        rot == null ||
        alpha == null ||
        z == null) {
      return null;
    }
    final tween = _parseOptionalTween(control);
    if (tween.invalid) return null;
    return CellTransform(
      dx: dx,
      dy: dy,
      scaleX: sx
          .clamp(CellTransform.minScale, CellTransform.maxScale)
          .toDouble(),
      scaleY: sy
          .clamp(CellTransform.minScale, CellTransform.maxScale)
          .toDouble(),
      rotationRad: rot,
      alpha: alpha.clamp(0.0, 1.0).toDouble(),
      zLayer: z,
      tween: tween.value,
    );
  }

  ({CellTween? value, bool invalid}) _parseOptionalTween(
    Map<String, String> control,
  ) {
    final hasTweenKey =
        control.containsKey('aid') ||
        control.containsKey('dur') ||
        control.containsKey('edx') ||
        control.containsKey('edy') ||
        control.containsKey('esx') ||
        control.containsKey('esy') ||
        control.containsKey('erot') ||
        control.containsKey('ea') ||
        control.containsKey('ease') ||
        control.containsKey('cur') ||
        control.containsKey('clr');
    if (!hasTweenKey) return (value: null, invalid: false);
    final aid = _parseOptionalInt(
      control['aid'],
      0,
      CellTween.maxAnimationId,
      fallback: 0,
    );
    final edx = _parseOptionalFiniteDouble(control['edx'], fallback: 0.0);
    final edy = _parseOptionalFiniteDouble(control['edy'], fallback: 0.0);
    final esx = _parseOptionalFiniteDouble(control['esx'], fallback: 1.0);
    final esy = _parseOptionalFiniteDouble(control['esy'], fallback: 1.0);
    final erot = _parseOptionalFiniteDouble(control['erot'], fallback: 0.0);
    final ea = _parseOptionalFiniteDouble(control['ea'], fallback: 1.0);
    final dur = _parseOptionalFiniteDouble(control['dur'], fallback: 0.3);
    final easing = control.containsKey('ease')
        ? CellTweenEasing.fromWireName(control['ease'])
        : CellTweenEasing.linear;
    final fromCurrent = _parseOptionalBool(control['cur'], fallback: false);
    final clearOnFinish = _parseOptionalBool(control['clr'], fallback: false);
    if (aid == null ||
        edx == null ||
        edy == null ||
        esx == null ||
        esy == null ||
        erot == null ||
        ea == null ||
        dur == null ||
        dur <= 0.0 ||
        easing == null ||
        fromCurrent == null ||
        clearOnFinish == null) {
      return (value: null, invalid: true);
    }
    return (
      value: CellTween(
        animationId: aid,
        endDx: edx,
        endDy: edy,
        endScaleX: esx
            .clamp(CellTransform.minScale, CellTransform.maxScale)
            .toDouble(),
        endScaleY: esy
            .clamp(CellTransform.minScale, CellTransform.maxScale)
            .toDouble(),
        endRotationRad: erot,
        endAlpha: ea.clamp(0.0, 1.0).toDouble(),
        durationSec: dur
            .clamp(CellTween.minDurationSec, CellTween.maxDurationSec)
            .toDouble(),
        easing: easing,
        fromCurrent: fromCurrent,
        clearOnFinish: clearOnFinish,
      ),
      invalid: false,
    );
  }

  void _handleBatchedXforms(Map<String, String> control, String dataPart) {
    final isMore = control['m'] == '1';
    final pending = _pendingXforms ??= _PendingXformsUpload(
      replace: _parseBool(control['replace']) ?? false,
    );
    _appendXformsChunk(pending, dataPart);
    if (isMore) return;
    _pendingXforms = null;
    if (pending.overflowed) return;
    final raw = _decodeBase64Bytes(
      pending.base64Data.toString(),
      maxBytes: _maxXformsRawBytes,
    );
    if (raw == null || raw.isEmpty) return;
    final List<CellTransformEntry> entries;
    try {
      entries = CellTransformCodec.unpackBatch(raw);
    } on FormatException {
      return;
    }
    _commitTransformBatch(entries, replace: pending.replace);
  }

  void _appendXformsChunk(_PendingXformsUpload pending, String dataPart) {
    if (pending.overflowed || dataPart.isEmpty) return;
    final clean = dataPart.replaceAll(_whitespaceRegex, '');
    if (clean.isEmpty) return;
    final nextChars = pending.charCount + clean.length;
    if (nextChars > _maxXformsBase64Chars) {
      pending.base64Data.clear();
      pending.charCount = 0;
      pending.overflowed = true;
      return;
    }
    pending.base64Data.write(clean);
    pending.charCount = nextChars;
  }

  void _commitTransformBatch(
    List<CellTransformEntry> entries, {
    required bool replace,
  }) {
    if (replace) _liveTransformKeys.clear();
    final accepted = <CellTransformEntry>[];
    for (final entry in entries) {
      final cellKey = (entry.row << 16) | entry.col;
      if (entry.transform == null) {
        _liveTransformKeys.remove(cellKey);
        accepted.add(entry);
        continue;
      }
      if (!_liveTransformKeys.contains(cellKey) &&
          _liveTransformKeys.length >= maxTransforms) {
        continue;
      }
      _liveTransformKeys.add(cellKey);
      accepted.add(entry);
    }
    if (accepted.isEmpty && !replace) return;
    onShaderEvent?.call(
      TerminalShaderTransformBatchEvent(entries: accepted, replace: replace),
    );
  }

  void _handleSet(Map<String, String> control) {
    final stage = (control['stage'] ?? 'post').trim().toLowerCase();
    if (!_validStages.contains(stage)) return;
    final clear =
        _parseBool(control['clear']) == true ||
        _parseBool(control['del']) == true;
    if (clear) {
      onShaderEvent?.call(TerminalShaderSetEvent(stage: stage, clear: true));
      return;
    }
    final presetId = control['preset'];
    final shaderId = control['id'] ?? control['s'];
    final hasPreset = presetId != null && _idPattern.hasMatch(presetId);
    final hasShader = shaderId != null && _idPattern.hasMatch(shaderId);
    if (!hasPreset && !hasShader) return;
    final paramsResult = _parseUniformParams(control);
    if (paramsResult == null) return;
    onShaderEvent?.call(
      TerminalShaderSetEvent(
        stage: stage,
        presetId: hasPreset ? presetId : null,
        shaderId: hasShader ? shaderId : null,
        params: paramsResult.params,
      ),
    );
  }

  void _handleUniform(Map<String, String> control) {
    final id = control['id'];
    if (id != null && !_idPattern.hasMatch(id)) return;
    final parsed = _parseUniformParams(control);
    if (parsed == null || parsed.mask == 0) return;
    onShaderEvent?.call(
      TerminalShaderUniformEvent(
        id: id,
        paramMask: parsed.mask,
        params: parsed.params,
      ),
    );
  }

  void _handleReset(Map<String, String> control) {
    final target = ShaderResetTarget.fromWireName(control['target']);
    if (target == null) return;
    switch (target) {
      case ShaderResetTarget.all:
        reset();
      case ShaderResetTarget.regions:
        _activeRegions.clear();
      case ShaderResetTarget.xforms:
        _liveTransformKeys.clear();
        _pendingXforms = null;
      case ShaderResetTarget.pane:
        break;
    }
    onShaderEvent?.call(TerminalResetShaderEvent(target: target));
  }

  static List<Rect>? _parseRects(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split('/');
    if (parts.isEmpty || parts.length > maxRectsPerRegion) return null;
    final rects = <Rect>[];
    for (final part in parts) {
      final nums = part.split(':');
      if (nums.length != 4) return null;
      final x = int.tryParse(nums[0]);
      final y = int.tryParse(nums[1]);
      final w = int.tryParse(nums[2]);
      final h = int.tryParse(nums[3]);
      if (x == null ||
          y == null ||
          w == null ||
          h == null ||
          x < 0 ||
          y < 0 ||
          w <= 0 ||
          h <= 0 ||
          x > 0xFFFF ||
          y > 0xFFFF ||
          w > 0xFFFF ||
          h > 0xFFFF) {
        return null;
      }
      rects.add(Rect(x, y, w, h));
    }
    return rects;
  }

  static CellPadding? _parsePadding(String? raw) {
    if (raw == null || raw.isEmpty) return CellPadding.zero;
    final nums = raw.split(':');
    if (nums.length != 4) return null;
    final t = int.tryParse(nums[0]);
    final r = int.tryParse(nums[1]);
    final b = int.tryParse(nums[2]);
    final l = int.tryParse(nums[3]);
    if (t == null || r == null || b == null || l == null) return null;
    if (t < 0 || r < 0 || b < 0 || l < 0) return null;
    return CellPadding(top: t, right: r, bottom: b, left: l).clamped();
  }

  static ({Float32List params, int mask})? _parseUniformParams(
    Map<String, String> control,
  ) {
    final params = Float32List(ShaderRegion.paramCount);
    var mask = 0;
    for (var i = 0; i < ShaderRegion.paramCount; i++) {
      final raw = control['p$i'];
      if (raw == null) continue;
      final value = double.tryParse(raw);
      if (value == null || !value.isFinite) return null;
      params[i] = value
          .clamp(ShaderRegion.minParamValue, ShaderRegion.maxParamValue)
          .toDouble();
      mask |= 1 << i;
    }
    return (params: params, mask: mask);
  }

  static int? _parseRequiredInt(String? raw, int minVal, int maxVal) {
    if (raw == null || raw.isEmpty) return null;
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < minVal || parsed > maxVal) return null;
    return parsed;
  }

  static int? _parseOptionalInt(
    String? raw,
    int minVal,
    int maxVal, {
    required int fallback,
  }) {
    if (raw == null || raw.isEmpty) return fallback;
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < minVal || parsed > maxVal) return null;
    return parsed;
  }

  static double? _parseOptionalFiniteDouble(
    String? raw, {
    required double fallback,
  }) {
    if (raw == null || raw.isEmpty) return fallback;
    final parsed = double.tryParse(raw);
    return (parsed != null && parsed.isFinite) ? parsed : null;
  }

  static bool? _parseBool(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return switch (raw.trim().toLowerCase()) {
      '1' || 'true' => true,
      '0' || 'false' => false,
      _ => null,
    };
  }

  static bool? _parseOptionalBool(String? raw, {required bool fallback}) {
    if (raw == null || raw.isEmpty) return fallback;
    return _parseBool(raw);
  }

  static Uint8List? _decodeBase64Bytes(String raw, {required int maxBytes}) {
    if (raw.isEmpty) return null;
    try {
      final decoded = base64Decode(raw);
      if (decoded.length > maxBytes) return null;
      return decoded;
    } on Object {
      return null;
    }
  }

  static String? _decodeUtf8Base64(String raw, {required int maxBytes}) {
    final bytes = _decodeBase64Bytes(raw, maxBytes: maxBytes);
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on Object {
      return null;
    }
  }
}
