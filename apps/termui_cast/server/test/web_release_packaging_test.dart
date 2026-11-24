import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:termui_cast_server/src/static_web_handler.dart';
import 'package:termui_cast_server/termui_cast_server.dart';
import 'package:test/test.dart';

String _findRepoRoot() {
  var dir = Directory.current.absolute;
  while (true) {
    final workflow = File(
      p.join(dir.path, '.github', 'workflows', 'release-fterm.yml'),
    );
    if (workflow.existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError(
        'Unable to locate repository root from ${Directory.current.path}',
      );
    }
    dir = parent;
  }
}

bool _hasCommand(String executable, List<String> probeArgs) {
  try {
    final result = Process.runSync(executable, probeArgs);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void main() {
  final repoRoot = _findRepoRoot();
  final workflowFile = File(
    p.join(repoRoot, '.github', 'workflows', 'release-fterm.yml'),
  );
  final packageScript = File(p.join(repoRoot, 'utils', 'package_fterm_web.sh'));
  final setupDocFile = File(
    p.join(repoRoot, 'apps', 'termui_cast', 'docs', 'setup.md'),
  );

  group('fterm-web WASM release pipeline (#423)', () {
    test(
      'release-fterm.yml builds gzip-only fterm-web once and splits termui_cast_server (+web) from termui_cast',
      () {
        final yaml = workflowFile.readAsStringSync();

        // Dedicated single build-web job.
        check(yaml).contains('build-web:');
        check(yaml).contains('flutter build web --wasm --no-web-resources-cdn');
        check(yaml).contains('--build-name=');
        check(yaml).contains('FTERM_BUILD_DATE=');
        check(yaml).contains('utils/package_fterm_web.sh');
        check(yaml).contains('dist/fterm-web.tar.gz');
        check(yaml).contains('name: fterm-web');

        // Build matrix depends on build-web and keeps caster CLI separate from server+web.
        check(yaml).contains('needs: [preflight, build-web]');
        check(yaml).contains('dist/termui_cast-\${TARGET}.tar.gz" bin lib');
        check(
          yaml,
        ).contains('tar -xzf dist/fterm-web.tar.gz -C build/server/bundle');
        check(
          yaml,
        ).contains('dist/termui_cast_server-\${TARGET}.tar.gz" bin web');
        check(yaml).contains("grep -Fqx 'web/index.html.gz'");
        check(yaml).contains("grep -Fqx 'web/main.dart.wasm.gz'");
        check(
          yaml,
        ).contains('tar.exe -xzf dist/fterm-web.tar.gz -C build/server/bundle');
        check(yaml).contains('dist/termui_cast_server-\$(\$env:TARGET).zip');
        check(yaml).contains('"web/index.html.gz"');
        check(yaml).contains('"web/main.dart.wasm.gz"');
        check(yaml).contains('name: termui_cast_server-\${{ matrix.target }}');
        check(yaml).contains('needs: [preflight, build-web, build]');
      },
    );

    test(
      'setup.md documents prebuilt termui_cast_server bundled gzip-only web/ and fterm-web.tar.gz',
      () {
        final doc = setupDocFile.readAsStringSync();

        check(doc).contains('termui_cast_server-<os>-<arch>');
        check(doc).contains('fterm-web.tar.gz');
        check(doc).contains('gzip');
      },
    );

    test(
      'package_fterm_web.sh extension list matches StaticWebHandler.compressibleExtensions',
      () {
        final script = packageScript.readAsStringSync();
        final compressSection = script.split('gzip -9 -n -f').last;
        final matches = RegExp(
          r"-iname '\*(\.[a-z0-9]+)'",
        ).allMatches(compressSection);
        final scriptExtensions = {for (final m in matches) m.group(1)!};
        check(
          scriptExtensions,
        ).deepEquals(StaticWebHandler.compressibleExtensions);
      },
    );

    test(
      'package_fterm_web.sh produces gzip-only web/ tar.gz served over gzip, plain, SPA, and --base-path by CastServer',
      () async {
        check(packageScript.existsSync()).isTrue();
        if (Platform.isWindows) return;
        if (!_hasCommand('gzip', const ['--version']) ||
            !_hasCommand('tar', const ['--version'])) {
          return;
        }

        // --help exits 0 and prints usage to stdout.
        final helpResult = await Process.run('bash', [
          packageScript.path,
          '--help',
        ]);
        check(helpResult.exitCode).equals(0);
        check(helpResult.stdout as String).contains('Usage:');

        final sandbox = await Directory.systemTemp.createTemp(
          'fterm_web_pkg_test_',
        );
        addTearDown(() => sandbox.delete(recursive: true));

        final buildDir = await Directory(
          p.join(sandbox.path, 'build_web'),
        ).create(recursive: true);
        final fontsDir = await Directory(
          p.join(buildDir.path, 'assets', 'fonts'),
        ).create(recursive: true);

        final compressibleFixtures = <String, List<int>>{
          'index.html': utf8.encode(
            '<!doctype html><html><head><base href="/"></head><body>fterm</body></html>',
          ),
          'flutter_bootstrap.js': utf8.encode(
            'window._flutter={"useLocalCanvasKit":true};',
          ),
          'main.dart.wasm': Uint8List.fromList([
            0x00,
            0x61,
            0x73,
            0x6d,
            0x01,
            0x00,
            0x00,
            0x00,
            for (var i = 0; i < 1024; i++) i % 23,
          ]),
          p.join('canvaskit', 'skwasm.wasm'): const [
            0x00,
            0x61,
            0x73,
            0x6d,
            0x01,
            0x00,
            0x00,
            0x00,
          ],
          'main.dart.mjs': utf8.encode('export const instantiated = true;\n'),
          'audio_unlock.js': utf8.encode('window.__unlock = () => {};\n'),
          'style.css': utf8.encode('body { background: #14171F; }\n'),
          'favicon.svg': utf8.encode(
            '<svg xmlns="http://www.w3.org/2000/svg"/>',
          ),
          'Icon.SVG': utf8.encode('<svg xmlns="http://www.w3.org/2000/svg"/>'),
          'manifest.json': utf8.encode('{"name":"fterm"}\n'),
          p.join('assets', 'fonts', 'Test.ttf'): Uint8List.fromList([
            for (var i = 0; i < 1024; i++) (i * 7) % 31,
          ]),
          p.join('assets', 'fonts', 'Test.otf'): Uint8List.fromList([
            for (var i = 0; i < 512; i++) (i * 11) % 29,
          ]),
        };

        final rawOnlyFixtures = <String, List<int>>{
          'favicon.png': const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
          p.join('assets', 'fonts', 'Test.woff2'): const [
            0x77,
            0x4F,
            0x46,
            0x32,
            1,
            2,
            3,
            4,
          ],
        };

        final strippedDebugFixtures = <String, List<int>>{
          p.join('canvaskit', 'skwasm.js.symbols'): utf8.encode(
            '0:debug_symbol_entry\n',
          ),
          'flutter.js.map': utf8.encode('{"version":3,"sources":[]}\n'),
        };

        for (final entry in compressibleFixtures.entries) {
          final target = File(p.join(buildDir.path, entry.key));
          await target.parent.create(recursive: true);
          await target.writeAsBytes(entry.value);
        }
        for (final entry in rawOnlyFixtures.entries) {
          final target = File(p.join(buildDir.path, entry.key));
          await target.parent.create(recursive: true);
          await target.writeAsBytes(entry.value);
        }
        for (final entry in strippedDebugFixtures.entries) {
          final target = File(p.join(buildDir.path, entry.key));
          await target.parent.create(recursive: true);
          await target.writeAsBytes(entry.value);
        }
        check(fontsDir.existsSync()).isTrue();

        final outArchive = p.join(sandbox.path, 'fterm-web.tar.gz');
        final pkgResult = await Process.run('bash', [
          packageScript.path,
          buildDir.path,
          outArchive,
        ]);
        check(
          pkgResult.exitCode,
          because: 'stderr: ${pkgResult.stderr}',
        ).equals(0);
        check(File(outArchive).existsSync()).isTrue();

        // Source build directory must not be mutated.
        check(
          File(p.join(buildDir.path, 'main.dart.wasm')).existsSync(),
        ).isTrue();
        check(
          File(p.join(buildDir.path, 'main.dart.wasm.gz')).existsSync(),
        ).isFalse();

        // Archive must be rooted under web/ (no flat tarbomb).
        final listResult = await Process.run('tar', ['-tzf', outArchive]);
        check(listResult.exitCode).equals(0);
        final entries = (listResult.stdout as String)
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .toList();
        check(entries).isNotEmpty();
        for (final entry in entries) {
          check(
            entry == 'web' || entry.startsWith('web/'),
            because: 'unexpected archive entry: $entry',
          ).isTrue();
        }

        // Extract into a bundle directory and verify gzip-only compressible assets (no uncompressed duplicates or .br).
        final extractDir = await Directory(
          p.join(sandbox.path, 'bundle'),
        ).create();
        final extractResult = await Process.run('tar', [
          '-xzf',
          outArchive,
          '-C',
          extractDir.path,
        ]);
        check(extractResult.exitCode).equals(0);

        final webDir = Directory(p.join(extractDir.path, 'web'));
        check(webDir.existsSync()).isTrue();

        for (final entry in compressibleFixtures.entries) {
          final rawFile = File(p.join(webDir.path, entry.key));
          final gzFile = File('${rawFile.path}.gz');
          final brFile = File('${rawFile.path}.br');
          check(rawFile.existsSync(), because: rawFile.path).isFalse();
          check(brFile.existsSync(), because: brFile.path).isFalse();
          check(gzFile.existsSync(), because: gzFile.path).isTrue();
          check(await gzFile.length()).isGreaterThan(0);
          check(
            gzip.decode(await gzFile.readAsBytes()),
          ).deepEquals(entry.value);
        }

        for (final entry in rawOnlyFixtures.entries) {
          final rawFile = File(p.join(webDir.path, entry.key));
          final gzFile = File('${rawFile.path}.gz');
          check(rawFile.existsSync(), because: rawFile.path).isTrue();
          check(gzFile.existsSync(), because: gzFile.path).isFalse();
        }

        for (final entry in strippedDebugFixtures.entries) {
          final staged = File(p.join(webDir.path, entry.key));
          check(staged.existsSync(), because: staged.path).isFalse();
          check(
            File(p.join(buildDir.path, entry.key)).existsSync(),
            because: 'source ${entry.key} preserved',
          ).isTrue();
        }

        // Serve extracted gzip-only web/ via CastServer.
        final server = await CastServer.bind(
          ServerConfig(port: 0, webRoot: webDir.path),
        );
        addTearDown(server.close);

        final client = HttpClient()..autoUncompress = false;
        addTearDown(() => client.close(force: true));

        Future<({int statusCode, HttpHeaders headers, List<int> body})> fetch(
          String urlPath, {
          String? acceptEncoding,
          String method = 'GET',
          int? port,
        }) async {
          final req = await client.openUrl(
            method,
            Uri.parse('http://127.0.0.1:${port ?? server.port}$urlPath'),
          );
          req.headers.removeAll(HttpHeaders.acceptEncodingHeader);
          if (acceptEncoding != null) {
            req.headers.set(HttpHeaders.acceptEncodingHeader, acceptEncoding);
          }
          final res = await req.close();
          final body = await res.fold<List<int>>(
            <int>[],
            (acc, chunk) => acc..addAll(chunk),
          );
          return (statusCode: res.statusCode, headers: res.headers, body: body);
        }

        // 1. Browser gzip request streams .gz directly with logical MIME + Cache-Control.
        for (final (urlPath, expectedMime, expectedCache, fixtureKey) in [
          ('/', 'text/html', 'no-cache', 'index.html'),
          ('/main.dart.wasm', 'application/wasm', 'no-cache', 'main.dart.wasm'),
          (
            '/assets/fonts/Test.ttf',
            'font/ttf',
            'public, max-age=3600',
            p.join('assets', 'fonts', 'Test.ttf'),
          ),
        ]) {
          final gzRes = await fetch(urlPath, acceptEncoding: 'gzip, deflate');
          check(gzRes.statusCode).equals(HttpStatus.ok);
          check(gzRes.headers.contentType?.mimeType).equals(expectedMime);
          check(
            gzRes.headers.value(HttpHeaders.cacheControlHeader),
          ).equals(expectedCache);
          check(
            gzRes.headers.value(HttpHeaders.contentEncodingHeader),
          ).equals('gzip');
          check(
            gzRes.headers.value(HttpHeaders.varyHeader),
          ).equals('Accept-Encoding');
          final diskGz = await File(
            '${p.join(webDir.path, fixtureKey)}.gz',
          ).readAsBytes();
          check(gzRes.body).deepEquals(diskGz);

          // 2. Client without Accept-Encoding (or gzip;q=0) transparently receives gunzipped raw bytes.
          final rawRes = await fetch(urlPath);
          check(rawRes.statusCode).equals(HttpStatus.ok);
          check(rawRes.headers.contentType?.mimeType).equals(expectedMime);
          check(
            rawRes.headers.value(HttpHeaders.contentEncodingHeader),
          ).isNull();
          check(
            rawRes.headers.value(HttpHeaders.varyHeader),
          ).equals('Accept-Encoding');
          check(rawRes.body).deepEquals(compressibleFixtures[fixtureKey]!);

          final headRaw = await fetch(urlPath, method: 'HEAD');
          check(headRaw.statusCode).equals(HttpStatus.ok);
          check(headRaw.body).isEmpty();
          check(
            headRaw.headers.contentLength,
          ).equals(compressibleFixtures[fixtureKey]!.length);
        }

        // 3. Extensionless SPA pass-through resolves index.html.gz.
        final spaRes = await fetch('/sessions/shell-1', acceptEncoding: 'gzip');
        check(spaRes.statusCode).equals(HttpStatus.ok);
        check(spaRes.headers.contentType?.mimeType).equals('text/html');
        check(
          gzip.decode(spaRes.body),
        ).deepEquals(compressibleFixtures['index.html']!);

        // 4. --base-path rewrites <base href="/"> on index.html.gz cleanly.
        final prefixedServer = await CastServer.bind(
          ServerConfig(port: 0, webRoot: webDir.path, basePath: '/term'),
        );
        addTearDown(prefixedServer.close);

        final prefixedGz = await fetch(
          '/term/',
          acceptEncoding: 'gzip',
          port: prefixedServer.port,
        );
        check(prefixedGz.statusCode).equals(HttpStatus.ok);
        check(
          prefixedGz.headers.value(HttpHeaders.contentEncodingHeader),
        ).equals('gzip');
        check(
          utf8.decode(gzip.decode(prefixedGz.body)),
        ).contains('<base href="/term/">');

        final prefixedRaw = await fetch('/term/', port: prefixedServer.port);
        check(prefixedRaw.statusCode).equals(HttpStatus.ok);
        check(
          prefixedRaw.headers.value(HttpHeaders.contentEncodingHeader),
        ).isNull();
        check(utf8.decode(prefixedRaw.body)).contains('<base href="/term/">');

        // 5. Already-compressed PNG asset serves raw without Vary/Content-Encoding.
        final pngRes = await fetch('/favicon.png', acceptEncoding: 'gzip');
        check(pngRes.statusCode).equals(HttpStatus.ok);
        check(pngRes.headers.value(HttpHeaders.contentEncodingHeader)).isNull();
        check(pngRes.headers.value(HttpHeaders.varyHeader)).isNull();
        check(pngRes.body).deepEquals(rawOnlyFixtures['favicon.png']!);

        // 6. Corrupt .gz-only asset returns 500 cleanly instead of hanging.
        await File(
          p.join(webDir.path, 'corrupt.wasm.gz'),
        ).writeAsBytes(const [0xDE, 0xAD, 0xBE, 0xEF]);
        final corruptRes = await fetch('/corrupt.wasm');
        check(corruptRes.statusCode).equals(HttpStatus.internalServerError);

        // 7. Symlink-escaped .gz-only asset returns 403 without leaking content.
        final outsideSecret = File(p.join(sandbox.path, 'secret.txt'))
          ..writeAsStringSync('TOP_SECRET');
        final escapedGz = Link(p.join(webDir.path, 'escape.wasm.gz'))
          ..createSync(outsideSecret.path);
        addTearDown(() {
          if (escapedGz.existsSync()) escapedGz.deleteSync();
        });
        final escapedRes = await fetch('/escape.wasm', acceptEncoding: 'gzip');
        check(escapedRes.statusCode).equals(HttpStatus.forbidden);
        check(
          utf8.decode(escapedRes.body, allowMalformed: true),
        ).not((it) => it.contains('TOP_SECRET'));

        // 8. Conditional 304 on gunzipped .gz-only asset uses cached raw ETag.
        final rawWasmRes = await fetch('/main.dart.wasm');
        final rawEtag = rawWasmRes.headers.value(HttpHeaders.etagHeader)!;
        final revalReq = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/main.dart.wasm'),
        );
        revalReq.headers
          ..removeAll(HttpHeaders.acceptEncodingHeader)
          ..set(HttpHeaders.ifNoneMatchHeader, rawEtag);
        final revalRes = await revalReq.close();
        await revalRes.drain<void>();
        check(revalRes.statusCode).equals(HttpStatus.notModified);

        // 9. Rejects builds produced without --no-web-resources-cdn or invalid output paths.
        final dirOutResult = await Process.run('bash', [
          packageScript.path,
          buildDir.path,
          sandbox.path,
        ]);
        check(dirOutResult.exitCode).equals(64);

        final cdnBuildDir = await Directory(
          p.join(sandbox.path, 'cdn_web'),
        ).create();
        await File(
          p.join(cdnBuildDir.path, 'index.html'),
        ).writeAsString('<!doctype html><html></html>');
        await File(
          p.join(cdnBuildDir.path, 'flutter_bootstrap.js'),
        ).writeAsString('window._flutter={"useLocalCanvasKit":false};');
        await File(
          p.join(cdnBuildDir.path, 'main.dart.wasm'),
        ).writeAsBytes(const [0x00, 0x61, 0x73, 0x6d]);

        final badResult = await Process.run('bash', [
          packageScript.path,
          cdnBuildDir.path,
          p.join(sandbox.path, 'should-fail.tar.gz'),
        ]);
        check(badResult.exitCode).not((it) => it.equals(0));
      },
    );
  });
}
