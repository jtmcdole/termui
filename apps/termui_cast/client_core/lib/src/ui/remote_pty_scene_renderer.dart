import 'dart:math';

import 'package:termui/termui.dart';

import 'view_model_scene_renderer.dart';

/// Direct [ListenableSceneRenderer] painting the active remote PTY [Buffer]
/// without wrapping a `PromptRunner`.
final class RemotePtySceneRenderer extends ViewModelSceneRenderer {
  static final int _traceRender = Tracer.registerString(
    'RemotePtySceneRenderer.render',
  );

  /// Optional predicate invoked on [KeyEventType.release] to suppress key-up
  /// transitions for shortcuts consumed on key-down by the host controller.
  bool Function(KeyEvent event)? shouldSuppressKeyRelease;

  /// Optional hook invoked on non-release key events forwarded to the PTY so
  /// any stale key-release suppression entry for the same key is cleared.
  void Function(KeyEvent event)? onPtyKeyPress;

  /// Creates a direct PTY scene renderer bound to [viewModel].
  RemotePtySceneRenderer({
    required super.viewModel,
    this.shouldSuppressKeyRelease,
    this.onPtyKeyPress,
  }) : super(
         initialWidth: viewModel.viewportCols,
         initialHeight: viewModel.viewportRows,
       ) {
    render();
  }

  @override
  bool get wantsMouseTracking => true;

  @override
  bool get wantsAlternateScreen => true;

  /// Whether the active remote PTY requests Kitty key-release events (`0x02`).
  bool get wantsKeyReleaseEvents => viewModel.wantsKeyReleaseEvents;

  /// Whether the active remote PTY requests `?1016h` SGR-Pixels mouse coordinates.
  bool get wantsPixelMouseEvents => viewModel.wantsPixelMouseEvents;

  /// Current viewer cell dimensions in logical pixels.
  (double width, double height) get cellPixelSize => viewModel.cellPixelSize;

  /// Updates the viewer cell dimensions in logical pixels for `?1016h` mouse normalization.
  void setCellPixelSize(double width, double height) =>
      viewModel.setCellPixelSize(width, height);

  @override
  void render() {
    if (isDisposed) return;
    Tracer.record(_traceRender, Phase.begin, TraceCategory.compositor);
    try {
      final composed = viewModel.composeActiveBufferWithCursor();
      if (composed.width == width && composed.height == height) {
        commitBuffer(composed);
        return;
      }
      commitBuffer(_fitToViewport(composed));
    } finally {
      Tracer.record(_traceRender, Phase.end, TraceCategory.compositor);
    }
  }

  Buffer _fitToViewport(Buffer source) {
    final fitted = Buffer.blank(width, height);
    final copyCols = min(source.width, width);
    final copyRows = min(source.height, height);
    for (var y = 0; y < copyRows; y++) {
      final srcStart = y * source.width;
      final dstStart = y * width;
      fitted.characters.setRange(
        dstStart,
        dstStart + copyCols,
        source.characters,
        srcStart,
      );
      fitted.attributes.setRange(
        dstStart * 3,
        (dstStart + copyCols) * 3,
        source.attributes,
        srcStart * 3,
      );
      fitted.copyCellAuxRangeFrom(source, dstStart, srcStart, copyCols);
    }
    fitted.propagateMetadataFrom(source, clip: Rect(0, 0, copyCols, copyRows));
    return fitted;
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (event.eventType == KeyEventType.release) {
      if (shouldSuppressKeyRelease?.call(event) ?? false) {
        return true;
      }
      return viewModel.encodeAndSendKey(event);
    }
    onPtyKeyPress?.call(event);
    return viewModel.encodeAndSendKey(event);
  }

  @override
  bool handlePasteEvent(PasteEvent event) {
    viewModel.encodeAndSendPaste(event);
    return true;
  }

  @override
  bool handleMouseEvent(MouseEvent event) =>
      viewModel.handlePtyMouseEvent(event);

  @override
  void resize(int width, int height) {
    if (isDisposed) return;
    final changed = updateDimensions(width, height);
    viewModel.resizeActiveViewport(this.width, this.height);
    if (changed || currentBuffer == null) {
      render();
    }
  }
}
