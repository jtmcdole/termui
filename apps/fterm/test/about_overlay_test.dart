import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart'
    show LicenseEntry, LicenseEntryWithLineBreaks;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/about/about_models.dart';
import 'package:fterm/src/about/about_repository.dart';
import 'package:fterm/src/about/about_service.dart';
import 'package:fterm/src/about/about_service_io.dart';
import 'package:fterm/src/about/about_service_stub.dart';
import 'package:fterm/src/about/about_view_model.dart';
import 'package:fterm/src/about/fterm_svg_baker.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/file_drop_bridge.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/fterm_app.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/ui/fterm_overlays.dart';
import 'package:fterm/src/update/update_service.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:material_ui/material_ui.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart'
    show CastClientRepository, WsClientTransport;

import 'support/app_three_way_harness.dart';

const String _kPinnedTestVersion = '0.3.0';
final DateTime _kPinnedTestBuildDateUtc = DateTime.utc(2026, 11, 18, 3, 15);

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
    await _ensureMaterialIconsLoaded();
  });

  group('About models, SVG baking, services, and ViewModel', () {
    test('FtermBuildMetadata reads appBuildName, formats build dates and SDK labels', () {
      final compileTime = FtermBuildMetadata.compileTime(defineBuildDate: '');
      expect(compileTime.version, equals(kFtermBuildVersion));
      expect(compileTime.displayVersion, startsWith('v$kFtermBuildVersion'));
      expect(compileTime.formattedBuildDate, isNull);

      final withDateAndMeta = FtermBuildMetadata(
        version: '0.3.0',
        buildNumber: '42',
        buildDateUtc: DateTime.utc(2026, 11, 18, 3, 5),
        flutterVersion: '3.41.2',
        flutterChannel: 'stable',
        dartVersion: '3.11.0',
      );
      expect(withDateAndMeta.displayVersion, equals('v0.3.0+42'));
      expect(
        withDateAndMeta.formattedBuildDate,
        equals('2026-11-18 03:05 UTC'),
      );
      expect(
        withDateAndMeta.runtimeToolchainLabel,
        equals('Flutter 3.41.2 (stable) · Dart 3.11.0'),
      );

      final cleared = withDateAndMeta.copyWith(clearBuildDate: true);
      expect(cleared.formattedBuildDate, isNull);
      expect(tryParseBuildDateUtc('  '), isNull);
      expect(tryParseBuildDateUtc('not-a-date'), isNull);
      expect(
        tryParseBuildDateUtc('2026-11-18T03:15:30Z'),
        equals(DateTime.utc(2026, 11, 18, 3, 15, 30)),
      );
    });

    test('IoAboutService resolves FTERM_BUILD_DATE first, then async fterm exe mtime, else null', () async {
      const fromDefine = IoAboutService(
        defineBuildDate: '2026-11-18T04:12:00Z',
        resolvedExecutableOverride: '/usr/bin/flutter_tester',
      );
      expect(
        await fromDefine.resolveBuildDateUtc(),
        equals(DateTime.utc(2026, 11, 18, 4, 12)),
      );

      String? probedPath;
      final fromWindowsBinary = IoAboutService(
        defineBuildDate: '',
        resolvedExecutableOverride: r'C:\opt\fterm\fterm.exe',
        environmentOverride: const {},
        executableModifiedUtcReader: (path) async {
          probedPath = path;
          return DateTime.utc(2026, 11, 17, 20, 45);
        },
      );
      expect(
        await fromWindowsBinary.resolveBuildDateUtc(),
        equals(DateTime.utc(2026, 11, 17, 20, 45)),
      );
      expect(probedPath, equals(r'C:\opt\fterm\fterm.exe'));

      String? probedPosixPath;
      final fromPosixBinary = IoAboutService(
        defineBuildDate: '',
        resolvedExecutableOverride: '/opt/fterm/fterm',
        environmentOverride: const {},
        executableModifiedUtcReader: (path) async {
          probedPosixPath = path;
          return DateTime.utc(2026, 11, 17, 21, 0);
        },
      );
      expect(
        await fromPosixBinary.resolveBuildDateUtc(),
        equals(DateTime.utc(2026, 11, 17, 21, 0)),
      );
      expect(probedPosixPath, equals('/opt/fterm/fterm'));

      const ignoredTester = IoAboutService(
        defineBuildDate: '',
        resolvedExecutableOverride: '/sdk/flutter_tester',
        environmentOverride: {},
      );
      expect(await ignoredTester.resolveBuildDateUtc(), isNull);

      final realFileMissing = IoAboutService(
        defineBuildDate: '',
        resolvedExecutableOverride: Platform.isWindows
            ? r'Z:\nonexistent-path\fterm.exe'
            : '/nonexistent-fterm-dir/fterm',
        environmentOverride: const {},
      );
      expect(await realFileMissing.resolveBuildDateUtc(), isNull);

      const defaultInTest = IoAboutService(defineBuildDate: '');
      expect(await defaultInTest.resolveBuildDateUtc(), isNull);

      const webService = WebAboutService(
        defineBuildDate: '2026-11-18T06:00:00Z',
      );
      expect(
        webService.resolveCompileTimeMetadata().version,
        equals(kFtermBuildVersion),
      );
      expect(
        await webService.resolveBuildDateUtc(),
        equals(DateTime.utc(2026, 11, 18, 6, 0)),
      );

      final clearedRepo = AboutRepository(
        service: IoAboutService(
          defineBuildDate: '',
          compileTimeMetadataOverride: FtermBuildMetadata(
            version: '7.8.9',
            buildDateUtc: DateTime.utc(2026, 1, 1),
          ),
        ),
      );
      expect(clearedRepo.initialBuildMetadata().version, equals('7.8.9'));
      expect(
        (await clearedRepo.loadBuildMetadata()).formattedBuildDate,
        isNull,
      );
    });

    test('bakeVersionIntoFtermSvg stamps XML-escaped pill and FtermLogoScene parses web/favicon.svg', () async {
      final rawSvg = await rootBundle.loadString('web/favicon.svg');
      final baked = bakeVersionIntoFtermSvg(
        rawSvg,
        version: '0.3.0-rc.1+<dev>',
      );

      expect(baked, contains('id="ftermVersionBadge"'));
      expect(baked, contains('v0.3.0-rc.1+&lt;dev&gt;'));
      expect(baked, contains('</svg>'));
      expect(
        baked.indexOf('id="ftermVersionBadge"'),
        lessThan(baked.lastIndexOf('</g>')),
      );

      final scene = FtermLogoScene.parse(rawSvg);
      expect(scene.bgStops, hasLength(3));
      expect(scene.rimStops, hasLength(3));
      expect(scene.fStops, hasLength(2));
      expect(scene.gtStops, hasLength(3));
      expect(
        scene.fStemPath.computeMetrics().single.length,
        greaterThan(500.0),
      );
      expect(
        scene.fCrossbarPath.computeMetrics().single.length,
        closeTo(210.0, 0.5),
      );
      expect(
        scene.promptChevronPath.computeMetrics().single.length,
        greaterThan(400.0),
      );
    });

    test('AboutRepository deduplicates license blocks per package and prioritizes first-party & bundled fonts', () async {
      final service = _FakeAboutService(
        version: '9.4.2-rc.1',
        buildDateUtc: _kPinnedTestBuildDateUtc,
        licenseEntries: [
          const LicenseEntryWithLineBreaks(['zlib_extra'], 'Zlib text.'),
          const LicenseEntryWithLineBreaks([
            'MesloLGS NF',
          ], 'MesloLGS NF License.'),
          const LicenseEntryWithLineBreaks([
            'Cascadia Mono',
          ], 'SIL Open Font License 1.1'),
          const LicenseEntryWithLineBreaks(['fterm'], 'MIT License A'),
          const LicenseEntryWithLineBreaks(['fterm'], 'MIT License A'),
          const LicenseEntryWithLineBreaks(['alpha_pkg'], 'BSD-3'),
        ],
      );
      final vm = AboutViewModel(repository: AboutRepository(service: service));
      addTearDown(vm.dispose);

      await vm.ensureInitialized();
      await vm.ensureLicensesLoaded();

      expect(
        vm.filteredPackages.map((p) => p.packageName).toList(),
        equals([
          'fterm',
          'Cascadia Mono',
          'MesloLGS NF',
          'alpha_pkg',
          'zlib_extra',
        ]),
      );
      expect(vm.filteredPackages.first.noticeCount, equals(1));
      expect(vm.selectedPackageName, equals('fterm'));
      expect(vm.metadata.version, equals('9.4.2-rc.1'));
      expect(vm.metadata.displayVersion, equals('v9.4.2-rc.1'));
      expect(vm.metadata.formattedBuildDate, equals('2026-11-18 03:15 UTC'));
      expect(vm.versionedSvg, contains('v9.4.2-rc.1'));

      vm.setFilterQuery('mono');
      expect(
        vm.filteredPackages.map((p) => p.packageName),
        equals(['Cascadia Mono']),
      );
      expect(vm.selectedPackageName, equals('Cascadia Mono'));

      vm.setFilterQuery('');
      vm.selectPackage('alpha_pkg');
      expect(vm.selectedPackageName, equals('alpha_pkg'));
    });
  });

  group('FtermAboutOverlay & FtermLicensesOverlay widget flows', () {
    testWidgets(
      'opens About from Chrome, Settings, and Ctrl+\\ a; clicks GitHub link; browses/filters Licenses; Esc navigates back cleanly',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(960, 680));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final harness = AppThreeWayWsHarness();
        final pty = await tester.runAsync(
          () => harness.startCaster(id: 's1', title: 'about-shell'),
        );
        addTearDown(() => tester.runAsync(harness.dispose));

        final openedUrls = <Uri>[];
        FtermWorkspaceController? workspace;

        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(token: harness.token),
            channelFactory: harness.openClientChannel,
            settingsStorage: _MemorySettingsStorage(),
            aboutService: _FakeAboutService(
              buildDateUtc: _kPinnedTestBuildDateUtc,
            ),
            onOpenUrl: openedUrls.add,
            resizeDebounce: Duration.zero,
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await settleCastApp(tester);

        // 1. Open About via top chrome info button.
        await tester.tap(find.byKey(const ValueKey('fterm-about-button')));
        await settleCastApp(tester, cycles: 3);

        expect(workspace!.activeOverlay, equals(FtermOverlay.about));
        expect(
          find.byKey(const ValueKey('fterm-overlay-about')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('about-fterm-svg-logo')),
          findsOneWidget,
        );
        expect(find.text('v$_kPinnedTestVersion'), findsOneWidget);
        expect(find.text(kFtermMotto), findsOneWidget);
        expect(find.text('2026-11-18 03:15 UTC'), findsOneWidget);
        expect(find.text(kFtermCopyrightNotice), findsOneWidget);

        // 2. Click GitHub repository link.
        await tester.tap(find.byKey(const ValueKey('about-github-link')));
        await tester.pump();
        expect(openedUrls, equals([Uri.parse(kFtermRepoUrl)]));

        // 3. Open Open Source Licenses overlay and inspect bundled entries.
        await tester.tap(find.byKey(const ValueKey('about-open-licenses')));
        await settleCastApp(tester, cycles: 4);

        expect(workspace!.activeOverlay, equals(FtermOverlay.licenses));
        expect(
          find.byKey(const ValueKey('fterm-overlay-licenses')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('licenses-pkg-fterm')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('licenses-pkg-Cascadia Mono')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('licenses-pkg-MesloLGS NF')),
          findsOneWidget,
        );
        expect(
          find.textContaining('John Thomas McDole', findRichText: true),
          findsWidgets,
        );

        await tester.tap(
          find.byKey(const ValueKey('licenses-pkg-Cascadia Mono')),
        );
        await tester.pump();
        expect(
          find.textContaining('SIL OPEN FONT LICENSE', findRichText: true),
          findsWidgets,
        );

        // Filter packages via search bar.
        await tester.enterText(
          find.byKey(const ValueKey('licenses-search-field')),
          'meslo',
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('licenses-pkg-MesloLGS NF')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('licenses-pkg-Cascadia Mono')),
          findsNothing,
        );

        // Empty filter match shows clear state without crashing.
        await tester.enterText(
          find.byKey(const ValueKey('licenses-search-field')),
          'does-not-exist-xyz',
        );
        await tester.pump();
        expect(find.text('No matching packages'), findsOneWidget);

        // Esc in Licenses returns to About; second Esc closes to workspace.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(workspace!.activeOverlay, equals(FtermOverlay.about));

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(workspace!.activeOverlay, equals(FtermOverlay.none));

        // 4. Open About from Settings overlay's About button, then verify
        // tapping the dark backdrop scrim dismisses About (Blender/GIMP style).
        workspace!.setOverlay(FtermOverlay.settings);
        await tester.pump();
        await tester.ensureVisible(
          find.byKey(const ValueKey('settings-open-about')),
        );
        await tester.tap(find.byKey(const ValueKey('settings-open-about')));
        await settleCastApp(tester, cycles: 2);
        expect(workspace!.activeOverlay, equals(FtermOverlay.about));

        await tester.tapAt(const Offset(12, 12));
        await tester.pump();
        expect(workspace!.activeOverlay, equals(FtermOverlay.none));

        // Clicking floating close button on splash hero also dismisses About.
        workspace!.setOverlay(FtermOverlay.about);
        await settleCastApp(tester, cycles: 2);
        await tester.tap(find.byKey(const ValueKey('about-close-button')));
        await tester.pump();
        expect(workspace!.activeOverlay, equals(FtermOverlay.none));

        // 5. Verify plain Ctrl+A reaches PTY (does not hijack shell chord) while
        // leader chord Ctrl+\ then a opens About.
        pty!.writtenInputs.clear();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(workspace!.activeOverlay, equals(FtermOverlay.none));
        expect(pty.writtenInputs.map((b) => utf8.decode(b)), contains('\x01'));

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.backslash);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.backslash);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(workspace!.isLeaderArmed, isTrue);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
        await settleCastApp(tester, cycles: 2);
        expect(workspace!.activeOverlay, equals(FtermOverlay.about));
      },
    );

    testWidgets(
      'hides Build Date row when unavailable and shows loading/error states in Licenses',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(720, 580));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final licenseCompleter = Completer<void>();
        final ws = _createStandaloneWorkspace(
          aboutService: _FakeAboutService(
            buildDateUtc: null,
            loadLicensesOverride: () async* {
              await licenseCompleter.future;
              throw StateError('corrupt bundle');
            },
          ),
        );
        addTearDown(() => tester.runAsync(ws.dispose));

        ws.setOverlay(FtermOverlay.about);
        await tester.pumpWidget(_buildOverlayTestHarness(ws));
        await settleCastApp(tester, cycles: 2);

        expect(
          find.byKey(const ValueKey('about-version-value')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('about-build-date-value')),
          findsNothing,
        );

        await tester.tap(find.byKey(const ValueKey('about-open-licenses')));
        await tester.pump();
        expect(find.text('Loading license notices...'), findsOneWidget);

        licenseCompleter.complete();
        await settleCastApp(tester, cycles: 2);
        expect(find.textContaining('Unable to load licenses:'), findsOneWidget);
      },
    );
  });

  group(
    'FtermAboutOverlay visual golden',
    skip: !Platform.isLinux
        ? 'Flutter pixel goldens run on Linux only (see apps/fterm/README.md).'
        : null,
    () {
      testWidgets(
        'matches golden with baked FTerm SVG version pill, metadata, repo link, and licenses CTA',
        (tester) async {
          tester.view.physicalSize = const Size(680, 560);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final ws = _createStandaloneWorkspace(
            aboutService: _FakeAboutService(
              version: _kPinnedTestVersion,
              buildDateUtc: _kPinnedTestBuildDateUtc,
            ),
          );
          addTearDown(() => tester.runAsync(ws.dispose));

          ws.setOverlay(FtermOverlay.about);
          await tester.pumpWidget(_buildOverlayTestHarness(ws));
          await tester.runAsync(() async {
            await ws.aboutViewModel.ensureInitialized();
          });
          await tester.pump(const Duration(milliseconds: 50));

          expect(ws.aboutViewModel.metadata.displayVersion, equals('v0.3.0'));
          expect(
            ws.aboutViewModel.metadata.formattedBuildDate,
            equals('2026-11-18 03:15 UTC'),
          );
          expect(
            ws.aboutViewModel.metadata.runtimeToolchainLabel,
            equals('Flutter 3.41.0 (stable) · Dart 3.11.0'),
          );

          await expectLater(
            find.byType(FtermOverlayHost),
            matchesGoldenFile('goldens/fterm_about_overlay.png'),
          );
        },
      );
    },
  );
}

