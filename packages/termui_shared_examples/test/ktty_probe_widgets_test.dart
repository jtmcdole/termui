import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:termui_shared_examples/ktty_probe/ktty_probe.dart';
import 'package:test/test.dart';

KttyProbeActions _noopActions({void Function()? onCycleDeleteMode}) =>
    KttyProbeActions(
      onSelectTab: (_) {},
      onReprobe: () {},
      onCycleKittyKeyboard: () {},
      onToggleSgrPixels: () {},
      onToggleOcclusion: () {},
      onCycleDeleteMode: onCycleDeleteMode,
      onSendNotification: () {},
      onSendClipboard: () {},
      onCycleWindowTitle: () {},
      onEmitPromptMarker: () {},
      onQuit: () {},
    );

Buffer _renderDashboard(
  KttyProbeViewState state, {
  required int width,
  required int height,
  KttyProbeActions? actions,
}) {
  final widget = KttyProbeDashboard(
    state: state,
    actions: actions ?? _noopActions(),
  );
  final element = widget.createElement()
    ..mount(null)
    ..layout(BoxConstraints.tight(Size(width, height)));
  final buffer = Buffer(width, height);
  element.paint(buffer, Offset.zero);
  element.unmount();
  return buffer;
}

String _bufferToText(Buffer buf) {
  final sb = StringBuffer();
  for (var y = 0; y < buf.height; y++) {
    for (var x = 0; x < buf.width; x++) {
      sb.write(buf.getCharacter(x, y));
    }
    sb.writeln();
  }
  return sb.toString();
}

Map<int, int> _countPlaceholderCellsByImageId(Buffer buf) {
  final counts = <int, int>{};
  for (var y = 0; y < buf.height; y++) {
    for (var x = 0; x < buf.width; x++) {
      final idx = y * buf.width + x;
      if ((buf.attributes[idx * 3 + 2] & Modifier.kittyPlaceholder) == 0) {
        continue;
      }
      final id = extractKittyCellImageId(
        buf.getCharacter(x, y),
        buf.getForeground(x, y),
      );
      counts[id] = (counts[id] ?? 0) + 1;
    }
  }
  return counts;
}

