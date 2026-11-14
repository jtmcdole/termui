import 'dart:io';

import 'package:termui_caster_cli/termui_caster_cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runCasterCli(args);
}
