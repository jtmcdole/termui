import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;
import 'example_base.dart';

/// Example demonstrating the [SplitPane] widget.
///
/// Features a draggable divider that dynamically updates child constraints
/// (percentage or length) in real-time based on mouse interactions.
class SplitPaneExample extends WidgetBookExample {
  /// The interactive split pane layout.
  late final ElementWidget splitPaneWrapper;

  @override
  void init() {
    final splitPaneDemo = SplitPane(
      child1: Text(
        'Left Panel. Drag the │ divider in the middle with your mouse! Try resizing the window or dragging past the limit of 5 columns.',
        style: const Style(foreground: CharmColors.uni),
      ),
      constraint1: const PercentageConstraint(50),
      child2: Text(
        'Right Panel. Dragging updates PercentageConstraint / LengthConstraint dynamically in real-time.',
        style: const Style(foreground: CharmColors.lichen),
      ),
      constraint2: const PercentageConstraint(50),
    );
    splitPaneWrapper = ElementWidget(splitPaneDemo);
  }

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    return splitPaneWrapper;
  }

  @override
  void handleMouseEvent(
    ui.MouseEvent event,
    int localX,
    int localY,
    int width,
    int height,
  ) {
    final el = splitPaneWrapper.element;
    if (el is SplitPaneElement) {
      final split = el.widget as SplitPane;
      final lastArea = split.lastArea;
      if (lastArea != null) {
        final splitX = event.x - lastArea.x;
        final splitY = event.y - lastArea.y;
        el.handleMouseEvent(event, splitX, splitY);
      }
    }
  }

  @override
  bool get capturesMouse {
    final el = splitPaneWrapper.element;
    if (el is SplitPaneElement) {
      final split = el.widget as SplitPane;
      return split.isDragging;
    }
    return false;
  }

  @override
  Map<String, String> get helpBindings => {'Mouse Drag': 'Drag │ Divider'};
}
