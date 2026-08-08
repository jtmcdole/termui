import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:termui_tinpot_example/termui_tinpot_app.dart';

void main() {
  group('TinpotViewModel & TinpotAppController Tests', () {
    late TinpotViewModel viewModel;
    late TinpotAppController controller;

    setUp(() {
      viewModel = TinpotViewModel();
      controller = TinpotAppController();
    });

    tearDown(() {
      viewModel.dispose();
    });

    test('Initial state is correct', () {
      expect(viewModel.state.isProcessing, isFalse);
      expect(viewModel.state.width, 80);
      expect(viewModel.state.workFactor, 9);
      expect(viewModel.state.imagePath, '');
    });

    test('setWidth and setWorkFactor', () {
      viewModel.setWidth(120);
      expect(viewModel.state.width, 120);

      viewModel.setWorkFactor(5);
      expect(viewModel.state.workFactor, 5);
    });

    test('convertImage on empty path', () async {
      viewModel.setImagePath('   ');
      await viewModel.convertImage();
      expect(viewModel.state.status, 'Error: Path is empty');
    });

    test('convertImage on non-existent file', () async {
      viewModel.setImagePath('does_not_exist.png');
      await viewModel.convertImage();
      expect(
        viewModel.state.status,
        'Error: File not found (does_not_exist.png)',
      );
    });

    test('convertImage on invalid file format', () async {
      final file = File('test_invalid.txt');
      await file.writeAsString('not an image');
      viewModel.setImagePath('test_invalid.txt');
      await viewModel.convertImage();
      expect(
        viewModel.state.status,
        startsWith('Error: Failed to decode image format'),
      );
      await file.delete();
    });

    test('TinpotAppController callbacks', () {
      bool pickCalled = false;
      controller.onPickImage = () async {
        pickCalled = true;
      };
      controller.requestImagePick();
      expect(pickCalled, isTrue);

      bool bytesDropped = false;
      controller.onBytesDropped = (bytes, name) => bytesDropped = true;
      controller.setImageBytes(Uint8List.fromList([0, 1]), 'test');
      expect(bytesDropped, isTrue);

      bool fileDropped = false;
      controller.onFileDropped = (path) => fileDropped = true;
      controller.setFilePath('test.png');
      expect(fileDropped, isTrue);
    });
  });
}
