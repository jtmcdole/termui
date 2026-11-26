import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:termui_flutter/termui_flutter.dart'
    show
        ShaderBackendKind,
        ShaderCompileException,
        ShaderDiagnostic,
        ShaderDiagnosticSeverity,
        ShaderPassSpec,
        ShaderStageHint,
        ShadertoyGlslShim,
        TerminalShaderPreset,
        TerminalShaderStage;

import '../../commands/fterm_capability_context.dart';
import '../../commands/settings_descriptors.dart';
import '../../workspace/fterm_workspace_controller.dart';
import '../fterm_overlays.dart';
import 'settings_descriptor_renderer.dart';
import 'settings_primitives.dart';

Widget _renderShaderSetting(
  String id, {
  required FtermWorkspaceController workspace,
  required FtermOverlayPalette palette,
  required FtermCapabilityContext capabilities,
}) {
  final descriptor = settingDescriptorById(id);
  if (descriptor == null) return const SizedBox.shrink();
  return buildSettingDescriptorWidget(
    descriptor,
    workspace: workspace,
    palette: palette,
    capabilities: capabilities,
  );
}

/// Renders all collapsible panels for the **Shaders** sidebar section, or a
/// single filtered panel when [SettingsPanelFilter.onlyPanelId] is supplied by
/// unified search.
final class SettingsShadersSection extends StatefulWidget {
  /// Backing workspace controller.
  final FtermWorkspaceController workspace;

  /// Active overlay palette.
  final FtermOverlayPalette palette;

  /// Whether the host is running on Web/Wasm.
  final bool isWeb;

  /// Panel visibility, collapse state, and search-filter configuration.
  final SettingsPanelFilter filter;

  /// Creates the Shaders settings section or single search-filtered panel.
  const SettingsShadersSection({
    super.key,
    required this.workspace,
    required this.palette,
    required this.isWeb,
    this.filter = const SettingsPanelFilter.showAll(),
  });

  @override
  State<SettingsShadersSection> createState() => _SettingsShadersSectionState();
}

final class _SettingsShadersSectionState extends State<SettingsShadersSection> {
  static const List<TerminalShaderPreset> _bgPresets = <TerminalShaderPreset>[
    .wallpaperWave,
  ];
  static const List<TerminalShaderPreset> _fgPresets = <TerminalShaderPreset>[
    .cursorGlow,
    .scanlineOverlay,
    .crtLottes,
    .phosphorGlow,
    .retroPhosphor,
  ];

  late final TextEditingController _customPathCtrl;
  late final TextEditingController _webNameCtrl;
  late final TextEditingController _webSourceCtrl;
  bool _showCustomPathForm = false;
  bool _showWebGlslForm = false;
  TerminalShaderStage _webUploadStage = .foreground;
  bool _webUploadStageLocked = false;
  ShaderStageHint? _webDetectedStageHint;

  @override
  void initState() {
    super.initState();
    _customPathCtrl = TextEditingController();
    _webNameCtrl = TextEditingController(text: 'custom.glsl');
    _webSourceCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _customPathCtrl.dispose();
    _webNameCtrl.dispose();
    _webSourceCtrl.dispose();
    super.dispose();
  }

  void _addCustomShaderPath(TerminalShaderStage stage) {
    final trimmed = _customPathCtrl.text.trim();
    if (trimmed.isEmpty) return;
    _customPathCtrl.clear();
    if (stage == .background) {
      final next = <String>[
        ...widget.workspace.backgroundShaderChain,
        if (!widget.workspace.backgroundShaderChain.contains(trimmed)) trimmed,
      ];
      unawaited(widget.workspace.setBackgroundShaderChain(next));
      return;
    }
    final next = <String>[
      ...widget.workspace.foregroundShaderChain,
      if (!widget.workspace.foregroundShaderChain.contains(trimmed)) trimmed,
    ];
    unawaited(widget.workspace.setForegroundShaderChain(next));
  }

  void _onWebGlslSourceChanged(String source) {
    ShaderStageHint? detected;
    try {
      detected = ShadertoyGlslShim.analyze(source).stageHint;
    } on Object {
      detected = null;
    }
    setState(() {
      _webDetectedStageHint = detected;
      if (!_webUploadStageLocked && detected != null) {
        _webUploadStage = detected == .background ? .background : .foreground;
      }
    });
  }

  void _selectWebUploadStage(TerminalShaderStage stage) {
    setState(() {
      _webUploadStage = stage;
      _webUploadStageLocked = true;
    });
  }

  void _submitWebGlsl() {
    final name = _webNameCtrl.text.trim();
    final source = _webSourceCtrl.text;
    if (name.isEmpty || source.trim().isEmpty) return;
    unawaited(
      widget.workspace.uploadCustomShader(name, source, stage: _webUploadStage),
    );
    setState(() {
      _showWebGlslForm = false;
      _webUploadStageLocked = false;
      _webDetectedStageHint = null;
    });
  }

