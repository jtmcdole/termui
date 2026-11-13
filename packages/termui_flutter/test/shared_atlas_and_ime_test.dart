import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/color.dart' as tui_color;
import 'package:termui/ui/style.dart';
import 'package:termui/ui/terminal_palette.dart';
import 'package:termui_flutter/src/rendering/painter.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/terminal_surface.dart'
    show TerminalSurfaceState;
import 'package:termui_flutter/termui_flutter.dart';

final class _FakeTerminalService implements TerminalService {
  final List<String> savedFiles = [];

  @override
  Future<String?> saveScreenshot(String basename, Uint8List bytes) async {
    savedFiles.add(basename);
    return basename;
  }

  @override
  Future<void> setClipboard(String text) async {}

  @override
  Future<String?> getClipboard() async => 'clip';

  @override
  Future<bool> openUrl(String url) async => true;
}

Future<void> _sendDeltas(
  WidgetTester tester,
  List<Map<String, Object?>> deltas,
) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        SystemChannels.textInput.name,
        SystemChannels.textInput.codec.encodeMethodCall(
          MethodCall('TextInputClient.updateEditingStateWithDeltas', <Object?>[
            -1,
            <String, Object?>{'deltas': deltas},
          ]),
        ),
        (_) {},
      );
  await tester.pump();
}

Map<String, Object?> _deltaPayload({
  required String oldText,
  required int start,
  required int end,
  required String deltaText,
  required int selectionBase,
  required int selectionExtent,
  int composingBase = -1,
  int composingExtent = -1,
}) => <String, Object?>{
  'oldText': oldText,
  'deltaStart': start,
  'deltaEnd': end,
  'deltaText': deltaText,
  'selectionBase': selectionBase,
  'selectionExtent': selectionExtent,
  'selectionAffinity': 'TextAffinity.downstream',
  'selectionIsDirectional': false,
  'composingBase': composingBase,
  'composingExtent': composingExtent,
};

Future<void> _pumpUntilSurfaceReady(WidgetTester tester) async {
  for (var i = 0; i < 30 && find.byType(CustomPaint).evaluate().isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Shared GlyphAtlasController & TerminalSurface', () {
    testWidgets(
      '4 simultaneous TerminalSurface panes share 1 GlyphAtlas and defer disposal post-frame on resize & glyph bake',
      _testFourPanesSharedAtlas,
    );
    testWidgets(
      'TerminalSurface mounts and saves screenshots without a Scaffold or MaterialApp',
      _testMountWithoutScaffold,
    );
    test(
      'GlyphAtlasController bounds fallback painter cache at 256 entries',
      _testFallbackCacheCap,
    );
    testWidgets(
      'shared-atlas pane theme and terminal fontSize changes preserve sibling caches and atlas size',
      _testSharedAtlasIsolationAcrossPanes,
    );
    testWidgets(
      'GlyphAtlasController coalesces multiple requestMissingStyledGlyphs calls into one atlas upload',
      _testCoalescedMissingStyledGlyphs,
    );
    testWidgets(
      'GlyphAtlasController does not overwrite recreated atlas with stale addStyledGlyphs batch',
      _testConcurrentRecreateDoesNotOverwriteAtlas,
    );
  });

  group('Clamped viewport dimming & pre-edit overlay', () {
    test(
      'TuiAtlasPainter dims cells outside activePtyCols/activePtyRows and underlines composingText',
      _testClampedDimmingAndComposingOverlay,
    );
    test(
      'TuiAtlasPainter renders transient fallback glyph on fallbackPainters cache miss',
      _testTransientFallbackGlyphOnCacheMiss,
    );
  });

  group('TerminalImeClient & Focus.onKeyEvent 3-rule arbitration', () {
    testWidgets(
      'emits printable keys once via DeltaTextInputClient, suppresses duplicates, and handles macOS Option dead-keys',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      _testMacOsDeadKeyAndKittyArbitration,
    );
    testWidgets(
      'supports macosOptionAsAlt: true and NonTextUpdate / cancelled IME composition',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      _testMacOsOptionAsAltAndNonTextCommit,
    );
    testWidgets(
      'handles functional keys, Ctrl+*/Meta+*, and Linux Alt+* in Focus while routing Shift-only through IME',
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
      _testLinuxAltAndFunctionalKeys,
    );
    testWidgets(
      'fast unmodified printable key immediately after Ctrl+E or Alt+E is not swallowed',
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
      _testFastPrintableAfterCtrlAndAlt,
    );
  });
}

