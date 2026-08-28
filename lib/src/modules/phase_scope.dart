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
/// The frame around the plot is a square with its two diagonals drawn: after
/// the rotation those diagonals *are* the L and R axes, so a signal in one
/// channel only lies along a diagonal, and the square's edges are where the
/// gamut's extremes point. The balance and correlation readings ride the
/// frame's own edges as markers — balance along the bottom, correlation up the
/// right — because both are one-dimensional summaries of the same picture, and
/// an axis a marker slides on says more than a bar in a corner.
///
/// ---------------------------------------------------------------------------
/// The transform does the work, so the audio is never copied per frame
///
/// The engine publishes 1024 raw (L, R) pairs as a `Float32List` view straight
/// onto its own memory. Rotating and scaling those in Dart would mean writing
/// 2048 floats into a second buffer every frame. Instead the canvas is
/// transformed — translate, scale, rotate — and the trail's buffers are handed
/// to `drawRawPoints` as they were written. The GPU does arithmetic it was
/// going to do anyway.
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
/// them. Each is one `drawRawPoints` call at its own age's alpha — forty
/// calls, recorded in about 0.1 ms. Two things improve as a side effect: the
/// decay is exact rather than compounded through an 8-bit surface, and the
/// trail no longer blurs. The old one resampled the whole picture every frame,
/// so a moving line smeared instead of fading in place.
///
/// ---------------------------------------------------------------------------
/// The trace is a polyline, so a slot holds its block in time order
///
/// Each frame is drawn with `PointMode.polygon` — consecutive samples joined —
/// because the connected path is what carries the waveform's structure: a bass
/// note is a loop, a delay is a braid, and a cloud of disconnected dots shows
/// neither. Joining consecutive *buffer* entries only draws the signal's path
/// if the buffer is in time order, so each slot stores its block that way, at
/// four detail levels side by side — full, then every 2nd, 4th and 8th sample,
/// each level contiguous so a draw is one buffer and no copy. See
/// [PhaseScopeModule.writeSlot]; the levels exist for the sparseness below,
/// and an even-in-time subsample traces the same figure with longer segments
/// rather than a piece of it. A short block ends in NaN pairs, and a segment
/// with a NaN endpoint is culled rather than drawn — which is also what ages a
/// mono source's trail out instead of freezing its last stereo frame.
///
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
/// single call measured the same as forty separate ones, so batching buys
/// nothing and only the fragment count is left. Those numbers were measured on
/// the dot cloud this module drew first; a polyline covers more fragments per
/// sample than a 1.4 px dot, which makes the two mitigations below more
/// load-bearing, not less:
///
///   - **No antialiasing.** On dots it measured 9,616 → 6,057 µs; a hairline
///     in a fading braid gains nothing legible from it either.
///   - **Sparseness that follows the fade** — see [_detailFor]. The dimmest
///     frames are drawn from an eighth of their samples.
///
/// On dots the pair took 9.6 ms to 3.3 ms on the GPU and 24.3 ms to 9.1 ms on
/// the software rasteriser — two backends, the same 2.6x. What was *not* done
/// is worth recording too: accumulating the trail into a pixel buffer, the way
/// `spectrogram.dart` does. That works there because a spectrogram scrolls —
/// one new column and a memmove, O(height) a frame. A trail decays everywhere
/// at once, so the same idea is O(width x height) of Dart on the UI thread
/// every published frame, and it would trade a parallel raster cost for a
/// serial one while reintroducing the 8-bit compounding this design was
/// written to escape.
class PhaseScopeModule extends StatefulWidget {
  const PhaseScopeModule({
    required this.engine,
    required this.clock,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;

  /// Floats in one trail slot: the block at full detail, then at every 2nd,
  /// 4th and 8th sample, each level contiguous. 2 · P · (1 + ½ + ¼ + ⅛).
  @visibleForTesting
  static const int slotFloats = MeterShape.scopePoints * 2 * 15 ~/ 8;

  /// Where detail [level]'s pairs start inside a slot, in floats.
  @visibleForTesting
  static int levelOffset(int level) {
    var offset = 0;
    for (var l = 0; l < level; l++) {
      offset += (MeterShape.scopePoints >> l) * 2;
    }
    return offset;
  }

  /// Writes the newest [frames] pairs of [scope] into [slot], in time order,
  /// once per detail level — full, then strided by 2, 4 and 8.
  ///
  /// Time order is what lets `PointMode.polygon` join consecutive entries into
  /// the signal's path, and the stride is what keeps a sparser level *the same
  /// figure* drawn with longer segments: an even subsample in time is an even
  /// subsample along the path. Keeping the first eighth of the samples instead
  /// would draw one eighth *of the path*, and a fading trail would visibly
  /// shrink towards wherever the block happened to start.
  ///
  /// Takes at most [MeterShape.scopePoints] pairs, and the newest ones: a
  /// snapshot off a wire may carry several blocks in one frame — see
  /// `MeterSource.scopeFrames` — and this display draws a figure, not a
  /// waveform; the oscilloscope is the module that needs every sample. What a
  /// short block leaves unfilled is NaN rather than stale audio: a segment
  /// with a NaN endpoint is culled, where a leftover would draw samples from a
  /// different moment joined to this one. A null [scope] blanks the slot
  /// entirely, which is how a mono source's trail ages out — see
  /// [_PhaseScopeModuleState.blank].
  @visibleForTesting
  static void writeSlot(Float32List slot, Float32List? scope, int frames) {
    final take = frames < MeterShape.scopePoints
        ? frames
        : MeterShape.scopePoints;
    final from = (frames - take) * 2;

    var out = 0;
    for (var level = 0; level < _detailLevels; level++) {
      final stride = 1 << level;
      final count = MeterShape.scopePoints >> level;
      for (var i = 0; i < count; i++) {
        final sample = i * stride;
        if (scope != null && sample < take) {
          slot[out] = scope[from + sample * 2];
          slot[out + 1] = scope[from + sample * 2 + 1];
        } else {
          slot[out] = double.nan;
          slot[out + 1] = double.nan;
        }
        out += 2;
      }
    }
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
/// The cost is fragments and nothing else — see the header — and ages 30 to 39
/// are drawn at alphas from 0.011 down to 0.0024, at most three parts in 255.
/// An eighth of the samples at three parts in 255, joined into a polyline of
/// segments eight times as long, is not a picture anybody can tell from all of
/// them; the frames that carry the shape you actually read are untouched: the
/// first ten are drawn whole. Even the sparsest level still spans the whole
/// block — 128 joined samples — so an old frame is a coarser figure, never a
/// shorter one.
int _detailFor(int age) {
  if (age < 10) return 0;
  if (age < 20) return 1;
  if (age < 30) return 2;
  return 3;
}

class _PhaseScopeModuleState extends State<PhaseScopeModule> {
  /// [_trailFrames] slots of scope samples, oldest overwritten. The views onto
  /// each slot's detail levels are built once, so drawing neither copies nor
  /// allocates.
  Float32List _ring = Float32List(0);

  /// Views onto each slot, one per detail level. Built with the ring so that a
  /// paint picks one rather than allocating one.
  List<List<Float32List>> _frames = const [];

  /// A whole-slot view per slot, for writing — built with the ring for the
  /// same reason: a publish must not allocate either.
  List<Float32List> _slots = const [];
  int _next = 0;
  int _filled = 0;

  ui.Paragraph? _balanceLabel;
  ui.Paragraph? _correlationLabel;

  /// The three axis letters: `L` and `R` at the far ends of the two
  /// diagonals, which after the 45° rotation are the two channels' axes, and
  /// `M` at the top, where a mono signal stands. Engraved on the frame, so a
  /// reader who has not learnt the rotation still knows which way is left.
  ui.Paragraph? _left;
  ui.Paragraph? _right;
  ui.Paragraph? _mono;

  /// Why the face is empty on a one-channel source. See the painter.
  ui.Paragraph? _monoNotice;
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

  /// Stores the newest measurement's samples as the newest trail frame.
  void write(Float32List scope, int frames) {
    if (scope.isEmpty || frames <= 0) return;
    _writeInto(scope, frames);
  }

  /// Advances the ring with a frame of nothing in it.
  ///
  /// What a mono source gets, and it is not the same as not writing at all: the
  /// trail is a ring of frames with a fixed alpha per age, so a scope that
  /// simply stopped being written would hold the last stereo frame at full
  /// brightness for the rest of the session — a Lissajous figure of audio that
  /// stopped playing. Ageing it out with empty frames is what makes changing to
  /// a mono input *dissolve* the figure over the trail's own length, which is
  /// what the stereo cloud's fade does for the same reason.
  void blank() => _writeInto(null, 0);

  void _writeInto(Float32List? scope, int frames) {
    if (_ring.length != _trailFrames * PhaseScopeModule.slotFloats) {
      _ring = Float32List(_trailFrames * PhaseScopeModule.slotFloats);
      _frames = [
        for (var slot = 0; slot < _trailFrames; slot++)
          [
            for (var level = 0; level < _detailLevels; level++)
              Float32List.sublistView(
                _ring,
                slot * PhaseScopeModule.slotFloats +
                    PhaseScopeModule.levelOffset(level),
                slot * PhaseScopeModule.slotFloats +
                    PhaseScopeModule.levelOffset(level) +
                    (MeterShape.scopePoints >> level) * 2,
              ),
          ],
      ];
      _slots = [
        for (var slot = 0; slot < _trailFrames; slot++)
          Float32List.sublistView(
            _ring,
            slot * PhaseScopeModule.slotFloats,
            (slot + 1) * PhaseScopeModule.slotFloats,
          ),
      ];
      _next = 0;
      _filled = 0;
    }

    PhaseScopeModule.writeSlot(_slots[_next], scope, frames);

    _next = (_next + 1) % _trailFrames;
    if (_filled < _trailFrames) _filled++;
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    if (_builtColor != colors.textFaint) {
      _builtColor = colors.textFaint;
      final style = OaaType.label.copyWith(color: colors.textFaint);
      _balanceLabel = layoutParagraph('BALANCE', style);
      _correlationLabel = layoutParagraph('CORRELATION', style);
      _left = layoutParagraph('L', style);
      _right = layoutParagraph('R', style);
      _mono = layoutParagraph('M', style);
      _monoNotice = layoutParagraph(
        'MONO SOURCE',
        OaaType.label.copyWith(color: colors.textMuted),
      );
    }

    if (_builtTrail != colors.accent) {
      _builtTrail = colors.accent;
      _trail = [
        for (var age = 0; age < _trailFrames; age++)
          Paint()
            ..color = colors.accent.withValues(
              alpha: math.pow(_decay, age).toDouble(),
            )
            // Butt caps: the polyline's joins cover their own ends, and caps
            // are per-segment work. The round-versus-square note that used to
            // sit here was about Skia's fast path for round *points*, which a
            // line does not take.
            ..strokeCap = StrokeCap.butt
            // A hairline in a fading braid gains nothing legible from being
            // antialiased, and on the dot cloud this trace grew from, having
            // it measured 9,616 µs against 6,057 µs.
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
       _marker = (Paint()..color = colors.accent),
       // The correlation marker below zero: a signal that is losing itself
       // in mono, which is the failure a phase scope exists to catch, and the
       // one reading on this face that earns the warning colour.
       _markerWarn = (Paint()..color = colors.warn),
       super(repaint: repaint);

  final MeterSource engine;
  final OaaColors colors;
  final _PhaseScopeModuleState state;

  final Paint _guide;
  final Paint _marker;
  final Paint _markerWarn;

  /// The balance and correlation markers: one diamond, built once and
  /// translated to wherever a reading puts it — never a `Path` on the frame
  /// path. A rotated square rather than a dot, so it reads as an indicator
  /// sitting on an axis rather than as a stray sample that escaped the plot.
  static final Path _diamond = Path()
    ..moveTo(0, -_markerReach)
    ..lineTo(_markerReach, 0)
    ..lineTo(0, _markerReach)
    ..lineTo(-_markerReach, 0)
    ..close();

  static const double _markerReach = 4.5;

  /// Stroke width of the trace, in logical pixels.
  static const double _strokeWidth = 1.0;

  @override
  void paint(Canvas canvas, Size size) {
    // The square leaves room on the right for the correlation label and
    // marker, and the same amount below for balance — and nothing on the
    // other two sides beyond a margin. It reserved the band on all four for a
    // phase, so the figure stayed centred as a square, and the price was a
    // quarter of the module's height standing empty above and below it. What
    // is centred now is the figure *with* its two label bands, which is the
    // ink the reader sees.
    final labelBand =
        (state._correlationLabel?.height ?? 0) + Space.sm + _markerReach;
    final half =
        math.min(
          size.width - Space.sm - labelBand,
          size.height - Space.sm - labelBand,
        ) /
        2;
    if (half < 24) return;

    final centre = Offset(
      (size.width - labelBand) / 2,
      (size.height - labelBand) / 2,
    );
    final square = Rect.fromCircle(center: centre, radius: half);

    // sqrt(2) of headroom, because a mono full-scale signal reaches (1,1),
    // whose rotated length is sqrt(2) — the middle of the square's top edge.
    // Without it a loud mono passage would clip against the frame and read as
    // a limiter.
    final radius = half / math.sqrt2;

    // **A one-channel source is not plotted at all.** The engine duplicates
    // channel 0 into the scope's right slot — see `oaa_scope_append` — so a mono
    // signal is L=R exactly, and this display rotates that diagonal upright: a
    // hard, bright, perfectly straight vertical line, every frame, whatever the
    // audio does. It is a true drawing of a tautology, and it is
    // indistinguishable from a scope that has stuck. The stereo cloud had the
    // same shape of bug reported as a broken module, and this is the same answer
    // — stop plotting and name the reason.
    final stereo = engine.channels >= 2;

    if (engine.generation != 0 && engine.generation != state.lastGeneration) {
      state.lastGeneration = engine.generation;
      if (stereo) {
        state.write(engine.scope, engine.scopeFrames);
      } else {
        state.blank();
      }
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
          ui.PointMode.polygon,
          state._frames[slot][_detailFor(age)],
          // strokeWidth is in the transformed space, so it has to be divided
          // back out or the line would be `radius` pixels across.
          state._trail[age]..strokeWidth = _strokeWidth / radius,
        );
      }
      canvas.restore();
    }

    // --- The frame, drawn fresh each frame so the trail cannot burn it in ---
    // A square with its diagonals: after the 45° rotation the diagonals are
    // the L and R axes, and the horizontal is the out-of-phase axis. The
    // notice, when there is one, breaks whatever would run through it — a
    // hairline through the middle of a word reads as a strikethrough, which is
    // the opposite of what the notice says.
    canvas.drawRect(square, _guide);

    final notice = stereo ? null : state._monoNotice!;
    final holdX = notice == null ? 0.0 : notice.longestLine / 2 + Space.sm;
    final holdY = notice == null ? 0.0 : notice.height / 2 + Space.xs;
    // The diagonals cross the centre at 45°, so their clearance from the
    // notice box is along the diagonal.
    final holdDiagonal = notice == null
        ? 0.0
        : math.max(holdX, holdY) * math.sqrt2;
    final diagonal = Offset(math.sqrt1_2, math.sqrt1_2);

    // The two upper diagonals start inside their corners, past the letters
    // that name them — a hairline through an `L` is the strikethrough
    // problem again, at the one place it would be read as a glyph.
    final left = state._left!;
    final letterHold = (left.height + Space.sm) * math.sqrt2;

    for (final (from, to) in [
      // The horizontal, in two halves around the notice.
      (Offset(square.left, centre.dy), Offset(centre.dx - holdX, centre.dy)),
      (Offset(centre.dx + holdX, centre.dy), Offset(square.right, centre.dy)),
      // The two diagonals, each in two halves for the same reason.
      (
        square.topLeft + diagonal * letterHold,
        centre - diagonal * holdDiagonal,
      ),
      (centre + diagonal * holdDiagonal, square.bottomRight),
      (
        square.bottomLeft,
        centre + Offset(-diagonal.dx, diagonal.dy) * holdDiagonal,
      ),
      (
        centre + Offset(diagonal.dx, -diagonal.dy) * holdDiagonal,
        square.topRight + Offset(-diagonal.dx, diagonal.dy) * letterHold,
      ),
    ]) {
      canvas.drawLine(from, to, _guide);
    }

    // The axis letters, inside the frame at the ends they name: `L` and `R`
    // a step in from their corners along the diagonals, `M` a step under
    // the top edge, where a mono signal stands after the rotation.
    final inset = Space.sm + left.height / 2;
    _letter(canvas, left, square.topLeft + Offset(inset, inset));
    _letter(canvas, state._right!, square.topRight + Offset(-inset, inset));
    _letter(canvas, state._mono!, Offset(centre.dx, square.top + inset));

    if (notice != null) {
      // Over the graticule, which stays drawn: the module is not unavailable,
      // it is showing everything a one-channel signal has to show, which is why
      // it names the reason rather than blanking the face.
      canvas.drawParagraph(
        notice,
        Offset(
          centre.dx - notice.longestLine / 2,
          centre.dy - notice.height / 2,
        ),
      );
    }

    // --- Balance, along the bottom edge --------------------------------------
    // −1 hard left to +1 hard right, the marker riding the frame itself. On a
    // one-channel source the marker is withheld the way the plot is — the
    // engine answers dead centre for mono, which is the same tautology — but
    // the label stays, because the face keeping its shape is what says the
    // module is fine and the signal has nothing to show.
    final balanceLabel = state._balanceLabel!;
    canvas.drawParagraph(
      balanceLabel,
      Offset(
        centre.dx - balanceLabel.longestLine / 2,
        square.bottom + _markerReach + Space.xs,
      ),
    );
    final balance = engine.balance;
    if (stereo && !balance.isNaN) {
      _markerAt(
        canvas,
        Offset(centre.dx + balance.clamp(-1.0, 1.0) * half, square.bottom),
        _marker,
      );
    }

    // --- Correlation, up the right edge ---------------------------------------
    // +1 — mono — at the top, where the mono axis of the plot points, and −1 at
    // the bottom: a signal that will disappear in mono, which is the failure a
    // phase scope exists to catch. Withheld for mono like the balance above;
    // the number is in `docs/METRICS.md` and in a Number Box for anybody who
    // wants it as a figure.
    final correlationLabel = state._correlationLabel!;
    // After the −90° turn the paragraph's box extends *rightwards* by its own
    // height from the origin, so the origin is the label's left edge.
    canvas.save();
    canvas.translate(
      square.right + _markerReach + Space.xs,
      centre.dy + correlationLabel.longestLine / 2,
    );
    canvas.rotate(-math.pi / 2);
    canvas.drawParagraph(correlationLabel, Offset.zero);
    canvas.restore();

    final correlation = engine.correlation;
    if (stereo && !correlation.isNaN) {
      _markerAt(
        canvas,
        Offset(square.right, centre.dy - correlation.clamp(-1.0, 1.0) * half),
        correlation < 0 ? _markerWarn : _marker,
      );
    }
  }

  void _markerAt(Canvas canvas, Offset at, Paint paint) {
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.drawPath(_diamond, paint);
    canvas.restore();
  }

  /// One axis letter, centred on [at].
  void _letter(Canvas canvas, ui.Paragraph letter, Offset at) {
    canvas.drawParagraph(
      letter,
      Offset(at.dx - letter.longestLine / 2, at.dy - letter.height / 2),
    );
  }

  @override
  bool shouldRepaint(_PhaseScopePainter oldDelegate) =>
      oldDelegate.colors != colors || !identical(oldDelegate.engine, engine);
}
