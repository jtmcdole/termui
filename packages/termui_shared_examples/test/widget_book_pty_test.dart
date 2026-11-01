@TestOn('vm')
@Timeout(Duration(seconds: 45))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:pty2/pty2.dart';
import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

String _readRow(Buffer buffer, int y) => [
  for (var x = 0; x < buffer.width; x++) buffer.getCharacter(x, y),
].join().trimRight();

Future<void> _waitForCondition(
  VirtualTerminal vt,
  bool Function() predicate, {
  required Duration timeout,
  required String Function() reason,
}) async {
  if (predicate()) return;
  final completer = Completer<void>();
  void onUpdate() {
    if (!completer.isCompleted && predicate()) {
      completer.complete();
    }
  }

  vt.addListener(onUpdate);
  try {
    await completer.future.timeout(
      timeout,
      onTimeout: () => fail('Timed out after $timeout: ${reason()}'),
    );
  } finally {
    vt.removeListener(onUpdate);
  }
}

void main() {
  test('CLI widget_book navigates sidebar menu on SGR mouse clicks '
      'and exits on q over a real PTY', () async {
    final runnerUri = Isolate.resolvePackageUriSync(
      Uri.parse(
        'package:termui_shared_examples/widget_book/widget_book_runner.dart',
      ),
    );
    expect(runnerUri, isNotNull);
    final packageDir = Directory.fromUri(
      runnerUri!.resolve('../../'),
    ).absolute.path;
    final scriptPath = File.fromUri(
      runnerUri.resolve('../../example/widget_book.dart'),
    ).absolute.path;

    final vt = VirtualTerminal(width: 120, height: 40);
    final outDone = Completer<void>();
    final pty = PseudoTerminal.start(
      Platform.resolvedExecutable,
      [scriptPath],
      workingDirectory: packageDir,
      environment: {...Platform.environment, 'TERM': 'xterm-256color'},
    );
    StreamSubscription<String>? outSub;
    var exited = false;

    try {
      pty.resize(120, 40);
      outSub = pty.out.listen(
        (chunk) => vt.write(utf8.encode(chunk)),
        onDone: () {
          if (!outDone.isCompleted) outDone.complete();
        },
      );

      await _waitForCondition(
        vt,
        () =>
            vt.isUsingAlternateScreen &&
            vt.mouseTrackingEnabled &&
            vt.sgrMouseMode &&
            _readRow(vt.buffer, 1).contains('Text Inputs Preview') &&
            _readRow(vt.buffer, 3).startsWith('Data Displays'),
        timeout: const Duration(seconds: 20),
        reason: () =>
            'Initial WidgetBook frame never became interactive '
            '(row 1: "${_readRow(vt.buffer, 1)}")',
      );

      // Click sidebar item 1 ("Data Displays", 0-based y=3 -> 1-based row 4)
      // with no CR/LF; raw mode must deliver SGR mouse bytes immediately.
      pty.write('\x1b[<0;5;4M\x1b[<0;5;4m');

      await _waitForCondition(
        vt,
        () =>
            _readRow(vt.buffer, 1).contains('Data Displays Preview') &&
            Color.argb(vt.buffer.getBackground(0, 3)) == CharmColors.charple,
        timeout: const Duration(seconds: 5),
        reason: () =>
            'Sidebar SGR click on "Data Displays" was not processed '
            '(row 1: "${_readRow(vt.buffer, 1)}")',
      );

      // Send a 63-byte SGR mouse-move prefix (3 * 11 + 3 * 10) before clicking
      // item 6 ("Charm Colors", 0-based y=8 -> 1-based row 9) so record 64
      // (or 128 with key-ups) lands on the leading ESC of '\x1b[<0;5;9M'.
      final moveBurst = '${'\x1b[<35;15;2M' * 3}${'\x1b[<35;5;2M' * 3}';
      pty.write('$moveBurst\x1b[<0;5;9M\x1b[<0;5;9m');

      await _waitForCondition(
        vt,
        () =>
            _readRow(vt.buffer, 1).contains('Charm Colors Preview') &&
            Color.argb(vt.buffer.getBackground(0, 8)) == CharmColors.charple,
        timeout: const Duration(seconds: 5),
        reason: () =>
            'Sidebar SGR click on "Charm Colors" was not processed '
            '(row 1: "${_readRow(vt.buffer, 1)}")',
      );

      // Press 'q' with no CR/LF and verify clean exit and terminal teardown.
      pty.write('q');

      final exitCode = await pty.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () =>
            fail('widget_book process did not exit after pressing q'),
      );
      exited = true;
      await outDone.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () =>
            fail('PTY output stream did not close after widget_book exited'),
      );
      expect(exitCode, Platform.isWindows ? equals(0) : anyOf(0, -1));
      expect(vt.isUsingAlternateScreen, isFalse);
      expect(vt.mouseTrackingEnabled, isFalse);
    } finally {
      if (!exited) {
        pty.kill(ProcessSignal.sigkill);
        await pty.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () => -1,
        );
      }
      if (!outDone.isCompleted) {
        await outDone.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
      }
      await outSub?.cancel();
      vt.dispose();
    }
  });
}