Future<void> _pumpEventQueue([int turns = 10]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() {
    FocusManager.instance.setPrimaryFocus(null);
    KittyImageRegistry.clear();
  });

  tearDown(() {
    FocusManager.instance.setPrimaryFocus(null);
    KittyImageRegistry.clear();
  });

  group('KttyShorthandTileWidget', () {
    test(
      'paints 3-unit row-only col 0, 2-unit bare cols 1..N, 24-bit ID 0x004B04, and p=1/p=2 underlineColor',
      () {
        const cols = 12;
        const rows = 4;
        final tile = buildShorthandVisualTile(cols: cols, rows: rows);
        final element = KttyShorthandTileWidget(imageData: tile).createElement()
          ..layout(BoxConstraints.tight(const Size(cols, rows)));
        final buffer = Buffer(20, 10);
        element.paint(buffer, const Offset(2, 3));
        element.unmount();

        final expectedFg = 0xFF000000 | kttyVisualShorthandImageId;
        final expectedTopUl = const Color(0, 0, 1).argb;
        final expectedBottomUl = const Color(0, 0, 2).argb;

        expect(
          KittyImageRegistry.global.lookupImage(kttyVisualShorthandImageId),
          isNotNull,
        );
        expect(
          identical(
            buffer.lookupKittyRegistry(2, 3),
            KittyImageRegistry.global,
          ),
          isTrue,
        );

        for (var ry = 0; ry < rows; ry++) {
          final by = 3 + ry;
          final expectedUl = ry < rows ~/ 2 ? expectedTopUl : expectedBottomUl;
          for (var rx = 0; rx < cols; rx++) {
            final bx = 2 + rx;
            final char = buffer.getCharacter(bx, by);
            final fg = buffer.getForeground(bx, by);
            final mod = buffer.attributes[(by * buffer.width + bx) * 3 + 2];

            expect(mod & Modifier.kittyPlaceholder, isNonZero);
            expect(fg, equals(expectedFg));
            expect(
              extractKittyCellImageId(char, fg),
              equals(kttyVisualShorthandImageId),
            );
            expect(buffer.getUnderlineColor(bx, by), equals(expectedUl));

            if (rx == 0) {
              expect(char.length, equals(3));
              expect(
                char,
                equals(
                  '$kittyPlaceholderChar${String.fromCharCode(kittyDiacritics[ry])}',
                ),
              );
              expect(
                parseKittyPlaceholderCell(char),
                equals((row: ry, col: 0, imageIdMsb: null)),
              );
            } else {
              expect(char.length, equals(2));
              expect(char, equals(kittyPlaceholderChar));
            }
          }
        }
      },
    );

    test(
      'reports intrinsic size, normalizes zero imageId to 0x004B04, and caches resized copies',
      () {
        final zeroTile = buildShorthandVisualTile(
          cols: 12,
          rows: 4,
        ).copyWith(imageId: 0);
        final widget = KttyShorthandTileWidget(imageData: zeroTile);
        expect(widget.getIntrinsicWidth(4), equals(12));
        expect(widget.getIntrinsicHeight(12), equals(4));

        final element = widget.createElement()
          ..layout(BoxConstraints.tight(const Size(6, 2)));
        final buffer = Buffer(10, 6);
        element.paint(buffer, Offset.zero);
        // Repaint with same constraints to exercise cached sized data and row heads.
        element.paint(buffer, Offset.zero);
        element.unmount();

        final registered = KittyImageRegistry.global.lookupImage(
          kttyVisualShorthandImageId,
        );
        expect(registered, isNotNull);
        expect((registered!.gridCols, registered.gridRows), equals((6, 2)));
        expect(
          extractKittyCellImageId(
            buffer.getCharacter(0, 0),
            buffer.getForeground(0, 0),
          ),
          equals(kttyVisualShorthandImageId),
        );
      },
    );
  });

  group('KttyProbeDashboard layout and badges', () {
    test(
      'renders all 4 tiles including Shorthand on wide Tab 3 (width >= 60) without overflow',
      () {
        final report = KttyProbeReport()..resetForNewProbe();
        final buffer = _renderDashboard(
          KttyProbeViewState(
            report: report,
            activeTab: .graphicsAndSgr,
            requestedKeyboardFlags: 11,
            sgrPixelsEnabled: true,
            showOcclusion: false,
            keyLog: const [],
            lastActionMessage: 'Ready',
          ),
          width: 60,
          height: 20,
        );

        final text = _bufferToText(buffer);
        expect(text, contains('Shorthand'));

        final counts = _countPlaceholderCellsByImageId(buffer);
        expect(counts[kttyVisualRgbaImageId], equals(48));
        expect(counts[kttyVisual32BitImageId], equals(48));
        expect(counts[kttyVisualPngImageId], equals(48));
        expect(counts[kttyVisualShorthandImageId], equals(48));
      },
    );

    test('keeps 3 tiles without clipping in narrow Overview (width = 88)', () {
      final report = KttyProbeReport()..resetForNewProbe();
      final buffer = _renderDashboard(
        KttyProbeViewState(
          report: report,
          activeTab: .overview,
          requestedKeyboardFlags: 11,
          sgrPixelsEnabled: true,
          showOcclusion: false,
          keyLog: const [],
          lastActionMessage: 'Ready',
        ),
        width: 88,
        height: 28,
      );

      final text = _bufferToText(buffer);
      expect(text, isNot(contains('Shorthand')));

      final counts = _countPlaceholderCellsByImageId(buffer);
      expect(counts[kttyVisualRgbaImageId], equals(48));
      expect(counts[kttyVisual32BitImageId], equals(48));
      expect(counts[kttyVisualPngImageId], equals(48));
      expect(counts[kttyVisualShorthandImageId], isNull);
    });

    test(
      'renders [OPT ] badge for optionalDisabled entries and [D:DelMode] action button',
      () {
        final report = KttyProbeReport()
          ..resetForNewProbe()
          ..recordDa1Sentinel('62;22');

        final matrixBuf = _renderDashboard(
          KttyProbeViewState(
            report: report,
            activeTab: .matrix,
            requestedKeyboardFlags: 11,
            sgrPixelsEnabled: true,
            showOcclusion: false,
            keyLog: const [],
            lastActionMessage: 'Ready',
          ),
          width: 100,
          height: 36,
        );
        final matrixText = _bufferToText(matrixBuf);
        expect(matrixText, contains('[OPT ] Kitty Temp File Medium'));
        expect(matrixText, contains('[OPT ] Kitty Shared Memory'));

        final inputBuf = _renderDashboard(
          KttyProbeViewState(
            report: report,
            activeTab: .inputAndOsc,
            requestedKeyboardFlags: 11,
            sgrPixelsEnabled: true,
            showOcclusion: false,
            keyLog: const [],
            lastActionMessage: 'Ready',
          ),
          width: 100,
          height: 16,
        );
        expect(_bufferToText(inputBuf), contains('[D:DelMode]'));

        final activeDelBuf = _renderDashboard(
          KttyProbeViewState(
            report: report,
            activeTab: .inputAndOsc,
            requestedKeyboardFlags: 11,
            sgrPixelsEnabled: true,
            showOcclusion: false,
            keyLog: const [],
            lastActionMessage: 'Ready',
            deleteModeLabel: 'd=a',
          ),
          width: 100,
          height: 16,
        );
        expect(_bufferToText(activeDelBuf), contains('[D:d=a]'));
      },
    );

    test(
      'renders compact tmux warning banner only when multiplexerDiagnostics has hints',
      () {
        final reportWithHints = KttyProbeReport()
          ..resetForNewProbe()
          ..multiplexerDiagnostics = const KttyMultiplexerDiagnostics(
            multiplexer: 'tmux',
            allowPassthrough: 'off',
            hasTrueColor: false,
            hints: ['set -gp allow-passthrough on'],
          );

        final withBanner = _bufferToText(
          _renderDashboard(
            KttyProbeViewState(
              report: reportWithHints,
              activeTab: .matrix,
              requestedKeyboardFlags: 11,
              sgrPixelsEnabled: true,
              showOcclusion: false,
              keyLog: const [],
              lastActionMessage: 'Ready',
            ),
            width: 100,
            height: 20,
          ),
        );
        expect(withBanner, contains('[WARN] tmux:'));
        expect(withBanner, contains('set -gp allow-passthrough on'));

        final reportNoHints = KttyProbeReport()
          ..resetForNewProbe()
          ..multiplexerDiagnostics = const KttyMultiplexerDiagnostics(
            multiplexer: 'tmux',
            allowPassthrough: 'on',
            hasTrueColor: true,
          );
        final withoutBanner = _bufferToText(
          _renderDashboard(
            KttyProbeViewState(
              report: reportNoHints,
              activeTab: .matrix,
              requestedKeyboardFlags: 11,
              sgrPixelsEnabled: true,
              showOcclusion: false,
              keyLog: const [],
              lastActionMessage: 'Ready',
            ),
            width: 100,
            height: 20,
          ),
        );
        expect(withoutBanner, isNot(contains('[WARN] tmux:')));
      },
    );
  });

  group('KttyProbeStatefulRoot wire interactions', () {
    test(
      '[D] cycles a=d,d=a,q=2 then a=d,d=A,q=2 and [K] cycles 11 -> 31 -> 15 -> 3 -> 1 -> 0 -> 11',
      () async {
        final wireInput = StreamController<List<int>>.broadcast();
        final wireOut = StringBuffer();
        final report = KttyProbeReport();
        final backend = KttyWireTerminalBackend(
          wireInput: wireInput.stream,
          onWriteWire: wireOut.write,
          report: report,
          initialSize: const Point<int>(100, 30),
        );
        final stopHandle = KttyProbeStopHandle();

        final runFuture = runKttyProbeOnWire(
          backend,
          probeTimeout: const Duration(milliseconds: 200),
          stopHandle: stopHandle,
        );

        await _pumpEventQueue();
        final startupWire = wireOut.toString();
        expect(startupWire, contains('\x1b[>11u'));

        // Switch to Tab 3 (Graphics&SGR) to render the shorthand tile;
        // verify p=1 and p=2 placements are emitted strictly AFTER Renderer uploads i=19204.
        wireInput.add(utf8.encode('3'));
        await _pumpEventQueue(16);
        final tab3Wire = wireOut.toString();
        final p1Plain =
            '\x1b_Ga=p,U=1,i=$kttyVisualShorthandImageId,p=1,c=12,r=4,q=2\x1b\\';
        final p2Plain =
            '\x1b_Ga=p,U=1,i=$kttyVisualShorthandImageId,p=2,c=12,r=4,q=2\x1b\\';
        final lastUploadIdx = tab3Wire.lastIndexOf(
          'a=p,U=1,i=$kttyVisualShorthandImageId,c=',
        );
        expect(lastUploadIdx, greaterThanOrEqualTo(0));
        expect(tab3Wire, contains(p1Plain));
        expect(tab3Wire, contains(p2Plain));
        expect(tab3Wire.indexOf(p1Plain), greaterThan(lastUploadIdx));
        expect(tab3Wire.indexOf(p2Plain), greaterThan(lastUploadIdx));

        // Press [D] three times: d=a -> d=A -> d=a.
        wireOut.clear();
        wireInput.add(utf8.encode('d'));
        await _pumpEventQueue();
        expect(wireOut.toString(), contains('\x1b_Ga=d,d=a,q=2\x1b\\'));

        wireOut.clear();
        wireInput.add(utf8.encode('d'));
        await _pumpEventQueue();
        expect(wireOut.toString(), contains('\x1b_Ga=d,d=A,q=2\x1b\\'));

        wireOut.clear();
        wireInput.add(utf8.encode('d'));
        await _pumpEventQueue();
        expect(wireOut.toString(), contains('\x1b_Ga=d,d=a,q=2\x1b\\'));

        // Press [K] six times: 11 -> 31 -> 15 -> 3 -> 1 -> 0 -> 11.
        for (final expectedFlags in const [31, 15, 3, 1, 0, 11]) {
          wireOut.clear();
          wireInput.add(utf8.encode('k'));
          await _pumpEventQueue();
          expect(wireOut.toString(), contains('\x1b[=$expectedFlags;1u'));
        }

        stopHandle.stop();
        await runFuture.timeout(const Duration(seconds: 3));
        backend.dispose();
        await wireInput.close();
      },
    );

    test(
      '[R] re-probe and [D] delete toggle do not blank live U=1 showcase tiles in VirtualTerminal',
      () async {
        final replies = StreamController<List<int>>.broadcast();
        final vt = VirtualTerminal(
          width: 90,
          height: 28,
          defaultForeground: const Color(220, 228, 240),
          defaultBackground: const Color(18, 22, 32),
          onReply: (reply) {
            final bytes = utf8.encode(reply);
            scheduleMicrotask(() {
              if (!replies.isClosed) replies.add(bytes);
            });
          },
        );
        final report = KttyProbeReport();
        final backend = KttyWireTerminalBackend(
          wireInput: replies.stream,
          onWriteWire: vt.writeString,
          report: report,
          initialSize: const Point<int>(90, 28),
        );
        final stopHandle = KttyProbeStopHandle();

        final runFuture = runKttyProbeOnWire(
          backend,
          probeTimeout: const Duration(milliseconds: 500),
          stopHandle: stopHandle,
        );

        await _pumpEventQueue(16);
        // Switch to Tab 3 (Graphics & SGR) and disable occlusion so all 4 tiles are fully visible.
        replies.add(utf8.encode('3o'));
        await _pumpEventQueue(16);

        const visualIds = [
          kttyVisualRgbaImageId,
          kttyVisual32BitImageId,
          kttyVisualPngImageId,
          kttyVisualShorthandImageId,
        ];

        final beforeCounts = _countPlaceholderCellsByImageId(vt.buffer);
        for (final id in visualIds) {
          expect(vt.imageRegistry.lookupImage(id), isNotNull);
          expect(beforeCounts[id], equals(48));
        }

        final beforeRuns = report.probeRunCount;
        // Trigger [R] re-probe and verify completion leaves all live U=1 tiles intact.
        replies.add(utf8.encode('r'));
        await _pumpEventQueue(20);
        expect(report.probeRunCount, equals(beforeRuns + 1));
        expect(report.isComplete, isTrue);

        final afterReprobeCounts = _countPlaceholderCellsByImageId(vt.buffer);
        for (final id in visualIds) {
          expect(vt.imageRegistry.lookupImage(id), isNotNull);
          expect(afterReprobeCounts[id], equals(48));
        }

        // Trigger [D] (d=a then d=A) and verify live U=1 virtual tiles survive both.
        replies.add(utf8.encode('dd'));
        await _pumpEventQueue(16);
        final afterDeleteCounts = _countPlaceholderCellsByImageId(vt.buffer);
        for (final id in visualIds) {
          expect(vt.imageRegistry.lookupImage(id), isNotNull);
          expect(afterDeleteCounts[id], equals(48));
        }

        stopHandle.stop();
        await runFuture.timeout(const Duration(seconds: 3));
        backend.dispose();
        await replies.close();
        vt.dispose();
      },
    );

    test(
      'runKttyBatchProbe and runKttyProbeOnWire forward KttyProbeOptions',
      () async {
        final wireInput = StreamController<List<int>>.broadcast();
        final emitted = StringBuffer();

        final future = runKttyBatchProbe(
          wireInput: wireInput.stream,
          onWriteWire: emitted.write,
          timeout: const Duration(milliseconds: 200),
          options: const KttyProbeOptions(wrapTmuxPassthrough: true),
        );
        wireInput.add(ascii.encode('\x1b[?62;22c'));
        final report = await future;

        expect(report.isComplete, isTrue);
        expect(emitted.toString(), contains('\x1bPtmux;'));

        final interactiveOut = StringBuffer();
        final interactiveBackend = KttyWireTerminalBackend(
          wireInput: wireInput.stream,
          onWriteWire: interactiveOut.write,
          report: KttyProbeReport(),
          initialSize: const Point<int>(100, 30),
        );
        final stopHandle = KttyProbeStopHandle();
        final interactiveFuture = runKttyProbeOnWire(
          interactiveBackend,
          probeTimeout: const Duration(milliseconds: 200),
          stopHandle: stopHandle,
          options: const KttyProbeOptions(wrapTmuxPassthrough: true),
        );
        await _pumpEventQueue();
        wireInput.add(utf8.encode('3'));
        await _pumpEventQueue(16);
        final outText = interactiveOut.toString();
        final uploadIdx = outText.lastIndexOf(
          'a=p,U=1,i=$kttyVisualShorthandImageId,c=',
        );
        expect(uploadIdx, greaterThanOrEqualTo(0));
        final p1Seq = wrapTmuxDcsPassthrough(
          '\x1b_Ga=p,U=1,i=$kttyVisualShorthandImageId,p=1,c=12,r=4,q=2\x1b\\',
        );
        final p2Seq = wrapTmuxDcsPassthrough(
          '\x1b_Ga=p,U=1,i=$kttyVisualShorthandImageId,p=2,c=12,r=4,q=2\x1b\\',
        );
        expect(outText, contains(p1Seq));
        expect(outText, contains(p2Seq));
        expect(outText.indexOf(p1Seq), greaterThan(uploadIdx));
        expect(outText.indexOf(p2Seq), greaterThan(uploadIdx));
        stopHandle.stop();
        await interactiveFuture.timeout(const Duration(seconds: 3));
        interactiveBackend.dispose();
        await wireInput.close();
      },
    );
  });
}
