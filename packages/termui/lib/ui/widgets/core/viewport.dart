import 'package:characters/characters.dart';
import 'dart:math';
import 'dart:typed_data';
import 'package:termui/termui.dart';

/// Undocumented public member.
class Viewport implements Buffer {
  /// The underlying parent buffer.
  final Buffer parent;

  /// The rectangular bounds within the parent buffer.
  final Rect bounds;

  /// Creates a viewport wrapping [parent] constrained to [bounds].
  Viewport(this.parent, Rect bounds)
    : bounds = Rect(
        bounds.x,
        bounds.y,
        max(0, bounds.width),
        max(0, bounds.height),
      );

  @override
  int get width => bounds.width;
  @override
  set width(int val) =>
      throw UnsupportedError('Cannot set width of a Viewport');

  @override
  int get height => bounds.height;
  @override
  set height(int val) =>
      throw UnsupportedError('Cannot set height of a Viewport');

  @override
  List<String> get characters => throw UnsupportedError(
    'Flat characters access not supported on Viewport',
  );
  @override
  set characters(List<String> val) => throw UnsupportedError(
    'Flat characters access not supported on Viewport',
  );

  @override
  Uint32List get attributes => throw UnsupportedError(
    'Flat attributes access not supported on Viewport',
  );
  @override
  set attributes(Uint32List val) => throw UnsupportedError(
    'Flat attributes access not supported on Viewport',
  );

  @override
  Rect get activeClip => parent.activeClip;

  @override
  void pushClip(Rect clipRect) {
    parent.pushClip(
      Rect(
        bounds.x + clipRect.x,
        bounds.y + clipRect.y,
        clipRect.width,
        clipRect.height,
      ),
    );
  }

  @override
  void popClip() {
    parent.popClip();
  }

  @override
  bool isCellValid(int x, int y) {
    if (x < 0 || x >= bounds.width || y < 0 || y >= bounds.height) return false;
    return parent.isCellValid(bounds.x + x, bounds.y + y);
  }

  @override
  String getCharacter(int x, int y) {
    if (x < 0 || x >= bounds.width || y < 0 || y >= bounds.height) return ' ';
    return parent.getCharacter(bounds.x + x, bounds.y + y);
  }

  @override
  int getForeground(int x, int y) {
    if (x < 0 || x >= bounds.width || y < 0 || y >= bounds.height) return 0;
    return parent.getForeground(bounds.x + x, bounds.y + y);
  }

  @override
  int getBackground(int x, int y) {
    if (x < 0 || x >= bounds.width || y < 0 || y >= bounds.height) return 0;
    return parent.getBackground(bounds.x + x, bounds.y + y);
  }

  @override
  int getModifiers(int x, int y) {
    if (x < 0 || x >= bounds.width || y < 0 || y >= bounds.height) {
      return Modifier.transparent;
    }
    return parent.getModifiers(bounds.x + x, bounds.y + y);
  }

  @override
  List<RegisteredEffect> get effects => parent.effects;

  @override
  void addEffect(RegisteredEffect effect) {
    parent.addEffect(
      RegisteredEffect(
        effect.effect,
        Rect(
          bounds.x + effect.bounds.x,
          bounds.y + effect.bounds.y,
          effect.bounds.width,
          effect.bounds.height,
        ),
        effect.zIndex,
        effect.originalIndex,
      ),
    );
  }

  @override
  void setCharacter(int x, int y, String char) {
    if (x >= 0 && x < bounds.width && y >= 0 && y < bounds.height) {
      parent.setCharacter(bounds.x + x, bounds.y + y, char);
    }
  }

  @override
  void setForeground(int x, int y, int fg) {
    if (x >= 0 && x < bounds.width && y >= 0 && y < bounds.height) {
      parent.setForeground(bounds.x + x, bounds.y + y, fg);
    }
  }

  @override
  void setBackground(int x, int y, int bg) {
    if (x >= 0 && x < bounds.width && y >= 0 && y < bounds.height) {
      parent.setBackground(bounds.x + x, bounds.y + y, bg);
    }
  }

  @override
  void setModifiers(int x, int y, int mod) {
    if (x >= 0 && x < bounds.width && y >= 0 && y < bounds.height) {
      parent.setModifiers(bounds.x + x, bounds.y + y, mod);
    }
  }

  @override
  void setCell(int x, int y, String char, int fg, int bg, int mod) {
    if (x >= 0 && x < bounds.width && y >= 0 && y < bounds.height) {
      parent.setCell(bounds.x + x, bounds.y + y, char, fg, bg, mod);
    }
  }