  ShaderPassSpec? _primaryActivePass() {
    final cfg = widget.workspace.activeShaderConfig;
    if (cfg.foregroundPasses.isNotEmpty) return cfg.foregroundPasses.first;
    if (cfg.backgroundPasses.isNotEmpty) return cfg.backgroundPasses.first;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final filter = widget.filter;
    final ws = widget.workspace;
    final palette = widget.palette;

    return SettingsSpacedColumn(
      key: filter.onlyPanelId == null
          ? const ValueKey('settings-shaders-section')
          : null,
      children: [
        if (filter.showPanel('shaders-pipeline'))
          _ShadersPipelinePanel(
            workspace: ws,
            palette: palette,
            isWeb: widget.isWeb,
            filter: filter,
            showWebGlslForm: _showWebGlslForm,
            webNameCtrl: _webNameCtrl,
            webSourceCtrl: _webSourceCtrl,
            webUploadStage: _webUploadStage,
            webDetectedStageHint: _webDetectedStageHint,
            onToggleWebUpload: () =>
                setState(() => _showWebGlslForm = !_showWebGlslForm),
            onWebSourceChanged: _onWebGlslSourceChanged,
            onWebStageSelected: _selectWebUploadStage,
            onWebSubmit: _submitWebGlsl,
          ),
        if (filter.showPanel('shaders-background'))
          _ShadersChainPanel(
            id: 'shaders-background',
            title: 'Background Shaders',
            keyPrefix: 'settings-bg-shader',
            stage: .background,
            presets: _bgPresets,
            activeChain: ws.backgroundShaderChain,
            showLegend: true,
            workspace: ws,
            palette: palette,
            filter: filter,
            onToggle: (entry) => unawaited(ws.toggleBackgroundShader(entry)),
            onMove: (from, to) => unawaited(ws.moveBackgroundShader(from, to)),
          ),
        if (filter.showPanel('shaders-foreground'))
          _ShadersChainPanel(
            id: 'shaders-foreground',
            title: 'Foreground Shaders',
            keyPrefix: 'settings-fg-shader',
            stage: .foreground,
            presets: _fgPresets,
            activeChain: ws.foregroundShaderChain,
            showLegend: false,
            workspace: ws,
            palette: palette,
            filter: filter,
            onToggle: (entry) => unawaited(ws.toggleForegroundShader(entry)),
            onMove: (from, to) => unawaited(ws.moveForegroundShader(from, to)),
          ),
        if (filter.showPanel('shaders-custom-params'))
          _ShadersCustomParamsPanel(
            workspace: ws,
            palette: palette,
            isWeb: widget.isWeb,
            filter: filter,
            primaryPass: _primaryActivePass(),
            customPathCtrl: _customPathCtrl,
            showCustomPathForm: _showCustomPathForm,
            onToggleCustomPathForm: () =>
                setState(() => _showCustomPathForm = !_showCustomPathForm),
            onAddBackground: () => _addCustomShaderPath(.background),
            onAddForeground: () => _addCustomShaderPath(.foreground),
          ),
        if (filter.showPanel('shaders-playback'))
          _ShadersPlaybackPanel(
            workspace: ws,
            palette: palette,
            filter: filter,
          ),
        if (filter.showPanel('shaders-cli'))
          _ShadersCliPanel(workspace: ws, palette: palette, filter: filter),
      ],
    );
  }
}

final class _ShadersPipelinePanel extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final bool isWeb;
  final SettingsPanelFilter filter;
  final bool showWebGlslForm;
  final TextEditingController webNameCtrl;
  final TextEditingController webSourceCtrl;
  final TerminalShaderStage webUploadStage;
  final ShaderStageHint? webDetectedStageHint;
  final VoidCallback onToggleWebUpload;
  final ValueChanged<String> onWebSourceChanged;
  final ValueChanged<TerminalShaderStage> onWebStageSelected;
  final VoidCallback onWebSubmit;

  const _ShadersPipelinePanel({
    required this.workspace,
    required this.palette,
    required this.isWeb,
    required this.filter,
    required this.showWebGlslForm,
    required this.webNameCtrl,
    required this.webSourceCtrl,
    required this.webUploadStage,
    required this.webDetectedStageHint,
    required this.onToggleWebUpload,
    required this.onWebSourceChanged,
    required this.onWebStageSelected,
    required this.onWebSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final activeKind = workspace.shaderController.backendKind;
    final hasError =
        workspace.lastShaderCompileError != null ||
        workspace.lastShaderAssetError != null;
    final capabilities = FtermCapabilityContext.fromWorkspace(
      workspace,
      isWeb: isWeb,
      platform: Theme.of(context).platform,
    );

    return BlenderSettingsPanel(
      id: 'shaders-pipeline',
      title: 'Pipeline & Actions',
      categoryBreadcrumb: filter.categoryBreadcrumb,
      expanded: filter.panelExpanded('shaders-pipeline'),
      onToggleExpanded: filter.toggleFor('shaders-pipeline'),
      palette: palette,
      trailing: _ShaderBackendBadge(activeKind: activeKind, palette: palette),
      child: SettingsSpacedColumn(
        spacing: 8,
        children: [
          if (filter.showItem('shaders-backend'))
            _renderShaderSetting(
              'shaders-backend',
              workspace: workspace,
              palette: palette,
              capabilities: capabilities,
            ),
          if (hasError)
            _ShaderCompileErrorBanner(
              compileError: workspace.lastShaderCompileError,
              assetError: workspace.lastShaderAssetError,
              palette: palette,
            ),
          if (filter.showItem('shaders-actions'))
            _ShaderActionsRow(
              workspace: workspace,
              isWeb: isWeb,
              onToggleWebUpload: onToggleWebUpload,
            ),
          if (isWeb && showWebGlslForm)
            _WebGlslUploadForm(
              nameController: webNameCtrl,
              sourceController: webSourceCtrl,
              stage: webUploadStage,
              detectedStageHint: webDetectedStageHint,
              palette: palette,
              onSourceChanged: onWebSourceChanged,
              onStageSelected: onWebStageSelected,
              onSubmit: onWebSubmit,
            ),
        ],
      ),
    );
  }
}

