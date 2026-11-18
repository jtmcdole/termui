import 'dart:ui' show Color, Path;

/// Geometry and label metrics for the version badge baked into the `fterm` SVG.
typedef FtermVersionBadgeMetrics = ({
  String label,
  double left,
  double top,
  double width,
  double height,
  double radius,
});

/// Computes shared geometry for the bottom-right squircle version pill inside
/// the `1024x1024` `web/favicon.svg` artwork coordinate space.
FtermVersionBadgeMetrics computeFtermVersionBadgeMetrics(String version) {
  final trimmed = version.trim();
  final normalized = trimmed.isEmpty ? '0.0.0-dev' : trimmed;
  final label = normalized.startsWith('v') ? normalized : 'v$normalized';
  final width = (label.length * 56.0 + 124.0).clamp(400.0, 560.0);
  const height = 156.0;
  const radius = height / 2;
  const right = 920.0;
  const bottom = 916.0;
  return (
    label: label,
    left: right - width,
    top: bottom - height,
    width: width,
    height: height,
    radius: radius,
  );
}

String _escapeXmlText(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// Bakes a crisp bottom-right version pill into [rawSvg] XML inside the main
/// icon transform group so exported SVGs match the rendered About emblem.
String bakeVersionIntoFtermSvg(String rawSvg, {required String version}) {
  final m = computeFtermVersionBadgeMetrics(version);
  final centerX = (m.left + m.width / 2).toStringAsFixed(1);
  final centerY = (m.top + m.height / 2 + 4.0).toStringAsFixed(1);
  final left = m.left.toStringAsFixed(1);
  final top = m.top.toStringAsFixed(1);
  final width = m.width.toStringAsFixed(1);
  final height = m.height.toStringAsFixed(1);
  final radius = m.radius.toStringAsFixed(1);
  final escaped = _escapeXmlText(m.label);

  final badgeXml =
      '    <g id="ftermVersionBadge">\n'
      '      <rect x="$left" y="$top" width="$width" height="$height" '
      'rx="$radius" ry="$radius" fill="#0D1017" fill-opacity="0.86" '
      'stroke="#62D196" stroke-opacity="0.48" stroke-width="8"/>\n'
      '      <text x="$centerX" y="$centerY" '
      'font-family="Cascadia Mono, monospace" font-size="80" font-weight="700" '
      'text-anchor="middle" dominant-baseline="central" fill="#86F2B8">'
      '$escaped</text>\n'
      '    </g>\n';

  final svgCloseIndex = rawSvg.lastIndexOf('</svg>');
  if (svgCloseIndex < 0) return '$rawSvg\n$badgeXml';

  final groupCloseIndex = rawSvg.lastIndexOf('</g>', svgCloseIndex);
  if (groupCloseIndex >= 0) {
    return '${rawSvg.substring(0, groupCloseIndex)}'
        '$badgeXml'
        '${rawSvg.substring(groupCloseIndex)}';
  }
  return '${rawSvg.substring(0, svgCloseIndex)}'
      '$badgeXml'
      '${rawSvg.substring(svgCloseIndex)}';
}

/// Vector scene extracted from `apps/fterm/web/favicon.svg`.
final class FtermLogoScene {
  static const String _defaultFStemData =
      'M 468 268 C 430 218, 360 228, 340 318 L 264 704 C 248 786, 184 808, 146 770';
  static const String _defaultFCrossbarData = 'M 206 448 L 416 448';
  static const String _defaultPromptChevronData =
      'M 576 382 L 802 522 L 576 662';

  static const List<Color> _defaultBgStops = [
    Color(0xFF1E2430),
    Color(0xFF14171F),
    Color(0xFF0D1017),
  ];
  static const List<Color> _defaultRimStops = [
    Color(0x38FFFFFF),
    Color(0x1F5294E2),
    Color(0x7A000000),
  ];
  static const List<Color> _defaultFStops = [
    Color(0xFFF6FAFF),
    Color(0xFFCEDCEB),
  ];
  static const List<Color> _defaultGtStops = [
    Color(0xFF86F2B8),
    Color(0xFF62D196),
    Color(0xFF3DB87A),
  ];

  static final RegExp _pathPattern = RegExp(r'<path[^>]*\bd="([^"]+)"');
  static final RegExp _pathTokenPattern = RegExp(r'[MLC]|-?\d+(?:\.\d+)?');
  static final RegExp _stopPattern = RegExp(
    r'<stop[^>]*stop-color="([^"]+)"(?:[^>]*stop-opacity="([^"]+)")?',
  );

  /// Squircle background linear gradient stops.
  final List<Color> bgStops;

  /// Squircle outer rim gradient stops.
  final List<Color> rimStops;

  /// Florin `f` glyph gradient stops.
  final List<Color> fStops;

  /// Prompt `>` glyph gradient stops.
  final List<Color> gtStops;

  /// Florin `f` curved stem path inside the `1024x1024` viewBox.
  final Path fStemPath;

  /// Florin `f` horizontal crossbar path inside the `1024x1024` viewBox.
  final Path fCrossbarPath;

  /// Prompt `>` chevron path inside the `1024x1024` viewBox.
  final Path promptChevronPath;

  /// Creates an immutable [FtermLogoScene].
  const FtermLogoScene({
    required this.bgStops,
    required this.rimStops,
    required this.fStops,
    required this.gtStops,
    required this.fStemPath,
    required this.fCrossbarPath,
    required this.promptChevronPath,
  });

  /// Synchronous default scene matching `apps/fterm/web/favicon.svg`.
  factory FtermLogoScene.fallback() => FtermLogoScene(
    bgStops: _defaultBgStops,
    rimStops: _defaultRimStops,
    fStops: _defaultFStops,
    gtStops: _defaultGtStops,
    fStemPath: parseSvgPath(_defaultFStemData),
    fCrossbarPath: parseSvgPath(_defaultFCrossbarData),
    promptChevronPath: parseSvgPath(_defaultPromptChevronData),
  );

  /// Parses paths and gradient stops from [svgXml], falling back cleanly for
  /// omitted tags.
  factory FtermLogoScene.parse(String svgXml) {
    final paths = [
      for (final match in _pathPattern.allMatches(svgXml)) match.group(1)!,
    ];
    final stemData = paths.isNotEmpty ? paths[0] : _defaultFStemData;
    final barData = paths.length > 1 ? paths[1] : _defaultFCrossbarData;
    final chevronData = paths.length > 2 ? paths[2] : _defaultPromptChevronData;

    return FtermLogoScene(
      bgStops: _extractStopColors(svgXml, 'bgGrad', _defaultBgStops),
      rimStops: _extractStopColors(svgXml, 'rimGrad', _defaultRimStops),
      fStops: _extractStopColors(svgXml, 'fGrad', _defaultFStops),
      gtStops: _extractStopColors(svgXml, 'gtGrad', _defaultGtStops),
      fStemPath: parseSvgPath(stemData),
      fCrossbarPath: parseSvgPath(barData),
      promptChevronPath: parseSvgPath(chevronData),
    );
  }

  /// Parses absolute SVG `M`, `L`, and `C` path commands into a [Path].
  static Path parseSvgPath(String d) {
    final tokens = [
      for (final match in _pathTokenPattern.allMatches(d)) match.group(0)!,
    ];
    final path = Path();
    var index = 0;
    var command = '';

    double nextNum() => double.parse(tokens[index++]);

    while (index < tokens.length) {
      final token = tokens[index];
      if (token == 'M' || token == 'L' || token == 'C') {
        command = token;
        index++;
        continue;
      }
      switch (command) {
        case 'M':
          path.moveTo(nextNum(), nextNum());
          command = 'L';
        case 'L':
          path.lineTo(nextNum(), nextNum());
        case 'C':
          path.cubicTo(
            nextNum(),
            nextNum(),
            nextNum(),
            nextNum(),
            nextNum(),
            nextNum(),
          );
        default:
          index++;
      }
    }
    return path;
  }

  static List<Color> _extractStopColors(
    String svgXml,
    String gradientId,
    List<Color> fallback,
  ) {
    final blockPattern = RegExp(
      '<(?:linear|radial)Gradient[^>]*id="$gradientId"[^>]*>([\\s\\S]*?)</(?:linear|radial)Gradient>',
    );
    final block = blockPattern.firstMatch(svgXml)?.group(1);
    if (block == null) return fallback;

    final parsed = <Color>[];
    for (final match in _stopPattern.allMatches(block)) {
      final hex = match.group(1);
      if (hex == null) continue;
      final opacity = double.tryParse(match.group(2) ?? '') ?? 1.0;
      final color = _tryParseHexColor(hex, opacity: opacity);
      if (color != null) parsed.add(color);
    }
    return parsed.length == fallback.length ? parsed : fallback;
  }

  static Color? _tryParseHexColor(String raw, {required double opacity}) {
    final normalized = raw.replaceFirst('#', '').trim();
    if (normalized.length != 6) return null;
    final rgb = int.tryParse(normalized, radix: 16);
    if (rgb == null) return null;
    final alpha = (opacity.clamp(0.0, 1.0) * 255).round();
    return Color((alpha << 24) | (rgb & 0xFFFFFF));
  }
}
