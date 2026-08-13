import 'dart:math';

import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;
import 'example_base.dart';

/// An example demonstrating network traffic sparklines (btop style).
final class SparklinesExample extends WidgetBookExample {
  final RingBuffer<double> _downloadData = RingBuffer<double>(500);
  final RingBuffer<double> _uploadData = RingBuffer<double>(500);
  final RingBuffer<double> _latencyData = RingBuffer<double>(
    100,
  ); // for vertical demo
  final Random _random = Random();

  double _downloadPhase = 0.0;
  double _uploadPhase = 0.0;
  double _latencyPhase = 0.0;

  ProgressBarType _barType = .braille;

  /// Creates a new [SparklinesExample].
  SparklinesExample() {
    // Fill some initial data
    for (int i = 0; i < 200; i++) {
      _tickData();
    }
  }

  void _tickData() {
    // Generate some fake network traffic using sine waves and noise
    double down = (sin(_downloadPhase) * 50 + 50) + _random.nextDouble() * 20;
    double up = (cos(_uploadPhase) * 30 + 30) + _random.nextDouble() * 15;
    double lat = (sin(_latencyPhase) * 20 + 40) + _random.nextDouble() * 10;

    _downloadData.add(down);
    _uploadData.add(up);
    _latencyData.add(lat);

    _downloadPhase += 0.1;
    _uploadPhase += 0.08;
    _latencyPhase += 0.15;
  }

  @override
  bool handleKeyEvent(ui.KeyEvent event) {
    if (event.key == 'q') {
      _barType = _barType == ProgressBarType.braille
          ? ProgressBarType.quads
          : ProgressBarType.braille;
      return true;
    }
    return false;
  }

  @override
  bool get requiresTick => true;

  @override
  bool tick(Duration duration) {
    _tickData();
    return true; // redraw
  }

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    final maxDownload = _downloadData.isEmpty ? 1.0 : _downloadData.reduce(max);
    final maxUpload = _uploadData.isEmpty ? 1.0 : _uploadData.reduce(max);
    final maxLatency = _latencyData.isEmpty ? 1.0 : _latencyData.reduce(max);

    return Padding(
      padding: const EdgeInsets.all(2),
      child: Column([
        SizedBox(
          height: 1,
          child: Text(
            'Press [q] to toggle Quads/Braille',
            style: const Style(modifiers: Modifier.bold),
          ),
        ),
        const SizedBox(height: 1),
        Expanded(
          child: Row([
            Expanded(
              child: Column([
                Row([
                  const Text('Download Traffic'),
                  const Expanded(child: Text('')),
                  Text(
                    '${_downloadData.isEmpty ? 0 : _downloadData.last.toStringAsFixed(1)} MB/s',
                    style: const Style(foreground: Color(180, 150, 255)),
                  ),
                ]),
                const SizedBox(height: 1),
                Flexible(
                  child: Stack([
                    Positioned(
                      left: 0,
                      top: 0,
                      right: 0,
                      bottom: 0,
                      child: Sparkline(
                        _downloadData,
                        max: maxDownload,
                        direction: ProgressDirection.bottomToTop,
                        barType: _barType,
                        colorBuilder: (index, v0, [v1, v2, v3]) => (
                          fg: [
                            (color: const Color(80, 0, 180), stop: 0.0),
                            (color: const Color(200, 150, 255), stop: 1.0),
                          ],
                          bg: null,
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      top: 0,
                      child: Text(
                        '${maxDownload.toStringAsFixed(1)}M',
                        style: const Style(foreground: Color(200, 150, 255)),
                      ),
                    ),
                  ]),
                ),
                Flexible(
                  child: Stack([
                    Positioned(
                      left: 0,
                      top: 0,
                      right: 0,
                      bottom: 0,
                      child: Sparkline(
                        _uploadData,
                        max: maxUpload,
                        direction: ProgressDirection.topToBottom,
                        barType: _barType,
                        colorBuilder: (index, v0, [v1, v2, v3]) => (
                          fg: [
                            (color: const Color(150, 0, 50), stop: 0.0),
                            (color: const Color(255, 100, 150), stop: 1.0),
                          ],
                          bg: null,
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      bottom: 0,
                      child: Text(
                        '${maxUpload.toStringAsFixed(1)}M',
                        style: const Style(foreground: Color(255, 100, 150)),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 1),
                Row([
                  const Text('Upload Traffic'),
                  const Expanded(child: Text('')),
                  Text(
                    '${_uploadData.isEmpty ? 0 : _uploadData.last.toStringAsFixed(1)} MB/s',
                    style: const Style(foreground: Color(255, 100, 150)),
                  ),
                ]),
              ]),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 25,
              child: Column([
                const SizedBox(height: 1, child: Text('Latency (ms)')),
                const SizedBox(height: 1),
                Expanded(
                  child: Stack([
                    Positioned(
                      left: 0,
                      top: 0,
                      right: 0,
                      bottom: 0,
                      child: Sparkline(
                        _latencyData,
                        max: maxLatency,
                        direction: ProgressDirection.leftToRight,
                        barType: _barType,
                        colorBuilder: (index, v0, [v1, v2, v3]) => (
                          fg: [
                            (
                              color: const Color(0, 255, 0),
                              stop: 0.0,
                            ), // bright green for low values
                            (
                              color: const Color(255, 165, 0),
                              stop: 0.5,
                            ), // orange for medium values
                            (
                              color: const Color(255, 0, 0),
                              stop: 1.0,
                            ), // red for high values
                          ],
                          bg: null,
                        ),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      child: Text(
                        '${maxLatency.toStringAsFixed(0)}ms',
                        style: const Style(foreground: Color(255, 0, 0)),
                      ),
                    ),
                  ]),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}
