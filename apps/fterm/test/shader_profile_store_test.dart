@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/shader_profile_store.dart';
import 'package:fterm/src/shader_profile_store_io.dart' as io_store;
import 'package:path/path.dart' as p;
import 'package:termui_flutter/termui_flutter.dart'
    show ShaderAnimationMode, ShaderBackendKind;

Uint8List _pngBytes([int totalLength = 16]) {
  final data = Uint8List(totalLength);
  const header = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  data.setRange(0, header.length, header);
  return data;
}

Uint8List _jpegBytes([int totalLength = 16]) {
  final data = Uint8List(totalLength);
  const header = <int>[0xFF, 0xD8, 0xFF, 0xE0];
  data.setRange(0, header.length, header);
  return data;
}

Uint8List _webpBytes([int totalLength = 16]) {
  final data = Uint8List(totalLength);
  const riff = <int>[0x52, 0x49, 0x46, 0x46];
  const webp = <int>[0x57, 0x45, 0x42, 0x50];
  data.setRange(0, 4, riff);
  data.setRange(8, 12, webp);
  return data;
}

void main() {
  _defineValidationTests();
  _defineDesktopResolutionAndIsolationTests();
  _defineIoShaderProfileStoreTests();
  _defineFtermPreferencesShaderTests();
}

void _defineValidationTests() {
  group('Wallpaper and shader source validation', () {
    test('accepts valid PNG, JPEG, and WebP magic-byte headers', () {
      expect(() => validateWallpaperBytes(_pngBytes()), returnsNormally);
      expect(() => validateWallpaperBytes(_jpegBytes()), returnsNormally);
      expect(() => validateWallpaperBytes(_webpBytes()), returnsNormally);
      expect(
        () => validateWallpaperBytes(_pngBytes(maxWallpaperBytes)),
        returnsNormally,
      );
    });

    test('rejects empty, oversized (> 16 MiB), and invalid headers', () {
      expect(
        () => validateWallpaperBytes(Uint8List(0), pathOrKey: 'empty.png'),
        throwsA(
          isA<ShaderAssetException>().having(
            (e) => e.toString(),
            'toString',
            contains('empty.png'),
          ),
        ),
      );

      final oversized = _pngBytes(maxWallpaperBytes + 1);
      expect(
        () => validateWallpaperBytes(oversized),
        throwsA(
          isA<ShaderAssetException>().having(
            (e) => e.toString(),
            'toString',
            contains('16 MiB'),
          ),
        ),
      );

      for (final invalid in <Uint8List>[
        Uint8List.fromList(utf8.encode('GIF89a0000000000')),
        Uint8List.fromList(<int>[0x89, 0x50, 0x4E]),
        Uint8List.fromList(<int>[0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 1, 2]),
        Uint8List.fromList(<int>[0x00, 0x01, 0x02, 0x03, 0x04]),
      ]) {
        expect(
          () => validateWallpaperBytes(invalid),
          throwsA(isA<ShaderAssetException>()),
        );
      }
    });

    test('validates shader source size (<= 64 KiB UTF-8) and extensions', () {
      expect(isSupportedShaderFilename('crt.glsl'), isTrue);
      expect(isSupportedShaderFilename('glow.FRAG'), isTrue);
      expect(isSupportedShaderFilename('notes.txt'), isFalse);
      expect(isSupportedShaderFilename('no_ext'), isFalse);

      final atLimit = 'a' * maxShaderSourceBytes;
      expect(() => validateShaderSource(atLimit), returnsNormally);
      expect(
        () => validateShaderSourceBytes(Uint8List(maxShaderSourceBytes)),
        returnsNormally,
      );

      final overLimit = 'a' * (maxShaderSourceBytes + 1);
      expect(
        () => validateShaderSource(overLimit, pathOrKey: 'big.glsl'),
        throwsA(
          isA<ShaderAssetException>().having(
            (e) => e.pathOrKey,
            'pathOrKey',
            equals('big.glsl'),
          ),
        ),
      );
      expect(
        () => validateShaderSourceBytes(Uint8List(maxShaderSourceBytes + 1)),
        throwsA(isA<ShaderAssetException>()),
      );
    });
  });
}

