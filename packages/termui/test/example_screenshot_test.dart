import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui_recorder/src/ansi_screenshot.dart';

void main() {
  group('Example Screenshot Tests', () {
    test('layout_demo renders correctly without throwing', () {
      const width = 80;
      const height = 24;
      final buffer = Buffer.blank(width, height);

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
            style: const Style(
              foreground: Colors.black,
              background: Colors.orange,
            ),
          ),
        ),
      ]);

      layout.render(buffer, const Rect(0, 0, width, height));

      final screenshot = AnsiScreenshot.capture(buffer);

      // We assert that the screenshot has some known strings inside ANSI
      expect(screenshot, contains('TUI Layout Demo'));
      expect(screenshot, contains('Sidebar content'));
      expect(screenshot, contains('Main Content Area'));
    });
  });
}
