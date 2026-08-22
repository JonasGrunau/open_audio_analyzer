// SPDX-License-Identifier: GPL-3.0-or-later
//
// The oscilloscope's arithmetic, held to the pictures that would otherwise be
// plausible and wrong.
//
// Every property below fails silently. A trigger that does not lock draws a
// waveform of exactly the right shape at a different phase each frame, which
// reads as a jittery meter rather than as a broken one; a gap filled in with
// whatever was left in the scope buffer draws a stretch of audio nobody
// measured, at the right amplitude, in the right place. Neither is visible in
// a widget assertion and neither throws, so these are pixel reads.
//
// The module keeps no engine and no native library — it is written against
// `MeterSource` like every other one — so the source here is driven by hand and
// a thousand published measurements take no real time.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa/src/clock/meter_clock.dart';
import 'package:oaa/src/modules/oscilloscope.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _colors = OaaColors.precisionInstrument;
const _rate = 48000;
const _block = MeterShape.scopePoints;
const _size = Size(400, 120);

/// A source the test drives a block at a time, the way the engine does.
///
/// It publishes exactly one analysis block per call, because that is the one
/// thing the module's arithmetic depends on: `elapsedSeconds` and the scope
/// buffer have to describe the same audio, and [skip] is how the test breaks
/// that on purpose.
class _Tone implements MeterSource {
  _Tone({required this.hz, this.amplitude = 0.8, this.channels = 1});

  /// No DAW. Every case below the tempo-sync group is about audio arriving
  /// without a playhead behind it, which is what a sound card is.
  @override
  Transport transport = Transport.none;

  final double hz;
  final double amplitude;

  @override
  final int channels;

  int _generation = 0;
  int _frames = 0;
  final Float32List _scope = Float32List(_block * 2);

  void publish() {
    _generation++;
    for (var i = 0; i < _block; i++) {
      final value = _sample(_frames + i);
      _scope[i * 2] = value;
      _scope[i * 2 + 1] = channels >= 2 ? -value : value;
    }
    _frames += _block;
  }

  /// Measures [blocks] blocks of audio and publishes only the last of them.
  ///
  /// What a file pushed through faster than real time does, and what an
  /// overrun looks like from the module's side: the elapsed clock advances by
  /// everything, the scope buffer carries the newest 1024 frames of it, and
  /// nothing anywhere says which is which except the difference between them.
  void skip(int blocks) {
    _frames += _block * (blocks - 1);
    publish();
  }

  double _sample(int frame) =>
      math.sin(2 * math.pi * hz * frame / _rate) * amplitude;

  @override
  int get generation => _generation;
  @override
  bool refresh() => true;
  @override
  bool get hasOverrun => false;
  @override
  bool get isRunning => true;
  @override
  int get sampleRate => _rate;
  @override
  double get elapsedSeconds => _frames / _rate;
  @override
  Float32List get scope => _scope;