final class _ShadersChainPanel extends StatelessWidget {
  final String id;
  final String title;
  final String keyPrefix;
  final TerminalShaderStage stage;
  final List<TerminalShaderPreset> presets;
  final List<String> activeChain;
  final bool showLegend;
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final SettingsPanelFilter filter;
  final void Function(String entry) onToggle;
  final void Function(int fromIndex, int toIndex) onMove;

  const _ShadersChainPanel({
    required this.id,
    required this.title,
    required this.keyPrefix,
    required this.stage,
    required this.presets,
    required this.activeChain,
    required this.showLegend,
    required this.workspace,
    required this.palette,
    required this.filter,
    required this.onToggle,
    required this.onMove,
  });

  @override
  Widget build(BuildContext context) {
    final selector = _ShaderChainSelector(
      keyPrefix: keyPrefix,
      stage: stage,
      presets: presets,
      activeChain: activeChain,
      availableCustomShaders: workspace.availableCustomShaders,
      samplesChannel0For: (entry) =>
          workspace.shaderSamplesChannel0(entry, stage),
      stageHintFor: (entry) => workspace.shaderStageHint(entry, stage),
      warningMessage: workspace.shaderChainWarningFor(stage),
      palette: palette,
      onToggle: onToggle,
      onMove: onMove,
      onEditCustom: (entry) =>
          unawaited(workspace.openShaderEditorTab(pathOrKey: entry)),
      onClonePreset: (preset) =>
          unawaited(workspace.openShaderEditorTab(clonePreset: preset)),
    );
    return BlenderSettingsPanel(
      id: id,
      title: title,
      categoryBreadcrumb: filter.categoryBreadcrumb,
      expanded: filter.panelExpanded(id),
      onToggleExpanded: filter.toggleFor(id),
      palette: palette,
      trailing: activeChain.length > 1
          ? Text(
              '${activeChain.length} active • top → bottom',
              style: TextStyle(color: palette.muted, fontSize: 10),
            )
          : null,
      child: showLegend
          ? SettingsSpacedColumn(
              spacing: 8,
              children: [
                _ShaderRoleLegend(palette: palette),
                selector,
              ],
            )
          : selector,
    );
  }
}

final class _ShadersCustomParamsPanel extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final bool isWeb;
  final SettingsPanelFilter filter;
  final ShaderPassSpec? primaryPass;
  final TextEditingController customPathCtrl;
  final bool showCustomPathForm;
  final VoidCallback onToggleCustomPathForm;
  final VoidCallback onAddBackground;
  final VoidCallback onAddForeground;

  const _ShadersCustomParamsPanel({
    required this.workspace,
    required this.palette,
    required this.isWeb,
    required this.filter,
    required this.primaryPass,
    required this.customPathCtrl,
    required this.showCustomPathForm,
    required this.onToggleCustomPathForm,
    required this.onAddBackground,
    required this.onAddForeground,
  });

  @override
  Widget build(BuildContext context) {
    final showCustom = !isWeb && filter.showItem('shaders-custom-path');
    final showParams = filter.showItem('shaders-params');
    return BlenderSettingsPanel(
      id: 'shaders-custom-params',
      title: 'Custom Shaders & Parameters',
      categoryBreadcrumb: filter.categoryBreadcrumb,
      expanded: filter.panelExpanded('shaders-custom-params'),
      onToggleExpanded: filter.toggleFor('shaders-custom-params'),
      palette: palette,
      child: SettingsSpacedColumn(
        children: [
          if (showCustom)
            _CustomShaderAddRow(
              controller: customPathCtrl,
              palette: palette,
              isExpanded: showCustomPathForm,
              onToggleExpanded: onToggleCustomPathForm,
              onAddBackground: onAddBackground,
              onAddForeground: onAddForeground,
            ),
          if (showParams && primaryPass != null)
            _ShaderParamSliders(
              workspace: workspace,
              pass: primaryPass!,
              palette: palette,
            )
          else if (showParams && !showCustom)
            Text(
              'Enable a background or foreground shader to adjust parameters.',
              style: TextStyle(color: palette.muted, fontSize: 11),
            ),
        ],
      ),
    );
  }
}

final class _ShadersPlaybackPanel extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final SettingsPanelFilter filter;

  const _ShadersPlaybackPanel({
    required this.workspace,
    required this.palette,
    required this.filter,
  });

  @override
  Widget build(BuildContext context) {
    final capabilities = FtermCapabilityContext.fromWorkspace(
      workspace,
      platform: Theme.of(context).platform,
    );
    return BlenderSettingsPanel(
      id: 'shaders-playback',
      title: 'Playback & Frame Pacing',
      categoryBreadcrumb: filter.categoryBreadcrumb,
      expanded: filter.panelExpanded('shaders-playback'),
      onToggleExpanded: filter.toggleFor('shaders-playback'),
      palette: palette,
      child: SettingsSpacedColumn(
        children: [
          if (filter.showItem('shaders-animation-mode'))
            _renderShaderSetting(
              'shaders-animation-mode',
              workspace: workspace,
              palette: palette,
              capabilities: capabilities,
            ),
          if (filter.showItem('shaders-max-fps'))
            _renderShaderSetting(
              'shaders-max-fps',
              workspace: workspace,
              palette: palette,
              capabilities: capabilities,
            ),
        ],
      ),
    );
  }
}

