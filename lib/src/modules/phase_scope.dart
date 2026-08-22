// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// A goniometer: left against right, rotated so mono stands upright.
///
/// The rotation is the convention that makes the display readable — a mono
/// signal has L equal to R, which is a 45° diagonal until you turn the whole
/// plot 45°, at which point it becomes a vertical line and "vertical means
/// mono, horizontal means out of phase" is something you can learn in one
/// glance. It stays here rather than in the engine because it is a convention
/// this module has and the CLI does not.
///
/// ---------------------------------------------------------------------------
/// The transform does the work, so the audio is never copied
///
/// The engine publishes 1024 raw (L, R) pairs as a `Float32List` view straight
/// onto its own memory. Rotating and scaling those in Dart would mean writing
/// 2048 floats into a second buffer every frame. Instead the canvas is
/// transformed — translate, scale, rotate — and the buffer is handed to
/// `drawRawPoints` as it arrived. The GPU does arithmetic it was going to do
/// anyway.
///
/// ---------------------------------------------------------------------------
/// The trail is the last [_trailFrames] frames, not a faded picture
///
/// The obvious afterglow keeps last frame's image, draws it back at 86% and
/// adds the new points. That is what this module used to do, and the image it
/// kept came from `toImageSync`, which retains the display list that drew it
/// for as long as the image lives — so every frame's image pinned the frame
/// before it, back to the first one. It leaked one image per published frame
/// and eventually killed the raster thread on the way out; the full account is
/// in the header of `spectrogram.dart`.
///
/// The trail is short, so keeping the frames is cheaper than keeping a picture
/// of them: at a decay of 0.86 a frame is below one part in 255 after forty of
/// them, and forty frames of scope is a 327 KB ring. Each is one
/// `drawRawPoints` call at its own age's alpha — forty calls, recorded in about
/// 0.1 ms. Two things improve as a side effect: the decay is exact rather
/// than compounded through an 8-bit surface, and the trail no longer blurs. The
/// old one resampled the whole picture every frame, so a moving dot smeared
/// instead of fading in place.
/// ---------------------------------------------------------------------------
/// It is fragment-bound, and that is why the fix is sparseness
///
/// This was the most expensive module in the application to rasterise, by a
/// long way, and the number that mattered took two benchmarks to find.
/// `tool/bench_modules.dart` runs under `flutter test`, which has no GPU, and
/// put the rasterise at ~24 ms — a figure worth distrusting, because points are
/// exactly what a GPU is good at. `tool/bench_gpu.dart` exists because of that
/// distrust and reads the engine's own `FrameTiming` in a profile build: on an
/// Apple Silicon Mac the honest answer was **9.6 ms of rasterising per frame**,
/// over half a 60 fps budget for one module, on a feature whose point is a
/// tablet with less GPU than that. The software figure overstated it 2.5x and
/// reordered the table underneath it; the ranking's top entry survived.
///
/// **The cost is fragments, and only fragments.** Drawing all forty frames in a
/// single `drawRawPoints` call measured 5,985 µs against 6,057 µs for forty
/// separate ones, so batching the calls buys nothing and there is no point
/// building a bucketing scheme for them. 40,960 translucent dots over a plot
/// about 300 px across is four and a half dots per pixel, and blending them is
/// the entire bill.
///
/// So the two things that worked both remove fragments rather than rearrange
/// them, and neither touches the exactness the trail is built on:
///
///   - **No antialiasing.** 9,616 → 6,057 µs. A 1.4 px dot in a cloud of tens
///     of thousands gains nothing legible from it. `StrokeCap.square` is
///     *slower* than round, which sounds backwards and is not: Skia has a fast
///     path for round points and none for square ones.
///   - **Sparseness that follows the fade** — see [_detailFor]. 19,200 points
///     instead of 40,960.
///
/// Together, **9.6 ms to 3.3 ms** on the GPU, and 24.3 ms to 9.1 ms on the
/// software rasteriser — two backends, the same 2.6x, which is the sort of
/// agreement worth having before believing either. What was *not* done is worth recording too:
/// accumulating the trail into a pixel buffer, the way `spectrogram.dart` does.
/// That works there because a spectrogram scrolls — one new column and a
/// memmove, O(height) a frame. A trail decays everywhere at once, so the same
/// idea is O(width x height) of Dart on the UI thread every published frame,
/// and it would trade a parallel raster cost for a serial one while
/// reintroducing the 8-bit compounding this design was written to escape.
///
class PhaseScopeModule extends StatefulWidget {
  const PhaseScopeModule({
    required this.engine,
    required this.clock,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;

  /// A permutation whose every power-of-two prefix is evenly spread.
  ///
  /// Bit reversal: position *p* receives sample `bitrev(p)`, so the first
  /// 2^k positions hold samples spaced 2^(10-k) apart across the block. A
  /// goniometer traces the signal's path in time, so a subsample that is even
  /// in time is even along the path — which is what makes a shortened prefix
  /// look like the same figure drawn more sparsely rather than like a piece of
  /// it. Falls back to the identity if the block is not a power of two, which
  /// no engine block is.
  @visibleForTesting
  static Int32List stratifiedOrder(int count) {
    final order = Int32List(count);
    final bits = count.bitLength - 1;
    if (count != 1 << bits) {
      for (var i = 0; i < count; i++) {
        order[i] = i;
      }
      return order;
    }
    for (var i = 0; i < count; i++) {
      var value = i;
      var reversed = 0;
      for (var bit = 0; bit < bits; bit++) {
        reversed = (reversed << 1) | (value & 1);
        value >>= 1;
      }
      order[i] = reversed;
    }
    return order;
  }

  @override
  State<PhaseScopeModule> createState() => _PhaseScopeModuleState();
}

/// How much of the previous frame survives. At ~47 published frames a second
/// this leaves a trail a little under half a second long, which is enough to
/// see the shape of a bass note without smearing a whole bar into a blob.
const double _decay = 0.86;

/// How many frames the trail keeps. `0.86^40` is 0.0024, below the 1/255 a
/// surface can show, so the fortieth frame is the last that could contribute.
const int _trailFrames = 40;

/// How many detail levels a slot is stored at: full, half, quarter, eighth.
const int _detailLevels = 4;

/// Which of those a frame of a given age is drawn at.
///
/// **The dimmer a frame is, the more sparsely it is drawn.** This is the whole
/// of the module's cost control and it is worth saying why it is legitimate.
/// The trail is 40,960 points blended over a plot about 300 px across — four
/// and a half dots per pixel — and it was measured at 9.6 ms of rasterising a
/// frame on an Apple Silicon Mac, over half a 60 fps budget for one module, on
/// a feature whose whole purpose is a tablet with less GPU than that. The cost
/// is fragments and nothing else: drawing all forty frames in a *single*
/// `drawRawPoints` call measured 5,985 µs against 6,057 µs for forty calls, so
/// batching them buys nothing and only the point count is left.
///
/// Ages 30 to 39 are drawn at alphas from 0.011 down to 0.0024 — at most three
/// parts in 255. An eighth of the points at three parts in 255 is not a picture
/// anybody can tell from all of them, and the frames that carry the shape you
/// actually read are untouched: the first ten are drawn whole.
int _detailFor(int age) {
  if (age < 10) return 0;
  if (age < 20) return 1;
  if (age < 30) return 2;
  return 3;
}

class _PhaseScopeModuleState extends State<PhaseScopeModule> {
  /// [_trailFrames] frames of scope points, oldest overwritten. The views onto
  /// its slots are built once, so drawing neither copies nor allocates.
  Float32List _ring = Float32List(0);

  /// Views onto each slot, one per detail level — see [_detail]. Built with the
  /// ring so that a paint picks one rather than allocating one.
  List<List<Float32List>> _frames = const [];

  /// Where a sample goes inside a slot, so that a *prefix* of the slot is a
  /// subsample spread evenly over the block. See [PhaseScopeModule.stratifiedOrder].
  Int32List _order = Int32List(0);
  int _next = 0;
  int _filled = 0;

  ui.Paragraph? _left;
  ui.Paragraph? _right;
  ui.Paragraph? _mono;
  Color? _builtColor;

  /// One [Paint] per age, alpha `_decay^age`.
  List<Paint> _trail = const [];
  Color? _builtTrail;

  /// The last generation written into the ring. The trail advances on new
  /// audio, not on repaints — a resize or a theme change must not age it by a
  /// frame it did not measure.
  ///
  /// Starts at 0 rather than −1 because generation 0 is "nothing measured yet",
  /// and the scope behind a fresh source is zeroed — a full frame of samples
  /// sitting exactly at the origin.
  int lastGeneration = 0;

  /// Stores the newest measurement's points as the newest trail frame.
  ///
  /// **Takes at most [MeterShape.scopePoints] pairs, and the newest ones.** A
  /// snapshot off a wire may carry several blocks of audio in one frame — see
  /// `MeterSource.scopeFrames` — and a goniometer does not want them: it draws
  /// a cloud rather than a waveform, the extra pairs land on pixels the others
  /// already covered, and a variable run would give the ring a variable stride
  /// and break the stratified order below. The oscilloscope is the module that
  /// needs every sample; this one needs a representative scatter of them.
  void write(Float32List scope, int frames) {
    if (scope.isEmpty || frames <= 0) return;

    final take = frames < MeterShape.scopePoints
        ? frames
        : MeterShape.scopePoints;
    final from = (frames - take) * 2;
    final slotLength = MeterShape.scopePoints * 2;

    if (_ring.length != _trailFrames * slotLength) {
      _ring = Float32List(_trailFrames * slotLength);
      _order = PhaseScopeModule.stratifiedOrder(MeterShape.scopePoints);
      _frames = [
        for (var slot = 0; slot < _trailFrames; slot++)
          [
            for (var level = 0; level < _detailLevels; level++)
              Float32List.sublistView(
                _ring,
                slot * slotLength,
                slot * slotLength + (slotLength >> level),
              ),
          ],
      ];
      _next = 0;
      _filled = 0;
    }

    // Scattered rather than copied, so that the first half of a slot is every
    // other sample and the first eighth is every eighth — see [_detail].
    final base = _next * slotLength;
    for (var i = 0; i < MeterShape.scopePoints; i++) {
      final to = base + _order[i] * 2;
      if (i < take) {
        _ring[to] = scope[from + i * 2];
        _ring[to + 1] = scope[from + i * 2 + 1];
      } else {
        // A short run — the link dropped a frame, or nothing has been measured
        // yet. NaN rather than a stale pair: `drawRawPoints` skips it, where a
        // leftover would draw a sample from a different moment.
        _ring[to] = double.nan;
        _ring[to + 1] = double.nan;
      }
    }

    _next = (_next + 1) % _trailFrames;
    if (_filled < _trailFrames) _filled++;
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    if (_builtColor != colors.textFaint) {
      _builtColor = colors.textFaint;
      final style = OaaType.tick.copyWith(color: colors.textFaint);
      _left = layoutParagraph('L', style);
      _right = layoutParagraph('R', style);
      _mono = layoutParagraph('M', style);
    }

    if (_builtTrail != colors.accent) {
      _builtTrail = colors.accent;
      _trail = [
        for (var age = 0; age < _trailFrames; age++)
          Paint()
            ..color = colors.accent.withValues(
              alpha: math.pow(_decay, age).toDouble(),
            )
            ..strokeCap = StrokeCap.round
            // A 1.4 px dot in a cloud of tens of thousands gains nothing
            // legible from being antialiased, and it measured 9,616 µs against
            // 6,057 µs to have it. `StrokeCap.square` is *slower* than round
            // here, which is the opposite of what it sounds like — Skia has a
            // fast path for round points and none for square ones.
            ..isAntiAlias = false,
      ];
    }

    return MeterBody(
      painter: _PhaseScopePainter(
        engine: widget.engine,
        colors: colors,
        state: this,
        repaint: widget.clock,
      ),
    );
  }
}

class _PhaseScopePainter extends MeterPainter {
  _PhaseScopePainter({
    required this.engine,
    required this.colors,
    required this.state,
    required Listenable repaint,
  }) : _guide = (Paint()
         ..color = colors.hairline
         ..style = PaintingStyle.stroke
         ..strokeWidth = OaaStroke.hairline),
       _correlation = (Paint()..color = colors.meterFill),
       _correlationTrack = (Paint()..color = colors.meterTrack),
       super(repaint: repaint);

  final MeterSource engine;
  final OaaColors colors;
  final _PhaseScopeModuleState state;

  final Paint _guide;
  final Paint _correlation;
  final Paint _correlationTrack;

  /// Radius of a plotted sample, in logical pixels.
  static const double _pointSize = 1.4;

  static const double _correlationHeight = 10;

  @override
  void paint(Canvas canvas, Size size) {
    final plotHeight = size.height - _correlationHeight - Space.xs;
    if (plotHeight < 40) return;
    final plot = Size(size.width, plotHeight);

    final centre = Offset(plot.width / 2, plot.height / 2);
    // sqrt(2) of headroom, because a mono full-scale signal reaches (1,1),
    // whose rotated length is sqrt(2). Without it a loud mono passage would
    // clip against the top of the display and read as a limiter.
    final radius =
        math.min(plot.width, plot.height) / 2 / math.sqrt2 - Space.xs;
    if (radius <= 0) return;

    if (engine.generation != 0 && engine.generation != state.lastGeneration) {
      state.lastGeneration = engine.generation;
      state.write(engine.scope, engine.scopeFrames);
    }

    // --- The trail, oldest first so the newest frame is on top --------------
    if (state._trail.length == _trailFrames) {
      canvas.save();
      canvas.translate(centre.dx, centre.dy);
      // Screen y grows downwards; the scale flips it so a positive sample goes
      // up. The rotation then turns the L=R diagonal upright.
      canvas.scale(radius, -radius);
      canvas.rotate(math.pi / 4);

      for (var age = state._filled - 1; age >= 0; age--) {
        final slot = (state._next - 1 - age + _trailFrames * 2) % _trailFrames;
        canvas.drawRawPoints(
          ui.PointMode.points,
          state._frames[slot][_detailFor(age)],
          // strokeWidth is in the transformed space, so it has to be divided
          // back out or a dot would be `radius` pixels across.
          state._trail[age]..strokeWidth = _pointSize / radius,
        );
      }
      canvas.restore();
    }

    // --- Guides, drawn fresh each frame so the trail cannot burn them in ----
    canvas.drawCircle(centre, radius * math.sqrt2, _guide);
    canvas.drawLine(
      Offset(centre.dx, centre.dy - radius * math.sqrt2),
      Offset(centre.dx, centre.dy + radius * math.sqrt2),
      _guide,
    );
    canvas.drawLine(
      Offset(centre.dx - radius * math.sqrt2, centre.dy),
      Offset(centre.dx + radius * math.sqrt2, centre.dy),
      _guide,
    );

    final reach = radius * math.sqrt2;
    _label(
      canvas,
      state._mono!,
      Offset(centre.dx, centre.dy - reach + Space.sm),
    );
    _label(
      canvas,
      state._left!,
      Offset(centre.dx - reach * 0.72, centre.dy - reach * 0.72 + Space.sm),
    );
    _label(
      canvas,
      state._right!,
      Offset(centre.dx + reach * 0.72, centre.dy - reach * 0.72 + Space.sm),
    );

    // --- Correlation --------------------------------------------------------
    // The same fact as the shape above, as a number you can read off. −1 is a
    // signal that will disappear in mono, which is the failure a phase scope
    // exists to catch and the one thing about it worth quantifying.
    final track = Rect.fromLTWH(
      0,
      size.height - _correlationHeight,
      size.width,
      _correlationHeight,
    );
    // Rounded at the two ends only: the bar is the one thing here that is not
    // part of the graticule, so it reads as a control rather than a scale.
    final rounded = RRect.fromRectAndRadius(track, OaaRadius.xs);
    canvas.drawRRect(rounded, _correlationTrack);

    final correlation = engine.correlation;
    if (!correlation.isNaN) {
      final centreX = track.center.dx;
      final extent = correlation.clamp(-1.0, 1.0) * track.width / 2;
      _correlation.color = correlation < 0 ? colors.warn : colors.meterFill;
      // At ±1 the fill reaches the end of the track, so it is clipped to the
      // same corners rather than drawn square over them.
      canvas.save();
      canvas.clipRRect(rounded);
      canvas.drawRect(
        Rect.fromLTRB(
          extent < 0 ? centreX + extent : centreX,
          track.top,
          extent < 0 ? centreX : centreX + extent,
          track.bottom,
        ),
        _correlation,
      );
      canvas.restore();
    }
    canvas.drawLine(
      Offset(track.center.dx, track.top),
      Offset(track.center.dx, track.bottom),
      _guide,
    );
  }

  void _label(Canvas canvas, ui.Paragraph label, Offset at) =>
      canvas.drawParagraph(
        label,
        at - Offset(label.longestLine / 2, label.height / 2),
      );

  @override
  bool shouldRepaint(_PhaseScopePainter oldDelegate) =>
      oldDelegate.colors != colors || !identical(oldDelegate.engine, engine);
}
