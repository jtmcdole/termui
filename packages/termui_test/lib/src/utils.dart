import 'package:clock/clock.dart';
import 'package:termui/termui.dart';

/// Prints the [element] and its children to the stdout.
void debugDumpTree(Element? element, [int depth = 0]) {
  if (element == null) return;
  final indent = '  ' * depth;
  // Prints the runtime type and any readable text data
  final widget = element.widget;
  final info = switch (widget) {
    Text(:final data) => '${widget.runtimeType}("$data")',
    final w => '${w.runtimeType}',
  };

  print('$indent- $info');
  element.visitChildren((child) => debugDumpTree(child, depth + 1));
}

/// Yields the event loop until [condition] returns true, or throws a [StateError] if [timeout] is exceeded.
Future<void> waitForCondition(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = clock.now().add(timeout);
  while (!condition()) {
    if (clock.now().isAfter(deadline)) {
      throw StateError('Condition not met within $timeout');
    }
    await Future.delayed(Duration.zero);
  }
}
