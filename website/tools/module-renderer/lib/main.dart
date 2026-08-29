// SPDX-License-Identifier: GPL-3.0-or-later

/// Renders one of the application's modules, filling the window, so that a
/// headless browser can photograph it.
///
/// This exists because the website used to draw its own approximations of the
/// fourteen meters in JavaScript, and an approximation of a measurement display
/// is the one thing this project should not ship: the modules would drift apart
/// silently, and a picture of a meter that disagrees with the meter is worse
/// than no picture. So the website's thumbnails are photographs of the real
/// widgets instead, taken from `package:oaa` itself — there is nothing here to
/// keep in sync, because there is no second copy.
///
/// Driven entirely by the query string, one module per page load:
///
///     ?module=spectrum_analyzer&columns=8&rows=6
///
/// See `website/scripts/render-modules.mjs`, which builds this, serves it and
/// walks the list.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:oaa/src/canvas/module_host.dart';
import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_replay/oaa_replay.dart';
import 'package:oaa_ui/oaa_ui.dart';

/// Set on `globalThis` once the programme has frozen and a frame has been
/// painted holding its final reading.
///
/// The renderer polls for it and photographs the page when it appears. Waiting
/// on the picture rather than on a stopwatch is what makes the images
/// reproducible: a slow machine takes longer to get here and produces the same
/// bytes, where a fixed delay would produce a half-finished spectrogram.
@JS('oaaRenderReady')
external set _renderReady(bool value);

void main() => runApp(const RendererApp());

@JS('fetch')
external JSPromise<_Response> _fetch(String url);

extension type _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external int get status;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

/// The recording, off the local server this page is served from. No gzip and no
/// streaming: it is a file on the same disk.
Future<Uint8List> _fetchBytes(String url) async {
  final response = await _fetch(url).toDart;
  if (!response.ok) throw StateError('$url returned ${response.status}');
  final buffer = await response.arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}

@JS('AudioContext')
extension type _AudioContext._(JSObject _) implements JSObject {
  external factory _AudioContext([_AudioContextOptions options]);
  external JSPromise<_AudioBuffer> decodeAudioData(JSArrayBuffer data);
}

/// Which rate to decode at: the recording's.
///
/// Without it the context adopts the output device's rate and
/// `decodeAudioData` resamples to that, so a machine set to 48 kHz decodes
/// 48,000 samples for every 44,100 the recording counts — and `ReplaySource`
/// hands the oscilloscope a window in one time base while `elapsedSeconds`
/// counts in another. Nothing is played here at all, so the request costs
/// nothing but the asking.
extension type _AudioContextOptions._(JSObject _) implements JSObject {
  external factory _AudioContextOptions({int sampleRate});
}

extension type _AudioBuffer._(JSObject _) implements JSObject {
  external int get numberOfChannels;
  external int get sampleRate;
  external int get length;
  external JSFloat32Array getChannelData(int channel);
}

/// The decoded excerpt, interleaved, which is the shape a scope reads.
class _Audio {
  const _Audio({
    required this.samples,
    required this.sampleRate,
    required this.channels,
  });

  final Float32List samples;
  final int sampleRate;
  final int channels;
}

/// Decode the excerpt, or return null.
///
/// Null rather than throwing: twelve of the fourteen modules do not draw a
/// waveform, and failing every photograph because two of them would be empty is
/// the wrong trade. The two that need it come out visibly blank, which is a
/// failure somebody sees.
Future<_Audio?> _decodeAudio(String url, int sampleRate) async {
  try {
    final bytes = await _fetchBytes(url);
    _AudioContext context;
    try {
      context = _AudioContext(_AudioContextOptions(sampleRate: sampleRate));
    } on Object {
      // A rate the implementation will not take, which there is no asking
      // about beforehand. The window is still correct, at the cost of a
      // resample — see `ReplaySource._fillScope`.
      context = _AudioContext();
    }
    // A copy: decodeAudioData detaches the buffer it is handed.
    final data = Uint8List.fromList(bytes);
    final buffer = await context.decodeAudioData(data.buffer.toJS).toDart;

    final channels = buffer.numberOfChannels;
    final frames = buffer.length;
    final samples = Float32List(frames * channels);
    for (var channel = 0; channel < channels; channel++) {
      final plane = buffer.getChannelData(channel).toDart;
      for (var frame = 0; frame < frames; frame++) {
        samples[frame * channels + channel] = plane[frame];
      }
    }
    return _Audio(
      samples: samples,
      sampleRate: buffer.sampleRate,
      channels: channels,
    );
  } on Object {
    return null;
  }
}

/// The delivery target the stills are shot against.
///
/// Streaming rather than broadcast because the recorded track is a loud modern
/// master — about -8 LUFS against this target's -14 — so it misses on loudness
/// and on true peak. That is the point, and it is not staged: a validator that
/// always passes and an alert meter that is never red teach a reader nothing
/// about what these modules are for.
const _calibration = Calibration(
  id: 'streaming',
  name: 'Streaming',
  lufsTarget: -14.0,
  lufsTolerance: 0.5,
  truePeakMax: -1.0,
  loudnessRangeMax: 12.0,
);

class RendererApp extends StatefulWidget {
  const RendererApp({super.key});

  @override
  State<RendererApp> createState() => _RendererAppState();
}

