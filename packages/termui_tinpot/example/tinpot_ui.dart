import 'dart:io';
import 'package:termui/termui.dart';
import 'package:termui_tinpot/termui_tinpot.dart';
import 'package:image/image.dart' as img;

import 'package:termui/terminal/terminal.dart' as term;

void main() async {
  await term.Terminal.runGuarded((terminal) async {
    terminal.enterAlternateScreen();
    terminal.hideCursor();
    terminal.enableMouseTracking();

    await PromptRunner(terminal: terminal, widget: const TinpotApp()).run();
  });
}

class TinpotApp extends StatefulWidget {
  const TinpotApp({super.key});

  @override
  State<TinpotApp> createState() => _TinpotAppState();
}

class _TinpotAppState extends State<TinpotApp> {
  final TextEditingController _pathController = TextEditingController();
  String _status = 'Enter image path and press Convert';
  List<List<TinpotOutputCell>>? _grid;

  int _width = 80;
  int _height = 40;

  void _convertImage() {
    final path = _pathController.text.trim();
    if (path.isEmpty) {
      setState(() => _status = 'Error: Path is empty');
      return;
    }

    final file = File(path);
    if (!file.existsSync()) {
      setState(() => _status = 'Error: File not found');
      return;
    }

    setState(() => _status = 'Loading image...');

    final imageBytes = file.readAsBytesSync();
    final image = img.decodeImage(imageBytes);

    if (image == null) {
      setState(() => _status = 'Error: Failed to decode image');
      return;
    }

    setState(() => _status = 'Converting...');

    final double imageAspect = image.width / image.height;
    int columns = _width;
    int rows = (columns / (imageAspect * 2.0)).round();

    if (rows > _height) {
      rows = _height;
      columns = (rows * imageAspect * 2.0).round();
    }
    if (columns < 1) columns = 1;
    if (rows < 1) rows = 1;

    final engine = TermuiTinpot();
    final grid = engine.convert(image, columns, rows);

    setState(() {
      _grid = grid;
      _status = 'Success! Image converted. Press Save to export.';
    });
  }

  void _saveAscii() {
    if (_grid == null) {
      setState(() => _status = 'Error: No image converted yet.');
      return;
    }

    final buffer = StringBuffer();
    for (int y = 0; y < _grid!.length; y++) {
      for (int x = 0; x < _grid![y].length; x++) {
        final cell = _grid![y][x];

        final fgR = (cell.fgColorArgb >> 16) & 0xFF;
        final fgG = (cell.fgColorArgb >> 8) & 0xFF;
        final fgB = cell.fgColorArgb & 0xFF;

        final bgR = (cell.bgColorArgb >> 16) & 0xFF;
        final bgG = (cell.bgColorArgb >> 8) & 0xFF;
        final bgB = cell.bgColorArgb & 0xFF;

        buffer.write('\x1B[38;2;$fgR;$fgG;${fgB}m');
        buffer.write('\x1B[48;2;$bgR;$bgG;${bgB}m');
        buffer.write(cell.character);
      }
      buffer.write('\x1B[0m\n');
    }

    final outPath = 'output.ascii';
    File(outPath).writeAsStringSync(buffer.toString());
    setState(() {
      _status = 'Saved to $outPath';
    });
  }

  Widget _buildPreview() {
    if (_grid == null) {
      return const Center(child: Text('No image preview'));
    }

    return Builder(
      builder: (context) {
        return RichText(
          text: TextSpan(
            children: [
              for (final row in _grid!) ...[
                for (final cell in row)
                  TextSpan(
                    text: cell.character,
                    style: Style(
                      foreground: Color(
                        (cell.fgColorArgb >> 16) & 0xFF,
                        (cell.fgColorArgb >> 8) & 0xFF,
                        cell.fgColorArgb & 0xFF,
                      ),
                      background: Color(
                        (cell.bgColorArgb >> 16) & 0xFF,
                        (cell.bgColorArgb >> 8) & 0xFF,
                        cell.bgColorArgb & 0xFF,
                      ),
                    ),
                  ),
                const TextSpan(text: '\n'),
              ],
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column([
      Column([
        Row([
          const Text('Image Path: '),
          Expanded(child: TextField(controller: _pathController)),
        ]),
        const SizedBox(height: 1),
        Row([
          Text('Width: $_width '),
          Expanded(
            child: Slider(
              value: _width.toDouble(),
              min: 10,
              max: 200,
              onChanged: (v) => setState(() => _width = v.toInt()),
            ),
          ),
        ]),
        Row([
          Text('Height: $_height '),
          Expanded(
            child: Slider(
              value: _height.toDouble(),
              min: 10,
              max: 100,
              onChanged: (v) => setState(() => _height = v.toInt()),
            ),
          ),
        ]),
        const SizedBox(height: 1),
        Row([
          Button(onPressed: _convertImage, text: 'Convert Image'),
          const SizedBox(width: 2),
          Button(onPressed: _saveAscii, text: 'Save .ascii'),
        ]),
        const SizedBox(height: 1),
        Text(
          'Status: $_status',
          style: const Style(foreground: Color(255, 255, 0)),
        ),
      ]),
      Expanded(
        child: DecoratedBox(
          decoration: const BoxDecoration(border: Border.single),
          child: _buildPreview(),
        ),
      ),
    ]);
  }
}