FtermWorkspaceController _createStandaloneWorkspace({
  required AboutService aboutService,
}) {
  final transport = WsClientTransport(
    serverUri: Uri.parse('ws://127.0.0.1:9/v1/client'),
  );
  return FtermWorkspaceController(
    launchConfig: CastLaunchConfig(),
    repository: CastClientRepository(transport: transport),
    localHostDriver: createLocalHostDriver(),
    audioController: FtermAudioController(),
    storage: _MemorySettingsStorage(),
    updateService: createPlatformUpdateService(),
    aboutService: aboutService,
  );
}

Widget _buildOverlayTestHarness(
  FtermWorkspaceController workspace, {
  UrlOpener? onOpenUrl,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  themeMode: ThemeMode.dark,
  darkTheme: ThemeData(
    brightness: Brightness.dark,
    fontFamily: castPrimaryFontFamily,
    fontFamilyFallback: castFallbackFontFamilies,
  ),
  home: Scaffold(
    backgroundColor: Color(workspace.activeTerminalTheme.background.argb),
    body: ListenableBuilder(
      listenable: workspace.chromeNotifier,
      builder: (_, _) => FtermOverlayHost(
        workspace: workspace,
        onOpenUrl: onOpenUrl ?? (_) {},
        isWeb: true,
      ),
    ),
  ),
);

final class _FakeAboutService implements AboutService {
  final String version;
  final DateTime? buildDateUtc;
  final List<LicenseEntry>? licenseEntries;
  final Stream<LicenseEntry> Function()? loadLicensesOverride;

  const _FakeAboutService({
    this.version = _kPinnedTestVersion,
    required this.buildDateUtc,
    this.licenseEntries,
    this.loadLicensesOverride,
  });

  @override
  FtermBuildMetadata resolveCompileTimeMetadata() => FtermBuildMetadata(
    version: version,
    flutterVersion: '3.41.0',
    flutterChannel: 'stable',
    dartVersion: '3.11.0',
  );

  @override
  Future<DateTime?> resolveBuildDateUtc() async => buildDateUtc;

  @override
  Future<String> loadLogoSvgTemplate() =>
      rootBundle.loadString('web/favicon.svg');

  @override
  Stream<LicenseEntry> readLicenseEntries() async* {
    if (loadLicensesOverride case final custom?) {
      yield* custom();
      return;
    }
    if (licenseEntries case final explicit?) {
      for (final entry in explicit) {
        yield entry;
      }
      return;
    }
    ensureFtermLicensesRegistered();
    yield* const IoAboutService().readLicenseEntries();
  }
}

final class _MemorySettingsStorage implements SettingsStorage {
  final Map<String, String> _values = {};

  @override
  String? getItem(String key) => _values[key];

  @override
  void setItem(String key, String value) {
    _values[key] = value;
  }
}

Future<void> _ensureMaterialIconsLoaded() async {
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 6; i++) {
    for (final relative in const [
      'material_fonts/MaterialIcons-Regular.otf',
      'artifacts/material_fonts/MaterialIcons-Regular.otf',
    ]) {
      final candidate = File('${dir.path}${Platform.pathSeparator}$relative');
      if (candidate.existsSync()) {
        final bytes = await candidate.readAsBytes();
        final loader = FontLoader('MaterialIcons')
          ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
        await loader.load();
        return;
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
}
