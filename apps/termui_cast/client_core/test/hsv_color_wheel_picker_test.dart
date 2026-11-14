@TestOn('vm')
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/termui.dart';
import 'package:termui_cast_client_core/src/ui/hsv_color_wheel_picker.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

import 'support/fake_three_way_ws_harness.dart';

final class _PickerHarness extends StatefulWidget {
  final HsvColor initialColor;
  final (double, double) cellPixelSize;
  final Color panelBackgroundColor;
  final int imageId;
  final int columns;
  final int rows;
  final EdgeInsets padding;
  final bool roundTrip8Bit;
  final bool rejectChanges;
  final void Function(HsvColor color) onChanged;
  final void Function(void Function() close)? onBindClose;
  final void Function(void Function(HsvColor) setColor)? onBindSetColor;

  const _PickerHarness({
    required this.initialColor,
    required this.cellPixelSize,
    required this.panelBackgroundColor,
    required this.imageId,
    required this.columns,
    required this.rows,
    required this.onChanged,
    this.padding = EdgeInsets.zero,
    this.roundTrip8Bit = false,
    this.rejectChanges = false,
    this.onBindClose,
    this.onBindSetColor,
  });

  @override
  State<_PickerHarness> createState() => _PickerHarnessState();
}

final class _PickerHarnessState extends State<_PickerHarness> {
  late HsvColor _color = widget.initialColor;

  void setExternalColor(HsvColor next) {
    setState(() => _color = next);
  }

  @override
  Widget build(BuildContext context) {
    widget.onBindClose?.call(() => PromptScope.of(context)?.done(null));
    widget.onBindSetColor?.call(setExternalColor);
    return Padding(
      padding: widget.padding,
      child: Align(
        alignment: Alignment.topLeft,
        child: HsvColorWheelPicker(
          hsvColor: _color,
          cellPixelSize: widget.cellPixelSize,
          panelBackgroundColor: widget.panelBackgroundColor,
          imageId: widget.imageId,
          columns: widget.columns,
          rows: widget.rows,
          onChanged: (next) {
            widget.onChanged(next);
            if (widget.rejectChanges) return;
            setState(() {
              _color = widget.roundTrip8Bit
                  ? HsvColor.fromColor(next.toColor())
                  : next;
            });
          },
        ),
      ),
    );
  }
}

void _checkColorClose(HsvColor actual, double h, double s, double v) {
  check(actual.hue).isCloseTo(h, 0.5);
  check(actual.saturation).isCloseTo(s, 0.02);
  check(actual.value).isCloseTo(v, 0.02);
}

