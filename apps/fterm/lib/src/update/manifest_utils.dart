import 'dart:convert';

import 'update_models.dart';

/// Name of the bundle-owned file manifest shipped inside Linux and Windows
/// `fterm` release archives.
const String kFtermManifestFileName = '.fterm-files.json';

/// Parses and validates a `.fterm-files.json` manifest string into sorted,
/// deduplicated, ancestor-pruned relative `/` paths.
///
/// Throws [UpdateException] if [rawJson] is malformed, empty, or contains any
/// unsafe path entry (leading `/`, `\`, `:`, `.`, `..`, or control characters).
List<String> parseManifestJson(String rawJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(rawJson);
  } on FormatException catch (e) {
    throw UpdateException('Invalid $kFtermManifestFileName JSON: ${e.message}');
  }
  if (decoded is! List<Object?>) {
    throw const UpdateException(
      'Invalid .fterm-files.json: expected a JSON array of relative paths.',
    );
  }
  final normalized = <String>[];
  for (final item in decoded) {
    if (item is! String) {
      throw const UpdateException(
        'Invalid .fterm-files.json: every manifest entry must be a string.',
      );
    }
    normalized.add(normalizeSafeRelativePath(item));
  }
  if (normalized.isEmpty) {
    throw const UpdateException(
      'Invalid .fterm-files.json: manifest is empty.',
    );
  }
  return deduplicateAndPruneAncestors(normalized);
}

/// Merges an optional [existing] bundle manifest with an [incoming] staged
/// manifest so retired files are backed up alongside updated and added files.
List<String> mergeUpdateManifests({
  List<String> existing = const [],
  required List<String> incoming,
}) {
  final combined = <String>[
    for (final entry in existing) normalizeSafeRelativePath(entry),
    for (final entry in incoming) normalizeSafeRelativePath(entry),
  ];
  if (combined.isEmpty) {
    throw const UpdateException('Merged update manifest cannot be empty.');
  }
  return deduplicateAndPruneAncestors(combined);
}

/// Validates and normalizes a relative bundle path to `/` separators with no
/// leading `./`, `/`, drive prefix, control characters, or `..` traversal.
String normalizeSafeRelativePath(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw const UpdateException('Bundle path entry cannot be empty.');
  }
  if (trimmed.startsWith('/') || trimmed.startsWith(r'\')) {
    throw UpdateException('Bundle path cannot be absolute: "$raw".');
  }
  for (var i = 0; i < trimmed.length; i++) {
    final unit = trimmed.codeUnitAt(i);
    if (unit < 0x20 || unit == 0x3A /* ':' */ || unit == 0x7F) {
      throw UpdateException('Bundle path contains invalid character: "$raw".');
    }
  }
  var slashNormalized = trimmed.replaceAll(r'\', '/');
  while (slashNormalized.endsWith('/')) {
    slashNormalized = slashNormalized.substring(0, slashNormalized.length - 1);
  }
  if (slashNormalized.isEmpty) {
    throw UpdateException('Bundle path resolves to root: "$raw".');
  }
  final segments = slashNormalized.split('/');
  for (final seg in segments) {
    if (seg.isEmpty || seg == '.' || seg == '..') {
      throw UpdateException('Unsafe bundle path segment in "$raw".');
    }
  }
  return segments.join('/');
}

/// Sorts [entries], removes duplicates, and drops child paths whose parent
/// directory is already present in [entries].
List<String> deduplicateAndPruneAncestors(Iterable<String> entries) {
  final sorted = entries.toSet().toList()..sort();
  final kept = <String>[];
  for (final candidate in sorted) {
    final coveredByAncestor = kept.any(
      (ancestor) =>
          candidate.length > ancestor.length &&
          candidate.startsWith(ancestor) &&
          candidate.codeUnitAt(ancestor.length) == 0x2F /* '/' */,
    );
    if (!coveredByAncestor) {
      kept.add(candidate);
    }
  }
  return List<String>.unmodifiable(kept);
}
