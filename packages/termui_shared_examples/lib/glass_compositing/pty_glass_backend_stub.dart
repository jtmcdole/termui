import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';

/// A stub backend for rendering a PTY-like interface on the web using a VirtualTerminal.
final class PtyBackend {
  VirtualTerminal? _terminal;
  Timer? _timer;

  /// Builds a widget that renders the terminal state.
  Widget buildView(FocusNode focusNode) {
    _terminal = VirtualTerminal(
      width: 80,
      height: 24,
      transparentBackground: true,
      defaultForeground: CharmColors.julep,
    );

    final random = Random();
    final colors = [
      CharmColors.julep,
      CharmColors.charple,
      CharmColors.malibu,
      CharmColors.mustard,
      CharmColors.flamingo,
    ];

    final messages = [
      'Connection established',
      'Handshake completed',
      'Receiving packets...',
      'PING',
      'PONG',
      'Buffer flush',
      'Heartbeat OK',
      'Analyzing telemetry',
      'Re-routing traffic',
    ];

    _timer = Timer.periodic(const Duration(milliseconds: 500), (t) {
      if (_terminal == null) return;
      final color = colors[random.nextInt(colors.length)];
      final msg = messages[random.nextInt(messages.length)];
      final ip =
          '${random.nextInt(255)}.${random.nextInt(255)}.${random.nextInt(255)}.${random.nextInt(255)}';

      final fgCode = color.foregroundCode;
      const resetCode = '\x1b[0m';
      final timestamp = DateTime.now().toIso8601String().substring(11, 19);

      final ansiString = '[$timestamp] $fgCode$ip$resetCode - $msg\r\n';
      _terminal!.write(utf8.encode(ansiString));
    });

    return _VirtualTerminalWrapper(terminal: _terminal!, focusNode: focusNode);
  }

  /// Cleans up terminal and timer resources.
  void kill() {
    _timer?.cancel();
    _terminal?.dispose();
    _terminal = null;
  }
}

final class _VirtualTerminalWrapper extends StatefulWidget {
  final VirtualTerminal terminal;
  final FocusNode focusNode;

  const _VirtualTerminalWrapper({
    required this.terminal,
    required this.focusNode,
  });

  @override
  State<_VirtualTerminalWrapper> createState() =>
      _VirtualTerminalWrapperState();
}

final class _VirtualTerminalWrapperState
    extends State<_VirtualTerminalWrapper> {
  @override
  void initState() {
    super.initState();
    widget.terminal.addListener(_onTerminalChanged);
  }

  @override
  void didUpdateWidget(_VirtualTerminalWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onTerminalChanged);
      widget.terminal.addListener(_onTerminalChanged);
    }
  }

  @override
  void dispose() {
    widget.terminal.removeListener(_onTerminalChanged);
    super.dispose();
  }

  void _onTerminalChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth == BoxConstraints.infinity
            ? 80
            : constraints.maxWidth.toInt();
        final h = constraints.maxHeight == BoxConstraints.infinity
            ? 24
            : constraints.maxHeight.toInt();
        widget.terminal.resize(w, h);
        return TerminalView(
          terminal: widget.terminal,
          focusNode: widget.focusNode,
          onInput: (_) {}, // dummy input handler
        );
      },
    );
  }
}