Future<void> _testFourPanesSharedAtlas(WidgetTester tester) async {
  final atlasController = GlyphAtlasController(
    fontSize: 13.0,
    fontFamily: 'Roboto Mono',
  );
  addTearDown(atlasController.dispose);

  final buffers = List<Buffer>.generate(4, (i) {
    return Buffer(12, 4)..writeString(0, 0, 'Pane $i', Style.empty);
  });

  await tester.runAsync<void>(() async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 800,
          height: 600,
          child: Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: TerminalSurface(
                        atlasController: atlasController,
                        buffer: buffers[0],
                      ),
                    ),
                    Expanded(
                      child: TerminalSurface(
                        atlasController: atlasController,
                        buffer: buffers[1],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: TerminalSurface(
                        atlasController: atlasController,
                        buffer: buffers[2],
                      ),
                    ),
                    Expanded(
                      child: TerminalSurface(
                        atlasController: atlasController,
                        buffer: buffers[3],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    for (var i = 0; i < 30 && atlasController.atlas == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  });
  await tester.pumpAndSettle();

  expect(atlasController.atlas, isNotNull);
  expect(atlasController.debugCreatedAtlasCount, equals(1));
  final initialAtlas = atlasController.atlas!;

  final painters = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((w) => w.painter! as TuiAtlasPainter)
      .toList();
  expect(painters.length, equals(4));
  for (final painter in painters) {
    expect(identical(painter.atlas, initialAtlas), isTrue);
  }

  var observedDuringNotify = false;
  void checkMidFrame() {
    if (!identical(atlasController.atlas, initialAtlas)) {
      observedDuringNotify = true;
      expect(initialAtlas.isDisposed, isFalse);
    }
  }

  atlasController.addListener(checkMidFrame);
  await tester.runAsync<void>(() async {
    await atlasController.setFontSize(18.0);
  });
  expect(observedDuringNotify, isTrue);
  expect(initialAtlas.isDisposed, isFalse);
  expect(atlasController.debugPendingAtlasDisposalCount, equals(1));

  await tester.pumpAndSettle();
  atlasController.removeListener(checkMidFrame);

  expect(tester.takeException(), isNull);
  expect(initialAtlas.isDisposed, isTrue);
  expect(atlasController.debugCreatedAtlasCount, equals(2));
  expect(atlasController.debugDisposedAtlasCount, equals(1));

  final resizedAtlas = atlasController.atlas!;
  final updatedPainters = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((w) => w.painter! as TuiAtlasPainter)
      .toList();
  for (final painter in updatedPainters) {
    expect(identical(painter.atlas, resizedAtlas), isTrue);
  }

  await tester.runAsync<void>(() async {
    atlasController.requestMissingStyledGlyphs(const [
      ('Ψ', GlyphStyleVariant.regular),
    ]);
    for (
      var i = 0;
      i < 30 && identical(atlasController.atlas, resizedAtlas);
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
  await tester.pumpAndSettle();

  expect(tester.takeException(), isNull);
  expect(resizedAtlas.isDisposed, isTrue);
  expect(atlasController.atlas!.rectFor('Ψ'), isNotNull);
}

Future<void> _testMountWithoutScaffold(WidgetTester tester) async {
  final service = _FakeTerminalService();
  final notices = <String>[];
  final buffer = Buffer(20, 6)..writeString(0, 0, 'No Scaffold', Style.empty);

  await tester.runAsync<void>(() async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 320,
          height: 200,
          child: TerminalSurface(
            buffer: buffer,
            service: service,
            onStatusNotice: (msg, {bool isError = false}) {
              notices.add(msg);
            },
          ),
        ),
      ),
    );
    await _pumpUntilSurfaceReady(tester);
  });
  await tester.pumpAndSettle();

  expect(find.byType(CustomPaint), findsOneWidget);

  final surfaceState = tester.state<TerminalSurfaceState>(
    find.byType(TerminalSurface),
  );
  await tester.runAsync<void>(() => surfaceState.takeScreenshot());
  await tester.pump();

  expect(tester.takeException(), isNull);
  expect(service.savedFiles.length, greaterThanOrEqualTo(3));
  expect(notices.single, startsWith('Saved: '));

  notices.clear();
  await tester.pumpWidget(
    WidgetsApp(
      color: const ui.Color(0xFF000000),
      pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
        settings: settings,
        pageBuilder: (context, _, _) => builder(context),
      ),
      home: SizedBox(
        width: 320,
        height: 200,
        child: TerminalSurface(
          buffer: buffer,
          service: service,
          onStatusNotice: (msg, {bool isError = false}) {
            notices.add(msg);
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final matSurfaceState = tester.state<TerminalSurfaceState>(
    find.byType(TerminalSurface),
  );
  await tester.runAsync<void>(() => matSurfaceState.takeScreenshot());
  await tester.pump();

  expect(tester.takeException(), isNull);
  expect(notices.single, startsWith('Saved: '));
}

Future<void> _testFallbackCacheCap() async {
  final controller = GlyphAtlasController(
    fontSize: 13.0,
    fontFamily: 'Roboto Mono',
  );
  addTearDown(controller.dispose);
  await controller.ensureInitialized();

  final buf = Buffer(300, 1);
  for (var i = 0; i < 300; i++) {
    buf.setCharacter(i, 0, String.fromCharCode(0x0400 + i));
  }
  controller.ensureFallbackPaintersForBuffer(
    buf,
    defaultForegroundArgb: 0xFFFFFFFF,
    defaultBackgroundArgb: 0xFF000000,
    faintOpacity: 0.55,
    palette: TerminalColorTheme.termuiDark,
  );
  expect(
    controller.fallbackPainters.length,
    equals(GlyphAtlasController.maxFallbackPainters),
  );
  // First 256 unbaked glyphs were cached; index 256 (\u0500) was deferred by the cap.
  expect(controller.fallbackPainters.keys.any((k) => k.$1 == '\u0400'), isTrue);
  expect(
    controller.fallbackPainters.keys.any((k) => k.$1 == '\u0500'),
    isFalse,
  );

  // Second scan caches the previously skipped \u0500 without losing the cache bound.
  controller.ensureFallbackPaintersForBuffer(
    buf,
    defaultForegroundArgb: 0xFFFFFFFF,
    defaultBackgroundArgb: 0xFF000000,
    faintOpacity: 0.55,
    palette: TerminalColorTheme.termuiDark,
  );
  expect(controller.fallbackPainters.keys.any((k) => k.$1 == '\u0500'), isTrue);
  expect(
    controller.fallbackPainters.length,
    equals(GlyphAtlasController.maxFallbackPainters),
  );
}

Future<void> _testClampedDimmingAndComposingOverlay() async {
  final atlas = await GlyphAtlasGenerator.generate(
    fontSize: 16.0,
    fontFamily: 'Roboto Mono',
  );
  addTearDown(atlas.image.dispose);

  final buffer = Buffer(10, 4);
  for (var y = 0; y < 4; y++) {
    for (var x = 0; x < 10; x++) {
      buffer.writeString(
        x,
        y,
        ' ',
        const Style(background: tui_color.Color(240, 240, 240)),
      );
    }
  }

  final w = (10 * atlas.cellWidth).ceil();
  final h = (4 * atlas.cellHeight).ceil();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  TuiAtlasPainter(
    buffer: buffer,
    atlas: atlas,
    fontFamily: 'Roboto Mono',
    fallbackPainters: const {},
    onMissingGlyphs: null,
    defaultForegroundArgb: 0xFF00FF00,
    defaultBackgroundArgb: 0xFF101010,
    activePtyCols: 5,
    activePtyRows: 2,
    composingText: 'é',
    cursorCol: 2,
    cursorRow: 1,
  ).paint(canvas, Size(w.toDouble(), h.toDouble()));

  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  picture.dispose();
  addTearDown(image.dispose);
  final rgba = (await image.toByteData())!.buffer.asUint8List();

  (int, int, int) sampleCellCenter(int col, int row) {
    final sx = ((col + 0.5) * atlas.cellWidth).floor().clamp(0, w - 1);
    final sy = ((row + 0.5) * atlas.cellHeight).floor().clamp(0, h - 1);
    final idx = (sy * w + sx) * 4;
    return (rgba[idx], rgba[idx + 1], rgba[idx + 2]);
  }

  expect(sampleCellCenter(1, 0), equals((240, 240, 240)));

  final rightOut = sampleCellCenter(7, 0);
  final bottomOut = sampleCellCenter(1, 3);
  expect(rightOut.$1, lessThan(160));
  expect(bottomOut.$1, lessThan(160));

  final x0 = (2 * atlas.cellWidth).floor();
  final x1 = (3 * atlas.cellWidth).ceil().clamp(0, w);
  final yStart = (1 * atlas.cellHeight + atlas.cellHeight * 0.7).floor();
  final yEnd = (2 * atlas.cellHeight).ceil().clamp(0, h);
  var foundGreenUnderline = false;
  for (var y = yStart; y < yEnd; y++) {
    for (var x = x0; x < x1; x++) {
      final idx = (y * w + x) * 4;
      if (rgba[idx] == 0 && rgba[idx + 1] > 200 && rgba[idx + 2] == 0) {
        foundGreenUnderline = true;
      }
    }
  }
  expect(foundGreenUnderline, isTrue);
}

Future<void> _testMacOsDeadKeyAndKittyArbitration(WidgetTester tester) async {
  final terminal = FlutterTerminal();
  addTearDown(terminal.dispose);
  final events = <term.InputEvent>[];
  final sub = terminal.events.listen(events.add);
  addTearDown(sub.cancel);

  final imeClient = TerminalImeClient();
  addTearDown(imeClient.dispose);

  await tester.runAsync<void>(() async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 480,
          height: 320,
          child: TerminalSurface(
            terminal: terminal,
            imeClient: imeClient,
            buffer: Buffer(40, 12),
            activePtySize: const (30, 10),
            cursorPosition: const (col: 4, row: 2),
          ),
        ),
      ),
    );
    await _pumpUntilSurfaceReady(tester);
  });
  await tester.pumpAndSettle();

  expect(imeClient.isAttached, isTrue);
  expect(
    tester.testTextInput.log.any(
      (m) => m.method == 'TextInput.setEditableSizeAndTransform',
    ),
    isTrue,
  );
  expect(
    tester.testTextInput.log.any(
      (m) => m.method == 'TextInput.setMarkedTextRect',
    ),
    isTrue,
  );

  // 1. Standard mode printable key 'a': Focus ignores hardware key, IME emits once.
  await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
  await tester.pump();
  expect(events, isEmpty);

  await _sendDeltas(tester, [
    _deltaPayload(
      oldText: '',
      start: 0,
      end: 0,
      deltaText: 'a',
      selectionBase: 1,
      selectionExtent: 1,
    ),
  ]);
  expect(events.whereType<term.KeyEvent>().toList(), [
    const term.KeyEvent('a', term.KeyType.character),
  ]);

  // 2. Functional Enter handled in Focus, duplicate performAction/delta suppressed.
  events.clear();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump();
  await tester.testTextInput.receiveAction(TextInputAction.newline);
  await _sendDeltas(tester, [
    _deltaPayload(
      oldText: '',
      start: 0,
      end: 0,
      deltaText: '\n',
      selectionBase: 1,
      selectionExtent: 1,
    ),
  ]);
  expect(events.whereType<term.KeyEvent>().toList(), [
    const term.KeyEvent('\n', term.KeyType.enter),
  ]);

  // 3. macOS Option+e e -> é dead-key composition when macosOptionAsAlt == false.
  events.clear();
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.pump();
  expect(events, isEmpty);

  await _sendDeltas(tester, [
    _deltaPayload(
      oldText: '',
      start: 0,
      end: 0,
      deltaText: '´',
      selectionBase: 1,
      selectionExtent: 1,
      composingBase: 0,
      composingExtent: 1,
    ),
  ]);
  expect(imeClient.isComposing, isTrue);
  expect(imeClient.composingText, equals('´'));
  expect(events, isEmpty);

  final composingPainter =
      tester.widget<CustomPaint>(find.byType(CustomPaint)).painter!
          as TuiAtlasPainter;
  expect(composingPainter.composingText, equals('´'));
  expect(composingPainter.cursorCol, equals(4));
  expect(composingPainter.cursorRow, equals(2));

  // 4. Rule (a): While composing, Enter/Escape/Backspace/Arrows are ignored by Focus.
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
  await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
  await tester.pump();
  expect(events, isEmpty);

  await _sendDeltas(tester, [
    _deltaPayload(
      oldText: '´',
      start: 0,
      end: 1,
      deltaText: 'é',
      selectionBase: 1,
      selectionExtent: 1,
    ),
  ]);
  expect(imeClient.isComposing, isFalse);
  expect(imeClient.composingText, isEmpty);
  expect(events.whereType<term.KeyEvent>().toList(), [
    const term.KeyEvent('é', term.KeyType.character),
  ]);

  // 5. Rule (c): Kitty CSI u mode claims press/repeat/release and suppresses IME insertion.
  events.clear();
  terminal.backend.write('\x1b[>10u');
  await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA, character: 'a');
  await _sendDeltas(tester, [
    _deltaPayload(
      oldText: '',
      start: 0,
      end: 0,
      deltaText: 'a',
      selectionBase: 1,
      selectionExtent: 1,
    ),
  ]);
  await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyA, character: 'a');
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
  await tester.pump();

  expect(
    events.whereType<term.KeyEvent>().map((e) => (e.key, e.eventType)).toList(),
    equals([
      ('a', term.KeyEventType.press),
      ('a', term.KeyEventType.repeat),
      ('a', term.KeyEventType.release),
    ]),
  );
}

