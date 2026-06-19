import '../perf/tracer.dart';
import 'buffer.dart';
import 'style.dart';

/// The target mode for terminal rendering.
enum RenderingMode {
  /// Renders to the absolute terminal screen area (typically combined with alternate screen buffer).
  alternateScreen,

  /// Renders relative to the cursor's current inline position without clearing screen history.
  inline,
}

/// A diff-based terminal renderer.
///
/// It maintains a front-buffer representing the last rendered state of the screen.
/// When [render] is called with a new back-buffer, the renderer finds the differences
/// and emits the minimal set of ANSI control sequences to update the display.
class Renderer {
  static final int _traceRenderId = Tracer.registerString('Renderer:render');

  final Buffer _frontBuffer;

  /// The rendering mode used by this renderer.
  /// Determines whether output is rendered inline or to the alternate screen buffer.
  final RenderingMode mode;
  int _lastHeight = 0;
  bool _firstFrame = true;

  /// Creates a renderer with an initial screen size.
  Renderer(int width, int height, {this.mode = RenderingMode.alternateScreen})
    : _frontBuffer = Buffer(width, height);

  /// Exposes the current front-buffer representing the screen state.
  Buffer get frontBuffer => _frontBuffer;

  bool _styleEquals(Style a, Style b) {
    if (identical(a, b)) return true;
    if (a.modifiers != b.modifiers) return false;

    final afg = a.foreground;
    final bfg = b.foreground;
    if (afg != bfg) {
      if (afg == null || bfg == null) return false;
      if (afg.argb != bfg.argb) return false;
    }

    final abg = a.background;
    final bbg = b.background;
    if (abg != bbg) {
      if (abg == null || bbg == null) return false;
      if (abg.argb != bbg.argb) return false;
    }

    return true;
  }

  /// Diffs [backBuffer] against [_frontBuffer] and writes minimal ANSI escape sequences to [out].
  void render(Buffer backBuffer, StringSink out) {
    Tracer.record(_traceRenderId, Phase.begin, TraceCategory.paint);
    try {
      bool sizeChanged = _firstFrame;
      _firstFrame = false;

      if (mode == RenderingMode.inline) {
        if (_lastHeight > 0) {
          // Move cursor back up to the top-left of the inline block
          out.write('\x1b[${_lastHeight}F');
        } else {
          // First frame: move to the next line to avoid printing TUI inline on the command prompt line
          out.write('\n\r');
        }
        if (backBuffer.width != _frontBuffer.width ||
            backBuffer.height != _frontBuffer.height) {
          _frontBuffer.resize(backBuffer.width, backBuffer.height);
          sizeChanged = true;
        }
      } else {
        if (backBuffer.width != _frontBuffer.width ||
            backBuffer.height != _frontBuffer.height ||
            sizeChanged) {
          _frontBuffer.resize(backBuffer.width, backBuffer.height);
          sizeChanged = true;
          // Clear screen and reset cursor position to top-left
          out.write('\x1b[2J\x1b[H');
        }
      }

      Style activeStyle = Style.empty;
      int cursorX = 0;
      int cursorY = 0;

      final width = backBuffer.width;
      final height = backBuffer.height;
      final backCells = backBuffer.cells;
      final frontCells = _frontBuffer.cells;

      for (var y = 0; y < height; y++) {
        var x = 0;
        final rowOffset = y * width;
        while (x < width) {
          final idx = rowOffset + x;
          final backCell = backCells[idx];
          final frontCell = frontCells[idx];

          final changed =
              sizeChanged ||
              (backCell.char != frontCell.char ||
                  !_styleEquals(backCell.style, frontCell.style));

          if (changed) {
            final runStart = x;
            var runEnd = x;
            // Find the end of the contiguous run of changed cells in the current row
            while (runEnd < width) {
              final cell = backCells[rowOffset + runEnd];
              final fCell = frontCells[rowOffset + runEnd];
              if (sizeChanged ||
                  cell.char != fCell.char ||
                  !_styleEquals(cell.style, fCell.style)) {
                runEnd++;
              } else {
                break;
              }
            }

            // Move cursor to (runStart, y) relative or absolute
            if (mode == RenderingMode.inline) {
              _moveCursorRelative(out, cursorX, cursorY, runStart, y);
              cursorX = runStart;
              cursorY = y;
            } else {
              out.write('\x1b[${y + 1};${runStart + 1}H');
            }

            // Render each cell in the run
            for (var rx = runStart; rx < runEnd; rx++) {
              final cell = backCells[rowOffset + rx];
              activeStyle = _writeStyleTransition(out, activeStyle, cell.style);
              out.write(cell.char);
              final fCell = frontCells[rowOffset + rx];
              fCell.char = cell.char;
              fCell.style = cell.style;
              if (mode == RenderingMode.inline) {
                cursorX++;
              }
            }
            x = runEnd;
          } else {
            x++;
          }
        }
      }

      if (activeStyle != Style.empty) {
        out.write('\x1b[0m');
      }

      if (mode == RenderingMode.inline) {
        // Position cursor at the beginning of the line immediately following the inline block
        _moveCursorRelative(out, cursorX, cursorY, 0, backBuffer.height);
        _lastHeight = backBuffer.height;
      }
    } finally {
      Tracer.record(_traceRenderId, Phase.end, TraceCategory.paint);
    }
  }

