import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

typedef ProcessRunner = Future<ProcessResult> Function(String, List<String>);

void main(List<String> args) async => build(args, runPty2Build);

Future<void> runPty2Build(
  BuildInput input,
  BuildOutputBuilder output, {
  OS? hostOS,
  Architecture? hostArch,
  ProcessRunner? runProcess,
}) async {
  if (!input.config.buildCodeAssets) return;
  final c = input.config.code;
  if (c.targetOS != .linux && c.targetOS != .macOS) return;
  if ((hostOS ?? OS.current, c.targetOS, c.cCompiler) ==
          (OS.linux, OS.linux, null) &&
      c.targetArchitecture == (hostArch ?? Architecture.current) &&
      c.linkModePreference != .static) {
    return _linux(input, output, runProcess ?? Process.run);
  }
  await CBuilder.library(
    name: 'pty2_unix',
    assetName: 'src/impl/unix.dart',
    sources: ['src/pty2_unix.c'],
    libraries: [if (c.targetOS == .linux) 'util'],
  ).run(input: input, output: output);
}

Future<void> _linux(BuildInput i, BuildOutputBuilder o, ProcessRunner f) async {
  final cc = await _probe(f);
  final src = i.packageRoot.resolve('src/pty2_unix.c');
  final out = i.outputDirectory.resolve(OS.linux.dylibFileName('pty2_unix'));
  const cflags = ['-shared', '-fPIC', '-O3', '-DNDEBUG', '-DRELEASE'];
  final p = src.toFilePath();
  final res = await f(cc, [...cflags, p, '-lutil', '-o', out.toFilePath()]);
  if (res.exitCode != 0) throw StateError('$cc failed: ${res.stderr}');
  o.dependencies.add(src);
  o.assets.code.add(
    CodeAsset(
      package: i.packageName,
      name: 'src/impl/unix.dart',
      linkMode: DynamicLoadingBundled(),
      file: out,
    ),
  );
}

Future<String> _probe(ProcessRunner run) async {
  for (final c in const ['cc', 'clang', 'gcc']) {
    try {
      if ((await run(c, const ['--version'])).exitCode == 0) return c;
    } on ProcessException {
      continue;
    }
  }
  throw StateError('No C compiler found on PATH (cc, clang, gcc).');
}