Future<void> _testMacOsOptionAsAltAndNonTextCommit(WidgetTester tester) async {
  final committedStrings = <String>[];
  final keyEvents = <term.KeyEvent>[];
  final imeClient = TerminalImeClient(
    macosOptionAsAlt: true,
    onKeyEvent: keyEvents.add,
    onTextInput: committedStrings.add,
  );
  addTearDown(imeClient.dispose);

  await tester.runAsync<void>(() async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 320,
          height: 200,
          child: TerminalSurface(
            imeClient: imeClient,
            macosOptionAsAlt: true,
            buffer: Buffer(20, 8),
            onInputEvent: (e) {
              if (e is term.KeyEvent) keyEvents.add(e);
            },
            onTextInput: committedStrings.add,
          ),
        ),
      ),
    );
    await _pumpUntilSurfaceReady(tester);
  });
  await tester.pumpAndSettle();

  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.pump();
  expect(keyEvents, [
    const term.KeyEvent(
      'e',
      term.KeyType.character,
      modifiers: {term.Modifier.alt},
    ),
  ]);

  await _sendDeltas(tester, [
    _deltaPayload(
      oldText: '',
      start: 0,
      end: 0,
      deltaText: 'nihao',
      selectionBase: 5,
      selectionExtent: 5,
      composingBase: 0,
      composingExtent: 5,
    ),
  ]);
  expect(imeClient.isComposing, isTrue);
  expect(committedStrings, isEmpty);

  await _sendDeltas(tester, [
    _deltaPayload(
      oldText: 'nihao',
      start: -1,
      end: -1,
      deltaText: '',
      selectionBase: 5,
      selectionExtent: 5,
    ),
  ]);
  expect(imeClient.isComposing, isFalse);
  expect(committedStrings, equals(['nihao']));

  committedStrings.clear();
  await _sendDeltas(tester, [
    _deltaPayload(
      oldText: '',
      start: 0,
      end: 0,
      deltaText: 'wo',
      selectionBase: 2,
      selectionExtent: 2,
      composingBase: 0,
      composingExtent: 2,
    ),
  ]);
  await _sendDeltas(tester, [
    _deltaPayload(
      oldText: 'wo',
      start: 0,
      end: 2,
      deltaText: '',
      selectionBase: 0,
      selectionExtent: 0,
    ),
  ]);
  expect(imeClient.isComposing, isFalse);
  expect(committedStrings, isEmpty);
}

