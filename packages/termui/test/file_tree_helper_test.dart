import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:termui/ui/widgets/core/io/file_tree_helper.dart';
import 'package:test/test.dart';

void main() {
  group('FileTreeHelper', () {
    test('sorts directories before files alphabetically and expands root', () {
      final fs = MemoryFileSystem();
      fs.file('/workspace/zebra.txt').createSync(recursive: true);
      fs.file('/workspace/alpha.txt').createSync(recursive: true);
      fs.directory('/workspace/src').createSync(recursive: true);
      fs.directory('/workspace/bin').createSync(recursive: true);
      fs.file('/workspace/bin/main.dart').createSync(recursive: true);

      final root = FileTreeHelper.buildFromPath(fs, '/workspace');

      expect(root.label, 'workspace');
      expect(root.isExpanded, isTrue);
      expect(
        [for (final child in root.children) child.label],
        ['bin', 'src', 'alpha.txt', 'zebra.txt'],
      );
      expect(root.children.first.children.single.label, 'main.dart');
    });

    test('suppresses FileSystemException on unreadable directories', () {
      var blockList = false;
      final fs = MemoryFileSystem(
        opHandle: (context, operation) {
          if (blockList && context == '/locked') {
            throw const FileSystemException('Permission denied', '/locked');
          }
        },
      );
      fs.directory('/locked').createSync(recursive: true);
      fs.file('/locked/secret.txt').createSync();

      // Allow isDirectorySync('/locked') once, then fail on listSync()
      var statChecks = 0;
      final guardedFs = MemoryFileSystem(
        opHandle: (context, operation) {
          if (context == '/locked') {
            statChecks++;
            if (statChecks > 1) {
              throw const FileSystemException('Permission denied', '/locked');
            }
          }
        },
      );
      guardedFs.directory('/locked').createSync(recursive: true);
      statChecks = 0;
      blockList = true;

      final node = FileTreeHelper.buildFromPath(
        guardedFs,
        '/locked',
        expandRoot: false,
      );

      expect(node.label, 'locked');
      expect(node.isExpanded, isFalse);
      expect(node.children, isEmpty);
      expect(blockList, isTrue);
    });
  });
}
