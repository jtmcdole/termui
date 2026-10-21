import 'package:termui/termui.dart';
import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/event.dart' as ui;
import 'package:termui_shared_examples/widget_book/widget_book_examples.dart';

class CliWidgetBookPlatform implements WidgetBookPlatform {
  Timer? _timer;

  @override
  bool get shouldRenderToTerminal => true;

  @override
  void onFrameRedrawn(Buffer buffer) {}

  @override
  void startTicker(void Function(Duration elapsed) onTick) {
    _timer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      onTick(const Duration(milliseconds: 16));
    });
  }

  @override
  void stopTicker() {
    _timer?.cancel();
  }

  @override
  bool handleKeyEvent(term.Terminal terminal, ui.KeyEvent event) {
    return false; // No platform-specific overrides for CLI
  }

  @override
  String? get initialPage => null;

  @override
  void onExit() {
    print('\nWidget Book exited cleanly.');
    exit(0);
  }

  @override
  Future<void> saveFile(String basename, List<int> bytes) async {}
}

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'mode',
      abbr: 'm',
      allowed: ['alternate', 'inline'],
      defaultsTo: 'alternate',
      help: 'Terminal rendering mode to run the widget book in.',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage details.');

  late ArgResults results;
  try {
    results = parser.parse(arguments);
  } catch (e) {
    stderr.writeln(e);
    exit(1);
  }

  if (results['help'] as bool) {
    print('Widget Book: A visual component catalog for cli_experiment.\n');
    print(parser.usage);
    exit(0);
  }

  final isInline = results['mode'] == 'inline';

  await term.Terminal.runGuarded((terminal) async {
    final platform = CliWidgetBookPlatform();
    await runWidgetBookShared(terminal, platform, isInline: isInline);
  });
}
