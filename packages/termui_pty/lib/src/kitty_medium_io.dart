import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'kitty_medium.dart';
import 'kitty_shm_macos.dart';

export 'kitty_medium.dart';

final RegExp _pathSeparatorRegex = RegExp(r'[/\\]');

/// Returns whether the current `dart:io` platform supports reading Kitty
/// transmission medium [medium] (`'t'` temp file or `'s'` POSIX shared memory).
bool platformSupportsKittyMedium(String medium) => switch (medium) {
  't' => true,
  's' => Platform.isLinux || Platform.isMacOS,
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

bool _isUnderAllowedTempRoot(String path) {
  final normalized = _normalizePrefix(path);
  for (final prefix in _canonicalAllowedTempPrefixes()) {
    if (normalized.startsWith(prefix)) return true;
  }
  return false;
}

bool _isUncOrDoubleSlash(String path) =>
    path.length >= 2 &&
    (path[0] == r'\' || path[0] == '/') &&
    (path[1] == r'\' || path[1] == '/');

({String? path, bool notFound}) _resolveTempPath(String decoded) {
  if (_hasParentTraversal(decoded) ||
      _isUncOrDoubleSlash(decoded) ||
      !File(decoded).isAbsolute ||
      !decoded.contains('tty-graphics-protocol')) {
    return (path: null, notFound: false);
  }
  final parent = File(decoded).parent;
  if (!parent.existsSync()) {
    return (path: null, notFound: _isUnderAllowedTempRoot(parent.path));
  }
  final String canonicalParent;
  try {
    canonicalParent = parent.resolveSymbolicLinksSync();
  } on FileSystemException {
    return (path: null, notFound: false);
  }
  if (!_isUnderAllowedTempRoot(canonicalParent)) {
    return (path: null, notFound: false);
  }
  final leaf = decoded.split(_pathSeparatorRegex).last;
  if (leaf.isEmpty ||
      leaf == '.' ||
      leaf == '..' ||
      (Platform.isWindows && leaf.contains(':'))) {
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

void _deleteBestEffort(File file) {
  try {
    file.deleteSync();
  } on FileSystemException {
    // Best-effort unlink per Kitty Graphics Protocol spec.
  }
}

/// Reads a Kitty Graphics Protocol temp file (`t=t`) or Linux/macOS POSIX
/// shared-memory object (`t=s`), enforcing [maxBytes] and safety checks.
///
/// When [unlink] is `true`, the backing file or shared-memory object is
/// unlinked after a successful read.
KittyMediumReadResult readPlatformKittyMedium(
  String medium,
  Uint8List encodedPathBytes, {
  required int maxBytes,
  int offset = 0,
  int? size,
  bool unlink = true,
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
  if (medium == 's' && Platform.isMacOS) {
    return readMacosPosixShm(
      decoded,
      maxBytes: maxBytes,
      offset: offset,
      size: size,
      unlink: unlink,
    );
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
  final KittyMediumReadResult result;
  try {
    result = _readFileSlice(
      file,
      maxBytes: maxBytes,
      offset: offset,
      size: size,
    );
  } on FileSystemException {
    return const KittyMediumReadInvalid();
  }
  if (unlink && result is KittyMediumReadOk) {
    _deleteBestEffort(file);
  }
  return result;
}
