// ignore_for_file: depend_on_referenced_packages
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:hooks/hooks.dart';
import 'package:code_assets/code_assets.dart';
import 'package:native_toolchain_cmake/native_toolchain_cmake.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final builder = CMakeBuilder.create(
      name: 'soloud_cli',
      sourceDir: input.packageRoot,
      defines: {'CMAKE_POLICY_VERSION_MINIMUM': '3.5'},
    );

    await builder.run(
      input: input,
      output: output,
      logger: Logger('soloud_cli')
        ..onRecord.listen((record) {
          print('${record.level.name}: ${record.time}: ${record.message}');
        }),
    );

    final targetOS = input.config.code.targetOS;
    final fileName = targetOS.dylibFileName('soloud_cli');

    var dllPath = input.outputDirectory.resolve(fileName);
    if (!File.fromUri(dllPath).existsSync()) {
      dllPath = input.outputDirectory.resolve('Release/$fileName');
    }

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/soloud_cli.dart',
        linkMode: DynamicLoadingBundled(),
        file: dllPath,
      ),
    );

    // If target OS is Windows, also register the dependent DLLs as code assets
    if (targetOS == OS.windows) {
      final xiphDlls = [
        'ogg.dll',
        'opus.dll',
        'vorbis.dll',
        'vorbisfile.dll',
        'FLAC.dll',
      ];
      for (final dll in xiphDlls) {
        var dllUri = input.outputDirectory.resolve(dll);
        if (!File.fromUri(dllUri).existsSync()) {
          dllUri = input.outputDirectory.resolve('Release/$dll');
        }
        if (File.fromUri(dllUri).existsSync()) {
          output.assets.code.add(
            CodeAsset(
              package: input.packageName,
              name: 'src/$dll',
              linkMode: DynamicLoadingBundled(),
              file: dllUri,
            ),
          );
        }
      }
    }
  });
}
