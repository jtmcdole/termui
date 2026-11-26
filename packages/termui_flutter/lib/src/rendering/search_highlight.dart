import 'package:flutter/rendering.dart';

/// Immutable cell-column highlight span rendered over a terminal viewport.
final class TerminalSearchHighlight {
  /// Monotonic virtual row index matching `TerminalSurface.topVirtualRow`.
  final int virtualRow;

  /// Inclusive zero-based cell column index.
  final int startCol;

  /// Exclusive zero-based cell column index.
  final int endCol;

  /// Whether this highlight is the currently focused active search match.
  final bool isActive;

  /// Creates an immutable [TerminalSearchHighlight].
  const TerminalSearchHighlight({
    required this.virtualRow,
    required this.startCol,
    required this.endCol,
    this.isActive = false,
  }) : assert(virtualRow >= 0, 'virtualRow must be non-negative'),
       assert(startCol >= 0, 'startCol must be non-negative'),
       assert(endCol >= startCol, 'endCol must be >= startCol');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalSearchHighlight &&
          other.virtualRow == virtualRow &&
          other.startCol == startCol &&
          other.endCol == endCol &&
          other.isActive == isActive;

  @override
  int get hashCode => Object.hash(virtualRow, startCol, endCol, isActive);

  @override
  String toString() =>
      'TerminalSearchHighlight(row: $virtualRow, '
      'cols: $startCol..$endCol, isActive: $isActive)';
}

/// Live provider returning active [TerminalSearchHighlight] spans to paint.
typedef TerminalSearchHighlightsProvider =
    List<TerminalSearchHighlight> Function();

/// Lightweight overlay painter drawing search match highlights above a
/// `TerminalSurface` without invalidating the glyph-atlas row cache or GPU
/// direct batch.
final class TerminalSearchHighlightPainter extends CustomPainter {
  static const double _inactiveFillAlphaScale = 0.28;
  static const double _activeFillAlphaScale = 0.45;
  static const double _activeBorderAlphaScale = 0.92;
  static const double _activeBorderWidth = 1.2;

  /// Live getter returning current highlight spans.
  final TerminalSearchHighlightsProvider highlightsProvider;

  /// Live getter returning the monotonic virtual row at viewport row `0`.
  final int Function() topVirtualRowProvider;

  /// Logical width of one terminal grid cell.
  final double cellWidth;

  /// Logical height of one terminal grid cell.
  final double cellHeight;

  /// Visible terminal grid column count.
  final int cols;

  /// Visible terminal grid row count.
  final int rows;

  /// Base color for inactive match fills.
  final Color matchColor;

  /// Base color for the active match fill and border.
  final Color activeMatchColor;

  /// Creates a [TerminalSearchHighlightPainter].
  const TerminalSearchHighlightPainter({
    super.repaint,
    required this.highlightsProvider,
    required this.topVirtualRowProvider,
    required this.cellWidth,
    required this.cellHeight,
    required this.cols,
    required this.rows,
    required this.matchColor,
    required this.activeMatchColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty ||
        cellWidth <= 0.0 ||
        cellHeight <= 0.0 ||
        cols <= 0 ||
        rows <= 0) {
      return;
    }
    final highlights = highlightsProvider();
    if (highlights.isEmpty) return;

    final topRow = topVirtualRowProvider();
    final bottomRow = topRow + rows;
    final inactiveFill = Paint()
      ..color = matchColor.withValues(
        alpha: (matchColor.a * _inactiveFillAlphaScale).clamp(0.0, 1.0),
      )
      ..style = .fill;
    final activeFill = Paint()
      ..color = activeMatchColor.withValues(
        alpha: (activeMatchColor.a * _activeFillAlphaScale).clamp(0.0, 1.0),
      )
      ..style = .fill;
    final activeBorder = Paint()
      ..color = activeMatchColor.withValues(
        alpha: (activeMatchColor.a * _activeBorderAlphaScale).clamp(0.0, 1.0),
      )
      ..style = .stroke
      ..strokeWidth = _activeBorderWidth;

    canvas
      ..save()
      ..clipRect(Offset.zero & size);
    for (final span in highlights) {
      if (span.virtualRow < topRow || span.virtualRow >= bottomRow) continue;
      final startCol = span.startCol.clamp(0, cols);
      final endCol = span.endCol.clamp(0, cols);
      if (endCol <= startCol) continue;
      final rect = Rect.fromLTWH(
        startCol * cellWidth,
        (span.virtualRow - topRow) * cellHeight,
        (endCol - startCol) * cellWidth,
        cellHeight,
      );
      if (span.isActive) {
        canvas
          ..drawRect(rect, activeFill)
          ..drawRect(rect, activeBorder);
      } else {
        canvas.drawRect(rect, inactiveFill);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant TerminalSearchHighlightPainter oldDelegate) =>
      !identical(oldDelegate.highlightsProvider, highlightsProvider) ||
      !identical(oldDelegate.topVirtualRowProvider, topVirtualRowProvider) ||
      oldDelegate.cellWidth != cellWidth ||
      oldDelegate.cellHeight != cellHeight ||
      oldDelegate.cols != cols ||
      oldDelegate.rows != rows ||
      oldDelegate.matchColor != matchColor ||
      oldDelegate.activeMatchColor != activeMatchColor;
}
