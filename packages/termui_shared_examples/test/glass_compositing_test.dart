import 'dart:math';
import 'package:fake_async/fake_async.dart';
import 'package:termui/termui.dart';
import 'package:termui_shared_examples/glass_compositing/glass_compositing.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    FocusManager.instance.setPrimaryFocus(null);
  });

  test(
    'runGlassCompositingShared keeps layers mounted on Enter and cleans up timers on q exit',
    () {
      fakeAsync((async) {
        final backend = MockTerminalBackend(size: const Point(80, 24));
        final terminal = Terminal(backend);

        Buffer? lastFrame;
        var exited = false;
        runGlassCompositingShared(
          terminal,
          isInline: false,
          onFrameRedrawn: (buf) {
            lastFrame = buf;
          },
        ).then((_) {
          exited = true;
        });

        async.elapse(const Duration(milliseconds: 100));
        expect(exited, isFalse);
        expect(lastFrame, isNotNull);

        // Pressing Enter while glassLayer is focused must not complete/unmount
        // the managed glassRunner.
        backend.pushString('\r');
        async.elapse(const Duration(milliseconds: 100));

        // Open settings with 's' and press Enter; settingsRunner must remain mounted
        // and reactive to config changes.
        backend.pushString('s');
        async.elapse(const Duration(milliseconds: 100));
        expect(lastFrame!.characters.join(), contains('Classic'));

        backend.pushString('\r');
        async.elapse(const Duration(seconds: 15));
        expect(lastFrame!.characters.join(), contains('Toxic'));

        // Press 'q' to exit and verify all periodic timers are cancelled cleanly.
        backend.pushString('q');
        async.elapse(const Duration(milliseconds: 100));

        expect(exited, isTrue);
        expect(async.periodicTimerCount, equals(0));
      });
    },
  );

  test(
    'PromptRunner.abort synchronously unmounts widget tree so timers are cancelled immediately',
    () {
      fakeAsync((async) {
        final backend = MockTerminalBackend(size: const Point(80, 24));
        final terminal = Terminal(backend);
        final config = FireConfig(InMemorySettingsRepository());

        final runner = PromptRunner<void>(
          terminal: terminal,
          widget: FireApp(config: config),
          alternateScreen: false,
          mode: ExecutionMode.managed,
        );
        runner.run().catchError((_) {});

        expect(async.periodicTimerCount, equals(1));

        // Calling abort() followed by dispose() (as runGlassCompositingShared does)
        // must immediately unmount FireApp and cancel its 16ms periodic timer.
        runner.abort();
        runner.dispose();

        expect(async.periodicTimerCount, equals(0));
      });
    },
  );
}
