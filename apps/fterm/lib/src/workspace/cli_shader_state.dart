import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_flutter/termui_flutter.dart'
    show
        BuiltinShaders,
        CliShaderRegistry,
        GpuFrameWatchdog,
        ShaderBackendKind,
        ShaderPassSpec,
        ShaderRegionPresets,
        TerminalShaderBackend,
        TerminalShaderConfig,
        TerminalShaderPreset,
        TerminalShaderStage;
import 'package:termui_pty/termui_pty.dart';

import '../settings_storage.dart';

/// Queued SHA-256 trust prompt for a custom CLI GLSL shader upload on a pane.
///
/// Approval actions bind strictly to [sha256] so a malicious PTY stream cannot
/// swap the shader source between prompt display and user confirmation (TOCTOU).
final class PendingCliShaderApproval {
  /// Owning workspace pane identifier.
  final String paneId;

  /// Human-readable pane label shown in the trust banner.
  final String paneLabel;

  /// Logical CLI shader slot ID (`a=define,id=...`).
  final String shaderId;

  /// Lowercase hex SHA-256 digest of [glslSource].
  final String sha256;

  /// Exact GLSL source bytes bound to [sha256].
  final String glslSource;

  /// Whether the shader requested previous-frame feedback (`persist=1`).
  final bool persist;

  /// Creates an immutable pending custom GLSL approval request.
  const PendingCliShaderApproval({
    required this.paneId,
    required this.paneLabel,
    required this.shaderId,
    required this.sha256,
    required this.glslSource,
    this.persist = false,
  });

  /// Short multi-line snippet of [glslSource] suitable for banner inspection.
  String get sourcePreview {
    final lines = glslSource.trim().split('\n');
    final preview = lines.take(5).join('\n');
    if (preview.length <= 280 && lines.length <= 5) return preview;
    final clipped = preview.length > 280 ? preview.substring(0, 280) : preview;
    return '$clipped…';
  }
}

/// User resolution choice when [CliFullPaneShaderMode.askOnConflict] detects
/// both CLI `a=set` and user Settings full-pane shaders.
enum CliFullPaneConflictChoice {
  /// Stack CLI passes before user Settings passes (CRT/bloom builds on top).
  cliBeforeUser,

  /// Let the active CLI full-pane pass replace user Settings passes.
  cliReplacesUser,

  /// Ignore the CLI full-pane pass and keep user Settings shaders only.
  keepUserOnly,
}

/// Pending user notice when a remote `termui_cast` session emits `0x1C` shader
/// frames while [FtermPreferences.remoteCliShaderPolicy] is
/// [CliShaderPolicy.disabled].
final class PendingBlockedRemoteShadersNotice {
  /// Owning workspace pane identifier.
  final String paneId;

  /// Human-readable pane label shown in the notice banner.
  final String paneLabel;

  /// Creates an immutable blocked remote shaders notice.
  const PendingBlockedRemoteShadersNotice({
    required this.paneId,
    required this.paneLabel,
  });
}

/// Pending user choice for a full-pane CLI vs user shader conflict.
final class PendingCliFullPaneConflict {
  /// Owning workspace pane identifier.
  final String paneId;

  /// Human-readable pane label.
  final String paneLabel;

  /// Stage requested by the CLI (`'bg'`, `'fg'`, or `'post'`).
  final String stage;

  /// Preset or custom shader identifier requested by the CLI.
  final String shaderLabel;

  /// Creates an immutable pending full-pane conflict notice.
  const PendingCliFullPaneConflict({
    required this.paneId,
    required this.paneLabel,
    required this.stage,
    required this.shaderLabel,
  });
}

final class _DefinedCliGlsl {
  final String id;
  final String sha256;
  final String source;
  final bool persist;

  const _DefinedCliGlsl({
    required this.id,
    required this.sha256,
    required this.source,
    required this.persist,
  });
}

final class _ActiveCliFullPanePass {
  final TerminalShaderStage stage;
  final String? presetId;
  final String? customShaderId;
  Float32List params;

  _ActiveCliFullPanePass({
    required this.stage,
    this.presetId,
    this.customShaderId,
    required this.params,
  });
}

/// Callback invoked when a pane quarantines an offending custom CLI shader ID.
typedef PaneCliShaderQuarantinedCallback = void Function(
  String paneId,
  String shaderId,
  String reason,
);

/// Manages per-pane CLI `ESC _ S` trust policy, SHA-256 approval prompts
/// (capped at `4`), compiled custom GLSL handles (`4s` compile timeout),
/// active regions, pane-clipped cell transforms, full-pane stacking, and
/// per-shader-ID [GpuFrameWatchdog] quarantine.
final class PaneCliShaderState {
  /// Maximum simultaneous queued custom GLSL trust prompts per pane.
  static const int maxPendingPrompts = 4;

