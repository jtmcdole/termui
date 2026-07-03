// ignore_for_file: file_names
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui_shared_examples/glass_compositing/glass_compositing.dart';

void main() async {
  await term.Terminal.runGuarded((terminal) async {
    await runGlassCompositingShared(terminal, isInline: false);
  });
}