void _defineDesktopResolutionAndIsolationTests() {
  group('Desktop shaders directory resolution and FLUTTER_TEST isolation', () {
    test('resolves POSIX and Windows shader directory paths', () {
      expect(
        io_store.resolveDesktopShadersDirectoryPath(
          environment: const {'HOME': '/Users/alice'},
          isWindows: false,
        ),
        equals('/Users/alice/.config/fterm/shaders'),
      );
      expect(
        io_store.resolveDesktopShadersDirectoryPath(
          environment: const {'HOME': '   '},
          isWindows: false,
        ),
        isNull,
      );
      expect(
        io_store.resolveDesktopShadersDirectoryPath(
          environment: const {'APPDATA': r'C:\Users\alice\AppData\Roaming'},
          isWindows: true,
        ),
        equals(r'C:\Users\alice\AppData\Roaming\fterm\shaders'),
      );
      expect(
        io_store.resolveDesktopShadersDirectoryPath(
          environment: const {'USERPROFILE': r'C:\Users\alice'},
          isWindows: true,
        ),
        equals(r'C:\Users\alice\AppData\Roaming\fterm\shaders'),
      );
      expect(
        io_store.resolveDesktopShadersDirectoryPath(
          environment: const {},
          isWindows: true,
        ),
        isNull,
      );
    });

    test('isolates under FLUTTER_TEST and when env is empty', () async {
      final noopDefault = createPlatformShaderProfileStore();
      expect(noopDefault.shadersDirectoryPath, isNull);
      expect(await noopDefault.listShaderFiles(), isEmpty);
      await expectLater(
        noopDefault.loadWallpaperBytes('wallpaper.png'),
        throwsA(isA<ShaderAssetException>()),
      );
      await expectLater(
        noopDefault.loadShaderSource('crt.glsl'),
        throwsA(isA<ShaderAssetException>()),
      );
      await noopDefault.saveShaderSource('crt.glsl', 'void mainImage() {}');
      await noopDefault.saveWallpaperBytes('bg.png', _pngBytes());
      expect(await noopDefault.watchShaderDirectory().toList(), isEmpty);
      noopDefault.dispose();

      final missingEnvStore = io_store.createPlatformShaderProfileStore(
        environment: const <String, String>{},
        isWindows: false,
      );
      expect(missingEnvStore.shadersDirectoryPath, isNull);

      final tempHome = await Directory.systemTemp.createTemp('fterm_shaders_');
      addTearDown(() => tempHome.delete(recursive: true));
      final liveStore = io_store.createPlatformShaderProfileStore(
        environment: <String, String>{'HOME': tempHome.path},
        isWindows: false,
      );
      addTearDown(liveStore.dispose);
      expect(
        liveStore.shadersDirectoryPath,
        equals(p.posix.join(tempHome.path, '.config', 'fterm', 'shaders')),
      );

      final overrideDir = Directory(p.join(tempHome.path, 'custom_shaders'));
      final overrideStore = io_store.createPlatformShaderProfileStore(
        shadersDirectoryOverride: overrideDir,
      );
      addTearDown(overrideStore.dispose);
      expect(overrideStore.shadersDirectoryPath, equals(overrideDir.path));
    });
  });
}

