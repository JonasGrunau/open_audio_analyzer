// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';
import '../data/metric_reader.dart';

/// One measurement, watched, printed as the worst it has been.
///
/// The latch is the entire module. Every other meter here answers "what is it
/// doing now", and nobody watches fourteen of those continuously — you play a
/// mix, you talk to someone, and the one moment true peak went over is three
/// minutes in the past and gone from every display. This one keeps it until it
/// is cleared, which is the only way a warning about a transient is any use.
///
/// **A quantity the engine already accumulates has no worst moment, and is
/// read rather than latched.** LUFS-I, LRA, TP Max, Peak Max and ODR-I are
/// each a statement about the whole programme since the last reset — the
/// engine is doing the holding, and what it holds is the answer. Two of the
/// five only ever climb, so latching them was a no-op; the other three
/// converge, and latching an extremum of a converging estimator is not a
/// measurement of anything.
///
/// It printed one until 0.14.1. ODR-I is `true_peak_max − lufs_integrated`,
/// and integrated loudness passes the −70 LUFS absolute gate while a track is
/// still room tone: on a real master (322 s, ODR-I 8.6 LU) the reading swung
/// between 33.5 and 7.6 in the first second and the module latched **7.6 LU**
/// for the remaining five minutes — a number the Number Box beside it, the
/// Validator and the delivery report all disagreed with, and red under any
/// floor the programme actually cleared. The rule is not about ODR: the same
/// first seconds put a latched LUFS-I over its target for the rest of a
/// session on any programme that starts loud.
///
/// The module still holds: a reading that goes away — a link gone quiet — does
/// not take the last verdict with it, because [observe] ignores an unavailable
/// reading whichever kind of metric it is. What changed is only which reading
/// an available one replaces.
///
/// **Which metrics those are, and which direction of each one is worse, are
/// facts about the quantities rather than about this module** — so they are
/// stated once, in the vocabulary, as [Metric.isAccumulated] and
/// [Metric.isWorse]. `analyseFile` reaches the same rule from the other end
/// when it takes a running minimum of ODR-S and derives ODR-I from the
/// finished figures, and the two were written apart: a painter's private copy
/// of a rule the report also holds is two answers to what a programme did.
///
/// **So the latch is the number, and it is the only number.** Through 0.14.0
/// the big reading was the live one and the latch was a small line beneath it,
/// which made this a Number Box carrying a footnote — and the canvas already
/// has a Number Box, four cells wide, that says the live value better. The
/// live reading has not gone anywhere: it is read every frame and it is what
/// the latch is taken from. It is simply not what the module prints.
///
/// **The panel is lit, and the light is the latched state's colour** — the
/// same state the digits are printed in, so the light and the number cannot
/// disagree. The module carried a two-pixel rule down its left edge and now
/// carries a wash rising out of that edge instead — the Number Box's glow
/// turned on its side, one shader for both. The rule said its piece in a
/// hundredth of the area, which is the wrong trade for the one module built to
/// be read from across a room and out of the corner of an eye; and a stripe a
/// gutter inside the panel's own edge reads as an indent nobody asked for.
///
/// **The wash followed the live signal for one revision, and it was read as a
/// fault.** The argument for it was that a latch never clears itself, so a
/// panel that follows one stays red for the rest of the session however the
/// signal recovers, and a canvas of these ends up uniformly lit. But a module
/// whose entire subject is the worst moment of the programme is *meant* to go
/// on saying so, and the engine's reset is what ends it. What the live wash bought instead
/// was a tile that contradicts itself: `−2.5 LU` in red on an amber panel,
/// which nobody reads as two facts in one module. They read it as a light that
/// has come loose from its number, and that is how it was reported. **One
/// verdict, in two sizes**: the digits and the light are decided from the same
/// latch and cleared by the same events.
///
/// **And no reading is no light.** An em dash — nothing latched yet, a link
/// gone quiet, a quantity this build does not compute — leaves the panel dark
/// rather than washed in the accent, which is the colour that means "measured,
/// and nothing says it is wrong". The Number Box goes dark on the same rule.
///
/// It is painted **outside** what the frame hands the body, which is why the
/// canvas asks `ModuleFrame` for `bleed` on this kind and on the Number Box
/// alone: light rising out of the panel's own edge is the effect, and inside
/// the twelve-pixel inset it is a lit rectangle in a dark gutter.
///
/// **Delta is the other half of a target meter, and it is a view rather than a
/// second measurement.** The same reading, printed as its signed distance from
/// the line the target draws — the loudness target itself, the true-peak
/// ceiling, the LRA maximum, an ODR floor. `+0.4 dB` is a statement somebody
/// can act on without knowing the spec by heart, where `-0.6 dBTP` is one they
/// have to look up first. The unit under the two is not the same one — a
/// distance from a dBTP ceiling is in dB — and the module prints the one it is
/// actually showing; see `deltaUnit`. It changes nothing about the latch or the colours: both
/// are decided from the reading, so a module in delta says exactly what the
/// same module beside it says, in the units of the decision rather than of the
/// measurement.
///
/// **Asked for, and only honoured where there is a line to measure from** —
/// which is a question about the metric *and* about the target in front of it.
/// The nine metrics no target judges have no distance to print, and neither
/// has a dynamics ratio under a target that states no floor: no built-in
/// states an ODR-I one and only `dynamic-master` states an ODR-S one. The menu
/// row is disabled in both cases and the module prints the reading itself,
/// with the Δ gone from the name along with the distance it no longer shows.
/// `alertDeltaOf` is where the three are resolved, and the stored choice is
/// kept — so it comes back the moment a target draws the line.
///
/// **It printed an em dash instead until 0.14.1**, on the argument that the
/// reading itself answers whether this target states a floor. It does not: a
/// dash is what a quantity nobody measured looks like, and this was two clicks
/// from the shipped defaults — pick ODR-S in the metric row, switch Delta on,
/// under the `streaming-14` the application starts with — after which the
/// module read a dash from the first frame to the last, with a disabled menu
/// row as its only way out. It was reported as a broken module, which is
/// exactly what it was. See `targetDelta`.
///
/// Latched state is deliberately *not* in the engine. It is a property of this
/// module — two Alert Meters watching different metrics need different latches,
/// and one watching the same metric as another should be clearable on its own.
/// It is cleared by the engine's reset, which is also what clears the maxima it
/// is watching, so the two cannot disagree.
class AlertMeterModule extends StatefulWidget {
  const AlertMeterModule({
    required this.engine,
    required this.clock,
    required this.metric,
    required this.calibration,
    required this.naming,
    this.delta = false,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;
  final Metric metric;
  final Calibration calibration;

  /// How the two dynamics readings are named. See `ModuleHost`.
  final DynamicsNaming naming;

  /// Print the reading as its distance from the target rather than as itself.
  final bool delta;

  @override
  State<AlertMeterModule> createState() => _AlertMeterModuleState();
}

class _AlertMeterModuleState extends State<AlertMeterModule> {
  final _value = ValueParagraph();
  ui.Paragraph? _name;

  /// The unit both readings are printed in, or null for a metric that has
  /// none and for a delta with no line to measure from. One paragraph drawn
  /// twice: the same three characters at the same size in both places.
  ui.Paragraph? _unit;

  /// Everything the two static labels are laid out from. A record rather than
  /// a colour, because the name also carries the delta mark and the metric —
  /// guarding on the colour alone left `Δ` on screen after the setting that
  /// put it there had been switched off, and no repaint anywhere would clear
  /// it.
  ({Color color, Metric metric, DynamicsNaming naming, bool delta})? _labels;

  /// The worst state seen, and the reading that caused it.
  ///
  /// Updated from `paint`, which is unusual and deliberate: it is a plain
  /// accumulator that changes no layout and triggers no rebuild. Routing it
  /// through `setState` would rebuild this subtree up to sixty times a second
  /// to change a number a painter is already reading for free.
  ReadingState worst = ReadingState.unavailable;
  double worstValue = double.nan;

  /// The engine's reset is one of the events that clears a latch. Detected by
  /// the elapsed clock running backwards, because a reset is exactly the thing
  /// that restarts it. The others are in [didUpdateWidget].
  double _lastElapsed = 0;

  /// Back to having seen nothing.
  ///
  /// The latch is the whole module, so dropping it is not something to do
  /// lightly — but a latch that outlives what gave it meaning is worse than
  /// no latch at all: it is a number on screen, in the module built to be
  /// believed from across a room, that nothing on the canvas measured.
  void clearLatch() {
    worst = ReadingState.unavailable;
    worstValue = double.nan;
  }

  /// **Every setting that changes what this module is showing drops what it
  /// has held.** One rule rather than four, because the four are not
  /// distinguishable to somebody watching:
  ///
  ///   - a different **metric** makes the latched number a different quantity
  ///     — a true-peak maximum printed under LUFS-I, in dBTP, as the worst
  ///     loudness of the programme;
  ///   - a different **unit** — Delta on or off — is the same measurement
  ///     re-expressed, and the latch would survive it honestly. It goes all the
  ///     same: "changing what this module shows clears what it held" is a rule
  ///     that can be learnt, where "except that one" is a surprise the module
  ///     springs the first time it matters;
  ///   - a different **delivery target** moves the line the latched *state* was
  ///     decided against, and that state is the colour. A peak latched as in
  ///     spec under a −1.0 ceiling stayed green under a −2.0 one until a louder
  ///     peak arrived to be judged, which on a programme already past its
  ///     loudest never happens;
  ///   - a different **engine** is a different programme. The desktop swaps its
  ///     source for a plugin's the moment a DAW connects, and the two elapsed
  ///     clocks have no relationship — so the backwards-clock test below
  ///     catches a reset and not this. It is the same case the oscilloscope
  ///     documents at its own `didUpdateWidget`.
  @override
  void didUpdateWidget(AlertMeterModule old) {
    super.didUpdateWidget(old);
    if (old.metric != widget.metric ||
        old.delta != widget.delta ||
        old.calibration != widget.calibration ||
        !identical(old.engine, widget.engine)) {
      clearLatch();
      // The new source's clock is not a continuation of the old one's, and a
      // stale reading here would fire the reset above on the next frame or
      // suppress it for the rest of the session, depending on which way the
      // two happened to sit.
      _lastElapsed = 0;
    }
  }

  void observe(ReadingState state, double value) {
    final elapsed = widget.engine.elapsedSeconds;
    // A link that has gone quiet reports NaN seconds, and a quiet link is not a
    // reset — the latch stays. What matters is that the NaN is not *stored*:
    // NaN compares false against everything, so a `_lastElapsed` holding one
    // makes the test below false forever and the latch can never be cleared
    // again, on this source or on any source selected after it.
    if (!elapsed.isNaN) {
      if (elapsed < _lastElapsed) clearLatch();
      _lastElapsed = elapsed;
    }

    if (state == ReadingState.unavailable) return;

    // **A metric the engine accumulates is taken as it stands.** It is already
    // the whole programme's answer, and the extremum of its trajectory is a
    // property of how it converged rather than of the audio — see the class
    // header for the five minutes of ODR-I this cost. The reading is still
    // held against a link going quiet: an unavailable one returned above.
    if (widget.metric.isAccumulated) {
      worst = state;
      worstValue = value;
      return;
    }

    final severity = _severity(state);
    final latched = _severity(worst);
    if (severity > latched ||
        (severity == latched && widget.metric.isWorse(value, worstValue))) {
      worst = state;
      worstValue = value;
    }
  }

  /// How bad a state is, as a number that can be compared.
  ///
  /// Not `ReadingState.index`: `unavailable` is declared last and would
  /// therefore sort as the worst of all, when it actually means "nothing has
  /// been measured yet" and must lose to everything.
  static int _severity(ReadingState state) => switch (state) {
    ReadingState.unavailable => -1,
    ReadingState.neutral || ReadingState.inSpec => 0,
    ReadingState.warn => 1,
    ReadingState.over => 2,
  };

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    final labels = (
      color: colors.textMuted,
      metric: widget.metric,
      naming: widget.naming,
      delta: widget.delta,
    );
    if (_labels != labels) {
      _labels = labels;
      // **`textMuted`, which is what the Number Box sets its name and its unit
      // in.** These were `textFaint` — the role for a graticule tick, a
      // quantity you read past rather than read — and the two modules that
      // print one big number therefore annotated it in two different greys.
      // The name of the thing being measured is not scenery.
      final style = OaaType.label.copyWith(color: colors.textMuted);
      // **The metric's own name and nothing else.** `WORST` led it while the
      // module was working out what it was: the latch had been a small second
      // line under a live reading, and the word was what stopped the promoted
      // figure from being read as the live one. The module is now a latch end
      // to end — the digits and the panel's light are the same held verdict —
      // so the word was labelling the only thing the module does, which is
      // what the title bar above it is for. The Δ still sits immediately
      // before the metric, the way a difference is written everywhere else it
      // is printed — the Validator's column is headed Δ and the reading under
      // it is signed.
      final name = widget.metric.labelIn(widget.naming).toUpperCase();
      _name = layoutParagraph(widget.delta ? 'Δ $name' : name, style);

      // **The unit of what is printed, which in delta is not the metric's
      // own** — the reference cancels in a subtraction, so a distance from a
      // −1.0 dBTP ceiling is in dB. See `deltaUnit`.
      //
      // Fixed at [OaaType.unit] rather than scaled with the reading, which is
      // the bargain the Number Box already makes: the number grows with the
      // module and the words around it do not, because a unit that scaled
      // would be a fourteenth type scale on the canvas.
      final unit = widget.delta ? deltaUnit(widget.metric) : widget.metric.unit;
      _unit = unit.isEmpty
          ? null
          : layoutParagraph(
              unit,
              OaaType.unit.copyWith(color: colors.textMuted),
            );
    }

    // Not `MeterBody`: it clips to the body, and this module's glow is drawn to
    // the panel. The frame clips it there instead — see `ModuleFrame.bleed`.
    return CustomPaint(
      painter: _AlertPainter(
        engine: widget.engine,
        metric: widget.metric,
        calibration: widget.calibration,
        delta: widget.delta,
        colors: colors,
        state: this,
        repaint: widget.clock,
      ),
      // Without this the CustomPaint has no intrinsic size and collapses.
      child: const SizedBox.expand(),
    );
  }
}

class _AlertPainter extends MeterPainter {
  _AlertPainter({
    required this.engine,
    required this.metric,
    required this.calibration,
    required this.delta,
    required this.colors,
    required this.state,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final MeterSource engine;
  final Metric metric;
  final Calibration calibration;
  final bool delta;
  final OaaColors colors;
  final _AlertMeterModuleState state;

  /// How far past the body the glow reaches on all four sides, which is
  /// exactly the frame's inset — so the wash is drawn to the *panel* and the
  /// body's margin, which is a margin for content, does not fence light in.
  static const double _bleed = Space.smd;

  /// Rising out of the module's left edge, behind the reading.
  final EdgeGlow _glow = EdgeGlow(GlowEdge.left);

  @override
  void paint(Canvas canvas, Size size) {
    final value = readMetric(engine, metric);
    state.observe(classify(metric, value, calibration), value);

    final latched = colorForState(state.worst, colors);

    // The latched state, as light off the panel's left edge — the same verdict
    // the digits below are printed in, at the scale a room can read. A wash
    // rather than a solid block: the reading has to stay legible, and a module
    // that turns entirely red is one whose number you then cannot read at the
    // exact moment you want it. It is out before it has crossed the module, so
    // it darkens the side the reading is read from least.
    //
    // **Always present, and only its colour carries the verdict** — the same
    // bargain the Number Box makes. A wash that appeared the moment something
    // went over was a module that looked broken until it did.
    //
    // The light is [latched] itself. It used to be a switch of its own,
    // because `colorForState` answered `textPrimary` for a metric no target
    // draws a line for and a panel washed in the ink colour is a panel that
    // looks switched off rather than one with no opinion. A reading with no
    // verdict is the accent now, so the two agree and there is one colour.
    //
    // **Except where there is nothing to have an opinion about**, which is the
    // em dash — nothing latched yet, a link gone quiet, a quantity this build
    // does not measure. The light is a verdict on a reading, so with no
    // reading there is no light; the Number Box goes dark on the same rule.
    if (state.worst != ReadingState.unavailable) {
      // The panel, in the body's own coordinates.
      _glow.paint(canvas, (Offset.zero & size).inflate(_bleed), latched);
    }

    final name = state._name!;
    // **Sized off both axes, and not capped at a size a large module dwarfs.**
    // Height alone overflowed a wide, short module, and the old ceiling of 44
    // meant an Alert Meter given a quarter of a 27" display drew the same
    // digits as one in a corner — the module this one exists to be read from
    // across a room, at the size where that matters least. The width term is
    // what keeps a long reading inside the box; the ceiling is now high enough
    // that the box is what limits it. The box is the body, edge to edge —
    // there is no longer a rule down the left of it to clear.
    //
    // Half the height rather than the 0.42 it was: that fraction was chosen
    // when a smaller latched line had to fit underneath this one, and with
    // that line gone the same arithmetic left a third of the module empty.
    final fontSize = math
        .min(size.height * 0.5, size.width * 0.3)
        .clamp(14.0, 96.0)
        .toDouble();

    // **The latched reading, and it is the only one.** The live value was the
    // big number here until 0.14.1, with the latch a small line beneath it —
    // which made this a Number Box that happened to carry a footnote, and the
    // canvas already has a Number Box. What no other module can say is what
    // the worst moment of the programme was; that is the whole reason this one
    // exists, so it is what the module prints.
    //
    // The live reading is still read every frame — it is what the latch is
    // taken from — but it is not printed and it does not colour anything.
    final text = _print(state.worstValue);
    final digits = state._value.of(
      text,
      OaaType.reading(fontSize).copyWith(color: latched),
      maxWidth: size.width,
    );

    // **The block is centred in the module, not hung from its top edge.**
    // Drawn from the origin it sat in the top-left corner of a module more
    // than twice its height, leaving two thirds of the tile empty below it.
    final blockHeight = name.height + Space.xxs + digits.height;
    var top = (size.height - blockHeight) / 2;
    if (top < 0) top = 0;

    canvas.drawParagraph(name, Offset(0, top));

    final digitsTop = top + name.height + Space.xxs;
    canvas.drawParagraph(digits, Offset(0, digitsTop));
    _drawUnit(canvas, size, digits, text, Offset(0, digitsTop));
  }

  /// The unit, after a reading, on that reading's own baseline.
  ///
  /// Centring it against the value's box instead is the usual shortcut and it
  /// always looks slightly wrong, because a unit's x-height and a digit's
  /// cap-height do not agree — the same note the Number Box carries, and the
  /// same arithmetic.
  ///
  /// **Not printed after an em dash**, which is every unavailable reading and
  /// every delta with no line to measure from: `— LUFS` states a unit for a
  /// quantity nobody measured. Dropped rather than clipped where the module is
  /// too narrow to hold both, because a unit cut off halfway is worse than the
  /// number standing alone.
  void _drawUnit(
    Canvas canvas,
    Size size,
    ui.Paragraph reading,
    String text,
    Offset at,
  ) {
    final unit = state._unit;
    if (unit == null || text == unmeasured) return;

    final left = at.dx + reading.longestLine + Space.xs;
    if (left + unit.longestLine > size.width) return;

    canvas.drawParagraph(
      unit,
      Offset(
        left,
        at.dy + reading.alphabeticBaseline - unit.alphabeticBaseline,
      ),
    );
  }

  /// A reading in the units the module is set to: the measurement itself, or
  /// its distance from the target.
  String _print(double value) => delta
      ? formatDelta(targetDelta(metric, value, calibration))
      : metric.format(value);

  @override
  bool shouldRepaint(_AlertPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.metric != metric ||
      oldDelegate.calibration != calibration ||
      oldDelegate.delta != delta ||
      !identical(oldDelegate.engine, engine);
}
