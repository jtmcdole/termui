@TestOn('vm')
library;

import 'package:termui/src/terminal/windows_console_input.dart';
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
}
