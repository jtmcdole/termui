import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart' hide Color;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_flutter/src/terminal.dart';
import 'package:termui_flutter/src/service/terminal_service.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/terminal/terminal.dart' as term;

final class MockTerminalService implements TerminalService {
  final Set<String> savedFiles = {};
  String? clipboardText;
  int getClipboardCalls = 0;
  int setClipboardCalls = 0;
  Object? clipboardError;

  @override
  Future<String?> saveScreenshot(String basename, Uint8List bytes) async {
    savedFiles.add(basename);
    return basename;
  }

  @override
  Future<void> setClipboard(String text) async {
    setClipboardCalls++;
    if (clipboardError case final error?) throw error;
    clipboardText = text;
  }

  @override
  Future<String?> getClipboard() async {
    getClipboardCalls++;
    if (clipboardError case final error?) throw error;
    return clipboardText;
  }
}

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
    final mockService = MockTerminalService();
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
              service: mockService,
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
    await tester.runAsync(() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.f12);

      // Wait for the service to be called
      for (var i = 0; i < 50; i++) {
        if (mockService.savedFiles.length >= 3) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });

    bool foundScreenshot = false;
    bool foundAtlas = false;
    bool foundCoordinates = false;

    for (final name in mockService.savedFiles) {
      if (name.startsWith('screenshot_') && name.endsWith('.png')) {
        foundScreenshot = true;
      } else if (name.startsWith('atlas_') && name.endsWith('.png')) {
        foundAtlas = true;
      } else if (name.startsWith('coordinates_') && name.endsWith('.json')) {
        foundCoordinates = true;
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
                  if (event case term.KeyEvent(
                    :final modifiers,
                    :final key,
                  ) when modifiers.contains(term.Modifier.control)) {
                    switch (key) {
                      case '=' || '+':
                        terminal.increaseFontSize();
                      case '-':
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

    final viewState = tester.state<PrivateTuiViewState>(
      find.byType(PrivateTuiView),
    );
    expect(viewState.fontSize, equals(currentFontSize));

    // Test direct API calls
    terminal.increaseFontSize(2.0);
    await tester.pumpAndSettle();
    expect(viewState.fontSize, equals(currentFontSize + 2.0));

    terminal.decreaseFontSize(1.0);
    await tester.pumpAndSettle();
    expect(viewState.fontSize, equals(currentFontSize + 1.0));

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

    expect(viewState.fontSize, equals(currentFontSize + 1.0));

    // Press Ctrl + Minus (Ctrl + "-") twice
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.minus);
    await tester.sendKeyEvent(LogicalKeyboardKey.minus);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(viewState.fontSize, equals(currentFontSize - 1.0));

    terminal.dispose();
  });

  testWidgets(
    'TuiView updates cursor state in MouseRegion when OSC 22 is received',
    (WidgetTester tester) async {
      final terminal = FlutterTerminal();

      await tester.pumpWidget(
        MaterialApp(
          home: Terminal(terminal: terminal, onRun: (term, drawFrame) async {}),
        ),
      );

      // Wait for the asynchronous GlyphAtlas generation
      await tester.pumpAndSettle();

      // Verify basic cursor initially
      final mouseRegionFinder = find.descendant(
        of: find.byType(PrivateTuiView),
        matching: find.byType(MouseRegion),
      );
      var mouseRegion = tester.widget<MouseRegion>(mouseRegionFinder);
      expect(mouseRegion.cursor, equals(SystemMouseCursors.basic));

      // Write OSC 22 sequence via backend
      terminal.backend.write('\x1b]22;pointer\x1b\\');
      await tester.idle();
      await tester.pump();

      // Verify cursor has updated to click cursor
      mouseRegion = tester.widget<MouseRegion>(mouseRegionFinder);
      expect(mouseRegion.cursor, equals(SystemMouseCursors.click));

      terminal.dispose();
    },
  );

  testWidgets(
    'TuiView bridges OSC 52 clipboard writes/paste requests and paste/copy shortcuts',
    (WidgetTester tester) async {
      final terminal = FlutterTerminal();
      final service = MockTerminalService()..clipboardText = 'from clipboard';
      final receivedEvents = <term.InputEvent>[];
      final sub = terminal.events.listen(receivedEvents.add);

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: Terminal(
                terminal: terminal,
                service: service,
                fontSize: 14,
                fontFamily: 'Cascadia Mono',
                onRun: (term, drawFrame) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final focusFinder = find.descendant(
        of: find.byType(Terminal),
        matching: find.byType(Focus),
      );
      expect(focusFinder, findsOneWidget);
      tester.widget<Focus>(focusFinder).focusNode?.requestFocus();
      await tester.pump();

      // 1. terminal.setClipboard writes to TerminalService.setClipboard.
      terminal.setClipboard('copied via OSC 52');
      await tester.pump();
      expect(service.clipboardText, equals('copied via OSC 52'));

      // 2. terminal.requestPaste reads from TerminalService.getClipboard and injects PasteEvent.
      service.clipboardText = 'pasted via OSC 52';
      terminal.requestPaste();
      await tester.pump();
      expect(
        receivedEvents.whereType<term.PasteEvent>().map((e) => e.text),
        equals(['pasted via OSC 52']),
      );

      // 3. Cmd+V (Meta + V) injects PasteEvent.
      receivedEvents.clear();
      service.clipboardText = 'cmd-v paste';
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(
        receivedEvents.whereType<term.PasteEvent>().map((e) => e.text),
        equals(['cmd-v paste']),
      );

      // 4. Ctrl+Shift+C injects clean 'c' KeyEvent with control+shift modifiers.
      receivedEvents.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      final keyEvents = receivedEvents.whereType<term.KeyEvent>().toList();
      expect(keyEvents, isNotEmpty);
      expect(keyEvents.last.key, equals('c'));
      expect(
        keyEvents.last.modifiers,
        containsAll([term.Modifier.control, term.Modifier.shift]),
      );

      // 5. Shift+Insert pastes from clipboard.
      receivedEvents.clear();
      service.clipboardText = 'shift-insert paste';
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.insert);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(
        receivedEvents.whereType<term.PasteEvent>().map((e) => e.text),
        equals(['shift-insert paste']),
      );

      // 6. Ctrl+Shift+/ preserves shifted '?' character instead of overriding with '/'.
      receivedEvents.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await simulateKeyDownEvent(
        LogicalKeyboardKey.slash,
        physicalKey: PhysicalKeyboardKey.slash,
        character: '?',
      );
      await simulateKeyUpEvent(
        LogicalKeyboardKey.slash,
        physicalKey: PhysicalKeyboardKey.slash,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      final slashEvents = receivedEvents.whereType<term.KeyEvent>().toList();
      expect(slashEvents, isNotEmpty);
      expect(slashEvents.last.key, equals('?'));
      expect(
        slashEvents.last.modifiers,
        containsAll([term.Modifier.control, term.Modifier.shift]),
      );

      // 7. Writing raw OSC 52 sequences to terminal.backend.write does NOT trigger clipboard I/O.
      final callsBeforeRawWrite =
          service.getClipboardCalls + service.setClipboardCalls;
      terminal.backend.write('\x1b]52;c;?\x07\x1b]52;c;aGk=\x07');
      await tester.pump();
      expect(
        service.getClipboardCalls + service.setClipboardCalls,
        equals(callsBeforeRawWrite),
      );

      // 8. PlatformException from clipboard service is caught without uncaught exceptions.
      service.clipboardError = PlatformException(code: 'CLIPBOARD_DENIED');
      terminal.setClipboard('denied write');
      terminal.requestPaste();
      await tester.pump();
      expect(tester.takeException(), isNull);

      unawaited(sub.cancel());
      terminal.dispose();
    },
  );
}
