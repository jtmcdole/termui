/// An exception thrown when a pseudo-terminal operation fails.
final class PtyException implements Exception {
  /// Creates a new [PtyException] with the given [message].
  PtyException(this.message);

  /// The error message describing the failure.
  final String message;

  @override
  String toString() => message;
}
