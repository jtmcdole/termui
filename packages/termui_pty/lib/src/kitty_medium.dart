import 'dart:typed_data';

/// Result of reading a local Kitty Graphics Protocol medium (`t=t`, `t=s`, or `t=f`).
sealed class KittyMediumReadResult {
  /// Creates a [KittyMediumReadResult].
  const KittyMediumReadResult();
}

/// Successfully read payload bytes from the local medium.
final class KittyMediumReadOk extends KittyMediumReadResult {
  /// Raw bytes read from the temp file or shared-memory object.
  final Uint8List bytes;

  /// Creates a successful read result with [bytes].
  const KittyMediumReadOk(this.bytes);
}

/// The referenced file or shared-memory object does not exist.
final class KittyMediumReadNotFound extends KittyMediumReadResult {
  /// Creates a not-found read result.
  const KittyMediumReadNotFound();
}

/// The referenced payload exceeds the allowed size limit.
final class KittyMediumReadTooLarge extends KittyMediumReadResult {
  /// Creates a payload-too-large read result.
  const KittyMediumReadTooLarge();
}

/// The path/name is invalid, unsafe, or cannot be read.
final class KittyMediumReadInvalid extends KittyMediumReadResult {
  /// Creates an invalid-payload read result.
  const KittyMediumReadInvalid();
}

/// The transmission medium is unsupported on this platform.
final class KittyMediumReadUnsupported extends KittyMediumReadResult {
  /// Creates an unsupported-medium read result.
  const KittyMediumReadUnsupported();
}

const List<String> _blockedShmPrefixes = [
  'sem.',
  'org.chromium.',
  'org.mozilla.',
  'com.google.chrome.',
  'pulse-shm-',
  'pipewire-',
  'jack_',
  'postgresql.',
  'wayland-',
  'xshmfence-',
  'mesa_shader_cache',
  'snap.',
  'flatpak-',
];

/// Returns whether a decoded POSIX shared-memory object name (`t=s`) is safe
/// to open for Kitty Graphics Protocol transmission.
///
/// Rejects path separators, NUL bytes, hidden names (leading `.`), POSIX
/// semaphores (`sem.*`), and well-known browser/audio/display/database IPC
/// namespaces while remaining compatible with Kitty clients (`icat-*`,
/// `peng-*`, `kitty-*`, `tty-graphics-protocol*`, etc.).
bool isAllowedKittyShmName(String decoded) {
  final clean = decoded.startsWith('/') ? decoded.substring(1) : decoded;
  if (clean.isEmpty ||
      clean.startsWith('.') ||
      clean.contains('/') ||
      clean.contains(r'\') ||
      clean.contains('\x00') ||
      clean == '..') {
    return false;
  }
  final lower = clean.toLowerCase();
  for (final prefix in _blockedShmPrefixes) {
    if (lower.startsWith(prefix)) return false;
  }
  return true;
}
