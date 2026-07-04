import 'dart:async';
import 'dart:io';
import 'package:pty2/pty.dart';
import 'package:pty2/src/impl/windows.dart' if (dart.library.html) '';

void main() async {
  final execName = Platform.isWindows ? 'echo_server.exe' : 'echo_server';
  final execFile = File('benchmark/$execName');

  if (!execFile.existsSync()) {
    stdout.writeln('Please compile echo_server.dart to $execName first.');
    exit(1);
  }

  const chunkSize = 4096;
  final chunk = 'a' * chunkSize;

  Future<double> runBenchmark(int durationSeconds, bool legacy) async {
    if (Platform.isWindows) {
      PtyCoreWindows.forceLegacyForTesting = legacy;
    }
    final pty = PseudoTerminal.start(execFile.absolute.path, [], raw: true);

    int receivedBytes = 0;
    pty.out.listen((data) {
      receivedBytes += data.length;
    });

    final stopwatch = Stopwatch()..start();
    bool running = true;

    // Stop writing after durationSeconds
    Timer(Duration(seconds: durationSeconds), () {
      running = false;
    });

    while (running) {
      pty.write(chunk);
      await Future.delayed(Duration.zero);
    }

    // Give it a tiny bit of time to flush the final buffers
    await Future.delayed(const Duration(milliseconds: 200));

    stopwatch.stop();
    pty.kill();
    await pty.exitCode;

    if (Platform.isWindows) {
      PtyCoreWindows.forceLegacyForTesting = false;
    }

    final bytesPerSec =
        receivedBytes / (stopwatch.elapsedMicroseconds / 1000000);
    return bytesPerSec / (1024 * 1024); // MB/s
  }

  stdout.writeln('Warming up JIT... (2 seconds)');
  await runBenchmark(2, false);

  final configs = [(name: 'ConPTY', legacy: false)];
  if (Platform.isWindows) {
    configs.add((name: 'Legacy Pipes', legacy: true));
  }

  stdout.writeln('\n--- Benchmark Results (5 Second Run) ---');
  for (final config in configs) {
    final speed = await runBenchmark(5, config.legacy);
    stdout.writeln('${config.name} : ${speed.toStringAsFixed(2)} MB/s');
  }
}
