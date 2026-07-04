import 'dart:io';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/termui.dart';
import 'package:pty2/pty2.dart';
import 'package:termui_pty/termui_pty.dart';

void main() async {
  // Start a bash shell that launches top, with a valid TERM environment
  final pty = PseudoTerminal.start(
    'bash',
    ['-c', 'top'],
    environment: {'TERM': 'xterm-256color'},
  );

  await term.Terminal.runGuarded((terminal) async {
    terminal.enterAlternateScreen();
    terminal.hideCursor();

    try {
      final runner = PromptRunner(
        terminal: terminal,
        alternateScreen: true,
        widget: SizedBox.expand(
          child: PlatformView(pty: pty),
        ),
      );

      // Run until the user types 'q' in top, which exits top and closes the pty?
      // Wait, top exits when you type 'q'. If the pty process exits, we should exit.
      // But PromptRunner runs until `abort` is called or focus is lost.
      // Let's just run it.
      await runner.run();
    } finally {
      terminal.showCursor();
      terminal.exitAlternateScreen();
    }
  });
  
  print('Exited cleanly.');
  exit(0);
}
