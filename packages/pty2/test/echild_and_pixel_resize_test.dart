@Timeout(Duration(seconds: 45))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:pty2/pty2.dart';
import 'package:pty2/src/impl/unix.dart';
import 'package:test/test.dart';

String _writeWinsizeHelper(Directory dir) {
  final helper = File('${dir.path}/winsize_helper.dart');
  helper.writeAsStringSync('''
import 'dart:ffi';
import 'dart:io';

final class _Winsize extends Struct {
  @Uint16()
  external int ws_row;
  @Uint16()
  external int ws_col;
  @Uint16()
  external int ws_xpixel;
  @Uint16()
  external int ws_ypixel;
}

typedef _IoctlNative =
    Int32 Function(Int32 fd, Uint64 request, VarArgs<(Pointer<Void>,)>);
typedef _IoctlDart = int Function(int fd, int request, Pointer<Void> arg);
typedef _CallocNative = Pointer<Void> Function(Size count, Size size);
typedef _CallocDart = Pointer<Void> Function(int count, int size);
typedef _FreeNative = Void Function(Pointer<Void> ptr);
typedef _FreeDart = void Function(Pointer<Void> ptr);

void main(List<String> args) async {
  final targetCols = int.parse(args[0]);
  final targetRows = int.parse(args[1]);
  final libc = DynamicLibrary.process();
  final ioctl = libc.lookupFunction<_IoctlNative, _IoctlDart>('ioctl');
  final calloc = libc.lookupFunction<_CallocNative, _CallocDart>('calloc');
  final free = libc.lookupFunction<_FreeNative, _FreeDart>('free');
  final tiocgwinsz = Platform.isMacOS ? 0x40087468 : 0x5413;
  print('READY');

  final sw = Stopwatch()..start();
  final wsPtr = calloc(1, sizeOf<_Winsize>()).cast<_Winsize>();
  try {
    while (sw.elapsedMilliseconds < 5000) {
      wsPtr.ref
        ..ws_row = 0
        ..ws_col = 0
        ..ws_xpixel = 0
        ..ws_ypixel = 0;
      if (ioctl(1, tiocgwinsz, wsPtr.cast()) == 0 &&
          wsPtr.ref.ws_col == targetCols &&
          wsPtr.ref.ws_row == targetRows) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    print(
      'WINSIZE:\${wsPtr.ref.ws_col}x\${wsPtr.ref.ws_row}:'
      '\${wsPtr.ref.ws_xpixel}x\${wsPtr.ref.ws_ypixel}',
    );
  } finally {
    free(wsPtr.cast());
  }
}
''');
  return helper.path;
}

Future<String> _runPixelResizeProbe({
  required int cols,
  required int rows,
  required int pixelWidth,
  required int pixelHeight,
}) async {
  final tempDir = Directory.systemTemp.createTempSync('pty2_pixel_winsz_');
  try {
    final helperPath = _writeWinsizeHelper(tempDir);
    final pty = PseudoTerminal.start(Platform.executable, [
      helperPath,
      '$cols',
      '$rows',
    ]);
    addTearDown(() => pty.kill(ProcessSignal.sigkill));

    final output = StringBuffer();
    final readyCompleter = Completer<void>();
    final doneCompleter = Completer<void>();

    final sub = pty.out.listen(
      (chunk) {
        output.write(chunk);
        if (output.toString().contains('READY') &&
            !readyCompleter.isCompleted) {
          readyCompleter.complete();
        }
      },
      onDone: () {
        if (!readyCompleter.isCompleted) readyCompleter.complete();
        if (!doneCompleter.isCompleted) doneCompleter.complete();
      },
    );
    addTearDown(sub.cancel);

    await readyCompleter.future.timeout(const Duration(seconds: 10));
    pty.resize(cols, rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight);

    await doneCompleter.future.timeout(const Duration(seconds: 10));
    expect(await pty.exitCode.timeout(const Duration(seconds: 5)), equals(0));
    await sub.cancel();
    return output.toString();
  } finally {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  }
}

