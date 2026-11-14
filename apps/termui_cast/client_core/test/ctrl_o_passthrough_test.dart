import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/terminal/input_parser.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

import 'support/fake_three_way_ws_harness.dart';

BufferSnapshot _snapshotWithKittyFlags(
  SessionId id, {
  required int seq,
  required int kittyKeyboardFlags,
}) => BufferSnapshot.fromBuffer(
  sessionId: id,
  seq: seq,
  buffer: Buffer.blank(80, 24),
  cursor: CursorState.origin,
  modes: TerminalModes(kittyKeyboardFlags: kittyKeyboardFlags),
);

void main() {
  const sessId = SessionId('ctrl-o-sess');

  group('Ctrl+O passthrough and KTTY normalization', () {
    test(
      'normalizes C0 and CapsLock Ctrl+O across KTTY and legacy modes with InputParser round-trip parity',
      () async {
        final pipe = StreamChannelController<Uint8List>();
        final wireInputs = <Uint8List>[];
        pipe.foreign.stream.listen((raw) {
          if (BufferFrameCodec.decode(raw) case InputFrame(:final data)) {
            wireInputs.add(data);
          }
        });

        final transport = WsClientTransport(
          channelFactory: () async => pipe.local,
        );
        final repo = CastClientRepository(transport: transport);
        final vm = CastWorkspaceViewModel(repository: repo);
        addTearDown(() async {
          await vm.dispose();
          await repo.dispose();
        });

        await repo.connect();
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessId, title: 'jetski', cols: 80, rows: 24),
              ],
            ),
          ),
        );
        // Enable Kitty disambiguate mode (`\x1b[=1;1u`, kittyKeyboardFlags: 1), matching jetski.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _snapshotWithKittyFlags(
                sessId,
                seq: 1,
                kittyKeyboardFlags: 1,
              ),
            ),
          ),
        );
        await pumpEventQueue();

        final ctrlOVariants = <ev.KeyEvent>[
          // 1. Native desktop embedders: character is C0 0x0f with Modifier.control.
          const ev.KeyEvent('\x0f', .character, modifiers: {.control}),
          // 2. Raw C0 byte injection without explicit Modifier.control.
          const ev.KeyEvent('\x0f', .character),
          // 3. Browser with CapsLock active: uppercase 'O' with Modifier.control and no Shift.
          const ev.KeyEvent('O', .character, modifiers: {.control}),
          // 4. Standard lowercase browser 'o' with Modifier.control.
          const ev.KeyEvent('o', .character, modifiers: {.control}),
        ];

        final parser = InputParser();
        for (final variant in ctrlOVariants) {
          wireInputs.clear();
          check(vm.encodeAndSendKey(variant)).isTrue();
          await pumpEventQueue();
          check(wireInputs).length.equals(1);
          check(utf8.decode(wireInputs.single)).equals('\x1b[111;5u');
          final decoded = parser.parse(wireInputs.single);
          check(decoded).deepEquals(const [
            ev.KeyEvent('o', .character, modifiers: {.control}),
          ]);
        }

        // C0 punctuation bytes (`^@`, `^\`, `^]`, `^^`, `^_`) also encode valid KTTY base codepoints.
        wireInputs.clear();
        for (final rawC0 in const ['\x00', '\x1c', '\x1d', '\x1e', '\x1f']) {
          check(
            vm.encodeAndSendKey(
              ev.KeyEvent(rawC0, .character, modifiers: const {.control}),
            ),
          ).isTrue();
        }
        await pumpEventQueue();
        check([for (final b in wireInputs) utf8.decode(b)]).deepEquals(const [
          '\x1b[32;5u',
          '\x1b[92;5u',
          '\x1b[93;5u',
          '\x1b[94;5u',
          '\x1b[95;5u',
        ]);

        // Enable reportEvents (`kittyKeyboardFlags: 3`) -> release of C0 and CapsLock Ctrl+O emits `;5:3u`.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _snapshotWithKittyFlags(
                sessId,
                seq: 2,
                kittyKeyboardFlags: 3,
              ),
            ),
          ),
        );
        await pumpEventQueue();
        wireInputs.clear();
        check(
          vm.encodeAndSendKey(
            const ev.KeyEvent(
              '\x0f',
              .character,
              modifiers: {.control},
              eventType: .release,
            ),
          ),
        ).isTrue();
        check(
          vm.encodeAndSendKey(
            const ev.KeyEvent(
              'O',
              .character,
              modifiers: {.control},
              eventType: .release,
            ),
          ),
        ).isTrue();
        await pumpEventQueue();
        check([
          for (final b in wireInputs) utf8.decode(b),
        ]).deepEquals(const ['\x1b[111;5:3u', '\x1b[111;5:3u']);

        // Enable reportAlternates (`kittyKeyboardFlags: 5`) -> genuine Ctrl+Shift+O preserves shifted codepoint 79.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _snapshotWithKittyFlags(
                sessId,
                seq: 3,
                kittyKeyboardFlags: 5,
              ),
            ),
          ),
        );
        await pumpEventQueue();
        wireInputs.clear();
        check(
          vm.encodeAndSendKey(
            const ev.KeyEvent('O', .character, modifiers: {.control, .shift}),
          ),
        ).isTrue();
        await pumpEventQueue();
        check(utf8.decode(wireInputs.single)).equals('\x1b[111:79;6u');

        // Legacy mode (`kittyKeyboardFlags: 0`) -> all Ctrl+O variants emit raw 0x0f.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _snapshotWithKittyFlags(
                sessId,
                seq: 4,
                kittyKeyboardFlags: 0,
              ),
            ),
          ),
        );
        await pumpEventQueue();
        for (final variant in ctrlOVariants) {
          wireInputs.clear();
          check(vm.encodeAndSendKey(variant)).isTrue();
          await pumpEventQueue();
          check(wireInputs.single).deepEquals(const [0x0f]);
        }
      },
    );

    test(
      'keeps debugToggleKey disabled across overlapping CastSceneController mount and dispose lifecycles',
      () async {
        final terminalA = MockTerminal(
          MockTerminalBackend(size: const Point(80, 24)),
        );
        final terminalB = MockTerminal(
          MockTerminalBackend(size: const Point(80, 24)),
        );
        final harness = FakeThreeWayWsHarness();
        final caster = await harness.startCaster(id: 'overlap', title: 'zsh');
        final viewerA = await harness.connectViewer();
        final viewerB = await harness.connectViewer();
        final priorDebugToggleKey = debugToggleKey;

        final controllerA = CastSceneController(
          terminal: terminalA,
          viewModel: viewerA.viewModel,
        );
        final controllerB = CastSceneController(
          terminal: terminalB,
          viewModel: viewerB.viewModel,
        );
        addTearDown(() async {
          controllerA.dispose();
          controllerB.dispose();
          terminalA.dispose();
          terminalB.dispose();
          debugToggleKey = priorDebugToggleKey;
          await harness.dispose();
        });

        await pumpEventQueue();

        // Disposing controllerA while controllerB is still mounted leaves global
        // debugToggleKey untouched and still forwards Ctrl+O without debug overlays.
        controllerA.dispose();
        check(debugToggleKey).equals(priorDebugToggleKey);
        check(controllerB.sceneManager.enableDebugToggleKey).isFalse();

        caster.pty.writtenInputs.clear();
        controllerB.sceneManager.handleKeyEvent(
          const ev.KeyEvent('o', .character, modifiers: {.control}),
        );
        await pumpEventQueue();

        check(debugPaintLayerBordersEnabled).isFalse();
        check(caster.pty.writtenInputs).length.equals(1);
        check(caster.pty.writtenInputs.single).deepEquals(const [0x0f]);

        // Even with a modal dialog (PromptRunner(mode: .managed)) open, Ctrl+O
        // does not toggle global debug overlays.
        controllerB.sceneManager.handleKeyEvent(
          const ev.KeyEvent(r'\', .character, modifiers: {.control}),
        );
        controllerB.sceneManager.handleKeyEvent(
          const ev.KeyEvent(',', .character),
        );
        await pumpEventQueue();
        check(controllerB.isSettingsDialogOpen).isTrue();

        controllerB.sceneManager.handleKeyEvent(
          const ev.KeyEvent('o', .character, modifiers: {.control}),
        );
        await pumpEventQueue();
        check(debugPaintLayerBordersEnabled).isFalse();
        check(debugShowTouchesEnabled).isFalse();
        check(debugPaintHoverEnabled).isFalse();
        check(debugMouseCursorEnabled).isFalse();

        controllerB.sceneManager.handleKeyEvent(
          const ev.KeyEvent('escape', .escape),
        );
        await pumpEventQueue();
        check(controllerB.isSettingsDialogOpen).isFalse();

        // Disposing the last active controller leaves prior debugToggleKey intact.
        controllerB.dispose();
        check(debugToggleKey).equals(priorDebugToggleKey);
      },
    );
  });
}
