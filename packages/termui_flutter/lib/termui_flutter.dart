/// A Flutter GUI embedder and renderer for termui applications.
///
/// This library provides the integration between `termui` and Flutter,
/// allowing TUI applications to be rendered inside a Flutter application.
///
/// It translates terminal draw commands and cell updates into Flutter text
/// textures, rendering the final output using custom painters. It also routes
/// keyboard and mouse interactions from the Flutter UI back to the terminal.
///
/// ### Example Usage
///
/// The following example demonstrates how to host a TUI application inside
/// a standard `MaterialApp`.
///
/// ```dart
/// import 'package:material_ui/material_ui.dart' hide Color;
/// import 'package:termui/termui.dart' as termui;
/// import 'package:termui_flutter/termui_flutter.dart';
///
/// void main() {
///   runApp(const MyApp());
/// }
///
/// class MyApp extends StatelessWidget {
///   const MyApp({super.key});
///
///   @override
///   Widget build(BuildContext context) {
///     return MaterialApp(
///       home: Scaffold(
///         body: Center(
///           child: SizedBox(
///             width: 640,
///             height: 480,
///             child: Terminal(
///               onRun: (terminal, drawFrame) async {
///                 final termSize = await terminal.size;
///                 final buffer = termui.Buffer.blank(termSize.x, termSize.y);
///
///                 void render() {
///                   buffer.clear();
///                   buffer.write(
///                     0,
///                     0,
///                     'Hello from Flutter TUI!',
///                     style: const termui.Style(foreground: termui.Colors.white),
///                   );
///                   drawFrame(buffer);
///                 }
///
///                 render();
///
///                 await for (final event in terminal.events) {
///                   if (event is termui.KeyEvent && event.key == 'q') {
///                     break;
///                   }
///                   render();
///                 }
///               },
///             ),
///           ),
///         ),
///       ),
///     );
///   }
/// }
/// ```
library;

export 'src/backend.dart' show FlutterTerminal;
export 'src/terminal.dart' show Terminal;
export 'src/terminal_ime_client.dart' show TerminalImeClient;
export 'src/terminal_surface.dart' show TerminalSurface;
export 'src/service/terminal_service.dart'
    show DefaultTerminalService, TerminalService;
export 'src/rendering/atlas.dart'
    show GlyphAtlas, GlyphAtlasGenerator, GlyphStyleVariant;
export 'src/rendering/atlas_controller.dart' show GlyphAtlasController;
export 'src/util/file_saver.dart' show saveFile;
export 'src/util/font_helper.dart' show waitForFontsToLoad;
export 'src/util/url_launcher.dart'
    show isAllowedExternalUrl, parseAllowedExternalUri;
export 'package:termui/ui/widgets/interactive/selection_controller.dart'
    show
        SelectionMode,
        SelectionRegion,
        TerminalSelectionController,
        VirtualLineLookup,
        VirtualLineSlice;
