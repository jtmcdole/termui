import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui_tinpot_example/termui_tinpot_app.dart';

void main() async {
  await term.Terminal.runGuarded((terminal) async {
    await runTinpotApp(terminal);
  });
}
