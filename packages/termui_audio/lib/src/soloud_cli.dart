// ignore_for_file: public_member_api_docs, non_constant_identifier_names
import 'dart:ffi';
import 'package:ffi/ffi.dart';

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

@Native<
  Int32 Function(
    Uint32,
    Uint32,
    Float,
    Float,
    Float,
    Float,
    Float,
    Float,
    Float,
    Bool,
    Bool,
    Double,
    Pointer<Uint32>,
  )
>(symbol: 'play3d')
external int play3d(
  int soundHash,
  int busId,
  double posX,
  double posY,
  double posZ,
  double velX,
  double velY,
  double velZ,
  double volume,
  bool paused,
  bool looping,
  double loopingStartAt,
  Pointer<Uint32> handle,
);

@Native<Void Function(Uint32, Float, Float, Float, Float, Float, Float)>(
  symbol: 'set3dSourceParameters',
)
external void set3dSourceParameters(
  int handle,
  double posX,
  double posY,
  double posZ,
  double velocityX,
  double velocityY,
  double velocityZ,
);

@Native<Int32 Function(Uint32, Float)>(symbol: 'seek')
external int seek(int handle, double time);

typedef DartVoiceEndedCallback = Void Function(Pointer<Uint32>);
typedef DartFileLoadedCallback =
    Void Function(
      Pointer<Int32>,
      Pointer<Utf8>,
      Pointer<Uint32>,
      Pointer<Uint64>,
    );
typedef DartStateChangedCallback = Void Function(Pointer<Int32>);

@Native<
  Void Function(
    Pointer<NativeFunction<DartVoiceEndedCallback>>,
    Pointer<NativeFunction<DartFileLoadedCallback>>,
    Pointer<NativeFunction<DartStateChangedCallback>>,
  )
>(symbol: 'setDartEventCallback')
external void setDartEventCallback(
  Pointer<NativeFunction<DartVoiceEndedCallback>> voiceEnded,
  Pointer<NativeFunction<DartFileLoadedCallback>> fileLoaded,
  Pointer<NativeFunction<DartStateChangedCallback>> stateChanged,
);
@Native<Double Function(Uint32)>(symbol: 'getLength')
external double getLength(int hash);

@Native<Double Function(Uint32)>(symbol: 'getPosition')
external double getPosition(int handle);
