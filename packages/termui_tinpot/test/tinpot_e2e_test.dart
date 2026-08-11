import 'dart:convert';
import 'dart:io';
import 'package:termui_tinpot/src/cli_runner.dart';
import 'package:test/test.dart';

void main() {
  group('tinpot CLI E2E Tests', () {
    late String assetPath;
    late String goldenPath;

    setUpAll(() {
      final rootDir = Directory.current.path;
      assetPath = '$rootDir/test/assets/omega_Gate.png';

      goldenPath = '$rootDir/test/assets/gate.main.ansi';
    });

    test(
      'AC1 Programmatic Golden Verification: --background FF000000 output matches gate.main.ansi byte-by-byte',
      () async {
        expect(
          File(goldenPath).existsSync(),
          isTrue,
          reason: 'gate.main.ansi must exist at $goldenPath',
        );
        expect(
          File(assetPath).existsSync(),
          isTrue,
          reason: 'omega_Gate.png must exist at $assetPath',
        );

        final goldenBytes = await File(goldenPath).readAsBytes();

        final out = StringBuffer();
        final err = StringBuffer();
        final exitCode = await runTinpotCli([
          assetPath,
          '--width',
          '85',
          '--background',
          'FF000000',
          '--work',
          '9',
          '--din99d',
        ], out: out, err: err);

        expect(
          exitCode,
          equals(0),
          reason: 'tinpot CLI should exit with 0. stderr: $err',
        );

        final outputBytes = utf8.encode(out.toString());
        expect(
          outputBytes,
          equals(goldenBytes),
          reason: 'Output bytes must match golden bytes byte-by-byte',
        );
      },
    );

    test(
      'AC2 Visual/Cell Verification: --background FF00001F (Dart blue) cell background verification',
      () async {
        final out = StringBuffer();
        final err = StringBuffer();
        final exitCode = await runTinpotCli([
          assetPath,
          '--width',
          '85',
          '--background',
          'FF00001F',
          '--work',
          '9',
          '--din99d',
        ], out: out, err: err);

        expect(
          exitCode,
          equals(0),
          reason: 'tinpot CLI should exit with 0. stderr: $err',
        );

        final stdoutText = out.toString();

        // Dart blue is ARGB 0xFF00001F -> RGB (0, 0, 31).
        // Background ANSI sequence will be \x1B[48;2;0;0;31m.
        // Transparent cells (spaces ' ') should contain \x1B[48;2;0;0;31m.
        expect(
          stdoutText,
          contains('\x1B[48;2;0;0;31m'),
          reason:
              'Output must render transparent cells with Dart blue background ANSI sequence ESC[48;2;0;0;31m',
        );
      },
    );

    test(
      'AC2 Visual/Cell Verification: --background FFFFFFFF (White) cell background verification',
      () async {
        final out = StringBuffer();
        final err = StringBuffer();
        final exitCode = await runTinpotCli([
          assetPath,
          '--width',
          '85',
          '--background',
          'FFFFFFFF',
          '--work',
          '9',
          '--din99d',
        ], out: out, err: err);

        expect(
          exitCode,
          equals(0),
          reason: 'tinpot CLI should exit with 0. stderr: $err',
        );

        final stdoutText = out.toString();

        // White is ARGB 0xFFFFFFFF -> RGB (255, 255, 255).
        // Background ANSI sequence will be \x1B[48;2;255;255;255m.
        // Transparent cells should contain \x1B[48;2;255;255;255m.
        expect(
          stdoutText,
          contains('\x1B[48;2;255;255;255m'),
          reason:
              'Output must render transparent cells with White background ANSI sequence ESC[48;2;255;255;255m',
        );
      },
    );
  });
}
