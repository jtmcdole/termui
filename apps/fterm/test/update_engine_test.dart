@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/desktop_launch_env.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/update/archive_validator_io.dart';
import 'package:fterm/src/update/manifest_utils.dart';
import 'package:fterm/src/update/portable_lock_io.dart';
import 'package:fterm/src/update/swapper_io.dart';
import 'package:fterm/src/update/update_repository_io.dart';
import 'package:fterm/src/update/update_service.dart';
import 'package:fterm/src/update/update_service_io.dart';
import 'package:fterm/src/update/update_service_stub.dart' as web_stub;
import 'package:fterm/src/update/update_view_model.dart';
import 'package:fterm/src/workspace/local_host_driver_io.dart';
import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_pty/termui_pty.dart';

void main() {
  _defineSemVerAndPubspecSyncTests();
  _definePreferencesAndCliHygieneTests();
  _defineParallelShutdownTests();
  _defineUpdateRepositoryTests();
  _defineArchiveValidatorTests();
  _definePortableLockAndSwapperTests();
  _defineUnixServiceAndEdgeCaseTests();
}

void _defineSemVerAndPubspecSyncTests() {
  group('FtermSemVer & pubspec.yaml sync', () {
    test('kFtermBuildVersion reflects pubspec.yaml via appBuildName', () {
      final pubspecFile = _locateFtermPubspec();
      final lines = pubspecFile.readAsLinesSync();
      String? pubspecVersion;
      for (final line in lines) {
        final match = RegExp(r'^version:\s*(\S+)').firstMatch(line);
        if (match != null) {
          pubspecVersion = match.group(1);
          break;
        }
      }
      expect(pubspecVersion, isNotNull);
      expect(kFtermBuildVersion, equals(pubspecVersion!.split('+').first));
      expect(FtermSemVer.tryParse(kFtermBuildVersion), isNotNull);
    });

    test('implements SemVer 2.0.0 pre-release and numeric precedence', () {
      final ordered = <String>[
        '0.2.2',
        '0.3.0-alpha',
        '0.3.0-alpha.1',
        '0.3.0-alpha.beta',
        '0.3.0-beta',
        '0.3.0-beta.2',
        '0.3.0-beta.11',
        '0.3.0-rc.1',
        '0.3.0',
        '0.3.1',
        '1.0.0',
      ].map(FtermSemVer.parse).toList();

      for (var i = 0; i < ordered.length - 1; i++) {
        expect(
          ordered[i] < ordered[i + 1],
          isTrue,
          reason: 'Expected ${ordered[i]} < ${ordered[i + 1]}',
        );
        expect(ordered[i + 1] > ordered[i], isTrue);
      }

      // Build metadata is ignored for version precedence and equality.
      final a = FtermSemVer.parse('0.3.0+20261116.1');
      final b = FtermSemVer.parse('0.3.0+sha.deadbeef');
      expect(a, equals(b));
      expect(a.compareTo(b), equals(0));
      expect(a.hashCode, equals(b.hashCode));

      expect(
        FtermSemVer.tryParseReleaseTag('refs/tags/fterm-v0.3.0-rc.2'),
        equals(FtermSemVer.parse('0.3.0-rc.2')),
      );
      expect(
        FtermSemVer.tryParseReleaseTag('refs/tags/termui-v0.18.0'),
        isNull,
      );
      expect(FtermSemVer.tryParse('01.2.3'), isNull);
      expect(FtermSemVer.tryParse('1.2'), isNull);
    });
  });
}

void _definePreferencesAndCliHygieneTests() {
  group('FtermPreferences update fields & CLI relaunch hygiene', () {
    test('round-trips update preferences and preserves legacy defaults', () {
      final legacy = FtermPreferences.fromJsonString('{"audioMuted":true}');
      expect(legacy.audioMuted, isTrue);
      expect(legacy.updateCheckMode, equals(UpdateCheckMode.manual));
      expect(legacy.includePrereleases, isFalse);
      expect(legacy.lastUpdateCheckUtc, isNull);
      expect(legacy.skippedUpdateVersion, isNull);
      expect(legacy.lastReleaseTagEtag, isNull);
      expect(legacy.cachedReleaseTags, isEmpty);

      final checkTime = DateTime.utc(2026, 11, 16, 4, 30);
      final populated = const FtermPreferences().copyWith(
        updateCheckMode: UpdateCheckMode.daily,
        includePrereleases: true,
        lastUpdateCheckUtc: checkTime,
        skippedUpdateVersion: '0.3.0',
        lastReleaseTagEtag: 'W/"etag-123"',
        cachedReleaseTags: ['fterm-v0.2.2', 'fterm-v0.3.0'],
      );
      final decoded = FtermPreferences.fromJsonString(populated.toJsonString());
      expect(decoded, equals(populated));
      expect(decoded.hashCode, equals(populated.hashCode));
      expect(decoded.updateCheckMode, equals(UpdateCheckMode.daily));
      expect(decoded.includePrereleases, isTrue);
      expect(decoded.lastUpdateCheckUtc, equals(checkTime));
      expect(decoded.skippedUpdateVersion, equals('0.3.0'));
      expect(decoded.lastReleaseTagEtag, equals('W/"etag-123"'));
      expect(
        decoded.cachedReleaseTags,
        equals(['fterm-v0.2.2', 'fterm-v0.3.0']),
      );

      final cleared = decoded.copyWith(
        clearLastUpdateCheckUtc: true,
        clearSkippedUpdateVersion: true,
        clearLastReleaseTagEtag: true,
        cachedReleaseTags: const [],
      );
      expect(cleared.lastUpdateCheckUtc, isNull);
      expect(cleared.skippedUpdateVersion, isNull);
      expect(cleared.lastReleaseTagEtag, isNull);
      expect(cleared.cachedReleaseTags, isEmpty);
    });

    test(
      'canonicalizes file flags to absolute paths and strips raw --token / --caster-token from relaunchArgs',
      () {
        final cfgWithRawSecrets = resolveCastLaunchConfig(
          baseUri: Uri.parse('file:///Users/dev/fterm/'),
          args: const [
            '-NSDocumentRevisionsDebugMode',
            'YES',
            '--url=wss://relay.example.com/v1/client',
            '--token=super-secret-viewer-token',
            '--caster-token',
            'super-secret-caster-token',
            '--iap-key-file=./creds/iap.json',
          ],
          environment: const {},
          canonicalizePath: (raw) => '/abs/work/${raw.replaceFirst('./', '')}',
          iapProviderBuilder:
              ({required serverUri, serviceAccount, keyFilePath}) =>
                  () async => 'iap-jwt:$keyFilePath',
          onCliSecretWarning: (_) {},
        );
        expect(
          cfgWithRawSecrets.relaunchArgs,
          equals([
            '--server',
            'wss://relay.example.com/v1/client',
            '--iap-key-file',
            '/abs/work/creds/iap.json',
          ]),
        );
        expect(
          cfgWithRawSecrets.relaunchArgs.join(' '),
          isNot(contains('super-secret')),
        );

        final cfgWithSecretFiles = resolveCastLaunchConfig(
          baseUri: Uri.parse('file:///Users/dev/fterm/'),
          args: const [
            '--server',
            'wss://relay.example.com/v1/client',
            '--token-file',
            'rel/viewer.tok',
            '--caster-token-file=rel/caster.tok',
            '--iap-service-account=viewer@proj.iam.gserviceaccount.com',
          ],
          environment: const {},
          canonicalizePath: (raw) => '/home/dev/$raw',
          secretFileReader: (path) => 'secret-from-$path',
          iapProviderBuilder:
              ({required serverUri, serviceAccount, keyFilePath}) =>
                  () async => 'jwt',
        );
        expect(
          cfgWithSecretFiles.token,
          equals('secret-from-/home/dev/rel/viewer.tok'),
        );
        expect(
          cfgWithSecretFiles.casterToken,
          equals('secret-from-/home/dev/rel/caster.tok'),
        );
        expect(
          cfgWithSecretFiles.relaunchArgs,
          equals([
            '--server',
            'wss://relay.example.com/v1/client',
            '--token-file',
            '/home/dev/rel/viewer.tok',
            '--caster-token-file',
            '/home/dev/rel/caster.tok',
            '--iap-service-account',
            'viewer@proj.iam.gserviceaccount.com',
          ]),
        );
      },
    );
  });
}