  /// Maximum custom CLI GLSL slots remembered per pane.
  static const int maxCustomSlots = CliShaderRegistry.maxCliShaderSlots;

  /// Maximum active scoped regions per pane.
  static const int maxRegions = tui.ShaderRegion.maxRegionsPerPane;

  /// Owning pane identifier.
  final String paneId;

  /// Whether this pane hosts a local desktop shell (`false` for remote cast).
  final bool isLocal;

  /// Callback returning the current human-readable label for this pane.
  final String Function() readPaneLabel;

  /// Notifies the owning controller when display buffer metadata or shader
  /// state changed and needs recomposition/repaint.
  final void Function() onVisualStateChanged;

  /// Notifies the workspace when prompts, conflicts, or full-pane chains change.
  final void Function() onPolicyUiChanged;

  /// Notifies the workspace when the per-pane watchdog quarantines a shader ID.
  final PaneCliShaderQuarantinedCallback? onQuarantined;

  /// Per-pane compiled CLI shader registry (`4s` timeout, `32 KiB` cap).
  final CliShaderRegistry registry;

  /// Per-pane best-effort GPU watchdog isolating offending custom CLI shaders.
  final GpuFrameWatchdog watchdog;

  CliShaderPolicy _policy;
  CliFullPaneShaderMode _fullPaneMode;
  Set<String> _trustedHashes;
  bool _userHasFullPaneShaders = false;
  bool _disposed = false;

  final Set<String> _allowOnceHashes = <String>{};
  final Set<String> _deniedHashes = <String>{};
  final Map<String, PendingCliShaderApproval> _pendingByHash =
      <String, PendingCliShaderApproval>{};
  final Map<String, List<({String id, bool persist})>> _pendingDefsByHash =
      <String, List<({String id, bool persist})>>{};
  final Map<String, _DefinedCliGlsl> _approvedDefs =
      <String, _DefinedCliGlsl>{};
  final Set<String> _altScreenApprovedIds = <String>{};
  final Map<String, tui.ShaderRegion> _activeRegions =
      <String, tui.ShaderRegion>{};
  final tui.CellTransformTable _activeTransforms = tui.CellTransformTable();
  final Map<TerminalShaderStage, _ActiveCliFullPanePass> _fullPanePasses =
      <TerminalShaderStage, _ActiveCliFullPanePass>{};
  CliFullPaneConflictChoice? _resolvedConflictChoice;
  PendingCliFullPaneConflict? _pendingFullPaneConflict;
  bool _hasBlockedRemoteShaders = false;
  bool _blockedRemoteNoticeDismissed = false;

  /// Creates per-pane CLI shader state with the supplied initial policy.
  PaneCliShaderState({
    required this.paneId,
    required this.isLocal,
    required CliShaderPolicy initialPolicy,
    required CliFullPaneShaderMode initialFullPaneMode,
    required Set<String> trustedHashes,
    required this.readPaneLabel,
    required this.onVisualStateChanged,
    required this.onPolicyUiChanged,
    this.onQuarantined,
    TerminalShaderBackend? backend,
    GpuFrameWatchdog? watchdog,
    CliShaderRegistry? registry,
  }) : _policy = initialPolicy,
       _fullPaneMode = initialFullPaneMode,
       _trustedHashes = Set<String>.of(trustedHashes),
       watchdog =
           watchdog ??
           GpuFrameWatchdog(isBuiltinPreset: ShaderRegionPresets.isPreset),
       registry =
           registry ?? CliShaderRegistry(backend: backend, watchdog: watchdog) {
    this.registry.attachWatchdog(this.watchdog);
    if (backend != null) {
      this.registry.attachBackend(backend);
    }
    this.watchdog.onShaderQuarantined = _handleWatchdogQuarantine;
  }

  /// Active trust policy applied to this pane.
  CliShaderPolicy get policy => _policy;

  /// Active full-pane stacking mode for this pane.
  CliFullPaneShaderMode get fullPaneMode => _fullPaneMode;

  /// Queued custom GLSL approval prompts (`<= 4`) awaiting user decision.
  List<PendingCliShaderApproval> get pendingApprovals =>
      List<PendingCliShaderApproval>.unmodifiable(_pendingByHash.values);

  /// Pending full-pane shader conflict prompt when [fullPaneMode] is
  /// [CliFullPaneShaderMode.askOnConflict], or `null` when resolved/absent.
  PendingCliFullPaneConflict? get pendingFullPaneConflict =>
      _pendingFullPaneConflict;

