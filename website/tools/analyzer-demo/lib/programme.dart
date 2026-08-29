// SPDX-License-Identifier: GPL-3.0-or-later

/// Fetching the recording, and playing the music it was taken from.
///
/// ---------------------------------------------------------------------------
/// Two files, one instant
///
/// `oaa_record` writes both of these in the same pass: the recording is what
/// the engine measured, and the audio is exactly the samples it measured. They
/// are cut by the loop that pushed them rather than by two tools agreeing on a
/// timestamp, which is what lets the meters and the music be the same moment
/// instead of nearly the same moment.
///
/// ---------------------------------------------------------------------------
/// Why the audio needs a second press
///
/// A browser will not start audio until somebody has interacted with *that*
/// document, and the press that opened this analyzer happened in the page
/// above, in a different document. So the canvas starts silent and running,
/// driven by a plain clock, and a control offers the sound. Taking it hands the
/// timekeeping over to the audio clock, from the position the silent one had
/// reached — so the picture does not jump when the music arrives.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// The small piece of the platform this needs.
//
// Declared here rather than taken from `package:web`, which is a large surface
// for four calls, and none of these are the kind of API that changes.

@JS('fetch')
external JSPromise<_Response> _fetch(String url);

extension type _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external int get status;
  external JSPromise<JSArrayBuffer> arrayBuffer();
  external _ReadableStream? get body;
}

extension type _ReadableStream._(JSObject _) implements JSObject {
  external _ReadableStream pipeThrough(_DecompressionStream transform);
}

@JS('DecompressionStream')
extension type _DecompressionStream._(JSObject _) implements JSObject {
  external factory _DecompressionStream(String format);
}

@JS('Response')
extension type _ResponseCtor._(JSObject _) implements JSObject {
  external factory _ResponseCtor(JSAny? body);
  external _ReadableStream? get body;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

@JS('AudioContext')
extension type AudioContext._(JSObject _) implements JSObject {
  external factory AudioContext([_AudioContextOptions options]);
  external double get currentTime;
  external String get state;
  external JSPromise<JSAny?> resume();
  external JSPromise<AudioBuffer> decodeAudioData(JSArrayBuffer data);
  external AudioBufferSourceNode createBufferSource();
  external JSObject get destination;
}

/// Which rate to decode and play at.
///
/// The recording's, always. A context created without this adopts the output
/// device's rate and `decodeAudioData` resamples the track to it, so on a Mac
/// set to 48 kHz the browser would hand back 48,000 samples for every 44,100
/// the recording counts — and the oscilloscope, which works out what is new
/// from the recording's clock, would take nine per cent less audio per frame
/// than went past. Asking for it here is exact and costs nothing: the output
/// stage resamples instead, which is where a rate conversion belongs.
extension type _AudioContextOptions._(JSObject _) implements JSObject {
  external factory _AudioContextOptions({int sampleRate});
}

extension type AudioBuffer._(JSObject _) implements JSObject {
  external int get numberOfChannels;
  external int get sampleRate;
  external int get length;
  external double get duration;
  external JSFloat32Array getChannelData(int channel);
}

extension type AudioBufferSourceNode._(JSObject _) implements JSObject {
  external set buffer(AudioBuffer value);
  external set loop(bool value);
  external void connect(JSObject destination);
  external void start(double when, double offset);
  external void stop();
}

// ---------------------------------------------------------------------------

/// The recording and the audio, once both have arrived.
class Programme {
  Programme({required this.recordingBytes, required this.audio});

  /// The `.oaa` file, decompressed.
  final Uint8List recordingBytes;

