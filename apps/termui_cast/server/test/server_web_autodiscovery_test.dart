import 'dart:io';

import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:termui_cast_server/termui_cast_server.dart';
import 'package:test/test.dart';

void main() {
  group('ServerConfig executable-adjacent web root auto-discovery (#423)', () {
    test(
      'auto-discovers ../web next to bin/termui_cast_server and ./web next to flat binary',
      () {
        final sandbox = Directory.systemTemp.createTempSync(
          'cast_srv_web_auto_',
        );
        addTearDown(() => sandbox.deleteSync(recursive: true));

        final bundleDir = Directory(p.join(sandbox.path, 'bundle'))
          ..createSync();
        final binDir = Directory(p.join(bundleDir.path, 'bin'))..createSync();
        final webDir = Directory(p.join(bundleDir.path, 'web'))..createSync();
        File(
          p.join(webDir.path, 'index.html.gz'),
        ).writeAsBytesSync(gzip.encode(const [60, 104, 116, 109, 108, 62]));

        final serverExe = p.join(binDir.path, 'termui_cast_server');
        final unrelatedCwd = Directory(p.join(sandbox.path, 'unrelated'))
          ..createSync();

        final fromBundle = ServerConfig.fromArgs(
          const [],
          environment: const {},
          currentDirectory: unrelatedCwd,
          resolvedExecutable: serverExe,
        )!;
        check(
          p.normalize(fromBundle.webRoot!),
        ).equals(p.normalize(webDir.path));

        // Flat layout: <dir>/termui_cast_server + <dir>/web/index.html.
        final flatDir = Directory(p.join(sandbox.path, 'flat'))..createSync();
        final flatWebDir = Directory(p.join(flatDir.path, 'web'))..createSync();
        File(
          p.join(flatWebDir.path, 'index.html'),
        ).writeAsStringSync('<!doctype html><html></html>');

        final fromFlat = ServerConfig.fromArgs(
          const [],
          environment: const {},
          currentDirectory: unrelatedCwd,
          resolvedExecutable: p.join(flatDir.path, 'termui_cast_server'),
        )!;
        check(
          p.normalize(fromFlat.webRoot!),
        ).equals(p.normalize(flatWebDir.path));

        // Explicit --no-web and --web-dir override executable-adjacent web/.
        final disabled = ServerConfig.fromArgs(
          const ['--no-web'],
          environment: const {},
          currentDirectory: unrelatedCwd,
          resolvedExecutable: serverExe,
        )!;
        check(disabled.webRoot).isNull();

        final customWeb = Directory(p.join(sandbox.path, 'custom_web'))
          ..createSync();
        File(
          p.join(customWeb.path, 'index.html'),
        ).writeAsStringSync('<!doctype html><html></html>');
        final overridden = ServerConfig.fromArgs(
          ['--web-dir=${customWeb.path}'],
          environment: const {},
          currentDirectory: unrelatedCwd,
          resolvedExecutable: serverExe,
        )!;
        check(
          p.normalize(overridden.webRoot!),
        ).equals(p.normalize(customWeb.path));
      },
    );

    test(
      'ignores executable-adjacent web/ when running under Dart/Flutter runtime binaries',
      () {
        final sandbox = Directory.systemTemp.createTempSync(
          'cast_srv_dart_rt_',
        );
        addTearDown(() => sandbox.deleteSync(recursive: true));

        final sdkBin = Directory(p.join(sandbox.path, 'bin'))..createSync();
        final sdkWeb = Directory(p.join(sandbox.path, 'web'))..createSync();
        File(
          p.join(sdkWeb.path, 'index.html'),
        ).writeAsStringSync('<!doctype html><html></html>');

        final unrelatedCwd = Directory(p.join(sandbox.path, 'cwd'))
          ..createSync();

        for (final runtimeName in const [
          'dart',
          'dart.exe',
          'dartaotruntime',
          'dartaotruntime.exe',
          'flutter_tester',
          'flutter_tester.exe',
        ]) {
          final cfg = ServerConfig.fromArgs(
            const [],
            environment: const {},
            currentDirectory: unrelatedCwd,
            resolvedExecutable: p.join(sdkBin.path, runtimeName),
          )!;
          check(cfg.webRoot, because: runtimeName).isNull();
        }

        // Empty or whitespace-only resolvedExecutable skips executable-adjacent probing.
        for (final blank in const ['', '   ']) {
          final cfg = ServerConfig.fromArgs(
            const [],
            environment: const {},
            currentDirectory: unrelatedCwd,
            resolvedExecutable: blank,
          )!;
          check(cfg.webRoot, because: 'blank:"$blank"').isNull();
        }
      },
    );
  });
}