  @override
  int get scopeFrames => _scope.length ~/ 2;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Harness extends StatefulWidget {
  const _Harness({
    required this.source,
    required this.boundary,
    required this.timeBase,
    this.fps = 60,
    this.sync = ScopeSync.free,
    this.division = ScopeDivision.bar1,
  });

  final MeterSource source;
  final GlobalKey boundary;
  final ScopeTimeBase timeBase;
  final ScopeSync sync;
  final ScopeDivision division;

  /// What the user set the meters to redraw at. The engine publishes at about
  /// 47 Hz regardless, so 30 is the setting where the two disagree.
  final int fps;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness>
    with SingleTickerProviderStateMixin {
  late final MeterClock clock = MeterClock(engine: widget.source, vsync: this)
    ..targetFps = widget.fps;

  @override
  void dispose() {
    clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: OaaTheme(
      colors: _colors,
      child: Material(
        color: _colors.background,
        child: Center(
          child: RepaintBoundary(
            key: widget.boundary,
            // No `ModuleFrame`, so the boundary is the plot and a pixel
            // coordinate here is a coordinate in the painter.
            child: SizedBox(
              width: _size.width,
              height: _size.height,
              child: OscilloscopeModule(
                engine: widget.source,
                clock: clock,
                timeBase: widget.timeBase,
                sync: widget.sync,
                division: widget.division,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

const int _width = 400;
const int _height = 120;

Future<void> _frame(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 17));

Future<Uint8List> _shoot(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  late Uint8List pixels;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    pixels = data!.buffer.asUint8List(0, data.lengthInBytes);
    image.dispose();
  });
  return pixels;
}

/// Whether the pixel is the signal.
///
/// Accent is `0xFF35E0C4`, far more green than red; over is `0xFFFF4D4D`, far
/// more red than green; and everything else the module draws — the graticule,
/// the centre lines, the labels — is grey, where the two are within a few
/// counts of each other. A margin of 40 separates all three, antialiased edges
/// included.
bool _isSignal(Uint8List pixels, int x, int y) {
  final i = (y * _width + x) * 4;
  return pixels[i + 1] - pixels[i] > 40;
}

bool _isOver(Uint8List pixels, int x, int y) {
  final i = (y * _width + x) * 4;
  return pixels[i] - pixels[i + 1] > 40;
}

/// The columns carrying signal ink, anywhere down their height.
List<int> _inked(Uint8List pixels) => [
  for (var x = 0; x < _width; x++)
    if (List.generate(_height, (y) => y).any((y) => _isSignal(pixels, x, y))) x,
];

/// The topmost row of signal ink in column [x], or null.
int? _top(Uint8List pixels, int x) {
  for (var y = 0; y < _height; y++) {
    if (_isSignal(pixels, x, y)) return y;
  }
  return null;
}

void main() {
  testWidgets('the trigger locks the waveform to the signal, not the block', (
    tester,
  ) async {
    // 1 kHz at 48 kHz is a period of exactly 48 samples, and a block is 1024 —
    // 21 periods and 16 samples. So every published block starts at a
    // different phase, and a display that drew the newest 20 ms would show the
    // waveform sliding sideways by a third of a cycle every frame. A triggered
    // one draws the same picture every time, which is the entire reason a
    // scope has a trigger.
    final key = GlobalKey();
    final source = _Tone(hz: 1000);
    await tester.pumpWidget(
      _Harness(source: source, boundary: key, timeBase: ScopeTimeBase.ms20),
    );

    // Enough to fill the kept window, so the trigger has somewhere to search.
    for (var i = 0; i < 40; i++) {
      source.publish();
      await _frame(tester);
    }

    final locked = await _shoot(tester, key);
    expect(
      _inked(locked),
      hasLength(greaterThan(_width ~/ 2)),
      reason:
          'nothing was drawn, so the frames below would match each other for '
          'the wrong reason',
    );

    for (var i = 0; i < 10; i++) {
      source.publish();
      await _frame(tester);
      expect(
        await _shoot(tester, key),
        locked,
        reason:
            'the waveform moved between published frames, which is what an '
            'untriggered display does with a block boundary that drifts',
      );
    }

    // And it locked to a *rising zero crossing*, not merely to something
    // repeatable: the leftmost sample drawn is the first one past the trigger
    // level, which on this tone is a tenth of full scale above the centre.
    // A free-running window would start wherever the block happened to, which
    // for this tone is 16 samples further round the cycle each time.
    final centre = _height / 2;
    final half = centre - OaaStroke.hairline;
    expect(
      _top(locked, 0),
      isNotNull,
      reason: 'the leftmost column drew nothing',
    );
    expect(
      (_top(locked, 0)! - centre).abs(),
      lessThan(half * 0.25),
      reason: 'the window does not start near a zero crossing',
    );
  });

  testWidgets('audio that was measured and never published is left blank', (
    tester,
  ) async {
    // The rolling display advances by however many frames `elapsedSeconds`
    // says were measured, not by one screenful of scope buffer per publish.
    // When those disagree — a file pushed through faster than real time — the
    // frames in between were never carried and the module has nothing to draw
    // for them. Drawing the buffer across the whole gap would put a stretch of
    // audio nobody measured on screen at the right amplitude and in the right
    // place, which is indistinguishable from a correct picture.
    final key = GlobalKey();
    final source = _Tone(hz: 1000);
    await tester.pumpWidget(
      _Harness(source: source, boundary: key, timeBase: ScopeTimeBase.s1),
    );

    // Twice, because the first publish is what establishes the elapsed
    // baseline the difference below is taken against — a module cannot know
    // how much audio a measurement carried until it has seen two of them.
    source.publish();
    await _frame(tester);
    source.publish();
    await _frame(tester);

    // Twenty blocks of audio measured, one of them published.
    source.skip(20);
    await _frame(tester);

    // One second across 400 columns is 120 frames a column, so a block is
    // rather more than eight of them and the nineteen that were skipped are a
    // hundred and sixty. What must be on screen is two short runs of ink that
    // far apart, with nothing in between.
    //
    // **The count of inked columns cannot see this and neither can the
    // amplitude.** A module that ignored the difference would still draw only
    // the two blocks it was given — it would draw them *adjacent*, having
    // advanced the display by one block instead of twenty, which compresses
    // four hundred milliseconds of programme into eighteen milliseconds of
    // display and is a perfectly ordinary-looking waveform.
    final columns = _inked(await _shoot(tester, key));
    expect(
      columns,
      isNotEmpty,
      reason: 'the published blocks were not drawn either',
    );
    expect(
      columns,
      hasLength(lessThan(40)),
      reason:
          'the gap was filled in with audio that was never carried to this '
          'module',
    );
    expect(
      columns.last - columns.first,
      greaterThan(140),
      reason:
          'the display advanced by what it was shown rather than by what was '
          'measured, so the skipped audio takes up no time on screen',
    );

    final blank = [
      for (var i = 1; i < columns.length; i++) columns[i] - columns[i - 1],
    ];
    expect(
      blank,
      contains(greaterThan(100)),
      reason: 'there is no gap on screen where the missing audio should be',
    );
  });

  testWidgets('the rolling display fills from the right edge', (tester) async {
    final key = GlobalKey();
    final source = _Tone(hz: 1000);
    await tester.pumpWidget(
      _Harness(source: source, boundary: key, timeBase: ScopeTimeBase.s1),
    );

    for (var i = 0; i < 8; i++) {
      source.publish();
      await _frame(tester);
    }

    // Eight blocks is 171 ms of a one-second display: a fifth of the width,
    // and it has to be the right-hand fifth. New audio entering at the left
    // would run the display backwards, which looks entirely normal until you
    // try to read a transient off it against anything else on the canvas.
    final columns = _inked(await _shoot(tester, key));
    expect(columns, isNotEmpty);
    expect(
      columns.first,
      greaterThan(_width ~/ 2),
      reason: 'the newest audio is not at the right edge',
    );
    expect(columns.last, greaterThan(_width - 4));
  });

  testWidgets('a repaint rate below the publish rate loses no audio', (
    tester,
  ) async {
    // The engine publishes at about 47 Hz and `oaa_snapshot_acquire` keeps one
    // slot, so a measurement nobody reads before the next one is gone. At the
    // 30 fps setting a reader that only looks when it paints asks every 33 ms
    // against a publish every 21 ms — it loses one publish in three, and on a
    // display whose axis is time each loss is a hole rather than a coarser
    // picture. This module reads from `MeterClock.measurements`, which is not
    // throttled, and this is the test that says so.
    //
    // The pumps below are the ticker running at 60 while the meters are set to
    // 30, which is exactly the arrangement that breaks a display folding its
    // history in from `paint`.
    final key = GlobalKey();
    final source = _Tone(hz: 1000);
    await tester.pumpWidget(
      _Harness(
        source: source,
        boundary: key,
        timeBase: ScopeTimeBase.s1,
        fps: 30,
      ),
    );

    for (var i = 0; i < 60; i++) {
      source.publish();
      await _frame(tester);
    }

    // Sixty blocks at 1024 frames is 1.28 s, so the whole width is covered.
    // Every column of it has to carry ink: a gap anywhere is a measurement
    // that was published and never read.
    final columns = _inked(await _shoot(tester, key));
    expect(
      columns,
      hasLength(_width),
      reason:
          'the display has holes in it, so measurements were lost between the '
          'publish rate and the repaint rate',
    );
  });

  testWidgets('a triggered window fills below the publish rate too', (
    tester,
  ) async {
    // The worse half of the test above, and the reason it is worth two. A
    // triggered window is cut out of the run of samples the module kept, so a
    // run that is never contiguous for as long as one span produces no window
    // at all: the display does not get coarser, it stays empty.
    final key = GlobalKey();
    final source = _Tone(hz: 1000);
    await tester.pumpWidget(
      _Harness(
        source: source,
        boundary: key,
        timeBase: ScopeTimeBase.ms100,
        fps: 30,
      ),
    );

    // 100 ms is 4800 frames, so five blocks would do. Sixty is a comfortable
    // margin over the kept window filling.
    for (var i = 0; i < 60; i++) {
      source.publish();
      await _frame(tester);
    }

    expect(
      _inked(await _shoot(tester, key)),
      hasLength(greaterThan(_width ~/ 2)),
      reason:
          'the kept samples were never contiguous for as long as one span, so '
          'no window could be cut from them',
    );
  });

  testWidgets('a stereo source draws two lanes and a mono source draws one', (
    tester,
  ) async {
    // The lanes are how the channels are told apart, so the count of them is
    // the whole convention. A mono source drawn as two lanes shows a stereo
    // image nobody has — `oaa_scope_append` copies the left channel into both
    // when there is one channel, so the second lane would be a perfect
    // duplicate of the first and look like a correlated stereo signal.
    //
    // Read at the exact vertical middle. Two lanes put the gap between them
    // there and nothing is drawn in it; one lane puts its centre line there
    // and a tone crossing zero draws through it in every column.
    const middle = _height ~/ 2;

    Future<int> inkAtTheMiddle(int channels) async {
      final key = GlobalKey();
      final source = _Tone(hz: 1000, channels: channels);
      await tester.pumpWidget(
        _Harness(source: source, boundary: key, timeBase: ScopeTimeBase.s1),
      );
      for (var i = 0; i < 8; i++) {
        source.publish();
        await _frame(tester);
      }
      final pixels = await _shoot(tester, key);
      var hits = 0;
      for (var x = 0; x < _width; x++) {
        if (_isSignal(pixels, x, middle)) hits++;
      }
      return hits;
    }

    expect(
      await inkAtTheMiddle(1),
      greaterThan(0),
      reason: 'a mono source did not draw one lane down the middle',
    );
    expect(
      await inkAtTheMiddle(2),
      0,
      reason: 'a stereo source drew through the gap between its two lanes',
    );
  });

  testWidgets('a signal that reached full scale is drawn as over', (
    tester,
  ) async {
    final key = GlobalKey();
    final hot = _Tone(hz: 1000, amplitude: 1.0);
    await tester.pumpWidget(
      _Harness(source: hot, boundary: key, timeBase: ScopeTimeBase.s1),
    );
    for (var i = 0; i < 8; i++) {
      hot.publish();
      await _frame(tester);
    }

    final pixels = await _shoot(tester, key);
    var over = 0;
    for (var x = 0; x < _width; x++) {
      for (var y = 0; y < _height; y++) {
        if (_isOver(pixels, x, y)) over++;
      }
    }
    expect(
      over,
      greaterThan(0),
      reason: 'a full-scale signal was drawn as if it had headroom',
    );
  });

  testWidgets('a signal with headroom is not drawn as over', (tester) async {
    // The other half of the test above, and the one that matters more: a
    // meter that cries over on material that never clipped is a meter people
    // stop believing, and then it cannot warn them about anything.
    final key = GlobalKey();
    final quiet = _Tone(hz: 1000, amplitude: 0.5);
    await tester.pumpWidget(
      _Harness(source: quiet, boundary: key, timeBase: ScopeTimeBase.s1),
    );
    for (var i = 0; i < 8; i++) {
      quiet.publish();
      await _frame(tester);
    }

    final pixels = await _shoot(tester, key);
    for (var x = 0; x < _width; x++) {
      for (var y = 0; y < _height; y++) {
        expect(
          _isOver(pixels, x, y),
          isFalse,
          reason: 'a −6 dBFS signal was marked as over at $x, $y',
        );
      }
    }
  });

  group('tempo sync', () {
    // A bar-locked display is the one picture in this module that cannot be
    // checked by looking at one frame: what it promises is that the *same*
    // audio lands in the *same* column pass after pass. So the impulse below
    // is placed at a fixed point in the bar and the column it draws in is
    // compared across two bars, which is the assertion a scrolling display
    // fails and a phase-locked one passes.

    testWidgets('the bar lands in the same column every pass', (tester) async {
      final key = GlobalKey();
      final source = _Bar();
      await tester.pumpWidget(
        _Harness(
          source: source,
          boundary: key,
          timeBase: ScopeTimeBase.s1,
          sync: ScopeSync.tempo,
        ),
      );

      // Two bars to fill the window, then a reading at the end of each of the
      // next two.
      await _playBars(tester, source, 2);
      await _playBars(tester, source, 1);
      final first = _tallestColumn(await _shoot(tester, key));
      await _playBars(tester, source, 1);
      final second = _tallestColumn(await _shoot(tester, key));

      expect(
        first,
        isNotNull,
        reason: 'nothing was drawn, so there is no column to compare',
      );
      expect(
        (second! - first!).abs(),
        lessThanOrEqualTo(2),
        reason:
            'the impulse moved between bars — the window is not locked to the '
            'playhead',
      );

      // And it is where the impulse is: a quarter of the way into the bar.
      expect((first - _width ~/ 4).abs(), lessThanOrEqualTo(6));
    });

    testWidgets('the division is the width of the window', (tester) async {
      // An impulse halfway through every beat. A one-beat window puts it in
      // the middle; a one-bar window would put it an eighth of the way in.
      // Same audio, same playhead, different grid — which is the only thing
      // the setting does.
      final key = GlobalKey();
      final source = _Bar(perBeat: true);
      await tester.pumpWidget(
        _Harness(
          source: source,
          boundary: key,
          timeBase: ScopeTimeBase.s1,
          sync: ScopeSync.tempo,
          division: ScopeDivision.quarter,
        ),
      );
      await _playBars(tester, source, 3);

      // Halfway into every beat, so halfway across a one-beat window — and an
      // eighth of the way across a one-bar one, which is where it would be if
      // the division were ignored.
      final at = _tallestColumn(await _shoot(tester, key));
      expect(at, isNotNull);
      expect(
        (at! - _width ~/ 2).abs(),
        lessThanOrEqualTo(6),
        reason: 'the window is not one beat wide',
      );
    });

    testWidgets('a parked playhead freezes rather than piling up', (
      tester,
    ) async {
      final key = GlobalKey();
      final source = _Bar();
      await tester.pumpWidget(
        _Harness(
          source: source,
          boundary: key,
          timeBase: ScopeTimeBase.s1,
          sync: ScopeSync.tempo,
        ),
      );
      await _playBars(tester, source, 3);
      final rolling = _tallestColumn(await _shoot(tester, key));

      // Stop. The plugin keeps publishing — a DAW calls `processBlock` with a
      // parked transport — and every block reports the same position, so every
      // sample would land in one column and bury the picture under a stripe of
      // room tone.
      source.playing = false;
      for (var i = 0; i < 60; i++) {
        source.publish();
        await _frame(tester);
      }

      expect(
        _tallestColumn(await _shoot(tester, key)),
        rolling,
        reason: 'a stopped transport redrew the display',
      );
    });

    testWidgets('a source with no playhead draws the free window', (
      tester,
    ) async {
      // Tempo sync on a sound card. There is nothing to lock to, and a blank
      // module would be a worse answer than the display that does work.
      final key = GlobalKey();
      final source = _Tone(hz: 1000);
      await tester.pumpWidget(
        _Harness(
          source: source,
          boundary: key,
          timeBase: ScopeTimeBase.ms20,
          sync: ScopeSync.tempo,
        ),
      );
      for (var i = 0; i < 20; i++) {
        source.publish();
        await _frame(tester);
      }

      expect(
        _inked(await _shoot(tester, key)).length,
        greaterThan(_width ~/ 2),
        reason: 'the display went blank instead of falling back',
      );
    });
  });
}

/// Plays [bars] bars of a source that carries a playhead.
Future<void> _playBars(WidgetTester tester, _Bar source, int bars) async {
  final blocks = (source.framesPerBar * bars / _block).ceil();
  for (var i = 0; i < blocks; i++) {
    source.publish();
    await _frame(tester);
  }
}

/// The column whose signal ink is tallest, or null if nothing is drawn.
///
/// A written column always has ink — a silent one is drawn as a single pixel
/// so that a flat signal is a flat line rather than nothing — so "which column
/// has ink" cannot find a transient. Its *height* can.
int? _tallestColumn(Uint8List pixels) {
  var best = -1;
  var bestHeight = 1;
  for (var x = 0; x < _width; x++) {
    var height = 0;
    for (var y = 0; y < _height; y++) {
      if (_isSignal(pixels, x, y)) height++;
    }
    if (height > bestHeight) {
      bestHeight = height;
      best = x;
    }
  }
  return best < 0 ? null : best;
}

/// A source with a DAW behind it: 120 bpm, 4/4, one impulse a quarter of the
/// way into every bar.
///
/// The playhead advances with the audio, the way a host's does — which is the
/// property tempo sync is built on and the one a fake that advanced it on a
/// wall clock would quietly break.
class _Bar implements MeterSource {
  _Bar({this.perBeat = false});

  /// Whether the impulse repeats every beat rather than every bar.
  ///
  /// A window narrower than the pattern in it is overwritten by the passes
  /// that carry nothing, which is correct and makes a bar-long pattern useless
  /// for testing a beat-long window.
  final bool perBeat;

  static const double bpm = 120;
  static const double quartersPerBar = 4;

  int _generation = 0;
  int _frames = 0;
  bool playing = true;
  final Float32List _scope = Float32List(_block * 2);

  Transport _transport = Transport.none;

  int get framesPerBar => (quartersPerBar * 60 / bpm * _rate).round();

  void publish() {
    _generation++;
    // The playhead this block starts at, before the audio in it is measured.
    _transport = Transport(
      flags:
          (playing ? Transport.flagPlaying : 0) |
          Transport.flagHasPpq |
          Transport.flagHasBarStart |
          Transport.flagHasBpm |
          Transport.flagHasTimeSig,
      ppqPosition: _frames / _rate * bpm / 60,
      bpm: bpm,
      timeSigNumerator: 4,
      timeSigDenominator: 4,
    );

    final period = perBeat ? framesPerBar ~/ 4 : framesPerBar;
    final impulseAt = perBeat ? period ~/ 2 : period ~/ 4;
    for (var i = 0; i < _block; i++) {
      final into = (_frames + i) % period;
      final hit = into >= impulseAt && into < impulseAt + 64;
      final value = hit ? 0.9 : 0.0;
      _scope[i * 2] = value;
      _scope[i * 2 + 1] = value;
    }
    if (playing) _frames += _block;
  }

  @override
  Transport get transport => _transport;
  @override
  int get generation => _generation;
  @override
  bool refresh() => true;
  @override
  bool get hasOverrun => false;
  @override
  bool get isRunning => true;
  @override
  int get sampleRate => _rate;
  @override
  int get channels => 1;
  @override
  double get elapsedSeconds => _frames / _rate;
  @override
  Float32List get scope => _scope;

  @override
  int get scopeFrames => _scope.length ~/ 2;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
