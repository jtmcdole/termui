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

  /// Optional callback invoked when the underlying PTY process exits.
  final void Function(int exitCode)? onExit;

  /// Creates a PseudoTerminalView that wires a [VirtualTerminal] to [pty].
  const PseudoTerminalView({
    super.key,
    required this.pty,
    this.transparentBackground = false,
    this.defaultForeground,
    this.focusNode,
    this.onExit,
  });

  @override
  State<PseudoTerminalView> createState() => _PseudoTerminalViewState();
}

class _PseudoTerminalViewState extends State<PseudoTerminalView> {
  late VirtualTerminal _terminal;
  StreamSubscription<String>? _outSubscription;
  late FocusNode _focusNode;
  bool _ownsFocusNode = false;
  bool _exited = false;
  int _lastWidth = 0;
  int _lastHeight = 0;

  void _notifyExit(int exitCode) {
    if (_exited || !mounted) return;
    _exited = true;
    if (widget.onExit != null) {
      widget.onExit!(exitCode);
    } else {
      PromptScope.of(context)?.done(exitCode);
    }
  }

  void _bindFocusNode(FocusNode? externalNode) {
    if (externalNode != null) {
      _focusNode = externalNode;
      _ownsFocusNode = false;
    } else {
      _focusNode = FocusNode(id: 'pseudo_terminal_view');
      _ownsFocusNode = true;
    }
  }

  void _subscribeToPty(PseudoTerminal pty) {
    _exited = false;
    _outSubscription = pty.out.listen(_terminal.writeString);
    pty.exitCode.then(
      (code) {
        if (mounted && widget.pty == pty) _notifyExit(code);
      },
      onError: (_) {
        if (mounted && widget.pty == pty) _notifyExit(-1);
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _bindFocusNode(widget.focusNode);
    _terminal = VirtualTerminal(
      width: 80,
      height: 24,
      transparentBackground: widget.transparentBackground,
      defaultForeground: widget.defaultForeground,
    );
    _subscribeToPty(widget.pty);
  }

  @override
  void didUpdateWidget(PseudoTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      if (_ownsFocusNode) {
        _focusNode.dispose();
      }
      _bindFocusNode(widget.focusNode);
    }
    if (widget.pty != oldWidget.pty) {
      _outSubscription?.cancel();
      _subscribeToPty(widget.pty);
      if (_lastWidth > 0 && _lastHeight > 0) {
        try {
          widget.pty.resize(_lastWidth, _lastHeight);
        } catch (_) {
          // Ignore unsupported platforms
        }
      }
    }
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