Future<void> _runTrackedPtyAndAssertCode(int expectedCode) async {
  final pty = PseudoTerminal.start('/bin/sh', ['-c', 'exit $expectedCode']);
  addTearDown(() => pty.kill(ProcessSignal.sigkill));
  final drainFuture = pty.out.drain<void>();
  final code = await pty.exitCode.timeout(const Duration(seconds: 10));
  expect(code, equals(expectedCode));
  await drainFuture.timeout(const Duration(seconds: 5));
  expect(pty.kill(ProcessSignal.sigkill), isFalse);
}

Future<void> _runProcessBatch(int count) async {
  final results = await Future.wait([
    for (var i = 0; i < count; i++)
      Process.run('/bin/sh', [
        '-c',
        'echo ok_$i',
      ]).timeout(const Duration(seconds: 5)),
  ]);
  for (var i = 0; i < count; i++) {
    expect(results[i].exitCode, equals(0));
    expect(results[i].stdout, equals('ok_$i\n'));
  }
}

Future<void> _verifyConcurrentPipeDrain(int count) async {
  for (var i = 0; i < count; i++) {
    final pty = PseudoTerminal.start('/bin/sh', ['-c', 'echo done; exit 9']);
    addTearDown(() => pty.kill(ProcessSignal.sigkill));
    final proc = await Process.start('/bin/sh', ['-c', 'echo pipe_$i']);
    final procOut = await proc.stdout
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 5));
    expect(procOut, equals('pipe_$i\n'));
    expect(await proc.exitCode.timeout(const Duration(seconds: 5)), equals(0));
    expect(await pty.exitCode.timeout(const Duration(seconds: 5)), equals(9));
    await pty.out.drain<void>().timeout(const Duration(seconds: 5));
  }
}

Future<void> _testConcurrentPtyAndProcessRun() async {
  final openPtys = <PseudoTerminal>[];
  addTearDown(() {
    for (final pty in openPtys) {
      pty.kill(ProcessSignal.sigkill);
    }
  });

  for (var i = 0; i < 3; i++) {
    final sleeper = PseudoTerminal.start('/bin/sh', [
      '-c',
      'read line; exit 0',
    ]);
    openPtys.add(sleeper);
    unawaited(sleeper.out.drain<void>());
  }

  const expectedCodes = [0, 7, 42, 13, 3, 19];
  for (var round = 0; round < 4; round++) {
    await Future.wait([
      for (final code in expectedCodes) _runTrackedPtyAndAssertCode(code),
      _runProcessBatch(6),
    ]);
  }

  await _verifyConcurrentPipeDrain(6);

  for (final sleeper in openPtys) {
    sleeper.write('\n');
    expect(
      await sleeper.exitCode.timeout(const Duration(seconds: 5)),
      equals(0),
    );
  }
}

