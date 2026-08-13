import 'package:flutter/foundation.dart';
import 'package:termui/termui.dart' as termui;
import 'package:termui_recorder/termui_recorder.dart';
import 'recording_service.dart';

final class RecordingViewModel extends ChangeNotifier {
  final RecordingService _service;
  final void Function(String)? onLog;

  bool _isRecordingTrace = false;
  bool _isRecordingAsciicast = false;

  RecordingViewModel(this._service, {this.onLog});

  bool get isRecordingTrace => _isRecordingTrace;
  bool get isRecordingAsciicast => _isRecordingAsciicast;
  AsciicastRecorder? get asciicastRecorder => _service.asciicastRecorder;

  Future<void> toggleTrace() async {
    try {
      if (_isRecordingTrace) {
        _isRecordingTrace = false;
        notifyListeners();
        onLog?.call('main.dart: Stopping trace');
        await _service.stopAndSaveTrace();
        onLog?.call('main.dart: Trace stopped and saved');
      } else {
        _isRecordingTrace = true;
        notifyListeners();
        onLog?.call('main.dart: Starting trace');
        await _service.startTrace();
        onLog?.call('main.dart: Trace started');
      }
    } catch (e, st) {
      onLog?.call('main.dart: Trace toggle failed: $e');
      if (kDebugMode) {
        print('Trace toggle failed: $e\n$st');
      }
    }
  }

  Future<void> toggleAsciicast(termui.Terminal backend) async {
    try {
      if (_isRecordingAsciicast) {
        _isRecordingAsciicast = false;
        notifyListeners();
        await _service.stopAndSaveAsciicast();
      } else {
        _isRecordingAsciicast = true;
        notifyListeners();
        await _service.startAsciicast(backend);
      }
    } catch (e, st) {
      if (kDebugMode) {
        print('Asciicast toggle failed: $e\n$st');
      }
    }
  }
}
