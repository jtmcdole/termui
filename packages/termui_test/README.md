# termui_test

Integration testing harness and utilities for the [termui](https://pub.dev/termui) package. This package runs TUI tests inside a controlled asynchronous timeline using `fake_async`, simulates user interaction (keys, mouse, resizing), performs element tree searches (finders), and supports automated terminal session traces.

---

## Features

- **Controlled Time Execution**: Uses `fake_async` to run test code synchronously and tick time precisely.
- **Simulated Input events**: Simulates keyboard key presses (with modifier support), string typing, mouse clicks, and terminal resize events.
- **Widget Tree Queries**: Leverages Flutter-like `Finder` APIs (e.g. `find.text`, `find.byType`) to query mounted elements.
- **Trace Recordings**: Automatically records tests into Asciinema `.cast` files for replay, including action logs mapped to metadata events.

---

## Key APIs & Classes

- **`TerminalTester`**: The main execution harness. Wraps tests in `fake_async` using `tester.run()`, manages the mock backend, pumps widgets, and controls trace recording.
- **`LogicalKey`**: Models key sequences for typing simulation (such as arrows, function keys, backspace, modifier keys).
- **`Finder` / `find`**: Utility namespace to locate widgets inside the active layout context.
- **`findsNothing` / `findsOneWidget` / `findsNWidgets`**: Assertions for verifying widget presence in the tree.

---

## Writing Integration Tests

Here is a simple example showing how to write an integration test using `TerminalTester`:

```dart
import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';

void main() {
  test('increments counter on button tap', () {
    final tester = TerminalTester();

    tester.run(() async {
      // Pump/mount the widget tree under test
      await tester.pumpWidget(
        Column(
          children: [
            Text('Clicked: 0 times'),
            Text('Submit'),
          ],
        ),
      );

      // Verify initial UI state
      expect(find.text('Clicked: 0 times'), findsOneWidget);

      // Simulate a mouse tap/click on the 'Submit' text widget
      tester.tap(find.text('Submit'));
      
      // Wait for layout updates or timers to settle
      await tester.pump();

      // Assert state changes, e.g. checking output changes
    });
  });
}
```

---

## Trace Recording & Actions Log

`TerminalTester` can automatically record interactive sessions during tests. This is invaluable for visual verification, debugging, or generating playbacks.

### 1. Enabling Trace Recording

Trace recording is configured via the `recordTraces` parameter in the `TerminalTester` constructor. By default, it is also controlled by the `ASCIICAST_TESTS` environment variable:

```dart
final tester = TerminalTester(
  recordTraces: true,
);
```

To enable trace recording, run your tests with the `ASCIICAST_TESTS` environment variable or `--dart-define` option set to `true` (which is the default):

```bash
# Enable trace recording (default is true)
dart test

# Disable trace recording explicitly
dart test --dart-define=ASCIICAST_TESTS=false
```

### 2. Dynamic Trace Filenames

When trace recording is enabled, trace files are automatically generated using dynamic, sanitized filenames based on the active test name (retrieved via `Invoker`/`TestHandle`). 
- A test named `'Verify multi-pane settings layout'` will produce a sanitized trace file named `verify_multi_pane_settings_layout.cast` in the project root.
- Unnamed or empty test states default to `trace.cast`.

### 3. Automated Action Logs & Debug Metadata

While a test is executing, user actions (like `sendKey`, `sendString`, `tap`, `simulateResize`) are automatically logged and appended to the cast file.
- Action logs are stored as custom `'d'` (debug metadata) event rows in the JSONL `.cast` file.
- When playing back the `.cast` file in `AsciicastPlayer`, these events appear in a dedicated Unicode Metadata border box above the status line, showing exactly which simulated event triggered each frame.
