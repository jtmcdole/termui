// ignore_for_file: public_member_api_docs

import 'dart:io';

import 'dart:typed_data';

abstract interface class PtyCore {
  Uint8List? read();

  int? exitCodeNonBlocking();

  int exitCodeBlocking();

  bool kill([ProcessSignal signal = ProcessSignal.sigterm]);

  void resize(int width, int height);

  // int get pid;

  void write(List<int> data);

  PtyCoreWorker get worker;
}

abstract interface class PtyCoreWorker {
  Uint8List? read();
  int exitCodeBlocking();
  void free();
}
