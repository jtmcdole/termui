import 'package:characters/characters.dart';
import 'dart:math';
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
  List<Cell> get cells =>
      throw UnsupportedError('Flat cells access not supported on Viewport');
  @override
  set cells(List<Cell> val) =>
      throw UnsupportedError('Flat cells access not supported on Viewport');

  @override
  Cell? getCell(int x, int y) {
    if (x < 0 || x >= bounds.width || y < 0 || y >= bounds.height) return null;
    return parent.getCell(bounds.x + x, bounds.y + y);
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
  void setCell(int x, int y, Cell cell) {
    if (x < 0 || x >= bounds.width || y < 0 || y >= bounds.height) return;
    parent.setCell(bounds.x + x, bounds.y + y, cell);
  }

  @override
  void clear() {
    for (var y = 0; y < bounds.height; y++) {
      for (var x = 0; x < bounds.width; x++) {
        final cell = parent.getCell(bounds.x + x, bounds.y + y);
        if (cell != null) {
          if (cell.char != ' ' || cell.style != Style.transparent) {
            cell.char = ' ';
            cell.style = Style.transparent;
          }
        }
      }
    }
  }

  @override
  void fill(Cell cell) {
    for (var y = 0; y < bounds.height; y++) {
      for (var x = 0; x < bounds.width; x++) {
        final targetCell = parent.getCell(bounds.x + x, bounds.y + y);
        if (targetCell != null) {
          targetCell.char = cell.char;
          targetCell.style = cell.style;
        }
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
        final cell = parent.getCell(bounds.x + currentX, bounds.y + currentY);
        if (cell != null) {
          if (cell.char == '') {
            if (currentX - 1 >= 0) {
              final prevCell = parent.getCell(
                bounds.x + currentX - 1,
                bounds.y + currentY,
              );
              if (prevCell != null && isWideGrapheme(prevCell.char)) {
                prevCell.char = ' ';
              }
            }
          } else if (isWideGrapheme(cell.char)) {
            if (currentX + 1 < bounds.width) {
              final nextCell = parent.getCell(
                bounds.x + currentX + 1,
                bounds.y + currentY,
              );
              if (nextCell != null && nextCell.char == '') {
                nextCell.char = ' ';
              }
            }
          }
        }

        final isWide = isWideGrapheme(char);
        if (isWide && currentX == bounds.width - 1) {
          // Can't fit wide character in the last column, write a space instead
          final cell = parent.getCell(bounds.x + currentX, bounds.y + currentY);
          if (cell != null) {
            cell.char = ' ';
            cell.style = Style(
              foreground: style.foreground,
              background: style.background ?? cell.style.background,
              modifiers: style.modifiers,
            );
          }
          currentX += 1;
        } else {
          final cell = parent.getCell(bounds.x + currentX, bounds.y + currentY);
          if (cell != null) {
            cell.char = char;
            cell.style = Style(
              foreground: style.foreground,
              background: style.background ?? cell.style.background,
              modifiers: style.modifiers,
            );
          }
          if (isWide) {
            if (currentX + 1 < bounds.width) {
              // Clear potential wide char we are overwriting in the next cell
              final nextCell = parent.getCell(
                bounds.x + currentX + 1,
                bounds.y + currentY,
              );
              if (nextCell != null) {
                if (isWideGrapheme(nextCell.char) &&
                    currentX + 2 < bounds.width) {
                  final nextNextCell = parent.getCell(
                    bounds.x + currentX + 2,
                    bounds.y + currentY,
                  );
                  if (nextNextCell != null && nextNextCell.char == '') {
                    nextNextCell.char = ' ';
                  }
                }
                nextCell.char = '';
                nextCell.style = Style(
                  foreground: style.foreground,
                  background: style.background ?? nextCell.style.background,
                  modifiers: style.modifiers,
                );
              }
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
