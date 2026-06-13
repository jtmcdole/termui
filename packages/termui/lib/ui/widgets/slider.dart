import 'dart:async';
import '../buffer.dart';
import '../color.dart';
import '../event.dart' hide Modifier;
import '../layout.dart';
import '../style.dart';
import '../../terminal/terminal.dart' as term;
import 'prompt_runner.dart';
import 'focus.dart';
import '../window.dart';

/// The orientation of the slider.
enum SliderAxis {
  /// Horizontal slider.
  horizontal,

  /// Vertical slider.
  vertical,
}

/// A widget for selecting a numeric value by sliding a thumb along a track.
class Slider extends StatefulWidget implements Focusable, KeyEventHandler {
  /// Whether the slider is focused.
  @override
  final bool focused;

  /// The current value.
  double value;

  /// The minimum value.
  final double min;

  /// The maximum value.
  final double max;

  /// The orientation of the slider.
  final SliderAxis axis;

  /// The style for the track.
  final Style trackStyle;

  /// The style for the thumb.
  final Style thumbStyle;

  /// The character used for the thumb.
  final String thumbChar;

  /// The character used for the track.
  final String trackChar;

  /// Callback when the value changes.
  final void Function(double value)? onChanged;

  /// Creates a slider.
  Slider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    this.focused = false,
    this.axis = SliderAxis.horizontal,
    this.trackStyle = const Style(foreground: CharmColors.iron),
    this.thumbStyle = const Style(modifiers: Modifier.bold),
    this.thumbChar = '█',
    this.trackChar = '─',
    this.onChanged,
  });

  // ignore: must_be_immutable
  SliderState? _state;

  @override
  bool handleKeyEvent(term.KeyEvent event) {
    return _state?.handleKeyEvent(event) ?? false;
  }

  /// Handles mouse events for dragging the slider thumb.
  void handleMouseEvent(MouseEvent event, int localX, int localY, Rect area) {
    _state?.handleMouseEvent(event, localX, localY, area);
  }

  @override
  State<Slider> createState() {
    final state = SliderState();
    _state = state;
    return state;
  }
}

/// The state for a [Slider] widget.
class SliderState extends State<Slider> implements KeyEventHandler {
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    widget._state = this;
    _focusNode = FocusNode(id: 'slider_${widget.hashCode}');
    if (widget.focused) {
      scheduleMicrotask(() {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(Slider oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget._state = this;
    if (widget.focused != oldWidget.focused) {
      if (widget.focused) {
        _focusNode.requestFocus();
      } else {
        _focusNode.unfocus();
      }
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// Handles mouse events to update the slider's value on drag or click.
  void handleMouseEvent(MouseEvent event, int localX, int localY, Rect area) {
    if (event.type != MouseEventType.press &&
        event.type != MouseEventType.drag) {
      return;
    }

    if (widget.axis == SliderAxis.horizontal) {
      if (localY != 0) return;
      final trackLength = area.width;
      if (trackLength <= 1) return;

      final percent = (localX / (trackLength - 1)).clamp(0.0, 1.0);
      widget.value = widget.min + percent * (widget.max - widget.min);
      widget.onChanged?.call(widget.value);
    } else {
      if (localX != 0) return;
      final trackLength = area.height;
      if (trackLength <= 1) return;

      // For vertical slider, top (y=0) is max, bottom (y=height-1) is min
      final percent = 1.0 - (localY / (trackLength - 1)).clamp(0.0, 1.0);
      widget.value = widget.min + percent * (widget.max - widget.min);
      widget.onChanged?.call(widget.value);
    }
  }

  /// Handles keyboard events for moving the slider.
  @override
  bool handleKeyEvent(term.KeyEvent event) {
    final step = (widget.max - widget.min) / 20.0; // 5% step size
    if (widget.axis == SliderAxis.horizontal) {
      if (event.type == KeyType.left) {
        widget.value = (widget.value - step).clamp(widget.min, widget.max);
        widget.onChanged?.call(widget.value);
        return true;
      } else if (event.type == KeyType.right) {
        widget.value = (widget.value + step).clamp(widget.min, widget.max);
        widget.onChanged?.call(widget.value);
        return true;
      }
    } else {
      if (event.type == KeyType.up) {
        widget.value = (widget.value + step).clamp(widget.min, widget.max);
        widget.onChanged?.call(widget.value);
        return true;
      } else if (event.type == KeyType.down) {
        widget.value = (widget.value - step).clamp(widget.min, widget.max);
        widget.onChanged?.call(widget.value);
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      onFocusChange: (hasFocus) {
        setState(() {});
      },
      onKeyEvent: (event) {
        return handleKeyEvent(event);
      },
      child: _SliderRenderWidget(
        widget: widget,
        focused: _focusNode.hasFocus || widget.focused,
      ),
    );
  }
}

class _SliderRenderWidget extends Widget {
  final Slider widget;
  final bool focused;

  const _SliderRenderWidget({required this.widget, required this.focused});

  @override
  void render(Buffer buffer, Rect area) {
    final percent = ((widget.value - widget.min) / (widget.max - widget.min))
        .clamp(0.0, 1.0);

    if (widget.axis == SliderAxis.horizontal) {
      final trackLength = area.width;
      if (trackLength <= 0) return;
      final thumbPos = (percent * (trackLength - 1)).round();
      final tc = widget.trackChar == '─' ? '─' : widget.trackChar;

      for (int i = 0; i < trackLength; i++) {
        if (i == thumbPos) {
          buffer.writeString(i, 0, widget.thumbChar, widget.thumbStyle);
        } else {
          buffer.writeString(i, 0, tc, widget.trackStyle);
        }
      }
    } else {
      final trackLength = area.height;
      if (trackLength <= 0) return;
      // In terminal, Y=0 is top. For vertical sliders, top is max.
      final thumbPos = trackLength - 1 - (percent * (trackLength - 1)).round();
      final tc = widget.trackChar == '─' ? '│' : widget.trackChar;

      for (int i = 0; i < trackLength; i++) {
        if (i == thumbPos) {
          buffer.writeString(0, i, widget.thumbChar, widget.thumbStyle);
        } else {
          buffer.writeString(0, i, tc, widget.trackStyle);
        }
      }
    }
  }
}