  @override
  void setAttributes(
    int x,
    int y, {
    String? char,
    int? fg,
    int? bg,
    int? modifiers,
  }) {
    if (x < 0 || x >= bounds.width || y < 0 || y >= bounds.height) return;
    parent.setAttributes(
      bounds.x + x,
      bounds.y + y,
      char: char,
      fg: fg,
      bg: bg,
      modifiers: modifiers,
    );
  }

  @override
  void clear() {
    for (var y = 0; y < bounds.height; y++) {
      for (var x = 0; x < bounds.width; x++) {
        parent.setAttributes(
          bounds.x + x,
          bounds.y + y,
          char: ' ',
          modifiers: Modifier.transparent,
          fg: 0,
          bg: 0,
        );
      }
    }
  }

  @override
  void fillAttributes({String? char, int? fg, int? bg, int? modifiers}) {
    for (var y = 0; y < bounds.height; y++) {
      for (var x = 0; x < bounds.width; x++) {
        parent.setAttributes(
          bounds.x + x,
          bounds.y + y,
          char: char,
          fg: fg,
          bg: bg,
          modifiers: modifiers,
        );
      }
    }
  }

  @override
  void resize(int newWidth, int newHeight) {
    throw UnsupportedError('Cannot resize a Viewport');
  }

  @override
  void writeString(int x, int y, String text, Style style) {
    final startX = x;
    final chars = text.characters;
    var currentX = x;
    var currentY = y;

    for (final char in chars) {
      if (char == '\n') {
        currentX = startX;
        currentY++;
        continue;
      }
      if (currentX >= 0 &&
          currentX < bounds.width &&
          currentY >= 0 &&
          currentY < bounds.height) {
        // Clear potential wide char we are about to overwrite
        final currentChar = parent.getCharacter(
          bounds.x + currentX,
          bounds.y + currentY,
        );
        if (currentChar == '') {
          if (currentX - 1 >= 0) {
            final prevChar = parent.getCharacter(
              bounds.x + currentX - 1,
              bounds.y + currentY,
            );
            if (isWideGrapheme(prevChar)) {
              parent.setAttributes(
                bounds.x + currentX - 1,
                bounds.y + currentY,
                char: ' ',
              );
            }
          }
        } else if (isWideGrapheme(currentChar)) {
          if (currentX + 1 < bounds.width) {
            final nextChar = parent.getCharacter(
              bounds.x + currentX + 1,
              bounds.y + currentY,
            );
            if (nextChar == '') {
              parent.setAttributes(
                bounds.x + currentX + 1,
                bounds.y + currentY,
                char: ' ',
              );
            }
          }
        }

        final isWide = isWideGrapheme(char);
        if (isWide && currentX == bounds.width - 1) {
          // Can't fit wide character in the last column, write a space instead
          final currentBg = parent.getBackground(
            bounds.x + currentX,
            bounds.y + currentY,
          );
          parent.setAttributes(
            bounds.x + currentX,
            bounds.y + currentY,
            char: ' ',
            fg: style.foreground?.argb ?? 0,
            bg: style.background?.argb ?? currentBg,
            modifiers: style.modifiers,
          );
          currentX += 1;
        } else {
          final currentBg = parent.getBackground(
            bounds.x + currentX,
            bounds.y + currentY,
          );
          parent.setAttributes(
            bounds.x + currentX,
            bounds.y + currentY,
            char: char,
            fg: style.foreground?.argb ?? 0,
            bg: style.background?.argb ?? currentBg,
            modifiers: style.modifiers,
          );
          if (isWide) {
            if (currentX + 1 < bounds.width) {
              // Clear potential wide char we are overwriting in the next cell
              final nextChar = parent.getCharacter(
                bounds.x + currentX + 1,
                bounds.y + currentY,
              );
              if (isWideGrapheme(nextChar) && currentX + 2 < bounds.width) {
                final nextNextChar = parent.getCharacter(
                  bounds.x + currentX + 2,
                  bounds.y + currentY,
                );
                if (nextNextChar == '') {
                  parent.setAttributes(
                    bounds.x + currentX + 2,
                    bounds.y + currentY,
                    char: ' ',
                  );
                }
              }
              final nextBg = parent.getBackground(
                bounds.x + currentX + 1,
                bounds.y + currentY,
              );
              parent.setAttributes(
                bounds.x + currentX + 1,
                bounds.y + currentY,
                char: '',
                fg: style.foreground?.argb ?? 0,
                bg: style.background?.argb ?? nextBg,
                modifiers: style.modifiers,
              );
            }
            currentX += 2;
          } else {
            currentX += 1;
          }
        }
      } else {
        currentX += 1;
      }
    }
  }
}

/// Splits a [Rect] area into multiple sub-rectangles according to layout constraints.
