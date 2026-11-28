// ignore_for_file: public_member_api_docs

import 'dart:io';

import 'dart:typed_data';

abstract interface class PtyCore {
  Uint8List? read();

  int? exitCodeNonBlocking();

  int exitCodeBlocking();

  bool kill([ProcessSignal signal = ProcessSignal.sigterm]);

  void resize(int width, int height, {int pixelWidth = 0, int pixelHeight = 0});

  // int get pid;

  void write(List<int> data);

  void onReaderClosed();

  PtyCoreWorker get worker;

  PtyCoreWriter get writer;
}

abstract interface class PtyCoreWorker {
  Uint8List? read();
  int exitCodeBlocking();
  void free();
}

abstract interface class PtyCoreWriter {
  bool write(Uint8List data);
  void free();
}
