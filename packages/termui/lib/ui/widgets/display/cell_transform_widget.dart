import 'dart:math';

import 'package:characters/characters.dart';
import 'package:termui/termui.dart';

/// Builder producing a per-cell [CellTransform] from local coordinates and grapheme.
typedef CellTransformBuilder =
    CellTransform? Function(int localX, int localY, String grapheme);

/// Builder producing a per-character [CellTransform] for [TweenText].
///
/// Receives the non-space grapheme ordinal [charIndex], the [grapheme] string,
/// and the stable logical [animationId] assigned to that character.
typedef TweenCharTransformBuilder =
    CellTransform? Function(int charIndex, String grapheme, int animationId);

/// A wrapper widget that attaches a static [CellTransform] or finite [CellTween]
/// across the non-empty painted cells of its [child].
class CellTransformWidget extends Widget {
  /// The child widget to paint before attaching per-cell transforms.
  final Widget child;

  /// Optional uniform [CellTransform] applied to every non-empty painted cell.
  final CellTransform? transform;

  /// Optional per-cell builder overriding [transform] for each painted cell.
  final CellTransformBuilder? transformBuilder;

  /// Whether space (`' '`) cells also receive transforms (defaults to `false`).
  final bool includeSpaces;

  /// Whether transforms are applied during paint.
  final bool enabled;

  /// Creates a [CellTransformWidget] wrapping [child].
  const CellTransformWidget({
    super.key,
    required this.child,
    this.transform,
    this.transformBuilder,
    this.includeSpaces = false,
    this.enabled = true,
  });

  @override
  int getIntrinsicHeight(int width) => child.getIntrinsicHeight(width);

  @override
  int getIntrinsicWidth(int height) => child.getIntrinsicWidth(height);

  @override
  Element createElement() => CellTransformElement(this);
}

/// Element managing a [CellTransformWidget].
class CellTransformElement extends SingleChildElement {
  /// Creates a [CellTransformElement] for [widget].
  CellTransformElement(CellTransformWidget super.widget);

  @override
  Widget? get childWidget => (widget as CellTransformWidget).child;

  @override
  Size performLayout(BoxConstraints constraints) {
    if (childElement != null) {
      final childSize = childElement!.layout(constraints);
      childElement!.relativeOffset = Offset.zero;
      return childSize;
    }
    return constraints.constrain(Size.zero);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    super.performPaint(buffer, offset);

    final cw = widget as CellTransformWidget;
    if (!cw.enabled) return;
    if (cw.transformBuilder == null &&
        (cw.transform == null || cw.transform!.isIdentity)) {
      return;
    }

    for (var ly = 0; ly < size.height; ly++) {
      final y = offset.dy + ly;
      for (var lx = 0; lx < size.width; lx++) {
        _applyCellTransform(buffer, offset.dx + lx, y, lx, ly, cw);
      }
    }
  }

  static void _applyCellTransform(
    Buffer buffer,
    int x,
    int y,
    int localX,
    int localY,
    CellTransformWidget cw,
  ) {
    if (!buffer.isCellValid(x, y)) return;
    if ((buffer.getModifiers(x, y) & Modifier.transparent) != 0) return;

    final char = buffer.getCharacter(x, y);
    if (char.isEmpty) return;
    if (!cw.includeSpaces && char == ' ') return;

    final resolved = cw.transformBuilder != null
        ? cw.transformBuilder!(localX, localY, char)
        : cw.transform;
    if (resolved != null && !resolved.isIdentity) {
      buffer.setCellTransform(x, y, resolved);
    }
  }
}

/// Declarative text widget supporting static per-cell poses, finite [CellTween]
/// transitions, `fromCurrent` multi-step keyframes, and stable logical
/// `animationId` values across unrelated rebuilds.
///
/// ### Logical `animationId` Stability
/// - When [animationId] is explicitly provided, it is used directly (and offset
///   by character index when [perCharacter] is `true`).
/// - When [animationId] is omitted and a tween uses `animationId: 0` (or
///   [characterTransform] uses the supplied `animationId`), the element manages
///   a deterministic logical ID that stays constant across unrelated rebuilds
///   and automatically advances whenever the target pose or tween parameters
///   change (e.g. multi-step `fromCurrent: true` keyframes).
class TweenText extends Widget {
  /// Text string to display.
  final String data;

