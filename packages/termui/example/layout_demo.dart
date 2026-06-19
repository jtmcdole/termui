import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/widgets/layout/row.dart';
import 'package:termui/ui/widgets/layout/column.dart';
import 'package:termui/ui/widgets/layout/sized_box.dart';
import 'package:termui/ui/widgets/layout/flexible.dart';
import 'package:termui/ui/widgets/core/widget.dart';
import 'package:termui/ui/widgets/core/geometry.dart';
import 'package:termui/ui/renderer.dart';
import 'package:termui/ui/widget_toolkit.dart';

void main() {
  const width = 80;
  const height = 24;
  final buffer = Buffer.blank(width, height);
  final renderer = Renderer(width, height);

  // Define Column layout with header, sidebar+content section, and footer
  final layout = Column([
    SizedBox(
      height: 1,
      child: Text(
        ' TUI Layout Demo ',
        style: const Style(
          foreground: Colors.white,
          background: Colors.blue,
          modifiers: Modifier.bold,
        ),
      ),
    ),
    Expanded(
      child: Row([
        // Sidebar taking 30% width
        Flexible(
          flex: 30,
          child: Column([
            Expanded(
              child: Text(
                'Sidebar content goes here. You can put lists, actions, or status information in this area.',
                style: const Style(foreground: Colors.white),
              ),
            ),
            const SizedBox(
              height: 1,
              child: LinearProgressIndicator(0.75, showPercentage: true),
            ),
          ]),
        ),
        // Main content taking the remaining space
        Expanded(
          flex: 70,
          child: Column([
            SizedBox(
              height: 1,
              child: Text(
                'Main Content Area',
                style: const Style(
                  foreground: Colors.orange,
                  modifiers: Modifier.bold | Modifier.underline,
                ),
              ),
            ),
            Expanded(
              child: Text(
                'This section of the layout represents the main workspace. Immediate mode UI rendering splits the viewport dynamically on every frame. If the terminal is resized, the box scales accordingly.',
                style: const Style(foreground: Colors.white),
              ),
            ),
          ]),
        ),
      ]),
    ),
    SizedBox(
      height: 1,
      child: Text(
        ' Press Ctrl+C or Q to exit ',
        style: const Style(foreground: Colors.black, background: Colors.orange),
      ),
    ),
  ]);

  final elementWrapper = ElementWidget(layout);
  elementWrapper.layout(BoxConstraints.tight(Size(width, height)));
  elementWrapper.paint(buffer, Offset.zero);

  final buf = StringBuffer();
  // Render buffer to stdout
  renderer.render(buffer, buf);
  print(buf);
  print(''); // Newline at end
}
