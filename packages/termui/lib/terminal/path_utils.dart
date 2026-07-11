import 'package:file/file.dart';
import 'package:path/path.dart' as p;

/// Utility class for verifying whether paste input represents a potential file path.
class PathUtils {
  /// The filesystem interface to query for path existence.
  final FileSystem fileSystem;

  /// The path context providing platform-specific path structures (Windows/Unix).
  final p.Context pathContext;

  /// Creates a [PathUtils] instance with mockable [fileSystem] and [pathContext] dependencies.
  const PathUtils({required this.fileSystem, required this.pathContext});

  /// Detects if a pasted [text] string represents a potential local file path.
  ///
  /// This check is backward compatible and handles both lexical patterns and physical
  /// file existence.
  ///
  /// > [!WARNING]
  /// > This method performs synchronous filesystem I/O (`typeSync`). Calling this
  /// > on the UI thread/rendering loop can block the event loop and cause frame drops.
  /// > Prefer [isLexicallyPotentialFilePath] for synchronous UI-thread checks, or
  /// > [isPotentialFilePathAsync] for asynchronous verification.
  bool isPotentialFilePath(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;

    if (isLexicallyPotentialFilePath(trimmed)) {
      return true;
    }

    // Verify physical file presence on the provided filesystem
    try {
      if (fileSystem.typeSync(trimmed) != FileSystemEntityType.notFound) {
        return true;
      }
    } catch (_) {}

    return false;
  }

  /// Lexically detects if a pasted [text] string represents a potential local file path.
  ///
  /// This check is purely synchronous and lexical, meaning it does not perform filesystem I/O,
  /// making it safe to run on the main UI/rendering thread without blocking.
  bool isLexicallyPotentialFilePath(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;

    if (pathContext.isAbsolute(trimmed)) return true;

    // Check for user home syntax or standard relative path segment prefixes
    return trimmed.startsWith('~/') ||
        trimmed.startsWith(r'~\') ||
        trimmed.startsWith('./') ||
        trimmed.startsWith(r'.\') ||
        trimmed.startsWith('../') ||
        trimmed.startsWith(r'..\');
  }

  /// Asynchronously detects if a pasted [text] string represents a potential local file path.
  ///
  /// First performs a fast lexical check. If that fails, it queries the filesystem asynchronously
  /// to verify if the file exists, avoiding blocking the Dart event loop.
  Future<bool> isPotentialFilePathAsync(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;

    if (isLexicallyPotentialFilePath(trimmed)) {
      return true;
    }

    // Verify physical file presence on the provided filesystem asynchronously
    try {
      final entityType = await fileSystem.type(trimmed);
      return entityType != FileSystemEntityType.notFound;
    } catch (_) {
      return false;
    }
  }
}
