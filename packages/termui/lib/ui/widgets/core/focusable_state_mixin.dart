import 'dart:async';
import 'package:termui/termui.dart';

/// A mixin that provides focus node management for interactive stateful widgets.
mixin FocusableStateMixin<T extends StatefulWidget> on State<T> {
  /// The underlying focus node.
  late FocusNode focusNode;

  late bool _wasFocused;

  /// Subclasses must override this to return the widget's focus property.
  bool get isWidgetFocused;

  /// A unique ID prefix for the focus node.
  String get focusNodeIdPrefix;

  @override
  void initState() {
    super.initState();
    _wasFocused = isWidgetFocused;
    focusNode = FocusNode(id: '${focusNodeIdPrefix}_${widget.hashCode}');
    if (isWidgetFocused) {
      scheduleMicrotask(() {
        if (mounted) focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);
    final isFocused = isWidgetFocused;
    updateFocusIfNeeded(_wasFocused, isFocused);
    _wasFocused = isFocused;
  }

  /// Updates focus node request state if the widget focus changed.
  void updateFocusIfNeeded(bool wasFocused, bool isFocused) {
    if (wasFocused != isFocused) {
      if (isFocused) {
        focusNode.requestFocus();
      } else {
        focusNode.unfocus();
      }
    }
  }

  @override
  void dispose() {
    focusNode.dispose();
    super.dispose();
  }
}
