import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/settings_storage_io.dart';
import 'package:fterm/src/workspace/fterm_pane_controller.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver_io.dart';
import 'package:fterm/src/workspace/split_tree_model.dart';
import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_audio_flutter/termui_audio_flutter.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_pty/termui_pty.dart';

import 'support/app_three_way_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _defineSplitTreeModelTests();
  _defineAudioControllerTests();
  _defineWorkspaceControllerTests();
  _defineHardeningRegressionTests();
  _defineWave2HardeningTests();
}

void _defineSplitTreeModelTests() {
  group('SplitTreeModel', () {
    test(
      'builds 4-pane grid, computes normalized rects & stereo pan, and navigates hjkl directionally',
      () {
        var tree = SplitTreeModel.single('p1')
            .splitPane(
              targetPaneId: 'p1',
              newPaneId: 'p2',
              axis: SplitAxis.horizontal,
              splitId: 's-h',
            )
            .focusPane('p1')
            .splitPane(
              targetPaneId: 'p1',
              newPaneId: 'p3',
              axis: SplitAxis.vertical,
              splitId: 's-v1',
            )
            .focusPane('p2')
            .splitPane(
              targetPaneId: 'p2',
              newPaneId: 'p4',
              axis: SplitAxis.vertical,
              splitId: 's-v2',
            );

        expect(tree.paneIds, equals(['p1', 'p3', 'p2', 'p4']));
        expect(tree.focusedPaneId, equals('p4'));
        expect(tree.panOf('p1'), closeTo(-0.5, 1e-6));
        expect(tree.panOf('p4'), closeTo(0.5, 1e-6));

        // 4 -> k (up to p2) -> h (left to p1) -> j (down to p3) -> l (right to p4)
        tree = tree.focusDirection(FocusDirection.up);
        expect(tree.focusedPaneId, equals('p2'));
        tree = tree.focusDirection(FocusDirection.left);
        expect(tree.focusedPaneId, equals('p1'));
        tree = tree.focusDirection(FocusDirection.down);
        expect(tree.focusedPaneId, equals('p3'));
        tree = tree.focusDirection(FocusDirection.right);
        expect(tree.focusedPaneId, equals('p4'));

        // Ratio clamps cleanly to [0.1, 0.9] and shifts stereo pan.
        tree = tree.setSplitRatio('s-h', 0.02);
        expect(tree.rectOf('p1')!.width, closeTo(0.1, 1e-6));
        expect(tree.panOf('p1'), closeTo(-0.9, 1e-6));
        tree = tree.setSplitRatio('s-h', 0.99);
        expect(tree.rectOf('p1')!.width, closeTo(0.9, 1e-6));
      },
    );

    test(
      'toggles tmux zoom cleanly and promotes siblings until final leaf returns null',
      () {
        var tree = SplitTreeModel.single('p1');
        expect(tree.toggleZoom().isZoomed, isFalse);

        tree = tree.splitPane(
          targetPaneId: 'p1',
          newPaneId: 'p2',
          axis: SplitAxis.horizontal,
        );
        tree = tree.toggleZoom();
        expect(tree.isZoomed, isTrue);
        expect(tree.zoomedPaneId, equals('p2'));

        // Focusing p1 exits zoom automatically.
        tree = tree.focusPane('p1');
        expect(tree.isZoomed, isFalse);

        final afterClose = tree.closePane('p1');
        expect(afterClose, isNotNull);
        expect(afterClose!.paneIds, equals(['p2']));
        expect(afterClose.focusedPaneId, equals('p2'));
        expect(afterClose.closePane('p2'), isNull);
      },
    );
  });
}