  /// Notice shown when this remote pane received blocked `0x1C` shader frames
  /// while [policy] is [CliShaderPolicy.disabled], or `null` when none/dismissed.
  PendingBlockedRemoteShadersNotice? get pendingBlockedRemoteNotice {
    if (isLocal ||
        _policy != CliShaderPolicy.disabled ||
        !_hasBlockedRemoteShaders ||
        _blockedRemoteNoticeDismissed) {
      return null;
    }
    return PendingBlockedRemoteShadersNotice(
      paneId: paneId,
      paneLabel: readPaneLabel(),
    );
  }

  /// Dismisses the blocked remote shader notice on this pane until reset.
  void dismissBlockedRemoteNotice() {
    if (_disposed || _blockedRemoteNoticeDismissed) return;
    _blockedRemoteNoticeDismissed = true;
    onPolicyUiChanged();
  }

  /// Whether any policy-allowed regions or cell transforms are currently active.
  bool get hasActiveOverlays =>
      _policy != CliShaderPolicy.disabled &&
      (_activeRegions.isNotEmpty || _activeTransforms.isNotEmpty);

  /// Whether this pane has any active CLI full-pane `a=set` passes.
  bool get hasActiveFullPanePasses =>
      _policy != CliShaderPolicy.disabled && _fullPanePasses.isNotEmpty;

  /// Computes lowercase hex SHA-256 digest of [glslSource].
  static String computeSha256(String glslSource) =>
      sha256.convert(utf8.encode(glslSource)).toString();

  /// Builds the canonical custom-pass source key used by `TerminalShaderController`.
  static String fullPanePassId(
    String paneId,
    TerminalShaderStage stage,
    String id,
  ) => 'cli:$paneId:${stage.name}:$id';

  /// Looks up approved GLSL source for a full-pane pass key [passId], if any.
  String? lookupApprovedFullPaneSource(String passId) {
    final prefix = 'cli:$paneId:';
    if (!passId.startsWith(prefix)) return null;
    final rest = passId.substring(prefix.length);
    final sep = rest.indexOf(':');
    if (sep < 0) return null;
    final shaderId = rest.substring(sep + 1);
    if (registry.isQuarantined(shaderId)) return null;
    return _approvedDefs[shaderId]?.source;
  }

  /// Attaches or switches the backing GPU/WebGL2 [backend].
  void attachBackend(TerminalShaderBackend? backend) {
    if (_disposed) return;
    registry.attachBackend(backend);
    if (backend != null && backend.supportsCustomGlsl) {
      for (final def in _approvedDefs.values) {
        if (!registry.isQuarantined(def.id)) {
          _compileApprovedDefinition(def);
        }
      }
      _ensureActiveRegionPresetsCompiled();
    }
  }

  /// Builds the [TerminalShaderCapabilities] advertised on `ESC _ S a=query`.
  TerminalShaderCapabilities resolveCapabilities(
    ShaderBackendKind backendKind,
  ) {
    if (_policy == CliShaderPolicy.disabled) {
      return (
        backend: 'disabled',
        glsl: false,
        xform: false,
        region: false,
        maxSlots: 0,
        maxRegions: 0,
      );
    }
    if (backendKind == ShaderBackendKind.disabled) {
      return defaultDisabledShaderCapabilities;
    }
    final backendName = switch (backendKind) {
      ShaderBackendKind.flutterGpu => 'flutter_gpu',
      ShaderBackendKind.webGl2 => 'webgl2',
      ShaderBackendKind.disabled => 'disabled',
    };
    final allowGlsl =
        _policy == CliShaderPolicy.promptCustomGlsl ||
        _policy == CliShaderPolicy.allowLocalCustomGlsl;
    return (
      backend: backendName,
      glsl: allowGlsl,
      xform: true,
      region: true,
      maxSlots: maxCustomSlots,
      maxRegions: maxRegions,
    );
  }

  /// Updates policy, stacking mode, trusted hashes, and whether user Settings
  /// shaders are active, downgrading/clearing disallowed CLI state immediately.
  void updatePolicy({
    required CliShaderPolicy policy,
    required CliFullPaneShaderMode fullPaneMode,
    required Set<String> trustedHashes,
    required bool userHasFullPaneShaders,
  }) {
    if (_disposed) return;
    final prevPolicy = _policy;
    final prevMode = _fullPaneMode;
    _policy = policy;
    _fullPaneMode = fullPaneMode;
    _trustedHashes = Set<String>.of(trustedHashes);
    _userHasFullPaneShaders = userHasFullPaneShaders;

    if (policy == CliShaderPolicy.disabled) {
      resetAll(notify: true);
      return;
    }
    _hasBlockedRemoteShaders = false;
    _blockedRemoteNoticeDismissed = false;
    if (policy == CliShaderPolicy.presetsAndTransforms &&
        prevPolicy != CliShaderPolicy.presetsAndTransforms) {
      _clearCustomGlslOnly();
    }
    if (prevMode != fullPaneMode) {
      _resolvedConflictChoice = null;
      _refreshFullPaneConflict();
    }
    _promoteNowTrustedPending();
    onVisualStateChanged();
    onPolicyUiChanged();
  }

