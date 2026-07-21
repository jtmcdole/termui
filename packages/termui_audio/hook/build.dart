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

    // If target OS is Linux, also register the dependent SOs as code assets
    if (targetOS == OS.linux) {
      final xiphSos = [
        'libogg.so',
        'libogg.so.0',
        'libogg.so.0.8.5',
        'libopus.so',
        'libopus.so.0',
        'libopus.so.0.10.1',
        'libvorbis.so',
        'libvorbis.so.0.4.9',
        'libvorbisfile.so',
        'libvorbisfile.so.3.3.8',
        'libFLAC.so',
        'libFLAC.so.14',
        'libFLAC.so.14.0.0',
      ];
      for (final so in xiphSos) {
        var soUri = input.outputDirectory.resolve(so);
        if (!File.fromUri(soUri).existsSync()) {
          soUri = input.outputDirectory.resolve('Release/$so');
        }
        if (File.fromUri(soUri).existsSync()) {
          output.assets.code.add(
            CodeAsset(
              package: input.packageName,
              name: 'src/$so',
              linkMode: DynamicLoadingBundled(),
              file: soUri,
            ),
          );
        }
      }
    }
  });
}
