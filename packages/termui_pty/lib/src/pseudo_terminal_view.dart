import 'dart:async';
import 'package:termui/termui.dart';
import 'package:pty2/pty2.dart';
import 'virtual_terminal.dart';
import 'terminal_view.dart';

/// A convenience widget that spawns and manages a TerminalView connected to a [PseudoTerminal].
class PseudoTerminalView extends StatefulWidget {
  /// The running pseudo-terminal process.
  final PseudoTerminal pty;

  /// If true, the terminal will use a transparent background (e.g. for compositing overlays).
  final bool transparentBackground;

  /// The default foreground color applied to characters when no explicit color is set.
  final Color? defaultForeground;

  /// Optional focus node for managing keyboard focus.
  final FocusNode? focusNode;

  /// Creates a PseudoTerminalView that wires a [VirtualTerminal] to [pty].
  const PseudoTerminalView({
    super.key,
    required this.pty,
    this.transparentBackground = false,
    this.defaultForeground,
    this.focusNode,
  });

  @override
  State<PseudoTerminalView> createState() => _PseudoTerminalViewState();
}

class _PseudoTerminalViewState extends State<PseudoTerminalView> {
  late VirtualTerminal _terminal;
  StreamSubscription? _outSubscription;
  late final FocusNode _focusNode;
  bool _ownsFocusNode = false;
  int _lastWidth = 0;
  int _lastHeight = 0;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode != null) {
      _focusNode = widget.focusNode!;
    } else {
      _focusNode = FocusNode(id: 'pseudo_terminal_view');
      _ownsFocusNode = true;
    }
    _terminal = VirtualTerminal(
      width: 80,
      height: 24,
      transparentBackground: widget.transparentBackground,
      defaultForeground: widget.defaultForeground,
    );
    _outSubscription = widget.pty.out.listen((data) {
      _terminal.write(data.codeUnits);
    });
  }

  @override
  void dispose() {
    _outSubscription?.cancel();
    _terminal.dispose();
    if (_ownsFocusNode) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  void _resizeIfNecessary(int width, int height) {
    if (width != _lastWidth || height != _lastHeight) {
      _lastWidth = width;
      _lastHeight = height;
      _terminal.resize(width, height);
      try {
        widget.pty.resize(width, height);
      } catch (e) {
        // Ignore unsupported platforms
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth == BoxConstraints.infinity
            ? 80
            : constraints.maxWidth;
        final height = constraints.maxHeight == BoxConstraints.infinity
            ? 24
            : constraints.maxHeight;

        _resizeIfNecessary(width, height);

        return TerminalView(
          terminal: _terminal,
          focusNode: _focusNode,
          onInput: (data) => widget.pty.write(data),
        );
      },
    );
  }
}
