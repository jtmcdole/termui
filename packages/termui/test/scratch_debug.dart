import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/event.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui_recorder/src/ansi_screenshot.dart';

void main() {
  final area = TextField(
    initialText: '',
    multiline: true,
    placeholder: 'HintText',
    placeholderStyle: const Style(foreground: Color(100, 100, 100)),
    cursorStyle: const Style(
      foreground: Colors.black,
      background: Colors.orange,
    ),
    focused: true,
  );
  final buffer = Buffer.blank(10, 1);
  buffer
      .clear(); // <--- Clear first to make initial state match cleared state style

  // 1. Empty state: showing placeholder
  ElementWidget(area)
    ..layout(BoxConstraints.tight(const Size(10, 1)))
    ..paint(buffer, Offset.zero);
  final ansi1 = AnsiScreenshot.capture(buffer);

  // 2. Add text
  buffer.clear();
  area.handleKeyEvent(const KeyEvent('x', KeyType.character));
  ElementWidget(area)
    ..layout(BoxConstraints.tight(const Size(10, 1)))
    ..paint(buffer, Offset.zero);

  // 3. Clear text
  buffer.clear();
  area.handleKeyEvent(const KeyEvent('backspace', KeyType.backspace));
  ElementWidget(area)
    ..layout(BoxConstraints.tight(const Size(10, 1)))
    ..paint(buffer, Offset.zero);
  final ansi3 = AnsiScreenshot.capture(buffer);

  print('ansi1 length: ${ansi1.length}');
  print('ansi3 length: ${ansi3.length}');
  print('ansi1 bytes: ${ansi1.codeUnits}');
  print('ansi3 bytes: ${ansi3.codeUnits}');
  print('Equal? ${ansi1 == ansi3}');
}
