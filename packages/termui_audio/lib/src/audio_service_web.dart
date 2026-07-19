import 'audio_service.dart';
import 'audio_service_web_impl.dart';

/// Web environment factory function.
AudioService createAudioService() => WebAudioService();
