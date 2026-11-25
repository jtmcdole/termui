import 'package:flutter_test/flutter_test.dart';
import 'package:termui_flutter/termui_flutter.dart';

void main() {
  group('GpuFrameWatchdog source-scoped active custom shaders', () {
    test(
      'keeps cli and host shader sets isolated without clobbering each other',
      () {
        final watchdog = GpuFrameWatchdog(
          isBuiltinPreset: (id) => id == 'preset:crt',
        );
        addTearDown(watchdog.dispose);

        // Register host user/draft shader.
        watchdog.setActiveCustomShaders(const <String>[
          'editor:pane-1',
          'preset:crt',
        ], source: 'host');
        expect(
          watchdog.activeCustomShaderIds,
          equals(<String>{'editor:pane-1'}),
        );

        // Default source ('cli') updates must not wipe 'host' shaders.
        watchdog.setActiveCustomShaders(const <String>['cli:spark']);
        expect(
          watchdog.activeCustomShaderIds,
          equals(<String>{'editor:pane-1', 'cli:spark'}),
        );

        // Clearing 'cli' shaders leaves 'host' shaders active.
        watchdog.setActiveCustomShaders(const <String>[]);
        expect(
          watchdog.activeCustomShaderIds,
          equals(<String>{'editor:pane-1'}),
        );
        expect(watchdog.isActiveCustomShader('editor:pane-1'), isTrue);
        expect(watchdog.isActiveCustomShader('cli:spark'), isFalse);

        // Updating 'host' leaves newly added 'cli' shaders active.
        watchdog.setActiveCustomShaders(const <String>[
          'cli:ripple',
        ], source: 'cli');
        watchdog.setActiveCustomShaders(const <String>[
          'user:custom.glsl',
        ], source: 'host');
        expect(
          watchdog.activeCustomShaderIds,
          equals(<String>{'cli:ripple', 'user:custom.glsl'}),
        );

        // Clearing 'host' preserves 'cli'.
        watchdog.setActiveCustomShaders(const <String>[], source: 'host');
        expect(watchdog.activeCustomShaderIds, equals(<String>{'cli:ripple'}));
      },
    );

    test('quarantines slow shaders independently across sources and cleans up on clearQuarantine/reset', () {
      final quarantined = <String>[];
      final watchdog = GpuFrameWatchdog(
        slowFrameThreshold: const Duration(milliseconds: 20),
        consecutiveSlowFrameLimit: 2,
        onShaderQuarantined: (id, _) => quarantined.add(id),
      );
      addTearDown(watchdog.dispose);

      watchdog.setActiveCustomShaders(const <String>['cli:fx'], source: 'cli');
      watchdog.setActiveCustomShaders(const <String>[
        'host:draft',
      ], source: 'host');

      // Slow frames only on host:draft quarantine host:draft without affecting cli:fx.
      watchdog.recordShaderFrameDuration(
        'host:draft',
        const Duration(milliseconds: 40),
      );
      watchdog.recordShaderFrameDuration(
        'host:draft',
        const Duration(milliseconds: 45),
      );
      expect(watchdog.isQuarantined('host:draft'), isTrue);
      expect(watchdog.isQuarantined('cli:fx'), isFalse);
      expect(quarantined, equals(<String>['host:draft']));

      // clearQuarantine lifts quarantine for a specific ID or all IDs.
      watchdog.clearQuarantine('host:draft');
      expect(watchdog.isQuarantined('host:draft'), isFalse);

      // Quarantine both via frame timing, then reset().
      watchdog.recordFrameTiming(const Duration(milliseconds: 50));
      watchdog.recordFrameTiming(const Duration(milliseconds: 50));
      expect(
        watchdog.quarantinedShaderIds,
        equals(<String>{'cli:fx', 'host:draft'}),
      );

      watchdog.reset();
      expect(watchdog.activeCustomShaderIds, isEmpty);
      expect(watchdog.quarantinedShaderIds, isEmpty);

      // Re-adding 'cli' after reset must NOT resurrect old 'host' entries.
      watchdog.setActiveCustomShaders(const <String>[
        'cli:fresh',
      ], source: 'cli');
      expect(watchdog.activeCustomShaderIds, equals(<String>{'cli:fresh'}));
    });

    test('dispose clears per-source maps and ignores subsequent updates', () {
      final watchdog = GpuFrameWatchdog();
      watchdog.setActiveCustomShaders(const <String>[
        'host:draft',
      ], source: 'host');
      watchdog.dispose();

      expect(watchdog.isDisposed, isTrue);
      expect(watchdog.activeCustomShaderIds, isEmpty);

      watchdog.setActiveCustomShaders(const <String>[
        'cli:after',
      ], source: 'cli');
      expect(watchdog.activeCustomShaderIds, isEmpty);
    });

    test('skips per-shader warmup frames before slow-frame quarantine while still quarantining explicit GPU failures immediately', () {
      final quarantined = <String>[];
      final watchdog = GpuFrameWatchdog(
        slowFrameThreshold: const Duration(milliseconds: 33),
        consecutiveSlowFrameLimit: 3,
        warmupFrameCount: 4,
        onShaderQuarantined: (id, _) => quarantined.add(id),
      );
      addTearDown(watchdog.dispose);

      watchdog.setActiveCustomShaders(const <String>[
        'host:circles',
      ], source: 'host');
      expect(watchdog.warmupFramesRemainingFor('host:circles'), equals(4));

      // 4 slow warmup frames are recorded for telemetry but never quarantine.
      for (var i = 0; i < 4; i++) {
        watchdog.recordShaderFrameDuration(
          'host:circles',
          const Duration(milliseconds: 60),
        );
      }
      expect(watchdog.warmupFramesRemainingFor('host:circles'), equals(0));
      expect(watchdog.consecutiveSlowFramesFor('host:circles'), equals(0));
      expect(
        watchdog.lastFrameDurationFor('host:circles'),
        equals(const Duration(milliseconds: 60)),
      );
      expect(watchdog.isQuarantined('host:circles'), isFalse);

      // Adding a sibling shader gives only the new shader its own warmup.
      watchdog.setActiveCustomShaders(const <String>[
        'host:circles',
        'host:aurora',
      ], source: 'host');
      expect(watchdog.warmupFramesRemainingFor('host:circles'), equals(0));
      expect(watchdog.warmupFramesRemainingFor('host:aurora'), equals(4));

      // Next 3 slow frames quarantine host:circles while host:aurora warms up.
      for (var i = 0; i < 3; i++) {
        watchdog.recordFrameTiming(const Duration(milliseconds: 55));
      }
      expect(watchdog.isQuarantined('host:circles'), isTrue);
      expect(watchdog.isQuarantined('host:aurora'), isFalse);
      expect(watchdog.warmupFramesRemainingFor('host:aurora'), equals(1));
      expect(quarantined, equals(<String>['host:circles']));

      // clearQuarantine restores warmup for the resumed shader.
      watchdog.clearQuarantine('host:circles');
      expect(watchdog.isQuarantined('host:circles'), isFalse);
      expect(watchdog.warmupFramesRemainingFor('host:circles'), equals(4));

      // Explicit command buffer failure still quarantines during warmup.
      final token = watchdog.beginCommandSubmission(const <String>[
        'host:circles',
      ]);
      watchdog.completeCommandSubmission(token, success: false);
      expect(watchdog.isQuarantined('host:circles'), isTrue);

      // resetWarmup refreshes active shaders and reset() clears warmup state.
      watchdog.resetWarmup();
      expect(watchdog.warmupFramesRemainingFor('host:aurora'), equals(4));
      watchdog.reset();
      expect(watchdog.warmupFramesRemainingFor('host:aurora'), equals(0));
    });
  });
}
