import '../buffer.dart';
import '../layout.dart';
import '../style.dart';
import '../event.dart' hide Modifier;
import '../scroll_controller.dart';

/// An interactive scrollbar widget that reflects and adjusts scrolling state.
///
/// The scrollbar bounds are determined automatically by querying the associated
/// [DiscreteScrollController]'s `viewportExtent` (how much content is visible)
/// and `totalExtent` (the complete virtual size of all items).
///
/// ### Interaction Modes
/// - **Mouse Clicks and Dragging**: Clicking or dragging along the scrollbar
///   track recalculates the proportional offset and invokes
///   [DiscreteScrollController.scrollOffset] updates, shifting the content view
///   accordingly.
///
/// ### Example Usage
///
/// ```dart
/// ScrollBar(
///   controller: myScrollController,
///   direction: LayoutDirection.vertical,
///   thumbChar: '█',
///   trackChar: '░',
/// );
/// ```
///
/// ### Properties and Settings
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `controller` | [DiscreteScrollController]?| Scroll state controller. |
/// | `direction` | [LayoutDirection] | Visual orientation (vertical/horizontal). |
/// | `trackStyle` | [Style] | Style of the background scrollbar track. |
/// | `thumbStyle` | [Style] | Style of the draggable scrollbar thumb. |
/// | `thumbChar` | [String] | Character used to draw the slider thumb. |
/// | `trackChar` | [String] | Character used to draw the track background. |
class ScrollBar extends Widget {
  /// The controller that manages the scrolling state.
  final DiscreteScrollController? controller;

  // Legacy/fallback properties

  /// Fallback property for the number of visible items.
  final int? viewportHeight;

  /// Fallback property for the total number of items.
  final int? totalItems;

  /// Fallback property for the current scroll offset.
  final int? scrollOffset;

  /// Fallback callback invoked when the scroll offset changes.
  final void Function(int newOffset)? onScrollChanged;

  /// The visual orientation of the scrollbar.
  final LayoutDirection direction;

  /// The visual style of the background track.
  final Style trackStyle;

  /// The visual style of the thumb indicator.
  final Style thumbStyle;

  /// The character used to render the thumb.
  final String thumbChar;

  /// The character used to render the background track.
  final String trackChar;

  /// Creates a [ScrollBar] widget.
  ScrollBar({
    this.controller,
    this.viewportHeight,
    this.totalItems,
    this.scrollOffset,
    this.onScrollChanged,
    this.direction = LayoutDirection.vertical,
    this.trackStyle = const Style(modifiers: Modifier.dim),
    this.thumbStyle = const Style(modifiers: Modifier.reverse),
    this.thumbChar = '█',
    this.trackChar = '░',
  });

  int get _viewportExtent => controller?.viewportExtent ?? viewportHeight ?? 0;
  int get _totalExtent => controller?.totalExtent ?? totalItems ?? 0;
  int get _scrollOffset => controller?.scrollOffset ?? scrollOffset ?? 0;

  void _updateScrollOffset(int newOffset) {
    if (controller != null) {
      controller!.scrollOffset = newOffset;
    } else if (onScrollChanged != null) {
      onScrollChanged!(newOffset);
    }
  }

  Rect? _lastArea;

  @override
  Element createElement() => ScrollBarElement(this);

  /// Handles track clicks or dragging of the thumb to update the scroll offset.
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (_lastArea == null) return;
    final trackHeight = direction == LayoutDirection.vertical
        ? _lastArea!.height
        : _lastArea!.width;

    final total = _totalExtent;
    final view = _viewportExtent;
    if (trackHeight <= 0 || total <= 0) return;

    final mousePos = direction == LayoutDirection.vertical ? localY : localX;

    final double clickRatio = (mousePos / trackHeight).clamp(0.0, 1.0);
    final int maxScrollOffset = total - view;

    final int newOffset = (clickRatio * total).round().clamp(
      0,
      maxScrollOffset > 0 ? maxScrollOffset : 0,
    );
    _updateScrollOffset(newOffset);
  }
}

/// Mount element class corresponding to [ScrollBar].
class ScrollBarElement extends Element {
  /// Proportional height of the thumb indicator calculated during layout.
  int thumbHeight = 0;

  /// Index position of the thumb indicator calculated during layout.
  int thumbPos = 0;

  /// Physical track span calculated during layout.
  int trackHeight = 0;

  /// Instantiates the rendering element for the given ScrollBar.
  ScrollBarElement(ScrollBar super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final sb = widget as ScrollBar;
    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : (sb.direction == LayoutDirection.vertical ? 1 : 80);
    final height = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : (sb.direction == LayoutDirection.vertical ? 80 : 1);

    trackHeight = sb.direction == LayoutDirection.vertical ? height : width;

    final total = sb._totalExtent;
    final view = sb._viewportExtent;
    if (total <= 0) {
      thumbHeight = 0;
      thumbPos = 0;
    } else {
      final double ratio = (view / total).clamp(0.0, 1.0);
      thumbHeight = (ratio * trackHeight).round().clamp(1, trackHeight);

      final int maxScrollOffset = total - view;
      thumbPos = 0;
      if (maxScrollOffset > 0) {
        final double scrollRatio = (sb._scrollOffset / maxScrollOffset).clamp(
          0.0,
          1.0,
        );
        thumbPos = (scrollRatio * (trackHeight - thumbHeight)).round().clamp(
          0,
          trackHeight - thumbHeight,
        );
      }
    }

    return constraints.constrain(Size(width, height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final sb = widget as ScrollBar;
    sb._lastArea = Rect(offset.dx, offset.dy, size.width, size.height);

    if (size.width <= 0 || size.height <= 0) return;
    final total = sb._totalExtent;
    if (total <= 0) return;

    if (sb.direction == LayoutDirection.vertical) {
      for (var y = 0; y < trackHeight; y++) {
        final isThumb = y >= thumbPos && y < thumbPos + thumbHeight;
        final cell = buffer.getCell(offset.dx, offset.dy + y);
        if (cell != null) {
          cell.char = isThumb ? sb.thumbChar : sb.trackChar;
          cell.style = isThumb ? sb.thumbStyle : sb.trackStyle;
        }
      }
    } else {
      for (var x = 0; x < trackHeight; x++) {
        final isThumb = x >= thumbPos && x < thumbPos + thumbHeight;
        final cell = buffer.getCell(offset.dx + x, offset.dy);
        if (cell != null) {
          cell.char = isThumb ? sb.thumbChar : sb.trackChar;
          cell.style = isThumb ? sb.thumbStyle : sb.trackStyle;
        }
      }
    }
  }
}
