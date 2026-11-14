import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/fterm_app.dart';

import 'support/app_three_way_harness.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  testWidgets(
    'forwards Control+O across C0, CapsLock, and lowercase key shapes in KTTY and legacy PTYs and across CastApp remounts',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(640, 384));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final harness = AppThreeWayWsHarness();
      final pty = await tester.runAsync(
        () => harness.startCaster(id: 'jetski-pty', title: 'jetski'),
      );

      await tester.pumpWidget(
        FtermApp(
          key: const ValueKey('cast-1'),
          config: CastLaunchConfig(token: harness.token),
          channelFactory: harness.openClientChannel,
          resizeDebounce: Duration.zero,
        ),
      );
      await settleCastApp(tester);

      // 1. Enable Kitty Keyboard Protocol (`\x1b[=1;1u` + `\x1b[>3u`), matching jetski / BubbleTea v2.
      pty!.emitRawAnsi('\x1b[=1;1u\x1b[>3u');
      await settleCastApp(tester, cycles: 4);

      for (final ch in const ['\x0f', 'O', 'o']) {
        pty.writtenInputs.clear();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyO, character: ch);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await settleCastApp(tester, cycles: 3);

        final wire = [
          for (final chunk in pty.writtenInputs) utf8.decode(chunk),
        ].join();
        expect(wire, contains('\x1b[111;5u'));
        expect(wire, contains('\x1b[111;5:3u'));
        expect(wire, isNot(contains('\x1b[15;')));
        expect(wire, isNot(contains('\x1b[79;')));
      }

      // 2. Reset KTTY back to legacy mode (`\x1b[=0;1u`) and remount a fresh CastApp immediately
      //    while cast-1's async _runScene shutdown is still unwinding.
      pty.emitRawAnsi('\x1b[=0;1u');
      await settleCastApp(tester, cycles: 4);

      await tester.pumpWidget(
        FtermApp(
          key: const ValueKey('cast-2'),
          config: CastLaunchConfig(token: harness.token),
          channelFactory: harness.openClientChannel,
          resizeDebounce: Duration.zero,
        ),
      );
      await settleCastApp(tester);

      pty.writtenInputs.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyO, character: '\x0f');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settleCastApp(tester, cycles: 3);

      expect(pty.writtenInputs, isNotEmpty);
      expect(pty.writtenInputs.single, equals(const [0x0f]));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(harness.dispose);
    },
  );
}
