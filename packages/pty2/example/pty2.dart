// ignore_for_file: avoid_print

import 'dart:io';
import 'package:pty2/pty.dart';

void main() async {
  print('Platform: ${Platform.isWindows ? 'pwsh.exe' : 'bash'}');

  final pty = PseudoTerminal.start(
    Platform.isWindows ? 'pwsh.exe' : 'bash',
    [],
    environment: {...Platform.environment, 'codefu': '1234'},
    raw: true,
  );

  pty.resize(120, 40);

  if (Platform.isWindows) {
    pty.write('dir\r\n');
  } else {
    pty.write('ls -la\n');
  }
  if (Platform.isWindows) {
    pty.write('echo \$env:codefu\r\n');
  } else {
    pty.write('echo \$codefu\n');
  }

  pty.out.listen((data) {
    stdout.write(data);
  });

  await Future.delayed(const Duration(seconds: 1));
  pty.kill();

  print(await pty.exitCode);
}
