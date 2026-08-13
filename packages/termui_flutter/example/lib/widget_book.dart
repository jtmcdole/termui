import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/event.dart' as ui;
import 'package:termui_shared_examples/widget_book/widget_book_examples.dart';
import 'package:termui_flutter/termui_flutter.dart';

final class FlutterWidgetBookPlatform implements WidgetBookPlatform {
  final void Function(Buffer)? _onFrameRedrawn;
  final String? _initialPage;
  Ticker? _ticker;

  FlutterWidgetBookPlatform(this._onFrameRedrawn, this._initialPage);

  @override
  bool get shouldRenderToTerminal => false;

  @override
  void onFrameRedrawn(Buffer buffer) {
    _onFrameRedrawn?.call(buffer);
  }

  @override
  void startTicker(void Function(Duration elapsed) onTick) {
    _ticker = Ticker((elapsed) {
      onTick(elapsed);
    });
    _ticker!.start();
  }

  @override
  void stopTicker() {
    _ticker?.dispose();
  }

  @override
  String? get initialPage => _initialPage;

  @override
  bool handleKeyEvent(term.Terminal terminal, ui.KeyEvent event) {
    if (event.modifiers.contains(ui.Modifier.control) &&
        terminal is FlutterTerminal) {
      switch (event.key) {
        case '=' || '+':
          terminal.increaseFontSize();
          return true;
        case '-':
          terminal.decreaseFontSize();
          return true;
      }
    }
    return false;
  }

  @override
  void onExit() {}

  @override
  Future<void> saveFile(String basename, List<int> bytes) async {
    await saveFile(basename, bytes);
  }
}

Future<void> runWidgetBook(
  term.Terminal terminal, {
  bool isInline = false,
  void Function(Buffer buffer)? onFrameRedrawn,
  String? initialPage,
}) async {
  final platform = FlutterWidgetBookPlatform(onFrameRedrawn, initialPage);
  await runWidgetBookShared(terminal, platform, isInline: isInline);
}
