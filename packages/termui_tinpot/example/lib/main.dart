import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_tinpot_example/termui_tinpot_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TermUI Tinpot Image Converter',
      theme: ThemeData.dark(),
      home: const TinpotPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class TinpotPage extends StatefulWidget {
  const TinpotPage({super.key});

  @override
  State<TinpotPage> createState() => _TinpotPageState();
}

class _TinpotPageState extends State<TinpotPage> {
  late final FlutterTerminal _terminal;
  final TinpotAppController _controller = TinpotAppController();
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _terminal = FlutterTerminal();

    _controller.onPickImage = () async {
      const XTypeGroup typeGroup = XTypeGroup(
        label: 'images',
        extensions: <String>['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'],
      );
      final XFile? file = await openFile(
        acceptedTypeGroups: <XTypeGroup>[typeGroup],
      );
      if (file != null) {
        final bytes = await file.readAsBytes();
        _controller.setImageBytes(bytes, file.name);
      }
    };
  }

  @override
  void dispose() {
    _terminal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DropTarget(
        onDragEntered: (details) => setState(() => _isDragging = true),
        onDragExited: (details) => setState(() => _isDragging = false),
        onDragDone: (details) async {
          setState(() => _isDragging = false);
          if (details.files.isNotEmpty) {
            final file = details.files.first;
            try {
              final bytes = await file.readAsBytes();
              _controller.setImageBytes(bytes, file.name);
            } catch (_) {
              _controller.setFilePath(file.path);
            }
          }
        },
        child: Stack(
          children: [
            Center(
              child: Container(
                constraints: const BoxConstraints.expand(),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white24, width: 1.0),
                  borderRadius: BorderRadius.circular(8.0),
                ),
                clipBehavior: Clip.antiAlias,
                child: Terminal(
                  terminal: _terminal,
                  fontSize: 14.0,
                  fontFamily: 'MesloLGS NF',
                  onRun: (terminal, drawFrame) async {
                    await runTinpotApp(
                      terminal,
                      controller: _controller,
                      onFrameRedrawn: drawFrame,
                    );
                  },
                ),
              ),
            ),
            if (_isDragging)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    color: Colors.blueAccent.withValues(alpha: 0.2),
                    child: const Center(
                      child: Text(
                        'Drop image file here to convert',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
