import 'dart:typed_data';

/// Result of reading a local Kitty Graphics Protocol medium (`t=t` or `t=s`).
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
