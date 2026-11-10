import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:test/test.dart';

import '../hook/build.dart';

Future<BuildOutput> _run(
  ProcessRunner fn, [
  OS os = .linux,
  bool cc = false,
]) async {
  final d = Directory.systemTemp.createTempSync('pty2_hook_');
  addTearDown(() => d.deleteSync(recursive: true));
  File.fromUri(d.uri.resolve('src/pty2_unix.c')).createSync(recursive: true);
  final p = (File.fromUri(d.uri.resolve('cc'))..writeAsStringSync('')).path;
  final s = Directory.fromUri(d.uri.resolve('s/'))..createSync();
  final i = BuildInput({
    'config': {
      'build_asset_types': ['code_assets/code'],
      'linking_enabled': false,
      'extensions': {
        'code_assets': {
          'link_mode_preference': 'dynamic',
          'target_architecture': 'x64',
          'target_os': os.name,
          if (cc) 'c_compiler': {'ar': p, 'cc': p, 'ld': p},
        },
      },
    },
    'out_dir_shared': s.path,
    'out_file': File.fromUri(d.uri.resolve('o.json')).path,
    'package_name': 'pty2',
    'package_root': d.path,
  });
  final o = BuildOutputBuilder();
  await runPty2Build(i, o, hostOS: .linux, hostArch: .x64, runProcess: fn);
  return o.build();
}

void main() {
  test('Linux gcc fallback registers asset and dependency', () async {
    final calls = <String>[];
    final built = await _run((exe, args) async {
      calls.add(args.first == '--version' ? exe : '$exe ${args.first}');
      if (exe != 'gcc') throw ProcessException(exe, args);
      if (args.contains('-o')) File(args.last).writeAsBytesSync(const [0x7f]);
      return ProcessResult(1, 0, 'gcc 13', '');
    });
    expect(calls, ['cc', 'clang', 'gcc', 'gcc -shared']);
    expect(built.assets.code.single.id, 'package:pty2/src/impl/unix.dart');
    expect(built.dependencies.single.toFilePath(), endsWith('pty2_unix.c'));
  });

  test('errors propagate and non-Linux passes through', () async {
    var hit = false;
    ProcessResult r(int c, [String e = '']) => ProcessResult(1, c, '', e);
    Matcher err(String s) =>
        throwsA((Object? e) => e is StateError && e.message.contains(s));
    await expectLater(_run((e, a) => throw ProcessException(e, a)), err('gcc'));
    await expectLater(_run((_, a) async => r(a.length - 1, 'bad')), err('bad'));
    Future<ProcessResult> spy(String _, List<String> _) async =>
        r((hit = true) ? 0 : 0);
    expect((await _run(spy, .windows)).assets.code, isEmpty);
    await expectLater(_run(spy, .linux, true), throwsStateError);
    expect(hit, isFalse);
  });
}