final class _ShadersCliPanel extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final SettingsPanelFilter filter;

  const _ShadersCliPanel({
    required this.workspace,
    required this.palette,
    required this.filter,
  });

  @override
  Widget build(BuildContext context) => BlenderSettingsPanel(
    id: 'shaders-cli',
    title: 'CLI Shaders & Transforms (ESC _ S)',
    categoryBreadcrumb: filter.categoryBreadcrumb,
    expanded: filter.panelExpanded('shaders-cli'),
    onToggleExpanded: filter.toggleFor('shaders-cli'),
    palette: palette,
    child: _CliShaderPolicyBody(
      workspace: workspace,
      palette: palette,
      filter: filter,
    ),
  );
}

final class _ShaderBackendBadge extends StatelessWidget {
  final ShaderBackendKind activeKind;
  final FtermOverlayPalette palette;

  const _ShaderBackendBadge({required this.activeKind, required this.palette});

  @override
  Widget build(BuildContext context) {
    final disabled = activeKind == .disabled;
    return Container(
      key: const ValueKey('settings-shader-backend-badge'),
      padding: const .symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: .circular(4),
        border: .all(color: disabled ? palette.border : palette.accent),
      ),
      child: Text(
        activeKind.name,
        style: TextStyle(
          color: disabled ? palette.muted : palette.accent,
          fontSize: 10,
          fontWeight: .w600,
        ),
      ),
    );
  }
}

final class _ShaderCompileErrorBanner extends StatelessWidget {
  final ShaderCompileException? compileError;
  final String? assetError;
  final FtermOverlayPalette palette;

  const _ShaderCompileErrorBanner({
    required this.compileError,
    required this.assetError,
    required this.palette,
  });

  String _formatSingleCompileError(ShaderCompileException err) {
    final loc = err.lineNumber == null ? '' : ' (line ${err.lineNumber})';
    return '${err.shaderId}$loc: ${err.message}';
  }

  Color _colorForSeverity(ShaderDiagnosticSeverity severity) =>
      switch (severity) {
        .error => palette.danger,
        .warning => palette.warning,
        .info => palette.accent,
      };

  static String _formatDiagnosticLine(ShaderDiagnostic diag) {
    final line = diag.line;
    final col = diag.column;
    final loc = line == null
        ? ''
        : (col == null ? 'L$line: ' : 'L$line:$col: ');
    final hint = diag.hint;
    final suffix = (hint != null && hint.isNotEmpty) ? ' ($hint)' : '';
    return '$loc${diag.message}$suffix';
  }

  @override
  Widget build(BuildContext context) {
    final err = compileError;
    final diags = err?.diagnostics ?? const <ShaderDiagnostic>[];
    final asset = assetError;
    return Container(
      key: const ValueKey('settings-shader-compile-error'),
      padding: const .all(8),
      decoration: BoxDecoration(
        color: palette.danger.withValues(alpha: 0.12),
        borderRadius: .circular(6),
        border: .all(color: palette.danger),
      ),
      child: Column(
        mainAxisSize: .min,
        crossAxisAlignment: .stretch,
        children: [
          if (err != null && diags.isNotEmpty) ...[
            Text(
              '${err.shaderId} (${diags.length} '
              '${diags.length == 1 ? 'diagnostic' : 'diagnostics'})',
              style: TextStyle(
                color: palette.danger,
                fontSize: 11,
                fontWeight: .w600,
              ),
            ),
            const SizedBox(height: 4),
            for (var i = 0; i < diags.length; i++)
              Padding(
                key: ValueKey('settings-shader-diagnostic-$i'),
                padding: const .only(top: 2),
                child: Text(
                  _formatDiagnosticLine(diags[i]),
                  style: TextStyle(
                    color: _colorForSeverity(diags[i].severity),
                    fontSize: 11,
                  ),
                ),
              ),
          ] else if (err != null)
            Text(
              _formatSingleCompileError(err),
              style: TextStyle(color: palette.danger, fontSize: 11),
            ),
          if (asset != null && asset.isNotEmpty) ...[
            if (err != null) const SizedBox(height: 4),
            Text(asset, style: TextStyle(color: palette.danger, fontSize: 11)),
          ],
        ],
      ),
    );
  }
}

final class _ShaderRoleLegend extends StatelessWidget {
  final FtermOverlayPalette palette;

  const _ShaderRoleLegend({required this.palette});

  @override
  Widget build(BuildContext context) => Wrap(
    key: const ValueKey('settings-shader-role-legend'),
    spacing: 12,
    runSpacing: 4,
    crossAxisAlignment: .center,
    children: [
      Row(
        mainAxisSize: .min,
        children: [
          Icon(Icons.bolt, size: 12, color: palette.warning),
          const SizedBox(width: 3),
          Text(
            'base (starts chain)',
            style: TextStyle(color: palette.muted, fontSize: 10),
          ),
        ],
      ),
      Row(
        mainAxisSize: .min,
        children: [
          Icon(Icons.input, size: 12, color: palette.accent),
          const SizedBox(width: 3),
          Text(
            'chains (reads iChannel0)',
            style: TextStyle(color: palette.muted, fontSize: 10),
          ),
        ],
      ),
    ],
  );
}

