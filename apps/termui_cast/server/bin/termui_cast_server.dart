import 'dart:io';

import 'package:termui_cast_server/termui_cast_server.dart';

Future<void> main(List<String> args) async {
  exitCode = await runServerCli(args);
}