  /// Foreground, background, and modifier styling for the painted cells.
  final Style style;

  /// Whether lines wrap to fit available width.
  final bool wrap;

  /// Horizontal text alignment within the layout bounds.
  final TextAlign textAlign;

  /// Optional maximum number of rendered lines.
  final int? maxLines;

  /// Optional static or starting [CellTransform] applied to painted graphemes.
  final CellTransform? transform;

  /// Optional finite [CellTween] attached to [transform] (or identity pose).
  final CellTween? tween;

  /// Optional per-character transform builder overriding [transform] and [tween].
  final TweenCharTransformBuilder? characterTransform;

  /// Whether each transformed character receives a distinct sequential `animationId`.
  final bool perCharacter;

  /// Optional explicit logical base `animationId` (`0..65535`).
  final int? animationId;

  /// Whether space characters (`' '`) also receive transforms (defaults to `false`).
  final bool includeSpaces;

  /// Creates a declarative [TweenText] widget.
  const TweenText(
    this.data, {
    super.key,
    this.style = Style.empty,
    this.wrap = true,
    this.textAlign = TextAlign.left,
    this.maxLines,
    this.transform,
    this.tween,
    this.characterTransform,
    this.perCharacter = false,
    this.animationId,
    this.includeSpaces = false,
  });

  @override
  Element createElement() => TweenTextElement(this);

  @override
  int getIntrinsicWidth(int height) {
    var maxWidth = 0;
    for (final line in data.split('\n')) {
      final w = measureStringWidth(line);
      if (w > maxWidth) maxWidth = w;
    }
    return maxWidth;
  }

  @override
  int getIntrinsicHeight(int width) {
    final lines = _layoutLines(data, wrap ? width : 999999, wrap: wrap);
    final count = lines.length;
    return maxLines != null ? min(maxLines!, count) : count;
  }
}

/// Element managing a [TweenText] widget and preserving stable logical
/// `animationId` state across unrelated rebuilds.
class TweenTextElement extends Element {
  List<List<String>> _cachedLines = const [];
  List<int> _lineWidths = const [];
  int? _autoAnimationId;
  _TweenTargetSignature? _lastSignature;

  /// Creates a [TweenTextElement] for [widget].
  TweenTextElement(TweenText super.widget);

  /// The current stable base logical `animationId` resolved by this element.
  int get resolvedBaseAnimationId {
    final tw = widget as TweenText;
    return _resolveBaseAnimationId(tw);
  }

  @override
  void mount(Element? parent) {
    super.mount(parent);
    _syncAutoAnimationId(widget as TweenText);
  }

  @override
  void update(Widget newWidget) {
    super.update(newWidget);
    _syncAutoAnimationId(newWidget as TweenText);
  }

  void _syncAutoAnimationId(TweenText tw) {
    final nextSig = _TweenTargetSignature.fromWidget(tw);
    if (_autoAnimationId == null) {
      _autoAnimationId = _initialAutoAnimationId(tw);
      _lastSignature = nextSig;
      return;
    }
    if (tw.animationId == null && _lastSignature != nextSig) {
      _autoAnimationId = _nextAnimationId(_autoAnimationId!);
      _lastSignature = nextSig;
    }
  }