Future<void> _testLinuxAltAndFunctionalKeys(WidgetTester tester) async {
  final keyEvents = <term.KeyEvent>[];
  final imeClient = TerminalImeClient(onKeyEvent: keyEvents.add);
  addTearDown(imeClient.dispose);

  await tester.runAsync<void>(() async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 320,
          height: 200,
          child: TerminalSurface(
            imeClient: imeClient,
            buffer: Buffer(20, 8),
            enableHostShortcuts: false,
            onInputEvent: (e) {
              if (e is term.KeyEvent) keyEvents.add(e);
            },
          ),
        ),
      ),
    );
    await _pumpUntilSurfaceReady(tester);
  });
  await tester.pumpAndSettle();

  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pump();
  expect(keyEvents, isEmpty);

  await _sendDeltas(tester, [
    _deltaPayload(
      oldText: '',
      start: 0,
      end: 0,
      deltaText: 'A',
      selectionBase: 1,
      selectionExtent: 1,
    ),
  ]);
  expect(keyEvents, [const term.KeyEvent('A', term.KeyType.character)]);

  keyEvents.clear();
  for (final key in const [
    LogicalKeyboardKey.backspace,
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.home,
    LogicalKeyboardKey.end,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown,
    LogicalKeyboardKey.insert,
    LogicalKeyboardKey.delete,
    LogicalKeyboardKey.f1,
    LogicalKeyboardKey.f12,
  ]) {
    await tester.sendKeyEvent(key);
  }
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();

  expect(keyEvents.map((e) => e.type).toList(), [
    term.KeyType.backspace,
    term.KeyType.tab,
    term.KeyType.escape,
    term.KeyType.up,
    term.KeyType.home,
    term.KeyType.end,
    term.KeyType.pageUp,
    term.KeyType.pageDown,
    term.KeyType.insert,
    term.KeyType.delete,
    term.KeyType.f1,
    term.KeyType.f12,
    term.KeyType.character,
    term.KeyType.character,
  ]);
  expect(
    keyEvents[12],
    const term.KeyEvent(
      'x',
      term.KeyType.character,
      modifiers: {term.Modifier.alt},
    ),
  );
  expect(
    keyEvents[13],
    const term.KeyEvent(
      'c',
      term.KeyType.character,
      modifiers: {term.Modifier.control},
    ),
  );
}

