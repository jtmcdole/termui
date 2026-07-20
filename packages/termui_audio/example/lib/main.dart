// ignore_for_file: public_member_api_docs, avoid_print
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_audio/termui_audio.dart';
// ignore: implementation_imports
import 'package:termui_audio/src/impl/flutter/flutter_audio_engine.dart';
import 'package:termui_audio_example/src/audio_player_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb &&
      (Platform.isWindows ||
          Platform.isLinux ||
          Platform.isMacOS ||
          Platform.isAndroid ||
          Platform.isIOS)) {
    TermuiAudio.instance = FlutterAudioEngine();
  }
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TermUI Audio Cozy Player',
      theme: ThemeData.dark(),
      home: const AudioPlayerPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class AudioPlayerPage extends StatefulWidget {
  const AudioPlayerPage({super.key});

  @override
  State<AudioPlayerPage> createState() => _AudioPlayerPageState();
}

class _AudioPlayerPageState extends State<AudioPlayerPage> {
  late final FlutterTerminal _terminal;
  TermuiAudioEngine? _audioService;

  @override
  void initState() {
    super.initState();
    _terminal = FlutterTerminal();
  }

  @override
  void dispose() {
    _terminal.dispose();
    _audioService?.dispose();
    super.dispose();
  }

  static int _fileLoadCounter = 0;

  Future<AudioBuffer> _flutterLoadAsset(
    String assetPath, {
    LoadProgressCallback? onProgress,
  }) async {
    final service = _audioService;
    if (service == null) {
      throw Exception('Audio service not initialized');
    }
    if (kIsWeb) {
      // In Flutter Web, the assets are served by the web server
      return await service.loadUrl(
        'assets/assets/${assetPath.split('/').last}',
        onProgress: onProgress,
      );
    } else {
      final byteData = await rootBundle.load(assetPath);
      final tempDir = await getTemporaryDirectory();
      final timestamp = _fileLoadCounter++;
      final tempFile = File(
        '${tempDir.path}/${timestamp}_${assetPath.split('/').last}',
      );
      await tempFile.writeAsBytes(byteData.buffer.asUint8List());
      return await service.loadFile(
        tempFile.absolute.path,
        onProgress: onProgress,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 800, maxHeight: 600),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white24),
            borderRadius: BorderRadius.circular(8.0),
          ),
          clipBehavior: Clip.antiAlias,
          child: Terminal(
            terminal: _terminal,
            fontSize: 16.0,
            fontFamily: 'MesloLGS NF',
            onRun: (terminal, drawFrame) async {
              final service = TermuiAudio.instance;
              _audioService = service;
              print('TermuiAudio instance type: ${service.runtimeType}');
              await service.init();
              await runAudioPlayerApp(
                terminal,
                service,
                _flutterLoadAsset,
                onFrameRedrawn: drawFrame,
              );
            },
          ),
        ),
      ),
    );
  }
}
