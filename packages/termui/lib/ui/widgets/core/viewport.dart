import 'package:characters/characters.dart';
import 'dart:math';
import 'dart:typed_data';
import 'package:termui/termui.dart';

/// A clipped view into a rectangular region of a parent [Buffer].
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
      ) {
    if (this.bounds.width > 0 && this.bounds.height > 0) {
      parent.registerSelectableRegion(this.bounds);
    }
  }

  @override
  bool get defaultBlend => parent.defaultBlend;

  @override
  bool get hasUnderlineColors => parent.hasUnderlineColors;

  @override
  bool get hasUris => parent.hasUris;

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
  int getUnderlineColor(int x, int y) {
    if (x < 0 || x >= bounds.width || y < 0 || y >= bounds.height) return 0;
    return parent.getUnderlineColor(bounds.x + x, bounds.y + y);
  }

  @override
  void setUnderlineColor(int x, int y, int ulColor) {
    if (x >= 0 && x < bounds.width && y >= 0 && y < bounds.height) {
      parent.setUnderlineColor(bounds.x + x, bounds.y + y, ulColor);
    }
  }

  @override
  String? getUri(int x, int y) {
    if (x < 0 || x >= bounds.width || y < 0 || y >= bounds.height) return null;
    return parent.getUri(bounds.x + x, bounds.y + y);
  }

  @override
  void setUri(int x, int y, String? uri) {
    if (x >= 0 && x < bounds.width && y >= 0 && y < bounds.height) {
      parent.setUri(bounds.x + x, bounds.y + y, uri);
    }
  }

  @override
  int getUnderlineColorAt(int cellIdx) => throw UnsupportedError(
    'Flat cell index access not supported on Viewport',
  );

  @override
  void setUnderlineColorAt(int cellIdx, int ulColor) => throw UnsupportedError(
    'Flat cell index access not supported on Viewport',
  );

  @override
  String? getUriAt(int cellIdx) => throw UnsupportedError(
    'Flat cell index access not supported on Viewport',
  );

  @override
  void setUriAt(int cellIdx, String? uri) => throw UnsupportedError(
    'Flat cell index access not supported on Viewport',
  );

  @override
  void copyCellAuxAt(Buffer source, int dstIdx, int srcIdx) =>
      throw UnsupportedError(
        'Flat cell index access not supported on Viewport',
      );

  @override
  void clearCellAuxRange(int start, int end) => throw UnsupportedError(
    'Flat cell index access not supported on Viewport',
  );

  @override
  void copyCellAuxRangeFrom(
    Buffer source,
    int dstStart,
    int srcStart,
    int count,
  ) => throw UnsupportedError(
    'Flat cell index access not supported on Viewport',
  );

  @override
  Uint32List? sliceUnderlineColors(int start, int end) =>
      throw UnsupportedError(
        'Flat cell index access not supported on Viewport',
      );

  @override
  List<String?>? sliceUris(int start, int end) => throw UnsupportedError(
    'Flat cell index access not supported on Viewport',
  );

  @override
  void writeCellAuxSlices(
    int dstStart,
    int count, {
    Uint32List? underlineColors,
    List<String?>? uris,
  }) => throw UnsupportedError(
    'Flat cell index access not supported on Viewport',
  );

  @override
  List<RegisteredEffect> get effects => parent.effects;

  @override
  List<Rect> get selectableRegions => parent.selectableRegions;

  @override
  void registerSelectableRegion(Rect region, {int zIndex = 0}) {
    if (region.width <= 0 || region.height <= 0) return;
    final clipped = bounds.intersect(
      Rect(
        bounds.x + region.x,
        bounds.y + region.y,
        region.width,
        region.height,
      ),
    );
    if (clipped.width > 0 && clipped.height > 0) {
      parent.registerSelectableRegion(clipped, zIndex: zIndex);
    }
  }

  @override
  int selectableRegionZIndexAt(int index) =>
      parent.selectableRegionZIndexAt(index);

  @override
  void registerKittyRegistry(Rect rect, KittyImageRegistry registry) {
    if (rect.width <= 0 || rect.height <= 0) return;
    final clipped = bounds.intersect(
      Rect(bounds.x + rect.x, bounds.y + rect.y, rect.width, rect.height),
    );
    if (clipped.width > 0 && clipped.height > 0) {
      parent.registerKittyRegistry(clipped, registry);
    }
  }

  @override
  KittyImageRegistry lookupKittyRegistry(int x, int y) {
    if (x < 0 || x >= bounds.width || y < 0 || y >= bounds.height) {
      return KittyImageRegistry.global;
    }
    return parent.lookupKittyRegistry(bounds.x + x, bounds.y + y);
  }

  @override
  KittyImageData? lookupKittyImage(int x, int y, int imageId) {
    if (x < 0 || x >= bounds.width || y < 0 || y >= bounds.height) return null;
    return parent.lookupKittyImage(bounds.x + x, bounds.y + y, imageId);
  }

  @override
  void propagateMetadataFrom(
    Buffer source, {
    int dx = 0,
    int dy = 0,
    Rect? clip,
    int? zIndex,
  }) {
    final vpClip = clip == null
        ? bounds
        : bounds.intersect(
            Rect(bounds.x + clip.x, bounds.y + clip.y, clip.width, clip.height),
          );
    if (vpClip.width <= 0 || vpClip.height <= 0) return;
    parent.propagateMetadataFrom(
      source,
      dx: bounds.x + dx,
      dy: bounds.y + dy,
      clip: vpClip,
      zIndex: zIndex,
    );
  }

  @override
  bool cellsEqual(int x, int y, Buffer other, int ox, int oy) =>
      getCharacter(x, y) == other.getCharacter(ox, oy) &&
      getForeground(x, y) == other.getForeground(ox, oy) &&
      getBackground(x, y) == other.getBackground(ox, oy) &&
      getModifiers(x, y) == other.getModifiers(ox, oy) &&
      getUnderlineColor(x, y) == other.getUnderlineColor(ox, oy) &&
      getUri(x, y) == other.getUri(ox, oy);

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
  void setCell(
    int x,
    int y,
    String char,
    int fg,
    int bg,
    int mod, {
    bool? blend,
    int underlineColor = 0,
    String? uri,
  }) {
    if (x >= 0 && x < bounds.width && y >= 0 && y < bounds.height) {
      parent.setCell(
        bounds.x + x,
        bounds.y + y,
        char,
        fg,
        bg,
        mod,
        blend: blend,
        underlineColor: underlineColor,
        uri: uri,
      );
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
    int? underlineColor,
    String? uri,
    bool? blend,
  }) {
    if (x < 0 || x >= bounds.width || y < 0 || y >= bounds.height) return;
    parent.setAttributes(
      bounds.x + x,
      bounds.y + y,
      char: char,
      fg: fg,
      bg: bg,
      modifiers: modifiers,
      underlineColor: underlineColor,
      uri: uri,
      blend: blend,
    );
  }

  @override
  void clear() {
    fillRect(
      Rect(0, 0, bounds.width, bounds.height),
      char: ' ',
      modifiers: Modifier.transparent,
      fg: 0,
      bg: 0,
      underlineColor: 0,
      uri: '',
      blend: false,
    );
  }

  @override
  void fillAttributes({
    String? char,
    int? fg,
    int? bg,
    int? modifiers,
    int? underlineColor,
    String? uri,
    bool? blend,
  }) {
    fillRect(
      Rect(0, 0, bounds.width, bounds.height),
      char: char,
      fg: fg,
      bg: bg,
      modifiers: modifiers,
      underlineColor: underlineColor,
      uri: uri,
      blend: blend,
    );
  }

  @override
  void fillRect(
    Rect rect, {
    String? char,
    int? fg,
    int? bg,
    int? modifiers,
    int? underlineColor,
    String? uri,
    bool? blend,
  }) {
    if (rect.width <= 0 || rect.height <= 0) return;
    final clipped = bounds.intersect(
      Rect(bounds.x + rect.x, bounds.y + rect.y, rect.width, rect.height),
    );
    if (clipped.width <= 0 || clipped.height <= 0) return;
    parent.fillRect(
      clipped,
      char: char,
      fg: fg,
      bg: bg,
      modifiers: modifiers,
      underlineColor: underlineColor,
      uri: uri,
      blend: blend,
    );
  }

  @override
  void drawCautionTape(Rect rect, int offsetX, int offsetY) {
    parent.drawCautionTape(
      Rect(bounds.x + rect.x, bounds.y + rect.y, rect.width, rect.height),
      bounds.x + offsetX,
      bounds.y + offsetY,
    );
  }

  @override
  void resize(int newWidth, int newHeight) {
    throw UnsupportedError('Cannot resize a Viewport');
  }

  @override
  void writeString(int x, int y, String text, Style style) {
    final startX = x;
    var currentX = x;
    var currentY = y;

    for (final char in text.characters) {
      if (char == '\n') {
        currentX = startX;
        currentY++;
        continue;
      }
      if (_isInBounds(currentX, currentY)) {
        currentX += _writeCharInBounds(currentX, currentY, char, style);
      } else {
        currentX += 1;
      }
    }
  }

  bool _isInBounds(int x, int y) =>
      x >= 0 && x < bounds.width && y >= 0 && y < bounds.height;

  void _clearOverwrittenWideChar(int x, int y) {
    final currentChar = parent.getCharacter(bounds.x + x, bounds.y + y);
    if (currentChar == '' && x - 1 >= 0) {
      final prevChar = parent.getCharacter(bounds.x + x - 1, bounds.y + y);
      if (isWideGrapheme(prevChar)) {
        parent.setAttributes(bounds.x + x - 1, bounds.y + y, char: ' ');
      }
    } else if (isWideGrapheme(currentChar) && x + 1 < bounds.width) {
      final nextChar = parent.getCharacter(bounds.x + x + 1, bounds.y + y);
      if (nextChar == '') {
        parent.setAttributes(bounds.x + x + 1, bounds.y + y, char: ' ');
      }
    }
  }

  void _clearNextWideFollower(int x, int y) {
    final nextChar = parent.getCharacter(bounds.x + x + 1, bounds.y + y);
    if (isWideGrapheme(nextChar) && x + 2 < bounds.width) {
      final nextNextChar = parent.getCharacter(bounds.x + x + 2, bounds.y + y);
      if (nextNextChar == '') {
        parent.setAttributes(bounds.x + x + 2, bounds.y + y, char: ' ');
      }
    }
  }

  int _writeCharInBounds(int x, int y, String char, Style style) {
    _clearOverwrittenWideChar(x, y);
    final isWide = isWideGrapheme(char);
    final fg = style.foreground?.argb ?? 0;
    final bg = style.background?.argb;
    final mod = style.modifiers;
    final ulColor = style.underlineColor?.argb ?? 0;
    final uri = style.uri ?? '';

    if (isWide && x == bounds.width - 1) {
      parent.setAttributes(
        bounds.x + x,
        bounds.y + y,
        char: ' ',
        fg: fg,
        bg: bg,
        modifiers: mod,
        underlineColor: ulColor,
        uri: uri,
      );
      return 1;
    }

    parent.setAttributes(
      bounds.x + x,
      bounds.y + y,
      char: char,
      fg: fg,
      bg: bg,
      modifiers: mod,
      underlineColor: ulColor,
      uri: uri,
    );
    if (!isWide) return 1;

    if (x + 1 < bounds.width) {
      _clearNextWideFollower(x, y);
      parent.setAttributes(
        bounds.x + x + 1,
        bounds.y + y,
        char: '',
        fg: fg,
        bg: bg,
        modifiers: mod,
        underlineColor: ulColor,
        uri: uri,
      );
    }
    return 2;
  }
}

/// Splits a [Rect] area into multiple sub-rectangles according to layout constraints.