final class _ShaderRoleBadge extends StatelessWidget {
  final bool samplesChannel0;
  final FtermOverlayPalette palette;

  const _ShaderRoleBadge({
    super.key,
    required this.samplesChannel0,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final color = samplesChannel0 ? palette.accent : palette.warning;
    final icon = samplesChannel0 ? Icons.input : Icons.bolt;
    final text = samplesChannel0 ? 'chains' : 'base';
    final tooltip = samplesChannel0
        ? 'Chains from previous pass (reads iChannel0)'
        : 'Base shader (starts chain — ignores iChannel0)';
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const .symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: .circular(4),
          border: .all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: .min,
          children: [
            Icon(icon, size: 10, color: color),
            const SizedBox(width: 3),
            Text(
              text,
              style: TextStyle(color: color, fontSize: 9, fontWeight: .w600),
            ),
          ],
        ),
      ),
    );
  }
}

final class _ShaderChainSelector extends StatelessWidget {
  final String keyPrefix;
  final TerminalShaderStage stage;
  final List<TerminalShaderPreset> presets;
  final List<String> activeChain;
  final List<String> availableCustomShaders;
  final bool? Function(String entry) samplesChannel0For;
  final ShaderStageHint? Function(String entry) stageHintFor;
  final String? warningMessage;
  final FtermOverlayPalette palette;
  final void Function(String entry) onToggle;
  final void Function(int fromIndex, int toIndex) onMove;
  final void Function(String entry) onEditCustom;
  final void Function(TerminalShaderPreset preset) onClonePreset;

  const _ShaderChainSelector({
    required this.keyPrefix,
    required this.stage,
    required this.presets,
    required this.activeChain,
    required this.availableCustomShaders,
    required this.samplesChannel0For,
    required this.stageHintFor,
    required this.warningMessage,
    required this.palette,
    required this.onToggle,
    required this.onMove,
    required this.onEditCustom,
    required this.onClonePreset,
  });

  bool _isRecommendedForStage(ShaderStageHint? hint) => switch (hint) {
    null || .any => true,
    .background => stage == .background,
    .foreground => stage == .foreground,
  };

  List<(String id, String label, bool isCustom)> _collectOptions() {
    final seen = <String>{};
    final options = <(String, String, bool)>[
      for (final preset in presets)
        if (seen.add(preset.wireName))
          (preset.wireName, preset.wireName, false),
    ];
    final customMatching = <(String, String, bool)>[];
    final customOther = <(String, String, bool)>[];
    void addCustom(String id) {
      if (!seen.add(id)) return;
      final item = (id, p.basename(id), true);
      if (_isRecommendedForStage(stageHintFor(id))) {
        customMatching.add(item);
      } else {
        customOther.add(item);
      }
    }

    for (final path in availableCustomShaders) {
      addCustom(path);
    }
    for (final active in activeChain) {
      addCustom(active);
    }
    return [...options, ...customMatching, ...customOther];
  }

