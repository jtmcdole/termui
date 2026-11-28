import 'dart:typed_data';

import 'kitty_medium.dart';

export 'kitty_medium.dart';

/// Returns whether the current platform supports reading Kitty medium [medium]
/// (`'t'` temp file, `'s'` POSIX shared memory, or `'f'` regular file).
bool platformSupportsKittyMedium(String medium) => false;

/// Reads (and optionally unlinks for `t=t`/`t=s`) a local Kitty medium payload
/// on `dart:io` platforms. Always returns [KittyMediumReadUnsupported] on Web.
KittyMediumReadResult readPlatformKittyMedium(
  String medium,
  Uint8List encodedPathBytes, {
  required int maxBytes,
  int offset = 0,
  int? size,
  bool unlink = true,
  bool Function(Uint8List bytes)? shouldUnlink,
}) => const KittyMediumReadUnsupported();
