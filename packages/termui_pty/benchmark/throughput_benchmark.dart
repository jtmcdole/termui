import 'package:benchmark_harness/benchmark_harness.dart';
import 'package:termui_pty/src/virtual_terminal.dart';

class ThroughputBenchmark extends BenchmarkBase {
  late VirtualTerminal terminal;
  late List<int> payload;

  ThroughputBenchmark() : super('ThroughputBenchmark');

  @override
  void setup() {
    terminal = VirtualTerminal(width: 80, height: 24);

    // Create a 1MB payload of 'top' like output
    final sb = StringBuffer();
    for (var i = 0; i < 1000; i++) {
      sb.write('\x1b[2J\x1b[1;1H');
      sb.write('\x1b[31mTop process 1\x1b[0m\n');
      sb.write('\x1b[32mTop process 2\x1b[0m\n');
      sb.write('\x1b[44mMemory usage: 50%\x1b[0m\n');
      for (var j = 0; j < 20; j++) {
        sb.write('Some random text to fill the buffer...\n');
      }
    }
    payload = sb.toString().codeUnits;
  }

  @override
  void run() {
    terminal.write(payload);
  }

  @override
  void teardown() {
    // Teardown
  }
}

void main() {
  ThroughputBenchmark().report();
}
