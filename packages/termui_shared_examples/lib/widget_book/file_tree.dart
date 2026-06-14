import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:file/memory.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui/ui/widgets/io/file_tree_helper.dart';
import 'package:termui/ui/event.dart' as ui;
import 'example_base.dart';

/// True if the current application is compiled to run on the web.
const bool _kIsWeb =
    bool.fromEnvironment('dart.library.js_interop') ||
    bool.fromEnvironment('dart.library.html') ||
    identical(0, 0.0);

/// An example showcasing an interactive file tree view of the local project.
class FileTreeExample extends WidgetBookExample {
  /// The root node of the file tree.
  late final TreeNode<FileSystemEntity> fileTreeRoot;

  /// The active tree widget rendering the file system entities.
  TreeWidget<FileSystemEntity>? _treeWidget;

  /// The currently selected file or directory path.
  String selectedPath = 'lib';

  @override
  void init() {
    FileSystem fs;
    if (_kIsWeb) {
      fs = MemoryFileSystem();
      fs.directory('lib').createSync(recursive: true);
      fs.file('lib/main.dart').writeAsStringSync('void main() {}');
      fs.file('lib/example.dart').writeAsStringSync('// test');
      fs.directory('lib/src').createSync(recursive: true);
      fs.file('lib/src/util.dart').writeAsStringSync('// util');
    } else {
      fs = const LocalFileSystem();
    }

    fileTreeRoot = FileTreeHelper.buildFromPath(fs, 'lib');
  }

  TreeWidget<FileSystemEntity> _buildTreeWidget(bool active) {
    _treeWidget = TreeWidget<FileSystemEntity>(
      root: fileTreeRoot,
      focused: active,
      onSelect: (node) {
        selectedPath = node.value.path;
      },
    );
    return _treeWidget!;
  }

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    final tree = _buildTreeWidget(focusDemoPane);
    return Column([
      SizedBox(
        height: 1,
        child: Text(
          'Interactive File Tree view of local project files (e.g. lib/):',
          style: const Style(foreground: CharmColors.squid),
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      Expanded(child: tree),
      const SizedBox(height: 1, child: Text('')),
      SizedBox(
        height: 1,
        child: Text(
          'Selected Path: $selectedPath',
          style: const Style(
            foreground: CharmColors.pepper,
            background: CharmColors.julep,
            modifiers: Modifier.bold,
          ),
        ),
      ),
    ]);
  }

  @override
  bool handleKeyEvent(ui.KeyEvent event) {
    _treeWidget?.handleKeyEvent(event);
    return true;
  }

  @override
  Map<String, String> get helpBindings => {
    'Up/Down': 'Select node',
    'Left/Right': 'Collapse/Expand',
    'Enter': 'Select path',
  };
}
