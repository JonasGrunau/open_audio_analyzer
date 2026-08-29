// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';

/// Where each frequency sits in the stereo image, over the last two seconds.
///
/// The phase scope answers "is this mix mono-compatible" in the time domain and
/// cannot tell you *which part* of it is not. This module is the same question
/// asked per band: horizontal is stereo position, vertical is frequency, and a
/// bass note that has drifted off centre or a cymbal pinned hard right shows up
/// as a shape in a place, which is the thing you can act on.
///
/// It shows a stretch of time rather than an instant, and that is the module.
/// A single frame of per-band pan is noise — the pan of a band between notes
/// is whatever leaked into it. Over a couple of seconds the persistent parts
/// of the image stand still while the transient parts scatter and fade, which
/// is exactly the distinction a mix engineer is trying to make.
///
/// ---------------------------------------------------------------------------
/// The picture is a ring of hits, drawn as marks, not an accumulation
///
/// Each published frame contributes one *hit* per band that stands out of the
/// mix: where the band sat and how far it stood out. The module keeps the
/// last [_frames] frames of those in a ring and draws every hit still in it
/// as a diamond — brighter and larger the louder the band, dimmer the older
/// the frame — so the display is Decibel's: a field of distinct marks, a
/// bright spine where the persistent energy sits, and a bass band that drifts
/// slowly across the middle leaving a ribbon, because its neighbours in
/// frequency and its own positions a frame apart adjoin.
///
/// The module went through two other designs first. It accumulated into an
/// image kept between frames, which held every display list back to the first
/// — see the header of `spectrogram.dart` for what that cost. Then it
/// accumulated into a grid of cell brightnesses, composited additively and
/// faded in place, which was bounded but drew the wrong picture: every band a
/// few decibels down the mix added a little to the cells it passed through,
/// and a little forty times a second is a lot, so the field filled edge to
/// edge with a haze that answered no question about *where* anything sat. A
/// hit's brightness here is its own and only its own; a quiet band is a faint
/// mark for two seconds and then nothing.
///
/// The ring is fixed at [_frames] × [MeterShape.spectrumBands] entries, which
/// is proportional to nothing the session does — not its length, not the
/// module's size. The hits are re-emitted into [PointBuckets] on every
/// published frame, one buffer per brightness step, which is that many draw
/// calls rather than one per mark; a resize re-emits the same ring at the new
/// geometry rather than dropping it.
///
/// ---------------------------------------------------------------------------
/// What makes a hit is relative, and that is what keeps the cloud readable
///
/// A fixed floor lit every band of real music every frame. What matters in a
/// mix is which bands stand out of it, so a band's weight is measured against
/// the frame's own loudest band — only the top [_StereoCloudPainter._window]
/// dB of the frame contribute at all — and cubed, so the top ten decibels do
/// nearly all of the lighting and a band twenty down is a mark the eye finds
/// only by looking for it. Squared over a 36 dB window, which is where this
/// started, lit two thirds of every frame's bands and the field read as a
/// haze whatever was drawn into it.
///
/// ---------------------------------------------------------------------------
/// Where a hit sits is the pan pot's angle, not the power balance
///
/// The engine publishes a band's balance as `(R − L) / (R + L)` over power,
/// which is the honest measurement and the wrong ruler for a picture: it is
/// steepest at the centre, so a band three decibels louder on one side lands
/// a third of the way to the edge and one ten decibels louder is nearly hard
/// against it, and every band with any width to it swept the plot from side
/// to side. What a mix engineer means by "half left" is the pan pot at half,
/// and under the constant-power law that is an amplitude *angle*:
/// `atan2(√R, √L)`, 45° at centre, 0 and 90° at the edges. Drawn at that
/// angle a source sits where its pot is, and a three-decibel lean is a fifth
/// of the way over. The measurement is unchanged; only the ruler is.
class StereoCloudModule extends StatefulWidget {
  const StereoCloudModule({
    required this.engine,
    required this.clock,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;

  @override
  State<StereoCloudModule> createState() => _StereoCloudModuleState();
}

/// How many brightness steps the marks are drawn in. Each is one
/// `drawRawPoints` call, so this is also the number of draw calls per frame.
/// Sixteen steps on a soft cloud are not distinguishable from a continuous
/// ramp.
const int _alphaSteps = 16;

/// Published frames of history the ring holds — about two seconds at the
/// engine's rate, which is enough for a slow drift to draw its ribbon and
/// short enough that a change in the mix is seen as one.
const int _frames = 96;

/// The diamond drawn for the faintest and the brightest hit, in logical
/// pixels. Level is told twice, by brightness and by size, because a bright
/// mark two pixels wide and a dim one read as the same thing at arm's length
/// and a loud band is the one thing the eye is meant to land on.
const double _markMin = 1.5;
const double _markMax = 4.0;

class _StereoCloudModuleState extends State<StereoCloudModule> {
  /// The ring: where each band sat, and how far it stood out of its frame
  /// (`0` for a band that did not), for each of the last [_frames] frames.
  /// Slot [_head] is where the next frame goes; the newest is the one before.
  final Float32List _pan = Float32List(_frames * MeterShape.spectrumBands);
  final Float32List _weight = Float32List(_frames * MeterShape.spectrumBands);
  int _head = 0;

  /// The base index of the slot the next frame is recorded into, advancing
  /// the ring. The caller fills every band of it — a band that does not stand
  /// out is written as a weight of zero, not skipped, or the slot would keep
  /// the hits of a frame [_frames] frames ago.
  int beginFrame() {
    final base = _head * MeterShape.spectrumBands;
    _head = (_head + 1) % _frames;
    return base;
  }

  /// Records a frame with no hits — a mono source, or one with no spectrum —
  /// so what is on screen ages out instead of freezing.
  void recordNothing() {
    final base = beginFrame();
    _weight.fillRange(base, base + MeterShape.spectrumBands, 0);
  }

  /// The emitted ring, sorted by brightness.
  final _marks = PointBuckets(_alphaSteps);

  /// One [Paint] per brightness step.
  List<Paint> _passes = const [];
  Color? _builtFor;
  ui.Paragraph? _left;
  ui.Paragraph? _centre;
  ui.Paragraph? _right;
  ui.Paragraph? _pair;
  ui.Paragraph? _mono;
  List<ui.Paragraph> _frequencyLabels = const [];

  /// The widest frequency label, which is what the gutter is sized by.
  double _frequencyInk = 0;

  /// Which [kHzGrid] values carry a label at the current plot height, solved
  /// when the plot resizes rather than per frame — by [fitHzLabels], the one
  /// rule every frequency axis fits by. The gridlines are all drawn; only the
  /// text thins, because two labels printed into each other read as neither.
  List<bool> _labelled = const [];
  double _labelledFor = -1;

  void solveAxis(double plotHeight) {
    if (_labelledFor == plotHeight || _frequencyLabels.isEmpty) return;
    _labelledFor = plotHeight;
    final labelHeight = _frequencyLabels.first.height;
    _labelled = fitHzLabels(plotHeight, (_) => labelHeight);
  }

  /// Generation 0 is "nothing has been measured yet". The arrays behind a fresh
  /// source are zeroed, which as dB is full scale on every band, at a pan of
  /// dead centre — a bright line down the middle of the cloud that then takes
  /// two seconds to fade, before any audio has arrived.
  int lastGeneration = 0;

  /// The plot the marks were last emitted for. A resize re-emits the ring at
  /// the new geometry; nothing is dropped, because the ring is bands and
  /// positions rather than cells.
  Size _emittedFor = Size.zero;

  /// Sorts every hit in the ring into a brightness step, newest frame first.
  ///
  /// **The positions are pre-rotated by −45°.** The painter draws the marks
  /// under a canvas rotated by +45°, which is what turns a square-capped point
  /// into a diamond; the two rotations cancel and each mark lands where the
  /// band and its pan put it. Rotating the canvas is free; rotating thirty
  /// thousand marks by hand is a multiply-add per mark, done here where they
  /// are already being written.
  void emit(Size plot) {
    _emittedFor = plot;
    _marks.clear();
    const bands = MeterShape.spectrumBands;
    const r = 0.7071067811865476;
    for (var age = 0; age < _frames; age++) {
      final slot = (_head - 1 - age + _frames) % _frames;
      final fade = 1 - age / _frames;
      final base = slot * bands;
      for (var band = 0; band < bands; band++) {
        final alpha = _weight[base + band] * fade;
        if (alpha < 1 / 255) continue;
        final bucket = (alpha * _alphaSteps).ceil().clamp(1, _alphaSteps) - 1;
        final x = plot.width / 2 * (1 + _pan[base + band]);
        final y = plot.height * (1 - band / bands);
        _marks.point(bucket, (x + y) * r, (y - x) * r);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    if (_builtFor != colors.accent) {
      _builtFor = colors.accent;
      _passes = [
        for (var step = 0; step < _alphaSteps; step++)
          Paint()
            ..color = colors.accent.withValues(alpha: (step + 1) / _alphaSteps)
            // A square cap, drawn under the painter's 45° rotation — see
            // [emit] — is a diamond; its size grows with the step, so the
            // brightest marks are also the largest.
            ..strokeWidth =
                _markMin + (_markMax - _markMin) * (step + 1) / _alphaSteps
            ..strokeCap = StrokeCap.square,
      ];

      final style = OaaType.tick.copyWith(color: colors.textFaint);
      _left = layoutParagraph('L', style);
      _centre = layoutParagraph('C', style);
      _right = layoutParagraph('R', style);
      // Which pair of channels the pan is computed from — the engine's
      // `spectrum_pan` reads the front pair, and a caption that says so is
      // what keeps the display honest on a source wider than stereo.
      _pair = layoutParagraph(
        'STEREO 1-2',
        OaaType.tick.copyWith(color: colors.accent),
      );
      _mono = layoutParagraph(
        'MONO SOURCE',
        OaaType.label.copyWith(color: colors.textMuted),
      );
      _frequencyLabels = [
        for (final hz in kHzGrid) layoutParagraph(formatHz(hz), style),
      ];
      _frequencyInk = 0;
      for (final label in _frequencyLabels) {
        if (label.longestLine > _frequencyInk) {
          _frequencyInk = label.longestLine;
        }
      }
      _labelledFor = -1;
    }

    return MeterBody(
      painter: _StereoCloudPainter(
        engine: widget.engine,
        colors: colors,
        state: this,
        repaint: widget.clock,
      ),
    );
  }
}

class _StereoCloudPainter extends MeterPainter {
  _StereoCloudPainter({
    required this.engine,
    required this.colors,
    required this.state,
    required Listenable repaint,
  }) : _guide = (Paint()
         ..color = colors.hairline
         ..strokeWidth = OaaStroke.hairline
         ..isAntiAlias = false),
       _centreGuide = (Paint()
         ..color = colors.hairlineStrong
         ..strokeWidth = OaaStroke.hairline
         ..isAntiAlias = false),
       // Two dividers stood here instead — one right of the frequency scale,
       // one above the L/C/R strip, both in the strong hairline. See
       // [PlotBorder] for why the field is boxed rather than ruled, and why
       // the box is the gridlines' own ink.
       _border = PlotBorder(colors),
       super(repaint: repaint);

  final MeterSource engine;
  final OaaColors colors;
  final _StereoCloudModuleState state;

  final Paint _guide;
  final Paint _centreGuide;
  final PlotBorder _border;

  /// Bands quieter than this contribute nothing, whatever the frame's maximum
  /// is. The relative window below carries the picture; this absolute floor is
  /// what keeps a silent frame from normalising its own noise to full
  /// brightness — with only a relative rule, digital black would light the
  /// cloud as confidently as a chorus. A band this quiet has no pan worth
  /// plotting either: it is the pan of whatever leaked into an empty band —
  /// see the note on `spectrumPan` in the engine.
  static const double _floorDb = -78;

  /// How far under the frame's loudest band a band may sit and still be a
  /// hit. Only what stands out of the mix places itself; see the header.
  static const double _window = 30;

  @override
  void paint(Canvas canvas, Size size) {
    if (state._passes.isEmpty) return;

    // The frequency scale in a gutter on the left and L, C, R in a strip
    // below, both outside the field's border — the scales beside the field
    // rather than over it, which is how Decibel lays the module out and what
    // keeps a label from ever sitting on a mark. Below the size floor the spectrogram uses
    // for the same decision, the gutter goes and the field is the whole width;
    // the strip stays, because a cloud without its L and R cannot be read at
    // all. Decided from the size alone, so nothing about the signal can flip
    // the layout.
    final left = state._left!;
    final axes = size.width >= 140 && size.height >= 80;
    final gutter = axes ? state._frequencyInk + Space.xs : 0.0;
    final strip = Space.xs + left.height;
    // The box, and the field inside it — see [PlotBorder]. The ring of marks
    // is emitted in the field's own coordinates, so it moves with it.
    final box = Rect.fromLTRB(gutter, 0, size.width, size.height - strip);
    final plot = PlotBorder.inside(box);
    if (plot.height < 40 || plot.width <= 0) return;

    // A one-channel source has no stereo position to plot, and the engine says
    // so the way it says it for `correlation` and `balance`: mono is dead
    // centre. Drawing that is a confident bright line down the middle of the
    // display for every band at once — which is indistinguishable from a broken
    // module, and was reported as one. An empty frame is still recorded, so
    // switching to a mono device ages the previous cloud out rather than
    // freezing it.
    final stereo = engine.channels >= 2;

    var stale = state._emittedFor != plot.size;

    if (engine.generation != 0 && engine.generation != state.lastGeneration) {
      state.lastGeneration = engine.generation;
      if (stereo && engine.hasSpectrum) {
        _record();
      } else {
        state.recordNothing();
      }
      stale = true;
    }

    if (stale) state.emit(plot.size);

    // The marks, as diamonds — see [_StereoCloudModuleState.emit] for the
    // rotation; the ring is emitted in the plot's own coordinates, so the
    // canvas is moved to the plot's corner before it is turned. Clipped to the
    // plot, because a mark half off its edge would otherwise be drawn into
    // the gutter or the strip.
    canvas.save();
    canvas.clipRect(plot);
    canvas.translate(plot.left, plot.top);
    canvas.rotate(math.pi / 4);
    state._marks.draw(canvas, ui.PointMode.points, state._passes);
    canvas.restore();

    // --- Guides -------------------------------------------------------------
    // **The frequency axis first, then the centre line over it.** The two are
    // not peers: the horizontals are a scale to read a height against, and the
    // vertical is the fact the module exists to show — where dead centre is.
    // Drawn underneath, it was interrupted at every crossing by a line dimmer
    // than itself, which reads as a dashed line rather than as a marked
    // centre. Crossing hairlines have to resolve one way or the other, and the
    // one that resolves in front is the one carrying the meaning.
    //
    // A gridline for every value of the shared series; a label only where the
    // plot is tall enough for it — solved on resize, not per frame — and only
    // where there is a gutter to put it in.
    state.solveAxis(plot.height);
    for (var i = 0; i < kHzGrid.length; i++) {
      final y = _y(plot, bandOfHz(kHzGrid[i]));
      if (y > plot.top + 0.5 && y < plot.bottom - 0.5) {
        canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), _guide);
      }
      if (axes && i < state._labelled.length && state._labelled[i]) {
        // Right-aligned against the border, centred on its line and kept
        // inside the plot, as the spectrogram's are: the same series on two
        // modules side by side has to sit the same way against the same lines.
        final label = state._frequencyLabels[i];
        canvas.drawParagraph(
          label,
          Offset(
            plot.left - Space.xs - label.longestLine,
            (y - label.height / 2).clamp(plot.top, plot.bottom - label.height),
          ),
        );
      }
    }

    // Drawn after the gridlines so every corner resolves in its favour.
    _border.paint(canvas, box);

    final pair = state._pair!;
    canvas.drawParagraph(
      pair,
      Offset(plot.right - pair.longestLine - Space.sm, plot.top + Space.sm),
    );

    final centre = plot.center.dx;
    if (stereo) {
      canvas.drawLine(
        Offset(centre, plot.top),
        Offset(centre, plot.bottom),
        _centreGuide,
      );
    } else {
      // Broken around the notice below. A hairline through the middle of a
      // word reads as a strikethrough, which is the opposite of what the
      // notice says.
      final gap = state._mono!.height / 2 + Space.xs;
      canvas.drawLine(
        Offset(centre, plot.top),
        Offset(centre, plot.center.dy - gap),
        _centreGuide,
      );
      canvas.drawLine(
        Offset(centre, plot.center.dy + gap),
        Offset(centre, plot.bottom),
        _centreGuide,
      );
    }

    // L under the plot's left edge, R under its right, C under the centre
    // line — under the *plot*, not the module, so each letter names the edge
    // of the field it labels.
    final centreLabel = state._centre!;
    final right = state._right!;
    final stripTop = plot.bottom + Space.xs;
    canvas.drawParagraph(left, Offset(plot.left, stripTop));
    canvas.drawParagraph(
      centreLabel,
      Offset(centre - centreLabel.longestLine / 2, stripTop),
    );
    canvas.drawParagraph(
      right,
      Offset(plot.right - right.longestLine, stripTop),
    );

    if (!stereo) {
      // The axis stays drawn beneath it. The module is not unavailable — it is
      // showing everything a mono signal has, which is why it names the reason
      // rather than blanking the face.
      final mono = state._mono!;
      canvas.drawParagraph(
        mono,
        Offset(
          plot.center.dx - mono.longestLine / 2,
          plot.center.dy - mono.height / 2,
        ),
      );
    }
  }

  /// Records this frame's hits into the ring.
  ///
  /// **Relative to the frame's own loudest band.** Only the top [_window] dB
  /// of the frame are hits at all, weighted by how far into that window they
  /// stand, squared — see the header. Every band is written, a weight of zero
  /// for the ones that are not, so the slot carries this frame and nothing
  /// older.
  void _record() {
    final spectrum = engine.spectrum;
    final pan = engine.spectrumPan;
    var maxDb = _floorDb;
    for (var band = 0; band < MeterShape.spectrumBands; band++) {
      final db = spectrum[band];
      if (db > maxDb) maxDb = db;
    }
    if (maxDb <= _floorDb) {
      state.recordNothing();
      return;
    }
    final sill = maxDb - _window;

    final base = state.beginFrame();
    for (var band = 0; band < MeterShape.spectrumBands; band++) {
      final db = spectrum[band];
      if (db <= sill || db <= _floorDb) {
        state._weight[base + band] = 0;
        continue;
      }
      final loudness = ((db - sill) / _window).clamp(0.0, 1.0);
      state._weight[base + band] = loudness * loudness * loudness;
      state._pan[base + band] = _positionOf(pan[band]);
    }
  }

  /// The pan pot's angle for a power balance — see the header. The balance
  /// gives each channel's share of the band's power, `(1 ± b) / 2`; their
  /// square roots are the amplitudes the angle is taken between, and the
  /// angle is scaled so that centre is 0 and the two edges are ±1.
  static double _positionOf(double balance) {
    final b = balance.clamp(-1.0, 1.0);
    final angle = math.atan2(math.sqrt((1 + b) / 2), math.sqrt((1 - b) / 2));
    return angle / (math.pi / 4) - 1;
  }

  /// Low frequencies at the bottom, as on the analyser.
  double _y(Rect plot, double band) =>
      plot.bottom - plot.height * band / MeterShape.spectrumBands;

  @override
  bool shouldRepaint(_StereoCloudPainter oldDelegate) =>
      oldDelegate.colors != colors || !identical(oldDelegate.engine, engine);
}
