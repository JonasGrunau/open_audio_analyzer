// SPDX-License-Identifier: GPL-3.0-or-later

/// A canvas of the application's real meter modules, running live in a browser.
///
/// What the website embeds behind "Load the live analyzer". Every module here is
/// the real one from `package:oaa` — the same `ModuleHost`, the same
/// `ModuleFrame`, the same painters, laid out on the same `GridGeometry` and
/// repainting from one `MeterClock`, exactly as the desktop canvas and the
/// tablet remote display do.
///
/// The numbers are the engine's too, and they are measurements of real music —
/// they are just not being taken here. `dart:ffi` has no web implementation, so
/// this build never reaches `OaaEngine`; instead `oaa_record` ran the engine
/// over a CC BY track on a machine that has one, wrote down what it measured,
/// and `ReplaySource` plays that back. It is the fourth `MeterSource`, beside
/// the native one, the socket the tablet reads and the mock that used to stand
/// here. Nothing on this canvas knows the difference, which is the point of
/// that interface — and this is the implementation the interface was for.
///
/// The audio is the same excerpt, so the meters and the music are one instant
/// rather than two clocks agreeing. It starts silent: a browser will not play
/// sound until somebody has interacted with *this* document, and the press that
/// opened it happened in the page above. See `programme.dart`.
///
///     ?seconds=32      freeze after this much programme, for a screenshot
///
/// Without it the programme runs, and loops.
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:oaa/src/canvas/module_host.dart';
import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_replay/oaa_replay.dart';
import 'package:oaa_ui/oaa_ui.dart';

import 'programme.dart';

/// Set once the programme has frozen and the final frame is painted. Only
/// meaningful when `?seconds=` was given — see `scripts/render-analyzer.mjs`.
@JS('oaaRenderReady')
external set _renderReady(bool value);

/// Set as soon as anything has actually been drawn.
///
/// The page that embeds this waits for it before fading the iframe in over the
/// still. `load` is too early: it fires when the document is parsed, several
/// seconds before CanvasKit has been fetched and the first frame painted, so
/// fading on it swapped a photograph of the meters for an empty panel.
@JS('oaaFirstFrame')
external set _firstFrame(bool value);

void main() => runApp(const AnalyzerDemo());

const _calibration = Calibration(
  id: 'streaming',
  name: 'Streaming',
  lufsTarget: -14.0,
  lufsTolerance: 0.5,
  truePeakMax: -1.0,
  loudnessRangeMax: 12.0,
);

/// The canvas, as one tab of eight modules on the 24x16 grid.
///
/// Authored here rather than read from a preset because it is a piece of the
/// website: it is chosen to show the range of what the application draws — bars,
/// arcs, a spectrum, a time axis, a verdict, a waveform — in one screen. Every
/// rect clears its module's stated minimum in [ModuleKind]; a rect that does not
/// draws `ModuleTooSmall`, which is honest and not what a demo is for.
final _tab = TabSpec(
  name: 'Mastering',
  modules: [
    // Loudness, across the top.
    const ModuleSpec(
      id: 'lufs',
      kind: ModuleKind.lufsMeter,
      rect: GridRect(column: 0, row: 0, columns: 5, rows: 8),
    ),
    const ModuleSpec(
      id: 'super',
      kind: ModuleKind.superMeter,
      rect: GridRect(column: 5, row: 0, columns: 8, rows: 8),
    ),
    const ModuleSpec(
      id: 'spectrum',
      kind: ModuleKind.spectrumAnalyzer,
      rect: GridRect(column: 13, row: 0, columns: 11, rows: 8),
    ),
    // How the programme moved, what it delivers against, and the channels.
    const ModuleSpec(
      id: 'histogram',
      kind: ModuleKind.histogram,
      rect: GridRect(column: 0, row: 8, columns: 13, rows: 5),
    ),
    const ModuleSpec(
      id: 'validator',
      kind: ModuleKind.validator,
      rect: GridRect(column: 13, row: 8, columns: 6, rows: 5),
    ),
    const ModuleSpec(
      id: 'digital',
      kind: ModuleKind.digitalMeter,
      rect: GridRect(column: 19, row: 8, columns: 5, rows: 8),
    ),
    // The signal itself, and the one thing that is failing.
    const ModuleSpec(
      id: 'scope',
      kind: ModuleKind.oscilloscope,
      rect: GridRect(column: 0, row: 13, columns: 13, rows: 3),
      // Five seconds rather than twenty milliseconds, overlaid rather than in
      // lanes. A triggered 20 ms window is the right default in the
      // application, where the picture is live and a person is looking for a
      // waveform's shape; on a page it is a still of one cycle and reads as an
      // ornament. Five seconds rolls, so the still shows the programme's
      // envelope over a phrase — which is the same forty-five seconds every
      // other module on this canvas is reading. Overlay puts both channels
      // around one centre line, which buys the trace the whole three rows
      // instead of half of them.
      // The zoom is 1.2 rather than 1: at full scale this track's envelope used
      // about four fifths of the lane and left a band of empty panel above and
      // below it. A fifth more fills the lane without the peaks reaching the
      // edge — which is the line to hold, because what runs past a lane is cut
      // off by it, and a trace clipped flat at the top reads as a mix that
      // clipped rather than as a picture that was zoomed.
      options: {'timeBase': '5s', 'stereo': 'overlay', 'zoom': 1.2},
    ),
    const ModuleSpec(
      id: 'alert',
      kind: ModuleKind.alertMeter,
      rect: GridRect(column: 13, row: 13, columns: 6, rows: 3),
    ),
  ],
);