  /// The excerpt, ready to be decoded and played. Null when it could not be
  /// fetched, in which case the canvas runs silently and says so.
  final Uint8List? audio;
}

/// Fetch both, in parallel.
///
/// The recording is gzipped by `npm run record` rather than left to the host: a
/// static host will not always compress an `application/octet-stream`, and
/// 1.2 MB arriving uncompressed because of a MIME type is not a failure anybody
/// would notice. See [_fetchRecording] for the other half of that decision.
Future<Programme> loadProgramme({
  required String recordingUrl,
  required String audioUrl,
}) async {
  final results = await Future.wait([
    _fetchRecording(recordingUrl),
    _fetchBytes(audioUrl).catchError((Object _) => null),
  ]);
  return Programme(recordingBytes: results[0]!, audio: results[1]);
}

Future<Uint8List?> _fetchBytes(String url) async {
  final response = await _fetch(url).toDart;
  if (!response.ok) {
    throw StateError('$url returned ${response.status}');
  }
  final buffer = await response.arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}

/// The recording, decompressed if it arrived that way.
///
/// It is gzipped on disk and served under a name no server recognises, which is
/// deliberate. Served as `.gz`, a static host is entitled to notice the
/// extension and send `Content-Encoding: gzip` — and then the browser
/// decompresses it on the way in, this decompresses it again, and the fetch
/// fails with a type error that says nothing about why. Astro's own preview
/// server does exactly that, which is how this was found.
///
/// Whether a host does it is not a property of this code, so the magic number
/// decides rather than the header: `1f 8b` means the bytes are still gzip and
/// need unpacking, anything else means somebody already unpacked them. The
/// `content-encoding` header cannot be used for this — a browser strips it from
/// a response it has decoded, so it reads the same either way.
Future<Uint8List?> _fetchRecording(String url) async {
  final response = await _fetch(url).toDart;
  if (!response.ok) {
    throw StateError('$url returned ${response.status}');
  }
  final bytes = (await response.arrayBuffer().toDart).toDart.asUint8List();
  if (bytes.length < 2 || bytes[0] != 0x1f || bytes[1] != 0x8b) return bytes;

  final packed = _ResponseCtor(bytes.toJS);
  final body = packed.body;
  if (body == null) return bytes;
  final unpacked = _ResponseCtor(
    body.pipeThrough(_DecompressionStream('gzip')),
  );
  return (await unpacked.arrayBuffer().toDart).toDart.asUint8List();
}

// ---------------------------------------------------------------------------

/// Where the playhead is, whether or not anything is audible.
///
/// One object so that the meters read a single position: with sound it is the
/// audio clock, without it is elapsed time, and the handover keeps the value
/// continuous. Two clocks running side by side would drift, and a metering
/// demo whose numbers lag its music by a second is worse than a silent one.
class Playhead {
  Playhead({required this.lengthSeconds, required this.sampleRate});

  /// The recording's length. The audio loops at this too, so the position is
  /// taken modulo it in one place.
  final double lengthSeconds;

  /// The rate the recording was measured at, which is the rate the excerpt is
  /// decoded at. See [_AudioContextOptions].
  final int sampleRate;

  final Stopwatch _silent = Stopwatch()..start();

  AudioContext? _context;
  AudioBufferSourceNode? _node;
  double _audioStartedAt = 0.0;
  double _audioStartedFrom = 0.0;

  bool get isPlaying => _node != null;

  /// Seconds into the programme.
  double get seconds {
    final context = _context;
    final node = _node;
    if (context != null && node != null) {
      final played = context.currentTime - _audioStartedAt;
      return (_audioStartedFrom + played) % lengthSeconds;
    }
    return (_silent.elapsedMicroseconds / 1e6) % lengthSeconds;
  }

  AudioBuffer? _buffer;

  /// Decode the excerpt, without making a sound.
  ///
  /// Decoding needs no interaction — only *playing* does — so this runs as soon
  /// as the bytes arrive, and the oscilloscope has a waveform from the first
  /// frame whether or not anybody ever asks for the audio. The context it
  /// creates starts suspended, which is exactly what is wanted.
  ///
  /// Returns the buffer so the caller can hand its samples to the source: the
  /// same samples that will play, rather than a second copy fetched separately.
  Future<AudioBuffer?> prepare(Uint8List audio) async {
    final context = _context ??= _open();
    // A copy, because decodeAudioData detaches the buffer it is given.
    final data = Uint8List.fromList(audio);
    return _buffer = await context.decodeAudioData(data.buffer.toJS).toDart;
  }

  /// A context at the recording's rate, or the device's if that is refused.
  ///
  /// A rate outside what the implementation supports throws, and there is no
  /// asking beforehand which those are. Falling back is safe rather than
  /// merely tidy: `ReplaySource` reads what it was handed back off the decoded
  /// buffer and steps through it accordingly, so a refusal costs a resample and
  /// not a wrong picture.
  AudioContext _open() {
    try {
      return AudioContext(_AudioContextOptions(sampleRate: sampleRate));
    } on Object {
      return AudioContext();
    }
  }

  /// Start the audio from wherever the silent clock has reached.
  Future<void> play() async {
    final context = _context;
    final buffer = _buffer;
    if (context == null || buffer == null || _node != null) return;

    if (context.state != 'running') {
      await context.resume().toDart;
    }

    final from = seconds;
    final node = context.createBufferSource()
      ..buffer = buffer
      ..loop = true;
    node.connect(context.destination);
    node.start(0, from);

    // Read after `start`, so the handover measures from the instant the audio
    // actually began rather than from the instant it was asked to.
    _audioStartedAt = context.currentTime;
    _audioStartedFrom = from;
    _node = node;
  }
}

/// The decoded audio as one interleaved buffer, which is what a scope reads.
Float32List interleave(AudioBuffer buffer) {
  final channels = buffer.numberOfChannels;
  final frames = buffer.length;
  final out = Float32List(frames * channels);
  for (var channel = 0; channel < channels; channel++) {
    final data = buffer.getChannelData(channel).toDart;
    for (var frame = 0; frame < frames; frame++) {
      out[frame * channels + channel] = data[frame];
    }
  }
  return out;
}