Future<void> _testFastPrintableAfterCtrlAndAlt(WidgetTester tester) async {
  final keyEvents = <term.KeyEvent>[];
  final committed = <String>[];
  final imeClient = TerminalImeClient(
    onKeyEvent: keyEvents.add,
    onTextInput: committed.add,
  );
  addTearDown(imeClient.dispose);

  await tester.runAsync<void>(() async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 320,
          height: 200,
          child: TerminalSurface(
            imeClient: imeClient,
            buffer: Buffer(20, 8),
            enableHostShortcuts: false,
            onInputEvent: (e) {
              if (e is term.KeyEvent) keyEvents.add(e);
            },
            onTextInput: committed.add,
          ),
        ),
      ),
    );
    await _pumpUntilSurfaceReady(tester);
  });
  await tester.pumpAndSettle();

  // Ctrl+E immediately followed (<100 ms) by unmodified 'e'.
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
  await _sendDeltas(tester, [
    _deltaPayload(
      oldText: '',
      start: 0,
      end: 0,
      deltaText: 'e',
      selectionBase: 1,
      selectionExtent: 1,
    ),
  ]);
  expect(keyEvents, [
    const term.KeyEvent(
      'e',
      term.KeyType.character,
      modifiers: {term.Modifier.control},
    ),
  ]);
  expect(committed, ['e']);

  // Alt+E immediately followed (<100 ms) by unmodified 'e'.
  keyEvents.clear();
  committed.clear();
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
  await _sendDeltas(tester, [
    _deltaPayload(
      oldText: '',
      start: 0,
      end: 0,
      deltaText: 'e',
      selectionBase: 1,
      selectionExtent: 1,
    ),
  ]);
  expect(keyEvents, [
    const term.KeyEvent(
      'e',
      term.KeyType.character,
      modifiers: {term.Modifier.alt},
    ),
  ]);
  expect(committed, ['e']);
}

