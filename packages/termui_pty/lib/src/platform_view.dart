import 'dart:async';
import 'package:termui/termui.dart';
import 'package:pty2/pty2.dart';
import 'virtual_terminal.dart';
import 'input_encoder.dart';
import 'package:termui/terminal/event.dart' as ev;

/// A widget that renders a PTY subprocess and forwards terminal input events.
class PlatformView extends StatefulWidget {
  /// The running pseudo-terminal process.
  final PseudoTerminal pty;

  /// If true, the terminal will use a transparent background (e.g. for compositing overlays).
  final bool transparentBackground;

  /// The default foreground color applied to characters when no explicit color is set.
  final Color? defaultForeground;

  /// Optional focus node for managing keyboard focus.
  final FocusNode? focusNode;

  /// Creates a PlatformView that manages a virtual terminal connected to [pty].
  const PlatformView({
    super.key,
    required this.pty,
    this.transparentBackground = false,
    this.defaultForeground,
    this.focusNode,
  });

  @override
  State<PlatformView> createState() => _PlatformViewState();
}

class _PlatformViewState extends State<PlatformView> {
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
          child: _RawTerminalBufferWidget(
            terminal: _terminal,
            pty: widget.pty,
            focusNode: _focusNode,
          ),
        );
      },
    );
  }
}

class _RawTerminalBufferWidget extends Widget {
  final VirtualTerminal terminal;
  final PseudoTerminal pty;
  final FocusNode focusNode;

  const _RawTerminalBufferWidget({
    required this.terminal,
    required this.pty,
    required this.focusNode,
  });

  @override
  Element createElement() => _RawTerminalBufferElement(this);

  @override
  int getIntrinsicHeight(int width) => terminal.height;

  @override
  int getIntrinsicWidth(int height) => terminal.width;
}

class _RawTerminalBufferElement extends LeafElement implements MouseEventHandler {
  _RawTerminalBufferElement(_RawTerminalBufferWidget super.widget);

  @override
  void mount(Element? parent) {
    super.mount(parent);
    final w = widget as _RawTerminalBufferWidget;
    w.terminal.addListener(markNeedsBuild);
  }

  @override
  void unmount() {
    final w = widget as _RawTerminalBufferWidget;
    w.terminal.removeListener(markNeedsBuild);
    super.unmount();
  }

  @override
  void update(Widget newWidget) {
    final oldWidget = widget as _RawTerminalBufferWidget;
    final newW = newWidget as _RawTerminalBufferWidget;
    if (oldWidget.terminal != newW.terminal) {
      oldWidget.terminal.removeListener(markNeedsBuild);
      newW.terminal.addListener(markNeedsBuild);
    }
    super.update(newWidget);
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = widget as _RawTerminalBufferWidget;
    return constraints.constrain(Size(w.terminal.width, w.terminal.height));
  }

  @override
  void handleMouseEvent(ev.MouseEvent event, int localX, int localY) {
    final w = widget as _RawTerminalBufferWidget;
    w.focusNode.requestFocus();

    if (!w.terminal.mouseTrackingEnabled) {
      return;
    }

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
      w.pty.write(str);
    }
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as _RawTerminalBufferWidget;
    final source = w.terminal.buffer;

    final startX = offset.dx.toInt();
    final startY = offset.dy.toInt();
    final endX = (startX + source.width).clamp(0, buffer.width);
    final endY = (startY + source.height).clamp(0, buffer.height);

    if (startX < endX && startY < endY) {
      final rowLength = endX - startX;
      final transparent = w.terminal.transparentBackground;

      for (var ty = startY; ty < endY; ty++) {
        final sy = ty - startY;
        final targetStartIdx = ty * buffer.width + startX;
        final sourceStartIdx = sy * source.width;

        if (!transparent) {
          // Fast path: block copy entire rows
          buffer.characters.setRange(targetStartIdx, targetStartIdx + rowLength, source.characters, sourceStartIdx);

          final targetAttrStart = targetStartIdx * 3;
          final sourceAttrStart = sourceStartIdx * 3;
          buffer.attributes.setRange(targetAttrStart, targetAttrStart + rowLength * 3, source.attributes, sourceAttrStart);
        } else {
          // Slow path: skip transparent cells but use direct array access
          var tIdx = targetStartIdx;
          var sIdx = sourceStartIdx;
          for (var i = 0; i < rowLength; i++, tIdx++, sIdx++) {
            final sAttrIdx = sIdx * 3;
            if ((source.attributes[sAttrIdx + 2] & Modifier.transparent) == 0) {
              buffer.characters[tIdx] = source.characters[sIdx];
              final tAttrIdx = tIdx * 3;
              buffer.attributes[tAttrIdx + 0] = source.attributes[sAttrIdx + 0];
              buffer.attributes[tAttrIdx + 1] = source.attributes[sAttrIdx + 1];
              buffer.attributes[tAttrIdx + 2] = source.attributes[sAttrIdx + 2];
            }
          }
        }
      }
    }
  }
}
