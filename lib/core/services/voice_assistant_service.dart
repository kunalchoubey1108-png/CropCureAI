import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

enum TtsPlaybackState { stopped, playing, paused }

/// Offline voice readout via the device's native TTS engine.
///
/// Uses the platform speech synthesizer (Android TextToSpeech / iOS
/// AVSpeechSynthesizer), so Hindi and English voices work with no network
/// once the device has the language packs — which ship by default on most
/// Android builds sold in India.
class VoiceAssistantService {
  VoiceAssistantService() {
    _tts.setStartHandler(() => state.value = TtsPlaybackState.playing);
    _tts.setCompletionHandler(() => state.value = TtsPlaybackState.stopped);
    _tts.setCancelHandler(() => state.value = TtsPlaybackState.stopped);
    _tts.setPauseHandler(() => state.value = TtsPlaybackState.paused);
    _tts.setContinueHandler(() => state.value = TtsPlaybackState.playing);
    _tts.setErrorHandler((_) => state.value = TtsPlaybackState.stopped);
  }

  static final VoiceAssistantService instance = VoiceAssistantService();

  static const String hindi = 'hi-IN';
  static const String english = 'en-IN';

  final FlutterTts _tts = FlutterTts();

  /// Observable playback state for UI (speaker FAB, pause button).
  final ValueNotifier<TtsPlaybackState> state = ValueNotifier(
    TtsPlaybackState.stopped,
  );

  bool _configured = false;
  String _lastText = '';
  String _lastLanguage = english;

  Future<void> _configure() async {
    if (_configured) return;
    _configured = true;
    // Slow, clear delivery for field use.
    await _tts.setSpeechRate(0.45);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
  }

  /// Speaks in the given language code ('hi' / 'en' shorthands accepted).
  Future<void> speak(String text, String language) {
    final code = switch (language) {
      'hi' => hindi,
      'en' => english,
      _ => language,
    };
    return _speak(text, code);
  }

  Future<void> _speak(String text, String languageCode) async {
    if (text.trim().isEmpty) return;
    try {
      await _configure();
      await stop();
      await _tts.setLanguage(languageCode);
      _lastText = text;
      _lastLanguage = languageCode;
      state.value = TtsPlaybackState.playing;
      await _tts.speak(text);
    } catch (e) {
      state.value = TtsPlaybackState.stopped;
      debugPrint('VoiceAssistantService: speak failed ($e)');
    }
  }

  /// True pause on iOS; on Android engines without pause support the
  /// engine stops instead, and [resume] restarts the readout.
  Future<void> pause() async {
    try {
      await _tts.pause();
      state.value = TtsPlaybackState.paused;
    } catch (e) {
      debugPrint('VoiceAssistantService: pause failed ($e)');
    }
  }

  /// Resumes by re-speaking the last text (native cross-platform resume
  /// is not available in flutter_tts 3.x).
  Future<void> resume() async {
    if (_lastText.isEmpty) return;
    await _speak(_lastText, _lastLanguage);
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (e) {
      debugPrint('VoiceAssistantService: stop failed ($e)');
    }
    state.value = TtsPlaybackState.stopped;
  }
}
