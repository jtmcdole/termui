// ignore_for_file: public_member_api_docs, avoid_print
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:termui_audio_example/src/audio_player_app.dart';
import 'package:termui_audio_flutter/termui_audio_flutter.dart';
import 'package:termui_flutter/termui_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  TermuiAudioFlutter.register();
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
    }
    onProgress?.call(0.1);
    final byteData = await rootBundle.load(assetPath);
    final timestamp = _fileLoadCounter++;
    final buffer = await service.loadMem(
      '${timestamp}_${assetPath.split('/').last}',
      Uint8List.sublistView(byteData),
    );
    onProgress?.call(1.0);
    return buffer;
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