  int _resolveBaseAnimationId(TweenText tw) {
    if (tw.animationId != null) {
      return tw.animationId!.clamp(0, CellTween.maxAnimationId);
    }
    final explicitTweenId = (tw.tween ?? tw.transform?.tween)?.animationId;
    if (explicitTweenId != null && explicitTweenId != 0) {
      return explicitTweenId.clamp(0, CellTween.maxAnimationId);
    }
    return _autoAnimationId ??= _initialAutoAnimationId(tw);
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final tw = widget as TweenText;
    final maxWidth = constraints.maxWidth == BoxConstraints.infinity
        ? 999999
        : constraints.maxWidth;

    _cachedLines = _layoutLines(tw.data, maxWidth, wrap: tw.wrap);
    final limit = tw.maxLines != null
        ? min(tw.maxLines!, _cachedLines.length)
        : _cachedLines.length;

    var measuredWidth = 0;
    _lineWidths = <int>[
      for (var i = 0; i < limit; i++) _measureLineWidth(_cachedLines[i]),
    ];
    for (final w in _lineWidths) {
      if (w > measuredWidth) measuredWidth = w;
    }
    return constraints.constrain(Size(measuredWidth, limit));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final tw = widget as TweenText;
    final area = Rect(offset.dx, offset.dy, size.width, size.height);
    final limit = tw.maxLines != null
        ? min(tw.maxLines!, min(area.height, _cachedLines.length))
        : min(area.height, _cachedLines.length);
    final baseAid = _resolveBaseAnimationId(tw);
    final baseTransform = _composeBaseTransform(tw);

    var charOrdinal = 0;
    for (var y = 0; y < limit; y++) {
      final line = _cachedLines[y];
      final lineWidth = _lineWidths[y];
      final startX = _alignStartX(tw.textAlign, area.width, lineWidth);
      charOrdinal = _paintLine(
        buffer,
        tw,
        line,
        area.x + startX,
        area.y + y,
        area.x + area.width,
        baseTransform,
        baseAid,
        charOrdinal,
      );
    }
  }

  int _paintLine(
    Buffer buffer,
    TweenText tw,
    List<String> line,
    int startX,
    int y,
    int maxX,
    CellTransform? baseTransform,
    int baseAid,
    int charOrdinal,
  ) {
    var col = startX;
    var ordinal = charOrdinal;
    final fg = tw.style.foreground?.argb ?? 0;
    final bg = tw.style.background?.argb ?? 0;
    final mods = tw.style.modifiers;
    final ulColor = tw.style.underlineColor?.argb ?? 0;
    final uri = tw.style.uri;

    for (final grapheme in line) {
      final w = graphemeWidth(grapheme);
      if (w <= 0) continue;
      if (col + w > maxX) break;

      buffer.setAttributes(
        col,
        y,
        char: grapheme,
        fg: fg,
        bg: bg,
        modifiers: mods,
        underlineColor: ulColor,
        uri: uri,
      );

      if (grapheme != ' ' || tw.includeSpaces) {
        _applyGraphemeTransform(
          buffer,
          tw,
          baseTransform,
          col,
          y,
          ordinal,
          grapheme,
          baseAid,
        );
        ordinal++;
      }
      col += w;
    }
    return ordinal;
  }

  static void _applyGraphemeTransform(
    Buffer buffer,
    TweenText tw,
    CellTransform? baseTransform,
    int col,
    int y,
    int ordinal,
    String grapheme,
    int baseAid,
  ) {
    final charAid = tw.perCharacter
        ? _offsetAnimationId(baseAid, ordinal)
        : baseAid;
    final resolved = _resolveCharTransform(
      tw,
      baseTransform,
      ordinal,
      grapheme,
      charAid,
    );
    if (resolved != null && !resolved.isIdentity) {
      buffer.setCellTransform(col, y, resolved);
    }
  }

  static CellTransform? _composeBaseTransform(TweenText tw) {
    if (tw.tween == null) return tw.transform;
    final base = tw.transform ?? CellTransform.identity;
    return base.copyWith(tween: tw.tween);
  }

  static CellTransform? _resolveCharTransform(
    TweenText tw,
    CellTransform? baseTransform,
    int charIndex,
    String grapheme,
    int charAid,
  ) {
    if (tw.characterTransform != null) {
      return tw.characterTransform!(charIndex, grapheme, charAid);
    }
    if (baseTransform == null) return null;
    final tween = baseTransform.tween;
    if (tween == null) return baseTransform;
    if (tween.animationId == charAid) return baseTransform;
    return baseTransform.copyWith(tween: tween.copyWith(animationId: charAid));
  }
}

