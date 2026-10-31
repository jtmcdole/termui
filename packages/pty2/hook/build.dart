import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final targetOS = input.config.code.targetOS;
    if (targetOS != OS.linux && targetOS != OS.macOS) {
      return;
    }

    final cbuilder = CBuilder.library(
      name: 'pty2_unix',
      assetName: 'src/impl/unix.dart',
      sources: ['src/pty2_unix.c'],
      libraries: [if (targetOS == OS.linux) 'util'],
    );
    await cbuilder.run(input: input, output: output);
  });
}