void _defineAudioControllerTests() {
  group('FtermAudioController', () {
    test(
      'gates engine initialization behind first gesture, pans BEL chimes, handles APC tones/clips, and recovers from init failure',
      () async {
        final fakeEngine = _FakeAudioEngine()..failNextInit = true;
        var currentTime = DateTime(2026, 1, 1, 12);
        final controller = FtermAudioController(
          engineFactory: () => fakeEngine,
          clock: Clock(() => currentTime),
        );

        // Before user gesture: no engine init.
        await controller.playBell(pan: -0.75);
        expect(fakeEngine.initCalls, equals(0));
        expect(controller.isInitialized, isFalse);

        // First gesture hits transient WASM failure -> cleans state & stays safe.
        await controller.notifyUserGesture();
        expect(fakeEngine.initCalls, equals(1));
        expect(controller.isInitialized, isFalse);

        // Next gesture retries and succeeds.
        await controller.notifyUserGesture();
        expect(fakeEngine.initCalls, equals(2));
        expect(controller.isInitialized, isTrue);

        // Stereo-panned BEL chime (respects cooldown).
        await controller.playBell(pan: -0.5);
        expect(fakeEngine.loadedWaveforms.last, equals((WaveForm.sin, 880.0)));
        expect(fakeEngine.lastVoicePan, closeTo(-0.5, 1e-6));
        await controller.playBell(pan: 0.5);
        expect(fakeEngine.playedVoices, hasLength(1));

        currentTime = currentTime.add(const Duration(milliseconds: 100));
        await controller.playBell(pan: 0.75);
        expect(fakeEngine.playedVoices, hasLength(2));
        expect(fakeEngine.lastVoicePan, closeTo(0.75, 1e-6));

        // APC tone & clip & stop.
        await controller.handleAudioEvent(
          const TerminalToneAudioEvent(
            waveform: 'sine',
            frequencyHz: 440,
            duration: Duration(milliseconds: 120),
            volume: 0.5,
          ),
          fallbackPan: -0.25,
        );
        expect(fakeEngine.loadedWaveforms.last, equals((WaveForm.sin, 440.0)));
        expect(fakeEngine.lastVoicePan, closeTo(-0.25, 1e-6));

        await controller.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 7,
            format: 'wav',
            bytes: Uint8List.fromList(const [1, 2, 3, 4]),
            loop: true,
          ),
          fallbackPan: 0.6,
        );
        expect(fakeEngine.lastLoadedMemId, equals('fterm-clip-default-7.wav'));
        expect(fakeEngine.lastVoicePan, closeTo(0.6, 1e-6));

        // Mute silences active voice volumes without throwing.
        controller.setMuted(true);
        expect(fakeEngine.lastVoiceVolume, equals(0.0));
        controller.setMuted(false);
        expect(fakeEngine.lastVoiceVolume, greaterThan(0.0));

        await controller.handleAudioEvent(
          const TerminalStopAudioEvent(clipId: 7),
        );
        expect(fakeEngine.stoppedVoiceIds, isNotEmpty);

        // One-shot tone clamping (<= 10s, 20..20000 Hz), 25ms tone cooldown, and stop(null) clears one-shot voices.
        currentTime = currentTime.add(const Duration(milliseconds: 50));
        await controller.handleAudioEvent(
          const TerminalToneAudioEvent(
            waveform: 'sine',
            frequencyHz: 99999,
            duration: Duration(hours: 1),
          ),
        );
        expect(
          fakeEngine.loadedWaveforms.last,
          equals((WaveForm.sin, 20000.0)),
        );
        expect(
          fakeEngine.lastScheduledStopDuration,
          equals(const Duration(seconds: 10)),
        );
        // Immediate tone within 25ms is dropped by cooldown.
        final countBeforeCooldownDrop = fakeEngine.playedVoices.length;
        await controller.handleAudioEvent(
          const TerminalToneAudioEvent(
            waveform: 'sine',
            frequencyHz: 500,
            duration: Duration(milliseconds: 40),
          ),
        );
        expect(fakeEngine.playedVoices.length, equals(countBeforeCooldownDrop));

        // Stop(clipId: null) stops active one-shot voices as well.
        final stoppedBefore = fakeEngine.stoppedVoiceIds.length;
        await controller.handleAudioEvent(const TerminalStopAudioEvent());
        expect(fakeEngine.stoppedVoiceIds.length, greaterThan(stoppedBefore));

        await controller.dispose();
        expect(fakeEngine.disposed, isTrue);
      },
    );

    test(
      'caps init retries with 2s cooldown, guards single dispose during init, dedupes concurrent loads, stops clip on reload, and caps voices',
      () async {
        // 1. Init retry backoff: 1st retry immediate, 2nd retry gated by 2s cooldown, capped at 3 attempts.
        var now = DateTime(2026, 1, 1, 12);
        final alwaysFailEngine = _FakeAudioEngine()..alwaysFailInit = true;
        final backoffCtrl = FtermAudioController(
          engineFactory: () => alwaysFailEngine,
          clock: Clock(() => now),
        );
        await backoffCtrl.notifyUserGesture();
        expect(alwaysFailEngine.initCalls, equals(1));
        await backoffCtrl.notifyUserGesture();
        expect(alwaysFailEngine.initCalls, equals(2));
        // Rapid gesture before 2s cooldown is skipped.
        await backoffCtrl.notifyUserGesture();
        expect(alwaysFailEngine.initCalls, equals(2));
        // After 2s cooldown, attempt 3 runs; subsequent gestures past cap of 3 stop retrying.
        now = now.add(const Duration(seconds: 3));
        await backoffCtrl.notifyUserGesture();
        expect(alwaysFailEngine.initCalls, equals(3));
        now = now.add(const Duration(seconds: 10));
        await backoffCtrl.notifyUserGesture();
        expect(alwaysFailEngine.initCalls, equals(3));
        await backoffCtrl.dispose();

        // 2. Single engine.dispose() when dispose() races pending init().
        final initGate = Completer<void>();
        final racingEngine = _FakeAudioEngine()..pendingInitGate = initGate;
        final racingCtrl = FtermAudioController(
          engineFactory: () => racingEngine,
          requireUserGesture: false,
        );
        final gestureFuture = racingCtrl.notifyUserGesture();
        await Future<void>.delayed(Duration.zero);
        await racingCtrl.dispose();
        initGate.complete();
        await gestureFuture;
        expect(racingEngine.disposeCalls, equals(1));

        // 3. Concurrent tone buffer load dedupe, clip reload stop, and voice caps (16 one-shot / 8 clip).
        var capTime = DateTime(2026, 1, 1, 13);
        final capEngine = _FakeAudioEngine()..throwOnStop = false;
        final capCtrl = FtermAudioController(
          engineFactory: () => capEngine,
          clock: Clock(() => capTime),
          requireUserGesture: false,
        );
        await capCtrl.notifyUserGesture();

        // Concurrent loadWaveform for identical key disposes duplicate buffer.
        final toneGate = Completer<void>();
        capEngine.pendingLoadGate = toneGate;
        final t1 = capCtrl.playBell();
        capTime = capTime.add(const Duration(milliseconds: 100));
        final t2 = capCtrl.playBell();
        await Future<void>.delayed(Duration.zero);
        toneGate.complete();
        await Future.wait([t1, t2]);
        expect(capEngine.disposedBufferCount, equals(1));
        capEngine.pendingLoadGate = null;

        // Reloading same clipId stops active voices even if engine.stop throws.
        await capCtrl.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 42,
            format: 'wav',
            bytes: Uint8List.fromList(const [1, 2]),
            loop: true,
          ),
        );
        capEngine.throwOnStop = true;
        await capCtrl.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 42,
            format: 'wav',
            bytes: Uint8List.fromList(const [3, 4]),
            loop: true,
          ),
        );
        capEngine.throwOnStop = false;
        expect(capEngine.stoppedVoiceIds, isNotEmpty);

        // One-shot voice cap <= 16 (2 prior bell voices + 18 new = 20 -> 4 evicted) and clip voice cap <= 8 evict oldest.
        final stopsBeforeOneShotCap = capEngine.stoppedVoiceIds.length;
        for (var i = 0; i < 18; i++) {
          capTime = capTime.add(const Duration(milliseconds: 100));
          await capCtrl.playBell();
        }
        expect(
          capEngine.stoppedVoiceIds.length - stopsBeforeOneShotCap,
          equals(4),
        );

        // Clip 42 is still active + 10 loop clips = 11 -> 3 evicted for <= 8 cap.
        final stopsBeforeClipCap = capEngine.stoppedVoiceIds.length;
        for (var i = 0; i < 10; i++) {
          await capCtrl.handleAudioEvent(
            TerminalClipAudioEvent(
              clipId: 100 + i,
              format: 'wav',
              bytes: Uint8List.fromList([i]),
              loop: true,
            ),
          );
        }
        expect(
          capEngine.stoppedVoiceIds.length - stopsBeforeClipCap,
          equals(3),
        );
        await capCtrl.dispose();
      },
    );

    test(
      'applies live TerminalUpdateAudioEvent to active voices and handles in-flight init/loadMem updates, stops, and superseded loads',
      () async {
        // 1. Live update on active voice, including explicit pan: 0.0 inside non-zero fallbackPan split pane.
        final liveEngine = _FakeAudioEngine();
        final liveCtrl = FtermAudioController(
          engineFactory: () => liveEngine,
          initialVolume: 0.5,
          requireUserGesture: false,
        );
        await liveCtrl.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 1,
            format: 'ogg',
            bytes: Uint8List.fromList(const [1, 2, 3]),
            loop: true,
          ),
          fallbackPan: 0.6,
        );
        final v1 = liveEngine.playedVoices.single;
        expect(liveEngine.voicePans[v1.id], closeTo(0.6, 1e-6));
        expect(liveEngine.voiceVolumes[v1.id], closeTo(0.5, 1e-6));

        await liveCtrl.handleAudioEvent(
          const TerminalUpdateAudioEvent(clipId: 1, volume: 0.8),
          fallbackPan: 0.6,
        );
        expect(liveEngine.voicePans[v1.id], closeTo(0.6, 1e-6));
        expect(liveEngine.voiceVolumes[v1.id], closeTo(0.4, 1e-6));

        await liveCtrl.handleAudioEvent(
          const TerminalUpdateAudioEvent(clipId: 1, pan: 0.0),
          fallbackPan: 0.6,
        );
        expect(liveEngine.voicePans[v1.id], equals(0.0));
        expect(liveEngine.voiceVolumes[v1.id], closeTo(0.4, 1e-6));

        // Mute/unmute preserves updated base volume (0.8 * 0.5 = 0.4).
        liveCtrl.setMuted(true);
        expect(liveEngine.voiceVolumes[v1.id], equals(0.0));
        liveCtrl.setMuted(false);
        expect(liveEngine.voiceVolumes[v1.id], closeTo(0.4, 1e-6));

        // Muted live update still records updated base volume for later unmute.
        liveCtrl.setMuted(true);
        await liveCtrl.handleAudioEvent(
          const TerminalUpdateAudioEvent(clipId: 1, volume: 0.2, pan: -0.5),
        );
        expect(liveEngine.voicePans[v1.id], closeTo(-0.5, 1e-6));
        expect(liveEngine.voiceVolumes[v1.id], equals(0.0));
        liveCtrl.setMuted(false);
        expect(liveEngine.voiceVolumes[v1.id], closeTo(0.1, 1e-6));
        await liveCtrl.dispose();

        // 2. Updates arriving while init() or loadMem() is awaiting apply on playback start.
        final initGate = Completer<void>();
        final memGate = Completer<void>();
        final pendingEngine = _FakeAudioEngine()
          ..pendingInitGate = initGate
          ..pendingMemLoadGate = memGate;
        final pendingCtrl = FtermAudioController(
          engineFactory: () => pendingEngine,
          initialVolume: 1.0,
          requireUserGesture: false,
        );
        final playFuture = pendingCtrl.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 2,
            format: 'ogg',
            bytes: Uint8List.fromList(const [4, 5, 6]),
          ),
          fallbackPan: 0.5,
        );
        await Future<void>.delayed(Duration.zero);
        await pendingCtrl.handleAudioEvent(
          const TerminalUpdateAudioEvent(clipId: 2, volume: 0.6),
        );
        initGate.complete();
        await Future<void>.delayed(Duration.zero);
        await pendingCtrl.handleAudioEvent(
          const TerminalUpdateAudioEvent(clipId: 2, pan: -0.75),
        );
        memGate.complete();
        await playFuture;
        final v2 = pendingEngine.playedVoices.single;
        expect(pendingEngine.voiceVolumes[v2.id], closeTo(0.6, 1e-6));
        expect(pendingEngine.voicePans[v2.id], closeTo(-0.75, 1e-6));
        await pendingCtrl.dispose();

        // 3. Stop arriving during lazy init (_engine == null) cancels playback.
        final cancelInitGate = Completer<void>();
        final cancelInitEngine = _FakeAudioEngine()
          ..pendingInitGate = cancelInitGate;
        final cancelInitCtrl = FtermAudioController(
          engineFactory: () => cancelInitEngine,
          requireUserGesture: false,
        );
        final cancelledByInitFuture = cancelInitCtrl.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 3,
            format: 'wav',
            bytes: Uint8List.fromList(const [1]),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await cancelInitCtrl.handleAudioEvent(
          const TerminalStopAudioEvent(clipId: 3),
        );
        cancelInitGate.complete();
        await cancelledByInitFuture;
        expect(cancelInitEngine.playedVoices, isEmpty);
        await cancelInitCtrl.dispose();

        // 4. Stop during loadMem() cancels playback and disposes loaded buffer;
        //    superseded concurrent clip load disposes stale buffer without stopping newer voice.
        final raceEngine = _FakeAudioEngine();
        final raceCtrl = FtermAudioController(
          engineFactory: () => raceEngine,
          requireUserGesture: false,
        );
        await raceCtrl.notifyUserGesture();

        final stopMemGate = Completer<void>();
        raceEngine.pendingMemLoadGate = stopMemGate;
        final stoppedLoadFuture = raceCtrl.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 4,
            format: 'wav',
            bytes: Uint8List.fromList(const [1, 2]),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await raceCtrl.handleAudioEvent(
          const TerminalStopAudioEvent(clipId: 4),
        );
        stopMemGate.complete();
        await stoppedLoadFuture;
        expect(raceEngine.playedVoices, isEmpty);
        expect(raceEngine.disposedBufferCount, equals(1));

        // Superseded concurrent TerminalClipAudioEvent for same clipId.
        final firstGate = Completer<void>();
        raceEngine.pendingMemLoadGate = firstGate;
        final firstClipFuture = raceCtrl.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 5,
            format: 'wav',
            bytes: Uint8List.fromList(const [10]),
            loop: true,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        raceEngine.pendingMemLoadGate = null;
        await raceCtrl.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 5,
            format: 'wav',
            bytes: Uint8List.fromList(const [20]),
            loop: true,
          ),
        );
        expect(raceEngine.playedVoices, hasLength(1));
        final newerVoice = raceEngine.playedVoices.single;

        firstGate.complete();
        await firstClipFuture;
        expect(raceEngine.playedVoices, hasLength(1));
        expect(raceEngine.stoppedVoiceIds, isNot(contains(newerVoice.id)));
        expect(raceEngine.disposedBufferCount, equals(2));
        await raceCtrl.dispose();
      },
    );

    test(
      'applies transport/fade/stop updates across pending and active voices and isolates ScopedAudioId scopes',
      () async {
        final engine = _FakeAudioEngine();
        final ctrl = FtermAudioController(
          engineFactory: () => engine,
          initialVolume: 0.5,
          requireUserGesture: false,
        );

        // 1. Pending clip with startOffset + deferred transport/fade/stop updates.
        final memGate = Completer<void>();
        engine.pendingMemLoadGate = memGate;
        final pendingPlay = ctrl.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 1,
            format: 'ogg',
            bytes: Uint8List.fromList(const [1, 2, 3]),
            startOffset: const Duration(milliseconds: 250),
            loop: true,
          ),
          scopeKey: 'scope-a',
        );
        await Future<void>.delayed(Duration.zero);
        await ctrl.handleAudioEvent(
          const TerminalUpdateAudioEvent(
            clipId: 1,
            seekPosition: Duration(milliseconds: 600),
            speed: 1.5,
            preservePitch: true,
            fadeVolumeTarget: 0.8,
            fadeVolumeDuration: Duration(milliseconds: 200),
            fadeSpeedTarget: 0.75,
            fadeSpeedDuration: Duration(milliseconds: 400),
            scheduleStopDuration: Duration(milliseconds: 900),
          ),
          scopeKey: 'scope-a',
        );
        memGate.complete();
        engine.pendingMemLoadGate = null;
        await pendingPlay;

        final vA = engine.playedVoices.single;
        expect(
          engine.voiceSeeks[vA.id],
          equals(const Duration(milliseconds: 600)),
        );
        expect(engine.voiceSpeeds[vA.id], equals((1.5, true)));
        expect(
          engine.voiceVolumeFades[vA.id],
          equals((0.4, const Duration(milliseconds: 200))),
        );
        expect(
          engine.voiceSpeedFades[vA.id],
          equals((0.75, const Duration(milliseconds: 400))),
        );
        expect(
          engine.voiceScheduledStops[vA.id],
          equals(const Duration(milliseconds: 900)),
        );

        // Mute/unmute reflects fade target base volume (0.8 * 0.5 = 0.4).
        ctrl.setMuted(true);
        expect(engine.voiceVolumes[vA.id], equals(0.0));
        ctrl.setMuted(false);
        expect(engine.voiceVolumes[vA.id], closeTo(0.4, 1e-6));

        // Active voice updates: pause, resume, seek, speed with preservePitch: true.
        await ctrl.handleAudioEvent(
          const TerminalUpdateAudioEvent(
            clipId: 1,
            paused: true,
            seekPosition: Duration(milliseconds: 1200),
            speed: 0.5,
            preservePitch: true,
          ),
          scopeKey: 'scope-a',
        );
        expect(engine.voicePauses[vA.id], isTrue);
        expect(
          engine.voiceSeeks[vA.id],
          equals(const Duration(milliseconds: 1200)),
        );
        expect(engine.voiceSpeeds[vA.id], equals((0.5, true)));

        // Same clipId=1 in scope-b does not collide with scope-a.
        await ctrl.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 1,
            format: 'wav',
            bytes: Uint8List.fromList(const [9, 8, 7]),
            loop: true,
          ),
          scopeKey: 'scope-b',
        );
        final vB = engine.playedVoices.last;
        expect(engine.stoppedVoiceIds, isNot(contains(vA.id)));

        // Global a=stop in scope-a leaves scope-b untouched.
        await ctrl.handleAudioEvent(
          const TerminalStopAudioEvent(),
          scopeKey: 'scope-a',
        );
        expect(engine.stoppedVoiceIds, contains(vA.id));
        expect(engine.stoppedVoiceIds, isNot(contains(vB.id)));

        // disposeScope('scope-a') disposes only scope-a cached buffers.
        final disposedBefore = engine.disposedBufferCount;
        ctrl.disposeScope('scope-a');
        expect(engine.disposedBufferCount, equals(disposedBefore + 1));
        expect(engine.stoppedVoiceIds, isNot(contains(vB.id)));

        ctrl.disposeScope('scope-b');
        expect(engine.stoppedVoiceIds, contains(vB.id));
        expect(engine.disposedBufferCount, equals(disposedBefore + 2));
        await ctrl.dispose();
      },
    );

    test(
      'manages scoped mixing buses (cap=4, filters, late-joiner null fallback, pending destroy, and dispose cleanup)',
      () async {
        final engine = _FakeAudioEngine();
        final ctrl = FtermAudioController(
          engineFactory: () => engine,
          requireUserGesture: false,
        );

        // 1. Pending bus create cancelled by destroy during lazy init.
        final initGate = Completer<void>();
        engine.pendingInitGate = initGate;
        final pendingCreate = ctrl.handleAudioEvent(
          const TerminalBusAudioEvent(op: 'create', busId: 99),
          scopeKey: 'scope-init',
        );
        await Future<void>.delayed(Duration.zero);
        await ctrl.handleAudioEvent(
          const TerminalBusAudioEvent(op: 'destroy', busId: 99),
          scopeKey: 'scope-init',
        );
        initGate.complete();
        await pendingCreate;
        expect(engine.createdBuses, isEmpty);

        // 2. Pending bus create followed immediately by attach/vol/param/fade while init completes.
        final initGate2 = Completer<void>();
        final engine2 = _FakeAudioEngine()..pendingInitGate = initGate2;
        final ctrl2 = FtermAudioController(
          engineFactory: () => engine2,
          requireUserGesture: false,
        );
        final createF = ctrl2.handleAudioEvent(
          const TerminalBusAudioEvent(op: 'create', busId: 1),
          scopeKey: 's1',
        );
        final attachF = ctrl2.handleAudioEvent(
          const TerminalBusAudioEvent(op: 'attach', busId: 1, filterId: 7),
          scopeKey: 's1',
        );
        final volF = ctrl2.handleAudioEvent(
          const TerminalBusAudioEvent(op: 'vol', busId: 1, value: 0.45),
          scopeKey: 's1',
        );
        final paramF = ctrl2.handleAudioEvent(
          const TerminalBusAudioEvent(
            op: 'param',
            busId: 1,
            filterId: 7,
            paramId: 2,
            value: 0.8,
          ),
          scopeKey: 's1',
        );
        final fadeF = ctrl2.handleAudioEvent(
          const TerminalBusAudioEvent(
            op: 'fade',
            busId: 1,
            filterId: 7,
            paramId: 2,
            value: 0.2,
            duration: Duration(milliseconds: 150),
          ),
          scopeKey: 's1',
        );
        initGate2.complete();
        await Future.wait([createF, attachF, volF, paramF, fadeF]);
        final b1 = engine2.createdBuses.single;
        expect(b1.volume, closeTo(0.45, 1e-6));
        expect(engine2.attachedFilters, equals([(b1.id, 7)]));
        expect(engine2.filterParams, equals([(b1.id, 7, 2, 0.8)]));
        expect(
          engine2.filterFades,
          equals([(b1.id, 7, 2, 0.2, const Duration(milliseconds: 150))]),
        );

        // 3. Tone & clip route to scoped bus; unknown busId falls back to master bus (null).
        await ctrl2.handleAudioEvent(
          const TerminalToneAudioEvent(
            waveform: 'sine',
            frequencyHz: 440,
            duration: Duration(milliseconds: 40),
            busId: 1,
          ),
          scopeKey: 's1',
        );
        final toneVoice = engine2.playedVoices.last;
        expect(engine2.playedBuses[toneVoice.id]?.id, equals(b1.id));

        await ctrl2.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 10,
            format: 'wav',
            bytes: Uint8List.fromList(const [1, 2]),
            busId: 1,
            loop: true,
          ),
          scopeKey: 's1',
        );
        final clipVoice = engine2.playedVoices.last;
        expect(engine2.playedBuses[clipVoice.id]?.id, equals(b1.id));

        await ctrl2.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 11,
            format: 'wav',
            bytes: Uint8List.fromList(const [3, 4]),
            busId: 777, // unknown late-joiner busId
          ),
          scopeKey: 's1',
        );
        final fallbackVoice = engine2.playedVoices.last;
        expect(engine2.playedBuses[fallbackVoice.id], isNull);

        // 4. Re-creating existing busId destroys prior bus; cap at 4 user buses per scope evicts oldest.
        await ctrl2.handleAudioEvent(
          const TerminalBusAudioEvent(op: 'create', busId: 1),
          scopeKey: 's1',
        );
        expect(engine2.destroyedBusIds, equals([b1.id]));
        final b1Replacement = engine2.createdBuses.last;

        for (final id in [2, 3, 4, 5]) {
          await ctrl2.handleAudioEvent(
            TerminalBusAudioEvent(op: 'create', busId: id),
            scopeKey: 's1',
          );
        }
        expect(engine2.destroyedBusIds, equals([b1.id, b1Replacement.id]));

        // Explicit destroy on active bus destroys and removes it.
        await ctrl2.handleAudioEvent(
          const TerminalBusAudioEvent(op: 'destroy', busId: 5),
          scopeKey: 's1',
        );
        expect(engine2.destroyedBusIds, hasLength(3));

        await ctrl2.handleAudioEvent(
          const TerminalBusAudioEvent(op: 'create', busId: 1),
          scopeKey: 's2',
        );
        final s2Bus = engine2.createdBuses.last;

        // disposeScope('s1') destroys only s1's 3 remaining buses, leaving s2 untouched.
        final destroyedBeforeScope = engine2.destroyedBusIds.length;
        ctrl2.disposeScope('s1');
        expect(
          engine2.destroyedBusIds.length - destroyedBeforeScope,
          equals(3),
        );
        expect(engine2.destroyedBusIds, isNot(contains(s2Bus.id)));

        // dispose() destroys remaining s2 bus.
        await ctrl2.dispose();
        expect(engine2.destroyedBusIds, contains(s2Bus.id));
        await ctrl.dispose();
      },
    );

    test(
      'manages scoped buffer streams (early queue, seq-gap handling, 4-stream cap, stream clip play/update/stop, and dispose cleanup)',
      () async {
        final engine = _FakeAudioEngine();
        final initGate = Completer<void>();
        engine.pendingInitGate = initGate;
        final ctrl = FtermAudioController(
          engineFactory: () => engine,
          requireUserGesture: false,
        );

        // 1. Open stream + early chunks + pending clip play + update while init/createBufferStream is resolving.
        final openF = ctrl.handleAudioEvent(
          const TerminalStreamAudioEvent(
            op: 'open',
            streamId: 1,
            maxBufferSize: 1024 * 1024,
            releaseConsumed: false,
            bufferingTimeNeeds: Duration(milliseconds: 250),
            sampleRate: 44100,
            channels: 1,
          ),
          scopeKey: 's1',
        );
        await ctrl.handleAudioEvent(
          TerminalStreamAudioEvent(
            op: 'chunk',
            streamId: 1,
            seq: 0,
            chunkBytes: Uint8List.fromList([1, 2, 3]),
          ),
          scopeKey: 's1',
        );
        await ctrl.handleAudioEvent(
          TerminalStreamAudioEvent(
            op: 'chunk',
            streamId: 1,
            seq: 1,
            chunkBytes: Uint8List.fromList([4, 5]),
          ),
          scopeKey: 's1',
        );
        final playF = ctrl.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 10,
            format: 'wav',
            bytes: Uint8List(0),
            streamId: 1,
            volume: 0.9,
            pan: -0.2,
            loop: true,
            startOffset: const Duration(milliseconds: 40),
          ),
          scopeKey: 's1',
        );
        await ctrl.handleAudioEvent(
          const TerminalUpdateAudioEvent(clipId: 10, volume: 0.35),
          scopeKey: 's1',
        );

        initGate.complete();
        await Future.wait([openF, playF]);

        expect(engine.createdStreams, hasLength(1));
        final s1Buf = engine.createdStreams.single;
        expect(
          engine.streamChunks[s1Buf.hash],
          equals([
            Uint8List.fromList([1, 2, 3]),
            Uint8List.fromList([4, 5]),
          ]),
        );
        final voice = engine.playedVoices.single;
        expect(engine.voiceVolumes[voice.id], closeTo(0.35 * 0.7, 1e-6));
        expect(
          engine.voiceSeeks[voice.id],
          equals(const Duration(milliseconds: 40)),
        );

        // a=update and a=stop control stream-backed voices identically.
        await ctrl.handleAudioEvent(
          const TerminalUpdateAudioEvent(clipId: 10, paused: true),
          scopeKey: 's1',
        );
        expect(engine.voicePauses[voice.id], isTrue);
        await ctrl.handleAudioEvent(
          const TerminalStopAudioEvent(clipId: 10),
          scopeKey: 's1',
        );
        expect(engine.stoppedVoiceIds, contains(voice.id));

        // 2. Live chunks & clean end after open, plus seq gap detection.
        await ctrl.handleAudioEvent(
          TerminalStreamAudioEvent(
            op: 'chunk',
            streamId: 1,
            seq: 2,
            chunkBytes: Uint8List.fromList([6, 7]),
          ),
          scopeKey: 's1',
        );
        expect(engine.streamChunks[s1Buf.hash], hasLength(3));
        await ctrl.handleAudioEvent(
          TerminalStreamAudioEvent(
            op: 'chunk',
            streamId: 1,
            seq: 4, // gap: expected 3
            chunkBytes: Uint8List.fromList([9, 9]),
          ),
          scopeKey: 's1',
        );
        expect(engine.endedStreams, contains(s1Buf.hash));
        expect(engine.streamChunks[s1Buf.hash], hasLength(3));

        // 2b. Clean open -> live chunk -> clean end with seq mismatch & exact match.
        await ctrl.handleAudioEvent(
          const TerminalStreamAudioEvent(op: 'open', streamId: 1),
          scopeKey: 's1',
        );
        final s1Replacement = engine.createdStreams.last;
        await ctrl.handleAudioEvent(
          TerminalStreamAudioEvent(
            op: 'chunk',
            streamId: 1,
            seq: 0,
            chunkBytes: Uint8List.fromList([1]),
          ),
          scopeKey: 's1',
        );
        await ctrl.handleAudioEvent(
          const TerminalStreamAudioEvent(op: 'end', streamId: 1, seq: 2),
          scopeKey: 's1',
        );
        expect(engine.endedStreams, contains(s1Replacement.hash));

        // 2c. 16 MiB cap on live non-released stream ends cleanly.
        await ctrl.handleAudioEvent(
          const TerminalStreamAudioEvent(
            op: 'open',
            streamId: 6,
            maxBufferSize: 16 * 1024 * 1024,
            releaseConsumed: false,
          ),
          scopeKey: 's1',
        );
        final s6Buf = engine.createdStreams.last;
        final twoMb = Uint8List(2 * 1024 * 1024);
        for (var seq = 0; seq < 9; seq++) {
          await ctrl.handleAudioEvent(
            TerminalStreamAudioEvent(
              op: 'chunk',
              streamId: 6,
              seq: seq,
              chunkBytes: twoMb,
            ),
            scopeKey: 's1',
          );
        }
        expect(engine.endedStreams, contains(s6Buf.hash));
        expect(engine.streamChunks[s6Buf.hash], hasLength(8));

        // 3. Cap at 4 concurrent streams per scope evicts oldest and disposes buffer.
        for (final id in [2, 3, 4, 5]) {
          await ctrl.handleAudioEvent(
            TerminalStreamAudioEvent(op: 'open', streamId: id),
            scopeKey: 's1',
          );
        }
        expect(engine.disposedBufferCount, greaterThanOrEqualTo(2));

        // 4. Open another stream in s2, then disposeScope('s1') leaves s2 intact.
        await ctrl.handleAudioEvent(
          const TerminalStreamAudioEvent(op: 'open', streamId: 1),
          scopeKey: 's2',
        );
        final disposedBeforeScope = engine.disposedBufferCount;
        ctrl.disposeScope('s1');
        expect(engine.disposedBufferCount, equals(disposedBeforeScope + 4));

        // dispose() disposes remaining s2 stream.
        await ctrl.dispose();
        expect(engine.disposedBufferCount, equals(disposedBeforeScope + 5));

        // 5. Early end, early seq-gap, early 16 MiB overflow, init failure, and dispose before init.
        final gate2 = Completer<void>();
        final engine2 = _FakeAudioEngine()..pendingInitGate = gate2;
        final ctrl2 = FtermAudioController(
          engineFactory: () => engine2,
          requireUserGesture: false,
        );
        final earlyOpen = ctrl2.handleAudioEvent(
          const TerminalStreamAudioEvent(op: 'open', streamId: 7),
          scopeKey: 'early',
        );
        await ctrl2.handleAudioEvent(
          TerminalStreamAudioEvent(
            op: 'chunk',
            streamId: 7,
            seq: 0,
            chunkBytes: Uint8List.fromList([1, 2]),
          ),
          scopeKey: 'early',
        );
        await ctrl2.handleAudioEvent(
          const TerminalStreamAudioEvent(op: 'end', streamId: 7, seq: 1),
          scopeKey: 'early',
        );
        final earlyGapOpen = ctrl2.handleAudioEvent(
          const TerminalStreamAudioEvent(op: 'open', streamId: 8),
          scopeKey: 'early',
        );
        await ctrl2.handleAudioEvent(
          TerminalStreamAudioEvent(
            op: 'chunk',
            streamId: 8,
            seq: 1, // early seq gap
            chunkBytes: Uint8List.fromList([3]),
          ),
          scopeKey: 'early',
        );
        final earlyOverflowOpen = ctrl2.handleAudioEvent(
          const TerminalStreamAudioEvent(
            op: 'open',
            streamId: 9,
            maxBufferSize: 16 * 1024 * 1024,
          ),
          scopeKey: 'early',
        );
        for (var seq = 0; seq < 9; seq++) {
          await ctrl2.handleAudioEvent(
            TerminalStreamAudioEvent(
              op: 'chunk',
              streamId: 9,
              seq: seq,
              chunkBytes: twoMb,
            ),
            scopeKey: 'early',
          );
        }
        gate2.complete();
        await Future.wait([earlyOpen, earlyGapOpen, earlyOverflowOpen]);
        expect(engine2.createdStreams, hasLength(3));
        expect(engine2.endedStreams, hasLength(3));
        expect(
          engine2.streamChunks[engine2.createdStreams[2].hash],
          hasLength(8),
        );
        await ctrl2.dispose();

        // Init failure aborts pending stream open cleanly.
        final engine3 = _FakeAudioEngine()..alwaysFailInit = true;
        final ctrl3 = FtermAudioController(
          engineFactory: () => engine3,
          requireUserGesture: false,
        );
        await ctrl3.handleAudioEvent(
          const TerminalStreamAudioEvent(op: 'open', streamId: 1),
          scopeKey: 'fail',
        );
        await ctrl3.dispose();

        // Dispose before init completes cleans up streams without engine.
        final gate4 = Completer<void>();
        final engine4 = _FakeAudioEngine()..pendingInitGate = gate4;
        final ctrl4 = FtermAudioController(
          engineFactory: () => engine4,
          requireUserGesture: false,
        );
        final pending4 = ctrl4.handleAudioEvent(
          const TerminalStreamAudioEvent(op: 'open', streamId: 1),
          scopeKey: 'd',
        );
        await ctrl4.dispose();
        gate4.complete();
        await pending4;
      },
    );

    test(
      'preserves sticky preservePitch across partial updates, accepts 128 MiB stream buffer, and stops bound voices on stream replacement/eviction',
      () async {
        final engine = _FakeAudioEngine();
        final ctrl = FtermAudioController(
          engineFactory: () => engine,
          requireUserGesture: false,
        );

        // Fix 4: sticky preservePitch across _startPendingClipVoice and partial _applyVoiceUpdate.
        final pendingGate = Completer<void>();
        engine.pendingMemLoadGate = pendingGate;
        final pendingClipF = ctrl.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 1,
            format: 'wav',
            bytes: Uint8List.fromList(const [1, 2, 3]),
          ),
          scopeKey: 's1',
        );
        await ctrl.handleAudioEvent(
          const TerminalUpdateAudioEvent(
            clipId: 1,
            speed: 1.5,
            preservePitch: true,
          ),
          scopeKey: 's1',
        );
        pendingGate.complete();
        await pendingClipF;
        final v1 = engine.playedVoices.single;
        expect(engine.voiceSpeeds[v1.id], equals((1.5, true)));

        // Speed-only update preserves sticky preservePitch: true.
        await ctrl.handleAudioEvent(
          const TerminalUpdateAudioEvent(clipId: 1, speed: 2.0),
          scopeKey: 's1',
        );
        expect(engine.voiceSpeeds[v1.id], equals((2.0, true)));

        // preservePitch-only update preserves previous speed (2.0).
        await ctrl.handleAudioEvent(
          const TerminalUpdateAudioEvent(clipId: 1, preservePitch: false),
          scopeKey: 's1',
        );
        expect(engine.voiceSpeeds[v1.id], equals((2.0, false)));

        // Pre-emission preservePitch-only update (speed == null) also sets speed=1.0, pp=true.
        final gate2 = Completer<void>();
        engine.pendingMemLoadGate = gate2;
        final pendingClip2F = ctrl.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 2,
            format: 'wav',
            bytes: Uint8List.fromList(const [4, 5]),
          ),
          scopeKey: 's1',
        );
        await ctrl.handleAudioEvent(
          const TerminalUpdateAudioEvent(clipId: 2, preservePitch: true),
          scopeKey: 's1',
        );
        gate2.complete();
        await pendingClip2F;
        final v2 = engine.playedVoices.last;
        expect(engine.voiceSpeeds[v2.id], equals((1.0, true)));

        // Fix 1: 128 MiB decoded PCM maxBufferSize is passed through unclamped at 16 MiB.
        await ctrl.handleAudioEvent(
          const TerminalStreamAudioEvent(
            op: 'open',
            streamId: 10,
            maxBufferSize: 128 * 1024 * 1024,
          ),
          scopeKey: 's1',
        );
        expect(engine.createdStreamMaxBuffers.last, equals(128 * 1024 * 1024));

        // Fix 6: replacing a stream stops bound voices before disposing its buffer.
        await ctrl.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 30,
            format: 'wav',
            bytes: Uint8List(0),
            streamId: 10,
            loop: true,
          ),
          scopeKey: 's1',
        );
        final streamVoice = engine.playedVoices.last;
        expect(engine.stoppedVoiceIds, isNot(contains(streamVoice.id)));
        final disposedBeforeReplace = engine.disposedBufferCount;
        await ctrl.handleAudioEvent(
          const TerminalStreamAudioEvent(op: 'open', streamId: 10),
          scopeKey: 's1',
        );
        expect(engine.stoppedVoiceIds, contains(streamVoice.id));
        expect(engine.disposedBufferCount, equals(disposedBeforeReplace + 1));

        // Natural completion removes clipId from activeClipIds so reusing clipId 31 for a clip
        // is NOT stopped when stream 10 is later evicted.
        await ctrl.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 31,
            format: 'wav',
            bytes: Uint8List(0),
            streamId: 10,
          ),
          scopeKey: 's1',
        );
        final naturalStreamVoice = engine.playedVoices.last;
        engine.completeVoice(naturalStreamVoice.id);
        await Future<void>.delayed(Duration.zero);

        await ctrl.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 31,
            format: 'wav',
            bytes: Uint8List.fromList(const [7, 8]),
          ),
          scopeKey: 's1',
        );
        final reusedClipVoice = engine.playedVoices.last;
        for (final sid in [11, 12, 13, 14]) {
          await ctrl.handleAudioEvent(
            TerminalStreamAudioEvent(op: 'open', streamId: sid),
            scopeKey: 's1',
          );
        }
        expect(engine.stoppedVoiceIds, isNot(contains(reusedClipVoice.id)));

        await ctrl.dispose();
      },
    );
  });
}

