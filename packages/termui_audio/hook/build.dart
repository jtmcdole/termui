// ignore_for_file: depend_on_referenced_packages
import 'package:logging/logging.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final cbuilder = CBuilder.library(
      name: 'soloud_cli',
      assetName: 'src/soloud_cli.dart',
      sources: ['src/flutter_soloud.cpp'],
      language: Language.cpp,
      includes: ['src/soloud/include', 'src/soloud/src', 'src/pffft', 'src'],
      defines: {
        'WITH_MINIAUDIO': null,
        'MA_NO_PULSEAUDIO': null,
        'NO_XIPH_LIBS': null,
      },
    );

    await cbuilder.run(
      input: input,
      output: output,
      logger: Logger('soloud_cli')
        ..onRecord.listen((record) {
          print('${record.level.name}: ${record.time}: ${record.message}');
        }),
    );
  });
}
