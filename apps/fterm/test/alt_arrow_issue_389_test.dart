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
    'encodes Alt+Up/Down/Right/Left as ESC[1;3A..D when kittyKeyboardFlags == 0 (altLeft, altRight, DECCKM, and ignores Meta)',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(640, 384));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final harness = AppThreeWayWsHarness();
      final pty = await tester.runAsync(
        () => harness.startCaster(id: 'tmux-pty', title: 'tmux'),
      );
      addTearDown(harness.dispose);

      try {
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(token: harness.token),
            channelFactory: harness.openClientChannel,
            resizeDebounce: Duration.zero,
          ),
        );
        await settleCastApp(tester);

        const arrows = [
          (LogicalKeyboardKey.arrowUp, '\x1b[1;3A'),
          (LogicalKeyboardKey.arrowDown, '\x1b[1;3B'),
          (LogicalKeyboardKey.arrowRight, '\x1b[1;3C'),
          (LogicalKeyboardKey.arrowLeft, '\x1b[1;3D'),
        ];

        // 1. Both altLeft and altRight + arrows with kittyKeyboardFlags == 0.
        for (final altKey in const [
          LogicalKeyboardKey.altLeft,
          LogicalKeyboardKey.altRight,
        ]) {
          pty!.writtenInputs.clear();
          await tester.sendKeyDownEvent(altKey);
          try {
            for (final (logical, _) in arrows) {
              await tester.sendKeyEvent(logical);
            }
          } finally {
            await tester.sendKeyUpEvent(altKey);
          }
          await settleCastApp(tester, cycles: 3);

          expect([
            for (final chunk in pty.writtenInputs) utf8.decode(chunk),
          ], equals([for (final (_, expected) in arrows) expected]));
        }

        // 2. Cmd/Meta + Arrow in legacy mode emits nothing to the PTY.
        pty!.writtenInputs.clear();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        try {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        } finally {
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        }
        await settleCastApp(tester, cycles: 2);
        expect(pty.writtenInputs, isEmpty);

        // 3. With DECCKM (?1h) active and kittyKeyboardFlags == 0, plain Up sends
        //    ESC O A while Alt+Up still sends ESC [ 1 ; 3 A.
        pty.emitRawAnsi('\x1b[?1h');
        await settleCastApp(tester, cycles: 3);
        pty.writtenInputs.clear();

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        try {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        } finally {
          await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        }
        await settleCastApp(tester, cycles: 3);

        expect([
          for (final chunk in pty.writtenInputs) utf8.decode(chunk),
        ], equals(const ['\x1bOA', '\x1b[1;3A']));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await settleCastApp(tester, cycles: 2);
      }
    },
  );
}