final class _TweenTargetSignature {
  final CellTransform? transform;
  final CellTween? tween;

  const _TweenTargetSignature(this.transform, this.tween);

  factory _TweenTargetSignature.fromWidget(TweenText tw) =>
      _TweenTargetSignature(tw.transform, tw.tween);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _TweenTargetSignature &&
          other.transform == transform &&
          other.tween == tween;

  @override
  int get hashCode => Object.hash(transform, tween);
}

int _initialAutoAnimationId(TweenText tw) {
  final seedSource = switch (tw.key) {
    final ValueKey<Object?> vk => 'k:${vk.value}',
    _ => 't:${tw.data}',
  };
  var hash = 0x811C9DC5;
  for (var i = 0; i < seedSource.length; i++) {
    hash ^= seedSource.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0x7FFFFFFF;
  }
  return (hash % 0x7FFF) + 1;
}

int _nextAnimationId(int current) =>
    current >= CellTween.maxAnimationId ? 1 : current + 1;

int _offsetAnimationId(int base, int delta) {
  final raw = base + delta;
  if (raw <= CellTween.maxAnimationId) return raw;
  return ((raw - 1) % CellTween.maxAnimationId) + 1;
}

int _alignStartX(TextAlign align, int areaWidth, int lineWidth) =>
    switch (align) {
      TextAlign.left || TextAlign.justify => 0,
      TextAlign.right => max(0, areaWidth - lineWidth),
      TextAlign.center => max(0, (areaWidth - lineWidth) ~/ 2),
    };

int _measureLineWidth(List<String> graphemes) {
  var width = 0;
  for (final g in graphemes) {
    width += graphemeWidth(g);
  }
  return width;
}

List<List<String>> _layoutLines(
  String text,
  int maxWidth, {
  required bool wrap,
}) {
  if (maxWidth <= 0) return const [];
  if (!wrap) {
    return [
      for (final rawLine in text.split('\n'))
        _clipGraphemes(rawLine.characters.toList(), maxWidth),
    ];
  }
  final lines = <List<String>>[];
  for (final paragraph in text.split('\n')) {
    _wrapParagraph(paragraph, maxWidth, lines);
  }
  return lines;
}

List<String> _clipGraphemes(List<String> chars, int maxWidth) {
  final out = <String>[];
  var width = 0;
  for (final ch in chars) {
    final w = graphemeWidth(ch);
    if (width + w > maxWidth) break;
    out.add(ch);
    width += w;
  }
  return out;
}

void _wrapParagraph(String paragraph, int maxWidth, List<List<String>> lines) {
  if (paragraph.isEmpty) {
    lines.add(const []);
    return;
  }
  final words = paragraph.split(' ');
  var current = <String>[];
  var currentWidth = 0;

  for (final word in words) {
    if (word.isEmpty) continue;
    final graphemes = word.characters.toList();
    final wordWidth = _measureLineWidth(graphemes);
    if (current.isNotEmpty && currentWidth + 1 + wordWidth <= maxWidth) {
      current
        ..add(' ')
        ..addAll(graphemes);
      currentWidth += 1 + wordWidth;
      continue;
    }
    if (current.isNotEmpty) {
      lines.add(current);
      current = <String>[];
      currentWidth = 0;
    }
    if (wordWidth <= maxWidth) {
      current = graphemes;
      currentWidth = wordWidth;
    } else {
      current = _appendSplitWord(graphemes, maxWidth, lines);
      currentWidth = _measureLineWidth(current);
    }
  }
  if (current.isNotEmpty) {
    lines.add(current);
  }
}

List<String> _appendSplitWord(
  List<String> graphemes,
  int maxWidth,
  List<List<String>> lines,
) {
  var chunk = <String>[];
  var chunkWidth = 0;
  for (final g in graphemes) {
    final w = graphemeWidth(g);
    if (chunk.isNotEmpty && chunkWidth + w > maxWidth) {
      lines.add(chunk);
      chunk = <String>[];
      chunkWidth = 0;
    }
    chunk.add(g);
    chunkWidth += w;
  }
  return chunk;
}
