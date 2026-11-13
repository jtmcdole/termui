import 'dart:io';

import '../apc_audio_encoder.dart';
import '../api/audio_engine.dart';
import 'cli/cli_audio_engine.dart';

/// Creates a new [TermuiAudioEngine] using the APC or CLI backend.
///
/// Returns a [PtyApcAudioEngine] writing escape sequences via [writeEscape]
/// (defaulting to [Stdout.write] on [stdout]) when `TERMUI_AUDIO_APC` in
/// [environment] (defaulting to [Platform.environment]) is `'1'` or `'true'`;
/// otherwise returns a native [CliAudioEngine].
TermuiAudioEngine createAudioEngine({
  Map<String, String>? environment,
  void Function(String sequence)? writeEscape,
}) {
  final env = environment ?? Platform.environment;
  final apcFlag = env['TERMUI_AUDIO_APC']?.trim().toLowerCase();
  if (apcFlag == '1' || apcFlag == 'true') {
    return PtyApcAudioEngine(writeEscape ?? stdout.write);
  }
  return CliAudioEngine();
}