void _defineParallelShutdownTests() {
  group('IoLocalHostDriver parallel PTY kill vs hung stopShare()', () {
    test(
      'kills local PTY immediately even when relay WebSocket close hangs indefinitely',
      () async {
        late _FakeRoutedPtyBackend spawnedBackend;
        final driver = IoLocalHostDriver(
          isWindows: false,
          downloadConPty: false,
          backendFactory:
              ({
                required executable,
                required arguments,
                required initialCols,
                required initialRows,
                required pixelWidth,
                required pixelHeight,
                workingDirectory,
                environment,
              }) => spawnedBackend = _FakeRoutedPtyBackend(),
        );

        final host = await driver.openShell(const LocalShellConfig());
        final neverClosingSink = _HungCloseStreamChannel();

        unawaited(
          host
              .startShare(
                serverUri: Uri.parse('ws://127.0.0.1:9999/v1/caster'),
                casterToken: 'tok',
                title: 'hung-share',
                channelOpener: () async => neverClosingSink.channel,
              )
              .catchError((_) => const SessionId('ignored')),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Start host.dispose(); stopShare() will hang on sink.close(), yet
        // spawnedBackend.dispose() MUST run immediately in parallel!
        final disposeFuture = host.dispose();
        await spawnedBackend.disposedCompleter.future.timeout(
          const Duration(milliseconds: 250),
        );
        expect(spawnedBackend.disposed, isTrue);

        neverClosingSink.releaseClose();
        await disposeFuture;
        await driver.dispose();
      },
    );
  });
}

void _defineUpdateRepositoryTests() {
  group('IoUpdateRepository tag discovery, 304 ETag, immutable & arch rules', () {
    const validSha =
        '70db0123456789abcdef0123456789abcdef0123456789abcdef0123456789ab';

    Map<String, Object?> releaseJson({
      required String tag,
      bool draft = false,
      bool prerelease = false,
      bool immutable = true,
      List<Map<String, Object?>>? assets,
    }) => <String, Object?>{
      'tag_name': tag,
      'html_url': 'https://github.com/jtmcdole/termui/releases/tag/$tag',
      'body': '## Highlights\nFaster rendering and portable updates.',
      'draft': draft,
      'prerelease': prerelease,
      'immutable': immutable,
      'assets':
          assets ??
          <Map<String, Object?>>[
            <String, Object?>{
              'name': 'fterm-windows-x64.zip',
              'size': 1024,
              'digest': 'sha256:$validSha',
              'browser_download_url':
                  'https://objects.githubusercontent.com/$tag/win-x64.zip',
            },
            <String, Object?>{
              'name': 'fterm-macos-arm64.tar.gz',
              'size': 2048,
              'digest': 'sha256:$validSha',
              'browser_download_url':
                  'https://objects.githubusercontent.com/$tag/macos.tar.gz',
            },
            <String, Object?>{
              'name': 'fterm-linux-x64.tar.gz',
              'size': 1536,
              'digest': 'sha256:$validSha',
              'browser_download_url':
                  'https://objects.githubusercontent.com/$tag/linux-x64.tar.gz',
            },
          ],
    };

    test(
      'filters Melos tags, reuses cached tags on 304 across binary versions, and skips ETag cache on draft/404 tags',
      () async {
        final fakeHttp = _FakeUpdateHttpClient();
        fakeHttp.jsonRoutes['https://api.github.com/repos/jtmcdole/termui/git/matching-refs/tags/fterm-v'] =
            (headers) {
              if (headers[HttpHeaders.ifNoneMatchHeader] == 'W/"tags-v1"') {
                return const UpdateHttpResponse(
                  statusCode: HttpStatus.notModified,
                  body: '',
                  etag: 'W/"tags-v1"',
                );
              }
              return UpdateHttpResponse(
                statusCode: HttpStatus.ok,
                etag: 'W/"tags-v1"',
                body: jsonEncode([
                  {'ref': 'refs/tags/termui-v0.99.0'},
                  {'ref': 'refs/tags/fterm-v0.2.2'},
                  {'ref': 'refs/tags/fterm-v0.3.0'},
                  {'ref': 'refs/tags/fterm-v0.4.0-rc.1'},
                ]),
              );
            };
        fakeHttp.jsonRoutes['https://api.github.com/repos/jtmcdole/termui/releases/tags/fterm-v0.3.0'] =
            (_) => UpdateHttpResponse(
              statusCode: HttpStatus.ok,
              body: jsonEncode(releaseJson(tag: 'fterm-v0.3.0')),
            );
        fakeHttp.jsonRoutes['https://api.github.com/repos/jtmcdole/termui/releases/tags/fterm-v0.4.0-rc.1'] =
            (_) => UpdateHttpResponse(
              statusCode: HttpStatus.ok,
              body: jsonEncode(
                releaseJson(tag: 'fterm-v0.4.0-rc.1', prerelease: true),
              ),
            );

        final repo = IoUpdateRepository(
          httpClient: fakeHttp,
          targetPlatform: DesktopTargetPlatform.windowsX64,
        );

        // 1. Stable check from 0.2.2 finds 0.3.0 (ignoring 0.4.0-rc.1 and termui-v0.99.0).
        final first = await repo.checkForUpdates(
          currentVersion: FtermSemVer.parse('0.2.2'),
          includePrereleases: false,
        );
        expect(first.cacheTagState, isTrue);
        expect(first.tagEtag, equals('W/"tags-v1"'));
        expect(
          first.availableUpdate?.version,
          equals(FtermSemVer.parse('0.3.0')),
        );
        expect(
          first.availableUpdate?.asset?.name,
          equals('fterm-windows-x64.zip'),
        );

        // 2. Subsequent check from a 0.2.1 portable copy receiving HTTP 304 STILL discovers 0.3.0!
        final fromOlderCopyOn304 = await repo.checkForUpdates(
          currentVersion: FtermSemVer.parse('0.2.1'),
          includePrereleases: false,
          lastEtag: first.tagEtag,
          cachedTags: first.cachedTags,
        );
        expect(
          fromOlderCopyOn304.availableUpdate?.version,
          equals(FtermSemVer.parse('0.3.0')),
        );

        // 3. Opting into pre-releases on 304 discovers 0.4.0-rc.1.
        final prereleaseOn304 = await repo.checkForUpdates(
          currentVersion: FtermSemVer.parse('0.3.0'),
          includePrereleases: true,
          lastEtag: first.tagEtag,
          cachedTags: first.cachedTags,
        );
        expect(
          prereleaseOn304.availableUpdate?.version,
          equals(FtermSemVer.parse('0.4.0-rc.1')),
        );

        // 4. Draft or 404 top candidate falls back to 0.3.0 AND sets cacheTagState = false.
        fakeHttp.jsonRoutes['https://api.github.com/repos/jtmcdole/termui/git/matching-refs/tags/fterm-v'] =
            (_) => UpdateHttpResponse(
              statusCode: HttpStatus.ok,
              etag: 'W/"tags-v2"',
              body: jsonEncode([
                {'ref': 'refs/tags/fterm-v0.3.0'},
                {'ref': 'refs/tags/fterm-v0.3.1'},
                {'ref': 'refs/tags/fterm-v0.3.2'},
              ]),
            );
        fakeHttp.jsonRoutes['https://api.github.com/repos/jtmcdole/termui/releases/tags/fterm-v0.3.2'] =
            (_) => const UpdateHttpResponse(
              statusCode: HttpStatus.notFound,
              body: '{}',
            );
        fakeHttp.jsonRoutes['https://api.github.com/repos/jtmcdole/termui/releases/tags/fterm-v0.3.1'] =
            (_) => UpdateHttpResponse(
              statusCode: HttpStatus.ok,
              body: jsonEncode(releaseJson(tag: 'fterm-v0.3.1', draft: true)),
            );
        final fallback = await repo.checkForUpdates(
          currentVersion: FtermSemVer.parse('0.2.2'),
          includePrereleases: false,
        );
        expect(
          fallback.availableUpdate?.version,
          equals(FtermSemVer.parse('0.3.0')),
        );
        expect(fallback.cacheTagState, isFalse);
      },
    );

    test(
      'rejects mutable releases and bad sha256 digests; maps Windows ARM64 Prism fallback and linux-arm64',
      () async {
        // OS / Arch target detection including Windows ARM64 Prism emulation.
        expect(
          resolveHostTargetPlatform(abi: Abi.macosArm64, environment: const {}),
          equals(DesktopTargetPlatform.macosArm64),
        );
        expect(
          resolveHostTargetPlatform(abi: Abi.macosX64, environment: const {}),
          equals(DesktopTargetPlatform.unsupported),
        );
        expect(
          resolveHostTargetPlatform(
            abi: Abi.windowsX64,
            environment: const {'PROCESSOR_ARCHITEW6432': 'ARM64'},
          ),
          equals(DesktopTargetPlatform.windowsArm64),
        );
        expect(
          resolveHostTargetPlatform(abi: Abi.linuxArm64, environment: const {}),
          equals(DesktopTargetPlatform.linuxArm64),
        );

        final fakeHttp = _FakeUpdateHttpClient();
        fakeHttp.jsonRoutes['https://api.github.com/repos/jtmcdole/termui/git/matching-refs/tags/fterm-v'] =
            (_) => UpdateHttpResponse(
              statusCode: HttpStatus.ok,
              body: jsonEncode([
                {'ref': 'refs/tags/fterm-v0.3.0'},
              ]),
            );

        // Windows ARM64 falls back to fterm-windows-x64.zip when arm64 asset is absent,
        // and prefers fterm-windows-arm64.zip once published.
        fakeHttp.jsonRoutes['https://api.github.com/repos/jtmcdole/termui/releases/tags/fterm-v0.3.0'] =
            (_) => UpdateHttpResponse(
              statusCode: HttpStatus.ok,
              body: jsonEncode(releaseJson(tag: 'fterm-v0.3.0')),
            );
        final winArmRepo = IoUpdateRepository(
          httpClient: fakeHttp,
          targetPlatform: DesktopTargetPlatform.windowsArm64,
        );
        final prismFallback = await winArmRepo.checkForUpdates(
          currentVersion: FtermSemVer.parse('0.2.2'),
          includePrereleases: false,
        );
        expect(
          prismFallback.availableUpdate?.asset?.name,
          equals('fterm-windows-x64.zip'),
        );

        // linux-arm64 reports unavailable asset reason cleanly when CI hasn't shipped it yet.
        final linuxArmRepo = IoUpdateRepository(
          httpClient: fakeHttp,
          targetPlatform: DesktopTargetPlatform.linuxArm64,
        );
        final linuxArm = await linuxArmRepo.checkForUpdates(
          currentVersion: FtermSemVer.parse('0.2.2'),
          includePrereleases: false,
        );
        expect(linuxArm.availableUpdate, isNotNull);
        expect(linuxArm.availableUpdate!.asset, isNull);
        expect(
          linuxArm.availableUpdate!.unavailableAssetReason,
          contains('No prebuilt archive for linux-arm64'),
        );

        // Mutable release (immutable: false) is rejected.
        fakeHttp.jsonRoutes['https://api.github.com/repos/jtmcdole/termui/releases/tags/fterm-v0.3.0'] =
            (_) => UpdateHttpResponse(
              statusCode: HttpStatus.ok,
              body: jsonEncode(
                releaseJson(tag: 'fterm-v0.3.0', immutable: false),
              ),
            );
        await expectLater(
          winArmRepo.checkForUpdates(
            currentVersion: FtermSemVer.parse('0.2.2'),
            includePrereleases: false,
          ),
          throwsA(isA<UpdateException>()),
        );

        // Missing or malformed sha256 digest is rejected.
        fakeHttp.jsonRoutes['https://api.github.com/repos/jtmcdole/termui/releases/tags/fterm-v0.3.0'] =
            (_) => UpdateHttpResponse(
              statusCode: HttpStatus.ok,
              body: jsonEncode(
                releaseJson(
                  tag: 'fterm-v0.3.0',
                  assets: [
                    {
                      'name': 'fterm-windows-x64.zip',
                      'size': 1024,
                      'digest': 'sha256:not-hex',
                      'browser_download_url': 'https://example.com/a.zip',
                    },
                  ],
                ),
              ),
            );
        await expectLater(
          winArmRepo.checkForUpdates(
            currentVersion: FtermSemVer.parse('0.2.2'),
            includePrereleases: false,
          ),
          throwsA(isA<UpdateException>()),
        );
      },
    );
  });
}

void _defineArchiveValidatorTests() {
  group('SHA-256, pure-Dart .zip, and streaming .tar.gz validators', () {
    test('verifies SHA-256 & size and rejects tampered bytes', () async {
      final dir = await Directory.systemTemp.createTemp('fterm_sha_test_');
      addTearDown(() => dir.delete(recursive: true));

      final payload = utf8.encode('immutable-release-payload');
      final hex = sha256.convert(payload).toString();
      final file = File(p.join(dir.path, 'bundle.bin'))
        ..writeAsBytesSync(payload);

      await verifyFileSizeAndSha256(
        filePath: file.path,
        expectedSize: payload.length,
        expectedSha256Hex: hex,
      );

      await expectLater(
        verifyFileSizeAndSha256(
          filePath: file.path,
          expectedSize: payload.length + 1,
          expectedSha256Hex: hex,
        ),
        throwsA(isA<UpdateException>()),
      );
      await expectLater(
        verifyFileSizeAndSha256(
          filePath: file.path,
          expectedSize: payload.length,
          expectedSha256Hex: '0' * 64,
        ),
        throwsA(isA<UpdateException>()),
      );
    });

    test(
      'extracts valid Windows .zip and rejects traversal, symlinks, and decompression bombs',
      () async {
        final dir = await Directory.systemTemp.createTemp('fterm_zip_test_');
        addTearDown(() => dir.delete(recursive: true));

        final validArchive = Archive()
          ..addFile(ArchiveFile.string(r'fterm.exe', 'MZ-exe'))
          ..addFile(ArchiveFile.string(r'flutter_windows.dll', 'MZ-dll'))
          ..addFile(ArchiveFile.string(r'data\icudtl.dat', 'ICU-DATA'))
          ..addFile(
            ArchiveFile.string(
              kFtermManifestFileName,
              jsonEncode([
                '.fterm-files.json',
                'data',
                'flutter_windows.dll',
                'fterm.exe',
              ]),
            ),
          );
        final validZipPath = p.join(dir.path, 'valid.zip');
        File(validZipPath).writeAsBytesSync(ZipEncoder().encode(validArchive));

        final outDir = p.join(dir.path, 'extracted');
        Directory(outDir).createSync();
        final manifest = extractAndValidateWindowsZip(
          zipPath: validZipPath,
          outputDirPath: outDir,
        );
        expect(
          manifest,
          equals([
            '.fterm-files.json',
            'data',
            'flutter_windows.dll',
            'fterm.exe',
          ]),
        );
        expect(
          File(p.join(outDir, 'data', 'icudtl.dat')).readAsStringSync(),
          equals('ICU-DATA'),
        );

        // Traversal entry rejected.
        for (final badName in const [
          '../escape.dll',
          r'data\..\..\escape.dll',
          '/abs/path.dll',
          'C:drive.dll',
        ]) {
          final badArchive = Archive()
            ..addFile(ArchiveFile.string(badName, 'evil'));
          final badPath = p.join(dir.path, 'bad_${badName.hashCode}.zip');
          File(badPath).writeAsBytesSync(ZipEncoder().encode(badArchive));
          final target = p.join(dir.path, 'bad_out_${badName.hashCode}');
          Directory(target).createSync();
          expect(
            () => extractAndValidateWindowsZip(
              zipPath: badPath,
              outputDirPath: target,
            ),
            throwsA(isA<UpdateException>()),
          );
        }

        // Symlink entry in zip rejected.
        final symlinkArchive = Archive()
          ..addFile(ArchiveFile.symlink('evil_link', '../target'));
        final symlinkZip = p.join(dir.path, 'symlink.zip');
        File(symlinkZip).writeAsBytesSync(ZipEncoder().encode(symlinkArchive));
        final symlinkOut = p.join(dir.path, 'symlink_out');
        Directory(symlinkOut).createSync();
        expect(
          () => extractAndValidateWindowsZip(
            zipPath: symlinkZip,
            outputDirPath: symlinkOut,
          ),
          throwsA(isA<UpdateException>()),
        );

        // Uncompressed budget cap enforced.
        final bombArchive = Archive()
          ..addFile(ArchiveFile.bytes('fterm.exe', Uint8List(4096)));
        final bombZip = p.join(dir.path, 'bomb.zip');
        File(bombZip).writeAsBytesSync(ZipEncoder().encode(bombArchive));
        final bombOut = p.join(dir.path, 'bomb_out');
        Directory(bombOut).createSync();
        expect(
          () => extractAndValidateWindowsZip(
            zipPath: bombZip,
            outputDirPath: bombOut,
            maxUncompressedBytes: 1024,
          ),
          throwsA(isA<UpdateException>()),
        );
      },
    );

    test(
      'inspectTarGzStream allows internal relative symlinks while rejecting traversal, PAX escapes, hardlinks, FIFOs, and external symlinks',
      () async {
        final dir = await Directory.systemTemp.createTemp('fterm_tar_test_');
        addTearDown(() => dir.delete(recursive: true));

        // 1. Valid macOS-style tar.gz with internal framework relative symlinks and './' Linux entries.
        final validTarGz = p.join(dir.path, 'valid.tar.gz');
        File(validTarGz).writeAsBytesSync(
          _buildGzippedTar([
            _TarSpec.dir('./'),
            _TarSpec.file(
              'fterm.app/Contents/MacOS/fterm',
              utf8.encode('MACHO'),
            ),
            _TarSpec.file(
              'fterm.app/Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS',
              utf8.encode('DYLIB'),
            ),
            _TarSpec.symlink(
              'fterm.app/Contents/Frameworks/FlutterMacOS.framework/Versions/Current',
              'A',
            ),
            _TarSpec.symlink(
              'fterm.app/Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS',
              'Versions/Current/FlutterMacOS',
            ),
          ]),
        );
        await inspectTarGzStream(tarGzPath: validTarGz);

        // 2. Rejects leading '/', '../', hardlinks ('1'), FIFOs ('6'), external symlinks, and PAX override escapes.
        final rejectedCases = <List<_TarSpec>>[
          [_TarSpec.file('/etc/passwd', utf8.encode('root'))],
          [_TarSpec.file('fterm.app/../../escape', utf8.encode('bad'))],
          [
            _TarSpec.raw(
              name: 'fterm.app/hardlink',
              typeFlag: 0x31,
              linkName: 'fterm.app/Contents/MacOS/fterm',
            ),
          ],
          [_TarSpec.raw(name: 'fterm.app/fifo', typeFlag: 0x36)],
          [_TarSpec.symlink('fterm.app/Contents/escape', '../../../outside')],
          [_TarSpec.symlink('fterm.app/abs_link', '/etc/hosts')],
          [
            _TarSpec.paxOverride(
              paxRecords: const {'path': '../../escaped_via_pax'},
              nextEntry: _TarSpec.file('safe_ustar_name', utf8.encode('x')),
            ),
          ],
        ];

        for (var i = 0; i < rejectedCases.length; i++) {
          final path = p.join(dir.path, 'bad_$i.tar.gz');
          File(path).writeAsBytesSync(_buildGzippedTar(rejectedCases[i]));
          await expectLater(
            inspectTarGzStream(tarGzPath: path),
            throwsA(isA<UpdateException>()),
            reason: 'Case $i should be rejected by inspectTarGzStream',
          );
        }

        // 3. Enforces maxUncompressedBytes stream cap.
        final capPath = p.join(dir.path, 'cap.tar.gz');
        File(capPath).writeAsBytesSync(
          _buildGzippedTar([_TarSpec.file('big.bin', Uint8List(8192))]),
        );
        await expectLater(
          inspectTarGzStream(tarGzPath: capPath, maxUncompressedBytes: 2048),
          throwsA(isA<UpdateException>()),
        );
      },
    );
  });
}

void _definePortableLockAndSwapperTests() {
  group('Multi-instance lock & pure-Dart POSIX/Windows swappers', () {
    test(
      'PortableInstanceLock detects live sibling process and upgrades cleanly once sibling exits',
      () async {
        final dir = await Directory.systemTemp.createTemp('fterm_inst_lock_');
        addTearDown(() => dir.delete(recursive: true));

        final helperScript = File(p.join(dir.path, 'hold_shared_lock.dart'))
          ..writeAsStringSync('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final raf = File(args.first).openSync(mode: FileMode.append);
  raf.lockSync(FileLock.shared);
  stdout.writeln('LOCKED');
  await stdin.first;
  raf.closeSync();
}
''');

        final primary = PortableInstanceLock.tryAcquireShared(dir.path);
        expect(primary, isNotNull);
        addTearDown(primary!.release);

        expect(primary.hasSiblingInstances(), isFalse);

        final lockFilePath = p.join(dir.path, kFtermInstanceLockFileName);
        final child = await Process.start(_resolveDartCliExecutable(), [
          helperScript.path,
          lockFilePath,
        ]);
        await child.stdout
            .transform(utf8.decoder)
            .firstWhere((chunk) => chunk.contains('LOCKED'));

        expect(primary.hasSiblingInstances(), isTrue);
        expect(primary.tryUpgradeToExclusiveForSwap(), isFalse);

        child.stdin.writeln('EXIT');
        await child.exitCode;

        expect(primary.hasSiblingInstances(), isFalse);
        expect(primary.tryUpgradeToExclusiveForSwap(), isTrue);
        primary.downgradeToShared();
        expect(primary.isHoldingExclusive, isFalse);
      },
    );

    test(
      'performLinuxInProcessSwap swaps union manifest, preserves sidecars, and rolls back on relaunch failure',
      () async {
        final root = await Directory.systemTemp.createTemp('fterm_linux_swap_');
        addTearDown(() => root.delete(recursive: true));

        final installDir = Directory(p.join(root.path, 'install'))
          ..createSync();
        final stagedDir = Directory(p.join(root.path, 'staged'))..createSync();

        // Populate v0.2.2 install with retired lib_old.so + user sidecar iap-key.json.
        File(p.join(installDir.path, 'fterm')).writeAsStringSync('OLD-BIN');
        Directory(p.join(installDir.path, 'data')).createSync();
        File(
          p.join(installDir.path, 'data', 'icudtl.dat'),
        ).writeAsStringSync('OLD-ICU');
        Directory(p.join(installDir.path, 'lib')).createSync();
        File(
          p.join(installDir.path, 'retired.so'),
        ).writeAsStringSync('RETIRED');
        File(
          p.join(installDir.path, 'iap-key.json'),
        ).writeAsStringSync('USER-SECRET');
        File(p.join(installDir.path, kFtermManifestFileName)).writeAsStringSync(
          jsonEncode([
            '.fterm-files.json',
            'data',
            'fterm',
            'lib',
            'retired.so',
          ]),
        );

        // Populate v0.3.0 staged dir (retires retired.so, adds added.so).
        File(p.join(stagedDir.path, 'fterm')).writeAsStringSync('NEW-BIN');
        Directory(p.join(stagedDir.path, 'data')).createSync();
        File(
          p.join(stagedDir.path, 'data', 'icudtl.dat'),
        ).writeAsStringSync('NEW-ICU');
        Directory(p.join(stagedDir.path, 'lib')).createSync();
        File(p.join(stagedDir.path, 'added.so')).writeAsStringSync('ADDED');
        File(p.join(stagedDir.path, kFtermManifestFileName)).writeAsStringSync(
          jsonEncode(['.fterm-files.json', 'added.so', 'data', 'fterm', 'lib']),
        );

        // 1. Failing relaunch rolls back everything to v0.2.2!
        await expectLater(
          performLinuxInProcessSwap(
            stagedDirPath: stagedDir.path,
            targetDirPath: installDir.path,
            relaunch: true,
            relaunchArgs: const ['--server', 'wss://example.com'],
            detachedLauncher: (_, _, _) async =>
                throw const FileSystemException('exec format error'),
          ),
          throwsA(isA<UpdateException>()),
        );
        expect(
          File(p.join(installDir.path, 'fterm')).readAsStringSync(),
          equals('OLD-BIN'),
        );
        expect(
          File(p.join(installDir.path, 'retired.so')).existsSync(),
          isTrue,
        );
        expect(File(p.join(installDir.path, 'added.so')).existsSync(), isFalse);
        expect(
          File(p.join(installDir.path, 'iap-key.json')).readAsStringSync(),
          equals('USER-SECRET'),
        );

        // 2. Successful swap updates managed entries, retires retired.so -> .fterm-bak, and preserves iap-key.json.
        String? launchedExe;
        List<String>? launchedArgs;
        await performLinuxInProcessSwap(
          stagedDirPath: stagedDir.path,
          targetDirPath: installDir.path,
          relaunch: true,
          relaunchArgs: const ['--server', 'wss://example.com'],
          detachedLauncher: (exe, args, _) async {
            launchedExe = exe;
            launchedArgs = args;
          },
        );
        expect(launchedExe, equals(p.join(installDir.path, 'fterm')));
        expect(launchedArgs, equals(['--server', 'wss://example.com']));
        expect(
          File(p.join(installDir.path, 'fterm')).readAsStringSync(),
          equals('NEW-BIN'),
        );
        expect(
          File(p.join(installDir.path, 'added.so')).readAsStringSync(),
          equals('ADDED'),
        );
        expect(
          File(p.join(installDir.path, 'retired.so')).existsSync(),
          isFalse,
        );
        expect(
          File(p.join(installDir.path, 'retired.so.fterm-bak')).existsSync(),
          isTrue,
        );
        expect(
          File(p.join(installDir.path, 'iap-key.json')).readAsStringSync(),
          equals('USER-SECRET'),
        );
      },
    );

    test(
      'performMacosInProcessSwap swaps .app atomically and rolls back cleanly on relaunch failure',
      () async {
        final root = await Directory.systemTemp.createTemp('fterm_macos_swap_');
        addTearDown(() => root.delete(recursive: true));

        final targetApp = Directory(p.join(root.path, 'fterm.app'))
          ..createSync();
        File(p.join(targetApp.path, 'version.txt')).writeAsStringSync('0.2.2');
        final stagedApp = Directory(p.join(root.path, 'staged', 'fterm.app'))
          ..createSync(recursive: true);
        File(p.join(stagedApp.path, 'version.txt')).writeAsStringSync('0.3.0');

        // Failed `open -n` rolls back fterm.app to 0.2.2.
        await expectLater(
          performMacosInProcessSwap(
            stagedAppPath: stagedApp.path,
            targetAppPath: targetApp.path,
            relaunch: true,
            detachedLauncher: (_, _, _) async =>
                throw const ProcessException('/usr/bin/open', ['-n']),
          ),
          throwsA(isA<UpdateException>()),
        );
        expect(
          File(p.join(targetApp.path, 'version.txt')).readAsStringSync(),
          equals('0.2.2'),
        );

        // Successful swap moves 0.3.0 into place and invokes `/usr/bin/open -n ... --args`.
        List<String>? openArgs;
        await performMacosInProcessSwap(
          stagedAppPath: stagedApp.path,
          targetAppPath: targetApp.path,
          relaunch: true,
          relaunchArgs: const ['--token-file', '/Users/me/tok'],
          detachedLauncher: (exe, args, _) async {
            expect(exe, equals('/usr/bin/open'));
            openArgs = args;
          },
        );
        expect(
          openArgs,
          equals([
            '-n',
            targetApp.path,
            '--args',
            '--token-file',
            '/Users/me/tok',
          ]),
        );
        expect(
          File(p.join(targetApp.path, 'version.txt')).readAsStringSync(),
          equals('0.3.0'),
        );
        expect(Directory('${targetApp.path}.fterm-bak').existsSync(), isTrue);
      },
    );

    test(
      'Windows --internal-swap-update stages .fterm-new copies, aborts on --wait-pid timeout, rolls back on failure, and cleans up .fterm-bak',
      () async {
        final root = await Directory.systemTemp.createTemp('fterm_win_swap_');
        addTearDown(() => root.delete(recursive: true));

        final installDir = Directory(p.join(root.path, 'install'))
          ..createSync();
        final stagedDir = Directory(
          p.join(root.path, 'install', '.fterm-update', 'extracted'),
        )..createSync(recursive: true);

        void seedV1() {
          File(
            p.join(installDir.path, 'fterm.exe'),
          ).writeAsStringSync('V1-EXE');
          File(
            p.join(installDir.path, 'retired.dll'),
          ).writeAsStringSync('V1-OLD');
          Directory(
            p.join(installDir.path, 'data'),
          ).createSync(recursive: true);
          File(
            p.join(installDir.path, 'data', 'icudtl.dat'),
          ).writeAsStringSync('V1-ICU');
          File(
            p.join(installDir.path, 'user-notes.txt'),
          ).writeAsStringSync('KEEP-ME');
          File(
            p.join(installDir.path, kFtermManifestFileName),
          ).writeAsStringSync(
            jsonEncode([
              '.fterm-files.json',
              'data',
              'fterm.exe',
              'retired.dll',
            ]),
          );

          File(p.join(stagedDir.path, 'fterm.exe')).writeAsStringSync('V2-EXE');
          File(
            p.join(stagedDir.path, 'new_plugin.dll'),
          ).writeAsStringSync('V2-NEW');
          Directory(p.join(stagedDir.path, 'data')).createSync(recursive: true);
          File(
            p.join(stagedDir.path, 'data', 'icudtl.dat'),
          ).writeAsStringSync('V2-ICU');
          File(
            p.join(stagedDir.path, kFtermManifestFileName),
          ).writeAsStringSync(
            jsonEncode([
              '.fterm-files.json',
              'data',
              'fterm.exe',
              'new_plugin.dll',
            ]),
          );
        }

        seedV1();

        // 1. --wait-pid timeout aborts with exit code 1 without modifying installDir!
        int? exitCode;
        await maybeExecuteWindowsInternalSwap(
          [
            kInternalSwapUpdateFlag,
            '--wait-pid',
            '4242',
            '--staged',
            stagedDir.path,
            '--target',
            installDir.path,
          ],
          pinTempWorkingDirectory: false,
          waitForProcessExit: (_, _) => false,
          onExit: (code) => exitCode = code,
        );
        expect(exitCode, equals(1));
        expect(
          File(p.join(installDir.path, 'fterm.exe')).readAsStringSync(),
          equals('V1-EXE'),
        );
        expect(
          File(p.join(installDir.path, 'new_plugin.dll')).existsSync(),
          isFalse,
        );

        // 2. Relaunch failure rolls back all swapped entries cleanly to V1!
        exitCode = null;
        await maybeExecuteWindowsInternalSwap(
          [
            kInternalSwapUpdateFlag,
            '--wait-pid',
            '4242',
            '--staged',
            stagedDir.path,
            '--target',
            installDir.path,
            '--relaunch',
            p.join(installDir.path, 'fterm.exe'),
            '--',
            '--server',
            'wss://relay.example.com',
          ],
          pinTempWorkingDirectory: false,
          waitForProcessExit: (_, _) => true,
          retryAttempts: 2,
          retryDelay: const Duration(milliseconds: 5),
          detachedLauncher: (_, _, _) async =>
              throw const FileSystemException('CreateProcessW failed'),
          onExit: (code) => exitCode = code,
        );
        expect(exitCode, equals(1));
        expect(
          File(p.join(installDir.path, 'fterm.exe')).readAsStringSync(),
          equals('V1-EXE'),
        );
        expect(
          File(p.join(installDir.path, 'retired.dll')).readAsStringSync(),
          equals('V1-OLD'),
        );
        expect(
          File(p.join(installDir.path, 'new_plugin.dll')).existsSync(),
          isFalse,
        );
        expect(
          File(p.join(installDir.path, 'user-notes.txt')).readAsStringSync(),
          equals('KEEP-ME'),
        );

        // 3. Re-seed staged (since .fterm-new copies preserve staged!) and run full successful swap + post-frame cleanup!
        String? relaunchedExe;
        List<String>? relaunchedArgs;
        await maybeExecuteWindowsInternalSwap(
          [
            kInternalSwapUpdateFlag,
            '--wait-pid',
            '4242',
            '--staged',
            stagedDir.path,
            '--target',
            installDir.path,
            '--relaunch',
            p.join(installDir.path, 'fterm.exe'),
            '--',
            '--server',
            'wss://relay.example.com',
          ],
          pinTempWorkingDirectory: false,
          waitForProcessExit: (_, _) => true,
          retryAttempts: 2,
          retryDelay: const Duration(milliseconds: 5),
          detachedLauncher: (exe, args, _) async {
            relaunchedExe = exe;
            relaunchedArgs = args;
          },
          onExit: (code) => exitCode = code,
        );
        expect(exitCode, equals(0));
        expect(relaunchedExe, equals(p.join(installDir.path, 'fterm.exe')));
        expect(relaunchedArgs, equals(['--server', 'wss://relay.example.com']));
        expect(
          File(p.join(installDir.path, 'fterm.exe')).readAsStringSync(),
          equals('V2-EXE'),
        );
        expect(
          File(
            p.join(installDir.path, 'data', 'icudtl.dat'),
          ).readAsStringSync(),
          equals('V2-ICU'),
        );
        expect(
          File(p.join(installDir.path, 'new_plugin.dll')).readAsStringSync(),
          equals('V2-NEW'),
        );
        expect(
          File(p.join(installDir.path, 'retired.dll')).existsSync(),
          isFalse,
        );
        expect(
          File(p.join(installDir.path, 'retired.dll.fterm-bak')).existsSync(),
          isTrue,
        );
        // Staged files were copied (not moved) so staged\fterm.exe remained intact while running!
        expect(File(p.join(stagedDir.path, 'fterm.exe')).existsSync(), isTrue);
        expect(
          File(p.join(installDir.path, 'user-notes.txt')).readAsStringSync(),
          equals('KEEP-ME'),
        );

        // 4. First-frame cleanup removes *.fterm-bak and .fterm-update while keeping user-notes.txt!
        await cleanupStaleUpdateArtifacts(
          lockDirPath: installDir.path,
          cleanupParentDir: installDir.path,
          isWindows: Platform.isWindows,
          windowsRetryCount: 3,
          windowsRetryDelay: const Duration(milliseconds: 10),
        );
        expect(
          Directory(p.join(installDir.path, '.fterm-update')).existsSync(),
          isFalse,
        );
        expect(
          File(p.join(installDir.path, 'retired.dll.fterm-bak')).existsSync(),
          isFalse,
        );
        expect(
          File(p.join(installDir.path, 'fterm.exe.fterm-bak')).existsSync(),
          isFalse,
        );
        expect(
          File(p.join(installDir.path, 'user-notes.txt')).readAsStringSync(),
          equals('KEEP-ME'),
        );
      },
    );

    test(
      'end-to-end compiled Windows release binary executes --internal-swap-update headlessly',
      () async {
        if (!Platform.isWindows) return;
        final pubspec = _locateFtermPubspec();
        final releaseDir = Directory(
          p.join(
            pubspec.parent.path,
            'build',
            'windows',
            'x64',
            'runner',
            'Release',
          ),
        );
        final builtExe = File(p.join(releaseDir.path, 'fterm.exe'));
        if (!builtExe.existsSync()) {
          // Verified once `flutter build windows --release` has been built.
          return;
        }

        final tempRoot = await Directory.systemTemp.createTemp(
          'fterm_e2e_win_bin_',
        );
        addTearDown(() => tempRoot.delete(recursive: true));

        final installDir = Directory(p.join(tempRoot.path, 'portable'))
          ..createSync();
        File(p.join(installDir.path, 'fterm.exe')).writeAsStringSync('OLD-BIN');
        Directory(p.join(installDir.path, 'data')).createSync();
        File(
          p.join(installDir.path, 'data', 'icudtl.dat'),
        ).writeAsStringSync('OLD');
        File(
          p.join(installDir.path, 'sidecar.json'),
        ).writeAsStringSync('{"keep":1}');
        File(p.join(installDir.path, kFtermManifestFileName)).writeAsStringSync(
          jsonEncode(['.fterm-files.json', 'data', 'fterm.exe']),
        );

        final stagedDir = Directory(
          p.join(installDir.path, '.fterm-update', 'extracted'),
        )..createSync(recursive: true);
        _copyTreeForTest(releaseDir.path, stagedDir.path);
        final stagedEntries = [
          for (final e in stagedDir.listSync(followLinks: false))
            p.basename(e.path),
          kFtermManifestFileName,
        ]..sort();
        File(
          p.join(stagedDir.path, kFtermManifestFileName),
        ).writeAsStringSync(jsonEncode(stagedEntries.toSet().toList()..sort()));

        // Spawn short-lived dummy parent process to exercise real Win32 OpenProcess + WaitForSingleObject!
        final shortParent = await Process.start(
          _resolveDartCliExecutable(),
          const ['--version'],
        );
        final parentPid = shortParent.pid;
        await shortParent.exitCode;

        final swapResult =
            await Process.run(p.join(stagedDir.path, 'fterm.exe'), [
              kInternalSwapUpdateFlag,
              '--wait-pid',
              '$parentPid',
              '--staged',
              stagedDir.path,
              '--target',
              installDir.path,
            ], workingDirectory: Directory.systemTemp.path);
        expect(swapResult.exitCode, equals(0));
        expect(
          File(p.join(installDir.path, 'fterm.exe')).lengthSync(),
          equals(builtExe.lengthSync()),
        );
        expect(
          File(
            p.join(installDir.path, 'fterm.exe.fterm-bak'),
          ).readAsStringSync(),
          equals('OLD-BIN'),
        );
        expect(
          File(p.join(installDir.path, 'sidecar.json')).readAsStringSync(),
          equals('{"keep":1}'),
        );
      },
    );

    test(
      'resolvePortableInstallLayout enforces build/, /nix/store, /AppTranslocation, FLUTTER_TEST, and bundle structure guards',
      () async {
        final dir = await Directory.systemTemp.createTemp('fterm_layout_');
        addTearDown(() => dir.delete(recursive: true));

        final winRoot = Directory(p.join(dir.path, 'win_portable'))
          ..createSync();
        Directory(p.join(winRoot.path, 'data')).createSync();
        File(
          p.join(winRoot.path, 'data', 'icudtl.dat'),
        ).writeAsStringSync('icu');
        final winExe = p.join(winRoot.path, 'fterm.exe');
        File(winExe).writeAsStringSync('exe');

        // Supported when releaseMode: true and FLUTTER_TEST absent.
        final supported = resolvePortableInstallLayout(
          resolvedExecutable: winExe,
          operatingSystem: 'windows',
          environment: const {},
          releaseMode: true,
        );
        expect(supported.capability, equals(SelfUpdateCapability.supported));
        expect(supported.portableRootPath, equals(winRoot.path));

        // Disabled under FLUTTER_TEST or !releaseMode or blocked paths.
        expect(
          resolvePortableInstallLayout(
            resolvedExecutable: winExe,
            operatingSystem: 'windows',
            environment: const {'FLUTTER_TEST': 'true'},
            releaseMode: true,
          ).capability,
          equals(SelfUpdateCapability.readOnlyOrNonPortable),
        );
        expect(
          resolvePortableInstallLayout(
            resolvedExecutable: winExe,
            operatingSystem: 'windows',
            environment: const {},
            releaseMode: false,
          ).capability,
          equals(SelfUpdateCapability.readOnlyOrNonPortable),
        );
        for (final blocked in const [
          '/Applications/AppTranslocation/123/d/fterm.app/Contents/MacOS/fterm',
          '/nix/store/abc-fterm/fterm',
          '/tmp/.mount_fterm123/usr/bin/fterm',
          '/usr/local/bin/fterm',
          '/home/dev/termui/apps/fterm/build/linux/x64/release/bundle/fterm',
        ]) {
          expect(
            resolvePortableInstallLayout(
              resolvedExecutable: blocked,
              operatingSystem: 'linux',
              environment: const {},
              releaseMode: true,
            ).capability,
            equals(SelfUpdateCapability.readOnlyOrNonPortable),
            reason: 'Expected $blocked to disable in-place self-update',
          );
        }
      },
    );

    test(
      'IoUpdateService.stageUpdate + IoUpdateHttpClient stream download, disk headroom check, and applyStagedUpdateAndExit',
      () async {
        final dir = await Directory.systemTemp.createTemp('fterm_service_io_');
        addTearDown(() => dir.delete(recursive: true));

        final archive = Archive()
          ..addFile(ArchiveFile.string('fterm.exe', 'NEW-WIN-EXE'))
          ..addFile(ArchiveFile.string('flutter_windows.dll', 'NEW-DLL'))
          ..addFile(ArchiveFile.string('data/icudtl.dat', 'NEW-ICU'))
          ..addFile(
            ArchiveFile.string(
              kFtermManifestFileName,
              jsonEncode([
                '.fterm-files.json',
                'data',
                'flutter_windows.dll',
                'fterm.exe',
              ]),
            ),
          );
        final zipBytes = Uint8List.fromList(ZipEncoder().encode(archive));
        final zipSha = sha256.convert(zipBytes).toString();

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          if (req.uri.path == '/fterm.zip') {
            req.response.statusCode = HttpStatus.ok;
            req.response.add(zipBytes);
            await req.response.close();
          } else {
            req.response.statusCode = HttpStatus.notFound;
            await req.response.close();
          }
        });

        final httpClient = IoUpdateHttpClient();
        addTearDown(httpClient.close);

        // Build download destination via FakeUpdateHttpClient wrapping real bytes so HTTPS scheme validation passes.
        final downloadFake = _FakeUpdateHttpClient()
          ..downloadPayload = zipBytes;

        final portableDir = Directory(p.join(dir.path, 'portable'))
          ..createSync();
        Directory(p.join(portableDir.path, 'data')).createSync();
        File(
          p.join(portableDir.path, 'data', 'icudtl.dat'),
        ).writeAsStringSync('OLD');
        File(p.join(portableDir.path, 'fterm.exe')).writeAsStringSync('OLD');

        final layout = PortableInstallLayout(
          operatingSystem: 'windows',
          capability: SelfUpdateCapability.supported,
          portableRootPath: portableDir.path,
          lockAndCleanupDirPath: portableDir.path,
          stagingDirPath: p.join(portableDir.path, '.fterm-update'),
        );

        var freeBytes =
            10 * 1024 * 1024; // Only 10 MB free initially -> must reject!
        int? exitCode;
        List<String>? spawnedSwapArgs;
        final service = IoUpdateService(
          currentVersion: FtermSemVer.parse('0.2.2'),
          repository: IoUpdateRepository(
            httpClient: downloadFake,
            targetPlatform: DesktopTargetPlatform.windowsX64,
          ),
          layout: layout,
          freeDiskBytesProbe: (_) async => freeBytes,
          processRunner: (_, _) async => ProcessResult(1, 0, '', ''),
          detachedLauncher: (_, args, _) async => spawnedSwapArgs = args,
          onExit: (code) => exitCode = code,
          environment: const {'USERNAME': 'tester'},
        );
        addTearDown(service.dispose);

        final update = AvailableUpdate(
          version: FtermSemVer.parse('0.3.0'),
          tagName: 'fterm-v0.3.0',
          htmlUrl: Uri.parse(
            'https://github.com/jtmcdole/termui/releases/tag/fterm-v0.3.0',
          ),
          asset: ReleaseAssetInfo(
            name: 'fterm-windows-x64.zip',
            browserDownloadUrl: Uri.parse(
              'https://objects.githubusercontent.com/fterm.zip',
            ),
            size: zipBytes.length,
            sha256Hex: zipSha,
          ),
        );

        // 1. Insufficient disk space (< 250 MB) rejected before download.
        await expectLater(
          service.stageUpdate(update),
          throwsA(isA<UpdateException>()),
        );

        // 2. Restore disk headroom -> stages & verifies inside Isolate.run!
        freeBytes = 1024 * 1024 * 1024;
        final progressEvents = <DownloadProgress>[];
        final staged = await service.stageUpdate(
          update,
          onProgress: progressEvents.add,
        );
        expect(progressEvents, isNotEmpty);
        expect(
          File(
            p.join(staged.stagedPayloadPath, 'fterm.exe'),
          ).readAsStringSync(),
          equals('NEW-WIN-EXE'),
        );

        // 3. Also verify real IoUpdateHttpClient loopback streaming & cap guard!
        final streamDest = File(p.join(dir.path, 'streamed.zip'));
        await httpClient.downloadToFile(
          uri: Uri.parse('http://127.0.0.1:${server.port}/fterm.zip'),
          destinationFile: streamDest,
          expectedBytes: zipBytes.length,
        );
        expect(streamDest.lengthSync(), equals(zipBytes.length));
        await expectLater(
          httpClient.downloadToFile(
            uri: Uri.parse('http://127.0.0.1:${server.port}/fterm.zip'),
            destinationFile: File(p.join(dir.path, 'capped.zip')),
            expectedBytes: 8,
            maxBytes: 16,
          ),
          throwsA(isA<UpdateException>()),
        );

        // 4. applyStagedUpdateAndExit spawns detached staged\fterm.exe --internal-swap-update and exits 0.
        await service.applyStagedUpdateAndExit(
          staged,
          relaunch: true,
          relaunchArgs: const ['--server', 'wss://relay.example.com'],
        );
        expect(exitCode, equals(0));
        expect(spawnedSwapArgs, isNotNull);
        expect(spawnedSwapArgs!.first, equals(kInternalSwapUpdateFlag));
        expect(spawnedSwapArgs, contains('--relaunch'));
      },
    );
  });
}

void _defineUnixServiceAndEdgeCaseTests() {
  group('macOS & Linux IoUpdateService flows, Win32 FFI helpers, and edge cases', () {
    test(
      'covers maybeRunInternalSwapUpdate, Win32 waitForWin32ProcessExit, queryAvailableDiskBytes, and malformed swap CLI args',
      () async {
        expect(await maybeRunInternalSwapUpdate(const []), isFalse);
        expect(
          await maybeRunInternalSwapUpdate(const ['--url', 'ws://x']),
          isFalse,
        );

        int? badArgsExit;
        expect(
          await maybeExecuteWindowsInternalSwap(
            const [kInternalSwapUpdateFlag, '--unknown', 'val'],
            pinTempWorkingDirectory: false,
            onExit: (c) => badArgsExit = c,
          ),
          isTrue,
        );
        expect(badArgsExit, equals(64));

        final freeDisk = await queryAvailableDiskBytes(
          Directory.systemTemp.path,
        );
        expect(freeDisk, isNotNull);
        expect(freeDisk, greaterThan(0));

        if (Platform.isWindows) {
          // Waiting 5ms on our own live PID times out cleanly (returns false).
          expect(waitForWin32ProcessExit(pid, 5), isFalse);
          // Waiting on an exited child process returns true immediately.
          final exitedProc = await Process.start(
            _resolveDartCliExecutable(),
            const ['--version'],
          );
          final exitedPid = exitedProc.pid;
          await exitedProc.exitCode;
          expect(waitForWin32ProcessExit(exitedPid, 2000), isTrue);
        }
      },
    );

    test(
      'covers Linux & macOS resolvePortableInstallLayout, stageUpdate (.tar.gz + xattr/codesign), applyStagedUpdateAndExit, revealStagedInFinder, and runStartupCleanup',
      () async {
        final root = await Directory.systemTemp.createTemp('fterm_unix_svc_');
        addTearDown(() => root.delete(recursive: true));

        // 1. Linux portable layout resolution & staging/swap flow.
        final linuxDir = Directory(p.join(root.path, 'linux_bundle'))
          ..createSync();
        File(p.join(linuxDir.path, 'fterm')).writeAsStringSync('OLD-LINUX');
        Directory(p.join(linuxDir.path, 'data')).createSync();
        Directory(p.join(linuxDir.path, 'lib')).createSync();

        final linuxLayout = resolvePortableInstallLayout(
          resolvedExecutable: p.join(linuxDir.path, 'fterm'),
          operatingSystem: 'linux',
          environment: const {},
          releaseMode: true,
        );
        expect(linuxLayout.capability, equals(SelfUpdateCapability.supported));
        expect(linuxLayout.portableRootPath, equals(linuxDir.path));

        final linuxTarBytes = Uint8List.fromList(
          _buildGzippedTar([
            _TarSpec.file('fterm', utf8.encode('NEW-LINUX')),
            _TarSpec.dir('data'),
            _TarSpec.file('data/icudtl.dat', utf8.encode('ICU')),
            _TarSpec.dir('lib'),
            _TarSpec.file('lib/libapp.so', utf8.encode('SO')),
            _TarSpec.file(
              kFtermManifestFileName,
              utf8.encode(
                jsonEncode(['.fterm-files.json', 'data', 'fterm', 'lib']),
              ),
            ),
          ]),
        );
        final linuxSha = sha256.convert(linuxTarBytes).toString();
        final linuxHttp = _FakeUpdateHttpClient()
          ..downloadPayload = linuxTarBytes;

        int? linuxExit;
        String? linuxLaunched;
        final linuxSvc = IoUpdateService(
          currentVersion: FtermSemVer.parse('0.2.2'),
          repository: IoUpdateRepository(
            httpClient: linuxHttp,
            targetPlatform: DesktopTargetPlatform.linuxX64,
          ),
          layout: linuxLayout,
          freeDiskBytesProbe: (_) async => 1024 * 1024 * 1024,
          processRunner: (exe, args) async {
            if (exe.endsWith('tar')) {
              final destDir = args.last;
              File(p.join(destDir, 'fterm')).writeAsStringSync('NEW-LINUX');
              Directory(p.join(destDir, 'data')).createSync(recursive: true);
              Directory(p.join(destDir, 'lib')).createSync(recursive: true);
              File(p.join(destDir, kFtermManifestFileName)).writeAsStringSync(
                jsonEncode(['.fterm-files.json', 'data', 'fterm', 'lib']),
              );
            }
            return ProcessResult(1, 0, '', '');
          },
          detachedLauncher: (exe, _, _) async => linuxLaunched = exe,
          onExit: (c) => linuxExit = c,
          environment: const {},
        );
        addTearDown(linuxSvc.dispose);

        final linuxUpdate = AvailableUpdate(
          version: FtermSemVer.parse('0.3.0'),
          tagName: 'fterm-v0.3.0',
          htmlUrl: Uri.parse(
            'https://github.com/jtmcdole/termui/releases/tag/fterm-v0.3.0',
          ),
          asset: ReleaseAssetInfo(
            name: 'fterm-linux-x64.tar.gz',
            browserDownloadUrl: Uri.parse(
              'https://objects.githubusercontent.com/linux.tar.gz',
            ),
            size: linuxTarBytes.length,
            sha256Hex: linuxSha,
          ),
        );
        final linuxStaged = await linuxSvc.stageUpdate(linuxUpdate);
        await linuxSvc.applyStagedUpdateAndExit(linuxStaged, relaunch: true);
        expect(linuxExit, equals(0));
        expect(linuxLaunched, equals(p.join(linuxDir.path, 'fterm')));
        expect(
          File(p.join(linuxDir.path, 'fterm')).readAsStringSync(),
          equals('NEW-LINUX'),
        );
        await linuxSvc.runStartupCleanup();
        expect(
          File(p.join(linuxDir.path, 'fterm.fterm-bak')).existsSync(),
          isFalse,
        );

        // 2. macOS portable layout resolution, xattr + codesign staging, revealStagedInFinder, and swap!
        final appsParent = Directory(p.join(root.path, 'Apps'))..createSync();
        final macosExe = p.join(
          appsParent.path,
          'fterm.app',
          'Contents',
          'MacOS',
          'fterm',
        );
        Directory(p.dirname(macosExe)).createSync(recursive: true);
        File(macosExe).writeAsStringSync('OLD-MACHO');

        final macosLayout = resolvePortableInstallLayout(
          resolvedExecutable: macosExe,
          operatingSystem: 'macos',
          environment: const {},
          releaseMode: true,
          posixUid: 501,
          stagingNonce: 'cafe1234',
        );
        expect(macosLayout.capability, equals(SelfUpdateCapability.supported));
        expect(
          macosLayout.portableRootPath,
          equals(p.join(appsParent.path, 'fterm.app')),
        );

        final macosTarBytes = Uint8List.fromList(
          _buildGzippedTar([
            _TarSpec.file(
              'fterm.app/Contents/MacOS/fterm',
              utf8.encode('NEW-MACHO'),
            ),
          ]),
        );
        final macosSha = sha256.convert(macosTarBytes).toString();
        final macosHttp = _FakeUpdateHttpClient()
          ..downloadPayload = macosTarBytes;
        final invokedTools = <String>[];
        int? macosExit;

        final macosSvc = IoUpdateService(
          currentVersion: FtermSemVer.parse('0.2.2'),
          repository: IoUpdateRepository(
            httpClient: macosHttp,
            targetPlatform: DesktopTargetPlatform.macosArm64,
          ),
          layout: macosLayout,
          freeDiskBytesProbe: (_) async => 1024 * 1024 * 1024,
          processRunner: (exe, args) async {
            invokedTools.add(exe);
            if (exe.endsWith('tar')) {
              final dest = args.last;
              final stagedBin = p.join(
                dest,
                'fterm.app',
                'Contents',
                'MacOS',
                'fterm',
              );
              Directory(p.dirname(stagedBin)).createSync(recursive: true);
              File(stagedBin).writeAsStringSync('NEW-MACHO');
            }
            return ProcessResult(1, 0, '', '');
          },
          detachedLauncher: (exe, _, _) async => invokedTools.add(exe),
          onExit: (c) => macosExit = c,
          environment: const {},
        );
        addTearDown(macosSvc.dispose);

        final macosUpdate = AvailableUpdate(
          version: FtermSemVer.parse('0.3.0'),
          tagName: 'fterm-v0.3.0',
          htmlUrl: Uri.parse(
            'https://github.com/jtmcdole/termui/releases/tag/fterm-v0.3.0',
          ),
          asset: ReleaseAssetInfo(
            name: 'fterm-macos-arm64.tar.gz',
            browserDownloadUrl: Uri.parse(
              'https://objects.githubusercontent.com/macos.tar.gz',
            ),
            size: macosTarBytes.length,
            sha256Hex: macosSha,
          ),
        );
        final macosStaged = await macosSvc.stageUpdate(macosUpdate);
        expect(
          invokedTools,
          containsAll(['/usr/bin/xattr', '/usr/bin/codesign']),
        );

        await macosSvc.revealStagedInFinder(macosStaged);
        expect(invokedTools, contains('/usr/bin/open'));

        await macosSvc.applyStagedUpdateAndExit(macosStaged, relaunch: true);
        expect(macosExit, equals(0));
        expect(File(macosExe).readAsStringSync(), equals('NEW-MACHO'));
      },
    );

    test(
      'covers IoUpdateHttpClient.getJson + >=64KB progress chunks, POSIX PortableInstanceLock, and GNU LongName tar headers',
      () async {
        final dir = await Directory.systemTemp.createTemp('fterm_extra_cov_');
        addTearDown(() => dir.delete(recursive: true));

        // 1. IoUpdateHttpClient.getJson + 128 KiB streaming download progress.
        final bigPayload = Uint8List(130 * 1024);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          if (req.uri.path == '/refs') {
            req.response.headers.set(HttpHeaders.etagHeader, 'W/"live-etag"');
            req.response.write('[{"ref":"refs/tags/fterm-v0.3.0"}]');
            await req.response.close();
          } else if (req.uri.path == '/big.bin') {
            req.response.add(bigPayload);
            await req.response.close();
          } else {
            req.response.statusCode = HttpStatus.notFound;
            await req.response.close();
          }
        });

        final client = IoUpdateHttpClient();
        addTearDown(client.close);
        final jsonRes = await client.getJson(
          Uri.parse('http://127.0.0.1:${server.port}/refs'),
          headers: const {'Accept': 'application/vnd.github+json'},
        );
        expect(jsonRes.statusCode, equals(HttpStatus.ok));
        expect(jsonRes.etag, equals('W/"live-etag"'));

        final chunks = <DownloadProgress>[];
        await client.downloadToFile(
          uri: Uri.parse('http://127.0.0.1:${server.port}/big.bin'),
          destinationFile: File(p.join(dir.path, 'big.bin')),
          expectedBytes: bigPayload.length,
          onProgress: chunks.add,
        );
        expect(chunks.length, greaterThanOrEqualTo(2));
        expect(chunks.last.fraction, closeTo(1.0, 0.001));

        await expectLater(
          client.downloadToFile(
            uri: Uri.parse('http://127.0.0.1:${server.port}/missing'),
            destinationFile: File(p.join(dir.path, '404.bin')),
            expectedBytes: 10,
          ),
          throwsA(isA<UpdateException>()),
        );

        // 2. POSIX lock upgrade path (isWindows: false) & PortableUpdateLock contention.
        final posixLock = PortableInstanceLock.tryAcquireShared(
          dir.path,
          isWindows: false,
        )!;
        if (Platform.isWindows) {
          // Win32 LockFileEx rejects overlapping self-locks, exercising the
          // FileSystemException catch branch of the POSIX path.
          expect(posixLock.hasSiblingInstances(), isTrue);
        } else {
          expect(posixLock.hasSiblingInstances(), isFalse);
          expect(posixLock.tryUpgradeToExclusiveForSwap(), isTrue);
          posixLock.downgradeToShared();
        }
        posixLock.release();

        final upLock1 = PortableUpdateLock.tryAcquire(dir.path);
        expect(upLock1, isNotNull);
        addTearDown(upLock1!.release);
        final probeScript = File(p.join(dir.path, 'probe_update_lock.dart'))
          ..writeAsStringSync('''
import 'dart:io';
void main(List<String> args) {
  final raf = File(args.first).openSync(mode: FileMode.append);
  try {
    raf.lockSync(FileLock.exclusive);
    exit(1);
  } on FileSystemException {
    exit(0);
  } finally {
    raf.closeSync();
  }
}
''');
        final childCheck = await Process.run(_resolveDartCliExecutable(), [
          probeScript.path,
          p.join(dir.path, kFtermUpdateLockFileName),
        ]);
        expect(childCheck.exitCode, equals(0));
        upLock1.release();

        // 3. GNU LongName ('L') + LongLink ('K') tar headers and synthesized zip manifest.
        final gnuTar = BytesBuilder(copy: false);
        final longNameBytes = Uint8List.fromList(
          utf8.encode(
            'fterm.app/Contents/Resources/very_long_asset_name.txt\x00',
          ),
        );
        gnuTar.add(
          _encodeUstarHeader('././@LongLink', 0x4C, '', longNameBytes.length),
        );
        gnuTar.add(_padTarPayload(longNameBytes));
        gnuTar.add(_encodeUstarHeader('truncated', 0x30, '', 2));
        gnuTar.add(_padTarPayload(utf8.encode('ok')));
        gnuTar.add(Uint8List(1024));
        final gnuTarGz = p.join(dir.path, 'gnu.tar.gz');
        File(gnuTarGz).writeAsBytesSync(gzip.encode(gnuTar.takeBytes()));
        await inspectTarGzStream(tarGzPath: gnuTarGz);

        // Zip without .fterm-files.json synthesizes manifest and extracts directory entries.
        final synthZip = Archive()
          ..addFile(ArchiveFile.directory('data/'))
          ..addFile(ArchiveFile.string('fterm.exe', 'EXE'))
          ..addFile(ArchiveFile.string('flutter_windows.dll', 'DLL'))
          ..addFile(ArchiveFile.string('data/icudtl.dat', 'ICU'));
        final synthZipPath = p.join(dir.path, 'synth.zip');
        File(synthZipPath).writeAsBytesSync(ZipEncoder().encode(synthZip));
        final synthOut = p.join(dir.path, 'synth_out')
          ..let((d) => Directory(d).createSync());
        final synthManifest = extractAndValidateWindowsZip(
          zipPath: synthZipPath,
          outputDirPath: synthOut,
        );
        expect(
          synthManifest,
          equals(['data', 'flutter_windows.dll', 'fterm.exe']),
        );
      },
    );

    test(
      'covers UpdateViewModel error/up-to-date/sibling branches, Web stub, locked-file swap rollback, and codesign failure',
      () async {
        // 1. Web stub coverage.
        final stub = web_stub.createUpdateService();
        expect(
          await web_stub.maybeRunPlatformInternalSwapUpdate(const []),
          isFalse,
        );
        expect(stub.capability, equals(SelfUpdateCapability.unsupportedWeb));
        expect(
          stub.currentVersion,
          equals(FtermSemVer.parse(kFtermBuildVersion)),
        );
        expect(stub.hasSiblingInstances(), isFalse);
        expect(stub.prepareExclusiveSwapLock(), isFalse);
        stub.cancelExclusiveSwapLock();
        final stubCheck = await stub.checkForUpdates(includePrereleases: false);
        expect(stubCheck.availableUpdate, isNull);
        await expectLater(
          stub.stageUpdate(
            AvailableUpdate(
              version: FtermSemVer.parse('0.3.0'),
              tagName: 'fterm-v0.3.0',
              htmlUrl: Uri.parse('https://example.com'),
            ),
          ),
          throwsA(isA<UpdateException>()),
        );
        await stub.runStartupCleanup();
        stub.dispose();

        // 2. UpdateViewModel up-to-date, background vs manual error, stage error, and sibling lock block.
        var prefs = const FtermPreferences();
        final vmSvc = _ScenarioUpdateService();
        final vm = UpdateViewModel(
          service: vmSvc,
          readPreferences: () => prefs,
          writePreferences: (next) => prefs = next,
        );
        expect(vm.canStageInPlace, isTrue);

        vmSvc.nextAvailable = null;
        await vm.checkForUpdates();
        expect(vm.status, equals(UpdateStatus.idle));
        expect(vm.statusMessage, equals('Up to date (v0.2.2)'));

        vmSvc.throwOnCheck = true;
        await vm.checkForUpdates(isBackground: true);
        expect(vm.status, equals(UpdateStatus.idle));
        await vm.checkForUpdates();
        expect(vm.status, equals(UpdateStatus.error));
        expect(vm.errorMessage, contains('network down'));

        vmSvc.throwOnCheck = false;
        vmSvc.nextAvailable = AvailableUpdate(
          version: FtermSemVer.parse('0.3.0'),
          tagName: 'fterm-v0.3.0',
          htmlUrl: Uri.parse('https://example.com'),
          asset: ReleaseAssetInfo(
            name: 'fterm-windows-x64.zip',
            browserDownloadUrl: Uri.parse('https://example.com/a.zip'),
            size: 32,
            sha256Hex: 'b' * 64,
          ),
        );
        vmSvc.cacheTagState = false;
        await vm.checkForUpdates();
        expect(vm.status, equals(UpdateStatus.available));

        vmSvc.throwOnStage = true;
        await vm.downloadAvailableUpdate();
        expect(vm.status, equals(UpdateStatus.error));

        vmSvc.throwOnStage = false;
        await vm.downloadAvailableUpdate();
        expect(vm.status, equals(UpdateStatus.readyToRestart));

        vmSvc.siblingOpen = true;
        expect(vm.hasSiblingInstances(), isTrue);
        expect(await vm.restartToUpdate(), isFalse);
        expect(vm.status, equals(UpdateStatus.error));
        expect(vm.errorMessage, contains('Close other open fterm windows'));
        vm.dispose();

        // 3. Windows mid-swap locked-file rollback (entry #1 moved to .fterm-bak, entry #2 locked -> rolls back entry #1!).
        if (Platform.isWindows) {
          final lockRoot = await Directory.systemTemp.createTemp(
            'fterm_mid_rb_',
          );
          addTearDown(() => lockRoot.delete(recursive: true));
          final target = Directory(p.join(lockRoot.path, 'target'))
            ..createSync();
          final staged = Directory(p.join(lockRoot.path, 'staged'))
            ..createSync();

          File(
            p.join(target.path, 'a_first.exe'),
          ).writeAsStringSync('OLD-FIRST');
          final lockedFile = File(p.join(target.path, 'z_locked.dll'))
            ..writeAsStringSync('OLD-LOCKED');
          File(
            p.join(staged.path, 'a_first.exe'),
          ).writeAsStringSync('NEW-FIRST');
          File(
            p.join(staged.path, 'b_added.dll'),
          ).writeAsStringSync('NEW-ADDED');
          File(
            p.join(staged.path, 'z_locked.dll'),
          ).writeAsStringSync('NEW-LOCKED');
          File(p.join(staged.path, kFtermManifestFileName)).writeAsStringSync(
            jsonEncode(['a_first.exe', 'b_added.dll', 'z_locked.dll']),
          );

          final openHandle = lockedFile.openSync(mode: FileMode.append);
          openHandle.lockSync(FileLock.exclusive);
          int? rbExit;
          try {
            await maybeExecuteWindowsInternalSwap(
              [
                kInternalSwapUpdateFlag,
                '--staged',
                staged.path,
                '--target',
                target.path,
              ],
              pinTempWorkingDirectory: false,
              retryAttempts: 1,
              retryDelay: const Duration(milliseconds: 1),
              onExit: (c) => rbExit = c,
            );
          } finally {
            openHandle.unlockSync();
            openHandle.closeSync();
          }
          expect(rbExit, equals(1));
          expect(
            File(p.join(target.path, 'a_first.exe')).readAsStringSync(),
            equals('OLD-FIRST'),
          );
          expect(
            File(p.join(target.path, 'b_added.dll')).existsSync(),
            isFalse,
          );
        }

        // 4. macOS codesign failure rejects stageUpdate and cleans staging dir.
        final csDir = await Directory.systemTemp.createTemp('fterm_cs_fail_');
        addTearDown(() => csDir.delete(recursive: true));
        final appRoot = Directory(p.join(csDir.path, 'fterm.app'))
          ..createSync();
        final tarBytes = Uint8List.fromList(
          _buildGzippedTar([
            _TarSpec.file('fterm.app/Contents/MacOS/fterm', utf8.encode('X')),
          ]),
        );
        final csSvc = IoUpdateService(
          currentVersion: FtermSemVer.parse('0.2.2'),
          repository: IoUpdateRepository(
            httpClient: _FakeUpdateHttpClient()..downloadPayload = tarBytes,
            targetPlatform: DesktopTargetPlatform.macosArm64,
          ),
          layout: PortableInstallLayout(
            operatingSystem: 'macos',
            capability: SelfUpdateCapability.supported,
            portableRootPath: appRoot.path,
            lockAndCleanupDirPath: csDir.path,
            stagingDirPath: p.join(csDir.path, '.fterm-update-501-bad'),
          ),
          freeDiskBytesProbe: (_) async => 1024 * 1024 * 1024,
          processRunner: (exe, args) async {
            if (exe.endsWith('tar')) {
              Directory(
                p.join(args.last, 'fterm.app'),
              ).createSync(recursive: true);
              return ProcessResult(1, 0, '', '');
            }
            if (exe == '/usr/bin/codesign') {
              return ProcessResult(1, 1, '', 'invalid signature');
            }
            return ProcessResult(1, 0, '', '');
          },
          environment: const {},
        );
        addTearDown(csSvc.dispose);
        await expectLater(
          csSvc.stageUpdate(
            AvailableUpdate(
              version: FtermSemVer.parse('0.3.0'),
              tagName: 'fterm-v0.3.0',
              htmlUrl: Uri.parse('https://example.com'),
              asset: ReleaseAssetInfo(
                name: 'fterm-macos-arm64.tar.gz',
                browserDownloadUrl: Uri.parse('https://example.com/m.tar.gz'),
                size: tarBytes.length,
                sha256Hex: sha256.convert(tarBytes).toString(),
              ),
            ),
          ),
          throwsA(isA<UpdateException>()),
        );
        expect(
          Directory(p.join(csDir.path, '.fterm-update-501-bad')).existsSync(),
          isFalse,
        );

        // 5. Additional error & rollback paths: stub applyStagedUpdateAndExit,
        //    Linux mid-swap failure rollback, macOS missing target rollback,
        //    tar non-zero exit, chmod non-zero exit, and busy .fterm-update.lock.
        await expectLater(
          web_stub.createUpdateService().applyStagedUpdateAndExit(
            StagedUpdate(
              update: AvailableUpdate(
                version: FtermSemVer.parse('0.3.0'),
                tagName: 'fterm-v0.3.0',
                htmlUrl: Uri.parse('https://example.com'),
              ),
              stagingDirPath: '/tmp/.u',
              stagedPayloadPath: '/tmp/.u/e',
              portableRootPath: '/tmp/app',
            ),
            relaunch: false,
          ),
          throwsA(isA<UpdateException>()),
        );

        await expectLater(
          performMacosInProcessSwap(
            stagedAppPath: p.join(csDir.path, 'missing_staged.app'),
            targetAppPath: appRoot.path,
            relaunch: false,
          ),
          throwsA(isA<UpdateException>()),
        );
        expect(appRoot.existsSync(), isTrue);

        // Busy .fterm-update.lock rejects concurrent stageUpdate immediately.
        final heldUpdateLock = PortableUpdateLock.tryAcquire(csDir.path);
        expect(heldUpdateLock, isNotNull);
        try {
          await expectLater(
            csSvc.stageUpdate(
              AvailableUpdate(
                version: FtermSemVer.parse('0.3.0'),
                tagName: 'fterm-v0.3.0',
                htmlUrl: Uri.parse('https://example.com'),
                asset: ReleaseAssetInfo(
                  name: 'fterm-macos-arm64.tar.gz',
                  browserDownloadUrl: Uri.parse('https://example.com/m.tar.gz'),
                  size: tarBytes.length,
                  sha256Hex: sha256.convert(tarBytes).toString(),
                ),
              ),
            ),
            throwsA(isA<UpdateException>()),
          );
        } finally {
          heldUpdateLock!.release();
        }

        // Non-zero chmod and non-zero tar exit codes surface clean UpdateExceptions.
        for (final failTool in ['chmod', 'tar']) {
          final failSvc = IoUpdateService(
            currentVersion: FtermSemVer.parse('0.2.2'),
            repository: IoUpdateRepository(
              httpClient: _FakeUpdateHttpClient()..downloadPayload = tarBytes,
              targetPlatform: DesktopTargetPlatform.macosArm64,
            ),
            layout: PortableInstallLayout(
              operatingSystem: 'macos',
              capability: SelfUpdateCapability.supported,
              portableRootPath: appRoot.path,
              lockAndCleanupDirPath: csDir.path,
              stagingDirPath: p.join(csDir.path, '.fterm-update-$failTool'),
            ),
            freeDiskBytesProbe: (_) async => 1024 * 1024 * 1024,
            processRunner: (exe, _) async {
              if (exe.endsWith(failTool)) {
                return ProcessResult(1, 2, '', '$failTool failed');
              }
              return ProcessResult(1, 0, '', '');
            },
            environment: const {},
          );
          addTearDown(failSvc.dispose);
          await expectLater(
            failSvc.stageUpdate(
              AvailableUpdate(
                version: FtermSemVer.parse('0.3.0'),
                tagName: 'fterm-v0.3.0',
                htmlUrl: Uri.parse('https://example.com'),
                asset: ReleaseAssetInfo(
                  name: 'fterm-macos-arm64.tar.gz',
                  browserDownloadUrl: Uri.parse('https://example.com/m.tar.gz'),
                  size: tarBytes.length,
                  sha256Hex: sha256.convert(tarBytes).toString(),
                ),
              ),
            ),
            throwsA(isA<UpdateException>()),
          );
        }
      },
    );
  });
}

final class _ScenarioUpdateService implements UpdateService {
  @override
  final FtermSemVer currentVersion = FtermSemVer.parse('0.2.2');

  @override
  SelfUpdateCapability capability = SelfUpdateCapability.supported;

  AvailableUpdate? nextAvailable;
  bool cacheTagState = true;
  bool throwOnCheck = false;
  bool throwOnStage = false;
  bool siblingOpen = false;

  @override
  Future<UpdateCheckOutcome> checkForUpdates({
    required bool includePrereleases,
    String? lastEtag,
    List<String> cachedTags = const [],
  }) async {
    if (throwOnCheck) throw const UpdateException('network down');
    return UpdateCheckOutcome(
      availableUpdate: nextAvailable,
      tagEtag: null,
      cachedTags: const [],
      cacheTagState: cacheTagState,
    );
  }

  @override
  Future<StagedUpdate> stageUpdate(
    AvailableUpdate update, {
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    if (throwOnStage) throw const UpdateException('disk error');
    return StagedUpdate(
      update: update,
      stagingDirPath: '/tmp/.u',
      stagedPayloadPath: '/tmp/.u/e',
      portableRootPath: '/tmp/app',
    );
  }

  @override
  bool hasSiblingInstances() => siblingOpen;

  @override
  bool prepareExclusiveSwapLock() => !siblingOpen;

  @override
  void cancelExclusiveSwapLock() {}

  @override
  Future<void> applyStagedUpdateAndExit(
    StagedUpdate staged, {
    required bool relaunch,
    List<String> relaunchArgs = const [],
    Future<void> Function()? beforeExitTeardown,
  }) async {}

  @override
  Future<void> revealStagedInFinder(StagedUpdate staged) async {}

  @override
  Future<void> runStartupCleanup() async {}

  @override
  void dispose() {}
}

extension _ScopeLet<T> on T {
  void let(void Function(T value) block) => block(this);
}

File _locateFtermPubspec() {
  for (final candidate in [
    File('pubspec.yaml'),
    File('apps/fterm/pubspec.yaml'),
  ]) {
    if (candidate.existsSync() &&
        candidate.readAsStringSync().contains('name: fterm')) {
      return candidate.absolute;
    }
  }
  throw StateError('Unable to locate apps/fterm/pubspec.yaml');
}

String _resolveDartCliExecutable() {
  final binName = Platform.isWindows ? 'dart.exe' : 'dart';
  final resolved = Platform.resolvedExecutable;
  if (p.basename(resolved).toLowerCase() == binName) {
    return resolved;
  }
  // Under `flutter test`, resolvedExecutable is `.../artifacts/engine/<arch>/flutter_tester`.
  final engineDir = p.dirname(resolved);
  for (final rel in [
    p.join(engineDir, '..', '..', '..', 'dart-sdk', 'bin', binName),
    p.join(engineDir, '..', '..', 'dart-sdk', 'bin', binName),
  ]) {
    final candidate = File(p.normalize(rel));
    if (candidate.existsSync()) return candidate.path;
  }
  return binName;
}

void _copyTreeForTest(String srcDir, String dstDir) {
  Directory(dstDir).createSync(recursive: true);
  for (final entity in Directory(srcDir).listSync(followLinks: false)) {
    final dstPath = p.join(dstDir, p.basename(entity.path));
    if (entity is File) {
      entity.copySync(dstPath);
    } else if (entity is Directory) {
      _copyTreeForTest(entity.path, dstPath);
    }
  }
}

final class _FakeRoutedPtyBackend implements RoutedPtyBackend {
  final StreamController<Uint8List> _out =
      StreamController<Uint8List>.broadcast();
  final Completer<int> _exit = Completer<int>();
  final Completer<void> disposedCompleter = Completer<void>();
  bool disposed = false;

  @override
  Stream<Uint8List> get output => _out.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void write(Uint8List data) {}

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  void kill() {
    if (!disposedCompleter.isCompleted) {
      disposedCompleter.complete();
    }
    if (!_exit.isCompleted) {
      _exit.complete(0);
    }
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    kill();
    await _out.close();
  }
}

final class _HungCloseStreamChannel {
  final StreamController<Uint8List> _inbound = StreamController<Uint8List>();
  final Completer<void> _closeGate = Completer<void>();

  late final StreamChannel<Uint8List> channel = StreamChannel<Uint8List>(
    _inbound.stream,
    _HungStreamSink(_closeGate.future),
  );

  void releaseClose() {
    if (!_closeGate.isCompleted) {
      _closeGate.complete();
    }
    unawaited(_inbound.close());
  }
}

final class _HungStreamSink implements StreamSink<Uint8List> {
  final Future<void> _doneFuture;
  _HungStreamSink(this._doneFuture);

  @override
  void add(Uint8List event) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Uint8List> stream) => stream.drain<void>();

  @override
  Future<void> close() => _doneFuture;

  @override
  Future<void> get done => _doneFuture;
}

final class _FakeUpdateHttpClient implements UpdateHttpClient {
  final Map<String, UpdateHttpResponse Function(Map<String, String> headers)>
  jsonRoutes = {};
  Uint8List? downloadPayload;

  @override
  Future<UpdateHttpResponse> getJson(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    final handler = jsonRoutes[uri.toString()];
    if (handler == null) {
      return const UpdateHttpResponse(
        statusCode: HttpStatus.notFound,
        body: '{}',
      );
    }
    return handler(headers);
  }

  @override
  Future<void> downloadToFile({
    required Uri uri,
    required File destinationFile,
    required int expectedBytes,
    int maxBytes = kMaxArchiveDownloadBytes,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    final bytes = downloadPayload;
    if (bytes == null) throw UnimplementedError();
    await destinationFile.writeAsBytes(bytes);
    onProgress?.call(
      DownloadProgress(receivedBytes: bytes.length, totalBytes: expectedBytes),
    );
  }

  @override
  void close() {}
}

final class _TarSpec {
  final String name;
  final int typeFlag;
  final String linkName;
  final Uint8List payload;
  final Map<String, String>? paxRecords;
  final _TarSpec? paxNext;

  const _TarSpec._({
    required this.name,
    required this.typeFlag,
    required this.linkName,
    required this.payload,
    this.paxRecords,
    this.paxNext,
  });

  factory _TarSpec.file(String name, List<int> bytes) => _TarSpec._(
    name: name,
    typeFlag: 0x30,
    linkName: '',
    payload: Uint8List.fromList(bytes),
  );

  factory _TarSpec.dir(String name) => _TarSpec._(
    name: name,
    typeFlag: 0x35,
    linkName: '',
    payload: Uint8List(0),
  );

  factory _TarSpec.symlink(String name, String target) => _TarSpec._(
    name: name,
    typeFlag: 0x32,
    linkName: target,
    payload: Uint8List(0),
  );

  factory _TarSpec.raw({
    required String name,
    required int typeFlag,
    String linkName = '',
  }) => _TarSpec._(
    name: name,
    typeFlag: typeFlag,
    linkName: linkName,
    payload: Uint8List(0),
  );

  factory _TarSpec.paxOverride({
    required Map<String, String> paxRecords,
    required _TarSpec nextEntry,
  }) => _TarSpec._(
    name: 'PaxHeader/entry',
    typeFlag: 0x78,
    linkName: '',
    payload: Uint8List(0),
    paxRecords: paxRecords,
    paxNext: nextEntry,
  );
}

List<int> _buildGzippedTar(List<_TarSpec> specs) {
  final tar = BytesBuilder(copy: false);
  void emit(_TarSpec spec) {
    if (spec.paxRecords case final records?) {
      final buf = StringBuffer();
      for (final MapEntry(:key, :value) in records.entries) {
        final body = ' $key=$value\n';
        var len = body.length + 2;
        while ('$len$body'.length != len) {
          len = '$len$body'.length;
        }
        buf.write('$len$body');
      }
      final paxBytes = Uint8List.fromList(utf8.encode(buf.toString()));
      tar.add(_encodeUstarHeader('PaxHeader/0', 0x78, '', paxBytes.length));
      tar.add(_padTarPayload(paxBytes));
      emit(spec.paxNext!);
      return;
    }
    tar.add(
      _encodeUstarHeader(
        spec.name,
        spec.typeFlag,
        spec.linkName,
        spec.payload.length,
      ),
    );
    if (spec.payload.isNotEmpty) {
      tar.add(_padTarPayload(spec.payload));
    }
  }

  for (final s in specs) {
    emit(s);
  }
  tar.add(Uint8List(1024)); // Two 512-byte EOF blocks.
  return gzip.encode(tar.takeBytes());
}

Uint8List _encodeUstarHeader(
  String name,
  int typeFlag,
  String linkName,
  int size,
) {
  final block = Uint8List(512);
  void writeStr(String s, int offset, int maxLen) {
    final bytes = utf8.encode(s);
    final count = bytes.length < maxLen ? bytes.length : maxLen;
    block.setRange(offset, offset + count, bytes);
  }

  writeStr(name, 0, 100);
  writeStr('0000755', 100, 7);
  writeStr('0000000', 108, 7);
  writeStr('0000000', 116, 7);
  writeStr(size.toRadixString(8).padLeft(11, '0'), 124, 11);
  writeStr('00000000000', 136, 11);
  block.fillRange(148, 156, 0x20); // Spaces while computing checksum.
  block[156] = typeFlag;
  writeStr(linkName, 157, 100);
  writeStr('ustar', 257, 5);
  writeStr('00', 263, 2);

  var sum = 0;
  for (final b in block) {
    sum += b;
  }
  final chk = sum.toRadixString(8).padLeft(6, '0');
  writeStr(chk, 148, 6);
  block[154] = 0;
  block[155] = 0x20;
  return block;
}

Uint8List _padTarPayload(Uint8List data) {
  final padded = ((data.length + 511) ~/ 512) * 512;
  final out = Uint8List(padded);
  out.setRange(0, data.length, data);
  return out;
}