void _defineIoShaderProfileStoreTests() {
  group(
    'IoShaderProfileStore async I/O, symlink rejection, and watch debounce',
    () {
      late Directory tempDir;
      late Directory shadersDir;
      late io_store.IoShaderProfileStore store;

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp('fterm_shader_store_');
        shadersDir = Directory(p.join(tempDir.path, 'shaders'));
        store = io_store.IoShaderProfileStore(
          shadersDir,
          watchDebounce: const Duration(milliseconds: 150),
        );
      });

      tearDown(() async {
        store.dispose();
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      test('saves, lists, and loads .glsl/.frag shaders and wallpapers asynchronously', () async {
        expect(await store.listShaderFiles(), isEmpty);

        const glsl = 'void mainImage(out vec4 c, in vec2 f) { c = vec4(1.0); }';
        await store.saveShaderSource('z_glow.frag', glsl);
        await store.saveShaderSource('a_crt.glsl', glsl);
        await File(p.join(shadersDir.path, 'readme.txt'))
            .writeAsString('ignore');

        final listed = await store.listShaderFiles();
        expect(
          listed,
          equals(<String>[
            p.join(shadersDir.path, 'a_crt.glsl'),
            p.join(shadersDir.path, 'z_glow.frag'),
          ]),
        );

        expect(await store.loadShaderSource('a_crt.glsl'), equals(glsl));
        expect(
          await store.loadShaderSource(p.join(shadersDir.path, 'z_glow.frag')),
          equals(glsl),
        );

        final png = _pngBytes(64);
        await store.saveWallpaperBytes('bg.png', png);
        final loadedRelative = await store.loadWallpaperBytes(
          p.join(shadersDir.path, 'bg.png'),
        );
        expect(loadedRelative, equals(png));

        final absWallpaper = p.join(tempDir.path, 'wallpapers', 'hero.webp');
        final webp = _webpBytes(48);
        await store.saveWallpaperBytes(absWallpaper, webp);
        expect(await store.loadWallpaperBytes(absWallpaper), equals(webp));
      });

      test('rejects oversized files, invalid UTF-8, path traversal, and missing files', () async {
        await shadersDir.create(recursive: true);

        final hugeShader = File(p.join(shadersDir.path, 'huge.glsl'));
        await hugeShader.writeAsBytes(Uint8List(maxShaderSourceBytes + 1));
        await expectLater(
          store.loadShaderSource('huge.glsl'),
          throwsA(isA<ShaderAssetException>()),
        );

        final badUtf8 = File(p.join(shadersDir.path, 'bad_utf8.glsl'));
        await badUtf8.writeAsBytes(const <int>[0xFF, 0xFE, 0xFD]);
        await expectLater(
          store.loadShaderSource('bad_utf8.glsl'),
          throwsA(isA<ShaderAssetException>()),
        );

        final hugeWallpaper = File(p.join(tempDir.path, 'huge.png'));
        await hugeWallpaper.writeAsBytes(_pngBytes(maxWallpaperBytes + 1));
        await expectLater(
          store.loadWallpaperBytes(hugeWallpaper.path),
          throwsA(isA<ShaderAssetException>()),
        );

        await expectLater(
          store.loadShaderSource('missing.glsl'),
          throwsA(isA<ShaderAssetException>()),
        );
        await expectLater(
          store.loadWallpaperBytes('   '),
          throwsA(isA<ShaderAssetException>()),
        );
        await expectLater(
          store.saveShaderSource('../escape.glsl', 'void main() {}'),
          throwsA(isA<ShaderAssetException>()),
        );
        await expectLater(
          store.saveShaderSource('bad.txt', 'void main() {}'),
          throwsA(isA<ShaderAssetException>()),
        );
      });

      test(
        'rejects symlinked shader files, wallpapers, and shaders directory',
        () async {
          await shadersDir.create(recursive: true);
          final realShader = File(p.join(tempDir.path, 'real.glsl'));
          await realShader.writeAsString('void mainImage() {}');
          final linkShader = Link(p.join(shadersDir.path, 'linked.glsl'));
          await linkShader.create(realShader.path);

          await expectLater(
            store.loadShaderSource(linkShader.path),
            throwsA(isA<ShaderAssetException>()),
          );

          final realPng = File(p.join(tempDir.path, 'real.png'));
          await realPng.writeAsBytes(_pngBytes());
          final linkPng = Link(p.join(tempDir.path, 'linked.png'));
          await linkPng.create(realPng.path);
          await expectLater(
            store.loadWallpaperBytes(linkPng.path),
            throwsA(isA<ShaderAssetException>()),
          );

          final linkedDir = Link(p.join(tempDir.path, 'linked_shaders'));
          await linkedDir.create(shadersDir.path);
          final linkedStore = io_store.IoShaderProfileStore(
            Directory(linkedDir.path),
          );
          addTearDown(linkedStore.dispose);
          await expectLater(
            linkedStore.listShaderFiles(),
            throwsA(isA<ShaderAssetException>()),
          );
          await expectLater(
            linkedStore.saveShaderSource('ok.glsl', 'void main() {}'),
            throwsA(isA<ShaderAssetException>()),
          );
        },
      );

      test('coalesces rapid .glsl modifications into one debounced ShaderDirectoryChange', () async {
        await shadersDir.create(recursive: true);
        final events = <ShaderDirectoryChange>[];
        final firstEvent = Completer<ShaderDirectoryChange>();

        final sub = store.watchShaderDirectory().listen((change) {
          events.add(change);
          if (!firstEvent.isCompleted) {
            firstEvent.complete(change);
          }
        });
        addTearDown(sub.cancel);

        // Give the OS directory watcher a brief moment to attach.
        await Future<void>.delayed(const Duration(milliseconds: 60));

        final shaderFile = File(p.join(shadersDir.path, 'live.glsl'));
        final ignoredFile = File(p.join(shadersDir.path, 'ignore.txt'));
        await ignoredFile.writeAsString('not a shader');
        await shaderFile.writeAsString('// v1');
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await shaderFile.writeAsString('// v2');
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await shaderFile.writeAsString('// v3');

        final received = await firstEvent.future.timeout(
          const Duration(seconds: 3),
        );
        expect(received.paths, equals(<String>[shaderFile.path]));
        expect(received.timestamp.isUtc, isTrue);

        // Wait slightly beyond another debounce window to verify coalescing.
        await Future<void>.delayed(const Duration(milliseconds: 220));
        expect(events.length, equals(1));

        store.dispose();
        expect(await store.watchShaderDirectory().toList(), isEmpty);
      });
    },
  );
}

