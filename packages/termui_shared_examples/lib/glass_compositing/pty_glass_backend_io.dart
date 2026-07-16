import 'dart:io';
import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:pty2/pty2.dart';

/// An IO-based backend that spawns a real local process via [PseudoTerminal].
class PtyBackend {
  PseudoTerminal? _pty;

  /// Starts the process and returns a [PseudoTerminalView].
  Widget buildView(FocusNode focusNode) {
    _pty = PseudoTerminal.start(
      //      Platform.isWindows ? 'pwsh.exe' : '/opt/homebrew/bin/btop',
      //      Platform.isWindows
      //          ? ['-C', 'ping 127.0.0.1 -t']
      //          : [], // Empty array for Mac/Linux
      Platform.isWindows ? 'pwsh.exe' : 'zsh',
      Platform.isWindows
          ? ['-C', 'ping 127.0.0.1 -t']
          : ['-i', '-c', '/opt/homebrew/bin/btop'],
      environment: {...Platform.environment},
    );
    _pty!.resize(100, 30); // 100 columns, 30 rows

    return PseudoTerminalView(
      pty: _pty!,
      transparentBackground: true,
      defaultForeground: CharmColors.julep,
      focusNode: focusNode,
    );
  }

  /// Kills the running process.
  void kill() {
    _pty?.kill();
  }
}