Future<void> _testSharedAtlasIsolationAcrossPanes(WidgetTester tester) async {
  final atlasController = GlyphAtlasController(
    fontSize: 13.0,
    fontFamily: 'Roboto Mono',
  );
  addTearDown(atlasController.dispose);

  final terminal = FlutterTerminal();
  addTearDown(terminal.dispose);
  final buffer = Buffer(10, 2)..writeString(0, 0, '<!--', Style.empty);

  await tester.runAsync<void>(() async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 320,
          height: 200,
          child: TerminalSurface(
            atlasController: atlasController,
            terminal: terminal,
            buffer: buffer,
            enableLigatures: true,
            backgroundColor: const ui.Color(0xFF000000),
          ),
        ),
      ),
    );
    await _pumpUntilSurfaceReady(tester);
  });
  await tester.pumpAndSettle();

  expect(atlasController.ligaturePainters, isNotEmpty);
  final initialFontSize = atlasController.fontSize;

  // Theme update on a non-owning child pane must not wipe shared painter caches.
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 320,
        height: 200,
        child: TerminalSurface(
          atlasController: atlasController,
          terminal: terminal,
          buffer: buffer,
          enableLigatures: true,
          backgroundColor: const ui.Color(0xFF607D8B),
        ),
      ),
    ),
  );
  await tester.pump();
  expect(atlasController.ligaturePainters, isNotEmpty);

  // Terminal fontSize stream on a non-owning child pane must not mutate shared atlas.
  terminal.setFontSize(22.0);
  await tester.pump();
  expect(atlasController.fontSize, equals(initialFontSize));
}

