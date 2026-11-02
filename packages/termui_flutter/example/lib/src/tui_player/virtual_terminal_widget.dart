import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';

/// A termui [StatelessWidget] that renders cells from a [VirtualTerminal] via [TerminalView].
final class VirtualTerminalWidget extends StatelessWidget {
  /// The virtual terminal instance containing the buffer to render.
  final VirtualTerminal virtualTerminal;

  /// Creates a [VirtualTerminalWidget].
  const VirtualTerminalWidget({super.key, required this.virtualTerminal});

  @override
  Widget build(BuildContext context) {
    return TerminalView(terminal: virtualTerminal, autofocus: false);
  }
}