  /// Handles an inbound `ESC _ S` (local) or `0x1C` (remote) shader event.
  void handleShaderEvent(
    TerminalShaderApcEvent event, {
    bool onAltScreen = false,
  }) {
    if (_disposed) return;
    if (event case TerminalResetShaderEvent(
      :final target,
      :final altScreenExit,
    )) {
      _handleReset(target, altScreenExit: altScreenExit);
      return;
    }
    if (_policy == CliShaderPolicy.disabled) {
      if (!isLocal &&
          event is! TerminalShaderQueryEvent &&
          !_hasBlockedRemoteShaders) {
        _hasBlockedRemoteShaders = true;
        onPolicyUiChanged();
      }
      return;
    }
    switch (event) {
      case TerminalShaderQueryEvent():
        break;
      case TerminalShaderDefineEvent():
        _handleDefine(event, onAltScreen: onAltScreen);
      case TerminalShaderRegionEvent():
        _handleRegion(event);
      case TerminalShaderTransformBatchEvent():
        _handleTransforms(event);
      case TerminalShaderSetEvent():
        _handleSet(event);
      case TerminalShaderUniformEvent():
        _handleUniform(event);
      case TerminalResetShaderEvent():
        break;
    }
  }

  /// Approves any queued custom GLSL prompt strictly matching [sha256].
  ///
  /// Returns `true` if a pending prompt matched [sha256].
  bool approveHash(String sha256, {required bool remember}) {
    if (_disposed || _policy == CliShaderPolicy.disabled) return false;
    final normalized = sha256.trim().toLowerCase();
    if (remember) {
      _trustedHashes.add(normalized);
    } else {
      _allowOnceHashes.add(normalized);
    }
    _deniedHashes.remove(normalized);
    final pending = _pendingByHash.remove(normalized);
    final queuedDefs = _pendingDefsByHash.remove(normalized);
    if (pending == null) return false;
    final defs = queuedDefs != null && queuedDefs.isNotEmpty
        ? queuedDefs
        : <({String id, bool persist})>[
            (id: pending.shaderId, persist: pending.persist),
          ];
    for (final entry in defs) {
      _activateApprovedDefinition(
        _DefinedCliGlsl(
          id: entry.id,
          sha256: pending.sha256,
          source: pending.glslSource,
          persist: entry.persist,
        ),
      );
    }
    onVisualStateChanged();
    onPolicyUiChanged();
    return true;
  }

  /// Denies and removes any pending custom GLSL prompt matching [sha256].
  bool denyHash(String sha256) {
    if (_disposed) return false;
    final normalized = sha256.trim().toLowerCase();
    _deniedHashes.add(normalized);
    _allowOnceHashes.remove(normalized);
    _pendingDefsByHash.remove(normalized);
    final removed = _pendingByHash.remove(normalized) != null;
    if (removed) {
      onPolicyUiChanged();
    }
    return removed;
  }

  /// Denies and clears all queued custom GLSL approval prompts on this pane.
  void denyAllPending() {
    if (_disposed || _pendingByHash.isEmpty) return;
    _deniedHashes.addAll(_pendingByHash.keys);
    _pendingByHash.clear();
    _pendingDefsByHash.clear();
    onPolicyUiChanged();
  }

  /// Resolves an active [CliFullPaneShaderMode.askOnConflict] prompt.
  void resolveFullPaneConflict(CliFullPaneConflictChoice choice) {
    if (_disposed) return;
    _resolvedConflictChoice = choice;
    _pendingFullPaneConflict = null;
    onVisualStateChanged();
    onPolicyUiChanged();
  }

