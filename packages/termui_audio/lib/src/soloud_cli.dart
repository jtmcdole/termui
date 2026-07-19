// ignore_for_file: public_member_api_docs, non_constant_identifier_names
import 'dart:ffi';

@Native<Int32 Function(Int32, Uint32, Uint32, Uint32, Uint32)>(
  symbol: 'initEngine',
)
external int initEngine(
  int deviceId,
  int sampleRate,
  int bufferSize,
  int channels,
  int lowLatency,
);

@Native<Void Function()>(symbol: 'dispose')
external void disposeEngine();

@Native<
  Int32 Function(Pointer<Char>, Pointer<Uint8>, Int32, Int32, Pointer<Uint32>)
>(symbol: 'loadMem')
external int loadMem(
  Pointer<Char> uniqueName,
  Pointer<Uint8> buffer,
  int length,
  int loadIntoMem,
  Pointer<Uint32> hash,
);

@Native<
  Int32 Function(
    Uint32,
    Uint32,
    Float,
    Float,
    Bool,
    Bool,
    Double,
    Pointer<Uint32>,
  )
>(symbol: 'play')
external int play(
  int soundHash,
  int busId,
  double volume,
  double pan,
  bool paused,
  bool looping,
  double loopingStartAt,
  Pointer<Uint32> handle,
);

@Native<Void Function(Uint32)>(symbol: 'stop')
external void stop(int handle);

@Native<Int32 Function(Uint32, Float)>(symbol: 'setVolume')
external int setVolume(int handle, double volume);

@Native<Void Function(Uint32)>(symbol: 'disposeSound')
external void disposeSound(int soundHash);

@Native<Void Function(Pointer<Void>)>(symbol: 'SoLoud_destroySound')
external void SoLoud_destroySound(Pointer<Void> handle);