Future<void> _testTransientFallbackGlyphOnCacheMiss() async {
  final atlas = await GlyphAtlasGenerator.generate(
    fontSize: 16.0,
    fontFamily: 'Roboto Mono',
  );
  addTearDown(atlas.image.dispose);

  final buffer = Buffer(4, 2)..setCharacter(1, 0, '\u0416');
  final w = (4 * atlas.cellWidth).ceil();
  final h = (2 * atlas.cellHeight).ceil();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  TuiAtlasPainter(
    buffer: buffer,
    atlas: atlas,
    fontFamily: 'Roboto Mono',
    fallbackPainters: const {},
    onMissingGlyphs: null,
    defaultForegroundArgb: 0xFFFFFFFF,
    defaultBackgroundArgb: 0xFF000000,
  ).paint(canvas, Size(w.toDouble(), h.toDouble()));

  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  picture.dispose();
  addTearDown(image.dispose);
  final rgba = (await image.toByteData())!.buffer.asUint8List();

  var litPixels = 0;
  for (var i = 0; i < rgba.length; i += 4) {
    if (rgba[i] > 20 || rgba[i + 1] > 20 || rgba[i + 2] > 20) {
      litPixels++;
    }
  }
  expect(litPixels, greaterThan(0));
}

Future<void> _testCoalescedMissingStyledGlyphs(WidgetTester tester) async {
  final atlasController = GlyphAtlasController(
    fontSize: 14.0,
    fontFamily: 'Roboto Mono',
  );
  addTearDown(atlasController.dispose);
  await tester.runAsync<void>(atlasController.ensureInitialized);
  final baseCount = atlasController.debugCreatedAtlasCount;

  await tester.runAsync<void>(() async {
    atlasController.requestMissingStyledGlyphs(const [
      ('Ψ', GlyphStyleVariant.regular),
    ]);
    atlasController.requestMissingStyledGlyphs(const [
      ('Ω', GlyphStyleVariant.bold),
    ]);
    for (
      var i = 0;
      i < 40 && atlasController.debugCreatedAtlasCount == baseCount;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  expect(atlasController.debugCreatedAtlasCount, equals(baseCount + 1));
  expect(
    atlasController.atlas!.hasNativeVariant('Ψ', GlyphStyleVariant.regular),
    isTrue,
  );
  expect(
    atlasController.atlas!.hasNativeVariant('Ω', GlyphStyleVariant.bold),
    isTrue,
  );

  // Also verify postFrameCallbacks -> microtask coalescing branch.
  final postFrameBaseCount = atlasController.debugCreatedAtlasCount;
  SchedulerBinding.instance.addPostFrameCallback((_) {
    atlasController.requestMissingStyledGlyphs(const [
      ('Δ', GlyphStyleVariant.regular),
    ]);
    atlasController.requestMissingStyledGlyphs(const [
      ('Λ', GlyphStyleVariant.italic),
    ]);
  });
  await tester.pump();
  await tester.runAsync<void>(() async {
    for (
      var i = 0;
      i < 40 && atlasController.debugCreatedAtlasCount == postFrameBaseCount;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  expect(
    atlasController.debugCreatedAtlasCount,
    equals(postFrameBaseCount + 1),
  );
  expect(
    atlasController.atlas!.hasNativeVariant('Δ', GlyphStyleVariant.regular),
    isTrue,
  );
  expect(
    atlasController.atlas!.hasNativeVariant('Λ', GlyphStyleVariant.italic),
    isTrue,
  );
}

Future<void> _testConcurrentRecreateDoesNotOverwriteAtlas(
  WidgetTester tester,
) async {
  final atlasController = GlyphAtlasController(
    fontSize: 13.0,
    fontFamily: 'Roboto Mono',
  );
  addTearDown(atlasController.dispose);
  await tester.runAsync<void>(atlasController.ensureInitialized);

  await tester.runAsync<void>(() async {
    final recreateFuture = atlasController.setFontSize(19.0);
    atlasController.requestMissingStyledGlyphs(const [
      ('Ψ', GlyphStyleVariant.regular),
    ]);
    await recreateFuture;
    for (
      var i = 0;
      i < 40 &&
          !atlasController.atlas!.hasNativeVariant(
            'Ψ',
            GlyphStyleVariant.regular,
          );
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });

  expect(atlasController.atlas!.fontSize, equals(19.0));
  expect(
    atlasController.atlas!.hasNativeVariant('Ψ', GlyphStyleVariant.regular),
    isTrue,
  );
}