  void _moveCursorRelative(
    StringSink out,
    int fromX,
    int fromY,
    int toX,
    int toY,
  ) {
    if (fromY == toY && fromX == toX) return;

    var currentX = fromX;

    final dy = toY - fromY;
    if (dy > 0) {
      for (var i = 0; i < dy; i++) {
        out.write('\n\r');
      }
      currentX = 0;
    } else if (dy < 0) {
      out.write('\x1b[${-dy}A');
    }

    if (toX == 0 && currentX > 0) {
      out.write('\r');
    } else {
      final dx = toX - currentX;
      if (dx > 0) {
        out.write('\x1b[${dx}C');
      } else if (dx < 0) {
        out.write('\x1b[${-dx}D');
      }
    }
  }

  Style _writeStyleTransition(StringSink out, Style current, Style target) {
    if (current == target) return current;

    if (target == Style.empty) {
      out.write('\x1b[0m');
      return Style.empty;
    }

    final colorCleared =
        (current.foreground != null && target.foreground == null) ||
        (current.background != null && target.background == null);

    bool modifierTurnedOff = false;
    for (var i = 0; i < 8; i++) {
      final mod = 1 << i;
      if (Modifier.has(current.modifiers, mod) &&
          !Modifier.has(target.modifiers, mod)) {
        modifierTurnedOff = true;
        break;
      }
    }

    var effectiveCurrent = current;
    if (colorCleared || modifierTurnedOff) {
      out.write('\x1b[0m');
      effectiveCurrent = Style.empty;
    }

    final sb = StringBuffer();

    if (target.foreground != effectiveCurrent.foreground &&
        target.foreground != null) {
      final fg = target.foreground!;
      sb.write('38;2;${fg.r};${fg.g};${fg.b};');
    }

    if (target.background != effectiveCurrent.background &&
        target.background != null) {
      final bg = target.background!;
      sb.write('48;2;${bg.r};${bg.g};${bg.b};');
    }

    for (var i = 0; i < 8; i++) {
      final mod = 1 << i;
      if (Modifier.has(target.modifiers, mod) &&
          !Modifier.has(effectiveCurrent.modifiers, mod)) {
        int code = 0;
        switch (mod) {
          case Modifier.bold:
            code = 1;
            break;
          case Modifier.dim:
            code = 2;
            break;
          case Modifier.italic:
            code = 3;
            break;
          case Modifier.underline:
            code = 4;
            break;
          case Modifier.blink:
            code = 5;
            break;
          case Modifier.reverse:
            code = 7;
            break;
          case Modifier.hidden:
            code = 8;
            break;
          case Modifier.crossedOut:
            code = 9;
            break;
        }
        if (code != 0) {
          sb.write('$code;');
        }
      }
    }

    var s = sb.toString();
    if (s.isNotEmpty) {
      if (s.endsWith(';')) {
        s = s.substring(0, s.length - 1);
      }
      out.write('\x1b[${s}m');
    }

    return target;
  }
}
