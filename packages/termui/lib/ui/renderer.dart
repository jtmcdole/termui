import 'package:termui/termui.dart';

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

      int activeFg = 0;
      int activeBg = 0;
      int activeMod = 0;
      int cursorX = 0;
      int cursorY = 0;

      final width = backBuffer.width;
      final height = backBuffer.height;

      final backChars = backBuffer.characters;
      final backAttr = backBuffer.attributes;

      final frontChars = _frontBuffer.characters;
      final frontAttr = _frontBuffer.attributes;

      for (var y = 0; y < height; y++) {
        var x = 0;
        final rowOffset = y * width;
        while (x < width) {
          final idx = rowOffset + x;
          final attrIdx = idx * 3;

          final changed =
              sizeChanged ||
              (backChars[idx] != frontChars[idx] ||
                  backAttr[attrIdx + 0] != frontAttr[attrIdx + 0] ||
                  backAttr[attrIdx + 1] != frontAttr[attrIdx + 1] ||
                  backAttr[attrIdx + 2] != frontAttr[attrIdx + 2]);

          if (changed) {
            final runStart = x;
            var runEnd = x;
            // Find the end of the contiguous run of changed cells in the current row
            while (runEnd < width) {
              final ridx = rowOffset + runEnd;
              final rattrIdx = ridx * 3;
              if (sizeChanged ||
                  backChars[ridx] != frontChars[ridx] ||
                  backAttr[rattrIdx + 0] != frontAttr[rattrIdx + 0] ||
                  backAttr[rattrIdx + 1] != frontAttr[rattrIdx + 1] ||
                  backAttr[rattrIdx + 2] != frontAttr[rattrIdx + 2]) {
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
              final rxIdx = rowOffset + rx;
              final rxAttrIdx = rxIdx * 3;
              final cellFg = backAttr[rxAttrIdx + 0];
              final cellBg = backAttr[rxAttrIdx + 1];
              final cellMod = backAttr[rxAttrIdx + 2];

              _writeStyleTransitionPrims(
                out,
                activeFg,
                activeBg,
                activeMod,
                cellFg,
                cellBg,
                cellMod,
              );
              activeFg = cellFg;
              activeBg = cellBg;
              activeMod = cellMod;

              out.write(backChars[rxIdx]);

              frontChars[rxIdx] = backChars[rxIdx];
              frontAttr[rxAttrIdx + 0] = backAttr[rxAttrIdx + 0];
              frontAttr[rxAttrIdx + 1] = backAttr[rxAttrIdx + 1];
              frontAttr[rxAttrIdx + 2] = backAttr[rxAttrIdx + 2];

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

      if (activeFg != 0 || activeBg != 0 || activeMod != 0) {
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

  /// Writes the ANSI style transitions between the current style state and the target state.
  ///
  /// [Optimization Note - Primitive Unboxing]:
  /// Instead of instantiating [Style] and [Color] objects in the inner rendering loop,
  /// this method takes raw unboxed integers for foreground, background, and modifiers.
  /// This eliminates garbage collector allocation pressure and hot-path object layout checks.
  void _writeStyleTransitionPrims(
    StringSink out,
    int curFg,
    int curBg,
    int curMod,
    int tgtFg,
    int tgtBg,
    int tgtMod,
  ) {
    if (curFg == tgtFg && curBg == tgtBg && curMod == tgtMod) return;

    if (tgtFg == 0 && tgtBg == 0 && tgtMod == 0) {
      out.write('\x1b[0m');
      return;
    }

    final colorCleared =
        (curFg != 0 && tgtFg == 0) || (curBg != 0 && tgtBg == 0);
    final modifierTurnedOff = (curMod & ~tgtMod) != 0;

    var effectiveFg = curFg;
    var effectiveBg = curBg;
    var effectiveMod = curMod;

    if (colorCleared || modifierTurnedOff) {
      out.write('\x1b[0m');
      effectiveFg = 0;
      effectiveBg = 0;
      effectiveMod = 0;
    }

    final sb = StringBuffer();

    if (tgtFg != effectiveFg && tgtFg != 0) {
      final r = (tgtFg >> 16) & 0xFF;
      final g = (tgtFg >> 8) & 0xFF;
      final b = tgtFg & 0xFF;
      sb.write('38;2;$r;$g;$b;');
    }

    if (tgtBg != effectiveBg && tgtBg != 0) {
      final r = (tgtBg >> 16) & 0xFF;
      final g = (tgtBg >> 8) & 0xFF;
      final b = tgtBg & 0xFF;
      sb.write('48;2;$r;$g;$b;');
    }

    final addedMods = tgtMod & ~effectiveMod;
    if (addedMods != 0) {
      for (var i = 0; i < 8; i++) {
        final mod = 1 << i;
        if ((addedMods & mod) != 0) {
          final code = switch (mod) {
            Modifier.bold => 1,
            Modifier.dim => 2,
            Modifier.italic => 3,
            Modifier.underline => 4,
            Modifier.blink => 5,
            Modifier.reverse => 7,
            Modifier.hidden => 8,
            Modifier.crossedOut => 9,
            _ => 0,
          };
          if (code != 0) {
            sb.write('$code;');
          }
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
  }
}