  Widget _buildChipLabel(String id, String label, bool isCustom) {
    final samples = samplesChannel0For(id);
    final stageHint = isCustom ? stageHintFor(id) : null;
    if (samples == null && stageHint == null) {
      return Text(label);
    }
    final isStageMatch = _isRecommendedForStage(stageHint);
    return Row(
      mainAxisSize: .min,
      children: [
        if (samples != null) ...[
          Icon(
            samples ? Icons.input : Icons.bolt,
            size: 12,
            color: samples ? palette.accent : palette.warning,
          ),
          const SizedBox(width: 4),
        ],
        Flexible(child: Text(label, overflow: .ellipsis)),
        if (stageHint != null) ...[
          const SizedBox(width: 5),
          Container(
            key: ValueKey('$keyPrefix-stage-hint-$id'),
            padding: const .symmetric(horizontal: 4, vertical: 0.5),
            decoration: BoxDecoration(
              color: (isStageMatch ? palette.accent : palette.muted).withValues(
                alpha: 0.14,
              ),
              borderRadius: .circular(3),
              border: .all(
                color: (isStageMatch ? palette.accent : palette.muted)
                    .withValues(alpha: 0.45),
              ),
            ),
            child: Text(
              stageHint.shortLabel,
              style: TextStyle(
                color: isStageMatch ? palette.accent : palette.muted,
                fontSize: 9,
                fontWeight: .w600,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildShaderChipEntry(String id, String label, bool isCustom) {
    final preset = isCustom
        ? TerminalShaderPreset.none
        : TerminalShaderPreset.fromWireName(id);
    return Row(
      mainAxisSize: .min,
      children: [
        Flexible(
          child: Tooltip(
            message: _chipTooltip(id),
            child: FilterChip(
              key: ValueKey('$keyPrefix-$id'),
              label: _buildChipLabel(id, label, isCustom),
              selected: activeChain.contains(id),
              visualDensity: .compact,
              onSelected: (_) => onToggle(id),
            ),
          ),
        ),
        if (isCustom)
          IconButton(
            key: ValueKey('$keyPrefix-edit-$id'),
            onPressed: () => onEditCustom(id),
            icon: Icon(Icons.edit, size: 13, color: palette.muted),
            tooltip: 'Edit $label in Shader Editor',
            padding: .zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
          )
        else if (preset != .none)
          IconButton(
            key: ValueKey('$keyPrefix-clone-$id'),
            onPressed: () => onClonePreset(preset),
            icon: Icon(
              Icons.file_copy_outlined,
              size: 13,
              color: palette.muted,
            ),
            tooltip: 'Clone & Edit $label',
            padding: .zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
          ),
      ],
    );
  }

  String _chipTooltip(String id) {
    final samples = samplesChannel0For(id);
    final hint = stageHintFor(id);
    final stageText = switch (hint) {
      .background => 'Designed for Background',
      .foreground => 'Designed for Foreground',
      .any => 'Works in Background or Foreground',
      null => null,
    };
    final roleText = switch (samples) {
      true => 'chains from previous pass (reads iChannel0)',
      false => 'base shader (starts chain, ignores iChannel0)',
      null => null,
    };
    final details = <String>[?stageText, ?roleText];
    return details.isEmpty ? id : '$id — ${details.join(' • ')}';
  }

  @override
  Widget build(BuildContext context) {
    final options = _collectOptions();
    return SettingsSpacedColumn(
      spacing: 8,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (id, label, isCustom) in options)
              _buildShaderChipEntry(id, label, isCustom),
          ],
        ),
        if (warningMessage case final message?)
          Container(
            key: ValueKey('$keyPrefix-warning'),
            padding: const .symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: palette.warning.withValues(alpha: 0.12),
              borderRadius: .circular(6),
              border: .all(color: palette.warning),
            ),
            child: Row(
              crossAxisAlignment: .start,
              children: [
                Padding(
                  padding: const .only(top: 1),
                  child: Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: palette.warning,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(color: palette.warning, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        if (activeChain.length > 1)
          _ShaderChainOrderList(
            keyPrefix: keyPrefix,
            activeChain: activeChain,
            samplesChannel0For: samplesChannel0For,
            palette: palette,
            onMove: onMove,
            onRemove: onToggle,
          ),
      ],
    );
  }
}

final class _ShaderChainOrderList extends StatelessWidget {
  final String keyPrefix;
  final List<String> activeChain;
  final bool? Function(String entry) samplesChannel0For;
  final FtermOverlayPalette palette;
  final void Function(int fromIndex, int toIndex) onMove;
  final void Function(String entry) onRemove;

  const _ShaderChainOrderList({
    required this.keyPrefix,
    required this.activeChain,
    required this.samplesChannel0For,
    required this.palette,
    required this.onMove,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey('$keyPrefix-order-list'),
    padding: const .symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: palette.surface,
      borderRadius: .circular(5),
      border: .all(color: palette.border),
    ),
    child: Column(
      mainAxisSize: .min,
      crossAxisAlignment: .stretch,
      children: [
        for (var i = 0; i < activeChain.length; i++)
          _ShaderChainOrderRow(
            keyPrefix: keyPrefix,
            index: i,
            totalCount: activeChain.length,
            entry: activeChain[i],
            samplesChannel0: samplesChannel0For(activeChain[i]),
            palette: palette,
            onMove: onMove,
            onRemove: onRemove,
          ),
      ],
    ),
  );
}

final class _ShaderChainOrderRow extends StatelessWidget {
  final String keyPrefix;
  final int index;
  final int totalCount;
  final String entry;
  final bool? samplesChannel0;
  final FtermOverlayPalette palette;
  final void Function(int fromIndex, int toIndex) onMove;
  final void Function(String entry) onRemove;

  const _ShaderChainOrderRow({
    required this.keyPrefix,
    required this.index,
    required this.totalCount,
    required this.entry,
    required this.samplesChannel0,
    required this.palette,
    required this.onMove,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final isFirst = index == 0;
    final isLast = index == totalCount - 1;
    final label = p.basename(entry);
    return Padding(
      padding: const .symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Text(
              '${index + 1}.',
              style: TextStyle(
                color: isLast ? palette.accent : palette.muted,
                fontSize: 11,
                fontWeight: isLast ? .w600 : .normal,
              ),
            ),
          ),
          Expanded(
            child: Text(
              label,
              overflow: .ellipsis,
              style: TextStyle(color: palette.foreground, fontSize: 11),
            ),
          ),
          if (samplesChannel0 case final samples?) ...[
            const SizedBox(width: 6),
            _ShaderRoleBadge(
              key: ValueKey('$keyPrefix-role-$index'),
              samplesChannel0: samples,
              palette: palette,
            ),
          ],
          if (isLast) ...[
            const SizedBox(width: 4),
            Container(
              padding: const .symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: palette.accent.withValues(alpha: 0.14),
                borderRadius: .circular(4),
                border: .all(color: palette.accent.withValues(alpha: 0.5)),
              ),
              child: Text(
                'final',
                style: TextStyle(
                  color: palette.accent,
                  fontSize: 9,
                  fontWeight: .w600,
                ),
              ),
            ),
          ],
          const SizedBox(width: 4),
          IconButton(
            key: ValueKey('$keyPrefix-move-up-$index'),
            onPressed: isFirst ? null : () => onMove(index, index - 1),
            icon: const Icon(Icons.arrow_upward, size: 14),
            tooltip: 'Move earlier (lower priority)',
            padding: .zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
          ),
          IconButton(
            key: ValueKey('$keyPrefix-move-down-$index'),
            onPressed: isLast ? null : () => onMove(index, index + 1),
            icon: const Icon(Icons.arrow_downward, size: 14),
            tooltip: 'Move later (higher priority)',
            padding: .zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
          ),
          IconButton(
            key: ValueKey('$keyPrefix-remove-$index'),
            onPressed: () => onRemove(entry),
            icon: const Icon(Icons.close, size: 14),
            tooltip: 'Disable shader',
            padding: .zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
          ),
        ],
      ),
    );
  }
}

final class _CustomShaderAddRow extends StatelessWidget {
  final TextEditingController controller;
  final FtermOverlayPalette palette;
  final bool isExpanded;
  final VoidCallback onToggleExpanded;
  final VoidCallback onAddBackground;
  final VoidCallback onAddForeground;

  const _CustomShaderAddRow({
    required this.controller,
    required this.palette,
    required this.isExpanded,
    required this.onToggleExpanded,
    required this.onAddBackground,
    required this.onAddForeground,
  });

  @override
  Widget build(BuildContext context) {
    if (!isExpanded) {
      return BlenderPropertyRow(
        label: 'Custom .glsl File',
        palette: palette,
        control: Align(
          alignment: .centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('settings-custom-shader-toggle'),
            onPressed: onToggleExpanded,
            icon: const Icon(Icons.add, size: 14),
            label: const Text('Add Custom .glsl Path…'),
          ),
        ),
      );
    }
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const ValueKey('settings-custom-shader-path-field'),
            controller: controller,
            style: TextStyle(color: palette.foreground, fontSize: 11.5),
            decoration: blenderInputDecoration(
              palette: palette,
              labelText: 'Custom .glsl file',
              hintText: 'my_effect.glsl or /path/to/shader.glsl',
            ),
            onSubmitted: (_) => onAddForeground(),
          ),
        ),
        const SizedBox(width: 6),
        OutlinedButton(
          key: const ValueKey('settings-custom-shader-add-bg'),
          onPressed: onAddBackground,
          child: const Text('Add BG'),
        ),
        const SizedBox(width: 4),
        OutlinedButton(
          key: const ValueKey('settings-custom-shader-add-fg'),
          onPressed: onAddForeground,
          child: const Text('Add FG'),
        ),
      ],
    );
  }
}

