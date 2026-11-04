import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:pty2/pty2.dart';
import 'package:pty2/src/impl/conpty_bundle.dart';
import 'package:pty2/src/impl/windows.dart' if (dart.library.html) '';
import 'package:test/test.dart';

typedef _ZipSpec = ({
  String name,
  Uint8List data,
  int method,
  int flags,
  int? fakeSize,
});

_ZipSpec _entry(
  String name,
  List<int> data, {
  int method = 0,
  int flags = 0,
  int? fakeSize,
}) => (
  name: name,
  data: data is Uint8List ? data : Uint8List.fromList(data),
  method: method,
  flags: flags,
  fakeSize: fakeSize,
);

Matcher _throwsFormat(String fragment) => throwsA(
  isA<FormatException>().having((e) => e.message, 'msg', contains(fragment)),
);

Uint8List _buildZipArchive(List<_ZipSpec> entries) {
  final out = BytesBuilder(copy: false);
  final rawZlib = ZLibCodec(raw: true);
  for (final e in entries) {
    final nameBytes = utf8.encode(e.name);
    final compressed = switch (e.method) {
      8 => Uint8List.fromList(rawZlib.encode(e.data)),
      _ => e.data,
    };
    final header = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, e.flags, Endian.little)
      ..setUint16(8, e.method, Endian.little)
      ..setUint32(18, compressed.length, Endian.little)
      ..setUint32(22, e.fakeSize ?? e.data.length, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little)
      ..setUint16(28, 0, Endian.little);
    out
      ..add(header.buffer.asUint8List())
      ..add(nameBytes)
      ..add(compressed);
  }
  final centralSig = ByteData(4)..setUint32(0, 0x02014b50, Endian.little);
  out.add(centralSig.buffer.asUint8List());
  return out.takeBytes();
}

