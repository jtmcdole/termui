import 'dart:async';
import 'dart:io';
import 'package:pty2/pty.dart';
import 'package:pty2/src/impl/windows.dart' if (dart.library.html) '';

void main() async {
  final execName = Platform.isWindows ? 'echo_server.exe' : 'echo_server';
  final execFile = File('benchmark/$execName');

  if (!execFile.existsSync()) {
    stdout.writeln('Please compile echo_server.dart to $execName first.');
    exit(1);
  }

  Future<void> runIntegrityTest(bool legacy) async {
    if (Platform.isWindows) {
      PtyCoreWindows.forceLegacyForTesting = legacy;
    }
    stdout.writeln(
      '\n--- Integrity Test (${legacy ? 'Legacy Pipes' : 'ConPTY'}) ---',
    );

    final pty = PseudoTerminal.start(execFile.absolute.path, []);

    final ansiRegex = RegExp(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])');

    int expectedNumber = 1;
    int missingNumbers = 0;
    int totalParsed = 0;

    String buffer = '';

    pty.out.listen((data) {
      final cleanData = data.replaceAll(ansiRegex, '');
      buffer += cleanData;

      final commaIndex = buffer.lastIndexOf(',');
      if (commaIndex != -1) {
        final chunkToParse = buffer.substring(0, commaIndex);
        buffer = buffer.substring(commaIndex + 1);

        final parts = chunkToParse.split(',');
        for (final part in parts) {
          final trimmed = part.trim();
          if (trimmed.isEmpty) continue;

          final num = int.tryParse(trimmed);
          if (num != null) {
            totalParsed++;
            if (num != expectedNumber) {
              if (num > expectedNumber) {
                missingNumbers += (num - expectedNumber);
              } else {
                missingNumbers++;
              }
              expectedNumber = num + 1;
            } else {
              expectedNumber++;
            }
          }
        }
      }
    });

    int sentNumber = 1;
    const targetNumbers = 100000;

    while (sentNumber <= targetNumbers) {
      final sb = StringBuffer();
      for (int i = 0; i < 500 && sentNumber <= targetNumbers; i++) {
        sb.write('$sentNumber,');
        sentNumber++;
      }
      pty.write(sb.toString());
      await Future.delayed(Duration.zero);
    }

    await Future.delayed(Duration(seconds: 2));
    pty.kill();
    await pty.exitCode;

    stdout.writeln('Sent          : $targetNumbers');
    stdout.writeln('Parsed        : $totalParsed');
    stdout.writeln('Missing/Drop  : $missingNumbers');
    final lossRate = (missingNumbers / targetNumbers) * 100;
    stdout.writeln('Data Loss %   : ${lossRate.toStringAsFixed(4)}%');

    if (Platform.isWindows) {
      PtyCoreWindows.forceLegacyForTesting = false;
    }
  }

  await runIntegrityTest(false);
  if (Platform.isWindows) {
    await runIntegrityTest(true);
  }
}
