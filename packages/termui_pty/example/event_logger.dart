import 'dart:io';
import 'package:termui/terminal/terminal.dart' as term;

void main() async {
  final logFile = File('/app/tcpp/events.log');
  await logFile.writeAsString('Started event logger\n');

  await term.Terminal.runGuarded((terminal) async {
    terminal.enterAlternateScreen();
    terminal.hideCursor();
    terminal.enableMouseTracking();

    try {
      await for (final event in terminal.events) {
        logFile.writeAsStringSync('Event: \$event\n', mode: FileMode.append);
        if (event is term.KeyEvent &&
            (event.key == 'q' || event.key == '\x03')) {
          break;
        }
      }
    } finally {
      terminal.exitAlternateScreen();
      terminal.showCursor();
      terminal.disableMouseTracking();
    }
  });

  exit(0);
}
