/// An exception thrown when a pseudo-terminal operation fails.
class PtyException implements Exception {
  /// Creates a new [PtyException] with the given [message].
  PtyException(this.message);

  final String message;

  @override
  String toString() {
    return message;
  }
}