void _defineWorkspaceControllerTests() {
  group('FtermWorkspaceController', () {
    test(
      'opens local shell on desktop startup, filters self-cast SessionIds, toggles per-pane share cleanly, tracks bells & pinned titles, and writes 0600 credentials',
      () async {
        final harness = AppThreeWayWsHarness();
        await harness.startCaster(id: 'remote-box', title: 'remote-zsh');
        addTearDown(harness.dispose);

        final tempHome = Directory.systemTemp.createTempSync('fterm_ws_home_');
        addTearDown(() => tempHome.deleteSync(recursive: true));
        final storage = createPlatformSettingsStorage(
          environment: {'HOME': tempHome.path},
          isWindows: false,
        );
        final driver = _FakeLocalHostDriver(harness: harness);
        final audioEngine = _FakeAudioEngine();
        final audio = FtermAudioController(
          engineFactory: () => audioEngine,
          requireUserGesture: false,
        );

        final transport = WsClientTransport(
          serverUri: CastLaunchConfig.defaultServerUri,
          token: harness.token,
          channelFactory: harness.openClientChannel,
        );
        final repository = CastClientRepository(transport: transport);
        final workspace = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(
            token: harness.token,
            casterToken: harness.token,
          ),
          repository: repository,
          localHostDriver: driver,
          audioController: audio,
          storage: storage,
          resizeDebounce: Duration.zero,
        );
        addTearDown(workspace.dispose);

        await workspace.start();
        await _pumpUntil(() => workspace.tabs.isNotEmpty);
        expect(workspace.tabs, hasLength(1));
        expect(workspace.focusedPane!.isLocal, isTrue);
        final localTabId = workspace.tabs.single.tabId;

        // Remote relay connects in background, but Desktop keeps local tab focused
        // without auto-opening tabs for remote sessions.
        await _pumpUntil(
          () => workspace.availableRemoteSessions.any(
            (s) => s.id.value == 'remote-box',
          ),
        );
        expect(workspace.tabs, hasLength(1));
        expect(workspace.tabs.single.tabId, equals(localTabId));

        // Share local pane onto the harness relay and confirm self-cast SessionId is filtered!
        final toggled = await workspace.togglePaneShare(
          channelOpener: harness.openClientChannel,
        );
        expect(toggled, isTrue);
        final sharedId = workspace.focusedPane!.shareSnapshot.sessionId!;
        expect(workspace.ownedSharedSessionIds, contains(sharedId));
        await _pumpUntil(
          () => harness.registry.sessions.any((s) => s.id == sharedId),
        );
        expect(
          workspace.availableRemoteSessions.map((s) => s.id),
          isNot(contains(sharedId)),
        );
        expect(
          workspace.availableRemoteSessions.map((s) => s.id),
          contains(const SessionId('remote-box')),
        );

        // Stop share keeps local shell alive and clears self-cast ownership.
        expect(
          await workspace.togglePaneShare(
            channelOpener: harness.openClientChannel,
          ),
          isTrue,
        );
        expect(driver.hosts.single.port.isDisposed, isFalse);
        expect(
          workspace.focusedPane!.shareSnapshot.state,
          equals(LocalShareState.unshared),
        );

        // Split horizontal cleanly creates two local panes; background bell increments & pans.
        await workspace.splitFocusedPane(SplitAxis.horizontal);
        expect(workspace.tabs.single.splitTree.paneCount, equals(2));
        expect(driver.hosts, hasLength(2));

        // Live shell title vs pinned title + clearPin.
        driver.hosts[1].port.emitTitle('vim main.dart');
        expect(
          workspace.activeTab!.resolveTitle({'p': workspace.focusedPane!}),
          isNotNull,
        );
        workspace.renameTab(title: 'Pinned Workspace');
        expect(workspace.activeTab!.isUserPinned, isTrue);
        driver.hosts[1].port.emitTitle('htop');
        expect(workspace.activeTab!.pinnedTitle, equals('Pinned Workspace'));
        workspace.renameTab(title: '', clearPin: true);
        expect(workspace.activeTab!.isUserPinned, isFalse);

        // Bell in left pane (pan = -0.5) while right pane is focused increments bell & plays panned chime.
        driver.hosts[0].port.emitBell();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(workspace.tabs.single.unreadBellCount, equals(1));
        expect(audioEngine.lastVoicePan, closeTo(-0.5, 1e-6));

        // Saving relay creds writes 0600 POSIX file inside 0700 ~/.config/fterm.
        await workspace.connectRelay(
          serverUri: Uri.parse('wss://relay.example.com/v1/client'),
          clientToken: 'new-client-tok',
          casterToken: 'new-caster-tok',
        );
        await (storage as BatchSettingsStorage).flush();
        final settingsFile = File(
          p.join(tempHome.path, '.config', 'fterm', 'settings.json'),
        );
        expect(settingsFile.existsSync(), isTrue);
        if (!Platform.isWindows) {
          expect(settingsFile.statSync().mode & 0x1ff, equals(0x180));
        }
        expect(
          loadStoredRelayCredentials(storage).clientToken,
          equals('new-client-tok'),
        );
      },
    );

    test('auto-populates relay tabs on Web stub host', () async {
      final harness = AppThreeWayWsHarness();
      await harness.startCaster(id: 'web-s1', title: 'alpha');
      await harness.startCaster(id: 'web-s2', title: 'beta');
      addTearDown(harness.dispose);

      final transport = WsClientTransport(
        serverUri: CastLaunchConfig.defaultServerUri,
        token: harness.token,
        channelFactory: harness.openClientChannel,
      );
      final workspace = FtermWorkspaceController(
        launchConfig: CastLaunchConfig(token: harness.token),
        repository: CastClientRepository(transport: transport),
        localHostDriver: _StubOnlyLocalHostDriver(),
        audioController: FtermAudioController(
          engineFactory: _FakeAudioEngine.new,
        ),
        storage: _InMemorySettingsStorage(),
        resizeDebounce: Duration.zero,
      );
      addTearDown(workspace.dispose);

      await workspace.start();
      await _pumpUntil(() => workspace.tabs.length == 2);
      expect(workspace.activeTabIndex, equals(0));
      expect(
        workspace.focusedPane!.remoteSessionId,
        equals(const SessionId('web-s1')),
      );
    });

    test(
      'scopes remote twin split panes by SessionId and disposes scope on last close or child exit',
      () async {
        final harness = AppThreeWayWsHarness();
        final twinPty = await harness.startCaster(
          id: 'twin-sess',
          title: 'twin',
        );
        addTearDown(harness.dispose);

        final audioEngine = _FakeAudioEngine();
        final audio = FtermAudioController(
          engineFactory: () => audioEngine,
          requireUserGesture: false,
        );
        final driver = _FakeLocalHostDriver(harness: harness);
        final transport = WsClientTransport(
          serverUri: CastLaunchConfig.defaultServerUri,
          token: harness.token,
          channelFactory: harness.openClientChannel,
        );
        final workspace = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(token: harness.token),
          repository: CastClientRepository(transport: transport),
          localHostDriver: driver,
          audioController: audio,
          storage: _InMemorySettingsStorage(),
          resizeDebounce: Duration.zero,
        );
        addTearDown(workspace.dispose);

        await workspace.start();
        await _pumpUntil(
          () => workspace.availableRemoteSessions.any(
            (s) => s.id.value == 'twin-sess',
          ),
        );

        // Local child exit disposes local pane's scopeKey cleanly.
        final localPaneId = workspace.focusedPane!.paneId;
        await audio.handleAudioEvent(
          TerminalClipAudioEvent(
            clipId: 3,
            format: 'wav',
            bytes: Uint8List.fromList(const [1, 2]),
            loop: true,
          ),
          scopeKey: localPaneId,
        );
        final localVoice = audioEngine.playedVoices.last;
        driver.hosts.single.port.completeExit(0);
        await Future<void>.delayed(Duration.zero);
        expect(audioEngine.stoppedVoiceIds, contains(localVoice.id));

        // Open remote session and split into twin panes on the same SessionId.
        workspace.openRemoteSessionTab(const SessionId('twin-sess'));
        final pane1Id = workspace.focusedPane!.paneId;
        final pane2Id = await workspace.splitFocusedPane(
          SplitAxis.vertical,
          remoteSessionId: const SessionId('twin-sess'),
        );
        expect(pane2Id, isNotNull);
        await _pumpUntil(() => workspace.audioEventsCount == 0);

        // Audio emitted by remote PTY flows through pane2 using scopeKey == 'twin-sess'.
        twinPty.emitRawAnsi('\x1b_Aa=clip,i=9,fmt=wav,l=1,m=0;BAUG\x1b\\');
        await _pumpUntil(() => audioEngine.playedVoices.length >= 2);
        final twinVoice = audioEngine.playedVoices.last;

        // Switching focus to twin pane1 and updating clip 9 still updates the same voice!
        workspace.focusPane(pane1Id);
        twinPty.emitRawAnsi('\x1b_Aa=update,i=9,pa=1;\x1b\\');
        await _pumpUntil(() => audioEngine.voicePauses[twinVoice.id] == true);
        expect(audioEngine.voicePauses[twinVoice.id], isTrue);

        // Closing one twin pane leaves twinVoice playing until the last pane closes.
        await workspace.closePane(pane2Id);
        expect(audioEngine.stoppedVoiceIds, isNot(contains(twinVoice.id)));
        await workspace.closePane(pane1Id);
        expect(audioEngine.stoppedVoiceIds, contains(twinVoice.id));
      },
    );

    test(
      'FtermPaneController.lookupVirtualLine returns null for evicted scrollback rows < oldestLine',
      () async {
        final port = _MemoryTerminalPort()
          ..oldestScrollbackLine = 10
          ..scrollbackRows = [
            ScrollbackLine(
              width: 80,
              characters: 'Line 10'.split(''),
              attributes: Uint32List(7 * 3),
            ),
            ScrollbackLine(
              width: 80,
              characters: 'Line 11'.split(''),
              attributes: Uint32List(7 * 3),
            ),
          ];
        final pane = FtermPaneController(
          paneId: 'evict-pane',
          port: port,
          colorResolver: TerminalColorResolver(
            theme: tui.TerminalColorTheme.termuiDark,
            settings: const TerminalThemeSettings(),
          ),
        );
        addTearDown(() {
          pane.dispose();
          unawaited(port.dispose());
        });

        expect(pane.lookupVirtualLine(5), isNull);
        expect(pane.lookupVirtualLine(9), isNull);
        expect(pane.lookupVirtualLine(10)?.characters.join(), 'Line 10');

        final sel = tui.TerminalSelectionController()
          ..startSelection(0, 5)
          ..updateSelection(6, 11);
        addTearDown(sel.dispose);
        expect(
          sel.extractVirtualText(pane.lookupVirtualLine, cols: 80),
          equals('Line 10\nLine 11'),
        );
      },
    );
  });
}

