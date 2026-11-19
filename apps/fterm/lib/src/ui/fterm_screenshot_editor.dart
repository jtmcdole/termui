import 'dart:ui' as ui;

import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';

import '../feedback/screenshot_annotations.dart';
import '../font_loader.dart';
import 'fterm_overlays.dart';

/// Opens the modal screenshot redaction & highlight editor for [image].
///
/// Returns the committed annotation list when the user clicks **Save PNG**, or
/// `null` if dismissed/cancelled. Callers retain ownership of [image].
Future<List<ScreenshotAnnotation>?> showFtermScreenshotEditorDialog({
  required BuildContext context,
  required ui.Image image,
  required FtermOverlayPalette palette,
  List<ScreenshotAnnotation> initialAnnotations = const [],
}) => showDialog<List<ScreenshotAnnotation>>(
  context: context,
  barrierColor: const Color(0xB8000000),
  builder: (_) => FtermScreenshotEditorDialog(
    image: image,
    palette: palette,
    initialAnnotations: initialAnnotations,
  ),
);

/// Interactive screenshot editor allowing users to drag blackout redaction
/// boxes and highlight callouts before saving a feedback PNG.
final class FtermScreenshotEditorDialog extends StatefulWidget {
  /// Captured terminal pane image (caller retains ownership and disposal).
  final ui.Image image;

  /// Overlay theme palette matching the active terminal theme.
  final FtermOverlayPalette palette;

  /// Existing annotations to restore when re-editing a captured screenshot.
  final List<ScreenshotAnnotation> initialAnnotations;

  /// Creates the [FtermScreenshotEditorDialog].
  const FtermScreenshotEditorDialog({
    super.key,
    required this.image,
    required this.palette,
    this.initialAnnotations = const [],
  });

  @override
  State<FtermScreenshotEditorDialog> createState() =>
      _FtermScreenshotEditorDialogState();
}