void _defineFtermPreferencesShaderTests() {
  group('FtermPreferences shader fields serialization and migration', () {
    test('migrates legacy JSON without shader fields to backward-compatible defaults', () {
      final legacyJson = jsonEncode(<String, Object?>{
        'audioMuted': true,
        'audioVolume': 0.5,
        'fontSize': 15.0,
      });

      final prefs = FtermPreferences.fromJsonString(legacyJson);
      expect(prefs.audioMuted, isTrue);
      expect(prefs.audioVolume, equals(0.5));
      expect(prefs.fontSize, equals(15.0));
      expect(prefs.backgroundImagePath, isNull);
      expect(prefs.backgroundShaderPaths, isEmpty);
      expect(prefs.foregroundShaderPaths, isEmpty);
      expect(prefs.shaderAnimationMode, equals(ShaderAnimationMode.focused));
      expect(prefs.shaderBackendOverride, isNull);
      expect(prefs.customShaderProfileJson, isNull);
    });

    test('round-trips all shader preference fields including shaderBackendOverride', () {
      const original = FtermPreferences(
        backgroundImagePath: '/home/user/wallpapers/nebula.png',
        backgroundShaderPaths: <String>['wallpaper_wave', 'bg_custom.glsl'],
        foregroundShaderPaths: <String>['crt_lottes', 'phosphor_glow'],
        shaderAnimationMode: ShaderAnimationMode.onActivity,
        shaderBackendOverride: ShaderBackendKind.disabled,
        customShaderProfileJson: '{"uParams0":[1.0,0.5,0.0,0.0]}',
      );

      final encoded = original.toJsonString();
      final decodedMap = jsonDecode(encoded) as Map<String, Object?>;
      expect(decodedMap['shaderAnimationMode'], equals('on_activity'));
      expect(decodedMap['shaderBackendOverride'], equals('disabled'));

      final restored = FtermPreferences.fromJsonString(encoded);
      expect(restored, equals(original));
      expect(restored.hashCode, equals(original.hashCode));

      for (final mode in ShaderAnimationMode.values) {
        final next = original.copyWith(shaderAnimationMode: mode);
        expect(
          FtermPreferences.fromJsonString(next.toJsonString())
              .shaderAnimationMode,
          equals(mode),
        );
      }

      for (final backend in ShaderBackendKind.values) {
        final next = original.copyWith(shaderBackendOverride: backend);
        expect(
          FtermPreferences.fromJsonString(next.toJsonString())
              .shaderBackendOverride,
          equals(backend),
        );
      }
    });

    test('supports copyWith clear flags, trimming, and equality checks', () {
      const base = FtermPreferences(
        backgroundImagePath: '/tmp/a.png',
        backgroundShaderPaths: <String>['a.glsl'],
        foregroundShaderPaths: <String>['b.glsl'],
        shaderAnimationMode: ShaderAnimationMode.always,
        shaderBackendOverride: ShaderBackendKind.flutterGpu,
        customShaderProfileJson: '{"v":1}',
      );

      final cleared = base.copyWith(
        clearBackgroundImagePath: true,
        backgroundShaderPaths: const <String>['  ', 'c.glsl '],
        foregroundShaderPaths: const <String>[],
        shaderAnimationMode: ShaderAnimationMode.staticOnly,
        clearShaderBackendOverride: true,
        clearCustomShaderProfileJson: true,
      );

      expect(cleared.backgroundImagePath, isNull);
      expect(cleared.backgroundShaderPaths, equals(<String>['c.glsl']));
      expect(cleared.foregroundShaderPaths, isEmpty);
      expect(
        cleared.shaderAnimationMode,
        equals(ShaderAnimationMode.staticOnly),
      );
      expect(cleared.shaderBackendOverride, isNull);
      expect(cleared.customShaderProfileJson, isNull);
      expect(cleared, isNot(equals(base)));

      final unknownBackend = FtermPreferences.fromJsonString(
        jsonEncode(<String, Object?>{
          'shaderAnimationMode': 'unknown_mode',
          'shaderBackendOverride': 'unknown_backend',
          'backgroundImagePath': '   ',
        }),
      );
      expect(
        unknownBackend.shaderAnimationMode,
        equals(ShaderAnimationMode.focused),
      );
      expect(unknownBackend.shaderBackendOverride, isNull);
      expect(unknownBackend.backgroundImagePath, isNull);
    });
  });
}
