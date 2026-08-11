import 'dart:io';
import 'package:termui_tinpot/src/cli_runner.dart';

void main(List<String> arguments) async {
  final exitCode = await runTinpotCli(arguments);
  exit(exitCode);
}