  /// Resets all CLI shader definitions, prompts, regions, transforms, and
  /// full-pane overrides on this pane (called on pane exit, `RIS`, `DECSTR`,
  /// or policy downgrade to `disabled`).
  void resetAll({bool notify = true}) {
    _pendingByHash.clear();
    _pendingDefsByHash.clear();
    _allowOnceHashes.clear();
    _approvedDefs.clear();
    _altScreenApprovedIds.clear();
    _activeRegions.clear();
    _activeTransforms.clear();
    _fullPanePasses.clear();
    _resolvedConflictChoice = null;
    _pendingFullPaneConflict = null;
    _hasBlockedRemoteShaders = false;
    _blockedRemoteNoticeDismissed = false;
    registry.clearCliShaders();
    watchdog.reset();
    if (notify && !_disposed) {
      onVisualStateChanged();
      onPolicyUiChanged();
    }
  }

  /// Applies policy-filtered [tui.ShaderRegion]s and clamped [tui.CellTransform]s onto
  /// [out], using [src] when the local `VirtualTerminal` already maintains
  /// scroll-shifted/alt-screen-isolated geometry.
  void applyOverlaysToBuffer(tui.Buffer out, tui.Buffer src) {
    if (_policy == CliShaderPolicy.disabled) {
      out.clearShaderRegions();
      out.clearCellTransforms();
      return;
    }

    out.clearCellTransforms();
    _applyTransformsToBuffer(out, src);
    _applyRegionsToBuffer(out, src);
  }

  /// Combines active CLI `a=set` full-pane passes with [userConfig] according
  /// to [fullPaneMode] (default [CliFullPaneShaderMode.cliBeforeUser]).
  TerminalShaderConfig resolveFullPaneConfig(TerminalShaderConfig userConfig) {
    if (_policy == CliShaderPolicy.disabled || _fullPanePasses.isEmpty) {
      return userConfig;
    }
    final userHasPasses =
        userConfig.backgroundPasses.isNotEmpty ||
        userConfig.foregroundPasses.isNotEmpty;
    final effectiveChoice = _effectiveStackChoice(userHasPasses);
    if (effectiveChoice == CliFullPaneConflictChoice.keepUserOnly ||
        effectiveChoice == null) {
      return userConfig;
    }

    final cliBg = _buildCliFullPanePass(TerminalShaderStage.background);
    final cliFg = _buildCliFullPanePass(TerminalShaderStage.foreground);
    if (cliBg == null && cliFg == null) return userConfig;

    final nextBg = _mergeStagePasses(
      cliPass: cliBg,
      userPasses: userConfig.backgroundPasses,
      replace: effectiveChoice == CliFullPaneConflictChoice.cliReplacesUser,
    );
    final nextFg = _mergeStagePasses(
      cliPass: cliFg,
      userPasses: userConfig.foregroundPasses,
      replace: effectiveChoice == CliFullPaneConflictChoice.cliReplacesUser,
    );
    return userConfig.copyWith(
      backgroundPasses: nextBg,
      foregroundPasses: nextFg,
    );
  }

  /// Collects any active CLI full-pane pass specs for workspace compilation sync.
  List<ShaderPassSpec> collectActiveCliFullPanePasses() {
    if (_policy == CliShaderPolicy.disabled || _fullPanePasses.isEmpty) {
      return const <ShaderPassSpec>[];
    }
    final bg = _buildCliFullPanePass(TerminalShaderStage.background);
    final fg = _buildCliFullPanePass(TerminalShaderStage.foreground);
    return <ShaderPassSpec>[?bg, ?fg];
  }