class AnalyzerDemo extends StatefulWidget {
  const AnalyzerDemo({super.key});

  @override
  State<AnalyzerDemo> createState() => _AnalyzerDemoState();
}

class _AnalyzerDemoState extends State<AnalyzerDemo>
    with SingleTickerProviderStateMixin {
  /// Where the recording and the excerpt are served from. Relative, so the
  /// build's `--base-href` puts them under /analyzer/ on the site and beside
  /// the page on a local server.
  static const _recordingUrl = 'programme.oaaz';
  static const _audioUrl = 'programme.m4a';

  /// A screenshot asks for a fixed amount of programme and then stops, so that
  /// the same picture comes out every time. Without it this runs and loops.
  static final double? _captureAt = double.tryParse(
    Uri.base.queryParameters['seconds'] ?? '',
  );

  ReplaySource? _source;
  MeterClock? _clock;
  Playhead? _playhead;

  /// The frame counter a screenshot advances by, in place of a clock. A still
  /// driven by wall time is a still that depends on how fast the machine
  /// rendering it happened to be.
  int _frame = 0;
  bool _frozen = false;

  bool _audioReady = false;
  bool _audioStarting = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _firstFrame = true);
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final programme = await loadProgramme(
        recordingUrl: _recordingUrl,
        audioUrl: _audioUrl,
      );
      if (!mounted) return;

      final recording = Recording.parse(programme.recordingBytes);
      final playhead = Playhead(
        lengthSeconds: recording.seconds,
        sampleRate: recording.header.sampleRate,
      );
      final source = ReplaySource(
        recording,
        positionSeconds: () =>
            _capturing ? _frame / recording.header.fps : playhead.seconds,
        // A screenshot stops at the end rather than wrapping to the start.
        loop: !_capturing,
      );

      setState(() {
        _playhead = playhead;
        _source = source;
        _clock = MeterClock(engine: source, vsync: this)..addListener(_onTick);
      });

      // The waveform, before anybody asks for sound. The oscilloscope and the
      // phase scope draw the newest stereo frames — the audio itself — so
      // decoding it now means they are drawing from the first frame rather than
      // sitting empty until somebody presses a button. Decoding is allowed
      // without interaction; only playing is not.
      final audio = programme.audio;
      if (audio != null) {
        final buffer = await playhead.prepare(audio);
        if (!mounted) return;
        if (buffer != null) {
          source.attachPcm(
            interleave(buffer),
            sampleRate: buffer.sampleRate,
            channels: buffer.numberOfChannels,
          );
          setState(() => _audioReady = true);
        }
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _failure = '$error');
    }
  }

  bool get _capturing => _captureAt != null;

  /// Advance the screenshot's frame counter, and announce when it is done.
  void _onTick() {
    final captureAt = _captureAt;
    final source = _source;
    if (captureAt == null || source == null || _frozen) return;

    final fps = source.recording.header.fps;
    if (_frame / fps >= captureAt || _frame >= source.recording.frames - 1) {
      _frozen = true;
      // Two frames: one to paint the final state, one to be sure it is on the
      // screen before anything photographs it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _renderReady = true,
        );
      });
      return;
    }
    _frame++;
  }

  Future<void> _startAudio() async {
    final playhead = _playhead;
    if (playhead == null || !_audioReady) return;

    setState(() => _audioStarting = true);
    try {
      await playhead.play();
    } on Object {
      // A refused AudioContext is not worth an error on the canvas: the meters
      // are the point and they are already running.
    } finally {
      if (mounted) setState(() => _audioStarting = false);
    }
  }

  @override
  void dispose() {
    _clock?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = oaaColorsFromSkin(BuiltInSkins.precisionInstrument);

    return OaaTheme(
      colors: colors,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          color: colors.background,
          padding: const EdgeInsets.all(Space.sm),
          child: _body(colors),
        ),
      ),
    );
  }

  Widget _body(OaaColors colors) {
    final source = _source;
    final clock = _clock;
    final failure = _failure;

    if (failure != null) {
      return _Notice(
        text: 'The recording could not be loaded.\n$failure',
        colors: colors,
      );
    }
    if (source == null || clock == null) {
      return _Notice(text: 'Loading the programme…', colors: colors);
    }

    return Stack(
      children: [
        // The same composition the tablet's canvas uses: one GridGeometry sized
        // to whatever the window is, every module positioned by the rect it
        // declares, and each keyed by id so that resizing preserves the State
        // its painter has laid its paragraphs out in.
        LayoutBuilder(
          builder: (context, constraints) {
            final geometry = GridGeometry(size: constraints.biggest);

            return Stack(
              children: [
                for (final module in _tab.modules)
                  Positioned.fromRect(
                    rect: geometry.rectFor(module.rect),
                    key: ValueKey<String>(module.id),
                    child: ModuleHost(
                      spec: module,
                      engine: source,
                      clock: clock,
                      calibration: _calibration,
                      selected: false,
                      // Nothing on this canvas can be changed, so no module
                      // draws a menu button — a control that swallows the tap
                      // is worse than no control.
                      onMenu: null,
                    ),
                  ),
              ],
            );
          },
        ),
        // Not while capturing. The audio is still decoded — the oscilloscope
        // and the phase scope are drawing from it — but a still that
        // photographs this control is a picture of a button, and the still is
        // the whole of what a phone is shown: the front page draws no control
        // of its own there either, so the only play mark left on the screen
        // would have been one inside a photograph. See the media query in
        // `website/src/pages/index.astro`.
        if (!_capturing && _audioReady && !(_playhead?.isPlaying ?? false))
          Positioned(
            right: Space.md,
            bottom: Space.md,
            child: _SoundButton(
              busy: _audioStarting,
              colors: colors,
              onPressed: _audioStarting ? null : _startAudio,
            ),
          ),
      ],
    );
  }
}

