import 'package:termui/termui.dart';
import 'example_base.dart';

/// Example demonstrating the use of the [Padding] widget.
///
/// This example shows how to shift viewport boundaries to isolate child
/// widgets and provide internal spacing.
final class LayoutPaddingExample extends WidgetBookExample {
  /// The inner padded text content.
  final innerParagraph = Text(
    'This paragraph is padded inside a surrounding container. Padding shifts viewport boundaries to isolate child widgets.',
    style: const Style(foreground: CharmColors.soda),
  );

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    return Column([
      SizedBox(
        height: 1,
        child: Text('Surrounding Border Container with Padding:'),
      ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
          child: innerParagraph,
        ),
      ),
    ]);
  }
}
