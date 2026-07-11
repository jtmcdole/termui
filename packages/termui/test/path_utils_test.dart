import 'package:file/memory.dart';
import 'package:path/path.dart' as p;
import 'package:termui/terminal/path_utils.dart';
import 'package:test/test.dart';

void main() {
  group('PathUtils Tests', () {
    late MemoryFileSystem fileSystem;
    late PathUtils unixPathUtils;
    late PathUtils windowsPathUtils;

    setUp(() {
      fileSystem = MemoryFileSystem();
      unixPathUtils = PathUtils(
        fileSystem: fileSystem,
        pathContext: p.Context(style: p.Style.posix),
      );
      windowsPathUtils = PathUtils(
        fileSystem: fileSystem,
        pathContext: p.Context(style: p.Style.windows),
      );
    });

    test('Identifies absolute paths correctly', () {
      expect(
        unixPathUtils.isPotentialFilePath('/absolute/path/to/file'),
        isTrue,
      );
      expect(
        windowsPathUtils.isPotentialFilePath(r'C:\absolute\path\to\file'),
        isTrue,
      );
      expect(unixPathUtils.isPotentialFilePath('relative/path'), isFalse);
    });

    test('Identifies user home paths correctly', () {
      expect(unixPathUtils.isPotentialFilePath('~/documents/file.txt'), isTrue);
      expect(
        windowsPathUtils.isPotentialFilePath('~/documents/file.txt'),
        isTrue,
      );
    });

    test('Verifies physical file presence', () {
      // Create a file in memory filesystem
      fileSystem.file('/app/config.json').createSync(recursive: true);

      expect(unixPathUtils.isPotentialFilePath('/app/config.json'), isTrue);
      expect(unixPathUtils.isPotentialFilePath('config.json'), isFalse);

      // Create file in relative location
      fileSystem.file('config.json').createSync(recursive: true);
      expect(unixPathUtils.isPotentialFilePath('config.json'), isTrue);
    });

    test('Identifies lexical paths correctly without disk access', () {
      expect(
        unixPathUtils.isLexicallyPotentialFilePath('/absolute/path'),
        isTrue,
      );
      expect(unixPathUtils.isLexicallyPotentialFilePath('~/home'), isTrue);
      expect(unixPathUtils.isLexicallyPotentialFilePath('./relative'), isTrue);
      expect(unixPathUtils.isLexicallyPotentialFilePath('../parent'), isTrue);
      expect(
        unixPathUtils.isLexicallyPotentialFilePath('config.json'),
        isFalse,
      );
    });

    test('Identifies potential files asynchronously', () async {
      fileSystem.file('async_config.json').createSync(recursive: true);

      expect(
        await unixPathUtils.isPotentialFilePathAsync('/absolute/path'),
        isTrue,
      );
      expect(await unixPathUtils.isPotentialFilePathAsync('~/home'), isTrue);
      expect(
        await unixPathUtils.isPotentialFilePathAsync('async_config.json'),
        isTrue,
      );
      expect(
        await unixPathUtils.isPotentialFilePathAsync('non_existent.json'),
        isFalse,
      );
    });

    test('Handles empty and invalid inputs', () {
      expect(unixPathUtils.isPotentialFilePath(''), isFalse);
      expect(unixPathUtils.isPotentialFilePath('   '), isFalse);
      expect(unixPathUtils.isLexicallyPotentialFilePath(''), isFalse);
      expect(unixPathUtils.isLexicallyPotentialFilePath('   '), isFalse);
    });
  });
}
