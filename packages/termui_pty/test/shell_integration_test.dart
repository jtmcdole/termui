import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

void main() {
  group(
    'VirtualTerminal OSC 7 working directory and OSC 133 shell integration',
    () {
      test(
        'OSC 7 parses file:// URI and percent-decodes working directory',
        () {
          final dirs = <String>[];
          final vt = VirtualTerminal(width: 20, height: 5)
            ..onWorkingDirectoryChanged = dirs.add;

          vt.writeString('\x1b]7;file://localhost/home/user/my%20project\x07');
          expect(vt.workingDirectory, equals('/home/user/my project'));
          expect(dirs, equals(['/home/user/my project']));

          vt.writeString('\x1b]7;/tmp/work\x1b\\');
          expect(vt.workingDirectory, equals('/tmp/work'));
          expect(dirs, equals(['/home/user/my project', '/tmp/work']));
        },
      );

      test(
        'OSC 133 tracks prompt, command input, command output, and exit code',
        () {
          final events = <(ShellPromptZone, int?)>[];
          final vt = VirtualTerminal(width: 20, height: 5)
            ..onShellIntegration = (zone, {exitCode}) {
              events.add((zone, exitCode));
            };

          expect(vt.promptZone, equals(ShellPromptZone.none));
          expect(vt.lastCommandExitCode, isNull);

          vt.writeString('\x1b]133;A;aid=1\x07');
          expect(vt.promptZone, equals(ShellPromptZone.prompt));

          vt.writeString('\x1b]133;B\x07');
          expect(vt.promptZone, equals(ShellPromptZone.commandInput));

          vt.writeString('\x1b]133;C\x07');
          expect(vt.promptZone, equals(ShellPromptZone.commandOutput));

          vt.writeString('\x1b]133;D;42;err=1\x07');
          expect(vt.promptZone, equals(ShellPromptZone.none));
          expect(vt.lastCommandExitCode, equals(42));

          expect(
            events,
            equals([
              (ShellPromptZone.prompt, null),
              (ShellPromptZone.commandInput, null),
              (ShellPromptZone.commandOutput, null),
              (ShellPromptZone.none, 42),
            ]),
          );
        },
      );
    },
  );
}
