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
      Platform.isWindows ? 'pwsh.exe' : 'bash',
      Platform.isWindows ? ['-C', 'ping 127.0.0.1 -t'] : ['-c', 'btop'],
      environment: {...Platform.environment},
    );
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
