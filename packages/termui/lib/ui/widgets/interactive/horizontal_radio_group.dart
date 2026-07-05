import 'dart:async';
import 'package:characters/characters.dart';
import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;

/// A horizontal group of radio-like choices.
class HorizontalRadioGroup extends StatefulWidget
    implements Focusable, MouseEventHandlerWithArea {
  /// The controller managing the selection state and options.
  final SelectionController<String> controller;

  /// Whether this group has active keyboard focus.
  @override
  final bool focused;

  /// Creates a [HorizontalRadioGroup].
  HorizontalRadioGroup({
    super.key,
    required this.controller,
    this.focused = false,
  });

  // ignore: must_be_immutable
  HorizontalRadioGroupState? _state;

  @override
  void handleMouseEvent(
    term.MouseEvent event,
    int localX,
    int localY,
    Rect area,
  ) {
    _state?.handleMouseEvent(event, localX, localY, area);
  }

  @override
  State<HorizontalRadioGroup> createState() {
    final state = HorizontalRadioGroupState();
    _state = state;
    return state;
  }
}

/// The state class for [HorizontalRadioGroup] managing selections and keyboard routing.
class HorizontalRadioGroupState extends State<HorizontalRadioGroup>
    implements KeyEventHandler, MouseEventHandlerWithArea {
  SelectionController<String>? _listenedController;
  late FocusNode _focusNode;

  void _onControllerChanged() {
    setState(() {});
  }

  void _updateListener() {
    if (_listenedController != widget.controller) {
      _listenedController?.removeListener(_onControllerChanged);
      _listenedController = widget.controller;
      _listenedController?.addListener(_onControllerChanged);
    }
  }

  @override
  void initState() {
    super.initState();
    widget._state = this;
    _focusNode = FocusNode(id: 'horizontal_radio_group_${widget.hashCode}');
    _updateListener();
    if (widget.focused) {
      scheduleMicrotask(() {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(HorizontalRadioGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget._state = this;
    _updateListener();
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
    _listenedController?.removeListener(_onControllerChanged);
    _focusNode.dispose();
    super.dispose();
  }

  /// Handles option selection and navigation.
  @override
  bool handleKeyEvent(term.KeyEvent event) {
    final controller = widget.controller;
    if (event.key == 'left' || event.key == 'h' || event.key == 'backtab') {
      setState(() {
        controller.focusedIndex =
            (controller.focusedIndex - 1) % controller.options.length;
        if (controller.focusedIndex < 0) {
          controller.focusedIndex += controller.options.length;
        }
      });
      return true;
    } else if (event.key == 'right' || event.key == 'l' || event.key == 'tab') {
      setState(() {
        controller.focusedIndex =
            (controller.focusedIndex + 1) % controller.options.length;
      });
      return true;
    } else if (event.baseKey == term.TermKey.space) {
      setState(() {
        controller.selectedIndex = controller.focusedIndex;
      });
      return true;
    } else if (event.baseKey == term.TermKey.enter) {
      setState(() {
        controller.selectedIndex = controller.focusedIndex;
      });
      return false;
    }
    return false;
  }

  @override
  void handleMouseEvent(
    term.MouseEvent event,
    int localX,
    int localY,
    Rect area,
  ) {
    if (event.type == term.MouseEventType.press) {
      int currentX = 0;
      final controller = widget.controller;
      for (var i = 0; i < controller.options.length; i++) {
        if (i > 0) currentX += 4;
        final option = controller.options[i];
        final textLength = 4 + option.characters.length;
        if (localX >= currentX && localX < currentX + textLength) {
          setState(() {
            controller.selectedIndex = i;
            controller.focusedIndex = i;
          });
          return;
        }
        currentX += textLength;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _updateListener();
    final optionWidgets = <Widget>[];
    final controller = widget.controller;
    for (var i = 0; i < controller.options.length; i++) {
      if (i > 0) {
        optionWidgets.add(const SizedBox(width: 4));
      }
      final option = controller.options[i];
      final isSelected = (controller.selectedIndex == i);
      final isFocused =
          (_focusNode.hasFocus || widget.focused) &&
          (controller.focusedIndex == i);

      final box = isSelected ? '[X]' : '[ ]';
      final text = '$box $option';

      final style = isFocused
          ? const Style(modifiers: Modifier.reverse, foreground: Colors.yellow)
          : (isSelected
                ? const Style(
                    foreground: Colors.yellow,
                    modifiers: Modifier.bold,
                  )
                : const Style(foreground: Colors.white));

      optionWidgets.add(
        SizedBox(
          width: text.characters.length,
          child: Text(text, style: style),
        ),
      );
    }

    return Focus(
      focusNode: _focusNode,
      onFocusChange: (hasFocus) {
        if (mounted) setState(() {});
      },
      onKeyEvent: (event) {
        return handleKeyEvent(event);
      },
      child: Row(optionWidgets),
    );
  }
}
