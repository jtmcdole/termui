import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'kitty_medium.dart';
import 'kitty_medium_posix.dart';
import 'kitty_shm_macos.dart';

export 'kitty_medium.dart';

final RegExp _pathSeparatorRegex = RegExp(r'[/\\]');

typedef _ResolvedKittyTarget = ({
  String? rootDir,
  List<String> relativeSegments,
  String? leafName,
  String? fullPath,
  bool notFound,
});

const _ResolvedKittyTarget _invalidTarget = (
  rootDir: null,
  relativeSegments: <String>[],
  leafName: null,
  fullPath: null,
  notFound: false,
);

const _ResolvedKittyTarget _notFoundTarget = (
  rootDir: null,
  relativeSegments: <String>[],
  leafName: null,
  fullPath: null,
  notFound: true,
);

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

String? _matchingAllowedTempPrefix(String path) {
  final normalized = _normalizePrefix(path);
  for (final prefix in _canonicalAllowedTempPrefixes()) {
    if (normalized.startsWith(prefix)) return prefix;
  }
  return null;
}

bool _isUncOrDoubleSlash(String path) =>
    path.length >= 2 &&
    (path[0] == r'\' || path[0] == '/') &&
    (path[1] == r'\' || path[1] == '/');

_ResolvedKittyTarget _resolveTempTarget(String decoded) {
  if (_hasParentTraversal(decoded) ||
      _isUncOrDoubleSlash(decoded) ||
      !File(decoded).isAbsolute ||
      !decoded.contains('tty-graphics-protocol')) {
    return _invalidTarget;
  }
  final parent = File(decoded).parent;
  if (!parent.existsSync()) {
    return _matchingAllowedTempPrefix(parent.path) != null
        ? _notFoundTarget
        : _invalidTarget;
  }
  final String canonicalParent;
  try {
    canonicalParent = parent.resolveSymbolicLinksSync();
  } on FileSystemException {
    return _invalidTarget;
  }
  final matchedPrefix = _matchingAllowedTempPrefix(canonicalParent);
  if (matchedPrefix == null) {
    return _invalidTarget;
  }
  final leaf = decoded.split(_pathSeparatorRegex).last;
  if (leaf.isEmpty ||
      leaf == '.' ||
      leaf == '..' ||
      (Platform.isWindows && leaf.contains(':'))) {
    return _invalidTarget;
  }
  final sep = Platform.pathSeparator;
  final fullPath = canonicalParent.endsWith(sep)
      ? '$canonicalParent$leaf'
      : '$canonicalParent$sep$leaf';
  // Enforce the Kitty spec marker on the canonicalized path so a symlink
  // inside /tmp cannot smuggle an unrelated temp file past the check.
  if (!fullPath.contains('tty-graphics-protocol')) {
    return _invalidTarget;
  }
  final normalizedParent = _normalizePrefix(canonicalParent);
  final relativePart = normalizedParent.substring(matchedPrefix.length);
  final relativeSegments = relativePart
      .split(_pathSeparatorRegex)
      .where((segment) => segment.isNotEmpty)
      .toList();
  final rootDir = matchedPrefix.length > 1 && matchedPrefix.endsWith(sep)
      ? matchedPrefix.substring(0, matchedPrefix.length - 1)
      : matchedPrefix;
  return (
    rootDir: rootDir,
    relativeSegments: relativeSegments,
    leafName: leaf,
    fullPath: fullPath,
    notFound: false,
  );
}

_ResolvedKittyTarget _resolveShmTarget(String decoded) {
  if (!Platform.isLinux || !isAllowedKittyShmName(decoded)) {
    return _invalidTarget;
  }
  final clean = decoded.startsWith('/') ? decoded.substring(1) : decoded;
  return (
    rootDir: '/dev/shm',
    relativeSegments: const <String>[],
    leafName: clean,
    fullPath: '/dev/shm/$clean',
    notFound: false,
  );
}

_ResolvedKittyTarget _resolveTarget(String medium, String decoded) =>
    switch (medium) {
      't' => _resolveTempTarget(decoded),
      's' => _resolveShmTarget(decoded),
      _ => _invalidTarget,
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

KittyMediumReadResult _readWindowsKittyFile(
  String targetPath, {
  required int maxBytes,
  required int offset,
  required int? size,
  required bool unlink,
  required bool Function(Uint8List bytes)? shouldUnlink,
}) {
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
  if (unlink &&
      result is KittyMediumReadOk &&
      (shouldUnlink == null || shouldUnlink(result.bytes))) {
    _deleteBestEffort(file);
  }
  return result;
}

/// Reads a Kitty Graphics Protocol temp file (`t=t`) or Linux/macOS POSIX
/// shared-memory object (`t=s`), enforcing [maxBytes] and safety checks.
///
/// When [unlink] is `true`, the backing file or shared-memory object is
/// unlinked after a successful read (and after [shouldUnlink], if provided,
/// returns `true`).
KittyMediumReadResult readPlatformKittyMedium(
  String medium,
  Uint8List encodedPathBytes, {
  required int maxBytes,
  int offset = 0,
  int? size,
  bool unlink = true,
  bool Function(Uint8List bytes)? shouldUnlink,
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
      shouldUnlink: shouldUnlink,
    );
  }

  final resolved = _resolveTarget(medium, decoded);
  if (resolved.notFound) return const KittyMediumReadNotFound();
  final targetPath = resolved.fullPath;
  if (targetPath == null) return const KittyMediumReadInvalid();

  if (!Platform.isWindows) {
    return readPosixKittyFile(
      rootDir: resolved.rootDir!,
      relativeSegments: resolved.relativeSegments,
      leafName: resolved.leafName!,
      maxBytes: maxBytes,
      offset: offset,
      size: size,
      unlink: unlink,
      shouldUnlink: shouldUnlink,
    );
  }

  return _readWindowsKittyFile(
    targetPath,
    maxBytes: maxBytes,
    offset: offset,
    size: size,
    unlink: unlink,
    shouldUnlink: shouldUnlink,
  );
}
