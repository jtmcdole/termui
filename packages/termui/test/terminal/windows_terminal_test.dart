@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:termui/src/terminal/windows_console_input.dart';
import 'package:termui/terminal/backend/io_backend.dart';
import 'package:termui/terminal/raw/terminal.dart' as raw;
import 'package:termui/terminal/terminal.dart';
import 'package:test/test.dart';
import 'package:win32/win32.dart'
    show
        ENABLE_AUTO_POSITION,
        ENABLE_ECHO_INPUT,
        ENABLE_EXTENDED_FLAGS,
        ENABLE_INSERT_MODE,
        ENABLE_LINE_INPUT,
        ENABLE_MOUSE_INPUT,
        ENABLE_PROCESSED_INPUT,
        ENABLE_QUICK_EDIT_MODE,
        ENABLE_VIRTUAL_TERMINAL_INPUT,
        ENABLE_WINDOW_INPUT;

final class _FakeRawTerminal implements raw.Terminal {
  _FakeRawTerminal(this.log, this._openStream);

  final List<String> log;
  final Stream<List<int>> Function() _openStream;

  @override
  void enableRawMode() {
    log.add('enableRawMode');
  }

  @override
  void disableRawMode() {
    log.add('disableRawMode');
  }

  @override
  Point<int> getScreenBufferSize() => const Point(100, 30);

  @override
  Stream<List<int>> openInputStream() {
    log.add('openInputStream');
    return _openStream();
  }
}

void main() {
  group('Windows console mode bitmasks', () {
    test('configureWindowsRawInputMode clears cooked and QuickEdit flags '
        'and sets VT + mouse flags', () {
      // Default Windows console input mode (0x01f7).
      final defaultCooked =
          ENABLE_PROCESSED_INPUT |
          ENABLE_LINE_INPUT |
          ENABLE_ECHO_INPUT |
          ENABLE_WINDOW_INPUT |
          ENABLE_MOUSE_INPUT |
          ENABLE_INSERT_MODE |
          ENABLE_QUICK_EDIT_MODE |
          ENABLE_EXTENDED_FLAGS |
          ENABLE_AUTO_POSITION;

      final rawMode = configureWindowsRawInputMode(defaultCooked);

      expect(rawMode & ENABLE_ECHO_INPUT, equals(0));
      expect(rawMode & ENABLE_PROCESSED_INPUT, equals(0));
      expect(rawMode & ENABLE_LINE_INPUT, equals(0));
      expect(rawMode & ENABLE_WINDOW_INPUT, equals(0));
      expect(rawMode & ENABLE_QUICK_EDIT_MODE, equals(0));

      expect(rawMode & ENABLE_EXTENDED_FLAGS, equals(ENABLE_EXTENDED_FLAGS));
      expect(rawMode & ENABLE_MOUSE_INPUT, equals(ENABLE_MOUSE_INPUT));
      expect(
        rawMode & ENABLE_VIRTUAL_TERMINAL_INPUT,
        equals(ENABLE_VIRTUAL_TERMINAL_INPUT),
      );
      expect(rawMode & ENABLE_INSERT_MODE, equals(ENABLE_INSERT_MODE));
      expect(rawMode & ENABLE_AUTO_POSITION, equals(ENABLE_AUTO_POSITION));
    });

    test(
      'configureWindowsRawInputMode enables required flags even from zero',
      () {
        final rawMode = configureWindowsRawInputMode(0);
        expect(
          rawMode,
          equals(
            ENABLE_EXTENDED_FLAGS |
                ENABLE_MOUSE_INPUT |
                ENABLE_VIRTUAL_TERMINAL_INPUT,
          ),
        );
      },
    );

    test('configureWindowsRestoreInputMode sets ENABLE_EXTENDED_FLAGS '
        'without enabling unset flags', () {
      final savedWithoutExtended =
          ENABLE_PROCESSED_INPUT |
          ENABLE_LINE_INPUT |
          ENABLE_ECHO_INPUT |
          ENABLE_INSERT_MODE |
          ENABLE_QUICK_EDIT_MODE;

      expect(
        configureWindowsRestoreInputMode(savedWithoutExtended),
        equals(savedWithoutExtended | ENABLE_EXTENDED_FLAGS),
      );

      final savedWithoutQuickEdit =
          ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT;
      final restoredWithoutQuickEdit = configureWindowsRestoreInputMode(
        savedWithoutQuickEdit,
      );
      expect(
        restoredWithoutQuickEdit,
        equals(savedWithoutQuickEdit | ENABLE_EXTENDED_FLAGS),
      );
      expect(restoredWithoutQuickEdit & ENABLE_QUICK_EDIT_MODE, equals(0));
    });
  });

  group('IoTerminalBackend lazy reader lifecycle', () {
    test('Terminal enables raw mode before starting input reader', () async {
      final log = <String>[];
      final source = StreamController<List<int>>();
      final backend = IoTerminalBackend(
        rawTerminal: _FakeRawTerminal(log, () => source.stream),
      );

      // Constructing IoTerminalBackend alone does not start the input reader.
      expect(log, isEmpty);

      final terminal = Terminal(backend);
      expect(log, equals(['enableRawMode', 'openInputStream']));

      final eventsFuture = terminal.events.first;
      source.add(utf8.encode('q'));
      final event = await eventsFuture;
      expect(event, isA<KeyEvent>().having((e) => e.key, 'key', 'q'));

      terminal.dispose();
      // Idempotent second dispose must not throw.
      backend.dispose();
      expect(
        log,
        equals(['enableRawMode', 'openInputStream', 'disableRawMode']),
      );
      await source.close();
    });

    test('canceling and re-listening on rawInput does not open a duplicate '
        'source stream', () async {
      final log = <String>[];
      final source = StreamController<List<int>>();
      final backend = IoTerminalBackend(
        rawTerminal: _FakeRawTerminal(log, () => source.stream),
      );

      final sub1 = backend.rawInput.listen((_) {});
      await sub1.cancel();

      final received = <List<int>>[];
      final errors = <Object>[];
      final done = Completer<void>();
      final sub2 = backend.rawInput.listen(
        received.add,
        onError: errors.add,
        onDone: done.complete,
      );

      expect(log, equals(['openInputStream']));
      source.add(const [65, 66]);
      source.addError(StateError('upstream read failed'));
      await source.close();
      await done.future;

      expect(
        received,
        equals([
          const [65, 66],
        ]),
      );
      expect(errors, contains(isA<StateError>()));

      await sub2.cancel();
      backend.dispose();
    });

    test('disposing before listening never opens input stream and completes '
        'listeners immediately', () async {
      final log = <String>[];
      final backend = IoTerminalBackend(
        rawTerminal: _FakeRawTerminal(
          log,
          () => fail('openInputStream must not run after dispose'),
        ),
      );

      backend.dispose();

      final done = Completer<void>();
      backend.rawInput.listen((_) {}, onDone: done.complete);
      await done.future;
      expect(log, isEmpty);
    });
  });
}
