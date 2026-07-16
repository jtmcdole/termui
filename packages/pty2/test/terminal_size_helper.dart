import 'dart:io';

void main() async {
  // Give the master PTY a brief moment to issue the resize ioctl/ConPTY resize
  // right after spawning.
  await Future<void>.delayed(const Duration(milliseconds: 200));
  if (stdout.hasTerminal) {
    print('SIZE:${stdout.terminalColumns}x${stdout.terminalLines}');
  } else {
    print('NO_TERMINAL');
  }
}