/// A line of text on the canvas ground, for the two seconds before the
/// recording arrives and for the case where it does not.
class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.colors});

  final String text;
  final OaaColors colors;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: colors.textMuted,
        fontFamily: 'Google Sans Code',
        fontSize: 12,
      ),
    ),
  );
}

/// Offers the sound, and goes once it is playing.
///
/// Deliberately small and in a corner: the canvas is the thing being shown, and
/// a control over the middle of it would be a second front door on a page whose
/// first one the reader has already opened.
class _SoundButton extends StatelessWidget {
  const _SoundButton({
    required this.busy,
    required this.colors,
    required this.onPressed,
  });

  final bool busy;
  final OaaColors colors;
  final VoidCallback? onPressed;

  /// Pixels to lift the words, so that their ink sits in the middle of the
  /// button rather than two pixels below it.
  ///
  /// **Measured off a 3× rendering, not derived** — the same rule as
  /// `_HistoryAction._drop` in the application's tab strip, and re-measure it if
  /// the size or the face moves. The words are low because they share a baseline
  /// with a note that is in neither bundled face: what sets the row's depth
  /// below that baseline is some other typeface's descent, so the words sit in a
  /// box they did not size.
  ///
  /// A transform and not padding, which is the version that did nothing: the row
  /// is already deeper than the words' own box, so two more pixels under them
  /// grew neither the row nor the button, and a baseline-aligned child does not
  /// move when the space beneath it does.
  static const double _sink = 2;

  /// The same correction for the note, which is low by half as much: it is a
  /// different face from the words it shares a baseline with, so the two are not
  /// off the middle by the same amount and one value cannot serve both.
  static const double _noteSink = 1;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: colors.accent,
      fontFamily: 'Google Sans Code',
      fontSize: 11,
    );
    return Semantics(
      button: true,
      label: 'Play the audio this was measured from',
      child: GestureDetector(
        onTap: onPressed,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.panelRaised,
            border: Border.all(color: colors.accent),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.sm,
              vertical: Space.xs,
            ),
            // The mark and the words are one object, so the space between them
            // has to be smaller than the space around them, or the note reads
            // as sitting nearer the border than its own label. It was two
            // monospace spaces, which at this size is 13 px — wider than the
            // padding on either side of the pair. `Space.sm` is a value rather
            // than a count of characters.
            child: Row(
              mainAxisSize: MainAxisSize.min,
              // On the words' baseline. `♪` is in neither bundled face, so it
              // comes from whatever the host falls back to and its line box is
              // some other typeface's idea of one; the baseline is the only
              // thing about it that can be placed.
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                // Gone while it starts, with the offer it was making.
                if (!busy) ...[
                  Transform.translate(
                    offset: const Offset(0, -_noteSink),
                    child: Text('♪', style: style),
                  ),
                  const SizedBox(width: Space.sm),
                ],
                Transform.translate(
                  offset: const Offset(0, -_sink),
                  child: Text(
                    busy ? 'starting…' : 'play the audio',
                    style: style,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