final class _ShaderParamSliders extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final ShaderPassSpec pass;
  final FtermOverlayPalette palette;

  const _ShaderParamSliders({
    required this.workspace,
    required this.pass,
    required this.palette,
  });

  static const List<String> _labels = <String>[
    'uParams0.x',
    'uParams0.y',
    'uParams0.z',
  ];

  @override
  Widget build(BuildContext context) {
    final values = workspace.shaderParamsFor(pass.id);
    return Column(
      key: const ValueKey('settings-shader-params'),
      mainAxisSize: .min,
      crossAxisAlignment: .stretch,
      children: [
        Text(
          'Shader Parameters (${pass.id})',
          style: TextStyle(
            color: palette.muted,
            fontSize: 10.5,
            fontWeight: .w600,
          ),
        ),
        const SizedBox(height: 6),
        SettingsSpacedColumn(
          spacing: 4,
          children: [
            for (var i = 0; i < _labels.length; i++)
              BlenderSliderRow(
                label: _labels[i],
                value: values[i].clamp(0.0, 2.0),
                min: 0.0,
                max: 2.0,
                valueLabel: values[i].clamp(0.0, 2.0).toStringAsFixed(2),
                sliderKey: ValueKey('settings-shader-param-$i'),
                palette: palette,
                onChanged: (v) => workspace.setShaderParam(pass.id, i, v),
              ),
          ],
        ),
      ],
    );
  }
}

final class _ShaderActionsRow extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final bool isWeb;
  final VoidCallback onToggleWebUpload;

  const _ShaderActionsRow({
    required this.workspace,
    required this.isWeb,
    required this.onToggleWebUpload,
  });

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 6,
    children: [
      FilledButton.icon(
        key: const ValueKey('settings-new-shader-tab'),
        onPressed: () => unawaited(workspace.openShaderEditorTab()),
        icon: const Icon(Icons.code, size: 14),
        label: const Text('New Shader Tab'),
      ),
      if (isWeb)
        OutlinedButton.icon(
          key: const ValueKey('settings-upload-glsl'),
          onPressed: onToggleWebUpload,
          icon: const Icon(Icons.upload_file, size: 14),
          label: const Text('Upload .glsl'),
        )
      else
        OutlinedButton.icon(
          key: const ValueKey('settings-open-shaders-folder'),
          onPressed: () => unawaited(workspace.openShadersFolder()),
          icon: const Icon(Icons.folder_open, size: 14),
          label: const Text('Open Shaders Folder'),
        ),
      Tooltip(
        message: 'Reload Shaders (Ctrl+Shift+F5)',
        child: OutlinedButton.icon(
          key: const ValueKey('settings-reload-shaders'),
          onPressed: () => unawaited(workspace.reloadShaders()),
          icon: const Icon(Icons.refresh, size: 14),
          label: const Text('Reload Shaders'),
        ),
      ),
    ],
  );
}

