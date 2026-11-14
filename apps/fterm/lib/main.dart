import 'package:material_ui/material_ui.dart';

import 'src/desktop_launch_env.dart';
import 'src/file_drop_bridge.dart';
import 'src/font_loader.dart';
import 'src/fterm_app.dart';

/// Launches the `fterm` desktop/web terminal workspace and TermUI Caster client.
Future<void> main(List<String> args) async {
  final CastLaunchConfig config;
  try {
    config = resolveCastLaunchConfig(
      baseUri: Uri.base,
      args: args,
      defineServerUrl: const String.fromEnvironment('TERMUI_CAST_SERVER_URL'),
      defineToken: const String.fromEnvironment('TERMUI_CAST_TOKEN'),
      defineCasterToken: const String.fromEnvironment(
        'TERMUI_CAST_CASTER_TOKEN',
      ),
    );
  } on FormatException catch (e) {
    reportDesktopStartupError(e.message);
    return;
  }
  scrubUrlFragment();
  WidgetsFlutterBinding.ensureInitialized();
  await loadCastFonts();
  runApp(FtermApp(config: config));
}
