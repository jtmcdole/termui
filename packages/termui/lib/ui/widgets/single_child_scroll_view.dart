import '../buffer.dart';
import '../layout.dart';
import '../scroll_controller.dart';

/// A widget that wraps a single child widget and makes it scrollable.
///
/// It clips the child's output to the viewport size and shifts the rendering
/// position based on the current scroll offset of the scroll controller.
///
/// ### Example Usage
///
/// The following example wraps a vertical column layout containing multiple
/// rows of text, allowing the user to scroll down through the list.
///
/// ```dart
/// SingleChildScrollView(
///   childLength: 100, // Total virtual lines
///   scrollDirection: LayoutDirection.vertical,
///   controller: myScrollController,
///   child: Column([
///     for (int i = 0; i < 100; i++)
///       SizedBox(height: 1, child: Text('Row #$i')),
///   ]),
/// );
/// ```
///
/// ### Properties and Settings
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `child` | [Widget] | The nested widget that will be scrolled. |
/// | `scrollDirection`| [LayoutDirection] | Scroll orientation (vertical or horizontal). |
/// | `controller` | [DiscreteScrollController]?| Scroll state tracker and scroll operations handler. |
/// | `childLength` | [int] | The total virtual width/height content offset size. |
class SingleChildScrollView extends StatefulWidget {
  /// The nested widget that will be scrolled.
  final Widget child;

  /// Scroll orientation (vertical or horizontal).
  final LayoutDirection scrollDirection;

  /// Scroll state tracker and scroll operations handler.
  final DiscreteScrollController? controller;

  /// The total virtual width/height content offset size.
  final int childLength;

  /// Creates a new [SingleChildScrollView].
  const SingleChildScrollView({
    required this.child,
    this.scrollDirection = LayoutDirection.vertical,
    this.controller,
    required this.childLength,
  });

  @override
  State createState() => _SingleChildScrollViewState();
}

class _SingleChildScrollViewState extends State<SingleChildScrollView> {
  DiscreteScrollController? _localController;
  DiscreteScrollController? _oldController;
  late DiscreteScrollController _activeController;

  void _onScroll() {
    setState(() {});
  }

  DiscreteScrollController _resolveController() {
    final current =
        widget.controller ?? (_localController ??= DiscreteScrollController());
    if (current != _oldController) {
      _oldController?.removeListener(_onScroll);
      current.addListener(_onScroll);
      _oldController = current;
    }
    _activeController = current;
    _activeController.totalExtent = widget.childLength;
    return _activeController;
  }

  @override
  void dispose() {
    _oldController?.removeListener(_onScroll);
    _localController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _resolveController();
    return _ScrollViewRenderProxy(
      child: widget.child,
      scrollDirection: widget.scrollDirection,
      controller: controller,
    );
  }
}

class _ScrollViewRenderProxy extends Widget {
  final Widget child;
  final LayoutDirection scrollDirection;
  final DiscreteScrollController controller;

  const _ScrollViewRenderProxy({
    required this.child,
    required this.scrollDirection,
    required this.controller,
  });

  @override
  Element createElement() => _ScrollViewRenderProxyElement(this);

  @override
  void render(Buffer buffer, Rect area) {
    // Fallback for direct widget rendering outside of active element tree
    final rootContext = _ScrollViewRenderProxyElement(this)..mount(null);
    rootContext.render(buffer, area);
  }
}

class _ScrollViewRenderProxyElement extends Element {
  Element? childElement;

  _ScrollViewRenderProxyElement(_ScrollViewRenderProxy super.widget);

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }

  @override
  void render(Buffer buffer, Rect area) {
    final proxyWidget = widget as _ScrollViewRenderProxy;
    if (area.width <= 0 || area.height <= 0) return;

    final extent = proxyWidget.scrollDirection == LayoutDirection.vertical
        ? area.height
        : area.width;
    proxyWidget.controller.viewportExtent = extent;

    final scrollOffset = proxyWidget.controller.scrollOffset;
    final int childWidth =
        proxyWidget.scrollDirection == LayoutDirection.vertical
        ? area.width
        : proxyWidget.controller.totalExtent;
    final int childHeight =
        proxyWidget.scrollDirection == LayoutDirection.vertical
        ? proxyWidget.controller.totalExtent
        : area.height;

    if (childWidth <= 0 || childHeight <= 0) return;

    if (childElement != null &&
        childElement!.widget.runtimeType == proxyWidget.child.runtimeType) {
      childElement!.update(proxyWidget.child);
    } else {
      childElement = proxyWidget.child.createElement();
      childElement!.mount(this);
    }

    final virtualBuffer = Buffer.blank(childWidth, childHeight);
    childElement!.render(virtualBuffer, Rect(0, 0, childWidth, childHeight));

    if (proxyWidget.scrollDirection == LayoutDirection.vertical) {
      for (var y = 0; y < area.height; y++) {
        final srcY = scrollOffset + y;
        if (srcY >= childHeight) break;
        for (var x = 0; x < area.width; x++) {
          final cell = virtualBuffer.getCell(x, srcY);
          if (cell != null) {
            final targetCell = buffer.getCell(area.x + x, area.y + y);
            if (targetCell != null) {
              final mergedStyle = targetCell.style.merge(cell.style);
              buffer.setCell(
                area.x + x,
                area.y + y,
                Cell(cell.char, mergedStyle),
              );
            } else {
              buffer.setCell(area.x + x, area.y + y, cell);
            }
          }
        }
      }
    } else {
      for (var y = 0; y < area.height; y++) {
        for (var x = 0; x < area.width; x++) {
          final srcX = scrollOffset + x;
          if (srcX >= childWidth) break;
          final cell = virtualBuffer.getCell(srcX, y);
          if (cell != null) {
            final targetCell = buffer.getCell(area.x + x, area.y + y);
            if (targetCell != null) {
              final mergedStyle = targetCell.style.merge(cell.style);
              buffer.setCell(
                area.x + x,
                area.y + y,
                Cell(cell.char, mergedStyle),
              );
            } else {
              buffer.setCell(area.x + x, area.y + y, cell);
            }
          }
        }
      }
    }
  }
}