final class _WebGlslUploadForm extends StatelessWidget {
  final TextEditingController nameController;
  final TextEditingController sourceController;
  final TerminalShaderStage stage;
  final ShaderStageHint? detectedStageHint;
  final FtermOverlayPalette palette;
  final ValueChanged<String> onSourceChanged;
  final ValueChanged<TerminalShaderStage> onStageSelected;
  final VoidCallback onSubmit;

  const _WebGlslUploadForm({
    required this.nameController,
    required this.sourceController,
    required this.stage,
    required this.detectedStageHint,
    required this.palette,
    required this.onSourceChanged,
    required this.onStageSelected,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('settings-web-glsl-form'),
    padding: const .all(10),
    decoration: BoxDecoration(
      color: palette.surface,
      borderRadius: .circular(5),
      border: .all(color: palette.border),
    ),
    child: SettingsSpacedColumn(
      spacing: 8,
      children: [
        TextField(
          key: const ValueKey('settings-web-glsl-name'),
          controller: nameController,
          style: TextStyle(color: palette.foreground, fontSize: 11.5),
          decoration: blenderInputDecoration(
            palette: palette,
            labelText: 'Shader filename (.glsl)',
          ),
        ),
        TextField(
          key: const ValueKey('settings-web-glsl-source'),
          controller: sourceController,
          maxLines: 4,
          onChanged: onSourceChanged,
          style: TextStyle(color: palette.foreground, fontSize: 11.5),
          decoration: blenderInputDecoration(
            palette: palette,
            labelText: 'Ghostty Shadertoy GLSL',
            hintText:
                'void mainImage(out vec4 fragColor, in vec2 fragCoord) {}',
          ),
        ),
        Row(
          children: [
            Expanded(
              child: BlenderSegmentedControl<TerminalShaderStage>(
                value: stage,
                palette: palette,
                options: const [
                  BlenderSegmentedOption<TerminalShaderStage>(
                    key: ValueKey('settings-web-glsl-stage-bg'),
                    value: .background,
                    label: 'Background',
                  ),
                  BlenderSegmentedOption<TerminalShaderStage>(
                    key: ValueKey('settings-web-glsl-stage-fg'),
                    value: .foreground,
                    label: 'Foreground',
                  ),
                ],
                onChanged: onStageSelected,
              ),
            ),
            if (detectedStageHint case final hint?) ...[
              const SizedBox(width: 8),
              Text(
                'Detected: ${hint.shortLabel}',
                key: const ValueKey('settings-web-glsl-detected-stage'),
                style: TextStyle(color: palette.muted, fontSize: 10.5),
              ),
            ],
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('settings-web-glsl-save'),
              onPressed: onSubmit,
              child: const Text('Save & Apply'),
            ),
          ],
        ),
      ],
    ),
  );
}

final class _CliShaderPolicyBody extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;
  final SettingsPanelFilter filter;

  const _CliShaderPolicyBody({
    required this.workspace,
    required this.palette,
    required this.filter,
  });

  @override
  Widget build(BuildContext context) {
    final capabilities = FtermCapabilityContext.fromWorkspace(
      workspace,
      platform: Theme.of(context).platform,
    );
    return SettingsSpacedColumn(
      key: const ValueKey('settings-cli-shader-policy-section'),
      spacing: 8,
      children: [
        if (filter.showItem('shaders-cli-local-policy'))
          _renderShaderSetting(
            'shaders-cli-local-policy',
            workspace: workspace,
            palette: palette,
            capabilities: capabilities,
          ),
        if (filter.showItem('shaders-cli-remote-policy'))
          _renderShaderSetting(
            'shaders-cli-remote-policy',
            workspace: workspace,
            palette: palette,
            capabilities: capabilities,
          ),
        if (filter.showItem('shaders-cli-stacking'))
          _renderShaderSetting(
            'shaders-cli-stacking',
            workspace: workspace,
            palette: palette,
            capabilities: capabilities,
          ),
        if (filter.showItem('shaders-cli-dev-trust'))
          _renderShaderSetting(
            'shaders-cli-dev-trust',
            workspace: workspace,
            palette: palette,
            capabilities: capabilities,
          ),
        if (filter.showItem('shaders-cli-trusted-hashes'))
          _CliTrustedHashesRow(workspace: workspace, palette: palette),
      ],
    );
  }
}

final class _CliTrustedHashesRow extends StatelessWidget {
  final FtermWorkspaceController workspace;
  final FtermOverlayPalette palette;

  const _CliTrustedHashesRow({required this.workspace, required this.palette});

  @override
  Widget build(BuildContext context) {
    final trustedCount = workspace.trustedCliShaderHashes.length;
    return BlenderPropertyRow(
      label: 'Trusted GLSL Hashes',
      palette: palette,
      control: Wrap(
        alignment: .spaceBetween,
        crossAxisAlignment: .center,
        spacing: 8,
        runSpacing: 4,
        children: [
          Text(
            '$trustedCount trusted',
            key: const ValueKey('settings-trusted-cli-hash-count'),
            style: TextStyle(color: palette.muted, fontSize: 11),
          ),
          TextButton(
            key: const ValueKey('settings-reset-trusted-cli-hashes'),
            onPressed: trustedCount > 0
                ? workspace.clearTrustedCliShaderHashes
                : null,
            child: const Text('Reset Trusted Hashes'),
          ),
        ],
      ),
    );
  }
}
