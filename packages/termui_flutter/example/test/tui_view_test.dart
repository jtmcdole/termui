import 'dart:math';
import 'package:flutter/material.dart' hide Color;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_flutter/src/terminal.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/perf/fs_locator.dart';

void main() {
  test('FlutterTerminal size and events integration test', () async {
    final terminal = FlutterTerminal();

    // Set initial size to resolve the completer
    terminal.updateSize(const Point(80, 24));
    expect(await terminal.size, const Point(80, 24));

    terminal.updateSize(const Point(100, 50));
    expect(await terminal.size, const Point(100, 50));

    // Test watchSize stream
    final sizeExpectation = expectLater(
      terminal.watchSize(),
      emitsInOrder([const Point(120, 60)]),
    );
    terminal.updateSize(const Point(120, 60));
    await sizeExpectation;

    // Test event injection
    final eventExpectation = expectLater(
      terminal.events,
      emitsInOrder([
        predicate<term.InputEvent>((e) => e.key == 'a'),
        predicate<term.InputEvent>(
          (e) => e is term.MouseEvent && e.x == 5 && e.y == 10,
        ),
      ]),
    );

    terminal.injectEvent(const term.KeyEvent('a', term.KeyType.character));
    terminal.injectEvent(
      const term.MouseEvent(
        x: 5,
        y: 10,
        button: term.MouseButton.left,
        type: term.MouseEventType.press,
      ),
    );
    await eventExpectation;

    terminal.dispose();
  });

  testWidgets('Terminal layout size constraints calculation', (
    WidgetTester tester,
  ) async {
    final terminal = FlutterTerminal();

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 300,
            child: Terminal(
              terminal: terminal,
              fontSize: 14,
              fontFamily: 'Cascadia Mono',
              onRun: (terminal, drawFrame) async {},
            ),
          ),
        ),
      ),
    );

    // Wait for the asynchronous GlyphAtlas generation
    await tester.pumpAndSettle();

    // Verify Terminal lays out and updates the terminal size
    final size = await terminal.size;

    // Ensure size has updated from default 80x24.
    expect(size.x, isNot(80));
    expect(size.y, isNot(24));

    // Test Resizing
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 600,
            height: 450,
            child: Terminal(
              terminal: terminal,
              fontSize: 14,
              fontFamily: 'Cascadia Mono',
              onRun: (terminal, drawFrame) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final size2 = await terminal.size;
    expect(size2.x, greaterThan(size.x));
    expect(size2.y, greaterThan(size.y));

    terminal.dispose();
  });

  testWidgets('Terminal F12 screenshot and rendering validation', (
    WidgetTester tester,
  ) async {
    final terminal = FlutterTerminal();
    late void Function(Buffer) drawFrame;

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 300,
            child: Terminal(
              terminal: terminal,
              fontSize: 14,
              fontFamily: 'Cascadia Mono',
              onRun: (terminal, onDrawFrame) async {
                drawFrame = onDrawFrame;
              },
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final size = await terminal.size;
    final buffer = Buffer.blank(size.x, size.y);
    buffer.writeString(0, 0, 'ASCII: Hello TUI!', const Style());
    buffer.writeString(0, 1, 'Braille: ⠋⠙⠹⠸', const Style());
    buffer.writeString(0, 2, 'Emoji: 😀🚀', const Style());
    buffer.writeString(0, 3, 'Blocks: █▀▄─│┌┐└┘├┤┬┴┼', const Style());

    drawFrame(buffer);
    await tester.pumpAndSettle();

    // Request focus
    final focusFinder = find.descendant(
      of: find.byType(Terminal),
      matching: find.byType(Focus),
    );
    expect(focusFinder, findsOneWidget);
    final focusWidget = tester.widget<Focus>(focusFinder);
    focusWidget.focusNode?.requestFocus();
    await tester.pump();

    // Verify fallback cells and painter do not crash
    // Now trigger F12 to take a screenshot and save the atlas/coordinates
    final fs = getDefaultFileSystem();
    var foundScreenshot = false;
    var foundAtlas = false;
    var foundCoordinates = false;

    await tester.runAsync(() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.f12);

      // Poll for files up to 2 seconds
      for (var i = 0; i < 20; i++) {
        final files = fs.currentDirectory.listSync();
        foundScreenshot = false;
        foundAtlas = false;
        foundCoordinates = false;

        for (final f in files) {
          final name = fs.path.basename(f.path);
          if (name.startsWith('screenshot_') && name.endsWith('.png')) {
            foundScreenshot = true;
          } else if (name.startsWith('atlas_') && name.endsWith('.png')) {
            foundAtlas = true;
          } else if (name.startsWith('coordinates_') &&
              name.endsWith('.json')) {
            foundCoordinates = true;
          }
        }

        if (foundScreenshot && foundAtlas && foundCoordinates) {
          break;
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
    });

    // Clean up files
    final files = fs.currentDirectory.listSync();
    for (final f in files) {
      final name = fs.path.basename(f.path);
      if ((name.startsWith('screenshot_') && name.endsWith('.png')) ||
          (name.startsWith('atlas_') && name.endsWith('.png')) ||
          (name.startsWith('coordinates_') && name.endsWith('.json'))) {
        f.deleteSync();
      }
    }

    expect(foundScreenshot, isTrue);
    expect(foundAtlas, isTrue);
    expect(foundCoordinates, isTrue);

    terminal.dispose();
  });

  testWidgets('Terminal Font Resizing key events and API', (
    WidgetTester tester,
  ) async {
    final terminal = FlutterTerminal(initialFontSize: 14.0);
    double currentFontSize = 14.0;

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 300,
            child: Terminal(
              terminal: terminal,
              fontSize: currentFontSize,
              fontFamily: 'Cascadia Mono',
              onRun: (terminal, drawFrame) async {
                await for (final event in terminal.events) {
                  if (event is term.KeyEvent &&
                      event.modifiers.contains(term.Modifier.control)) {
                    if (event.key == '=' || event.key == '+') {
                      terminal.increaseFontSize();
                    } else if (event.key == '-') {
                      terminal.decreaseFontSize();
                    }
                  }
                }
              },
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final state = tester.state(find.byType(PrivateTuiView));
    final dynamicViewState = state as dynamic;
    expect(dynamicViewState.fontSize, equals(currentFontSize));

    // Test direct API calls
    terminal.increaseFontSize(2.0);
    await tester.pumpAndSettle();
    expect(dynamicViewState.fontSize, equals(currentFontSize + 2.0));

    terminal.decreaseFontSize(1.0);
    await tester.pumpAndSettle();
    expect(dynamicViewState.fontSize, equals(currentFontSize + 1.0));

    // Reset back to base for key event testing
    terminal.setFontSize(currentFontSize);
    await tester.pumpAndSettle();

    final focusFinder = find.descendant(
      of: find.byType(Terminal),
      matching: find.byType(Focus),
    );
    expect(focusFinder, findsOneWidget);
    final focusWidget = tester.widget<Focus>(focusFinder);
    focusWidget.focusNode?.requestFocus();
    await tester.pump();

    // Press Ctrl + Equal (Ctrl + "+")
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(dynamicViewState.fontSize, equals(currentFontSize + 1.0));

    // Press Ctrl + Minus (Ctrl + "-") twice
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.minus);
    await tester.sendKeyEvent(LogicalKeyboardKey.minus);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(dynamicViewState.fontSize, equals(currentFontSize - 1.0));

    terminal.dispose();
  });
}
