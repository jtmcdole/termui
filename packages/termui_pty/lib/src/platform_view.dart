import 'dart:async';
import 'package:termui/termui.dart';
import 'package:pty2/pty2.dart';
import 'virtual_terminal.dart';
import 'input_encoder.dart';
import 'package:termui/terminal/event.dart' as ev;

/// A widget that renders a PTY subprocess and forwards terminal input events.
class PlatformView extends StatefulWidget implements MouseEventHandler {
  /// The running pseudo-terminal process.
  final PseudoTerminal pty;

  /// If true, the terminal will use a transparent background (e.g. for compositing overlays).
  final bool transparentBackground;

  /// The default foreground color applied to characters when no explicit color is set.
  final Color? defaultForeground;

  /// Optional focus node for managing keyboard focus.
  final FocusNode? focusNode;

  /// Creates a PlatformView that manages a virtual terminal connected to [pty].
  PlatformView({
    super.key,
    required this.pty,
    this.transparentBackground = false,
    this.defaultForeground,
    this.focusNode,
  });

  _PlatformViewState? _state;

  @override
  void handleMouseEvent(ev.MouseEvent event, int localX, int localY) {
    _state?.handleMouseEvent(event, localX, localY);
  }

  @override
  State<PlatformView> createState() {
    final state = _PlatformViewState();
    _state = state;
    return state;
  }
}

class _PlatformViewState extends State<PlatformView>
    implements MouseEventHandler {
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
      _focusNode = FocusNode(id: 'platform_view');
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
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _outSubscription?.cancel();
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
  void handleMouseEvent(ev.MouseEvent event, int localX, int localY) {
    _focusNode.requestFocus();

    // Convert local coordinates back to 1-indexed VT100 coordinates
    final translatedEvent = ev.MouseEvent(
      x: localX + 1,
      y: localY + 1,
      globalX: event.globalX,
      globalY: event.globalY,
      button: event.button,
      type: event.type,
      modifiers: event.modifiers,
    );
    final str = InputEncoder.encode(translatedEvent);
    if (str.isNotEmpty) {
      widget.pty.write(str);
    }
  }

  @override
  Widget build(BuildContext context) {
    widget._state = this;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth == BoxConstraints.infinity
            ? 80
            : constraints.maxWidth;
        final height = constraints.maxHeight == BoxConstraints.infinity
            ? 24
            : constraints.maxHeight;

        _resizeIfNecessary(width, height);

        return Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: (event) {
            final str = InputEncoder.encode(event);
            if (str.isNotEmpty) {
              widget.pty.write(str);
              return true;
            }
            return false;
          },
          child: _RawTerminalBufferWidget(buffer: _terminal.buffer),
        );
      },
    );
  }
}

class _RawTerminalBufferWidget extends Widget {
  final Buffer buffer;

  const _RawTerminalBufferWidget({required this.buffer});

  @override
  Element createElement() => _RawTerminalBufferElement(this);

  @override
  int getIntrinsicHeight(int width) => buffer.height;

  @override
  int getIntrinsicWidth(int height) => buffer.width;
}

class _RawTerminalBufferElement extends LeafElement {
  _RawTerminalBufferElement(_RawTerminalBufferWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = widget as _RawTerminalBufferWidget;
    return constraints.constrain(Size(w.buffer.width, w.buffer.height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as _RawTerminalBufferWidget;
    final source = w.buffer;

    // We just composite the source buffer into the target buffer at offset
    final startX = offset.dx.toInt();
    final startY = offset.dy.toInt();
    final endX = (startX + source.width).clamp(0, buffer.width);
    final endY = (startY + source.height).clamp(0, buffer.height);

    if (startX < endX && startY < endY) {
      for (var ty = startY; ty < endY; ty++) {
        final sy = ty - startY;
        for (var tx = startX; tx < endX; tx++) {
          final sx = tx - startX;

          final char = source.getCharacter(sx, sy);
          final fg = source.getForeground(sx, sy);
          final bg = source.getBackground(sx, sy);
          final mod = source.getModifiers(sx, sy);

          if ((mod & Modifier.transparent) == 0) {
            buffer.setCell(tx, ty, char, fg, bg, mod);
          }
        }
      }
    }
  }
}
