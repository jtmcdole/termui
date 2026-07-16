import 'dart:io';

void main() async {
  if (!stdout.hasTerminal) {
    print('NO_TERMINAL');
    return;
  }

  // Poll up to 5 seconds for the parent process's pty.resize(123, 45) to take effect
  // inside the ConPTY / PTY child console buffer, ensuring 100% determinism on slow CI virtual machines.
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsedMilliseconds < 5000) {
    if (stdout.terminalColumns == 123 && stdout.terminalLines == 45) {
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  print('SIZE:${stdout.terminalColumns}x${stdout.terminalLines}');
}
