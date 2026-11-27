import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'kitty_medium.dart';

export 'kitty_medium.dart';

final RegExp _pathSeparatorRegex = RegExp(r'[/\\]');

/// Returns whether the current `dart:io` platform supports reading Kitty
/// transmission medium [medium] (`'t'` temp file or `'s'` POSIX shared memory).
bool platformSupportsKittyMedium(String medium) => switch (medium) {
  't' => true,
  's' => Platform.isLinux,
  _ => false,
};

bool _hasParentTraversal(String path) =>
    path.split(_pathSeparatorRegex).contains('..');

String _normalizePrefix(String raw) {
  final sep = Platform.pathSeparator;
  final normalized = Platform.isWindows
      ? raw.replaceAll('/', sep).toLowerCase()
      : raw;
  return normalized.endsWith(sep) ? normalized : '$normalized$sep';
}

List<String> _canonicalAllowedTempPrefixes() {
  final candidates = <String>[
    Directory.systemTemp.path,
    if (!Platform.isWindows) '/tmp',
    if (!Platform.isWindows) '/var/tmp',
    if (Platform.isMacOS) '/private/tmp',
    if (Platform.isLinux) '/dev/shm',
  ];
  final prefixes = <String>[];
  for (final dirPath in candidates) {
    try {
      final resolved = Directory(dirPath).resolveSymbolicLinksSync();
      prefixes.add(_normalizePrefix(resolved));
    } on FileSystemException {
      // Skip non-existent temp roots on this platform.
    }
  }
  return prefixes;
}

bool _isCanonicalParentAllowed(String canonicalParent) {
  final normalizedParent = _normalizePrefix(canonicalParent);
  for (final prefix in _canonicalAllowedTempPrefixes()) {
    if (normalizedParent.startsWith(prefix)) return true;
  }
  return false;
}

bool _isRawPathUnderTempRoot(String rawPath) {
  final normalized = _normalizePrefix(rawPath);
  for (final prefix in _canonicalAllowedTempPrefixes()) {
    if (normalized.startsWith(prefix)) return true;
  }
  return false;
}

({String? path, bool notFound}) _resolveTempPath(String decoded) {
  if (_hasParentTraversal(decoded)) return (path: null, notFound: false);
  final parent = File(decoded).parent;
  if (!parent.existsSync()) {
    final underTemp =
        decoded.contains('tty-graphics-protocol') &&
        _isRawPathUnderTempRoot(parent.path);
    return (path: null, notFound: underTemp);
  }
  final String canonicalParent;
  try {
    canonicalParent = parent.resolveSymbolicLinksSync();
  } on FileSystemException {
    return (path: null, notFound: false);
  }
  if (!_isCanonicalParentAllowed(canonicalParent)) {
    return (path: null, notFound: false);
  }
  final leaf = decoded.split(_pathSeparatorRegex).last;
  if (leaf.isEmpty || leaf == '.' || leaf == '..') {
    return (path: null, notFound: false);
  }
  final sep = Platform.pathSeparator;
  final fullPath = canonicalParent.endsWith(sep)
      ? '$canonicalParent$leaf'
      : '$canonicalParent$sep$leaf';
  // Enforce the Kitty spec marker on the canonicalized path so a symlink
  // inside /tmp cannot smuggle an unrelated temp file past the check.
  if (!fullPath.contains('tty-graphics-protocol')) {
    return (path: null, notFound: false);
  }
  return (path: fullPath, notFound: false);
}

String? _resolveShmPath(String decoded) {
  if (!Platform.isLinux) return null;
  final clean = decoded.startsWith('/') ? decoded.substring(1) : decoded;
  if (clean.isEmpty ||
      clean.contains(_pathSeparatorRegex) ||
      clean == '.' ||
      clean == '..') {
    return null;
  }
  return '/dev/shm/$clean';
}

({String? path, bool notFound}) _resolveTargetPath(
  String medium,
  String decoded,
) => switch (medium) {
  't' => _resolveTempPath(decoded),
  's' => (path: _resolveShmPath(decoded), notFound: false),
  _ => (path: null, notFound: false),
};

KittyMediumReadResult _readFileSlice(
  File file, {
  required int maxBytes,
  required int offset,
  required int? size,
}) {
  final raf = file.openSync();
  try {
    final fileLen = raf.lengthSync();
    if (offset > fileLen) return const KittyMediumReadInvalid();
    final available = fileLen - offset;
    final effectiveSize = (size != null && size > 0) ? size : available;
    final readLen = math.min(effectiveSize, available);
    if (readLen > maxBytes) return const KittyMediumReadTooLarge();
    if (readLen == 0) return KittyMediumReadOk(Uint8List(0));
    if (offset > 0) raf.setPositionSync(offset);
    return KittyMediumReadOk(raf.readSync(readLen));
  } finally {
    raf.closeSync();
  }
}

/// Reads and unlinks a Kitty Graphics Protocol temp file (`t=t`) or Linux
/// POSIX shared-memory object (`t=s`), enforcing [maxBytes] and safety checks.
KittyMediumReadResult readPlatformKittyMedium(
  String medium,
  Uint8List encodedPathBytes, {
  required int maxBytes,
  int offset = 0,
  int? size,
}) {
  if (!platformSupportsKittyMedium(medium)) {
    return const KittyMediumReadUnsupported();
  }
  if (offset < 0 || (size != null && size < 0)) {
    return const KittyMediumReadInvalid();
  }

  final String decoded;
  try {
    decoded = utf8.decode(encodedPathBytes);
  } on FormatException {
    return const KittyMediumReadInvalid();
  }
  if (decoded.isEmpty || decoded.contains('\x00')) {
    return const KittyMediumReadInvalid();
  }

  final resolved = _resolveTargetPath(medium, decoded);
  if (resolved.notFound) return const KittyMediumReadNotFound();
  final targetPath = resolved.path;
  if (targetPath == null) return const KittyMediumReadInvalid();

  final entityType = FileSystemEntity.typeSync(targetPath, followLinks: false);
  if (entityType == FileSystemEntityType.notFound) {
    return const KittyMediumReadNotFound();
  }
  if (entityType != FileSystemEntityType.file) {
    return const KittyMediumReadInvalid();
  }

  final file = File(targetPath);
  try {
    return _readFileSlice(file, maxBytes: maxBytes, offset: offset, size: size);
  } on FileSystemException {
    return const KittyMediumReadInvalid();
  } finally {
    try {
      file.deleteSync();
    } on FileSystemException {
      // Best-effort unlink per Kitty Graphics Protocol spec.
    }
  }
}