Future<void> _pumpUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out awaiting test condition.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

final class _InMemorySettingsStorage implements SettingsStorage {
  final Map<String, String> _map = {};

  @override
  String? getItem(String key) => _map[key];

  @override
  void setItem(String key, String value) => _map[key] = value;
}

final class _StubOnlyLocalHostDriver implements LocalHostDriver {
  @override
  bool get isSupported => false;

  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) =>
      Future.error(UnsupportedError('Web stub'));

  @override
  Future<void> dispose() async {}
}

final class _FakeLocalHostDriver implements LocalHostDriver {
  final AppThreeWayWsHarness harness;
  final List<_FakeLocalPaneHost> hosts = [];
  int _counter = 0;

  _FakeLocalHostDriver({required this.harness});

  @override
  bool get isSupported => true;

  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) async {
    final host = _FakeLocalPaneHost(
      id: 'local-${++_counter}',
      harness: harness,
    );
    hosts.add(host);
    return host;
  }

  @override
  Future<void> dispose() async {
    for (final h in [...hosts]) {
      await h.dispose();
    }
  }
}

final class _FakeLocalPaneHost implements LocalPaneHost {
  @override
  final String id;
  final AppThreeWayWsHarness harness;
  @override
  final _MemoryTerminalPort port = _MemoryTerminalPort();
  final Completer<int> _exitCode = Completer<int>();
  final StreamController<LocalShareSnapshot> _shareUpdates =
      StreamController<LocalShareSnapshot>.broadcast();
  LocalShareSnapshot _snapshot = LocalShareSnapshot.unshared;
  int startShareCalls = 0;

  _FakeLocalPaneHost({required this.id, required this.harness});

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  LocalShareSnapshot get shareSnapshot => _snapshot;

  @override
  Stream<LocalShareSnapshot> get shareUpdates => _shareUpdates.stream;

  @override
  Future<SessionId> startShare({
    required Uri serverUri,
    required String casterToken,
    required String title,
    String? uploadDirPath,
    IapTokenProvider? iapTokenProvider,
    CasterTransportOpener? channelOpener,
  }) async {
    startShareCalls += 1;
    final assigned = SessionId('self-$id');
    await harness.startCaster(id: assigned.value, title: title);
    _snapshot = LocalShareSnapshot(
      state: LocalShareState.live,
      sessionId: assigned,
      subscriberCount: 1,
    );
    if (!_shareUpdates.isClosed) _shareUpdates.add(_snapshot);
    return assigned;
  }

  @override
  Future<void> stopShare() async {
    _snapshot = LocalShareSnapshot.unshared;
    if (!_shareUpdates.isClosed) _shareUpdates.add(_snapshot);
  }

  @override
  void setColorScheme(tui.TerminalBrightness brightness) {}

  @override
  Future<void> dispose() async {
    await stopShare();
    await port.dispose();
    if (!_exitCode.isCompleted) _exitCode.complete(0);
    await _shareUpdates.close();
  }
}

final class _MemoryTerminalPort implements TerminalPort {
  final tui.Buffer _buffer = tui.Buffer.blank(80, 24);
  final Set<void Function()> _listeners = {};
  final Set<void Function()> _bellListeners = {};
  final Set<void Function(String)> _titleListeners = {};
  final Set<void Function(TerminalAudioEvent)> _audioListeners = {};
  final Set<void Function(String, String)> _clipboardListeners = {};
  final List<Uint8List> sentInputs = [];
  final Completer<int> _exitCode = Completer<int>();
  String _title = 'zsh';
  int oldestScrollbackLine = 0;
  int clearSeq = 0;
  int _renderRevision = 0;
  List<ScrollbackLine> scrollbackRows = const [];
  bool isDisposed = false;

  void emitFrame() {
    _renderRevision += 1;
    for (final fn in [..._listeners]) {
      fn();
    }
  }

  void emitAudio(TerminalAudioEvent event) {
    for (final fn in [..._audioListeners]) {
      fn(event);
    }
  }

  void emitClipboard(String selection, String text) {
    for (final fn in [..._clipboardListeners]) {
      fn(selection, text);
    }
  }

  void emitBell() {
    for (final fn in [..._bellListeners]) {
      fn();
    }
  }

  void emitTitle(String title) {
    _title = title;
    for (final fn in [..._titleListeners]) {
      fn(title);
    }
  }

  void completeExit([int code = 0]) {
    if (!_exitCode.isCompleted) _exitCode.complete(code);
  }

  @override
  String get id => 'mem-port';

  @override
  int get renderRevision => _renderRevision;

  @override
  int get fullSyncRevision => 0;

  @override
  List<DirtyCellSpan> get dirtySpans => const [];

  @override
  tui.Buffer get buffer => _buffer;

  @override
  int get cols => _buffer.width;

  @override
  int get rows => _buffer.height;

  @override
  (int cols, int rows) get activePtySize => (_buffer.width, _buffer.height);

  @override
  CursorStateData get cursor => CursorStateData.origin;

  @override
  TerminalPortModes get modes => TerminalPortModes.defaults;

  @override
  ScrollbackWindowData get scrollbackWindow => (
    clearSeq: clearSeq,
    oldestLine: oldestScrollbackLine,
    totalLines: oldestScrollbackLine + scrollbackRows.length,
  );

  @override
  String get windowTitle => _title;

  @override
  String? get workingDirectory => '/tmp';

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  @override
  void addTitleListener(void Function(String title) listener) =>
      _titleListeners.add(listener);

  @override
  void removeTitleListener(void Function(String title) listener) =>
      _titleListeners.remove(listener);

  @override
  void addBellListener(void Function() listener) =>
      _bellListeners.add(listener);

  @override
  void removeBellListener(void Function() listener) =>
      _bellListeners.remove(listener);

  @override
  void addAudioListener(void Function(TerminalAudioEvent event) listener) =>
      _audioListeners.add(listener);

  @override
  void removeAudioListener(void Function(TerminalAudioEvent event) listener) =>
      _audioListeners.remove(listener);

  @override
  void addClipboardListener(
    void Function(String selection, String text) listener,
  ) => _clipboardListeners.add(listener);

  @override
  void removeClipboardListener(
    void Function(String selection, String text) listener,
  ) => _clipboardListeners.remove(listener);

  @override
  void sendInput(Uint8List utf8Bytes) =>
      sentInputs.add(Uint8List.fromList(utf8Bytes));

  @override
  void setViewportSize(
    int cols,
    int rows, {
    int cellPixelWidth = 0,
    int cellPixelHeight = 0,
  }) {}

  @override
  List<ScrollbackLine?> readScrollbackSlice(int startLine, int count) {
    if (scrollbackRows.isEmpty) return const [];
    return List<ScrollbackLine?>.generate(count, (i) {
      final offset = (startLine + i) - oldestScrollbackLine;
      if (offset < 0 || offset >= scrollbackRows.length) return null;
      return scrollbackRows[offset];
    });
  }

  @override
  Future<void> dispose() async {
    isDisposed = true;
    if (!_exitCode.isCompleted) _exitCode.complete(0);
  }
}

final class _FakeAudioBuffer implements AudioBuffer {
  @override
  final int hash;

  _FakeAudioBuffer(this.hash);
}

final class _FakeAudioEngine implements TermuiAudioEngine {
  int initCalls = 0;
  int disposeCalls = 0;
  int disposedBufferCount = 0;
  bool failNextInit = false;
  bool alwaysFailInit = false;
  bool throwOnStop = false;
  Completer<void>? pendingInitGate;
  Completer<void>? pendingLoadGate;
  Completer<void>? pendingMemLoadGate;
  bool disposed = false;
  int _nextId = 1;
  final List<(WaveForm, double)> loadedWaveforms = [];
  final List<AudioVoice> playedVoices = [];
  final List<int> stoppedVoiceIds = [];
  final Map<int, double> voicePans = {};
  final Map<int, double> voiceVolumes = {};
  final Map<int, Duration> voiceSeeks = {};
  final Map<int, bool> voicePauses = {};
  final Map<int, (double, bool)> voiceSpeeds = {};
  final Map<int, (double, Duration)> voiceVolumeFades = {};
  final Map<int, (double, Duration)> voiceSpeedFades = {};
  final Map<int, Duration> voiceScheduledStops = {};
  final Map<int, AudioBus?> playedBuses = {};
  final List<_FakeAudioBus> createdBuses = [];
  final List<int> destroyedBusIds = [];
  final List<_FakeAudioBuffer> createdStreams = [];
  final List<int> createdStreamMaxBuffers = [];
  final Map<int, Completer<void>> voiceCompleters = {};
  final Map<int, List<Uint8List>> streamChunks = {};
  final Set<int> endedStreams = {};
  final List<(int busId, int filterId)> attachedFilters = [];
  final List<(int busId, int filterId, int paramId, double value)>
  filterParams = [];
  final List<
    (int busId, int filterId, int paramId, double targetValue, Duration dur)
  >
  filterFades = [];
  double? lastVoicePan;
  double? lastVoiceVolume;
  Duration? lastScheduledStopDuration;
  String? lastLoadedMemId;
  Float32List? nextWaveform;

  @override
  Future<void> init({bool enableVisualization = true}) async {
    initCalls += 1;
    final gate = pendingInitGate;
    if (gate != null) {
      pendingInitGate = null;
      await gate.future;
    }
    if (alwaysFailInit) {
      throw StateError('Simulated permanent audio failure');
    }
    if (failNextInit) {
      failNextInit = false;
      throw StateError('Simulated Web WASM not ready');
    }
  }

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
    disposed = true;
  }

  @override
  Future<AudioBuffer> loadWaveform(
    WaveForm shape,
    double frequency, {
    bool usePcmFallback = false,
  }) async {
    final gate = pendingLoadGate;
    if (gate != null) {
      await gate.future;
    }
    loadedWaveforms.add((shape, frequency));
    return _FakeAudioBuffer(++_nextId);
  }

  @override
  Future<AudioBuffer> loadMem(
    String pathId,
    Uint8List bytes, {
    bool stream = false,
  }) async {
    final gate = pendingMemLoadGate;
    if (gate != null) {
      await gate.future;
    }
    lastLoadedMemId = pathId;
    return _FakeAudioBuffer(++_nextId);
  }

  @override
  AudioVoice play(
    AudioBuffer buffer, {
    bool loop = false,
    AudioBus? bus,
    bool paused = false,
  }) {
    final id = ++_nextId;
    final completer = Completer<void>();
    voiceCompleters[id] = completer;
    final voice = AudioVoice(id, completer.future);
    playedVoices.add(voice);
    playedBuses[voice.id] = bus;
    return voice;
  }

  void completeVoice(int voiceId) {
    final completer = voiceCompleters.remove(voiceId);
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  @override
  void setVoicePan(AudioVoice voice, double pan) {
    lastVoicePan = pan;
    voicePans[voice.id] = pan;
  }

  @override
  void setVoiceVolume(AudioVoice voice, double volume) {
    lastVoiceVolume = volume;
    voiceVolumes[voice.id] = volume;
  }

  @override
  void setPaused(AudioVoice voice, bool paused) {
    voicePauses[voice.id] = paused;
  }

  @override
  void fadeVolume(AudioVoice voice, double targetVolume, Duration duration) {
    voiceVolumeFades[voice.id] = (targetVolume, duration);
  }

  @override
  void scheduleStop(AudioVoice voice, Duration duration) {
    lastScheduledStopDuration = duration;
    voiceScheduledStops[voice.id] = duration;
  }

  @override
  void stop(AudioVoice voice) {
    stoppedVoiceIds.add(voice.id);
    if (throwOnStop) {
      throw StateError('Simulated stop error');
    }
  }

  @override
  Future<void> disposeBuffer(AudioBuffer buffer) async {
    disposedBufferCount += 1;
  }

  @override
  void addStreamData(AudioBuffer buffer, Uint8List chunk) {
    streamChunks.putIfAbsent(buffer.hash, () => []).add(chunk);
  }

  @override
  void attachFilterToBus(AudioBus bus, int filterId) {
    attachedFilters.add((bus.id, filterId));
  }

  @override
  Future<AudioBuffer> createBufferStream({
    int maxBufferSize = 4 * 1024 * 1024,
    bool releaseConsumed = false,
    Duration bufferingTimeNeeds = const Duration(milliseconds: 500),
    int sampleRate = 48000,
    int channels = 2,
  }) async {
    final buf = _FakeAudioBuffer(++_nextId);
    createdStreams.add(buf);
    createdStreamMaxBuffers.add(maxBufferSize);
    return buf;
  }

  @override
  int createFilter(FilterType type) => 1;

  @override
  void fadeRelativePlaySpeed(
    AudioVoice voice,
    double speed,
    Duration duration,
  ) {
    voiceSpeedFades[voice.id] = (speed, duration);
  }

  @override
  Duration getBufferDuration(AudioBuffer buffer) => Duration.zero;

  @override
  Duration getVoicePosition(AudioVoice voice) => Duration.zero;

  @override
  Stream<Duration> getVoicePositionStream(
    AudioVoice voice, {
    Duration interval = const Duration(milliseconds: 50),
  }) => const Stream.empty();

  @override
  Future<AudioBuffer> loadFile(
    String path, {
    bool stream = false,
    LoadProgressCallback? onProgress,
  }) async => _FakeAudioBuffer(++_nextId);

  @override
  Future<Uint8List> loadFileBytes(String path) async => Uint8List(0);

  @override
  Future<AudioBuffer> loadUrl(
    String url, {
    LoadProgressCallback? onProgress,
  }) async => _FakeAudioBuffer(++_nextId);

  @override
  AudioVoice play3d(AudioBuffer buffer, double x, double y, double z) =>
      play(buffer);

  @override
  void seek(AudioVoice voice, Duration position) {
    voiceSeeks[voice.id] = position;
  }

  @override
  void set3dSourceAttenuation(
    AudioVoice voice,
    AttenuationModel attenuationModel,
    double attenuationRolloffFactor,
  ) {}

  @override
  void set3dSourceMinMaxDistance(
    AudioVoice voice,
    double minDistance,
    double maxDistance,
  ) {}

  @override
  void set3dSourceParameters(
    AudioVoice voice,
    double x,
    double y,
    double z, {
    double vx = 0.0,
    double vy = 0.0,
    double vz = 0.0,
  }) {}

  @override
  void setFilterParameter(
    AudioBus bus,
    int filterId,
    int attributeId,
    double value,
  ) {
    filterParams.add((bus.id, filterId, attributeId, value));
  }

  @override
  void setRelativePlaySpeed(
    AudioVoice voice,
    double speed, {
    bool preservePitch = false,
  }) {
    voiceSpeeds[voice.id] = (speed, preservePitch);
  }

  @override
  void setStreamEnded(AudioBuffer buffer) {
    endedStreams.add(buffer.hash);
  }

  @override
  AudioBus createBus() {
    final bus = _FakeAudioBus(++_nextId);
    createdBuses.add(bus);
    return bus;
  }

  @override
  void destroyBus(AudioBus bus) {
    destroyedBusIds.add(bus.id);
  }

  @override
  void fadeFilterParameter(
    AudioBus bus,
    int filterId,
    int paramId,
    double targetValue,
    Duration duration,
  ) {
    filterFades.add((bus.id, filterId, paramId, targetValue, duration));
  }

  @override
  double getFilterParameter(AudioBus bus, int filterId, int paramId) => 0.0;

  @override
  Float32List getWaveform([Float32List? outBuffer]) {
    final buf = outBuffer ?? Float32List(256);
    if (nextWaveform case final src?) {
      buf.setRange(0, 256, src);
    }
    return buf;
  }

  @override
  Future<Float32List> fetchWaveform([Float32List? outBuffer]) async =>
      getWaveform(outBuffer);

  @override
  Stream<Float32List> watchWaveform({
    Duration interval = const Duration(milliseconds: 100),
  }) => const Stream.empty();

  @override
  AudioVoice playSprite(
    AudioBuffer buffer, {
    required Duration start,
    required Duration duration,
    AudioBus? bus,
  }) => play(buffer, bus: bus);

  @override
  Future<void> playSpriteSequence(
    AudioBuffer buffer,
    List<SpriteSegment> segments, {
    AudioBus? bus,
  }) async {}
}

