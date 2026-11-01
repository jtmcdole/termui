@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:math';

import 'package:ffi/ffi.dart';
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
        ENABLE_WINDOW_INPUT,
        FOCUS_EVENT,
        INPUT_RECORD,
        INPUT_RECORD_0_Extension,
        KEY_EVENT,
        KEY_EVENT_RECORD_0_Extension,
        MOUSE_EVENT,
        VK_MENU,
        WINDOW_BUFFER_SIZE_EVENT;

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

void _writeKeyRecord(
  Pointer<INPUT_RECORD> records,
  int index, {
  required bool keyDown,
  required int codeUnit,
  int repeatCount = 1,
  int virtualKeyCode = 0,
}) {
  final record = records[index];
  record.EventType = KEY_EVENT;
  record.KeyEvent
    ..bKeyDown = keyDown
    ..wRepeatCount = repeatCount
    ..wVirtualKeyCode = virtualKeyCode
    ..UnicodeChar = codeUnit;
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

  group('WindowsConsoleInputDecoder', () {
    test(
      'ignores non-key, key-up, and zero-char records while decoding SGR bytes',
      () {
        const sgr = '\x1b[<0;5;4M';
        final totalRecords = 6 + sgr.codeUnits.length;
        final records = calloc<INPUT_RECORD>(totalRecords);
        try {
          records[0].EventType = FOCUS_EVENT;
          records[1].EventType = MOUSE_EVENT;
          records[2].EventType = WINDOW_BUFFER_SIZE_EVENT;
          // Key-up for 'q' must not emit a duplicate character.
          _writeKeyRecord(
            records,
            3,
            keyDown: false,
            codeUnit: 0x71,
            virtualKeyCode: 0x51,
          );
          // Modifier-only key-down (Shift/Ctrl/Alt) has UnicodeChar == 0.
          _writeKeyRecord(records, 4, keyDown: true, codeUnit: 0);
          // Normal Alt release has UnicodeChar == 0 and must be ignored.
          _writeKeyRecord(
            records,
            5,
            keyDown: false,
            codeUnit: 0,
            virtualKeyCode: VK_MENU,
          );

          for (var i = 0; i < sgr.codeUnits.length; i++) {
            _writeKeyRecord(
              records,
              6 + i,
              keyDown: true,
              codeUnit: sgr.codeUnits[i],
            );
          }

          final decoder = WindowsConsoleInputDecoder();
          final bytes = decoder.decode(records, totalRecords);
          expect(utf8.decode(bytes), equals(sgr));
        } finally {
          calloc.free(records);
        }
      },
    );

    test('decodes BMP multi-byte UTF-8, Alt+Numpad VK_MENU key-up, '
        'and wRepeatCount', () {
      final records = calloc<INPUT_RECORD>(4);
      try {
        // repeatCount: 0 on synthetic records falls back to 1.
        _writeKeyRecord(
          records,
          0,
          keyDown: true,
          codeUnit: 'é'.codeUnitAt(0),
          repeatCount: 0,
        );
        // Alt+Numpad commits its composed character on VK_MENU key-up.
        _writeKeyRecord(
          records,
          1,
          keyDown: false,
          codeUnit: 'ñ'.codeUnitAt(0),
          virtualKeyCode: VK_MENU,
        );
        _writeKeyRecord(
          records,
          2,
          keyDown: true,
          codeUnit: '─'.codeUnitAt(0),
          repeatCount: 3,
        );
        _writeKeyRecord(
          records,
          3,
          keyDown: true,
          codeUnit: 'q'.codeUnitAt(0),
          repeatCount: 2,
        );

        final decoder = WindowsConsoleInputDecoder();
        final bytes = decoder.decode(records, 4);
        expect(utf8.decode(bytes), equals('éñ───qq'));
      } finally {
        calloc.free(records);
      }
    });

    test('stitches UTF-16 surrogate pairs across batches and interleaved '
        'non-character records', () {
      const party = '🎉'; // 0xD83C, 0xDF89
      final high = party.codeUnitAt(0);
      final low = party.codeUnitAt(1);
      final batch1 = calloc<INPUT_RECORD>(3);
      final batch2 = calloc<INPUT_RECORD>(1);
      try {
        _writeKeyRecord(batch1, 0, keyDown: true, codeUnit: high);
        // Interleaved key-up and focus records must not drop the high half.
        _writeKeyRecord(batch1, 1, keyDown: false, codeUnit: high);
        batch1[2].EventType = FOCUS_EVENT;
        _writeKeyRecord(
          batch2,
          0,
          keyDown: true,
          codeUnit: low,
          repeatCount: 2,
        );

        final decoder = WindowsConsoleInputDecoder();
        expect(decoder.decode(batch1, 3), isEmpty);
        final secondBytes = decoder.decode(batch2, 1);
        expect(utf8.decode(secondBytes), equals('🎉🎉'));
        expect(decoder.flush(), isEmpty);
      } finally {
        calloc.free(batch1);
        calloc.free(batch2);
      }
    });

    test('replaces unpaired surrogates with U+FFFD and preserves a following '
        'valid pair', () {
      const grin = '😀'; // 0xD83D, 0xDE00
      final records = calloc<INPUT_RECORD>(6);
      try {
        // Lone high surrogate followed by 'a' -> '\uFFFDa'
        _writeKeyRecord(records, 0, keyDown: true, codeUnit: 0xD83C);
        _writeKeyRecord(records, 1, keyDown: true, codeUnit: 0x61);
        // Lone high surrogate followed directly by a valid pair -> '\uFFFD😀'
        _writeKeyRecord(records, 2, keyDown: true, codeUnit: 0xD83C);
        _writeKeyRecord(
          records,
          3,
          keyDown: true,
          codeUnit: grin.codeUnitAt(0),
        );
        _writeKeyRecord(
          records,
          4,
          keyDown: true,
          codeUnit: grin.codeUnitAt(1),
        );
        // Lone low surrogate -> '\uFFFD'
        _writeKeyRecord(records, 5, keyDown: true, codeUnit: 0xDF89);

        final decoder = WindowsConsoleInputDecoder();
        final bodyBytes = decoder.decode(records, 6);
        expect(utf8.decode(bodyBytes), equals('\uFFFDa\uFFFD😀\uFFFD'));

        // Trailing lone high surrogate -> held until flush()
        final trailing = calloc<INPUT_RECORD>(1);
        try {
          _writeKeyRecord(trailing, 0, keyDown: true, codeUnit: 0xD83D);
          expect(decoder.decode(trailing, 1), isEmpty);
          expect(utf8.decode(decoder.flush()), equals('\uFFFD'));
          expect(decoder.flush(), isEmpty);
        } finally {
          calloc.free(trailing);
        }
      } finally {
        calloc.free(records);
      }
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
