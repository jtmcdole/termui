import 'dart:async';
import 'dart:io';
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';
import 'package:pty2/pty2.dart';

class MockPseudoTerminal implements PseudoTerminal {
  final _outCtrl = StreamController<String>.broadcast();
  final _exitCompleter = Completer<int>();
  final writtenData = <String>[];

  @override
  Stream<String> get out => _outCtrl.stream;

  @override
  void write(String data) {
    writtenData.add(data);
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(0);
    }
    _outCtrl.close();
    return true;
  }

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  void resize(int columns, int rows) {}

  @override
  void ackProcessed() {}

  @override
  void init() {}
}

void main() {
  test('PseudoTerminalView forwards mouse and keyboard events to PTY', () {
    debugShowTouchesEnabled = false;
    final tester = TerminalTester();
    final pty = MockPseudoTerminal();

    tester.run(() async {
      final runner = PromptRunner<Object?>(
        terminal: tester.terminal,
        alternateScreen: false,
        widget: SizedBox.expand(child: PseudoTerminalView(pty: pty)),
      );

      final runFuture = runner.run();
      await tester.pump(const Duration(milliseconds: 100));

      // Send 'A' via keyboard
      tester.sendKey(LogicalKey('A', 'a'));
      await tester.pump(const Duration(milliseconds: 100));

      // Enable mouse tracking in the VirtualTerminal (like a real program would)
      pty._outCtrl.add('\x1b[?1000h\x1b[?1006h');
      await tester.pump(const Duration(milliseconds: 100));

      // Send a mouse event at x=10, y=5.
      // PseudoTerminalView should receive this and encode it to SGR format.
      // SGR Mouse format: \x1b[<cb;x;yM
      // A left click (button 0) at x=10, y=5 is \x1b[<0;10;5M
      tester.sendString('\x1b[<0;10;5M');
      await tester.pump(const Duration(milliseconds: 100));

      final outputString = pty.writtenData.join();

      // We expect 'a' (from keyboard) and then the encoded mouse event
      // PseudoTerminalView encodes mouse events into SGR format: \x1b[<0;10;5M
      expect(outputString, contains('A'));
      expect(outputString, contains('\x1b[<0;10;5M'));

      runner.abort();
      await runFuture.catchError((_) => null);
    });
  });

  group('InputEncoder', () {
    test('encodes Tab, Shift+Tab, and backtab', () {
      expect(
        InputEncoder.encode(
          const ev.KeyEvent(
            'Tab',
            ev.KeyType.tab,
            modifiers: {ev.Modifier.shift},
          ),
        ),
        '\x1b[Z',
      );
      expect(
        InputEncoder.encode(const ev.KeyEvent('backtab', ev.KeyType.tab)),
        '\x1b[Z',
      );
      expect(
        InputEncoder.encode(const ev.KeyEvent('Tab', ev.KeyType.tab)),
        '\t',
      );
    });

    test('encodes C0 control punctuation with Ctrl modifier', () {
      expect(
        InputEncoder.encode(
          const ev.KeyEvent(
            '@',
            ev.KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        ),
        '\x00',
      );
      expect(
        InputEncoder.encode(
          const ev.KeyEvent(
            ' ',
            ev.KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        ),
        '\x00',
      );
      expect(
        InputEncoder.encode(
          const ev.KeyEvent(
            '[',
            ev.KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        ),
        '\x1b',
      );
      expect(
        InputEncoder.encode(
          const ev.KeyEvent(
            r'\',
            ev.KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        ),
        '\x1c',
      );
      expect(
        InputEncoder.encode(
          const ev.KeyEvent(
            ']',
            ev.KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        ),
        '\x1d',
      );
      expect(
        InputEncoder.encode(
          const ev.KeyEvent(
            '^',
            ev.KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        ),
        '\x1e',
      );
      expect(
        InputEncoder.encode(
          const ev.KeyEvent(
            '6',
            ev.KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        ),
        '\x1e',
      );
      expect(
        InputEncoder.encode(
          const ev.KeyEvent(
            '_',
            ev.KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        ),
        '\x1f',
      );
      expect(
        InputEncoder.encode(
          const ev.KeyEvent(
            '-',
            ev.KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        ),
        '\x1f',
      );
      expect(
        InputEncoder.encode(
          const ev.KeyEvent(
            '?',
            ev.KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        ),
        '\x7f',
      );
      expect(
        InputEncoder.encode(
          const ev.KeyEvent(
            '2',
            ev.KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        ),
        '\x00',
      );
      expect(
        InputEncoder.encode(
          const ev.KeyEvent(
            '/',
            ev.KeyType.character,
            modifiers: {ev.Modifier.control},
          ),
        ),
        '\x1f',
      );
      expect(
        InputEncoder.encode(
          const ev.KeyEvent(
            'c',
            ev.KeyType.character,
            modifiers: {ev.Modifier.control, ev.Modifier.alt},
          ),
        ),
        '\x1b\x03',
      );
      expect(
        InputEncoder.encode(
          const ev.KeyEvent(
            '[',
            ev.KeyType.character,
            modifiers: {ev.Modifier.control, ev.Modifier.alt},
          ),
        ),
        '\x1b\x1b',
      );
    });

    test('guards out-of-bounds mouse coordinates', () {
      expect(
        InputEncoder.encode(
          const ev.MouseEvent(
            x: -1,
            y: -1,
            button: ev.MouseButton.none,
            type: ev.MouseEventType.move,
          ),
        ),
        isEmpty,
      );
      expect(
        InputEncoder.encode(
          const ev.MouseEvent(
            x: 0,
            y: 1,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.press,
          ),
        ),
        isEmpty,
      );
      expect(
        InputEncoder.encode(
          const ev.MouseEvent(
            x: 1,
            y: 1,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.press,
          ),
        ),
        '\x1b[<0;1;1M',
      );
    });

    test(
      'wraps PasteEvent in bracketed paste markers when enabled and sanitizes markers',
      () {
        const paste = ev.PasteEvent('line1\nline2\x1b[201~injected\x1b[200~');
        expect(
          InputEncoder.encode(paste),
          'line1\nline2\x1b[201~injected\x1b[200~',
        );
        expect(
          InputEncoder.encode(paste, bracketedPaste: true),
          '\x1b[200~line1\nline2injected\x1b[201~',
        );
      },
    );

    test(
      'strips nested markers, 8-bit C1 CSI markers, and unsafe controls in bracketed paste',
      () {
        const nestedClose = ev.PasteEvent('x\x1b[20\x1b[201~1~\rcmd\r');
        expect(
          InputEncoder.encode(nestedClose, bracketedPaste: true),
          '\x1b[200~x\rcmd\r\x1b[201~',
        );

        const nestedCross = ev.PasteEvent('x\x1b[201\x1b[200~~\rcmd\r');
        expect(
          InputEncoder.encode(nestedCross, bracketedPaste: true),
          '\x1b[200~x\rcmd\r\x1b[201~',
        );

        const c1Markers = ev.PasteEvent('a\x9b201~b\x9b20\x9b200~0~c');
        expect(
          InputEncoder.encode(c1Markers, bracketedPaste: true),
          '\x1b[200~abc\x1b[201~',
        );

        const rawControls = ev.PasteEvent(
          'ok\t\n\r🚀\x00\x03\x04\x07\x08\x0b\x0c\x1b[31m\x7f\x80\x9bA\x9f!',
        );
        expect(
          InputEncoder.encode(rawControls, bracketedPaste: true),
          '\x1b[200~ok\t\n\r🚀[31m[A!\x1b[201~',
        );
      },
    );

    test('ignores character keys when Modifier.meta is pressed', () {
      expect(
        InputEncoder.encode(
          const ev.KeyEvent(
            'v',
            ev.KeyType.character,
            modifiers: {ev.Modifier.meta},
          ),
        ),
        isEmpty,
      );
      expect(
        InputEncoder.encode(
          const ev.KeyEvent(
            'c',
            ev.KeyType.character,
            modifiers: {ev.Modifier.meta},
          ),
        ),
        isEmpty,
      );
    });

    test('encodes SS3 cursor keys when applicationCursorKeys is enabled', () {
      const keys = [
        (ev.KeyType.up, '\x1bOA', '\x1b[A'),
        (ev.KeyType.down, '\x1bOB', '\x1b[B'),
        (ev.KeyType.right, '\x1bOC', '\x1b[C'),
        (ev.KeyType.left, '\x1bOD', '\x1b[D'),
        (ev.KeyType.home, '\x1bOH', '\x1b[H'),
        (ev.KeyType.end, '\x1bOF', '\x1b[F'),
      ];
      for (final (keyType, appSeq, normalSeq) in keys) {
        expect(
          InputEncoder.encode(
            ev.KeyEvent('', keyType),
            applicationCursorKeys: true,
          ),
          appSeq,
        );
        expect(InputEncoder.encode(ev.KeyEvent('', keyType)), normalSeq);
        for (final mod in [
          ev.Modifier.shift,
          ev.Modifier.alt,
          ev.Modifier.control,
        ]) {
          expect(
            InputEncoder.encode(
              ev.KeyEvent('', keyType, modifiers: {mod}),
              applicationCursorKeys: true,
            ),
            normalSeq,
          );
        }
      }
      // Non-cursor keys remain unchanged when applicationCursorKeys is true.
      expect(
        InputEncoder.encode(
          const ev.KeyEvent('', ev.KeyType.pageUp),
          applicationCursorKeys: true,
        ),
        '\x1b[5~',
      );
    });

    test('encodes alternate scroll wheel sequences', () {
      expect(
        InputEncoder.encodeAlternateScroll(ev.MouseButton.wheelUp),
        '\x1b[A',
      );
      expect(
        InputEncoder.encodeAlternateScroll(ev.MouseButton.wheelUp, lines: 2),
        '\x1b[A\x1b[A',
      );
      expect(
        InputEncoder.encodeAlternateScroll(
          ev.MouseButton.wheelUp,
          applicationCursorKeys: true,
        ),
        '\x1bOA',
      );
      expect(
        InputEncoder.encodeAlternateScroll(ev.MouseButton.wheelDown),
        '\x1b[B',
      );
      expect(
        InputEncoder.encodeAlternateScroll(
          ev.MouseButton.wheelDown,
          lines: 3,
          applicationCursorKeys: true,
        ),
        '\x1bOB\x1bOB\x1bOB',
      );
      expect(InputEncoder.encodeAlternateScroll(ev.MouseButton.left), isEmpty);
      expect(
        InputEncoder.encodeAlternateScroll(ev.MouseButton.wheelUp, lines: 0),
        isEmpty,
      );
      expect(
        InputEncoder.encodeAlternateScroll(ev.MouseButton.wheelDown, lines: -1),
        isEmpty,
      );
    });

    test('encodes X10 mouse fallback when sgrMouse is false', () {
      const press = ev.MouseEvent(
        x: 10,
        y: 5,
        button: ev.MouseButton.left,
        type: ev.MouseEventType.press,
      );
      expect(
        InputEncoder.encode(press, sgrMouse: false),
        String.fromCharCodes([0x1B, 0x5B, 0x4D, 32, 42, 37]),
      );

      // Release sets low button bits to 3 while preserving modifier bits.
      const shiftRelease = ev.MouseEvent(
        x: 10,
        y: 5,
        button: ev.MouseButton.right,
        type: ev.MouseEventType.release,
        modifiers: {ev.Modifier.shift},
      );
      expect(
        InputEncoder.encode(shiftRelease, sgrMouse: false),
        String.fromCharCodes([0x1B, 0x5B, 0x4D, 32 + (4 | 3), 42, 37]),
      );

      // Drag adds motion +32 and modifier bits up to max coordinate 223.
      const ctrlDragAtMax = ev.MouseEvent(
        x: 223,
        y: 223,
        button: ev.MouseButton.middle,
        type: ev.MouseEventType.drag,
        modifiers: {ev.Modifier.control, ev.Modifier.alt},
      );
      expect(
        InputEncoder.encode(ctrlDragAtMax, sgrMouse: false),
        String.fromCharCodes([
          0x1B,
          0x5B,
          0x4D,
          32 + (1 | 32 | 8 | 16),
          255,
          255,
        ]),
      );

      // Out-of-range (> 223) and buttonless hover (move) are dropped in X10 mode.
      const outOfBounds = ev.MouseEvent(
        x: 224,
        y: 1,
        button: ev.MouseButton.left,
        type: ev.MouseEventType.press,
      );
      expect(InputEncoder.encode(outOfBounds, sgrMouse: false), isEmpty);

      const hover = ev.MouseEvent(
        x: 10,
        y: 5,
        button: ev.MouseButton.none,
        type: ev.MouseEventType.move,
      );
      expect(InputEncoder.encode(hover, sgrMouse: false), isEmpty);
    });

    test('suppresses non-press wheel events in both SGR and X10 modes', () {
      for (final button in [ev.MouseButton.wheelUp, ev.MouseButton.wheelDown]) {
        for (final type in [
          ev.MouseEventType.release,
          ev.MouseEventType.drag,
          ev.MouseEventType.move,
        ]) {
          final event = ev.MouseEvent(x: 4, y: 3, button: button, type: type);
          expect(InputEncoder.encode(event, sgrMouse: true), isEmpty);
          expect(InputEncoder.encode(event, sgrMouse: false), isEmpty);
        }
      }

      const wheelUpPress = ev.MouseEvent(
        x: 4,
        y: 3,
        button: ev.MouseButton.wheelUp,
        type: ev.MouseEventType.press,
      );
      expect(
        InputEncoder.encode(wheelUpPress, sgrMouse: true),
        '\x1b[<64;4;3M',
      );
      expect(
        InputEncoder.encode(wheelUpPress, sgrMouse: false),
        String.fromCharCodes([0x1B, 0x5B, 0x4D, 96, 36, 35]),
      );
    });
  });

  test('VirtualTerminal tracks DECCKM (?1) and Alternate Scroll (?1007)', () {
    final vt = VirtualTerminal(width: 20, height: 5);
    expect(vt.applicationCursorKeys, isFalse);
    expect(vt.alternateScrollMode, isTrue);

    vt.writeString('\x1b[?1h\x1b[?1007l');
    expect(vt.applicationCursorKeys, isTrue);
    expect(vt.alternateScrollMode, isFalse);

    vt.writeString('\x1b[?1l\x1b[?1007h');
    expect(vt.applicationCursorKeys, isFalse);
    expect(vt.alternateScrollMode, isTrue);

    // DECSTR (!p) soft reset restores defaults.
    vt.writeString('\x1b[?1h\x1b[?1007l\x1b[!p');
    expect(vt.applicationCursorKeys, isFalse);
    expect(vt.alternateScrollMode, isTrue);

    // RIS (ESC c) full reset restores defaults.
    vt.writeString('\x1b[?1h\x1b[?1007l\x1bc');
    expect(vt.applicationCursorKeys, isFalse);
    expect(vt.alternateScrollMode, isTrue);
  });

  test(
    'TerminalView forwards DECCKM, X10/SGR mouse, and alternate scroll modes',
    () {
      debugShowTouchesEnabled = false;
      FocusManager.instance.setPrimaryFocus(null);
      final tester = TerminalTester();
      final vt = VirtualTerminal(width: 20, height: 10);
      final written = <String>[];

      tester.run(() async {
        final runner = PromptRunner<Object?>(
          terminal: tester.terminal,
          alternateScreen: false,
          widget: SizedBox.expand(
            child: TerminalView(terminal: vt, onInput: written.add),
          ),
        );

        final runFuture = runner.run();
        await tester.pump(const Duration(milliseconds: 50));

        // 1. DECCKM (?1h vs ?1l) cursor key forwarding.
        tester.sendKey(LogicalKey.arrowUp);
        await tester.pump(const Duration(milliseconds: 20));
        expect(written, ['\x1b[A']);
        written.clear();

        vt.writeString('\x1b[?1h');
        tester.sendKey(LogicalKey.arrowUp);
        await tester.pump(const Duration(milliseconds: 20));
        expect(written, ['\x1bOA']);
        written.clear();

        // 2. Alternate scroll on ?1049h when mouse tracking is disabled.
        tester.sendString('\x1b[<64;3;2M');
        await tester.pump(const Duration(milliseconds: 20));
        expect(written, isEmpty);

        vt.writeString('\x1b[?1049h');
        tester.sendString('\x1b[<64;3;2M\x1b[<65;3;2M');
        await tester.pump(const Duration(milliseconds: 20));
        expect(written, ['\x1bOA', '\x1bOB']);
        written.clear();

        vt.writeString('\x1b[?1l');
        tester.sendString('\x1b[<64;3;2M');
        await tester.pump(const Duration(milliseconds: 20));
        expect(written, ['\x1b[A']);
        written.clear();

        vt.writeString('\x1b[?1007l');
        tester.sendString('\x1b[<64;3;2M');
        await tester.pump(const Duration(milliseconds: 20));
        expect(written, isEmpty);

        // 3. Mouse tracking: ?1000h without ?1006h encodes X10; adding ?1006h encodes SGR.
        vt.writeString('\x1b[?1049l\x1b[?1000h');
        tester.sendString('\x1b[<0;10;5M');
        await tester.pump(const Duration(milliseconds: 20));
        expect(written, [
          String.fromCharCodes([0x1B, 0x5B, 0x4D, 32, 42, 37]),
        ]);
        written.clear();

        vt.writeString('\x1b[?1006h');
        tester.sendString('\x1b[<0;10;5M');
        await tester.pump(const Duration(milliseconds: 20));
        expect(written, ['\x1b[<0;10;5M']);

        runner.abort();
        await runFuture.catchError((_) => null);
      });
    },
  );
}