final class _FakeAudioBus implements AudioBus {
  _FakeAudioBus(this.id);

  @override
  final int id;

  double volume = 1.0;

  @override
  void setVolume(double value) {
    volume = value;
  }
}

void _defineHardeningRegressionTests() {
  group('Downstream hardening regressions', () {
    test(
      'IoLocalHostDriver stops polling on share auth_failed without killing local PTY and retries cleanly on single toggle; non-loopback share with empty casterToken prompts',
      () async {
        final harness = AppThreeWayWsHarness();
        addTearDown(harness.dispose);

        final backends = <_TestRoutedPtyBackend>[];
        final driver = IoLocalHostDriver(
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
              }) {
                final b = _TestRoutedPtyBackend();
                backends.add(b);
                return b;
              },
        );
        final transport = WsClientTransport(
          serverUri: CastLaunchConfig.defaultServerUri,
          token: harness.token,
          channelFactory: harness.openClientChannel,
        );
        final workspace = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(
            token: harness.token,
            casterToken: harness.token,
          ),
          repository: CastClientRepository(transport: transport),
          localHostDriver: driver,
          audioController: FtermAudioController(
            engineFactory: _FakeAudioEngine.new,
          ),
          storage: _InMemorySettingsStorage(),
          resizeDebounce: Duration.zero,
        );
        addTearDown(workspace.dispose);

        await workspace.openLocalShellTab();
        expect(backends, hasLength(1));

        // 1. Failing share (auth_failed) stops share polling, enters error, and leaves local PTY alive!
        final failOpened = await workspace.togglePaneShare(
          channelOpener: () async {
            final ctrl = StreamChannelController<Uint8List>();
            ctrl.foreign.stream.listen((raw) {
              if (BufferFrameCodec.decode(raw) is AuthFrame) {
                ctrl.foreign.sink.add(
                  BufferFrameCodec.encode(
                    const ErrorFrame(
                      code: 'auth_failed',
                      message: 'bad caster token',
                    ),
                  ),
                );
              }
            });
            return ctrl.local;
          },
        );
        expect(failOpened, isTrue);
        await _pumpUntil(
          () =>
              workspace.focusedPane!.shareSnapshot.state ==
              LocalShareState.error,
        );
        expect(driver.hasActiveSharePolling, isFalse);
        expect(backends.single.killed, isFalse);

        // 2. Transient dial error during share surfaces errorMessage while connecting, then clears on live!
        var dialAttempt = 0;
        final retried = await workspace.togglePaneShare(
          channelOpener: () async {
            dialAttempt += 1;
            if (dialAttempt == 1) {
              throw const WebSocketException(
                "Connection to 'https://relay.run.app/v1/caster' was not upgraded to websocket (302)",
              );
            }
            final ctrl = StreamChannelController<Uint8List>();
            harness.relayHandler.attachCasterChannel(ctrl.foreign);
            return ctrl.local;
          },
        );
        expect(retried, isTrue);
        await _pumpUntil(
          () => workspace.focusedPane!.shareSnapshot.errorMessage != null,
        );
        expect(
          workspace.focusedPane!.shareSnapshot.errorMessage,
          contains('was not upgraded to websocket (302)'),
        );
        expect(workspace.statusBanner, contains('Share failed:'));
        await _pumpUntil(
          () =>
              workspace.focusedPane!.shareSnapshot.state ==
              LocalShareState.live,
        );
        await Future<void>.delayed(Duration.zero);
        expect(workspace.focusedPane!.shareSnapshot.errorMessage, isNull);
        expect(workspace.statusBanner, isNull);
        expect(backends.single.killed, isFalse);

        // 3. Non-loopback host with clientToken set + empty casterToken opens connect modal.
        final nonLoopbackDriver = _FakeLocalHostDriver(harness: harness);
        final nonLoopbackWs = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(
            serverUri: Uri.parse('wss://relay.example.com/v1/client'),
            token: 'viewer-token-present',
            casterToken: '',
          ),
          repository: CastClientRepository(
            transport: WsClientTransport(
              serverUri: Uri.parse('wss://relay.example.com/v1/client'),
              token: 'viewer-token-present',
              channelFactory: harness.openClientChannel,
            ),
            enableReconnect: false,
          ),
          localHostDriver: nonLoopbackDriver,
          audioController: FtermAudioController(
            engineFactory: _FakeAudioEngine.new,
          ),
          storage: _InMemorySettingsStorage(),
          resizeDebounce: Duration.zero,
        );
        addTearDown(nonLoopbackWs.dispose);

        await nonLoopbackWs.openLocalShellTab();
        final blockedShare = await nonLoopbackWs.togglePaneShare();
        expect(blockedShare, isFalse);
        expect(nonLoopbackWs.activeOverlay, equals(FtermOverlay.connect));
        expect(nonLoopbackDriver.hosts.single.startShareCalls, equals(0));
      },
    );

    test(
      'start() reconnects using stored desktop RelayCredentials, handles openLocalShellTab errors, and Web never reads/writes relay credentials',
      () async {
        // 1. Desktop start() connects to hydrated credentials instead of raw launchConfig defaults.
        final desktopStorage = _InMemorySettingsStorage();
        saveStoredRelayCredentials(
          desktopStorage,
          const RelayCredentials(
            serverUrl: 'wss://saved-relay.example.com/v1/client',
            clientToken: 'saved-client-token',
          ),
        );
        final recordedEndpoints = <(Uri, String)>[];
        final harness = AppThreeWayWsHarness();
        addTearDown(harness.dispose);
        final desktopRepo = CastClientRepository(
          transport: WsClientTransport(
            channelFactory: harness.openClientChannel,
          ),
          transportFactory: (endpoint) {
            recordedEndpoints.add((endpoint.serverUri, endpoint.token));
            return WsClientTransport(
              serverUri: endpoint.serverUri,
              token: endpoint.token,
              channelFactory: harness.openClientChannel,
            );
          },
          enableReconnect: false,
        );
        final desktopWs = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(),
          repository: desktopRepo,
          localHostDriver: _FakeLocalHostDriver(harness: harness),
          audioController: FtermAudioController(
            engineFactory: _FakeAudioEngine.new,
          ),
          storage: desktopStorage,
          resizeDebounce: Duration.zero,
        );
        addTearDown(desktopWs.dispose);

        await desktopWs.start();
        await _pumpUntil(() => recordedEndpoints.isNotEmpty);
        expect(
          recordedEndpoints.single,
          equals((
            Uri.parse('wss://saved-relay.example.com/v1/client'),
            'saved-client-token',
          )),
        );

        // 2. Throwing openLocalShellTab sets statusBanner and still starts relay connection.
        final failingDriver = _ThrowingOpenShellDriver();
        final connectAttempts = <Uri>[];
        final fallbackRepo = CastClientRepository(
          transport: WsClientTransport(
            serverUri: CastLaunchConfig.defaultServerUri,
            token: harness.token,
            channelFactory: harness.openClientChannel,
          ),
          enableReconnect: false,
        );
        clientConnectingEvent.addListener(
          fallbackRepo.bus,
          connectAttempts.add,
        );
        final failingWs = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(token: harness.token),
          repository: fallbackRepo,
          localHostDriver: failingDriver,
          audioController: FtermAudioController(
            engineFactory: _FakeAudioEngine.new,
          ),
          storage: _InMemorySettingsStorage(),
          resizeDebounce: Duration.zero,
        );
        addTearDown(failingWs.dispose);
        await failingWs.start();
        await _pumpUntil(() => connectAttempts.isNotEmpty);
        expect(failingWs.statusBanner, contains('Local shell failed:'));
        expect(failingWs.tabs, isEmpty);

        // 3. Web (!localHostDriver.isSupported) ignores stored relay credentials and never writes them.
        final webStorage = _RecordingSettingsStorage();
        saveStoredRelayCredentials(
          webStorage,
          const RelayCredentials(
            serverUrl: 'wss://stale.example/v1/client',
            clientToken: 'stale-web-secret',
            casterToken: 'stale-caster-secret',
          ),
        );
        webStorage.writes.clear();
        final webWs = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(promptForConnection: true),
          repository: CastClientRepository(
            transport: WsClientTransport(
              channelFactory: harness.openClientChannel,
            ),
            enableReconnect: false,
          ),
          localHostDriver: _StubOnlyLocalHostDriver(),
          audioController: FtermAudioController(
            engineFactory: _FakeAudioEngine.new,
          ),
          storage: webStorage,
          resizeDebounce: Duration.zero,
        );
        addTearDown(webWs.dispose);
        expect(webWs.activeClientToken, isEmpty);
        expect(webWs.activeRelayUri, equals(CastLaunchConfig.defaultServerUri));

        await webWs.connectRelay(
          serverUri: Uri.parse('wss://web.example.com/v1/client'),
          clientToken: harness.token,
        );
        expect(
          webStorage.writes.containsKey(ftermRelayCredentialsStorageKey),
          isFalse,
        );
      },
    );

    test(
      'closePane and splitFocusedPane handle concurrent close across awaits without stale tab index or orphan host',
      () async {
        final harness = AppThreeWayWsHarness();
        addTearDown(harness.dispose);

        // 1. Concurrent closePane across 3 tabs with delayed port disposal preserves middle tab cleanly.
        final disposeGate1 = Completer<void>();
        final disposeGate2 = Completer<void>()..complete();
        final disposeGate3 = Completer<void>();
        final delayedDriver = _ConfigurableLocalHostDriver(
          disposeGates: [disposeGate1, disposeGate2, disposeGate3],
        );
        final closeWs = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(token: harness.token),
          repository: CastClientRepository(
            transport: WsClientTransport(
              channelFactory: harness.openClientChannel,
            ),
            enableReconnect: false,
          ),
          localHostDriver: delayedDriver,
          audioController: FtermAudioController(
            engineFactory: _FakeAudioEngine.new,
          ),
          storage: _InMemorySettingsStorage(),
          resizeDebounce: Duration.zero,
        );
        addTearDown(closeWs.dispose);

        await closeWs.openLocalShellTab();
        await closeWs.openLocalShellTab();
        await closeWs.openLocalShellTab();
        final p1 = closeWs.tabs[0].splitTree.focusedPaneId;
        final p2 = closeWs.tabs[1].splitTree.focusedPaneId;
        final p3 = closeWs.tabs[2].splitTree.focusedPaneId;

        final close1 = closeWs.closePane(p1);
        final close3 = closeWs.closePane(p3);
        expect(closeWs.tabs, hasLength(1));
        expect(closeWs.tabs.single.splitTree.focusedPaneId, equals(p2));

        disposeGate3.complete();
        disposeGate1.complete();
        await Future.wait([close1, close3]);
        expect(closeWs.tabs, hasLength(1));
        expect(closeWs.tabs.single.splitTree.focusedPaneId, equals(p2));

        // 2. Target pane closed while openShell is in flight inside splitFocusedPane disposes new host cleanly.
        final openGate = Completer<void>();
        final openStarted = Completer<void>();
        final gatedDriver = _ConfigurableLocalHostDriver(
          openGates: [null, openGate],
          onOpenStarted: (idx) {
            if (idx == 1 && !openStarted.isCompleted) {
              openStarted.complete();
            }
          },
        );
        final splitWs = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(token: harness.token),
          repository: CastClientRepository(
            transport: WsClientTransport(
              channelFactory: harness.openClientChannel,
            ),
            enableReconnect: false,
          ),
          localHostDriver: gatedDriver,
          audioController: FtermAudioController(
            engineFactory: _FakeAudioEngine.new,
          ),
          storage: _InMemorySettingsStorage(),
          resizeDebounce: Duration.zero,
        );
        addTearDown(splitWs.dispose);

        await splitWs.openLocalShellTab();
        final targetPaneId = splitWs.tabs.single.splitTree.focusedPaneId;
        final pendingSplit = splitWs.splitFocusedPane(SplitAxis.horizontal);
        await openStarted.future;

        await splitWs.closePane(targetPaneId);
        openGate.complete();
        final splitResult = await pendingSplit;

        expect(splitResult, isNull);
        expect(splitWs.tabs, isEmpty);
        expect(gatedDriver.createdHosts, hasLength(2));
        expect(gatedDriver.createdHosts[1].disposed, isTrue);
      },
    );

    testWidgets(
      'throttles rapid updatePreferences slider ticks via ThrottledSettingsSaver while updating audioController immediately',
      (tester) async {
        final harness = AppThreeWayWsHarness();
        addTearDown(() => tester.runAsync(harness.dispose));

        final storage = _RecordingSettingsStorage();
        final audio = FtermAudioController(engineFactory: _FakeAudioEngine.new);
        final workspace = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(token: harness.token),
          repository: CastClientRepository(
            transport: WsClientTransport(
              serverUri: CastLaunchConfig.defaultServerUri,
              token: harness.token,
              channelFactory: harness.openClientChannel,
            ),
            enableReconnect: false,
          ),
          localHostDriver: _StubOnlyLocalHostDriver(),
          audioController: audio,
          storage: storage,
          resizeDebounce: Duration.zero,
        );
        addTearDown(() => tester.runAsync(workspace.dispose));

        for (var i = 1; i <= 20; i++) {
          workspace.updatePreferences(
            workspace.preferences.copyWith(audioVolume: i / 20.0),
          );
          await tester.pump(const Duration(milliseconds: 2));
        }

        expect(audio.volume, closeTo(1.0, 1e-6));
        expect(storage.writeCounts[ftermPreferencesStorageKey], equals(1));

        await tester.pump(const Duration(milliseconds: 200));
        expect(storage.writeCounts[ftermPreferencesStorageKey], equals(2));
        expect(loadStoredPreferences(storage).audioVolume, closeTo(1.0, 1e-6));
        await tester.pump(const Duration(milliseconds: 200));
        await tester.runAsync(workspace.dispose);
      },
    );

    test(
      'IoLocalHostDriver resolves POSIX login args, UTF-8 LANG fallback, and USERPROFILE working directory',
      () {
        const defaultConfig = LocalShellConfig();
        expect(
          IoLocalHostDriver.resolveShellArguments(
            defaultConfig,
            '/bin/zsh',
            isWindows: false,
          ),
          equals(const ['-l']),
        );
        expect(
          IoLocalHostDriver.resolveShellArguments(
            defaultConfig,
            '/usr/bin/fish',
            isWindows: false,
          ),
          equals(const ['-l']),
        );
        expect(
          IoLocalHostDriver.resolveShellArguments(
            const LocalShellConfig(executable: '/bin/zsh'),
            '/bin/zsh',
            isWindows: false,
          ),
          isEmpty,
        );
        expect(
          IoLocalHostDriver.resolveShellArguments(
            const LocalShellConfig(loginShell: false),
            '/bin/zsh',
            isWindows: false,
          ),
          isEmpty,
        );
        expect(
          IoLocalHostDriver.resolveShellArguments(
            const LocalShellConfig(executable: '/bin/zsh', loginShell: true),
            '/bin/zsh',
            isWindows: false,
          ),
          equals(const ['-l']),
        );
        expect(
          IoLocalHostDriver.resolveShellArguments(
            const LocalShellConfig(arguments: ['-i']),
            '/bin/bash',
            isWindows: false,
          ),
          equals(const ['-i']),
        );
        expect(
          IoLocalHostDriver.resolveShellArguments(
            defaultConfig,
            'pwsh.exe',
            isWindows: true,
          ),
          isEmpty,
        );

        for (final env in const <Map<String, String>>[
          {},
          {'LANG': ''},
          {'LANG': 'C'},
          {'LANG': 'POSIX'},
        ]) {
          expect(
            IoLocalHostDriver.resolveChildEnvironmentOverrides(env),
            equals(const {'LANG': 'en_US.UTF-8'}),
          );
        }
        expect(
          IoLocalHostDriver.resolveChildEnvironmentOverrides(const {
            'LANG': 'en_US.UTF-8',
          }),
          isEmpty,
        );

        expect(
          IoLocalHostDriver.resolveInitialWorkingDirectory(
            null,
            environment: const {'USERPROFILE': r'C:\Users\alice'},
            directoryExists: (path) => path == r'C:\Users\alice',
          ),
          equals(r'C:\Users\alice'),
        );
      },
    );

    test(
      'IoLocalHostDriver awaits shared ConPTY download before starting Windows shells and retries after transient null',
      () async {
        final downloadFlags = <bool>[];
        final startedBackends = <_TestRoutedPtyBackend>[];
        Completer<String?>? pendingPrepare;
        String? nextResult;
        var prepareCalls = 0;

        final driver = IoLocalHostDriver(
          isWindows: true,
          downloadConPty: true,
          ensureConPtyReady: ({bool download = false, onWarning}) {
            prepareCalls += 1;
            downloadFlags.add(download);
            final completer = pendingPrepare;
            if (completer != null) {
              return completer.future;
            }
            return Future<String?>.value(nextResult);
          },
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
              }) {
                final b = _TestRoutedPtyBackend();
                startedBackends.add(b);
                return b;
              },
        );
        addTearDown(driver.dispose);

        // 1. Offline / transient null: returns gracefully and retries on next open.
        nextResult = null;
        final offlineHost = await driver.openShell(
          const LocalShellConfig(executable: 'pwsh.exe'),
        );
        expect(prepareCalls, equals(1));
        expect(downloadFlags, equals(const [true]));
        expect(startedBackends, hasLength(1));
        await offlineHost.dispose();

        // 2. Concurrent shell launches share the same in-flight future and wait
        //    until ConPTY staging finishes before spawning backends.
        final activeCompleter = Completer<String?>();
        pendingPrepare = activeCompleter;
        final openA = driver.openShell(
          const LocalShellConfig(executable: 'pwsh.exe'),
        );
        final openB = driver.openShell(
          const LocalShellConfig(executable: 'pwsh.exe'),
        );
        await Future<void>.delayed(Duration.zero);
        expect(prepareCalls, equals(2));
        expect(
          startedBackends,
          hasLength(1),
          reason:
              'Neither concurrent shell may start before ConPTY staging finishes.',
        );

        activeCompleter.complete(r'C:\pty2\conpty.dll');
        pendingPrepare = null;
        final hostA = await openA;
        final hostB = await openB;
        expect(startedBackends, hasLength(3));
        await hostA.dispose();
        await hostB.dispose();

        // 3. Subsequent shell launch reuses cached resolved ConPTY without re-probing.
        final cachedHost = await driver.openShell(
          const LocalShellConfig(executable: 'pwsh.exe'),
        );
        expect(prepareCalls, equals(2));
        await cachedHost.dispose();
      },
    );

    test('IoLocalHostDriver skips ConPTY preparation on non-Windows', () async {
      var prepareCalls = 0;
      final driver = IoLocalHostDriver(
        isWindows: false,
        downloadConPty: true,
        ensureConPtyReady: ({bool download = false, onWarning}) async {
          prepareCalls += 1;
          return r'C:\pty2\conpty.dll';
        },
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
            }) => _TestRoutedPtyBackend(),
      );
      addTearDown(driver.dispose);

      final host = await driver.openShell(
        const LocalShellConfig(executable: '/bin/sh'),
      );
      expect(prepareCalls, equals(0));
      await host.dispose();
    });

    test(
      'elects one canonical pane per remote SessionId so twin split panes do not double-play bell/audio or increment unread badges',
      () async {
        final harness = AppThreeWayWsHarness();
        final pty = await harness.startCaster(id: 'twin-s1', title: 'twin');
        addTearDown(harness.dispose);

        final fakeEngine = _FakeAudioEngine();
        final workspace = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(token: harness.token),
          repository: CastClientRepository(
            transport: WsClientTransport(
              serverUri: CastLaunchConfig.defaultServerUri,
              token: harness.token,
              channelFactory: harness.openClientChannel,
            ),
            enableReconnect: false,
          ),
          localHostDriver: _StubOnlyLocalHostDriver(),
          audioController: FtermAudioController(
            engineFactory: () => fakeEngine,
            requireUserGesture: false,
          ),
          storage: _InMemorySettingsStorage(),
          resizeDebounce: Duration.zero,
        );
        addTearDown(workspace.dispose);

        await workspace.start();
        await _pumpUntil(() => workspace.tabs.length == 1);
        await workspace.splitFocusedPane(SplitAxis.horizontal);
        expect(workspace.tabs.single.splitTree.paneCount, equals(2));

        // Pane 2 (right, pan = +0.5) is focused. Emit 1 BEL + 1 APC tone from caster.
        pty.emitRawAnsi('\x07\x1b_Aa=tone,w=sine,f=523,d=40;\x1b\\');
        await _pumpUntil(() => workspace.audioEventsCount >= 1);
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(workspace.bellEventsCount, equals(1));
        expect(workspace.audioEventsCount, equals(1));
        expect(fakeEngine.playedVoices, hasLength(2));
        expect(fakeEngine.lastVoicePan, closeTo(0.5, 1e-6));
        expect(workspace.tabs.single.unreadBellCount, equals(0));
      },
    );

    test(
      'routes TerminalWaveformQueryAudioEvent end-to-end across remote and local panes and stays silent when muted, zero-volume, or uninitialized',
      () async {
        // 1. FtermAudioController.captureActiveWaveform returns null until initialized, unmuted, and volume > 0.
        final unitEngine = _FakeAudioEngine()
          ..nextWaveform = (Float32List(256)..[7] = 0.625);
        final unitCtrl = FtermAudioController(
          engineFactory: () => unitEngine,
          requireUserGesture: false,
          initialVolume: 0.7,
        );
        expect(unitCtrl.captureActiveWaveform(), isNull);
        await unitCtrl.notifyUserGesture();
        expect(unitCtrl.captureActiveWaveform()?[7], closeTo(0.625, 1e-6));
        unitCtrl.setMuted(true);
        expect(unitCtrl.captureActiveWaveform(), isNull);
        unitCtrl.setMuted(false);
        unitCtrl.setVolume(0.0);
        expect(unitCtrl.captureActiveWaveform(), isNull);
        await unitCtrl.handleAudioEvent(
          const TerminalWaveformQueryAudioEvent(requestId: 1),
        );
        await unitCtrl.dispose();

        // 2. End-to-end remote query: muted viewer stays silent so active unmuted viewer wins _pendingWaveformReqId.
        final harness = AppThreeWayWsHarness();
        final pty = await harness.startCaster(id: 'wave-e2e', title: 'wave');
        addTearDown(harness.dispose);

        final mutedEngine = _FakeAudioEngine()
          ..nextWaveform = (Float32List(256)..[0] = 0.125);
        final mutedWs = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(token: harness.token),
          repository: CastClientRepository(
            transport: WsClientTransport(
              serverUri: CastLaunchConfig.defaultServerUri,
              token: harness.token,
              channelFactory: harness.openClientChannel,
            ),
            enableReconnect: false,
          ),
          localHostDriver: _StubOnlyLocalHostDriver(),
          audioController: FtermAudioController(
            engineFactory: () => mutedEngine,
            requireUserGesture: false,
            initialMuted: true,
          ),
          storage: _InMemorySettingsStorage(),
          resizeDebounce: Duration.zero,
        );
        addTearDown(mutedWs.dispose);

        final activeSamples = Float32List(256)..[5] = -0.75;
        final activeEngine = _FakeAudioEngine()..nextWaveform = activeSamples;
        final activeDriver = _FakeLocalHostDriver(harness: harness);
        final activeWs = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(token: harness.token),
          repository: CastClientRepository(
            transport: WsClientTransport(
              serverUri: CastLaunchConfig.defaultServerUri,
              token: harness.token,
              channelFactory: harness.openClientChannel,
            ),
            enableReconnect: false,
          ),
          localHostDriver: activeDriver,
          audioController: FtermAudioController(
            engineFactory: () => activeEngine,
            requireUserGesture: false,
          ),
          storage: _InMemorySettingsStorage(),
          resizeDebounce: Duration.zero,
        );
        addTearDown(activeWs.dispose);

        await mutedWs.start();
        mutedWs.audioController.setMuted(true);
        await activeWs.start();
        await _pumpUntil(() => mutedWs.tabs.length == 1);
        await _pumpUntil(
          () => activeWs.availableRemoteSessions.any(
            (s) => s.id.value == 'wave-e2e',
          ),
        );
        activeWs.openRemoteSessionTab(const SessionId('wave-e2e'));
        await _pumpUntil(() => activeWs.tabs.length == 2);
        await activeWs.audioController.notifyUserGesture();

        // 2. D-11: Focused remote muted viewer replies with 256 zeros, while unmuted focused viewer returns engine samples.
        pty.emitRawAnsi('\x1b_Aa=wave,q=88;\x1b\\');
        await _pumpUntil(() => pty.writtenInputs.isNotEmpty);
        expect(
          utf8.decode(pty.writtenInputs.last),
          equals(ApcAudioEncoder.encodeWaveformReply(88, Float32List(256))),
        );

        await mutedWs.dispose();
        final afterMutedLen = pty.writtenInputs.length;
        pty.emitRawAnsi('\x1b_Aa=wave,q=89;\x1b\\');
        await _pumpUntil(() => pty.writtenInputs.length > afterMutedLen);
        final expectedReply = ApcAudioEncoder.encodeWaveformReply(
          89,
          activeSamples,
        );
        expect(pty.writtenInputs.map(utf8.decode), contains(expectedReply));

        // 3. Unfocused local tab 0 stays silent; focused local tab 0 writes a=waver via port.sendInput.
        final localPort = activeDriver.hosts.single.port;
        localPort.sentInputs.clear();
        localPort.emitAudio(
          const TerminalWaveformQueryAudioEvent(requestId: 9),
        );
        expect(localPort.sentInputs, isEmpty);

        activeWs.selectTab(0);
        localPort.emitAudio(
          const TerminalWaveformQueryAudioEvent(requestId: 9),
        );
        expect(
          localPort.sentInputs.map(utf8.decode),
          equals([ApcAudioEncoder.encodeWaveformReply(9, activeSamples)]),
        );

        // Muted or exited local pane stays silent.
        activeWs.focusedPane!.sendInputEvent(
          const tui.AudioApcReplyEvent('Aa=waver,q=1;'),
        );
        localPort.sentInputs.clear();
        activeWs.audioController.setMuted(true);
        localPort.emitAudio(
          const TerminalWaveformQueryAudioEvent(requestId: 10),
        );
        expect(localPort.sentInputs, isEmpty);

        activeWs.audioController.setMuted(false);
        localPort.completeExit(0);
        await Future<void>.delayed(Duration.zero);
        localPort.emitAudio(
          const TerminalWaveformQueryAudioEvent(requestId: 11),
        );
        expect(localPort.sentInputs, isEmpty);
      },
    );

    test(
      'FtermPaneController incremental delta recomposition is cell-for-cell identical to fresh full recomposition',
      () async {
        const sessionId = SessionId('inc-equiv');
        final toClient = StreamController<Uint8List>(sync: true);
        final fromClient = StreamController<Uint8List>(sync: true);
        final serverSub = fromClient.stream.listen((_) {});
        final transport = WsClientTransport(
          channelFactory: () async =>
              StreamChannel<Uint8List>(toClient.stream, fromClient.sink),
        );
        final repo = CastClientRepository(
          transport: transport,
          enableReconnect: false,
        );
        addTearDown(() async {
          await serverSub.cancel();
          await toClient.close();
          await fromClient.close();
          await repo.dispose();
        });

        await repo.connect();
        toClient.add(
          BufferFrameCodec.encode(const AuthAcceptedFrame(role: .client)),
        );
        await Future<void>.delayed(Duration.zero);

        final port = repo.openTerminalPort(
          sessionId,
          initialCols: 16,
          initialRows: 4,
        );
        await Future<void>.delayed(Duration.zero);

        final initialResolver = TerminalColorResolver(
          theme: tui.TerminalColorTheme.solarizedDark,
          settings: const TerminalThemeSettings(
            minimumContrast: 4.5,
            boldIsBright: true,
          ),
        );
        final pane = FtermPaneController(
          paneId: 'pane-inc',
          port: port,
          colorResolver: initialResolver,
          remoteSessionId: sessionId,
        )..setFocused(true);
        addTearDown(() => pane.dispose(disposePort: false));

        void assertMatchesFreshFull(TerminalColorResolver resolver) {
          final fresh = FtermPaneController(
            paneId: 'pane-fresh',
            port: port,
            colorResolver: resolver,
            remoteSessionId: sessionId,
          )..setFocused(pane.isFocused);
          final actual = pane.displayBuffer;
          final expected = fresh.displayBuffer;
          expect(actual.width, equals(expected.width));
          expect(actual.height, equals(expected.height));
          expect(actual.characters, equals(expected.characters));
          expect(actual.attributes, equals(expected.attributes));
          final total = actual.width * actual.height;
          for (var i = 0; i < total; i++) {
            expect(
              actual.getUnderlineColorAt(i),
              equals(expected.getUnderlineColorAt(i)),
              reason: 'underline mismatch at cell $i',
            );
            expect(
              actual.getUriAt(i),
              equals(expected.getUriAt(i)),
              reason: 'uri mismatch at cell $i',
            );
          }
          fresh.dispose(disposePort: false);
        }

        // Snapshot with initial text, wide CJK graphemes, SGR 58, and OSC 8.
        final initBuf = tui.Buffer.blank(16, 4)
          ..writeString(
            0,
            0,
            'Hi漢字',
            tui.Style(
              foreground: const tui.Color.ansi(4),
              modifiers: tui.Modifier.bold,
            ),
          )
          ..setUnderlineColor(0, 0, 0xFF11AA22)
          ..setUri(1, 0, 'https://termui.dev');
        toClient.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: BufferSnapshot.fromBuffer(
                sessionId: sessionId,
                seq: 1,
                buffer: initBuf,
                cursor: const CursorState(x: 1, y: 0, visible: true),
                modes: TerminalModes.defaults,
                scrollback: const ScrollbackWindow(
                  clearSeq: 1,
                  oldestLine: 0,
                  totalLines: 10,
                ),
              ),
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        assertMatchesFreshFull(initialResolver);

        // 1. Typing delta + cursor move + SGR 58 + OSC 8 update.
        toClient.add(
          BufferFrameCodec.encode(
            BufferDeltaFrame(
              delta: BufferDelta(
                sessionId: sessionId,
                baseSeq: 1,
                seq: 2,
                cols: 16,
                rows: 4,
                cursor: const CursorState(x: 6, y: 1, visible: true),
                modes: TerminalModes.defaults,
                scrollback: const ScrollbackWindow(
                  clearSeq: 1,
                  oldestLine: 0,
                  totalLines: 10,
                ),
                runs: [
                  CellRun(
                    startIndex: 16,
                    characters: const ['A', 'B', 'C'],
                    attributes: Uint32List.fromList([
                      const tui.Color.ansi(2).argb,
                      const tui.Color.ansi(0).argb,
                      tui.Modifier.underline,
                      0xFF445566,
                      0,
                      tui.Modifier.italic,
                      const tui.Color.ansi(1).argb,
                      0,
                      tui.Modifier.reverse,
                    ]),
                    underlineColors: const {0: 0xFFFF00FF},
                    uriRuns: const [
                      (start: 1, length: 2, uri: 'https://example.com'),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        assertMatchesFreshFull(initialResolver);

        // 2. Cursor-only delta (hides cursor, then moves it to wide cell).
        toClient.add(
          BufferFrameCodec.encode(
            BufferDeltaFrame(
              delta: BufferDelta(
                sessionId: sessionId,
                baseSeq: 2,
                seq: 3,
                cols: 16,
                rows: 4,
                cursor: const CursorState(x: 2, y: 0, visible: false),
                modes: TerminalModes.defaults,
                scrollback: const ScrollbackWindow(
                  clearSeq: 1,
                  oldestLine: 0,
                  totalLines: 10,
                ),
                runs: const [],
              ),
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        assertMatchesFreshFull(initialResolver);

        // 3. Clearing previously set SGR 58 + OSC 8 + restoring cursor visibility.
        toClient.add(
          BufferFrameCodec.encode(
            BufferDeltaFrame(
              delta: BufferDelta(
                sessionId: sessionId,
                baseSeq: 3,
                seq: 4,
                cols: 16,
                rows: 4,
                cursor: const CursorState(x: 2, y: 0, visible: true),
                modes: TerminalModes.defaults,
                scrollback: const ScrollbackWindow(
                  clearSeq: 1,
                  oldestLine: 0,
                  totalLines: 10,
                ),
                runs: [
                  CellRun(
                    startIndex: 16,
                    characters: const ['X', 'Y'],
                    attributes: Uint32List.fromList([0, 0, 0, 0, 0, 0]),
                  ),
                ],
              ),
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        assertMatchesFreshFull(initialResolver);

        // 4. Scrollback scroll + return to bottom.
        pane.scrollLines(2);
        expect(pane.scrollOffsetLines, equals(2));
        pane.jumpToBottom();
        assertMatchesFreshFull(initialResolver);

        // 5. Focus toggle + theme change + incremental delta under termuiDark inverse cursor.
        pane.setFocused(false);
        assertMatchesFreshFull(initialResolver);
        final darkResolver = TerminalColorResolver(
          theme: tui.TerminalColorTheme.termuiDark,
          settings: const TerminalThemeSettings(),
        );
        pane.setColorResolver(darkResolver);
        pane.setFocused(true);
        assertMatchesFreshFull(darkResolver);

        toClient.add(
          BufferFrameCodec.encode(
            BufferDeltaFrame(
              delta: BufferDelta(
                sessionId: sessionId,
                baseSeq: 4,
                seq: 5,
                cols: 16,
                rows: 4,
                cursor: const CursorState(x: 4, y: 2, visible: true),
                modes: TerminalModes.defaults,
                scrollback: const ScrollbackWindow(
                  clearSeq: 1,
                  oldestLine: 0,
                  totalLines: 10,
                ),
                runs: [
                  CellRun(
                    startIndex: 32,
                    characters: const ['Z'],
                    attributes: Uint32List.fromList([0, 0, 0]),
                  ),
                ],
              ),
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        assertMatchesFreshFull(darkResolver);
      },
    );

    test(
      'D-13: _tryIncrementalRecomposite clears stale metadata when src clears effects or selectableRegions',
      () {
        final port = _IncrementalMetaTerminalPort();
        port.mutableBuffer.writeString(0, 0, 'AB', const tui.Style());
        port.mutableBuffer.registerSelectableRegion(const tui.Rect(0, 0, 4, 1));

        final resolver = TerminalColorResolver(
          theme: tui.TerminalColorTheme.termuiDark,
          settings: const TerminalThemeSettings(),
        );
        final pane = FtermPaneController(
          paneId: 'pane-meta',
          port: port,
          colorResolver: resolver,
        )..setFocused(true);
        addTearDown(() => pane.dispose(disposePort: false));

        expect(pane.displayBuffer.selectableRegions, isNotEmpty);

        // Clear metadata on src and emit an incremental dirty span without fullSyncRevision bump.
        port.mutableBuffer.clearMetadata();
        port.mutableBuffer.writeString(0, 0, 'X', const tui.Style());
        port.bumpIncremental(start: 0, length: 1);

        expect(pane.displayBuffer.selectableRegions, isEmpty);
      },
    );
  });
}

final class _IncrementalMetaTerminalPort extends _MemoryTerminalPort {
  int _rev = 1;
  List<DirtyCellSpan> _spans = const [];

  tui.Buffer get mutableBuffer => _buffer;

  @override
  int get renderRevision => _rev;

  @override
  List<DirtyCellSpan> get dirtySpans => _spans;

  void bumpIncremental({required int start, required int length}) {
    _rev += 1;
    _spans = [(start: start, length: length, revision: _rev)];
    for (final fn in [..._listeners]) {
      fn();
    }
  }
}

final class _TestRoutedPtyBackend implements RoutedPtyBackend {
  final StreamController<Uint8List> _output =
      StreamController<Uint8List>.broadcast();
  final Completer<int> _exitCode = Completer<int>();
  bool killed = false;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  void write(Uint8List bytes) {}

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  void kill() {
    killed = true;
    if (!_exitCode.isCompleted) _exitCode.complete(0);
  }

  @override
  Future<void> dispose() async {
    if (!_output.isClosed) await _output.close();
    if (!_exitCode.isCompleted) _exitCode.complete(0);
  }
}

final class _ThrowingOpenShellDriver implements LocalHostDriver {
  @override
  bool get isSupported => true;

  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) =>
      Future.error(StateError('spawn failed'));

  @override
  Future<void> dispose() async {}
}

final class _RecordingSettingsStorage implements SettingsStorage {
  final Map<String, String> writes = {};
  final Map<String, int> writeCounts = {};

  @override
  String? getItem(String key) => writes[key];

  @override
  void setItem(String key, String value) {
    writes[key] = value;
    writeCounts[key] = (writeCounts[key] ?? 0) + 1;
  }
}

final class _ConfigurableLocalHostDriver implements LocalHostDriver {
  final List<Completer<void>> disposeGates;
  final List<Completer<void>?> openGates;
  final void Function(int index)? onOpenStarted;
  final List<_ConfigurableLocalPaneHost> createdHosts = [];
  int _nextIndex = 0;

  _ConfigurableLocalHostDriver({
    this.disposeGates = const [],
    this.openGates = const [],
    this.onOpenStarted,
  });

  @override
  bool get isSupported => true;

  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) async {
    final idx = _nextIndex++;
    onOpenStarted?.call(idx);
    if (idx < openGates.length && openGates[idx] != null) {
      await openGates[idx]!.future;
    }
    final gate = idx < disposeGates.length
        ? disposeGates[idx]
        : (Completer<void>()..complete());
    final host = _ConfigurableLocalPaneHost(
      id: 'cfg-local-$idx',
      disposeGate: gate,
    );
    createdHosts.add(host);
    return host;
  }

  @override
  Future<void> dispose() async {
    for (final h in createdHosts) {
      if (!h.disposeGate.isCompleted) {
        h.disposeGate.complete();
      }
      await h.dispose();
    }
  }
}

final class _ConfigurableLocalPaneHost implements LocalPaneHost {
  @override
  final String id;
  final Completer<void> disposeGate;
  @override
  final _MemoryTerminalPort port = _MemoryTerminalPort();
  final Completer<int> _exitCode = Completer<int>();
  final StreamController<LocalShareSnapshot> _shareUpdates =
      StreamController<LocalShareSnapshot>.broadcast();
  bool disposed = false;

  _ConfigurableLocalPaneHost({required this.id, required this.disposeGate});

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  LocalShareSnapshot get shareSnapshot => LocalShareSnapshot.unshared;

  @override
  Stream<LocalShareSnapshot> get shareUpdates => _shareUpdates.stream;

  @override
  Future<SessionId> startShare({
    required Uri serverUri,
    required String casterToken,
    required String title,
    String? uploadDirPath,
    IapTokenProvider? iapTokenProvider,
    CasterTransportOpener? channelOpener,
  }) => throw UnsupportedError('Not used');

  @override
  Future<void> stopShare() async {}

  @override
  void setColorScheme(tui.TerminalBrightness brightness) {}

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await disposeGate.future;
    await port.dispose();
    if (!_exitCode.isCompleted) _exitCode.complete(0);
    await _shareUpdates.close();
  }
}

void _defineWave2HardeningTests() {
  group('Wave 2 security, scrollback wrap, upload, and driver hardening', () {
    test(
      'FtermPaneController handles oldestLine > 0 scrollback wrap without RangeError on local & remote ports',
      () async {
        // 1. Local port with evicted scrollback (oldestLine: 5000, retained: 1200).
        final localPort = _MemoryTerminalPort();
        addTearDown(localPort.dispose);
        localPort.oldestScrollbackLine = 5000;
        localPort.scrollbackRows = [
          for (var i = 0; i < 1200; i++)
            ScrollbackLine(
              width: 80,
              characters: ['L', '$i'],
              attributes: Uint32List(6),
              uris: ['https://example.com/${5000 + i}', null],
            ),
        ];
        final resolver = TerminalColorResolver(
          theme: tui.TerminalColorTheme.termuiDark,
          settings: const TerminalThemeSettings(),
        );
        final localPane = FtermPaneController(
          paneId: 'wrap-local',
          port: localPort,
          colorResolver: resolver,
        );
        addTearDown(() => localPane.dispose(disposePort: false));

        // Scroll beyond retained scrollback clamps cleanly to 1200 and maps virtual lines.
        localPane.scrollLines(2000);
        expect(localPane.scrollOffsetLines, equals(1200));
        final topLink = localPane.lookupLinkLine(0);
        expect(topLink?.uris?.first, equals('https://example.com/5000'));

        // Scroll partway into wrapped history.
        localPane.jumpToBottom();
        localPane.scrollLines(10);
        expect(localPane.scrollOffsetLines, equals(10));
        expect(
          localPane.lookupLinkLine(0)?.uris?.first,
          equals('https://example.com/6190'),
        );

        // 2. Remote port receiving BufferSnapshotFrame(oldestLine: 5000, totalLines: 6200)
        //    + ScrollbackChunkFrame returning lines 5000..5003.
        const remoteId = SessionId('wrap-remote');
        final toClient = StreamController<Uint8List>(sync: true);
        final fromClient = StreamController<Uint8List>(sync: true);
        final fromClientFrames = <CastMessage>[];
        final fromSub = fromClient.stream.listen(
          (bytes) => fromClientFrames.add(BufferFrameCodec.decode(bytes)),
        );
        final repo = CastClientRepository(
          transport: WsClientTransport(
            channelFactory: () async =>
                StreamChannel<Uint8List>(toClient.stream, fromClient.sink),
          ),
          enableReconnect: false,
        );
        addTearDown(() async {
          await fromSub.cancel();
          await repo.dispose();
          await toClient.close();
          await fromClient.close();
        });
        await repo.connect();
        toClient.add(
          BufferFrameCodec.encode(const AuthAcceptedFrame(role: .client)),
        );
        await Future<void>.delayed(Duration.zero);

        final remotePort = repo.openTerminalPort(
          remoteId,
          initialCols: 16,
          initialRows: 4,
        );
        final remotePane = FtermPaneController(
          paneId: 'wrap-remote-pane',
          port: remotePort,
          colorResolver: resolver,
          remoteSessionId: remoteId,
        );
        addTearDown(() => remotePane.dispose(disposePort: false));

        toClient.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: BufferSnapshot.fromBuffer(
                sessionId: remoteId,
                seq: 1,
                buffer: tui.Buffer.blank(16, 4),
                cursor: const CursorState(x: 0, y: 0),
                modes: TerminalModes.defaults,
                scrollback: const ScrollbackWindow(
                  clearSeq: 1,
                  oldestLine: 5000,
                  totalLines: 6200,
                ),
              ),
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        remotePane.scrollLines(2000);
        expect(remotePane.scrollOffsetLines, equals(1200));
        final sbReq = fromClientFrames.whereType<RequestScrollbackFrame>().last;
        expect(sbReq.startLine, equals(5000));

        toClient.add(
          BufferFrameCodec.encode(
            ScrollbackChunkFrame(
              sessionId: remoteId,
              requestId: sbReq.requestId,
              clearSeq: 1,
              startLine: 5000,
              rows: [
                for (var i = 0; i < 4; i++)
                  EncodedScrollbackRow(
                    isWrapped: false,
                    characters: const ['W', 'R', 'A', 'P'],
                    attributes: Uint32List(12),
                    uriRuns: [
                      (
                        start: 0,
                        length: 1,
                        uri: 'https://remote.example/${5000 + i}',
                      ),
                    ],
                  ),
              ],
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(remotePane.displayBuffer.getCharacter(0, 0), equals('W'));
        expect(
          remotePane.lookupLinkLine(0)?.uris?.first,
          equals('https://remote.example/5000'),
        );
      },
    );

    test(
      'OSC 52 clipboard writes require focused pane, active window focus, allow policy, and <= 1 MiB payload',
      () async {
        final copied = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                final args = call.arguments as Map<Object?, Object?>;
                copied.add(args['text'] as String);
              }
              return null;
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null);
        });

        final harness = AppThreeWayWsHarness();
        addTearDown(harness.dispose);
        final driver = _FakeLocalHostDriver(harness: harness);
        final workspace = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(),
          repository: CastClientRepository(
            transport: WsClientTransport(
              channelFactory: harness.openClientChannel,
            ),
            enableReconnect: false,
          ),
          localHostDriver: driver,
          audioController: FtermAudioController(
            engineFactory: _FakeAudioEngine.new,
          ),
          storage: _InMemorySettingsStorage(),
          resizeDebounce: Duration.zero,
        );
        addTearDown(workspace.dispose);

        await workspace.openLocalShellTab();
        final p1 = driver.hosts[0].port;
        await workspace.splitFocusedPane(SplitAxis.horizontal);
        final p2 = driver.hosts[1].port; // p2 is now focused

        // 1. Unfocused pane p1 is blocked.
        p1.emitClipboard('c', 'from-unfocused');
        expect(copied, isEmpty);

        // 2. Background / inactive window blocks even focused pane p2.
        workspace.setWindowFocused(false);
        p2.emitClipboard('c', 'while-unfocused-window');
        expect(copied, isEmpty);
        workspace.setWindowFocused(true);

        // 3. Policy = deny blocks focused pane p2.
        workspace.setOsc52Policy(Osc52ClipboardPolicy.deny);
        p2.emitClipboard('c', 'denied-text');
        expect(copied, isEmpty);
        workspace.setOsc52Policy(Osc52ClipboardPolicy.allowFocused);

        // 4. Oversized > 1 MiB payload is dropped.
        p2.emitClipboard('c', 'x' * (1024 * 1024 + 1));
        expect(copied, isEmpty);

        // 5. Focused pane + active window + allowFocused policy + <= 1 MiB succeeds.
        p2.emitClipboard('c', 'allowed-osc52');
        expect(copied, equals(['allowed-osc52']));
      },
    );

    test(
      'unfocused or background remote waveform queries return 256 zero samples while focused pane returns engine samples',
      () async {
        final harness = AppThreeWayWsHarness();
        addTearDown(harness.dispose);
        final pty = await harness.startCaster(id: 'wf-remote', title: 'wf');

        final fakeEngine = _FakeAudioEngine()
          ..nextWaveform = Float32List.fromList(List.filled(256, 0.75));
        final workspace = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(token: harness.token),
          repository: CastClientRepository(
            transport: WsClientTransport(
              serverUri: CastLaunchConfig.defaultServerUri,
              token: harness.token,
              channelFactory: harness.openClientChannel,
            ),
            enableReconnect: false,
          ),
          localHostDriver: _StubOnlyLocalHostDriver(),
          audioController: FtermAudioController(
            engineFactory: () => fakeEngine,
            requireUserGesture: false,
          ),
          storage: _InMemorySettingsStorage(),
          resizeDebounce: Duration.zero,
        );
        addTearDown(workspace.dispose);

        await workspace.audioController.notifyUserGesture();
        await workspace.start();
        await _pumpUntil(() => workspace.tabs.isNotEmpty);
        final remotePane = workspace.focusedPane!;
        expect(
          remotePane.remoteSessionId,
          equals(const SessionId('wf-remote')),
        );

        // 1. Backgrounded window -> remote waveform query sends 256 zeros.
        workspace.setWindowFocused(false);
        final bytesBeforeBg = pty.writtenInputs.length;
        pty.emitRawAnsi('\x1b_Aa=wave,q=11\x1b\\');
        await _pumpUntil(() => pty.writtenInputs.length > bytesBeforeBg);
        expect(
          utf8.decode(pty.writtenInputs.last),
          equals(ApcAudioEncoder.encodeWaveformReply(11, Float32List(256))),
        );

        // 2. Foreground focused window + focused pane -> sends 0.75 waveform samples.
        workspace.setWindowFocused(true);
        final bytesBeforeFg = pty.writtenInputs.length;
        pty.emitRawAnsi('\x1b_Aa=wave,q=12\x1b\\');
        await _pumpUntil(() => pty.writtenInputs.length > bytesBeforeFg);
        expect(
          utf8.decode(pty.writtenInputs.last),
          equals(
            ApcAudioEncoder.encodeWaveformReply(
              12,
              Float32List.fromList(List.filled(256, 0.75)),
            ),
          ),
        );

        // 3. D-11: Unfocused/background local pane ignores TerminalWaveformQueryAudioEvent.
        final localDriver = _FakeLocalHostDriver(harness: harness);
        final localWs = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(token: harness.token),
          repository: CastClientRepository(
            transport: WsClientTransport(
              serverUri: CastLaunchConfig.defaultServerUri,
              token: harness.token,
              channelFactory: harness.openClientChannel,
            ),
            enableReconnect: false,
          ),
          localHostDriver: localDriver,
          audioController: FtermAudioController(
            engineFactory: () => fakeEngine,
            requireUserGesture: false,
          ),
          storage: _InMemorySettingsStorage(),
          resizeDebounce: Duration.zero,
        );
        addTearDown(localWs.dispose);
        await localWs.audioController.notifyUserGesture();
        await localWs.start();
        await localWs.openLocalShellTab();
        expect(localDriver.hosts.length, equals(2));
        final bgLocalPort = localDriver.hosts[0].port;
        bgLocalPort.sentInputs.clear();
        bgLocalPort.emitAudio(
          const TerminalWaveformQueryAudioEvent(requestId: 77),
        );
        expect(bgLocalPort.sentInputs, isEmpty);
      },
    );

    test(
      'cancelFileUpload / dismissOverlay cancels upload and staged sessionId stays pinned across focus switch',
      () async {
        final harness = AppThreeWayWsHarness();
        addTearDown(harness.dispose);
        await harness.startCaster(id: 'up-s1', title: 's1');
        await harness.startCaster(id: 'up-s2', title: 's2');

        final workspace = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(token: harness.token),
          repository: CastClientRepository(
            transport: WsClientTransport(
              serverUri: CastLaunchConfig.defaultServerUri,
              token: harness.token,
              channelFactory: harness.openClientChannel,
            ),
            enableReconnect: false,
          ),
          localHostDriver: _StubOnlyLocalHostDriver(),
          audioController: FtermAudioController(
            engineFactory: _FakeAudioEngine.new,
          ),
          storage: _InMemorySettingsStorage(),
          resizeDebounce: Duration.zero,
        );
        addTearDown(workspace.dispose);

        await workspace.start();
        await _pumpUntil(() => workspace.tabs.length == 2);
        workspace.selectTab(0);
        final s1SessionId = workspace.focusedPane!.remoteSessionId!;

        // Stage file on s1, then switch active tab to s2 before confirming/canceling.
        workspace.stageDroppedFiles([
          MemoryDroppedFileSource(
            name: 'staged.txt',
            bytes: Uint8List.fromList(utf8.encode('payload')),
          ),
        ]);
        expect(workspace.activeOverlay, equals(FtermOverlay.fileUpload));
        expect(workspace.pendingUploadFiles, hasLength(1));

        workspace.selectTab(1);
        expect(
          workspace.focusedPane!.remoteSessionId,
          isNot(equals(s1SessionId)),
        );

        // Confirming uploads to s1 (the pinned session), not s2; dismissing clears cleanly.
        workspace.dismissOverlay();
        expect(workspace.activeOverlay, equals(FtermOverlay.none));
        expect(workspace.pendingUploadFiles, isEmpty);
        expect(await workspace.confirmFileUpload(), isFalse);
      },
    );

    test(
      'IoLocalHostDriver.openShell disposed during ConPTY prepare throws StateError without spawning backend',
      () async {
        final prepareGate = Completer<String?>();
        var backendCalls = 0;
        final driver = IoLocalHostDriver(
          isWindows: true,
          downloadConPty: false,
          ensureConPtyReady: ({download = false, onWarning}) =>
              prepareGate.future,
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
              }) {
                backendCalls += 1;
                return _TestRoutedPtyBackend();
              },
        );

        final openFuture = driver.openShell(const LocalShellConfig());
        await driver.dispose();
        prepareGate.complete('C:\\fake\\conpty.dll');

        await expectLater(openFuture, throwsStateError);
        expect(backendCalls, equals(0));
      },
    );

    test(
      'togglePaneShare ignores rapid double-invocation while startShare is in flight',
      () async {
        final harness = AppThreeWayWsHarness();
        addTearDown(harness.dispose);
        final startGate = Completer<void>();
        final driver = _GateableLocalHostDriver(
          harness: harness,
          startGate: startGate,
        );
        final workspace = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(),
          repository: CastClientRepository(
            transport: WsClientTransport(
              channelFactory: harness.openClientChannel,
            ),
            enableReconnect: false,
          ),
          localHostDriver: driver,
          audioController: FtermAudioController(
            engineFactory: _FakeAudioEngine.new,
          ),
          storage: _InMemorySettingsStorage(),
          resizeDebounce: Duration.zero,
        );
        addTearDown(workspace.dispose);

        await workspace.openLocalShellTab();
        final paneId = workspace.focusedPane!.paneId;

        final first = workspace.togglePaneShare(paneId: paneId);
        final second = workspace.togglePaneShare(paneId: paneId);
        expect(await second, isFalse);

        startGate.complete();
        expect(await first, isTrue);
        expect(driver.hosts.single.startShareCalls, equals(1));
      },
    );

    test(
      'IoLocalHostDriver statusStream transitions error snapshot and cleans up subscription on failure and dispose',
      () async {
        final driver = IoLocalHostDriver(
          isWindows: false,
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
              }) => _TestRoutedPtyBackend(),
        );
        addTearDown(driver.dispose);

        final host = await driver.openShell(const LocalShellConfig());
        final states = <LocalShareState>[];
        final sub = host.shareUpdates.listen((s) => states.add(s.state));
        addTearDown(sub.cancel);

        await host.startShare(
          serverUri: Uri.parse('ws://127.0.0.1:8420/v1/caster'),
          casterToken: 'bad-tok',
          title: 'status-test',
          channelOpener: () async {
            final ctrl = StreamChannelController<Uint8List>();
            ctrl.foreign.stream.listen((raw) {
              if (BufferFrameCodec.decode(raw) is AuthFrame) {
                ctrl.foreign.sink.add(
                  BufferFrameCodec.encode(
                    const ErrorFrame(
                      code: 'auth_failed',
                      message: 'invalid caster token',
                    ),
                  ),
                );
              }
            });
            return ctrl.local;
          },
        );

        await _pumpUntil(
          () => host.shareSnapshot.state == LocalShareState.error,
        );
        expect(driver.hasActiveSharePolling, isFalse);
        expect(states, contains(LocalShareState.error));
        await host.dispose();
        expect(driver.hasActiveSharePolling, isFalse);
      },
    );

    test(
      'workspace font zoom methods, shell arg parser, and shell overrides wire through new tabs and splits',
      () async {
        expect(
          FtermWorkspaceController.parseShellArguments('  -l\t--norc  '),
          equals(const ['-l', '--norc']),
        );
        expect(FtermWorkspaceController.parseShellArguments('   '), isEmpty);
        expect(
          FtermWorkspaceController.parseShellArguments(
            '-c "tmux new -A -s main"',
          ),
          equals(const ['-c', 'tmux new -A -s main']),
        );
        expect(
          FtermWorkspaceController.parseShellArguments(
            '--rcfile "/path/with spaces/bashrc"',
          ),
          equals(const ['--rcfile', '/path/with spaces/bashrc']),
        );
        expect(
          FtermWorkspaceController.parseShellArguments('""'),
          equals(const ['']),
        );
        expect(
          FtermWorkspaceController.parseShellArguments(r'-c "echo \"hi\""'),
          equals(const ['-c', 'echo "hi"']),
        );
        expect(
          FtermWorkspaceController.parseShellArguments(
            r"'-c' 'echo \x' \--flag",
          ),
          equals(const ['-c', r'echo \x', '--flag']),
        );
        const roundTripCases = [
          <String>[],
          ['-l', '--norc'],
          ['-c', 'tmux new -A -s main'],
          ['--rcfile', '/path/with spaces/bashrc'],
          [''],
          ['-c', 'echo "hi"'],
          ['-c', r'a\b'],
        ];
        for (final args in roundTripCases) {
          final formatted = FtermWorkspaceController.formatShellArguments(args);
          expect(
            FtermWorkspaceController.parseShellArguments(formatted),
            equals(args),
          );
        }

        final harness = AppThreeWayWsHarness();
        final repo = CastClientRepository(
          transport: WsClientTransport(
            channelFactory: harness.openClientChannel,
          ),
        );
        final driver = _GateableLocalHostDriver(
          harness: harness,
          startGate: Completer<void>()..complete(),
        );
        final storage = _InMemorySettingsStorage();
        final audio = FtermAudioController(engineFactory: _FakeAudioEngine.new);
        final workspace = FtermWorkspaceController(
          launchConfig: CastLaunchConfig(
            token: harness.token,
            promptForConnection: false,
          ),
          repository: repo,
          localHostDriver: driver,
          audioController: audio,
          storage: storage,
          defaultFontSize: 15.0,
        );
        addTearDown(() async {
          await workspace.dispose();
          await repo.dispose();
          await driver.dispose();
          await harness.dispose();
        });

        expect(workspace.effectiveFontSize, equals(15.0));
        workspace.adjustFontSize(2.0);
        expect(workspace.effectiveFontSize, equals(17.0));
        workspace.adjustFontSize(-100.0);
        expect(
          workspace.effectiveFontSize,
          equals(FtermPreferences.minFontSize),
        );
        workspace.adjustFontSize(200.0);
        expect(
          workspace.effectiveFontSize,
          equals(FtermPreferences.maxFontSize),
        );
        workspace.resetFontSize();
        expect(workspace.preferences.fontSize, isNull);
        expect(workspace.effectiveFontSize, equals(15.0));

        workspace.updatePreferences(
          workspace.preferences.copyWith(
            shellExecutable: '/usr/bin/zsh',
            shellArguments: const ['-i', '-l'],
            loginShell: false,
          ),
        );
        await workspace.openLocalShellTab();
        expect(driver.openedConfigs.last.executable, equals('/usr/bin/zsh'));
        expect(driver.openedConfigs.last.arguments, equals(const ['-i', '-l']));
        expect(driver.openedConfigs.last.loginShell, isFalse);

        await workspace.splitFocusedPane(SplitAxis.horizontal);
        expect(driver.openedConfigs.last.executable, equals('/usr/bin/zsh'));
        expect(driver.openedConfigs.last.arguments, equals(const ['-i', '-l']));
        expect(driver.openedConfigs.last.loginShell, isFalse);
      },
    );

    test(
      'FtermPaneController.pillNotifier stays silent on 0 -> 0 PTY streaming and notifies on +N -> 0 reset, share updates, and exit',
      () async {
        final harness = AppThreeWayWsHarness();
        final driver = _GateableLocalHostDriver(
          harness: harness,
          startGate: Completer<void>()..complete(),
        );
        final host =
            await driver.openShell(const LocalShellConfig())
                as _GateableLocalPaneHost;
        final controller = FtermPaneController(
          paneId: 'pane-pill',
          port: host.port,
          localHost: host,
          colorResolver: TerminalColorResolver(
            theme: tui.TerminalColorTheme.termuiDark,
            settings: const TerminalThemeSettings(),
          ),
        );
        addTearDown(() async {
          await controller.dispose();
          await host.dispose();
          await harness.dispose();
        });

        var pillHits = 0;
        var visualHits = 0;
        controller.pillNotifier.addListener(() => pillHits += 1);
        controller.visualNotifier.addListener(() => visualHits += 1);

        // Emit normal PTY frames while scrollOffset == 0 -> 0.
        host.port.scrollbackRows = List<ScrollbackLine>.generate(
          20,
          (i) => ScrollbackLine(
            width: 80,
            characters: ['L', '$i'],
            attributes: Uint32List(6),
            uris: const [null, null],
          ),
        );
        for (var i = 0; i < 10; i++) {
          host.port.emitFrame();
        }
        await Future<void>.delayed(Duration.zero);
        expect(visualHits, greaterThan(0));
        expect(pillHits, equals(0));

        // Scroll into scrollback (0 -> +2), then clearSeq reset (+2 -> 0).
        controller.scrollLines(2);
        expect(controller.scrollOffsetLines, equals(2));
        expect(pillHits, equals(1));

        host.port.clearSeq += 1;
        host.port.scrollbackRows = const [];
        host.port.emitFrame();
        await Future<void>.delayed(Duration.zero);
        expect(controller.scrollOffsetLines, equals(0));
        expect(pillHits, equals(2));

        // Share update and process exit notify pillNotifier.
        await host.startShare(
          serverUri: Uri.parse('ws://127.0.0.1:8420/v1/caster'),
          casterToken: 'tok',
          title: 'pill-share',
        );
        await Future<void>.delayed(Duration.zero);
        expect(pillHits, equals(3));

        host.port.completeExit(0);
        await Future<void>.delayed(Duration.zero);
        expect(controller.hasExited, isTrue);
        expect(pillHits, equals(4));
      },
    );
  });
}