final class _FtermScreenshotEditorDialogState
    extends State<FtermScreenshotEditorDialog> {
  static const double _minDragPixels = 4.0;

  late final List<ScreenshotAnnotation> _annotations;
  final List<ScreenshotAnnotation> _redoStack = [];
  ScreenshotAnnotationTool _tool = ScreenshotAnnotationTool.redact;
  Offset? _dragStartNormalized;
  ScreenshotAnnotation? _activeDraft;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _annotations = List<ScreenshotAnnotation>.of(widget.initialAnnotations);
  }

  Size get _imageSize =>
      Size(widget.image.width.toDouble(), widget.image.height.toDouble());

  void _selectTool(ScreenshotAnnotationTool tool) {
    if (_tool == tool) return;
    setState(() => _tool = tool);
  }

  void _undo() {
    if (_annotations.isEmpty) return;
    setState(() {
      _redoStack.add(_annotations.removeLast());
      _revision++;
    });
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    setState(() {
      _annotations.add(_redoStack.removeLast());
      _revision++;
    });
  }

  void _clearAll() {
    if (_annotations.isEmpty) return;
    setState(() {
      _redoStack
        ..clear()
        ..addAll(_annotations.reversed);
      _annotations.clear();
      _revision++;
    });
  }

  void _handlePanStart(DragStartDetails details, Rect imageBounds) {
    final start = pointerToNormalizedImagePoint(
      details.localPosition,
      imageBounds,
    );
    if (start == null) return;
    setState(() {
      _dragStartNormalized = start;
      _activeDraft = ScreenshotAnnotation.fromNormalizedPoints(
        tool: _tool,
        start: start,
        end: start,
      );
      _revision++;
    });
  }

  void _handlePanUpdate(DragUpdateDetails details, Rect imageBounds) {
    final start = _dragStartNormalized;
    if (start == null) return;
    final current = clampPointerToNormalizedImagePoint(
      details.localPosition,
      imageBounds,
    );
    setState(() {
      _activeDraft = ScreenshotAnnotation.fromNormalizedPoints(
        tool: _tool,
        start: start,
        end: current,
      );
      _revision++;
    });
  }

  void _handlePanEnd(Rect imageBounds) {
    final draft = _activeDraft;
    if (draft == null) return;
    final pixelRect = draft.toCanvasRect(imageBounds);
    final keep =
        pixelRect.width >= _minDragPixels && pixelRect.height >= _minDragPixels;
    setState(() {
      if (keep) {
        _annotations.add(draft);
        _redoStack.clear();
      }
      _dragStartNormalized = null;
      _activeDraft = null;
      _revision++;
    });
  }

  void _handlePanCancel() {
    if (_dragStartNormalized == null && _activeDraft == null) return;
    setState(() {
      _dragStartNormalized = null;
      _activeDraft = null;
      _revision++;
    });
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    final primaryMod = kb.isMetaPressed || kb.isControlPressed;
    final plainKey = !primaryMod && !kb.isAltPressed;

    switch ((event.logicalKey, primaryMod, kb.isShiftPressed, plainKey)) {
      case (LogicalKeyboardKey.escape, _, _, _):
        _dragStartNormalized != null
            ? _handlePanCancel()
            : Navigator.of(context).pop();
        return KeyEventResult.handled;
      case (LogicalKeyboardKey.keyZ, true, false, _):
        _undo();
        return KeyEventResult.handled;
      case (LogicalKeyboardKey.keyZ, true, true, _) ||
          (LogicalKeyboardKey.keyY, true, _, _):
        _redo();
        return KeyEventResult.handled;
      case (LogicalKeyboardKey.keyB, _, _, true):
        _selectTool(ScreenshotAnnotationTool.redact);
        return KeyEventResult.handled;
      case (LogicalKeyboardKey.keyH, _, _, true):
        _selectTool(ScreenshotAnnotationTool.highlight);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Dialog(
      key: const ValueKey('fterm-screenshot-editor'),
      insetPadding: const EdgeInsets.all(24),
      backgroundColor: p.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: p.border),
      ),
      child: Focus(
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: DefaultTextStyle(
          style: TextStyle(
            color: p.foreground,
            fontFamily: castPrimaryFontFamily,
            fontSize: 12,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120, maxHeight: 780),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  buildFtermOverlayHeader(
                    title: 'Edit Screenshot',
                    palette: p,
                    onClose: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Drag on the image to black out private text or highlight '
                    'an area before saving.',
                    style: TextStyle(color: p.muted, fontSize: 11),
                  ),
                  const SizedBox(height: 10),
                  _ScreenshotEditorToolbar(
                    activeTool: _tool,
                    canUndo: _annotations.isNotEmpty,
                    canRedo: _redoStack.isNotEmpty,
                    onSelectTool: _selectTool,
                    onUndo: _undo,
                    onRedo: _redo,
                    onClear: _clearAll,
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xFF0A0C0F),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: p.border),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: LayoutBuilder(
                          builder: (_, constraints) {
                            final viewport = constraints.biggest;
                            final imageBounds = computeFittedImageRect(
                              viewport,
                              _imageSize,
                            );
                            return MouseRegion(
                              cursor: SystemMouseCursors.precise,
                              child: GestureDetector(
                                key: const ValueKey('screenshot-editor-canvas'),
                                behavior: HitTestBehavior.opaque,
                                onPanStart: (d) =>
                                    _handlePanStart(d, imageBounds),
                                onPanUpdate: (d) =>
                                    _handlePanUpdate(d, imageBounds),
                                onPanEnd: (_) => _handlePanEnd(imageBounds),
                                onPanCancel: _handlePanCancel,
                                child: CustomPaint(
                                  size: viewport,
                                  painter: _ScreenshotEditorPainter(
                                    image: widget.image,
                                    imageBounds: imageBounds,
                                    annotations: _annotations,
                                    activeDraft: _activeDraft,
                                    revision: _revision,
                                    frameBorderColor: p.border,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _ScreenshotEditorFooter(
                    palette: p,
                    summary: formatAnnotationSummary(_annotations),
                    dimensionsLabel:
                        '${widget.image.width}×${widget.image.height}px',
                    onCancel: () => Navigator.of(context).pop(),
                    onSave: () => Navigator.of(context).pop(
                      List<ScreenshotAnnotation>.unmodifiable(_annotations),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _ScreenshotEditorToolbar extends StatelessWidget {
  final ScreenshotAnnotationTool activeTool;
  final bool canUndo;
  final bool canRedo;
  final ValueChanged<ScreenshotAnnotationTool> onSelectTool;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onClear;

  const _ScreenshotEditorToolbar({
    required this.activeTool,
    required this.canUndo,
    required this.canRedo,
    required this.onSelectTool,
    required this.onUndo,
    required this.onRedo,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ChoiceChip(
          key: const ValueKey('screenshot-tool-redact'),
          avatar: const Icon(Icons.visibility_off_outlined, size: 14),
          label: const Text('Black Out (B)'),
          selected: activeTool == ScreenshotAnnotationTool.redact,
          onSelected: (_) => onSelectTool(ScreenshotAnnotationTool.redact),
        ),
        ChoiceChip(
          key: const ValueKey('screenshot-tool-highlight'),
          avatar: const Icon(Icons.highlight_alt, size: 14),
          label: const Text('Highlight (H)'),
          selected: activeTool == ScreenshotAnnotationTool.highlight,
          onSelected: (_) => onSelectTool(ScreenshotAnnotationTool.highlight),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          key: const ValueKey('screenshot-editor-undo'),
          onPressed: canUndo ? onUndo : null,
          icon: const Icon(Icons.undo, size: 14),
          label: const Text('Undo'),
        ),
        OutlinedButton.icon(
          key: const ValueKey('screenshot-editor-redo'),
          onPressed: canRedo ? onRedo : null,
          icon: const Icon(Icons.redo, size: 14),
          label: const Text('Redo'),
        ),
        OutlinedButton.icon(
          key: const ValueKey('screenshot-editor-clear'),
          onPressed: canUndo ? onClear : null,
          icon: const Icon(Icons.layers_clear_outlined, size: 14),
          label: const Text('Clear'),
        ),
      ],
    );
  }
}

final class _ScreenshotEditorFooter extends StatelessWidget {
  final FtermOverlayPalette palette;
  final String summary;
  final String dimensionsLabel;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  const _ScreenshotEditorFooter({
    required this.palette,
    required this.summary,
    required this.dimensionsLabel,
    required this.onCancel,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [
        Text(
          '$summary · $dimensionsLabel',
          key: const ValueKey('screenshot-editor-summary'),
          style: TextStyle(color: palette.muted, fontSize: 11),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton(
              key: const ValueKey('screenshot-editor-cancel'),
              onPressed: onCancel,
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              key: const ValueKey('screenshot-editor-save'),
              onPressed: onSave,
              icon: const Icon(Icons.save_alt_outlined, size: 14),
              label: const Text('Save PNG'),
            ),
          ],
        ),
      ],
    );
  }
}

final class _ScreenshotEditorPainter extends CustomPainter {
  final ui.Image image;
  final Rect imageBounds;
  final List<ScreenshotAnnotation> annotations;
  final ScreenshotAnnotation? activeDraft;
  final int revision;
  final Color frameBorderColor;

  const _ScreenshotEditorPainter({
    required this.image,
    required this.imageBounds,
    required this.annotations,
    required this.activeDraft,
    required this.revision,
    required this.frameBorderColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (imageBounds.isEmpty) return;
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    canvas.drawImageRect(
      image,
      src,
      imageBounds,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.drawRect(
      imageBounds,
      Paint()
        ..color = frameBorderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
    paintScreenshotAnnotations(
      canvas,
      imageBounds,
      annotations,
      activeDraft: activeDraft,
      showRedactOutline: true,
    );
  }

  @override
  bool shouldRepaint(_ScreenshotEditorPainter oldDelegate) =>
      !identical(oldDelegate.image, image) ||
      oldDelegate.imageBounds != imageBounds ||
      oldDelegate.revision != revision ||
      oldDelegate.frameBorderColor != frameBorderColor;
}
