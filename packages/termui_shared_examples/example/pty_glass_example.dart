import 'dart:io';
import 'package:termui/terminal/terminal.dart' as term;
// Reuse the shared runner logic from the flutter example directory.
import 'package:termui_shared_examples/glass_compositing/pty_glass_runner.dart';

void main() async {
  await term.Terminal.runGuarded((terminal) async {
    await runPtyGlassDemo(terminal);
  });

  exit(0);
}