  /// Disposes the per-pane [CliShaderRegistry] and [GpuFrameWatchdog].
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    watchdog.onShaderQuarantined = null;
    watchdog.dispose();
    registry.dispose();
    _pendingByHash.clear();
    _pendingDefsByHash.clear();
    _approvedDefs.clear();
    _altScreenApprovedIds.clear();
    _activeRegions.clear();
    _activeTransforms.clear();
    _fullPanePasses.clear();
  }

  void _handleDefine(
    TerminalShaderDefineEvent event, {
    bool onAltScreen = false,
  }) {
    if (_policy == CliShaderPolicy.presetsAndTransforms) return;
    final byteLen = utf8.encode(event.glslSource).length;
    if (byteLen == 0 || byteLen > CliShaderRegistry.maxCliSourceBytes) return;

    final hash = computeSha256(event.glslSource);
    if (_deniedHashes.contains(hash)) return;

    final autoTrust =
        (isLocal && _policy == CliShaderPolicy.allowLocalCustomGlsl) ||
        _trustedHashes.contains(hash) ||
        _allowOnceHashes.contains(hash);
    if (autoTrust) {
      _activateApprovedDefinition(
        _DefinedCliGlsl(
          id: event.id,
          sha256: hash,
          source: event.glslSource,
          persist: event.persist,
        ),
        fromAltScreen: onAltScreen,
      );
      onVisualStateChanged();
      onPolicyUiChanged();
      return;
    }

    final existingDefs = _pendingDefsByHash[hash];
    if (existingDefs != null) {
      final idx = existingDefs.indexWhere((e) => e.id == event.id);
      if (idx >= 0) {
        existingDefs[idx] = (id: event.id, persist: event.persist);
      } else if (existingDefs.length < maxCustomSlots) {
        existingDefs.add((id: event.id, persist: event.persist));
      }
      return;
    }
    if (_pendingByHash.length >= maxPendingPrompts) return;
    _pendingDefsByHash[hash] = <({String id, bool persist})>[
      (id: event.id, persist: event.persist),
    ];
    _pendingByHash[hash] = PendingCliShaderApproval(
      paneId: paneId,
      paneLabel: readPaneLabel(),
      shaderId: event.id,
      sha256: hash,
      glslSource: event.glslSource,
      persist: event.persist,
    );
    onPolicyUiChanged();
  }

  void _handleRegion(TerminalShaderRegionEvent event) {
    if (event.remove || event.region == null) {
      if (_activeRegions.remove(event.id) != null) {
        onVisualStateChanged();
      }
      return;
    }
    final region = event.region!;
    if (!_activeRegions.containsKey(region.id) &&
        _activeRegions.length >= maxRegions) {
      return;
    }
    _activeRegions[region.id] = region;
    _ensurePresetCompiledIfNeeded(region);
    onVisualStateChanged();
  }

  void _handleTransforms(TerminalShaderTransformBatchEvent event) {
    if (event.replace) {
      _activeTransforms.clear();
    }
    for (final entry in event.entries) {
      final key = (entry.row << 16) | entry.col;
      final t = entry.transform;
      if (t == null || t.isIdentity) {
        _activeTransforms.remove(key);
      } else {
        _activeTransforms.set(key, t.sanitized());
      }
    }
    onVisualStateChanged();
  }

  void _handleSet(TerminalShaderSetEvent event) {
    final stage = event.stage == 'bg'
        ? TerminalShaderStage.background
        : TerminalShaderStage.foreground;
    if (event.clear) {
      if (_fullPanePasses.remove(stage) != null) {
        _refreshFullPaneConflict();
        onVisualStateChanged();
        onPolicyUiChanged();
      }
      return;
    }
    final preset = event.presetId;
    final customId = event.shaderId;
    if (preset != null) {
      final resolved = TerminalShaderPreset.fromWireName(preset);
      if (resolved == TerminalShaderPreset.none) return;
      _fullPanePasses[stage] = _ActiveCliFullPanePass(
        stage: stage,
        presetId: resolved.wireName,
        params: tui.ShaderRegion.sanitizeParams(event.params),
      );
    } else if (customId != null) {
      if (_policy == CliShaderPolicy.presetsAndTransforms) return;
      _fullPanePasses[stage] = _ActiveCliFullPanePass(
        stage: stage,
        customShaderId: customId,
        params: tui.ShaderRegion.sanitizeParams(event.params),
      );
    } else {
      return;
    }
    _refreshFullPaneConflict();
    onVisualStateChanged();
    onPolicyUiChanged();
  }

  void _handleUniform(TerminalShaderUniformEvent event) {
    final targetId = event.id;
    if (targetId == null) {
      var changed = false;
      for (final pass in _fullPanePasses.values) {
        _applyParamMask(pass.params, event.paramMask, event.params);
        changed = true;
      }
      if (changed) {
        onVisualStateChanged();
        onPolicyUiChanged();
      }
      return;
    }
    final region = _activeRegions[targetId];
    if (region == null) return;
    final nextParams = Float32List.fromList(region.params);
    _applyParamMask(nextParams, event.paramMask, event.params);
    _activeRegions[targetId] = region.copyWith(params: nextParams);
    onVisualStateChanged();
  }

  void _handleReset(ShaderResetTarget target, {bool altScreenExit = false}) {
    switch (target) {
      case ShaderResetTarget.all:
        if (altScreenExit) {
          _resetAltScreenOnly();
        } else {
          resetAll(notify: true);
        }
      case ShaderResetTarget.regions:
        _activeRegions.clear();
        onVisualStateChanged();
      case ShaderResetTarget.xforms:
        _activeTransforms.clear();
        onVisualStateChanged();
      case ShaderResetTarget.pane:
        _fullPanePasses.clear();
        _pendingFullPaneConflict = null;
        _resolvedConflictChoice = null;
        onVisualStateChanged();
        onPolicyUiChanged();
    }
  }

  void _resetAltScreenOnly() {
    _pendingByHash.clear();
    _pendingDefsByHash.clear();
    _activeRegions.clear();
    _activeTransforms.clear();
    _fullPanePasses.clear();
    _resolvedConflictChoice = null;
    _pendingFullPaneConflict = null;
    for (final altId in _altScreenApprovedIds) {
      _approvedDefs.remove(altId);
      registry.removeCliShader(altId);
    }
    _altScreenApprovedIds.clear();
    if (!_disposed) {
      onVisualStateChanged();
      onPolicyUiChanged();
    }
  }

  void _clearCustomGlslOnly() {
    _pendingByHash.clear();
    _pendingDefsByHash.clear();
    _allowOnceHashes.clear();
    _approvedDefs.clear();
    _altScreenApprovedIds.clear();
    _fullPanePasses.removeWhere((_, pass) => pass.customShaderId != null);
    registry.clearCliShaders();
    _refreshFullPaneConflict();
  }

  void _promoteNowTrustedPending() {
    if (_pendingByHash.isEmpty) return;
    final toApprove = <PendingCliShaderApproval>[
      for (final pending in _pendingByHash.values)
        if ((isLocal && _policy == CliShaderPolicy.allowLocalCustomGlsl) ||
            _trustedHashes.contains(pending.sha256) ||
            _allowOnceHashes.contains(pending.sha256))
          pending,
    ];
    for (final item in toApprove) {
      _pendingByHash.remove(item.sha256);
      final queuedDefs = _pendingDefsByHash.remove(item.sha256);
      final defs = queuedDefs != null && queuedDefs.isNotEmpty
          ? queuedDefs
          : <({String id, bool persist})>[
              (id: item.shaderId, persist: item.persist),
            ];
      for (final entry in defs) {
        _activateApprovedDefinition(
          _DefinedCliGlsl(
            id: entry.id,
            sha256: item.sha256,
            source: item.glslSource,
            persist: entry.persist,
          ),
        );
      }
    }
  }

  void _activateApprovedDefinition(
    _DefinedCliGlsl def, {
    bool fromAltScreen = false,
  }) {
    final existedBefore = _approvedDefs.containsKey(def.id);
    if (!existedBefore && _approvedDefs.length >= maxCustomSlots) {
      return;
    }
    _approvedDefs[def.id] = def;
    if (fromAltScreen && !existedBefore) {
      _altScreenApprovedIds.add(def.id);
    } else if (!fromAltScreen) {
      _altScreenApprovedIds.remove(def.id);
    }
    _compileApprovedDefinition(def);
  }

  void _compileApprovedDefinition(_DefinedCliGlsl def) {
    unawaited(
      registry
          .registerCliShader(
            id: def.id,
            source: def.source,
            usesPrevFrame: def.persist,
            timeout: CliShaderRegistry.cliCompileTimeout,
          )
          .catchError((Object _) => null),
    );
  }

  void _ensurePresetCompiledIfNeeded(tui.ShaderRegion region) {
    if (!ShaderRegionPresets.isPreset(region.shaderId)) return;
    if (registry.handleForShader(region.shaderId) != null ||
        registry.isQuarantined(region.shaderId)) {
      return;
    }
    unawaited(
      registry
          .ensureRegionShaderCompiled(region)
          .catchError((Object _) => null),
    );
  }

  void _ensureActiveRegionPresetsCompiled() {
    for (final region in _activeRegions.values) {
      _ensurePresetCompiledIfNeeded(region);
    }
  }

  void _handleWatchdogQuarantine(String shaderId, String reason) {
    if (_disposed || ShaderRegionPresets.isPreset(shaderId)) return;
    registry.quarantineShader(shaderId, reason);
    _fullPanePasses.removeWhere((_, pass) => pass.customShaderId == shaderId);
    onQuarantined?.call(paneId, shaderId, reason);
    onVisualStateChanged();
    onPolicyUiChanged();
  }

  bool _isShaderIdAllowed(String shaderId) {
    if (ShaderRegionPresets.isPreset(shaderId)) return true;
    if (_policy == CliShaderPolicy.presetsAndTransforms ||
        _policy == CliShaderPolicy.disabled) {
      return false;
    }
    if (registry.isQuarantined(shaderId)) return false;
    return _approvedDefs.containsKey(shaderId);
  }

  void _applyTransformsToBuffer(tui.Buffer out, tui.Buffer src) {
    if (isLocal) {
      if (!src.hasCellTransforms || src.width <= 0) return;
      final srcTable = src.cellTransforms!;
      for (final entry in srcTable.entries) {
        final x = entry.key % src.width;
        final y = entry.key ~/ src.width;
        if (x >= 0 && x < out.width && y >= 0 && y < out.height) {
          out.setCellTransform(x, y, entry.value.sanitized());
        }
      }
      return;
    }
    for (final entry in _activeTransforms.entries) {
      final col = entry.key & 0xFFFF;
      final row = (entry.key >> 16) & 0xFFFF;
      if (col < out.width && row < out.height) {
        out.setCellTransform(col, row, entry.value.sanitized());
      }
    }
  }

  void _applyRegionsToBuffer(tui.Buffer out, tui.Buffer src) {
    final Iterable<tui.ShaderRegion> sourceRegions = isLocal
        ? src.shaderRegions
        : _activeRegions.values;
    final desired = <tui.ShaderRegion>[];
    for (final region in sourceRegions) {
      if (!_isShaderIdAllowed(region.shaderId)) continue;
      final effectiveRegion = isLocal
          ? region
          : (_activeRegions[region.id] ?? region);
      final merged = isLocal
          ? region
          : region.copyWith(params: effectiveRegion.params);
      final clipped = merged.translatedAndClipped(0, 0, out.activeClip);
      if (clipped == null) continue;
      desired.add(clipped);
      _ensurePresetCompiledIfNeeded(clipped);
    }
    if (_shaderRegionsEqual(out.shaderRegions, desired)) {
      return;
    }
    out.clearShaderRegions();
    for (final region in desired) {
      out.addShaderRegion(region);
    }
  }

  static bool _shaderRegionsEqual(
    List<tui.ShaderRegion> a,
    List<tui.ShaderRegion> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _refreshFullPaneConflict() {
    if (_fullPaneMode != CliFullPaneShaderMode.askOnConflict ||
        !_userHasFullPaneShaders ||
        _fullPanePasses.isEmpty ||
        _resolvedConflictChoice != null) {
      _pendingFullPaneConflict = null;
      return;
    }
    final first = _fullPanePasses.values.first;
    _pendingFullPaneConflict = PendingCliFullPaneConflict(
      paneId: paneId,
      paneLabel: readPaneLabel(),
      stage: first.stage == TerminalShaderStage.background ? 'bg' : 'post',
      shaderLabel: first.presetId ?? first.customShaderId ?? 'cli_shader',
    );
  }

  CliFullPaneConflictChoice? _effectiveStackChoice(bool userHasPasses) =>
      switch (_fullPaneMode) {
        CliFullPaneShaderMode.cliBeforeUser =>
          CliFullPaneConflictChoice.cliBeforeUser,
        CliFullPaneShaderMode.cliReplacesUser =>
          CliFullPaneConflictChoice.cliReplacesUser,
        CliFullPaneShaderMode.askOnConflict =>
          userHasPasses
              ? _resolvedConflictChoice
              : CliFullPaneConflictChoice.cliBeforeUser,
      };

  ShaderPassSpec? _buildCliFullPanePass(TerminalShaderStage stage) {
    final active = _fullPanePasses[stage];
    if (active == null) return null;
    if (active.presetId case final presetName?) {
      final preset = TerminalShaderPreset.fromWireName(presetName);
      if (preset == TerminalShaderPreset.none) return null;
      return ShaderPassSpec(
        id: fullPanePassId(paneId, stage, presetName),
        stage: stage,
        preset: preset,
        usesPrevFrame: BuiltinShaders.usesPrevFrame(preset),
        params: Float32List.fromList(active.params),
      );
    }
    final customId = active.customShaderId;
    if (customId == null || !_isShaderIdAllowed(customId)) return null;
    final def = _approvedDefs[customId]!;
    final passId = fullPanePassId(paneId, stage, customId);
    return ShaderPassSpec(
      id: passId,
      stage: stage,
      customSourcePath: passId,
      usesPrevFrame: def.persist,
      params: Float32List.fromList(active.params),
    );
  }

  static List<ShaderPassSpec> _mergeStagePasses({
    required ShaderPassSpec? cliPass,
    required List<ShaderPassSpec> userPasses,
    required bool replace,
  }) {
    if (cliPass == null) return userPasses;
    if (replace) return <ShaderPassSpec>[cliPass];
    return <ShaderPassSpec>[cliPass, ...userPasses];
  }

  static void _applyParamMask(Float32List dst, int mask, Float32List src) {
    for (var i = 0; i < tui.ShaderRegion.paramCount && i < dst.length; i++) {
      if ((mask & (1 << i)) != 0 && src[i].isFinite) {
        dst[i] = src[i]
            .clamp(
              tui.ShaderRegion.minParamValue,
              tui.ShaderRegion.maxParamValue,
            )
            .toDouble();
      }
    }
  }
}