class _RendererAppState extends State<RendererApp>
    with SingleTickerProviderStateMixin {
  /// The recording, written beside this page by `npm run record`.
  ///
  /// The full one, not the site's: the stereo cloud draws per-band stereo
  /// position, which the file the website ships leaves out because none of the
  /// eight modules on that canvas reads it.
  static const _recordingUrl = 'programme.oaa';

  /// The audio the recording was taken from.
  ///
  /// The oscilloscope and the phase scope draw the newest stereo frames,
  /// which is the waveform itself and is deliberately not in the recording —
  /// see the note on the scope in `oaa_replay`. Decoding needs no interaction
  /// and no playback: this page never makes a sound, it just needs the samples.
  static const _audioUrl = 'programme.wav';

  ReplaySource? _source;
  MeterClock? _clock;
  Recording? _recording;
  String? _failure;

  /// How much programme to play before the shutter opens.
  ///
  /// Long enough that the integrated reading has settled and there are enough
  /// short-term blocks for a range; the modules with a time axis ask for more.
  static final double _captureAt =
      double.tryParse(Uri.base.queryParameters['seconds'] ?? '') ?? 14.0;

  /// Stepped by frame rather than by clock, so the same picture comes out every
  /// time regardless of how fast the machine rendering it is.
  int _frame = 0;
  bool _frozen = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final bytes = await _fetchBytes(_recordingUrl);
      if (!mounted) return;
      final recording = Recording.parse(bytes);
      final source = ReplaySource(
        recording,
        positionSeconds: () => _frame / recording.header.fps,
        // A still stops at the end rather than wrapping round to the start.
        loop: false,
      );

      final audio = await _decodeAudio(_audioUrl, recording.header.sampleRate);
      if (audio != null) {
        source.attachPcm(
          audio.samples,
          sampleRate: audio.sampleRate,
          channels: audio.channels,
        );
      }
      setState(() {
        _recording = recording;
        _source = source;
        _clock = MeterClock(engine: source, vsync: this)..addListener(_onTick);
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _failure = '$error');
    }
  }

  void _onTick() {
    final recording = _recording;
    if (recording == null || _frozen) return;

    final fps = recording.header.fps;
    if (_frame / fps >= _captureAt || _frame >= recording.frames - 1) {
      _frozen = true;
      _announceReady();
      return;
    }
    _frame++;
  }

  /// The frozen reading is set during the tick, *before* the frame that shows
  /// it has been painted. Two frames' grace, then the shutter may open.
  void _announceReady() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _renderReady = true);
    });
  }

  @override
  void dispose() {
    _clock?.dispose();
    super.dispose();
  }

  ModuleSpec _spec() {
    final q = Uri.base.queryParameters;
    final kind = ModuleKind.fromId(q['module'] ?? '') ?? ModuleKind.lufsMeter;

    // A module's appearance depends on how many cells it was given, not only on
    // how many pixels: several of them decide what to label and whether to draw
    // a scale from the cell count. So the renderer passes both, and the caller
    // keeps them in proportion.
    final columns = int.tryParse(q['columns'] ?? '') ?? kind.defaultColumns;
    final rows = int.tryParse(q['rows'] ?? '') ?? kind.defaultRows;

    return ModuleSpec(
      id: kind.id,
      kind: kind,
      rect: GridRect(column: 0, row: 0, columns: columns, rows: rows),
      // Anything else in the query string is passed through as a module option,
      // so a thumbnail can ask for a particular metric or channel mode without
      // this file growing a case for each one.
      options: {
        for (final entry in q.entries)
          if (!const {
            'module',
            'columns',
            'rows',
            'w',
            'h',
            'fw',
            'fh',
            'seconds',
          }.contains(entry.key))
            entry.key: entry.value,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = oaaColorsFromSkin(BuiltInSkins.precisionInstrument);
    final q = Uri.base.queryParameters;

    // The frame every photograph comes out as, so the catalogue is a grid of
    // identically sized pictures.
    final frameW = double.tryParse(q['fw'] ?? '') ?? 360;
    final frameH = double.tryParse(q['fh'] ?? '') ?? 236;

    // The module inside it. Most fill the frame — a module is resizable on the
    // real canvas and these are the proportions most of them are happiest at.
    // The two bar meters are not: stretched this wide, a pair of vertical bars
    // becomes a pair of squat slabs. They keep their own width and sit centred
    // in the frame instead, which is why the frame exists.
    final width = double.tryParse(q['w'] ?? '') ?? frameW;
    final height = double.tryParse(q['h'] ?? '') ?? frameH;

    return OaaTheme(
      colors: colors,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          color: colors.background,
          // Pinned to the top-left rather than filling the window, because
          // headless Chrome refuses to open a window narrower than 500 px:
          // asking for a 360 px one silently lays the page out at 500 and hands
          // back a picture of the wrong layout. Anchoring here means the frame
          // is the same size whatever window the renderer got, and the caller
          // clips a known rectangle out of the corner.
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: frameW,
            height: frameH,
            child: Center(
              child: SizedBox(
                width: width,
                height: height,
                child: _module(colors),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _module(OaaColors colors) {
    final source = _source;
    final clock = _clock;
    final failure = _failure;

    // A renderer that draws an empty frame when the recording is missing takes
    // fourteen photographs of nothing and reports success. Saying so on the
    // picture means the failure is visible in the file it produced.
    if (failure != null) {
      return Center(
        child: Text(
          'no recording: $failure\nrun `npm run record`',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colors.over,
            fontFamily: 'Google Sans Code',
            fontSize: 10,
          ),
        ),
      );
    }
    if (source == null || clock == null) return const SizedBox.shrink();

    return ModuleHost(
      spec: _spec(),
      engine: source,
      clock: clock,
      calibration: _calibration,
      selected: false,
      // Null, as on the remote display: a menu button that cannot be pressed in
      // a photograph should not be drawn in one.
      onMenu: null,
    );
  }
}
