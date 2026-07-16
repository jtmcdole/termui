import 'package:termui/termui.dart';

/// Prints the [element] and its children to the stdout.
void debugDumpTree(Element? element, [int depth = 0]) {
  if (element == null) return;
  final indent = '  ' * depth;
  // Prints the runtime type and any readable text data
  final widget = element.widget;
  String info = widget.runtimeType.toString();

  if (widget is Text) info += '("${widget.data}")';
  // Add other widget types as needed...

  print('$indent- $info');
  element.visitChildren((child) => debugDumpTree(child, depth + 1));
}

/// Yields the event loop until [condition] returns true, or throws a [StateError] if [timeout] is exceeded.
Future<void> waitForCondition(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Condition not met within $timeout');
    }
    await Future.delayed(Duration.zero);
  }
}
