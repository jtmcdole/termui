@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/file_drop_bridge.dart';
import 'package:web/web.dart' as web;

bool _dispatchCancelableKeyDown({
  required String key,
  String code = 'KeyO',
  bool ctrlKey = false,
  bool shiftKey = false,
  bool altKey = false,
  bool metaKey = false,
  bool isComposing = false,
  int keyCode = 0,
}) {
  final event = web.KeyboardEvent(
    'keydown',
    web.KeyboardEventInit(
      key: key,
      code: code,
      ctrlKey: ctrlKey,
      shiftKey: shiftKey,
      altKey: altKey,
      metaKey: metaKey,
      isComposing: isComposing,
      keyCode: keyCode,
      bubbles: true,
      cancelable: true,
    ),
  );
  web.window.dispatchEvent(event);
  return event.defaultPrevented;
}

void main() {
  test(
    'synchronously calls preventDefault() on browser Ctrl+<key> terminal chords without blocking paste, DevTools, zoom, or Cmd shortcuts',
    () {
      final bridge = attachFileDropBridge(
        onDragHoverChanged: (_) {},
        onFilesDropped: (_) {},
      );
      addTearDown(bridge.dispose);

      // Unshifted Ctrl+O (lowercase, CapsLock uppercase, and C0) and terminal chords must suppress browser Open/Save/Print/Find dialogs.
      expect(_dispatchCancelableKeyDown(key: 'o', ctrlKey: true), isTrue);
      expect(_dispatchCancelableKeyDown(key: 'O', ctrlKey: true), isTrue);
      expect(_dispatchCancelableKeyDown(key: '\x0f', ctrlKey: true), isTrue);
      expect(
        _dispatchCancelableKeyDown(key: 's', code: 'KeyS', ctrlKey: true),
        isTrue,
      );
      expect(
        _dispatchCancelableKeyDown(key: 'p', code: 'KeyP', ctrlKey: true),
        isTrue,
      );
      expect(
        _dispatchCancelableKeyDown(key: 'f', code: 'KeyF', ctrlKey: true),
        isTrue,
      );
      expect(
        _dispatchCancelableKeyDown(key: 'b', code: 'KeyB', ctrlKey: true),
        isTrue,
      );
      expect(
        _dispatchCancelableKeyDown(key: r'\', code: 'Backslash', ctrlKey: true),
        isTrue,
      );

      // Paste (Ctrl+Shift+V), DevTools (Ctrl+Shift+I, F12), macOS Cmd+O, browser zoom (Ctrl+=/Ctrl+-/Ctrl+0), and bare keys stay untouched.
      expect(
        _dispatchCancelableKeyDown(
          key: 'V',
          code: 'KeyV',
          ctrlKey: true,
          shiftKey: true,
        ),
        isFalse,
      );
      expect(
        _dispatchCancelableKeyDown(
          key: 'I',
          code: 'KeyI',
          ctrlKey: true,
          shiftKey: true,
        ),
        isFalse,
      );
      expect(_dispatchCancelableKeyDown(key: 'o', metaKey: true), isFalse);
      expect(
        _dispatchCancelableKeyDown(key: 'o', ctrlKey: true, altKey: true),
        isFalse,
      );
      expect(
        _dispatchCancelableKeyDown(key: '=', code: 'Equal', ctrlKey: true),
        isFalse,
      );
      expect(
        _dispatchCancelableKeyDown(key: '-', code: 'Minus', ctrlKey: true),
        isFalse,
      );
      expect(
        _dispatchCancelableKeyDown(key: '0', code: 'Digit0', ctrlKey: true),
        isFalse,
      );
      expect(_dispatchCancelableKeyDown(key: 'F12', code: 'F12'), isFalse);
      expect(
        _dispatchCancelableKeyDown(
          key: 'Control',
          code: 'ControlLeft',
          ctrlKey: true,
        ),
        isFalse,
      );
      expect(_dispatchCancelableKeyDown(key: 'o'), isFalse);

      // Non-Latin keyboard layouts still suppress browser Ctrl+<letter> defaults via event.code.
      expect(
        _dispatchCancelableKeyDown(key: 'щ', code: 'KeyO', ctrlKey: true),
        isTrue,
      );
      // IME composition events must not call preventDefault().
      expect(
        _dispatchCancelableKeyDown(
          key: 'o',
          code: 'KeyO',
          ctrlKey: true,
          isComposing: true,
        ),
        isFalse,
      );
      expect(
        _dispatchCancelableKeyDown(
          key: 'o',
          code: 'KeyO',
          ctrlKey: true,
          keyCode: 229,
        ),
        isFalse,
      );

      // Disposing the bridge detaches the DOM keydown listener.
      bridge.dispose();
      expect(_dispatchCancelableKeyDown(key: 'o', ctrlKey: true), isFalse);
    },
  );
}