Future<void> _testKillAfterNaturalExit() async {
  final core = PtyCoreUnix.start('/bin/sh', ['-c', 'exit 42']);
  addTearDown(() => core.kill(ProcessSignal.sigkill));

  final deadline = DateTime.now().add(const Duration(seconds: 5));
  int? nonBlocking;
  while (nonBlocking == null && DateTime.now().isBefore(deadline)) {
    nonBlocking = core.exitCodeNonBlocking();
    if (nonBlocking == null) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  expect(nonBlocking, equals(42));
  expect(core.exitCodeBlocking(), equals(42));
  expect(core.exitCodeNonBlocking(), equals(42));
  expect(core.kill(ProcessSignal.sigkill), isFalse);
  expect(core.kill(ProcessSignal.sigterm), isFalse);
  core.onReaderClosed();
  core.worker.free();
}

Future<void> _testKillWhileBlockingExit() async {
  final pty = PseudoTerminal.start('/bin/sh', ['-c', 'sleep 30']);
  addTearDown(() => pty.kill(ProcessSignal.sigkill));
  unawaited(pty.out.drain<void>());

  await Future<void>.delayed(const Duration(milliseconds: 50));
  expect(pty.kill(ProcessSignal.sigkill), isTrue);

  final code = await pty.exitCode.timeout(const Duration(seconds: 5));
  expect(code, equals(137));
  expect(pty.kill(ProcessSignal.sigkill), isFalse);
}

Future<void> _testDrainsTrailingPollinBytes() async {
  const lineCount = 500;
  final pty = PseudoTerminal.start('/bin/sh', [
    '-c',
    'i=1; while [ \$i -le $lineCount ]; do echo "LINE_\$i"; i=\$((i+1)); done; exit 5',
  ]);
  addTearDown(() => pty.kill(ProcessSignal.sigkill));

  final output = await pty.out.join().timeout(const Duration(seconds: 10));
  final code = await pty.exitCode.timeout(const Duration(seconds: 5));
  expect(code, equals(5));
  expect(output, contains('LINE_1'));
  expect(output, contains('LINE_$lineCount'));
}

Future<void> _testPixelResizeReportsValues() async {
  final output = await _runPixelResizeProbe(
    cols: 132,
    rows: 43,
    pixelWidth: 1584,
    pixelHeight: 860,
  );
  expect(output, contains('WINSIZE:132x43:1584x860'));
}

Future<void> _testPixelResizeClampsBounds() async {
  final upper = await _runPixelResizeProbe(
    cols: 100,
    rows: 30,
    pixelWidth: 70000,
    pixelHeight: 65536,
  );
  expect(upper, contains('WINSIZE:100x30:65535x65535'));

  final lower = await _runPixelResizeProbe(
    cols: 101,
    rows: 31,
    pixelWidth: -5,
    pixelHeight: -10,
  );
  expect(lower, contains('WINSIZE:101x31:0x0'));
}

Future<void> _testResizeAcceptsOptionalPixels() async {
  final pty = PseudoTerminal.start(
    Platform.isWindows ? 'cmd.exe' : '/bin/sh',
    Platform.isWindows ? ['/c', 'exit 0'] : ['-c', 'exit 0'],
  );
  addTearDown(() => pty.kill(ProcessSignal.sigkill));
  pty.resize(80, 24, pixelWidth: 640, pixelHeight: 480);
  await pty.exitCode.timeout(const Duration(seconds: 5));
  await pty.out.drain<void>().timeout(const Duration(seconds: 5));
}

Future<void> _testReaperShimSurvivesSignalsAndSeparatePgid() async {
  final pty = PseudoTerminal.start('/bin/sh', [
    '-c',
    'echo "SHIM_PID:\$(ps -o ppid= -p \$\$)"; read line; exit 42',
  ]);
  addTearDown(() => pty.kill(ProcessSignal.sigkill));

  final output = StringBuffer();
  final shimCompleter = Completer<int>();
  final doneCompleter = Completer<void>();
  final sub = pty.out.listen(
    (chunk) {
      output.write(chunk);
      final match = RegExp(r'SHIM_PID:\s*(\d+)').firstMatch(output.toString());
      if (match != null && !shimCompleter.isCompleted) {
        shimCompleter.complete(int.parse(match.group(1)!));
      }
    },
    onDone: () {
      if (!doneCompleter.isCompleted) doneCompleter.complete();
    },
  );
  addTearDown(sub.cancel);

  final shimPid = await shimCompleter.future.timeout(
    const Duration(seconds: 5),
  );
  expect(shimPid, greaterThan(1));
  expect(shimPid, isNot(equals(pid)));

  final shimPgidResult = await Process.run('ps', [
    '-o',
    'pgid=',
    '-p',
    '$shimPid',
  ]).timeout(const Duration(seconds: 5));
  final hostPgidResult = await Process.run('ps', [
    '-o',
    'pgid=',
    '-p',
    '$pid',
  ]).timeout(const Duration(seconds: 5));
  final shimPgid = int.parse((shimPgidResult.stdout as String).trim());
  final hostPgid = int.parse((hostPgidResult.stdout as String).trim());
  expect(shimPgid, equals(shimPid));
  expect(shimPgid, isNot(equals(hostPgid)));

  expect(Process.killPid(shimPid, ProcessSignal.sigint), isTrue);
  expect(Process.killPid(shimPid, ProcessSignal.sighup), isTrue);
  await Future<void>.delayed(const Duration(milliseconds: 50));

  pty.write('go\n');
  final code = await pty.exitCode.timeout(const Duration(seconds: 5));
  expect(code, equals(42));
  await doneCompleter.future.timeout(const Duration(seconds: 5));
  await sub.cancel();
}

Future<void> _testCancellingOutBeforeEofExitsDartVm() async {
  final tempDir = Directory.systemTemp.createTempSync('pty2_cancel_exit_');
  addTearDown(() => tempDir.deleteSync(recursive: true));

  final pkgConfig = (await Isolate.packageConfig)?.toFilePath();
  final driver = File('${tempDir.path}/cancel_exit_driver.dart');
  driver.writeAsStringSync('''
import 'dart:async';
import 'dart:io';

import 'package:pty2/pty2.dart';

Future<void> main() async {
  final pty = PseudoTerminal.start(
    '/bin/sh',
    const ['-c', 'trap "" TERM; printf "HELLO\\n"; sleep 30'],
    ackProcessed: true,
  );
  final sawHello = Completer<void>();
  late StreamSubscription<String> sub;
  sub = pty.out.listen((chunk) {
    if (chunk.contains('HELLO') && !sawHello.isCompleted) {
      sawHello.complete();
    }
    pty.ackProcessed();
  });
  await sawHello.future.timeout(const Duration(seconds: 5));
  await sub.cancel();
  pty.kill(ProcessSignal.sigkill);
  await pty.exitCode.timeout(const Duration(seconds: 5));
}
''');

  final result = await Process.run(Platform.resolvedExecutable, [
    'run',
    if (pkgConfig != null) '--packages=$pkgConfig',
    driver.path,
  ]).timeout(const Duration(seconds: 15));

  expect(result.exitCode, equals(0), reason: '${result.stderr}');
}

void main() {
  test(
    'concurrent PseudoTerminal.start + Process.run returns exact exit codes '
    'and never hangs pipes while multiple PTYs stay open',
    _testConcurrentPtyAndProcessRun,
    testOn: 'posix',
  );

  test(
    'kill(SIGKILL) after natural exit is a safe no-op and '
    'exitCodeNonBlocking matches exitCodeBlocking',
    _testKillAfterNaturalExit,
    testOn: 'posix',
  );

  test(
    'kill() does not deadlock while exitCodeBlocking() waits on running shell',
    _testKillWhileBlockingExit,
    testOn: 'posix',
  );

  test(
    'drains trailing POLLIN output from fast-exiting process without truncation',
    _testDrainsTrailingPollinBytes,
    testOn: 'posix',
  );

  test(
    'TIOCGWINSZ reports pixelWidth and pixelHeight set via resize',
    _testPixelResizeReportsValues,
    testOn: 'posix',
  );

  test(
    'TIOCGWINSZ clamps pixelWidth and pixelHeight to uint16 bounds',
    _testPixelResizeClampsBounds,
    testOn: 'posix',
  );

  test(
    'PseudoTerminal.resize accepts optional pixelWidth and pixelHeight',
    _testResizeAcceptsOptionalPixels,
  );

  test(
    'reaper shim isolates pgid/signals and reports child exit code after SIGINT/SIGHUP',
    _testReaperShimSurvivesSignalsAndSeparatePgid,
    testOn: 'posix',
  );

  test(
    'cancelling out before EOF drains BlockingPseudoTerminal isolates so Dart VM exits',
    _testCancellingOutBeforeEofExitsDartVm,
    testOn: 'posix',
  );
}
