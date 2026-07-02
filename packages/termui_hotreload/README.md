# termui_hotreload

An optional companion package for `termui` that provides dead-simple automatic hot reloading during development.

## Features

- **Seamless integration:** Injects Dart VM hot reloading into your `termui` application.
- **Zero-config binding:** Automatically broadcasts hot reload events to all registered `Reassemblable` widgets in the `termui` widget tree.
- **Development only:** Gracefully bypasses hot reload initialization when compiled or run in a production environment (when `dart.vm.product` is true).

## Getting started

Add `termui_hotreload` to your `pubspec.yaml`:

```yaml
dependencies:
  termui_hotreload: any
```

## Usage

Simply call `TermuiHotReload.enable()` at the beginning of your `main()` function, and call `disable()` when your application is shutting down.

```dart
import 'package:termui/termui.dart';
import 'package:termui_hotreload/termui_hotreload.dart';

void main() async {
  // 1. Setup HotReloader in development mode
  final hotreload = await TermuiHotReload.enable(
    onError: (e) {
      // Custom fallback logic if VM service is not found
    },
  );

  final terminal = Terminal();
  final runner = PromptRunner<void>(
    terminal: terminal,
    widget: const Text('Hello World!'),
  );

  await runner.run();

  // 2. Disable at the end so the Dart process can gracefully exit
  await hotreload?.disable();
  terminal.dispose();
}
```

### Running with Hot Reload

To allow the application to hot reload, you must run your Dart application with the VM service enabled:

```sh
dart --enable-vm-service bin/main.dart
```

Now modify your widget code, save the file, and watch the terminal UI update instantly without losing state!

## Additional information

For more information, visit the [termui repository](https://github.com/jtmcdole/termui).
