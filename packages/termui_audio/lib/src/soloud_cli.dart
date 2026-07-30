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

@Native<Int32 Function(Int32, Int32, Float, Float, Pointer<Uint32>)>(
  symbol: 'loadWaveform',
)
external int loadWaveform(
  int waveform,
  int superWave,
  double scale,
  double detune,
  Pointer<Uint32> hash,
);

@Native<Void Function(Uint32, Float)>(symbol: 'setWaveformFreq')
external void setWaveformFreq(int hash, double newFreq);

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

@Native<Void Function(Uint32, Bool)>(symbol: 'setPause')
external void setPause(int handle, bool pause);

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

@Native<Void Function(Uint32, Float, Float)>(
  symbol: 'set3dSourceMinMaxDistance',
)
external void set3dSourceMinMaxDistance(
  int handle,
  double minDistance,
  double maxDistance,
);

@Native<Void Function(Uint32, Uint32, Float)>(symbol: 'set3dSourceAttenuation')
external void set3dSourceAttenuation(
  int handle,
  int attenuationModel,
  double attenuationRolloffFactor,
);

@Native<Int32 Function(Uint32, Float)>(symbol: 'seek')
external int seek(int handle, double time);

typedef DartVoiceEndedFunction = Void Function(Pointer<Uint32>);
typedef DartFileLoadedFunction =
    Void Function(
      Pointer<Int32>,
      Pointer<Utf8>,
      Pointer<Uint32>,
      Pointer<Uint64>,
    );
typedef DartStateChangedFunction = Void Function(Pointer<Int32>);

@Native<Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)>(
  symbol: 'setDartEventCallback',
)
external void setDartEventCallback(
  Pointer<Void> voiceEnded,
  Pointer<Void> fileLoaded,
  Pointer<Void> stateChanged,
);
@Native<Double Function(Uint32)>(symbol: 'getLength')
external double getLength(int hash);

@Native<Double Function(Uint32)>(symbol: 'getPosition')
external double getPosition(int handle);

@Native<Void Function(Uint32, Float)>(symbol: 'setRelativePlaySpeed')
external void setRelativePlaySpeed(int handle, double speed);

@Native<Int32 Function(Uint32, Float, Float)>(symbol: 'fadeRelativePlaySpeed')
external int fadeRelativePlaySpeed(int handle, double to, double time);

@Native<Int32 Function(Uint32, Float, Float)>(symbol: 'fadeVolume')
external int fadeVolume(int handle, double to, double time);

@Native<Int32 Function(Uint32, Float)>(symbol: 'scheduleStop')
external int scheduleStop(int handle, double time);

@Native<Int32 Function(Uint32, Uint32, Int32)>(symbol: 'addFilter')
external int addFilter(int soundHash, int busId, int filterType);

@Native<Int32 Function(Uint32, Uint32, Int32, Int32, Float)>(
  symbol: 'setFilterParams',
)
external int setFilterParams(
  int handle,
  int busId,
  int filterType,
  int attributeId,
  double value,
);

@Native<Int32 Function(Uint32, Uint32, Int32, Int32, Pointer<Float>)>(
  symbol: 'getFilterParams',
)
external int getFilterParams(
  int handle,
  int busId,
  int filterType,
  int attributeId,
  Pointer<Float> filterValue,
);

@Native<Int32 Function(Uint32, Uint32, Int32, Int32, Float, Float)>(
  symbol: 'fadeFilterParameter',
)
external int fadeFilterParameter(
  int handle,
  int busId,
  int filterType,
  int attributeId,
  double to,
  double time,
);

@Native<Void Function(Pointer<Pointer<Float>>, Pointer<Bool>)>(
  symbol: 'getWave',
)
external void getWave(
  Pointer<Pointer<Float>> wave,
  Pointer<Bool> isTheSameAsBefore,
);

@Native<Void Function(Bool)>(symbol: 'setVisualizationEnabled')
external void setVisualizationEnabled(bool enabled);

@Native<Uint32 Function()>(symbol: 'createBus')
external int createBus();

@Native<Void Function(Uint32)>(symbol: 'destroyBus')
external void destroyBus(int busId);

@Native<Uint32 Function(Uint32, Float, Bool)>(symbol: 'busPlayOnEngine')
external int busPlayOnEngine(int busId, double volume, bool paused);

@Native<Float Function(Uint32)>(symbol: 'Soloud_getApproximateVolume')
external double getApproximateVolume(int channel);

@Native<Void Function(Pointer<Int16>, Uint32)>(symbol: 'Soloud_mixSigned16')
external void mixSigned16(Pointer<Int16> buffer, int samples);
