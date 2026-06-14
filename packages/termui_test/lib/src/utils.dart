import 'package:termui/ui/ui.dart';

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
