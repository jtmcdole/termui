@TestOn('vm')
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math';

import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:termui/termui.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_recorder/termui_recorder.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

String _goldenPath(String filename) {
  final libUri = Isolate.resolvePackageUriSync(
    Uri.parse('package:termui_cast_client_core/termui_cast_client_core.dart'),
  );
  if (libUri == null) {
    throw StateError('Unable to resolve package:termui_cast_client_core URI.');
  }
  final pkgRoot = p.dirname(p.dirname(p.fromUri(libUri)));
  return p.join(pkgRoot, 'test', 'goldens', filename);
}

void main() {
  const activeAccentArgb = 0xFF62D196; // Color(98, 209, 150)

  group('ConnectionPromptDialog', () {
    setUp(() {
      FocusManager.instance.setPrimaryFocus(null);
    });

    test(
      'traverses Server URL -> Bearer Token -> Connect button via Tab, validates URL inline, and matches ANSI golden',
      () {
        final tester = TerminalTester(size: const Point(80, 24));
        tester.run(() async {
          final sceneManager = SceneManager(
            tester.terminal,
            renderingMode: .alternateScreen,
          )..enableMouseTracking = true;

          CastEndpoint? submitted;
          unawaited(
            ConnectionPromptDialog.show(
              sceneManager,
              initialServerUrl: 'http://bad-scheme',
            ).then((value) => submitted = value),
          );

          await tester.pump(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 20));

          // 1. Pressing Enter with invalid scheme shows inline validation error and keeps modal open.
          tester.sendKey(LogicalKey.enter);
          await tester.pump(const Duration(milliseconds: 20));
          check(submitted).isNull();
          expect(
            tester.backend.buffer,
            matchesAnsiGolden(_goldenPath('connection_prompt_invalid.ansi')),
          );

          // 2. Replace invalid URL with valid wss:// URL, Tab into Bearer Token field, type token, and press Enter.
          for (var i = 0; i < 'http://bad-scheme'.length; i++) {
            tester.sendKey(LogicalKey.backspace);
          }
          tester.sendString('wss://cast.example:8420/v1/client');
          tester.sendKey(LogicalKey.tab);
          await tester.pump(const Duration(milliseconds: 20));
          tester.sendString('my-secret-token');
          tester.sendKey(LogicalKey.tab);
          await tester.pump(const Duration(milliseconds: 20));

          expect(
            tester.backend.buffer,
            matchesAnsiGolden(
              _goldenPath('connection_prompt_focused_btn.ansi'),
            ),
          );

          tester.sendKey(LogicalKey.enter);
          await tester.pump(const Duration(milliseconds: 20));

          check(submitted).isNotNull();
          check(
            '${submitted!.serverUri}',
          ).equals('wss://cast.example:8420/v1/client');
          check(submitted!.token).equals('my-secret-token');

          sceneManager.dispose();
        });
      },
    );

    test(
      'clears initial server URL focus when clicking Bearer Token field directly with the mouse',
      () {
        final tester = TerminalTester(size: const Point(80, 24));
        tester.run(() async {
          final sceneManager = SceneManager(
            tester.terminal,
            renderingMode: .alternateScreen,
          )..enableMouseTracking = true;

          CastEndpoint? submitted;
          unawaited(
            ConnectionPromptDialog.show(
              sceneManager,
            ).then((value) => submitted = value),
          );

          await tester.pump(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 20));

          // Click directly on the Bearer Token TextField (1-based col 15, row 14 -> 0-based y=13).
          tester.mouseDown(15, 14);
          tester.mouseUp(15, 14);
          await tester.pump(const Duration(milliseconds: 20));

          // Server URL row (0-based y=9) must lose active cursor background,
          // and Bearer Token row (0-based y=13, first content cell x=12) must show active cursor.
          final dialogBuffer = tester.backend.buffer!;
          final serverHasCursor = [
            for (var x = 12; x < 68; x++) dialogBuffer.getBackground(x, 9),
          ].contains(activeAccentArgb);
          check(serverHasCursor).isFalse();
          check(dialogBuffer.getForeground(11, 13)).equals(activeAccentArgb);
          check(dialogBuffer.getBackground(12, 13)).equals(activeAccentArgb);
          check(
            dialogBuffer.getModifiers(12, 13) & Modifier.underline,
          ).not((it) => it.equals(0));

          tester.sendString('mouse-tok');
          tester.sendKey(LogicalKey.enter);
          await tester.pump(const Duration(milliseconds: 20));

          check(submitted).isNotNull();
          check('${submitted!.serverUri}').equals(defaultClientServerUrl);
          check(submitted!.token).equals('mouse-tok');

          sceneManager.dispose();
        });
      },
    );

    test(
      'renders active cursor and border affordance on Tab, masks bearer token in Buffer, and honors barrierDismissible',
      () {
        final tester = TerminalTester(size: const Point(80, 24));
        tester.run(() async {
          final sceneManager = SceneManager(
            tester.terminal,
            renderingMode: .alternateScreen,
          )..enableMouseTracking = true;

          var completed = false;
          CastEndpoint? result;
          unawaited(
            ConnectionPromptDialog.show(sceneManager).then((value) {
              completed = true;
              result = value;
            }),
          );

          await tester.pump(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 20));

          // Tab into empty Bearer Token field -> must highlight border (x=11, y=13) and cursor cell (x=12, y=13).
          tester.sendKey(LogicalKey.tab);
          await tester.pump(const Duration(milliseconds: 20));

          String extractScreenText(Buffer buf) {
            final sb = StringBuffer();
            for (var y = 0; y < buf.height; y++) {
              for (var x = 0; x < buf.width; x++) {
                sb.write(buf.getCharacter(x, y));
              }
              sb.writeln();
            }
            return '$sb';
          }

          final emptyBuf = tester.backend.buffer!;
          check(emptyBuf.getForeground(11, 13)).equals(activeAccentArgb);
          check(emptyBuf.getBackground(12, 13)).equals(activeAccentArgb);

          // Type secret token -> screen must show '******' with cursor at col 18 and NEVER leak 's3cr3t' to Buffer or Tracer!
          tester.sendString('s3cr3t');
          await tester.pump(const Duration(milliseconds: 20));

          final maskedBuf = tester.backend.buffer!;
          final maskedScreen = extractScreenText(maskedBuf);
          check(maskedScreen).contains('******');
          check(maskedScreen).not((it) => it.contains('s3cr3t'));
          check(maskedBuf.getBackground(12 + 6, 13)).equals(activeAccentArgb);

          // Click outside dialog at top-left dimming barrier (1, 1) -> dismisses with null!
          tester.mouseDown(1, 1);
          tester.mouseUp(1, 1);
          await tester.pump(const Duration(milliseconds: 20));

          check(completed).isTrue();
          check(result).isNull();

          // Re-open with initialError and dismiss via native SceneManager.showDialog Escape handling.
          var escDismissed = false;
          unawaited(
            ConnectionPromptDialog.show(
              sceneManager,
              initialError: 'Auth failed: Invalid bearer token',
            ).then((value) {
              escDismissed = value == null;
            }),
          );
          await tester.pump(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 20));
          check(
            extractScreenText(tester.backend.buffer!),
          ).contains('Auth failed: Invalid bearer token');

          tester.sendKey(LogicalKey.escape);
          await tester.pump(const Duration(milliseconds: 20));
          check(escDismissed).isTrue();

          // When barrierDismissible is false, Escape must NOT dismiss the dialog.
          var lockedCompleted = false;
          unawaited(
            ConnectionPromptDialog.show(
              sceneManager,
              barrierDismissible: false,
            ).then((_) => lockedCompleted = true),
          );
          await tester.pump(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 20));
          tester.sendKey(LogicalKey.escape);
          await tester.pump(const Duration(milliseconds: 20));
          check(lockedCompleted).isFalse();

          tester.sendKey(LogicalKey.enter);
          await tester.pump(const Duration(milliseconds: 20));
          check(lockedCompleted).isTrue();

          sceneManager.dispose();
        });
      },
    );
  });
}
