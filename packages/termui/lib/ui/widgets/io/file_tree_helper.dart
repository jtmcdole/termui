import 'package:file/file.dart';

import 'package:termui/ui/widgets/tree.dart';

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
    final node = _buildNode(fs, entity);
    if (expandRoot) {
      node.isExpanded = true;
    }
    return node;
  }

  static TreeNode<FileSystemEntity> _buildNode(
    FileSystem fs,
    FileSystemEntity entity,
  ) {
    final name = entity.uri.pathSegments.isNotEmpty
        ? (entity.uri.pathSegments.last.isEmpty
              ? entity.uri.pathSegments[entity.uri.pathSegments.length - 2]
              : entity.uri.pathSegments.last)
        : entity.path;

    final children = <TreeNode<FileSystemEntity>>[];
    if (entity is Directory) {
      try {
        final list = entity.listSync().toList();
        // Sort: directories first, then files alphabetically
        list.sort((a, b) {
          final aIsDir = fs.isDirectorySync(a.path);
          final bIsDir = fs.isDirectorySync(b.path);
          if (aIsDir && !bIsDir) return -1;
          if (!aIsDir && bIsDir) return 1;
          return a.path.compareTo(b.path);
        });

        for (final child in list) {
          children.add(_buildNode(fs, child));
        }
      } catch (_) {
        // Suppress listing errors for unreadable paths
      }
    }

    return TreeNode<FileSystemEntity>(
      label: name,
      value: entity,
      children: children,
    );
  }
}