void main() {
  group('ConPtyBundle.sha256Hex', () {
    test('computes lowercase hex SHA-256 digest via package:crypto', () {
      expect(
        ConPtyBundle.sha256Hex(utf8.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });
  });

  group('ConPtyBundle.extractZipEntries', () {
    test('extracts stored, raw-DEFLATE, and rejects malformed headers', () {
      final dllPayload = Uint8List.fromList(
        List<int>.generate(256, (i) => i & 0xff),
      );
      final exePayload = utf8.encode('OpenConsole-binary-payload-' * 20);
      final zip = _buildZipArchive([
        _entry(r'runtimes\win-x64\native\conpty.dll', dllPayload, method: 8),
        _entry('unused/readme.txt', utf8.encode('skip me')),
        _entry('build/native/runtimes/x64/OpenConsole.exe', exePayload),
      ]);
      final extracted = ConPtyBundle.extractZipEntries(zip, {
        'runtimes/win-x64/native/conpty.dll',
        'build/native/runtimes/x64/OpenConsole.exe',
      });
      expect(extracted['runtimes/win-x64/native/conpty.dll'], dllPayload);
      expect(
        extracted['build/native/runtimes/x64/OpenConsole.exe'],
        exePayload,
      );

      for (final (spec, msg) in [
        (_entry('a.bin', [1, 2], flags: 0x0008), 'bit 3'),
        (_entry('a.bin', [1, 2], method: 99), 'compression method 99'),
        (_entry('a.bin', [1, 2], fakeSize: 999), 'Uncompressed size mismatch'),
      ]) {
        expect(
          () => ConPtyBundle.extractZipEntries(_buildZipArchive([spec]), {
            'a.bin',
          }),
          _throwsFormat(msg),
        );
      }
      final valid = _buildZipArchive([
        _entry('a.bin', [1, 2, 3]),
      ]);
      expect(
        () => ConPtyBundle.extractZipEntries(
          Uint8List.sublistView(valid, 0, valid.length - 5),
          {'a.bin'},
        ),
        _throwsFormat('Truncated ZIP entry payload'),
      );
    });
  });

  group('ConPtyBundle side-by-side & verified cache resolution', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('pty2_conpty_test_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('requires non-empty conpty.dll and OpenConsole.exe side-by-side', () {
      final dir = Directory(p.join(tempRoot.path, 'pair'))..createSync();
      final dllFile = File(p.join(dir.path, 'conpty.dll'))
        ..writeAsBytesSync([1, 2, 3, 4]);

      // Missing OpenConsole.exe must be rejected so conpty.dll never silently
      // falls back to C:\Windows\System32\conhost.exe.
      expect(ConPtyBundle.hasValidPair(dir), isFalse);
      expect(
        ConPtyBundle.resolveConPtyDllPath(
          arch: .x64,
          environment: {'PTY2_CONPTY_DIR': dir.path},
          resolvedExecutablePath: p.join(tempRoot.path, 'none', 'dart'),
        ),
        isNull,
      );

      // Empty OpenConsole.exe must also be rejected.
      final exeFile = File(p.join(dir.path, 'OpenConsole.exe'))
        ..writeAsBytesSync(const []);
      expect(ConPtyBundle.hasValidPair(dir), isFalse);

      exeFile.writeAsBytesSync([5, 6, 7, 8]);
      expect(ConPtyBundle.hasValidPair(dir), isTrue);
      expect(
        ConPtyBundle.resolveConPtyDllPath(
          arch: .x64,
          environment: {'PTY2_CONPTY_DIR': dir.path},
          resolvedExecutablePath: p.join(tempRoot.path, 'none', 'dart'),
        ),
        dllFile.path,
      );

      // Verification against ConPtyArchSpec rejects dummy non-matching files.
      expect(
        ConPtyBundle.hasValidPair(
          dir,
          verifySpec: ConPtyBundle.specs[ConPtyArch.x64],
        ),
        isFalse,
      );
    });

    test(
      'resolves executable-adjacent directory and PTY2_CONPTY_DIR precedence',
      () {
        final exeDir = Directory(p.join(tempRoot.path, 'bin'))..createSync();
        File(p.join(exeDir.path, 'conpty.dll')).writeAsBytesSync([1, 2]);
        File(p.join(exeDir.path, 'OpenConsole.exe')).writeAsBytesSync([3, 4]);

        expect(
          ConPtyBundle.resolveConPtyDllPath(
            arch: .x64,
            environment: const {},
            resolvedExecutablePath: p.join(exeDir.path, 'termui_cast.exe'),
          ),
          p.join(exeDir.path, 'conpty.dll'),
        );

        final overrideDir = Directory(p.join(tempRoot.path, 'override'))
          ..createSync();
        File(p.join(overrideDir.path, 'conpty.dll')).writeAsBytesSync([9, 10]);
        File(
          p.join(overrideDir.path, 'OpenConsole.exe'),
        ).writeAsBytesSync([11, 12]);

        expect(
          ConPtyBundle.resolveConPtyDllPath(
            arch: .x64,
            environment: {'PTY2_CONPTY_DIR': overrideDir.path},
            resolvedExecutablePath: p.join(exeDir.path, 'termui_cast.exe'),
          ),
          p.join(overrideDir.path, 'conpty.dll'),
        );
      },
    );

    test(
      'resolves verified per-user cache and rejects size or SHA-256 mismatches',
      () async {
        expect(
          ConPtyBundle.defaultCacheDirectory(arch: .x64, environment: const {}),
          isNull,
        );

        final profileEnv = {'USERPROFILE': p.join(tempRoot.path, 'profile')};
        final profileCache = ConPtyBundle.defaultCacheDirectory(
          arch: .arm64,
          environment: profileEnv,
        );
        expect(
          profileCache?.path,
          p.join(
            tempRoot.path,
            'profile',
            'AppData',
            'Local',
            'pty2',
            'conpty',
            ConPtyBundle.version,
            'arm64',
          ),
        );

        final dllBytes = utf8.encode('verified-conpty-dll-x64');
        final exeBytes = utf8.encode('verified-OpenConsole-exe-x64');
        final customSpec = ConPtyArchSpec(
          arch: .x64,
          dllEntryPath: 'runtimes/win-x64/native/conpty.dll',
          dllSha256: ConPtyBundle.sha256Hex(dllBytes),
          dllSize: dllBytes.length,
          exeEntryPath: 'build/native/runtimes/x64/OpenConsole.exe',
          exeSha256: ConPtyBundle.sha256Hex(exeBytes),
          exeSize: exeBytes.length,
        );
        final customSpecs = <ConPtyArch, ConPtyArchSpec>{.x64: customSpec};
        final env = {'LOCALAPPDATA': p.join(tempRoot.path, 'localappdata')};
        final cacheDir = ConPtyBundle.defaultCacheDirectory(
          arch: .x64,
          environment: env,
        )!..createSync(recursive: true);

        final dllFile = File(p.join(cacheDir.path, 'conpty.dll'))
          ..writeAsBytesSync(dllBytes);
        final exeFile = File(p.join(cacheDir.path, 'OpenConsole.exe'))
          ..writeAsBytesSync(exeBytes);

        expect(
          ConPtyBundle.resolveConPtyDllPath(
            arch: .x64,
            environment: env,
            resolvedExecutablePath: p.join(tempRoot.path, 'none', 'app.exe'),
            customSpecs: customSpecs,
          ),
          dllFile.path,
        );

        // Same-length corrupted OpenConsole.exe is rejected by SHA-256 check.
        exeFile.writeAsBytesSync(utf8.encode('tampered-OpenConsole-exe-x64'));
        expect(
          ConPtyBundle.resolveConPtyDllPath(
            arch: .x64,
            environment: env,
            resolvedExecutablePath: p.join(tempRoot.path, 'none', 'app.exe'),
            customSpecs: customSpecs,
          ),
          isNull,
        );

        // Explicit installConPty / installFromNupkgFile heals corrupt cache.
        final nupkg = _buildZipArchive([
          _entry('runtimes/win-x64/native/conpty.dll', dllBytes, method: 8),
          _entry(
            'build/native/runtimes/x64/OpenConsole.exe',
            exeBytes,
            method: 8,
          ),
        ]);
        final nupkgFile = File(p.join(tempRoot.path, 'conpty.nupkg'))
          ..writeAsBytesSync(nupkg);
        await expectLater(
          () => PseudoTerminal.installConPty(nupkgFile, environment: env),
          _throwsFormat('ConPTY NuGet SHA-256 mismatch'),
        );
        expect(
          await ConPtyBundle.installFromNupkgFile(
            nupkgFile,
            arch: .x64,
            environment: env,
            expectedNupkgSha256: ConPtyBundle.sha256Hex(nupkg),
            customSpecs: customSpecs,
          ),
          dllFile.path,
        );
        expect(
          ConPtyBundle.resolveConPtyDllPath(
            arch: .x64,
            environment: env,
            resolvedExecutablePath: p.join(tempRoot.path, 'none', 'app.exe'),
            customSpecs: customSpecs,
          ),
          dllFile.path,
        );
      },
    );

    test(
      'ensureReady downloads and verifies via loopback HttpServer and enforces maxBytes',
      () async {
        final dllBytes = utf8.encode('http-conpty-dll-x64');
        final exeBytes = utf8.encode('http-OpenConsole-exe-x64');
        final nupkgBytes = _buildZipArchive([
          _entry('runtimes/win-x64/native/conpty.dll', dllBytes, method: 8),
          _entry(
            'build/native/runtimes/x64/OpenConsole.exe',
            exeBytes,
            method: 8,
          ),
        ]);
        final nupkgSha = ConPtyBundle.sha256Hex(nupkgBytes);
        final customSpecs = <ConPtyArch, ConPtyArchSpec>{
          .x64: ConPtyArchSpec(
            arch: .x64,
            dllEntryPath: 'runtimes/win-x64/native/conpty.dll',
            dllSha256: ConPtyBundle.sha256Hex(dllBytes),
            dllSize: dllBytes.length,
            exeEntryPath: 'build/native/runtimes/x64/OpenConsole.exe',
            exeSha256: ConPtyBundle.sha256Hex(exeBytes),
            exeSize: exeBytes.length,
          ),
        };

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          if (request.uri.path == '/valid.nupkg') {
            request.response
              ..statusCode = HttpStatus.ok
              ..contentLength = nupkgBytes.length
              ..add(nupkgBytes);
          } else {
            request.response.statusCode = HttpStatus.notFound;
          }
          await request.response.close();
        });

        final baseUri = Uri.parse('http://127.0.0.1:${server.port}');
        final env = {'LOCALAPPDATA': p.join(tempRoot.path, 'http_appdata')};
        final noneExe = p.join(tempRoot.path, 'none', 'app.exe');

        // Default download: false does not hit network.
        expect(
          await ConPtyBundle.ensureReady(
            arch: .x64,
            environment: env,
            resolvedExecutablePath: noneExe,
            downloadUri: baseUri.resolve('/valid.nupkg'),
            expectedNupkgSha256: nupkgSha,
            customSpecs: customSpecs,
          ),
          isNull,
        );

        // Exceeding maxBytes reports warning and returns null.
        final warnings = <String>[];
        expect(
          await ConPtyBundle.ensureReady(
            arch: .x64,
            environment: env,
            resolvedExecutablePath: noneExe,
            download: true,
            downloadUri: baseUri.resolve('/valid.nupkg'),
            expectedNupkgSha256: nupkgSha,
            customSpecs: customSpecs,
            maxBytes: 10,
            onWarning: warnings.add,
          ),
          isNull,
        );
        expect(warnings.single, contains('exceeds 10 bytes'));

        // HTTP 404 reports warning and returns null.
        warnings.clear();
        expect(
          await ConPtyBundle.ensureReady(
            arch: .x64,
            environment: env,
            resolvedExecutablePath: noneExe,
            download: true,
            downloadUri: baseUri.resolve('/missing.nupkg'),
            expectedNupkgSha256: nupkgSha,
            customSpecs: customSpecs,
            onWarning: warnings.add,
          ),
          isNull,
        );
        expect(warnings.single, contains('HTTP 404'));

        // Valid download stages and verifies both binaries.
        final resolved = await ConPtyBundle.ensureReady(
          arch: .x64,
          environment: env,
          resolvedExecutablePath: noneExe,
          download: true,
          downloadUri: baseUri.resolve('/valid.nupkg'),
          expectedNupkgSha256: nupkgSha,
          customSpecs: customSpecs,
        );
        final cacheDir = ConPtyBundle.defaultCacheDirectory(
          arch: .x64,
          environment: env,
        )!;
        expect(resolved, p.join(cacheDir.path, 'conpty.dll'));
        if (!Platform.isWindows) {
          expect(await PseudoTerminal.ensureConPtyReady(), isNull);
        }
      },
    );
  });

  test(
    'Windows OpenConsole passthrough preserves SGR 58;2;R;G;B sequence',
    testOn: 'windows',
    () async {
      final tempDir = Directory.systemTemp.createTempSync('pty2_sgr58_');
      addTearDown(() {
        try {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        } on FileSystemException {
          // Ignore transient Windows file lock during teardown.
        }
      });

      final scriptFile = File(p.join(tempDir.path, 'emit_sgr58.dart'))
        ..writeAsStringSync(r'''
import 'dart:io';

void main() {
  stdout.write('START_SGR58\x1b[4;38;2;92;124;232;58;2;92;124;232mJ\x1b[0mEND_SGR58\n');
}
''');

      final pty = PseudoTerminal.start(Platform.executable, [scriptFile.path]);
      addTearDown(() => pty.kill(ProcessSignal.sigkill));

      final fullOutput = await pty.out.join().timeout(
        const Duration(seconds: 15),
      );
      await pty.exitCode.timeout(const Duration(seconds: 5));

      expect(fullOutput, contains('START_SGR58'));
      expect(fullOutput, contains('END_SGR58'));
      if (PtyCoreWindows.isUsingBundledConPty) {
        expect(fullOutput, contains('58;2;92;124;232'));
        expect(fullOutput, isNot(contains('\x1b[92m')));
      }
    },
  );
}
