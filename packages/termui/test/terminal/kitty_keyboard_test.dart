import 'package:termui/terminal/event.dart';
import 'package:termui/terminal/input_parser.dart';
import 'package:termui/termui.dart' hide Modifier;
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

class _KeyReleaseReceiver extends Widget implements Focusable, KeyEventHandler {
  final List<KeyEvent> received = [];

  @override
  final bool wantsKeyReleaseEvents;

  _KeyReleaseReceiver({this.wantsKeyReleaseEvents = true});

  @override
  bool get focused => true;

  @override
  bool handleKeyEvent(KeyEvent event) {
    received.add(event);
    return true;
  }
}

class _FocusReleaseWidget extends StatelessWidget {
  final List<KeyEvent> received;
  final FocusNode focusNode;

  @override
  final bool wantsKeyReleaseEvents;

  const _FocusReleaseWidget({
    required this.received,
    required this.focusNode,
    this.wantsKeyReleaseEvents = true,
  });

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      autofocus: true,
      onKeyEvent: (event) {
        received.add(event);
        return true;
      },
      child: const Text('term'),
    );
  }
}

void main() {
  group('KeyEvent, MouseEvent, and KittyKeyboardEvent value semantics', () {
    test(
      'KeyEvent equality, hashCode, and toString include eventType and layout codepoints',
      () {
        const press = KeyEvent('a', KeyType.character);
        const release = KeyEvent(
          'a',
          KeyType.character,
          eventType: KeyEventType.release,
        );
        const withSubparams = KeyEvent(
          'a',
          KeyType.character,
          modifiers: {Modifier.shift},
          shiftedCodepoint: 65,
          baseLayoutCodepoint: 97,
        );
        const withSubparamsSame = KeyEvent(
          'a',
          KeyType.character,
          modifiers: {Modifier.shift},
          shiftedCodepoint: 65,
          baseLayoutCodepoint: 97,
        );
        const withDifferentBase = KeyEvent(
          'a',
          KeyType.character,
          modifiers: {Modifier.shift},
          shiftedCodepoint: 65,
          baseLayoutCodepoint: 113,
        );

        expect(press, isNot(equals(release)));
        expect(withSubparams, equals(withSubparamsSame));
        expect(withSubparams.hashCode, equals(withSubparamsSame.hashCode));
        expect(withSubparams, isNot(equals(withDifferentBase)));
        expect(release.toString(), contains('eventType: KeyEventType.release'));
        expect(withSubparams.toString(), contains('shiftedCodepoint: 65'));
        expect(withSubparams.toString(), contains('baseLayoutCodepoint: 97'));
      },
    );

    test(
      'MouseEvent equality, hashCode, and toString include pixelX and pixelY',
      () {
        const m1 = MouseEvent(
          x: 3,
          y: 4,
          pixelX: 24,
          pixelY: 64,
          button: MouseButton.left,
          type: MouseEventType.press,
        );
        const m2 = MouseEvent(
          x: 3,
          y: 4,
          pixelX: 24,
          pixelY: 64,
          button: MouseButton.left,
          type: MouseEventType.press,
        );
        const m3 = MouseEvent(
          x: 3,
          y: 4,
          pixelX: 25,
          pixelY: 64,
          button: MouseButton.left,
          type: MouseEventType.press,
        );

        expect(m1, equals(m2));
        expect(m1.hashCode, equals(m2.hashCode));
        expect(m1, isNot(equals(m3)));
        expect(m1.toString(), contains('pixelX: 24'));
        expect(m1.toString(), contains('pixelY: 64'));
      },
    );

    test('KittyKeyboardEvent value semantics', () {
      const e1 = KittyKeyboardEvent(flags: 9);
      const e2 = KittyKeyboardEvent(flags: 9);
      const e3 = KittyKeyboardEvent(flags: 0);

      expect(e1, equals(e2));
      expect(e1.hashCode, equals(e2.hashCode));
      expect(e1, isNot(equals(e3)));
      expect(e1.toString(), equals('KittyKeyboardEvent(flags: 9)'));
    });
  });

  group('InputParser Kitty Keyboard Protocol (CSI u)', () {
    late InputParser parser;

    setUp(() {
      parser = InputParser();
    });

    test('parses CSI ? flags u into KittyKeyboardEvent', () {
      final zeroFlags = parser.parse('\x1b[?0u'.codeUnits);
      expect(zeroFlags, equals([const KittyKeyboardEvent(flags: 0)]));

      final nineFlags = parser.parse('\x1b[?9u'.codeUnits);
      expect(nineFlags, equals([const KittyKeyboardEvent(flags: 9)]));
    });

    test('parses basic character keys without modifiers', () {
      final events = parser.parse('\x1b[97u'.codeUnits);
      expect(events, hasLength(1));
      final ev = events.first as KeyEvent;
      expect(ev.key, equals('a'));
      expect(ev.type, equals(KeyType.character));
      expect(ev.modifiers, isEmpty);
      expect(ev.eventType, equals(KeyEventType.press));
      expect(ev.shiftedCodepoint, isNull);
      expect(ev.baseLayoutCodepoint, isNull);
    });

    test('parses keys with modifiers and event types', () {
      final events = parser.parse('\x1b[97;5:3u'.codeUnits);
      expect(events, hasLength(1));
      final ev = events.first as KeyEvent;
      expect(ev.key, equals('a'));
      expect(ev.modifiers, equals({Modifier.control}));
      expect(ev.eventType, equals(KeyEventType.release));
    });

    test('parses keys with repeat event type', () {
      final events = parser.parse('\x1b[120;1:2u'.codeUnits);
      expect(events, hasLength(1));
      final ev = events.first as KeyEvent;
      expect(ev.key, equals('x'));
      expect(ev.modifiers, isEmpty);
      expect(ev.eventType, equals(KeyEventType.repeat));
    });

    test('parses extended subparameters codepoint:shifted:base', () {
      final events = parser.parse('\x1b[97:65:97;2:1u'.codeUnits);
      expect(events, hasLength(1));
      final ev = events.first as KeyEvent;
      expect(ev.key, equals('a'));
      expect(ev.shiftedCodepoint, equals(65));
      expect(ev.baseLayoutCodepoint, equals(97));
      expect(ev.modifiers, equals({Modifier.shift}));
      expect(ev.eventType, equals(KeyEventType.press));

      // Omitted shifted subparameter: code::base
      final dvorak = parser.parse('\x1b[111::115;5:1u'.codeUnits);
      expect(dvorak, hasLength(1));
      final dv = dvorak.first as KeyEvent;
      expect(dv.key, equals('o'));
      expect(dv.shiftedCodepoint, isNull);
      expect(dv.baseLayoutCodepoint, equals(115));
      expect(dv.modifiers, equals({Modifier.control}));
    });

    test(
      'maps official Kitty PUA codepoints 57344..57357 and 57364..57375',
      () {
        final expected = <int, (String, KeyType)>{
          57344: ('\x1b', KeyType.escape),
          57345: ('\r', KeyType.enter),
          57346: ('\t', KeyType.tab),
          57347: ('\x7f', KeyType.backspace),
          57348: ('', KeyType.insert),
          57349: ('', KeyType.delete),
          57350: ('', KeyType.arrowLeft),
          57351: ('', KeyType.arrowRight),
          57352: ('', KeyType.arrowUp),
          57353: ('', KeyType.arrowDown),
          57354: ('', KeyType.pageUp),
          57355: ('', KeyType.pageDown),
          57356: ('', KeyType.home),
          57357: ('', KeyType.end),
          57364: ('', KeyType.f1),
          57365: ('', KeyType.f2),
          57366: ('', KeyType.f3),
          57367: ('', KeyType.f4),
          57368: ('', KeyType.f5),
          57369: ('', KeyType.f6),
          57370: ('', KeyType.f7),
          57371: ('', KeyType.f8),
          57372: ('', KeyType.f9),
          57373: ('', KeyType.f10),
          57374: ('', KeyType.f11),
          57375: ('', KeyType.f12),
        };

        for (final MapEntry(:key, :value) in expected.entries) {
          final events = parser.parse('\x1b[$key;3:2u'.codeUnits);
          expect(events, hasLength(1), reason: 'codepoint $key');
          final ev = events.single as KeyEvent;
          expect(ev.key, equals(value.$1), reason: 'key for $key');
          expect(ev.type, equals(value.$2), reason: 'type for $key');
          expect(ev.modifiers, equals({Modifier.alt}));
          expect(ev.eventType, equals(KeyEventType.repeat));
        }
      },
    );

    test('parses :eventType on legacy-final CSI functional keys', () {
      final upRelease =
          parser.parse('\x1b[1;1:3A'.codeUnits).single as KeyEvent;
      expect(upRelease.type, equals(KeyType.up));
      expect(upRelease.modifiers, isEmpty);
      expect(upRelease.eventType, equals(KeyEventType.release));

      final f1Repeat = parser.parse('\x1b[1;2:2P'.codeUnits).single as KeyEvent;
      expect(f1Repeat.type, equals(KeyType.f1));
      expect(f1Repeat.modifiers, equals({Modifier.shift}));
      expect(f1Repeat.eventType, equals(KeyEventType.repeat));

      final f2Release =
          parser.parse('\x1b[1;1:3Q'.codeUnits).single as KeyEvent;
      expect(f2Release.type, equals(KeyType.f2));
      expect(f2Release.eventType, equals(KeyEventType.release));

      final f4Release =
          parser.parse('\x1b[1;1:3S'.codeUnits).single as KeyEvent;
      expect(f4Release.type, equals(KeyType.f4));
      expect(f4Release.eventType, equals(KeyEventType.release));

      final homeRelease =
          parser.parse('\x1b[1;1:3H'.codeUnits).single as KeyEvent;
      expect(homeRelease.type, equals(KeyType.home));
      expect(homeRelease.eventType, equals(KeyEventType.release));

      final endRelease =
          parser.parse('\x1b[1;1:3F'.codeUnits).single as KeyEvent;
      expect(endRelease.type, equals(KeyType.end));
      expect(endRelease.eventType, equals(KeyEventType.release));

      final delRelease =
          parser.parse('\x1b[3;1:3~'.codeUnits).single as KeyEvent;
      expect(delRelease.type, equals(KeyType.delete));
      expect(delRelease.eventType, equals(KeyEventType.release));

      final f5Release =
          parser.parse('\x1b[15;1:3~'.codeUnits).single as KeyEvent;
      expect(f5Release.type, equals(KeyType.f5));
      expect(f5Release.eventType, equals(KeyEventType.release));
    });
  });

  group('KeyEventType.release gating in PromptRunner and SceneManager', () {
    test(
      'PromptRunner ignores KeyEventType.release for standard widgets and exit triggers',
      () async {
        var buttonPresses = 0;
        var globalShortcutCalls = 0;
        final backend = MockTerminalBackend();
        final terminal = Terminal(backend);
        final runner = PromptRunner<String>(
          terminal: terminal,
          mode: ExecutionMode.managed,
          exitConditions: const {
            PromptExitTrigger.enter: PromptExitAction.complete,
            PromptExitTrigger.escape: PromptExitAction.cancel,
            PromptExitTrigger.controlC: PromptExitAction.abort,
          },
          onComplete: () => 'done',
          onKeyEvent: (_) {
            globalShortcutCalls++;
            return false;
          },
          widget: Button(
            text: 'Submit',
            focused: true,
            onPressed: () => buttonPresses++,
          ),
        );

        var completed = false;
        final future = runner.run().then((val) {
          completed = true;
          return val;
        });
        await Future<void>.delayed(Duration.zero);

        // Release events must NOT activate Button, global onKeyEvent, or exit triggers.
        runner.handleKeyEvent(
          const KeyEvent(
            ' ',
            KeyType.character,
            eventType: KeyEventType.release,
          ),
        );
        runner.handleKeyEvent(
          const KeyEvent('\r', KeyType.enter, eventType: KeyEventType.release),
        );
        runner.handleKeyEvent(
          const KeyEvent(
            'escape',
            KeyType.escape,
            eventType: KeyEventType.release,
          ),
        );
        runner.handleKeyEvent(
          const KeyEvent(
            'c',
            KeyType.character,
            modifiers: {Modifier.control},
            eventType: KeyEventType.release,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(buttonPresses, equals(0));
        expect(globalShortcutCalls, equals(0));
        expect(completed, isFalse);

        runner.dispose();
        await future;
        terminal.dispose();
      },
    );

    test(
      'SceneManager skips global shortcuts on release and forwards only to wantsKeyReleaseEvents widgets',
      () async {
        final backend = MockTerminalBackend();
        final terminal = Terminal(backend);
        final scene = SceneManager(terminal);
        var sceneGlobalCalls = 0;
        scene.onKeyEvent = (_) {
          sceneGlobalCalls++;
          return true;
        };

        final receiver = _KeyReleaseReceiver(wantsKeyReleaseEvents: true);
        final ignored = _KeyReleaseReceiver(wantsKeyReleaseEvents: false);
        final focusNode = FocusNode(id: 'term_focus');
        final focusReceived = <KeyEvent>[];

        final runner = PromptRunner<void>(
          terminal: terminal,
          mode: ExecutionMode.managed,
          widget: Column([
            receiver,
            ignored,
            _FocusReleaseWidget(
              received: focusReceived,
              focusNode: focusNode,
              wantsKeyReleaseEvents: true,
            ),
          ]),
        );

        final layer = SceneLayer(renderer: runner, width: 40, height: 10);
        scene.layers.add(layer);
        scene.focusedLayer = layer;
        final runFuture = runner.run();
        await Future<void>.delayed(Duration.zero);
        focusNode.requestFocus();

        const releaseEvent = KeyEvent(
          'k',
          KeyType.character,
          eventType: KeyEventType.release,
        );
        scene.handleKeyEvent(releaseEvent);

        // Global scene shortcut was skipped on release, and Focus release widget got it.
        expect(sceneGlobalCalls, equals(0));
        expect(focusReceived, equals([releaseEvent]));
        expect(ignored.received, isEmpty);

        // Also verify direct KeyEventHandler element routing when Focus doesn't consume.
        focusNode.unfocus();
        const release2 = KeyEvent(
          'z',
          KeyType.character,
          eventType: KeyEventType.release,
        );
        scene.handleKeyEvent(release2);
        expect(receiver.received, equals([release2]));
        expect(ignored.received, isEmpty);

        scene.dispose();
        await runFuture;
        terminal.dispose();
      },
    );
  });
}
