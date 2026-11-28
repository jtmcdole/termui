@Timeout(Duration(seconds: 45))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:pty2/pty2.dart';
import 'package:test/test.dart';

void _safeDeleteDir(Directory dir) {
  try {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  } on FileSystemException {
    // Ignore transient Windows file lock during teardown.
  }
}

Future<({int exitCode, String stdout, String stderr, bool timedOut})>
_runDriverScript(
  Directory tempDir,
  String filename,
  String source, {
  Duration timeout = const Duration(seconds: 12),
}) async {
  final pkgConfig = (await Isolate.packageConfig)?.toFilePath();
  final driver = File('${tempDir.path}/$filename')..writeAsStringSync(source);
  final proc = await Process.start(Platform.resolvedExecutable, [
    'run',
    if (pkgConfig != null) '--packages=$pkgConfig',
    driver.path,
  ]);

  final outBuf = StringBuffer();
  final errBuf = StringBuffer();
  final outSub = proc.stdout.transform(utf8.decoder).listen(outBuf.write);
  final errSub = proc.stderr.transform(utf8.decoder).listen(errBuf.write);

  var timedOut = false;
  final exitCode = await proc.exitCode.timeout(
    timeout,
    onTimeout: () {
      timedOut = true;
      proc.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
  await outSub.cancel();
  await errSub.cancel();
  return (
    exitCode: exitCode,
    stdout: outBuf.toString(),
    stderr: errBuf.toString(),
    timedOut: timedOut,
  );
}

void main() {
  test(
    'ackProcessed bidirectional burst does not deadlock when writing inside onData',
    () async {
      final tempDir = Directory.systemTemp.createTempSync('pty2_write_dl_');
      addTearDown(() => _safeDeleteDir(tempDir));

      final childFile = File('${tempDir.path}/burst_child.dart')
        ..writeAsStringSync(r'''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  try {
    stdin.echoMode = false;
    stdin.lineMode = false;
  } on StdinException {
    // Non-TTY fallback.
  }

  // Emit a START marker plus 128 KiB of APC passthrough sequences BEFORE
  // reading a single byte from stdin. ConPTY forwards APC sequences verbatim
  // (unlike plain scrolling text which gets coalesced to an 80x25 grid),
  // saturating the ConPTY output pipe while the parent awaits ackProcessed.
  final apcPayload = '\x1b_Gi=901,a=q;${'A' * 1000}\x1b\\';
  final burst = StringBuffer('BURST_START\n');
  for (var i = 0; i < 128; i++) {
    burst.write(apcPayload);
  }
  stdout.write(burst.toString());
  await stdout.flush();

  // Now drain stdin until END_MARKER arrives.
  var totalBytes = 0;
  var tail = '';
  await for (final chunk in stdin) {
    totalBytes += chunk.length;
    tail += utf8.decode(chunk, allowMalformed: true);
    if (tail.contains('END_MARKER')) {
      break;
    }
    if (tail.length > 64) {
      tail = tail.substring(tail.length - 64);
    }
  }
  stdout.writeln('CHILD_DONE:$totalBytes');
  await stdout.flush();
}
''');

      final childPathLiteral = jsonEncode(childFile.path);
      final result = await _runDriverScript(tempDir, 'deadlock_driver.dart', '''
import 'dart:async';
import 'dart:io';

import 'package:pty2/pty2.dart';

Future<void> main() async {
  final pty = PseudoTerminal.start(
    Platform.resolvedExecutable,
    [$childPathLiteral],
    ackProcessed: true,
    raw: true,
  );

  var wroteBurst = false;
  final output = StringBuffer();
  final done = Completer<void>();
  // 128 KiB payload exceeds both 4 KiB default and 64 KiB pipe buffers.
  final payload = '\${'X' * (128 * 1024)}END_MARKER\\n';

  final sub = pty.out.listen(
    (chunk) {
      output.write(chunk);
      if (!wroteBurst && output.toString().contains('BURST_START')) {
        wroteBurst = true;
        final sw = Stopwatch()..start();
        pty.write(payload);
        sw.stop();
        stdout.writeln('WRITE_MS:\${sw.elapsedMilliseconds}');
      }
      Timer.run(pty.ackProcessed);
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );

  await done.future;
  final code = await pty.exitCode;
  await sub.cancel();

  final text = output.toString();
  final match = RegExp(r'CHILD_DONE:(\\d+)').firstMatch(text);
  stdout.writeln('EXIT:\$code');
  stdout.writeln('MATCH:\${match?.group(1) ?? "NONE"}');
}
''', timeout: const Duration(seconds: 10));

      expect(
        result.timedOut,
        isFalse,
        reason:
            'Driver deadlocked during bidirectional burst!\n'
            'stdout: ${result.stdout}\nstderr: ${result.stderr}',
      );
      expect(
        result.exitCode,
        equals(0),
        reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
      );
      expect(result.stdout, contains('EXIT:0'));

      final match = RegExp(r'MATCH:(\d+)').firstMatch(result.stdout);
      expect(match, isNotNull, reason: 'stdout: ${result.stdout}');
      final receivedBytes = int.parse(match!.group(1)!);
      expect(receivedBytes, greaterThanOrEqualTo(128 * 1024));

      final writeMsMatch = RegExp(r'WRITE_MS:(\d+)').firstMatch(result.stdout);
      expect(writeMsMatch, isNotNull, reason: 'stdout: ${result.stdout}');
      final writeMs = int.parse(writeMsMatch!.group(1)!);
      expect(
        writeMs,
        lessThan(500),
        reason: 'pty.write() blocked main isolate for ${writeMs}ms',
      );
    },
  );

  test(
    'kill() unblocks cleanly when writer is backpressured on a full input pipe',
    () async {
      final tempDir = Directory.systemTemp.createTempSync('pty2_write_kill_');
      addTearDown(() => _safeDeleteDir(tempDir));

      final childFile = File('${tempDir.path}/sleep_child.dart')
        ..writeAsStringSync('''
import 'dart:io';

Future<void> main() async {
  stdout.writeln('SLEEPING');
  await stdout.flush();
  await Future<void>.delayed(const Duration(seconds: 30));
}
''');

      final childPathLiteral = jsonEncode(childFile.path);
      final result = await _runDriverScript(
        tempDir,
        'kill_backpressured_driver.dart',
        '''
import 'dart:async';
import 'dart:io';

import 'package:pty2/pty2.dart';

Future<void> main() async {
  final pty = PseudoTerminal.start(
    Platform.resolvedExecutable,
    [$childPathLiteral],
    ackProcessed: true,
    raw: true,
  );
  final sawSleeping = Completer<void>();
  final sub = pty.out.listen((chunk) {
    if (chunk.contains('SLEEPING') && !sawSleeping.isCompleted) {
      sawSleeping.complete();
    }
    Timer.run(pty.ackProcessed);
  });

  await sawSleeping.future.timeout(const Duration(seconds: 5));

  // Flood input pipe while child is sleeping and never reads stdin.
  final sw = Stopwatch()..start();
  pty.write('Z' * (256 * 1024));
  sw.stop();
  stdout.writeln('WRITE_MS:\${sw.elapsedMilliseconds}');

  // Give writer isolate a moment to enter blocking write syscall, then kill.
  await Future<void>.delayed(const Duration(milliseconds: 50));
  pty.kill(ProcessSignal.sigkill);
  await pty.exitCode.timeout(const Duration(seconds: 5));
  await sub.cancel();
  stdout.writeln('CLEAN_EXIT');
}
''',
        timeout: const Duration(seconds: 10),
      );

      expect(
        result.timedOut,
        isFalse,
        reason:
            'Driver hung during kill() with backpressured writer!\n'
            'stdout: ${result.stdout}\nstderr: ${result.stderr}',
      );
      expect(
        result.exitCode,
        equals(0),
        reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
      );
      expect(result.stdout, contains('CLEAN_EXIT'));
    },
  );

  test('sequential writes preserve exact byte ordering off-thread', () async {
    final tempDir = Directory.systemTemp.createTempSync('pty2_write_order_');
    addTearDown(() => _safeDeleteDir(tempDir));

    final childFile = File('${tempDir.path}/order_child.dart')
      ..writeAsStringSync(r'''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  try {
    stdin.echoMode = false;
    stdin.lineMode = false;
  } on StdinException {
    // Non-TTY fallback.
  }
  stdout.writeln('READY');
  await stdout.flush();

  final buf = StringBuffer();
  await for (final chunk in stdin) {
    buf.write(utf8.decode(chunk, allowMalformed: true));
    if (buf.toString().contains('FIN')) break;
  }
  final received = buf.toString();
  final tokens = RegExp(r'T\d+').allMatches(received).map((m) => m.group(0)!).toList();
  var ordered = tokens.length == 200;
  for (var i = 0; ordered && i < 200; i++) {
    if (tokens[i] != 'T$i') ordered = false;
  }
  stdout.writeln('ORDERED:$ordered:${tokens.length}');
  await stdout.flush();
}
''');

    final pty = PseudoTerminal.start(
      Platform.resolvedExecutable,
      [childFile.path],
      ackProcessed: true,
      raw: true,
    );
    addTearDown(() => pty.kill(ProcessSignal.sigkill));

    final ready = Completer<void>();
    final output = StringBuffer();
    final done = Completer<void>();
    final sub = pty.out.listen(
      (chunk) {
        output.write(chunk);
        if (output.toString().contains('READY') && !ready.isCompleted) {
          ready.complete();
        }
        Timer.run(pty.ackProcessed);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    addTearDown(sub.cancel);

    await ready.future.timeout(const Duration(seconds: 10));
    for (var i = 0; i < 200; i++) {
      pty.write('T$i ');
    }
    pty.write('FIN\n');

    await done.future.timeout(const Duration(seconds: 10));
    await pty.exitCode.timeout(const Duration(seconds: 5));
    expect(output.toString(), contains('ORDERED:true:200'));
  });
}
