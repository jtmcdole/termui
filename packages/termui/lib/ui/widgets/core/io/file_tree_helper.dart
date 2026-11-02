import 'package:termui/termui.dart';
import 'package:file/file.dart';

import 'package:termui/ui/widgets/display/tree.dart';

/// Helper class to construct TreeNodes from direct local file system path structures.
class FileTreeHelper {
  /// Recursively reads a file system path and returns a `TreeNode<FileSystemEntity>` hierarchy.
  static TreeNode<FileSystemEntity> buildFromPath(
    FileSystem fs,
    String path, {
    bool expandRoot = true,
  }) {
    final entity = fs.isDirectorySync(path)
        ? fs.directory(path)
        : fs.file(path);
    final node = _buildNode(entity);
    if (expandRoot) {
      node.isExpanded = true;
    }
    return node;
  }

  static TreeNode<FileSystemEntity> _buildNode(FileSystemEntity entity) {
    final name = _entityName(entity);
    final children = <TreeNode<FileSystemEntity>>[];

    if (entity is Directory) {
      try {
        final list = entity.listSync()..sort(_compareEntities);
        for (final child in list) {
          children.add(_buildNode(child));
        }
      } on FileSystemException {
        // Suppress listing errors for unreadable paths
      }
    }

    return TreeNode<FileSystemEntity>(
      label: name,
      value: entity,
      children: children,
    );
  }

  static String _entityName(FileSystemEntity entity) {
    final segments = entity.uri.pathSegments;
    if (segments.isEmpty) return entity.path;
    if (segments.last.isNotEmpty) return segments.last;
    return segments.length >= 2 ? segments[segments.length - 2] : entity.path;
  }

  static int _compareEntities(FileSystemEntity a, FileSystemEntity b) {
    final aIsDir = a is Directory;
    final bIsDir = b is Directory;
    if (aIsDir && !bIsDir) return -1;
    if (!aIsDir && bIsDir) return 1;
    return a.path.compareTo(b.path);
  }
}
