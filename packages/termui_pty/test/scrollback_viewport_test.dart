import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

void main() {
  group('VirtualTerminal Scrollback Viewport Navigation', () {
    test('initial viewportOffset is 0 and clamping respects retainedLines', () {
      final terminal = VirtualTerminal(
        width: 10,
        height: 4,
        maxScrollbackLines: 10,
      );
      expect(terminal.viewportOffset, equals(0));
      expect(terminal.scrollback.totalLines, equals(0));

      terminal.scrollViewport(5);
      expect(terminal.viewportOffset, equals(0));

      terminal.scrollViewport(-5);
      expect(terminal.viewportOffset, equals(0));

      terminal.viewportOffset = 10;
      expect(terminal.viewportOffset, equals(0));
    });

    test('clamps viewportOffset to retainedLines (never evicted totalLines)', () {
      final terminal = VirtualTerminal(
        width: 10,
        height: 2,
        maxScrollbackLines: 3,
      );

      // Write 10 lines -> height=2 means 8 lines evicted (totalLines=8), but retainedLines=3!
      terminal.writeString(
        'L0\r\nL1\r\nL2\r\nL3\r\nL4\r\nL5\r\nL6\r\nL7\r\nL8\r\nL9',
      );
      expect(terminal.scrollback.totalLines, equals(8));
      expect(terminal.scrollback.retainedLines, equals(3));

      terminal.scrollViewport(100);
      expect(terminal.viewportOffset, equals(3));

      terminal.viewportOffset = 50;
      expect(terminal.viewportOffset, equals(3));

      // Scrolling more output while pinned at top of retained history stays clamped at 3!
      terminal.writeString('\r\nL10\r\nL11');
      expect(terminal.scrollback.totalLines, equals(10));
      expect(terminal.scrollback.retainedLines, equals(3));
      expect(terminal.viewportOffset, equals(3));

      // Paint at max offset renders L7 ('7'), L8 ('8'), never evicted null lines!
      final canvas = Buffer.blank(10, 2);
      final element =
          TerminalView(terminal: terminal, autofocus: false).createElement()
            ..mount(null)
            ..layout(BoxConstraints.tight(const Size(10, 2)))
            ..paint(canvas, Offset.zero);
      addTearDown(element.unmount);

      expect(canvas.getCharacter(1, 0), equals('7'));
      expect(canvas.getCharacter(1, 1), equals('8'));
    });

    test(
      'scrollViewport delta updates viewportOffset with clamping and notifications',
      () {
        final terminal = VirtualTerminal(
          width: 10,
          height: 4,
          maxScrollbackLines: 10,
        );
        terminal.writeString('L1\r\nL2\r\nL3\r\nL4\r\nL5\r\nL6\r\nL7');
        expect(terminal.scrollback.retainedLines, equals(3));

        var notifyCount = 0;
        terminal.addListener(() => notifyCount++);

        terminal.scrollViewport(2);
        expect(terminal.viewportOffset, equals(2));
        expect(notifyCount, equals(1));

        terminal.scrollViewport(5);
        expect(terminal.viewportOffset, equals(3));
        expect(notifyCount, equals(2));

        terminal.scrollViewport(-1);
        expect(terminal.viewportOffset, equals(2));
        expect(notifyCount, equals(3));

        terminal.scrollViewport(-10);
        expect(terminal.viewportOffset, equals(0));
        expect(notifyCount, equals(4));

        terminal.viewportOffset = 2;
        expect(terminal.viewportOffset, equals(2));
        expect(notifyCount, equals(5));

        terminal.viewportOffset = 100;
        expect(terminal.viewportOffset, equals(3));
        expect(notifyCount, equals(6));

        terminal.viewportOffset = -10;
        expect(terminal.viewportOffset, equals(0));
        expect(notifyCount, equals(7));
      },
    );

    test('resetViewport resets viewportOffset to 0 and notifies listeners', () {
      final terminal = VirtualTerminal(
        width: 10,
        height: 4,
        maxScrollbackLines: 10,
      );
      terminal.writeString('L1\r\nL2\r\nL3\r\nL4\r\nL5\r\nL6\r\nL7');
      terminal.scrollViewport(3);
      expect(terminal.viewportOffset, equals(3));

      var notified = false;
      terminal.addListener(() => notified = true);

      terminal.resetViewport();
      expect(terminal.viewportOffset, equals(0));
      expect(notified, isTrue);
    });

    test('viewportOffset tracks when new rows scroll into scrollback', () {
      final terminal = VirtualTerminal(
        width: 10,
        height: 4,
        maxScrollbackLines: 10,
      );
      terminal.writeString('L1\r\nL2\r\nL3\r\nL4\r\nL5\r\nL6\r\nL7');
      expect(terminal.scrollback.totalLines, equals(3));

      terminal.scrollViewport(2);
      expect(terminal.viewportOffset, equals(2));

      terminal.writeString('\r\nL8\r\nL9');
      expect(terminal.scrollback.totalLines, equals(5));
      expect(terminal.viewportOffset, equals(4));

      terminal.resetViewport();
      expect(terminal.viewportOffset, equals(0));
      terminal.writeString('\r\nL10\r\nL11');
      expect(terminal.viewportOffset, equals(0));
    });

    test('erasing scrollback resets viewportOffset to 0', () {
      final terminal = VirtualTerminal(
        width: 10,
        height: 4,
        maxScrollbackLines: 10,
      );
      terminal.writeString('L1\r\nL2\r\nL3\r\nL4\r\nL5\r\nL6\r\nL7');
      terminal.scrollViewport(2);
      expect(terminal.viewportOffset, equals(2));

      terminal.writeString('\x1b[3J');
      expect(terminal.scrollback.totalLines, equals(0));
      expect(terminal.viewportOffset, equals(0));
    });
  });

  group('Semantic Prompt Jumping (OSC 133;A)', () {
    test(
      'jumpToPrompt supports direction and backward, returns bool, and binary searches',
      () {
        final terminal = VirtualTerminal(
          width: 20,
          height: 5,
          maxScrollbackLines: 100,
        );

        for (var i = 1; i <= 10; i++) {
          terminal.writeString(
            '\x1b]133;A\x07\$ cmd $i\r\noutA_$i\r\noutB_$i\r\n',
          );
        }
        expect(terminal.promptLineIndices.length, equals(10));

        final p7 = terminal.promptLineIndices[6];
        final p8 = terminal.promptLineIndices[7];
        final p9 = terminal.promptLineIndices[8];

        // p10 (line 27) is already visible on active screen (lines 26..30), so
        // jumping backward from topLine=26 lands on p9, then p8, then p7.
        expect(terminal.jumpToPrompt(direction: -1), isTrue);
        expect(
          terminal.viewportOffset,
          equals(terminal.scrollback.totalLines - p9),
        );

        expect(terminal.jumpToPrompt(direction: -1), isTrue);
        expect(
          terminal.viewportOffset,
          equals(terminal.scrollback.totalLines - p8),
        );

        // Also supports backward: true
        expect(terminal.jumpToPrompt(backward: true), isTrue);
        expect(
          terminal.viewportOffset,
          equals(terminal.scrollback.totalLines - p7),
        );

        // Jump all the way to oldest prompt
        while (terminal.jumpToPrompt(direction: -1)) {}
        expect(
          terminal.viewportOffset,
          equals(
            terminal.scrollback.totalLines - terminal.promptLineIndices.first,
          ),
        );
        expect(terminal.jumpToPrompt(direction: -1), isFalse);

        // Jump forward using direction: 1 back to active screen (0)
        while (terminal.viewportOffset > 0) {
          expect(terminal.jumpToPrompt(direction: 1), isTrue);
        }
        expect(terminal.viewportOffset, equals(0));
        expect(terminal.jumpToPrompt(direction: 1), isFalse);
        expect(terminal.jumpToPrompt(backward: false), isFalse);
      },
    );

    test(
      'prunes prompts < oldestLine and discards scrolled prompts when maxScrollbackLines == 0',
      () {
        final bounded = VirtualTerminal(
          width: 10,
          height: 2,
          maxScrollbackLines: 3,
        );
        bounded.writeString(
          '\x1b]133;A\x07P1\r\nA\r\nB\r\nC\r\nD\r\nE\r\nF\r\n\x1b]133;A\x07P2\r\n',
        );
        expect(bounded.promptLineIndices.contains(0), isFalse);

        final zeroSb = VirtualTerminal(
          width: 10,
          height: 2,
          maxScrollbackLines: 0,
        );
        zeroSb.writeString(
          '\x1b]133;A\x07P1\r\nLine2\r\nLine3\r\n\x1b]133;A\x07P2',
        );
        // P1 scrolled off screen with maxScrollbackLines == 0 -> discarded!
        expect(zeroSb.promptLineIndices.length, equals(1));
        expect(zeroSb.jumpToPrompt(direction: -1), isFalse);
      },
    );
  });

  group('TerminalView Viewport Scrolling & Bindings', () {
    test(
      'scrolls viewport on mouse wheel, Shift+PageUp/Down, Ctrl+Shift+Up/Down, and resets on typing',
      () {
        debugShowTouchesEnabled = false;
        FocusManager.instance.setPrimaryFocus(null);
        final tester = TerminalTester();
        final vt = VirtualTerminal(
          width: 20,
          height: 6,
          maxScrollbackLines: 50,
        );
        final inputs = <String>[];

        // Populate scrollback with semantic prompts
        for (var i = 1; i <= 6; i++) {
          vt.writeString('\x1b]133;A\x07\$ p$i\r\no1_$i\r\no2_$i\r\n');
        }
        expect(vt.scrollback.retainedLines, greaterThan(6));

        final view = TerminalView(terminal: vt, onInput: inputs.add);

        tester.run(() async {
          final runner = PromptRunner<Object?>(
            terminal: tester.terminal,
            alternateScreen: false,
            widget: SizedBox.expand(child: view),
          );
          final runFuture = runner.run();
          await tester.pump(const Duration(milliseconds: 30));

          // 1. Mouse wheelUp (+3) & wheelDown (-3) when !mouseTrackingEnabled && !isUsingAlternateScreen
          tester.sendString('\x1b[<64;2;2M\x1b[<64;2;2M');
          await tester.pump(const Duration(milliseconds: 20));
          expect(vt.viewportOffset, equals(6));
          expect(inputs, isEmpty);

          tester.sendString('\x1b[<65;2;2M');
          await tester.pump(const Duration(milliseconds: 20));
          expect(vt.viewportOffset, equals(3));

          // 2. Shift+PageUp (+height~/2 = +3) & Shift+PageDown (-3)
          expect(
            view.handleKeyEvent(
              const ev.KeyEvent(
                'pageUp',
                ev.KeyType.pageUp,
                modifiers: {ev.Modifier.shift},
              ),
            ),
            isTrue,
          );
          expect(vt.viewportOffset, equals(6));

          expect(
            view.handleKeyEvent(
              const ev.KeyEvent(
                'pageDown',
                ev.KeyType.pageDown,
                modifiers: {ev.Modifier.shift},
              ),
            ),
            isTrue,
          );
          expect(vt.viewportOffset, equals(3));

          // 3. Ctrl+Shift+Up & Ctrl+Shift+Down jump between semantic prompts
          vt.resetViewport();
          expect(
            view.handleKeyEvent(
              const ev.KeyEvent(
                'up',
                ev.KeyType.up,
                modifiers: {ev.Modifier.control, ev.Modifier.shift},
              ),
            ),
            isTrue,
          );
          expect(vt.viewportOffset, greaterThan(0));
          final firstJump = vt.viewportOffset;

          expect(
            view.handleKeyEvent(
              const ev.KeyEvent(
                'up',
                ev.KeyType.up,
                modifiers: {ev.Modifier.control, ev.Modifier.shift},
              ),
            ),
            isTrue,
          );
          expect(vt.viewportOffset, greaterThan(firstJump));

          expect(
            view.handleKeyEvent(
              const ev.KeyEvent(
                'down',
                ev.KeyType.down,
                modifiers: {ev.Modifier.control, ev.Modifier.shift},
              ),
            ),
            isTrue,
          );
          expect(vt.viewportOffset, equals(firstJump));

          // 4. Typing a regular key while scrolled back resets viewportOffset to 0 and forwards key!
          tester.sendKey(LogicalKey('x', 'x'));
          await tester.pump(const Duration(milliseconds: 20));
          expect(vt.viewportOffset, equals(0));
          expect(inputs, equals(['x']));

          runner.abort();
          await runFuture.catchError((_) => null);
        });
        vt.dispose();
      },
    );

    test(
      'performPaint renders scrollback lines and preserves transparent background',
      () {
        final terminal = VirtualTerminal(
          width: 6,
          height: 2,
          maxScrollbackLines: 10,
          transparentBackground: true,
        );
        terminal.writeString('\x1b[42mHI\x1b[0m\r\nWORLD\r\nNEXT\r\nLAST');
        terminal.scrollViewport(2);

        final canvas = Buffer.blank(6, 2)
          ..fillAttributes(char: '.', fg: 0, bg: 0xFF112233);

        final element =
            TerminalView(terminal: terminal, autofocus: false).createElement()
              ..mount(null)
              ..layout(BoxConstraints.tight(const Size(6, 2)))
              ..paint(canvas, Offset.zero);
        addTearDown(element.unmount);

        expect(canvas.getCharacter(0, 0), equals('H'));
        expect(canvas.getCharacter(1, 0), equals('I'));
        expect(canvas.getCharacter(2, 0), equals('.'));
        expect(canvas.getBackground(2, 0), equals(0xFF112233));
      },
    );

    test(
      'ScrollbackLine, renderBuffer, and TerminalView preserve SGR 58 underlineColor and OSC 8 uri',
      () {
        final terminal = VirtualTerminal(
          width: 10,
          height: 2,
          maxScrollbackLines: 10,
        );
        terminal.writeString(
          '\x1b[4:3;58:2::12:34:56m\x1b]8;;https://scroll.dev\x1b\\DOCS\x1b]8;;\x1b\\\x1b[0m\r\n'
          'ROW2\r\nROW3',
        );
        terminal.scrollViewport(1);

        final rendered = terminal.renderBuffer();
        expect(rendered.getCharacter(0, 0), equals('D'));
        expect(
          rendered.getUnderlineColor(0, 0),
          equals(const Color(12, 34, 56).argb),
        );
        expect(rendered.getUri(0, 0), equals('https://scroll.dev'));
        expect(rendered.getUri(4, 0), isNull);

        final canvas = Buffer.blank(10, 2);
        final element =
            TerminalView(terminal: terminal, autofocus: false).createElement()
              ..mount(null)
              ..layout(BoxConstraints.tight(const Size(10, 2)))
              ..paint(canvas, Offset.zero);
        addTearDown(element.unmount);

        expect(
          canvas.getUnderlineColor(1, 0),
          equals(const Color(12, 34, 56).argb),
        );
        expect(canvas.getUri(1, 0), equals('https://scroll.dev'));
        expect(canvas.getUri(5, 0), isNull);
        terminal.dispose();
      },
    );
  });
}