final class _GateableLocalHostDriver implements LocalHostDriver {
  final AppThreeWayWsHarness harness;
  final Completer<void> startGate;
  final List<_GateableLocalPaneHost> hosts = [];
  final List<LocalShellConfig> openedConfigs = [];

  _GateableLocalHostDriver({required this.harness, required this.startGate});

  @override
  bool get isSupported => true;

  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) async {
    openedConfigs.add(config);
    final host = _GateableLocalPaneHost(
      id: 'gated-${hosts.length + 1}',
      harness: harness,
      startGate: startGate,
    );
    hosts.add(host);
    return host;
  }

  @override
  Future<void> dispose() async {
    for (final h in hosts) {
      await h.dispose();
    }
  }
}

final class _GateableLocalPaneHost implements LocalPaneHost {
  @override
  final String id;
  final AppThreeWayWsHarness harness;
  final Completer<void> startGate;
  @override
  final _MemoryTerminalPort port = _MemoryTerminalPort();
  final Completer<int> _exitCode = Completer<int>();
  final StreamController<LocalShareSnapshot> _shareUpdates =
      StreamController<LocalShareSnapshot>.broadcast();
  LocalShareSnapshot _snapshot = LocalShareSnapshot.unshared;
  int startShareCalls = 0;

  _GateableLocalPaneHost({
    required this.id,
    required this.harness,
    required this.startGate,
  });

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  LocalShareSnapshot get shareSnapshot => _snapshot;

  @override
  Stream<LocalShareSnapshot> get shareUpdates => _shareUpdates.stream;

  @override
  Future<SessionId> startShare({
    required Uri serverUri,
    required String casterToken,
    required String title,
    String? uploadDirPath,
    IapTokenProvider? iapTokenProvider,
    CasterTransportOpener? channelOpener,
  }) async {
    startShareCalls += 1;
    await startGate.future;
    final assigned = SessionId('gated-$id');
    _snapshot = LocalShareSnapshot(
      state: LocalShareState.live,
      sessionId: assigned,
    );
    if (!_shareUpdates.isClosed) _shareUpdates.add(_snapshot);
    return assigned;
  }

  @override
  Future<void> stopShare() async {
    _snapshot = LocalShareSnapshot.unshared;
    if (!_shareUpdates.isClosed) _shareUpdates.add(_snapshot);
  }

  @override
  void setColorScheme(tui.TerminalBrightness brightness) {}

  @override
  Future<void> dispose() async {
    await port.dispose();
    if (!_exitCode.isCompleted) _exitCode.complete(0);
    await _shareUpdates.close();
  }

  void completeExit(int code) {
    if (!_exitCode.isCompleted) _exitCode.complete(code);
  }
}