Future<void> _settle(TerminalTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  tearDown(KittyImageRegistry.clear);

  group('HsvColor', () {
    test('round-trips primaries, secondaries, and theme colors', () {
      const cases = <(Color, double, double, double)>[
        (Color(255, 0, 0), 0, 1, 1),
        (Color(255, 255, 0), 60, 1, 1),
        (Color(0, 255, 0), 120, 1, 1),
        (Color(0, 255, 255), 180, 1, 1),
        (Color(0, 0, 255), 240, 1, 1),
        (Color(255, 0, 255), 300, 1, 1),
        (Color(0x1E, 0x1E, 0x2E), 240, 0.348, 0.180),
        (Color(0xF3, 0x8B, 0xA8), 343.3, 0.428, 0.953),
      ];
      for (final (rgb, h, s, v) in cases) {
        final hsv = HsvColor.fromColor(rgb);
        _checkColorClose(hsv, h, s, v);
        check(hsv.toColor()).equals(rgb);
      }
    });

    test(
      'retains fallback hue/saturation on black and fallback hue on gray',
      () {
        final black = HsvColor.fromColor(
          const Color(0, 0, 0),
          fallbackHue: -145,
          fallbackSaturation: 0.72,
        );
        check(black.hue).isCloseTo(215, 0.001);
        check(black.saturation).isCloseTo(0.72, 0.001);
        check(black.value).equals(0.0);
        check(black.toColor()).equals(const Color(0, 0, 0));

        final gray = HsvColor.fromColor(
          const Color(128, 128, 128),
          fallbackHue: 420,
          fallbackSaturation: 0.9,
        );
        check(gray.hue).isCloseTo(60, 0.001);
        check(gray.saturation).equals(0.0);
        check(gray.value).isCloseTo(128 / 255.0, 0.001);

        const nanHue = HsvColor(double.nan, 0.5, 0.5);
        check(nanHue.toColor()).equals(const Color(128, 64, 64));
        // ignore: prefer_const_constructors
        final nonConstA = HsvColor(120, 0.5, 0.5);
        // ignore: prefer_const_constructors
        final nonConstB = HsvColor(120, 0.5, 0.5);
        check(identical(nonConstA, nonConstB)).isFalse();
        check(nonConstA).equals(nonConstB);
        check(nonConstA.hashCode).equals(nonConstB.hashCode);
      },
    );
  });

  group('CastSceneController.wantsPixelMouseEvents', () {
    test(
      'enables for PaletteEditorDialog, disables for SettingsDialog, and respects dispose',
      () {
        final tester = TerminalTester(size: const Point(80, 26));
        tester.run(() async {
          final harness = FakeThreeWayWsHarness();
          final shell = await harness.startCaster(id: 'px-1', title: 'px');
          final viewer = await harness.connectViewer();
          final controller = CastSceneController(
            terminal: tester.terminal,
            viewModel: viewer.viewModel,
          );
          await _settle(tester);

          // Idle without ?1016h -> false; with PaletteEditorDialog -> true.
          check(controller.wantsPixelMouseEvents).isFalse();
          unawaited(controller.openPaletteEditor());
          await _settle(tester);
          check(controller.isPaletteEditorOpen).isTrue();
          check(controller.wantsPixelMouseEvents).isTrue();
          tester.sendKey(LogicalKey.escape);
          await _settle(tester);
          check(controller.isPaletteEditorOpen).isFalse();
          check(controller.wantsPixelMouseEvents).isFalse();

          // Enable ?1016h on PTY -> true idle, but false while SettingsDialog is open.
          shell.pty.emitRawAnsi('\x1b[?1002;1016h');
          await _settle(tester);
          check(controller.wantsPixelMouseEvents).isTrue();
          unawaited(controller.openSettings());
          await _settle(tester);
          check(controller.isSettingsDialogOpen).isTrue();
          check(controller.wantsPixelMouseEvents).isFalse();
          tester.sendKey(LogicalKey.escape);
          await _settle(tester);
          check(controller.wantsPixelMouseEvents).isTrue();

          controller.dispose();
          check(controller.wantsPixelMouseEvents).isFalse();
          await harness.dispose();
        });
      },
    );
  });

  group('HsvColorWheelPicker rasterization and interaction', () {
    test(
      'composites opaque panelBackgroundColor, preserves aspect/256-cap, and caches immutable snapshots',
      () {
        const imageId = 0x00F41E77;
        const bg = Color(0x1E, 0x1E, 0x2E);
        final tester = TerminalTester(size: const Point(80, 26));
        tester.run(() async {
          await tester.pumpWidget(
            _PickerHarness(
              initialColor: const HsvColor(0, 1, 1),
              cellPixelSize: const (8.0, 16.0),
              panelBackgroundColor: bg,
              imageId: imageId,
              columns: 24,
              rows: 10,
              onChanged: (_) {},
            ),
          );
          final state =
              (tester.rootElement! as StatefulElement).state
                  as _PickerHarnessState;

          final first = KittyImageRegistry.lookup(imageId);
          check(first).isNotNull();
          check(first!.pixelWidth).equals(192);
          check(first.pixelHeight).equals(160);
          final pixels1 = first.rgbaPixels;
          for (var i = 3; i < pixels1.length; i += 4) {
            check(pixels1[i]).equals(255);
          }
          // Check all 4 corners are opaque panelBackgroundColor.
          for (final (x, y) in [
            (0, 0),
            (first.pixelWidth - 1, 0),
            (0, first.pixelHeight - 1),
            (first.pixelWidth - 1, first.pixelHeight - 1),
          ]) {
            final off = (y * first.pixelWidth + x) * 4;
            check((
              pixels1[off],
              pixels1[off + 1],
              pixels1[off + 2],
              pixels1[off + 3],
            )).equals((bg.r, bg.g, bg.b, 255));
          }

          // Rebuilding without changing state keeps identical Uint8List and version.
          await tester.pump();
          final same = KittyImageRegistry.lookup(imageId)!;
          check(identical(same.rgbaPixels, pixels1)).isTrue();
          check(same.version).equals(first.version);

          // Changing color allocates a fresh Uint8List without mutating pixels1.
          final copyBefore = Uint8List.fromList(pixels1);
          state.setExternalColor(const HsvColor(180, 0.8, 0.5));
          await tester.pump();
          final second = KittyImageRegistry.lookup(imageId)!;
          check(identical(second.rgbaPixels, pixels1)).isFalse();
          check(second.version).isGreaterThan(first.version);
          check(pixels1).deepEquals(copyBefore);

          // Larger grid caps longer side at 256 while preserving 400:320 aspect.
          await tester.pumpWidget(
            _PickerHarness(
              initialColor: const HsvColor(120, 1, 1),
              cellPixelSize: const (10.0, 20.0),
              panelBackgroundColor: bg,
              imageId: imageId,
              columns: 40,
              rows: 16,
              onChanged: (_) {},
            ),
          );
          final capped = KittyImageRegistry.lookup(imageId)!;
          check(capped.pixelWidth).equals(256);
          check(capped.pixelHeight).equals(205);
        });
      },
    );

    test(
      'distinguishes sub-cell pixelX/pixelY clicks in same cell and falls back to cell centers when null',
      () {
        const imageId = 0x00F41E88;
        final tester = TerminalTester(size: const Point(60, 20));
        tester.run(() async {
          final changes = <HsvColor>[];
          late void Function() closePrompt;
          final runner = PromptRunner<void>(
            terminal: tester.terminal,
            alternateScreen: false,
            widget: _PickerHarness(
              initialColor: const HsvColor(0, 0, 1),
              cellPixelSize: const (10.0, 20.0),
              panelBackgroundColor: const Color(0x1E, 0x1E, 0x2E),
              imageId: imageId,
              columns: 24,
              rows: 10,
              padding: const EdgeInsets.only(left: 4, top: 2),
              onChanged: changes.add,
              onBindClose: (fn) => closePrompt = fn,
            ),
          );
          final runFuture = tester.runPrompt(runner, () async {
            await tester.pump();
            // Cell (x: 10, y: 7) 1-based => global col0=9, row0=6 => pixel X in 91..100, Y in 121..140.
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 10,
                y: 7,
                pixelX: 91,
                pixelY: 121,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.press,
              ),
            );
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 10,
                y: 7,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.release,
              ),
            );
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 10,
                y: 7,
                pixelX: 99,
                pixelY: 139,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.press,
              ),
            );
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 10,
                y: 7,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.release,
              ),
            );

            check(changes.length).equals(2);
            check(changes[0] == changes[1]).isFalse();

            // Fallback when pixelX/pixelY are null uses cell center.
            changes.clear();
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 18,
                y: 7,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.press,
              ),
            );
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 18,
                y: 7,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.release,
              ),
            );
            check(changes.length).equals(1);
            check(changes.single.hue).isCloseTo(14.4, 2.5);
            check(changes.single.saturation).isGreaterThan(0.2);

            closePrompt();
            await tester.pump();
          });
          await runFuture;
        });
      },
    );

    test(
      'lifts V from 0 on wheel click, retains hue/sat across V=0 bar drag, clamps OOB, ignores (-1,-1) release, and unregisters on dispose',
      () {
        const imageId = 0x00F41E99;
        final tester = TerminalTester(size: const Point(60, 20));
        tester.run(() async {
          final changes = <HsvColor>[];
          late void Function() closePrompt;
          final runner = PromptRunner<void>(
            terminal: tester.terminal,
            alternateScreen: false,
            widget: _PickerHarness(
              initialColor: const HsvColor(0, 0, 0),
              cellPixelSize: const (10.0, 20.0),
              panelBackgroundColor: const Color(0x1E, 0x1E, 0x2E),
              imageId: imageId,
              columns: 24,
              rows: 10,
              onChanged: changes.add,
              onBindClose: (fn) => closePrompt = fn,
            ),
          );
          final runFuture = tester.runPrompt(runner, () async {
            await tester.pump();
            check(KittyImageRegistry.lookup(imageId)).isNotNull();

            // 1. Click wheel while V == 0 -> auto-lifts V to 1.0.
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 15,
                y: 5,
                pixelX: 150,
                pixelY: 100,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.press,
              ),
            );
            await tester.pump();
            check(changes.last.value).equals(1.0);
            final pickedHue = changes.last.hue;
            final pickedSat = changes.last.saturation;
            check(pickedHue).isGreaterThan(0.0);
            check(pickedSat).isGreaterThan(0.1);

            // Out-of-bounds wheel drag clamps saturation <= 1.0 without dropping lock.
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: -5,
                y: -3,
                pixelX: -40,
                pixelY: -40,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.drag,
              ),
            );
            await tester.pump();
            check(changes.last.saturation).equals(1.0);
            check(changes.last.value).equals(1.0);

            // Synthetic (-1, -1) release must not resample or change color.
            final beforeReleaseCount = changes.length;
            final beforeReleaseColor = changes.last;
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: -1,
                y: -1,
                globalX: -1,
                globalY: -1,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.release,
              ),
            );
            check(changes.length).equals(beforeReleaseCount);
            check(changes.last).equals(beforeReleaseColor);

            // 2. Press brightness bar (right side: col 23 => px ~225), drag to bottom (V=0), then up to ~0.7.
            // First pick interior wheel color with non-zero hue/sat.
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 13,
                y: 4,
                pixelX: 130,
                pixelY: 75,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.press,
              ),
            );
            await tester.pump();
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 13,
                y: 4,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.release,
              ),
            );
            final anchorHue = changes.last.hue;
            final anchorSat = changes.last.saturation;
            check(anchorHue).isGreaterThan(20.0);
            check(anchorSat).isGreaterThan(0.2);

            // Press brightness bar top.
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 23,
                y: 2,
                pixelX: 225,
                pixelY: 20,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.press,
              ),
            );
            // Drag far below widget -> clamps V to 0.0 while retaining hue & saturation.
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 23,
                y: 15,
                pixelX: 225,
                pixelY: 260,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.drag,
              ),
            );
            check(changes.last.value).equals(0.0);
            check(changes.last.hue).equals(anchorHue);
            check(changes.last.saturation).equals(anchorSat);

            // Drag back up to ~0.7 -> hue & saturation remain retained.
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 23,
                y: 4,
                pixelX: 225,
                pixelY: 68,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.drag,
              ),
            );
            check(changes.last.value).isGreaterThan(0.5);
            check(changes.last.value).isLessThan(0.9);
            check(changes.last.hue).equals(anchorHue);
            check(changes.last.saturation).equals(anchorSat);

            // Synthetic (-1, -1) release keeps the ~0.7 color untouched.
            final finalBarColor = changes.last;
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: -1,
                y: -1,
                globalX: -1,
                globalY: -1,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.release,
              ),
            );
            check(changes.last).equals(finalBarColor);

            closePrompt();
            await tester.pump();
          });
          await runFuture;
          // PromptRunner teardown unmounts the tree -> dispose() unregisters imageId.
          check(KittyImageRegistry.lookup(imageId)).isNull();
        });
      },
    );

    test(
      'supports non-zero SceneLayer offset and aligns rendered pixel hue with hit-test hue',
      () {
        const imageId = 0x00F41EAA;
        const layerX = 12;
        const layerY = 4;
        final tester = TerminalTester(size: const Point(60, 20));
        tester.run(() async {
          final changes = <HsvColor>[];
          late void Function() closePrompt;
          final scene = SceneManager(
            tester.terminal,
            renderingMode: .alternateScreen,
          )..enableMouseTracking = true;
          final runner = PromptRunner<void>(
            terminal: tester.terminal,
            mode: ExecutionMode.managed,
            widget: _PickerHarness(
              initialColor: const HsvColor(0, 0, 1),
              cellPixelSize: const (10.0, 20.0),
              panelBackgroundColor: const Color(0x1E, 0x1E, 0x2E),
              imageId: imageId,
              columns: 24,
              rows: 10,
              onChanged: changes.add,
              onBindClose: (fn) => closePrompt = fn,
            ),
          );
          final layer = SceneLayer(
            renderer: runner,
            x: layerX,
            y: layerY,
            width: 24,
            height: 10,
          );
          scene.layers.add(layer);
          scene.focusedLayer = layer;
          final runFuture = runner.run();
          await _settle(tester);
          scene.render();

          final image = KittyImageRegistry.lookup(imageId)!;
          // Target wheel pixel (150, 70) in cell (15, 3) => global cell (28, 8).
          const wheelPx = 150;
          const wheelPy = 70;
          final off = (wheelPy * image.pixelWidth + wheelPx) * 4;
          final renderedColor = Color(
            image.rgbaPixels[off],
            image.rgbaPixels[off + 1],
            image.rgbaPixels[off + 2],
          );
          final renderedHue = HsvColor.fromColor(renderedColor).hue;

          scene.handleMouseEvent(
            const ev.MouseEvent(
              x: layerX + 16,
              y: layerY + 4,
              pixelX: layerX * 10 + wheelPx + 1,
              pixelY: layerY * 20 + wheelPy + 1,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.press,
            ),
          );
          scene.handleMouseEvent(
            const ev.MouseEvent(
              x: layerX + 16,
              y: layerY + 4,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.release,
            ),
          );
          // Second pixel in the SAME cell (159, 79).
          scene.handleMouseEvent(
            const ev.MouseEvent(
              x: layerX + 16,
              y: layerY + 4,
              pixelX: layerX * 10 + 160,
              pixelY: layerY * 20 + 80,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.press,
            ),
          );
          scene.handleMouseEvent(
            const ev.MouseEvent(
              x: layerX + 16,
              y: layerY + 4,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.release,
            ),
          );

          check(changes.length).equals(2);
          check(changes[0].hue).isCloseTo(renderedHue, 1.5);
          check(changes[0] == changes[1]).isFalse();

          closePrompt();
          await tester.pump();
          await runFuture;
          scene.dispose();
        });
      },
    );

    test(
      'retains hue/sat across 8-bit Color round-trip on V=0 bar drag and dedupes clamped OOB drags',
      () {
        const imageId = 0x00F41EAB;
        final tester = TerminalTester(size: const Point(60, 20));
        tester.run(() async {
          final changes = <HsvColor>[];
          late void Function() closePrompt;
          final runner = PromptRunner<void>(
            terminal: tester.terminal,
            alternateScreen: false,
            widget: _PickerHarness(
              initialColor: const HsvColor(210, 0.75, 1.0),
              cellPixelSize: const (10.0, 20.0),
              panelBackgroundColor: const Color(0x1E, 0x1E, 0x2E),
              imageId: imageId,
              columns: 24,
              rows: 10,
              roundTrip8Bit: true,
              onChanged: changes.add,
              onBindClose: (fn) => closePrompt = fn,
            ),
          );
          final runFuture = tester.runPrompt(runner, () async {
            await tester.pump();
            // Press brightness bar top -> drag past bottom (V=0) twice.
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 23,
                y: 2,
                pixelX: 225,
                pixelY: 20,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.press,
              ),
            );
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 23,
                y: 15,
                pixelX: 225,
                pixelY: 260,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.drag,
              ),
            );
            await tester.pump();
            final countAtBottom = changes.length;
            check(changes.last.value).equals(0.0);
            check(changes.last.hue).equals(210.0);
            check(changes.last.saturation).equals(0.75);

            // Second clamped OOB drag produces identical HsvColor -> deduped.
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 23,
                y: 18,
                pixelX: 225,
                pixelY: 320,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.drag,
              ),
            );
            check(changes.length).equals(countAtBottom);

            // Drag back up to ~0.7 after 8-bit Color(0,0,0) round-trip echo.
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 23,
                y: 4,
                pixelX: 225,
                pixelY: 68,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.drag,
              ),
            );
            check(changes.last.value).isGreaterThan(0.5);
            check(changes.last.value).isLessThan(0.9);
            check(changes.last.hue).equals(210.0);
            check(changes.last.saturation).equals(0.75);

            closePrompt();
            await tester.pump();
          });
          await runFuture;
        });
      },
    );

    test(
      'cancels active drag on external setExternalColor, ignores post-release drag, and resyncs rejected updates on release',
      () {
        const imageId = 0x00F41EAC;
        final tester = TerminalTester(size: const Point(60, 20));
        tester.run(() async {
          final changes = <HsvColor>[];
          late void Function() closePrompt;
          late void Function(HsvColor) setExternalColor;
          final runner = PromptRunner<void>(
            terminal: tester.terminal,
            alternateScreen: false,
            widget: _PickerHarness(
              initialColor: const HsvColor(0, 1, 1),
              cellPixelSize: const (10.0, 20.0),
              panelBackgroundColor: const Color(0x1E, 0x1E, 0x2E),
              imageId: imageId,
              columns: 24,
              rows: 10,
              onChanged: changes.add,
              onBindClose: (fn) => closePrompt = fn,
              onBindSetColor: (fn) => setExternalColor = fn,
            ),
          );
          final runFuture = tester.runPrompt(runner, () async {
            await tester.pump();
            // Start drag on wheel.
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 15,
                y: 5,
                pixelX: 150,
                pixelY: 100,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.press,
              ),
            );
            final countBeforeSwitch = changes.length;

            // External slot switch mid-drag must abort active drag capture.
            setExternalColor(const HsvColor(120, 1, 1));
            await tester.pump();

            // Subsequent drag from the aborted gesture must be ignored.
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 10,
                y: 7,
                pixelX: 95,
                pixelY: 130,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.drag,
              ),
            );
            check(changes.length).equals(countBeforeSwitch);

            // Start a fresh press, then release with synthetic (-1, -1), then drag -> ignored.
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 13,
                y: 4,
                pixelX: 130,
                pixelY: 75,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.press,
              ),
            );
            final countAfterPress = changes.length;
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: -1,
                y: -1,
                globalX: -1,
                globalY: -1,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.release,
              ),
            );
            runner.handleMouseEvent(
              const ev.MouseEvent(
                x: 16,
                y: 6,
                pixelX: 160,
                pixelY: 115,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.drag,
              ),
            );
            check(changes.length).equals(countAfterPress);

            closePrompt();
            await tester.pump();
          });
          await runFuture;

          // Rejected parent update resyncs back to widget.hsvColor on release.
          const rejectId = 0x00F41EAD;
          final rejectedChanges = <HsvColor>[];
          late void Function() closeReject;
          final rejectRunner = PromptRunner<void>(
            terminal: tester.terminal,
            alternateScreen: false,
            widget: _PickerHarness(
              initialColor: const HsvColor(240, 1, 1),
              cellPixelSize: const (10.0, 20.0),
              panelBackgroundColor: const Color(0x1E, 0x1E, 0x2E),
              imageId: rejectId,
              columns: 24,
              rows: 10,
              rejectChanges: true,
              onChanged: rejectedChanges.add,
              onBindClose: (fn) => closeReject = fn,
            ),
          );
          await tester.runPrompt(rejectRunner, () async {
            await tester.pump();
            final baseline = Uint8List.fromList(
              KittyImageRegistry.lookup(rejectId)!.rgbaPixels,
            );
            rejectRunner.handleMouseEvent(
              const ev.MouseEvent(
                x: 18,
                y: 5,
                pixelX: 175,
                pixelY: 100,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.press,
              ),
            );
            await tester.pump();
            check(rejectedChanges.length).equals(1);
            check(
              KittyImageRegistry.lookup(rejectId)!.rgbaPixels,
            ).not((it) => it.deepEquals(baseline));

            rejectRunner.handleMouseEvent(
              const ev.MouseEvent(
                x: 18,
                y: 5,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.release,
              ),
            );
            await tester.pump();
            check(
              KittyImageRegistry.lookup(rejectId)!.rgbaPixels,
            ).deepEquals(baseline);

            closeReject();
            await tester.pump();
          });
        });
      },
    );

    test(
      'sanitizes NaN/360 colors at 1x1 narrow constraints, preserves image during #isMeasuringIntrinsics, and unregisters normalized imageId 1 on 0 -> newId',
      () {
        final tester = TerminalTester(size: const Point(60, 20));
        tester.run(() async {
          final changes = <HsvColor>[];
          // imageId 0 normalizes to 1; 1x1 * (1, 1) clamps raster to >= 2x2.
          await tester.pumpWidget(
            Align(
              alignment: Alignment.topLeft,
              child: HsvColorWheelPicker(
                hsvColor: const HsvColor(double.nan, double.nan, double.nan),
                cellPixelSize: const (1.0, 1.0),
                panelBackgroundColor: const Color(0x1E, 0x1E, 0x2E),
                imageId: 0,
                columns: 1,
                rows: 1,
                onChanged: changes.add,
              ),
            ),
          );
          final normalized = KittyImageRegistry.lookup(1);
          check(normalized).isNotNull();
          check(normalized!.pixelWidth).isGreaterOrEqual(2);
          check(normalized.pixelHeight).isGreaterOrEqual(2);
          check(KittyImageRegistry.lookup(0)).isNull();

          // Update with hue == 360 and new imageId -> old normalized ID 1 is unregistered.
          const nextId = 0x00F41EAE;
          await tester.pumpWidget(
            Align(
              alignment: Alignment.topLeft,
              child: HsvColorWheelPicker(
                hsvColor: const HsvColor(360, 1.5, 2.0),
                cellPixelSize: const (8.0, 16.0),
                panelBackgroundColor: const Color(0x1E, 0x1E, 0x2E),
                imageId: nextId,
                columns: 12,
                rows: 6,
                onChanged: changes.add,
              ),
            ),
          );
          check(KittyImageRegistry.lookup(1)).isNull();
          final live = KittyImageRegistry.lookup(nextId)!;
          final liveVersion = live.version;
          final livePixels = live.rgbaPixels;

          // Intrinsic measurement runs inside #isMeasuringIntrinsics zone and must not
          // clobber or unregister the live KittyImage entry.
          final probe = SizedBox(
            width: 12,
            height: 6,
            child: HsvColorWheelPicker(
              hsvColor: const HsvColor(180, 1, 1),
              cellPixelSize: const (8.0, 16.0),
              panelBackgroundColor: const Color(0x1E, 0x1E, 0x2E),
              imageId: nextId,
              columns: 12,
              rows: 6,
              onChanged: (_) {},
            ),
          );
          probe.getIntrinsicWidth(6);
          final afterProbe = KittyImageRegistry.lookup(nextId);
          check(afterProbe).isNotNull();
          check(afterProbe!.version).equals(liveVersion);
          check(identical(afterProbe.rgbaPixels, livePixels)).isTrue();
        });
      },
    );
  });
}
