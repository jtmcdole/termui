import 'dart:io';

import 'package:file/memory.dart';
import 'package:test/test.dart';

import '../bin/termui_play.dart';

void main() {
  group('termui_play CLI validation', () {
    test(
      'exits with 64 and writes to stderr when input path is missing',
      () async {
        final out = StringBuffer();
        final err = StringBuffer();
        final code = await runTermuiPlayCli(
          const [],
          out: out,
          err: err,
          fs: MemoryFileSystem(),
        );
        expect(code, 64);
        expect(out.toString(), isEmpty);
        expect(err.toString(), contains('Missing input .cast file path'));
      },
    );

    test('exits with 64 and writes to stderr on unknown option', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await runTermuiPlayCli(
        const ['--unknown-flag'],
        out: out,
        err: err,
        fs: MemoryFileSystem(),
      );
      expect(code, 64);
      expect(out.toString(), isEmpty);
      expect(err.toString(), contains('Error parsing arguments'));
    });

    test('exits with 64 and writes to stderr on invalid --speed', () async {
      for (final badSpeed in ['abc', '0', '-1.5', 'NaN', 'Infinity']) {
        final out = StringBuffer();
        final err = StringBuffer();
        final code = await runTermuiPlayCli(
          ['--speed', badSpeed, 'demo.cast'],
          out: out,
          err: err,
          fs: MemoryFileSystem(),
        );
        expect(code, 64, reason: 'Failed for speed=$badSpeed');
        expect(out.toString(), isEmpty);
        expect(err.toString(), contains('Invalid --speed'));
      }
    });

    test('exits with 66 and writes to stderr when file is missing', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await runTermuiPlayCli(
        const ['non_existent_recording_12345.cast'],
        out: out,
        err: err,
        fs: MemoryFileSystem(),
      );
      expect(code, 66);
      expect(out.toString(), isEmpty);
      expect(err.toString(), contains('File does not exist'));
    });

    test('exits with 0 and writes usage to stdout on --help', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await runTermuiPlayCli(
        const ['--help'],
        out: out,
        err: err,
        fs: MemoryFileSystem(),
      );
      expect(code, 0);
      expect(err.toString(), isEmpty);
      expect(out.toString(), contains('Usage: dart run termui_recorder'));
    });

    test(
      'process entrypoint propagates exitCode and stderr to OS process',
      () async {
        final result = await Process.run(Platform.resolvedExecutable, [
          'bin/termui_play.dart',
          '--speed',
          '0',
          'demo.cast',
        ]);
        expect(result.exitCode, 64);
        expect(result.stderr.toString(), contains('Invalid --speed'));
      },
    );
  });
}
