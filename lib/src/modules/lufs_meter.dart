// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/widgets.dart';

import '../clock/meter_clock.dart';
import '../data/metric_reader.dart';

/// Momentary, short-term and integrated loudness as three bars on one scale.
///
/// Three bars rather than three numbers, because the only question anybody has
/// while mixing is how they relate: momentary swinging far above integrated is
/// a mix that will be turned down, and you can see that in one glance here and
/// in no arrangement of three separate figures. The figures are printed under
/// the bars anyway — a bar answers "roughly where", a delivery conversation
/// needs "exactly what".
///
/// Integrated is a bar like the other two, not a line across them: it is the
/// number that gets delivered, and it earns the same presence as the readings
/// that are chasing it. Which bar is which is written up the bar itself —
/// MOMENTARY, SHORT, INTEGRATED — because a bar tall enough to read is tall
/// enough to label, and single letters under the bars only survive as the
/// fallback for a module too small to carry the words. The name is set to the
/// bar it is written on, like the readings under it: at one fixed size the
/// word filled a narrow bar edge to edge on a small module and read as a
/// label of the meter rather than one written on a bar.
///
/// The target band comes from the active calibration and is the reason the
/// meter is worth looking at rather than the numbers underneath it. The line
/// through it is dashed, in [OaaColors.over], with the target value printed on
/// the axis in the same colour — a line at −14 LUFS with a ±0.5 LU band around
/// it turns "what is my loudness" into "am I there yet", which is the question
/// that actually gets asked.
///
/// The bars are [OaaColors.meterAccent] under [MeterFill]'s gradient, as on
/// the Digital Meter and the Super Meter's arcs — the reading's colour, over a
/// grey track. They were the grey [OaaColors.meterFill] through 0.14, and a
/// bar the colour of its own track read as a level you had to look for. Across
/// its width a bar is shaded at both edges and lit down its centre line, which
/// is what makes a column read as round; the stretch standing above the target
/// is [OaaColors.over] carrying the same shading at its edges and no light in
/// its middle, so it is the same solid as the bar under it in a different
/// paint — but flat down its height, where the bar deepens down its own. The
/// painter says why.
class LufsMeterModule extends StatefulWidget {
  const LufsMeterModule({
    required this.engine,
    required this.clock,
    required this.calibration,
    super.key,
  });

  final MeterSource engine;
  final MeterClock clock;
  final Calibration calibration;

  @override
  State<LufsMeterModule> createState() => _LufsMeterModuleState();
}

class _LufsMeterModuleState extends State<LufsMeterModule> {
  /// Ticks crowded at the top where broadcast at −23 and streaming at −14 are
  /// read, −∞ at the floor. The taper is [MeterScale.tapered]'s and shared
  /// with every other level scale.
  static const _scale = MeterScale.tapered(
    max: 0,
    ticks: [0, -3, -6, -9, -12, -18, -24, -30, -40],
  );

  /// What is written up each bar, in the painter's order.
  static const names = ['MOMENTARY', 'SHORT', 'INTEGRATED'];

  ScaleGraticule? _graticule;
  final _momentary = ValueParagraph();
  final _short = ValueParagraph();
  final _integrated = ValueParagraph();
  final _target = ValueParagraph();

  /// The names, twice — once in the text colour and once in the ground's, for
  /// the two halves of a bar. A [ValueParagraph] each rather than a paragraph
  /// each because the face is the *module's* now: the string never changes and
  /// the size does, so these re-lay-out on a resize and on nothing else.
  final _names = [ValueParagraph(), ValueParagraph(), ValueParagraph()];
  final _namesOnFill = [ValueParagraph(), ValueParagraph(), ValueParagraph()];
  List<ui.Paragraph> _letters = const [];

  /// The longest name's line, and a name's line height, per pixel of font
  /// size — measured once, at [OaaType.label]'s own size.
  ///
  /// The painter sizes the face from these rather than laying a name out to
  /// see whether it fits. It can, because it scales the tracking with the size
  /// too: everything about the paragraph is then proportional to the size, so
  /// the size that fits is arithmetic on the frame path instead of a trial
  /// layout on it — the same trade the readouts make with [_advance], and
  /// exact rather than an upper bound because it is measured from the face
  /// that will be drawn.
  late final double _nameWidthPerPx;
  late final double _nameHeightPerPx;

  @override
  void initState() {
    super.initState();
    var width = 0.0;
    var height = 0.0;
    for (final name in names) {
      final line = layoutParagraph(name, OaaType.label);
      width = math.max(width, line.longestLine);
      height = math.max(height, line.height);
    }
    _nameWidthPerPx = width / OaaType.label.fontSize!;
    _nameHeightPerPx = height / OaaType.label.fontSize!;
  }

  @override
  void dispose() {
    _graticule?.dispose();
    _momentary.dispose();
    _short.dispose();
    _integrated.dispose();
    _target.dispose();
    for (final name in _names) {
      name.dispose();
    }
    for (final name in _namesOnFill) {
      name.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    // Rebuilt only when the palette or the target changes, never per frame:
    // these hold laid-out paragraphs, and throwing them away every rebuild
    // would defeat the point of caching them.
    if (_graticule == null ||
        !_graticule!.matches(
          _scale,
          ScaleSide.both,
          colors.textFaint,
          avoiding: widget.calibration.lufsTarget,
        )) {
      _graticule?.dispose();
      _graticule = ScaleGraticule(
        scale: _scale,
        side: ScaleSide.both,
        lineColor: colors.hairline,
        labelColor: colors.textFaint,
        avoid: widget.calibration.lufsTarget,
      );

      // **Left-aligned, and centred by measuring.** These asked for
      // `TextAlign.center` once and were not drawn at all: an unconstrained
      // paragraph is laid out a megapixel wide, and centre alignment then puts
      // the glyph half a million pixels along a line whose origin is the offset
      // it is drawn at. See `layoutParagraph`.
      //
      // Only the letters are built here, at the one size they have. The names
      // are laid out by the painter, in the face the *module* asks for — a
      // palette is not what changes them any more.
      final letterStyle = OaaType.label.copyWith(color: colors.textFaint);
      _letters = [
        layoutParagraph('M', letterStyle),
        layoutParagraph('S', letterStyle),
        layoutParagraph('I', letterStyle),
      ];
    }

    return MeterBody(
      painter: _LufsMeterPainter(
        engine: widget.engine,
        calibration: widget.calibration,
        colors: colors,
        graticule: _graticule!,
        state: this,
        repaint: widget.clock,
      ),
    );
  }
}

class _LufsMeterPainter extends MeterPainter {
  _LufsMeterPainter({
    required this.engine,
    required this.calibration,
    required this.colors,
    required this.graticule,
    required this.state,
    required Listenable repaint,
  }) : _track = (Paint()..color = colors.meterTrack),
       // Taken once: `meterAccent` is derived, and `paint` allocates nothing.
       _ink = colors.meterAccent,
       // The part of a bar that stands above the target, in [OaaColors.over] —
       // the application's one mark for "past the number you set".
       _overInk = colors.over,
       _targetBand = (Paint()
         ..color = colors.textFaint.withValues(alpha: 0.18)),
       _targetDash = (Paint()
         ..color = colors.over
         ..strokeWidth = OaaStroke.mark
         ..isAntiAlias = false),
       _targetStyle = OaaType.tick.copyWith(color: colors.over),
       super(repaint: repaint);

  final MeterSource engine;
  final Calibration calibration;
  final OaaColors colors;
  final ScaleGraticule graticule;
  final _LufsMeterModuleState state;

  final Paint _track;
  final Color _ink;
  final Color _overInk;
  final Paint _targetBand;
  final Paint _targetDash;
  final MeterFill _fill = MeterFill();

  /// The over part's shading. A second [MeterFill] rather than re-preparing
  /// the first one: [MeterFill.prepare] caches on the ink and rebuilds both
  /// its shaders when it changes, so one instance alternating between two inks
  /// would build four gradients per bar per frame — an allocation on the frame
  /// path, and the one thing this class exists to avoid.
  final MeterFill _overFill = MeterFill();

  final TextStyle _targetStyle;

  /// The dashed target line, rebuilt only when the geometry moves.
  Float32List _dashes = Float32List(0);
  Rect _dashesFor = Rect.zero;
  double _dashesY = double.nan;

  /// Below this there is no room for the readouts and the bars keep the space.
  static const double _minimumHeight = 60;

  /// The same judgement as [_minimumHeight], in the other axis: under this a
  /// reading is chrome rather than a number, and the bars keep the space.
  /// The graticule's own ticks are 10, so 10 is still a number that can be
  /// read — and the default five-cell module fits its three readings at
  /// fractionally under 11, which is why 11 was the wrong floor: it hid the
  /// numbers on exactly the size the module ships at.
  static const double _minimumValueSize = 10;

  /// Advance of one glyph of [OaaType.reading], in ems. Google Sans Code is 0.6
  /// and the style tightens it by half a pixel; the slack is what keeps this an
  /// upper bound rather than a measurement.
  static const double _advance = 0.62;

  /// The glyph budget the readout band is built from — the width of `-17.6`.
  ///
  /// Fitting the string that is actually on screen resizes the whole row the
  /// moment a reading crosses −10 and gains a digit. Tabular figures exist so
  /// a readout does not move while you watch it; a face that changes size at a
  /// threshold undoes that far more visibly than proportional digits ever did.
  ///
  /// **That is why the band's height comes from this constant alone and never
  /// from the readings**, which is the half the comment above described and the
  /// code did not do: it took the longest string as well, and the band's height
  /// is what the bars stand on. So a six-glyph reading shortened the bars, and
  /// on the size this module ships at it took the face under
  /// [_minimumValueSize] and removed all three numbers. Every reading below
  /// −100 did it — which is a decade nobody mixes in, but every meter passes
  /// through it on its way down when the music stops.
  ///
  /// A longer string still has to fit, so the *drawn* face shrinks to hold it
  /// while the band stays put. A number that is briefly smaller is a far
  /// smaller lie than `-100.` in place of `-100.3`, and nothing else on the
  /// module moves for it.
  static const int _readingGlyphs = 5;

  static const double _dashOn = 4;
  static const double _dashOff = 4;

  /// A name's size: a base, plus this much of the track's height. It is taken
  /// off the *height* rather than fitted to the bar's width because a name is
  /// read as a caption on the instrument, so what it has to stay in proportion
  /// to is the instrument — a rule that only asks "does it fit" leaves 10 px
  /// type on a module a third the size of the one it was chosen on, which is
  /// where this started.
  ///
  /// **A base and a slope, not a straight proportion**, because type does not
  /// scale with its container and a rule that says it does is wrong at both
  /// ends: through the origin, a share steep enough to keep a large module's
  /// names in proportion writes a headline on it, and one gentle enough not to
  /// takes a small module under the floor and onto the letters — including the
  /// 190 px module the website photographs, which is a real size somebody
  /// docks three meters at. These two numbers put the default five-cell module
  /// a little over 10, the website's at 8 and a large one at the 12 px
  /// ceiling: about the size it always was where it started, and a gentler
  /// spread than the module around it.
  static const double _nameBaseSize = 6.0;
  static const double _nameOfTrack = 0.012;

  /// The two guards on that share, for the shapes where it is not the width
  /// that is left over. Half of the bar across it keeps the name inside the
  /// lit middle of a column that is narrow for its height, with the tube's
  /// shading either side of it — the strip it was put there to use. Seven
  /// tenths of the track along it keeps `INTEGRATED` — the long one, and the
  /// one all three sizes are taken from so that they agree — clear of the
  /// reading at the top and the foot at the bottom on a module that is wide
  /// and short.
  static const double _nameOfBar = 0.5;
  static const double _nameRunOfTrack = 0.7;

  /// The band the names are set in. Below the floor the words go and the
  /// single letters take over — a word set smaller than this is not read, it
  /// is just a mark that used to be one — and the ceiling is what stops a
  /// module the size of a screen from writing its bar names in a headline.
  static const double _minimumNameSize = 6.0;
  static const double _maximumNameSize = 12;

  @override
  void paint(Canvas canvas, Size size) {
    const gap = Space.xs;

    final momentary = engine.lufsMomentary;
    final short = engine.lufsShort;
    final integrated = engine.lufsIntegrated;
    final momentaryText = Metric.lufsMomentary.format(momentary);
    final shortText = Metric.lufsShort.format(short);
    final integratedText = Metric.lufsIntegrated.format(integrated);

    // The target's own number is wider than the tick labels — "-14.0" against
    // "-40" — so the left gutter grows to hold it whole. Laid out inside the
    // graticule's gutter it was silently cropped to "-14", which is not a
    // shortened label but a different number.
    final targetLabel = state._target.of(
      calibration.lufsTarget.toStringAsFixed(1),
      _targetStyle,
    );
    final leftInset = math.max(
      graticule.gutter,
      targetLabel.longestLine + Space.xs,
    );

    final barWidth = (size.width - leftInset - graticule.gutter - gap * 2) / 3;

    // **The readouts scale with the module, like the bars above them.** Sized
    // off the height alone, a tall narrow meter asks for a reading in a column
    // that cannot hold it — and a paragraph laid out at `maxLines: 1` does not
    // complain, it simply stops drawing where it runs out of room. `-17.6` was
    // once rendered as `-17.`, which is not a clipped number but a *different*
    // one. Every glyph of a reading is a digit, a minus or a point and the
    // face is monospaced, so the width that fits is arithmetic — no trial
    // layout on the frame path.
    // Fitted to the bar's *pitch*, not its width: the numbers are centred on
    // their bars and the gaps between bars are theirs to borrow, which is what
    // keeps them legible on a narrow module. Fitted to the bar alone, a
    // five-cell meter put the readings under the 11 px floor and drew none.
    final readoutWidth = barWidth + gap - Space.xs;
    // The band, and everything the layout hangs off it — fitted to
    // [_readingGlyphs] and to nothing that is on screen this frame.
    final bandSize = math
        .min(size.height * 0.09, readoutWidth / (_readingGlyphs * _advance))
        .clamp(0.0, 40.0)
        .toDouble();
    final readoutHeight = bandSize * 1.3 + Space.xs;
    final showReadouts =
        bandSize >= _minimumValueSize &&
        size.height > _minimumHeight + readoutHeight;

    // The face the numbers are actually set in: the band's, until a string
    // arrives that will not fit in it.
    final glyphs = math.max(
      _readingGlyphs,
      math.max(
        momentaryText.length,
        math.max(shortText.length, integratedText.length),
      ),
    );
    final valueSize = math.min(bandSize, readoutWidth / (glyphs * _advance));

    // **The names are set to the module, like the readouts under them.** At
    // one fixed size a name is a caption on a module the size of a screen and
    // a slab on one the size of a business card — and it was the slab that was
    // wrong, because the small module is the one whose bars have no width to
    // spare: at 10 px the word filled a narrow bar edge to edge and read as a
    // label *of* the meter rather than as one written on a bar. So the size is
    // a share of the track, held under both of the guards that stop it
    // overrunning a module that is a strange shape, and it is one size for all
    // three bars: three names at three sizes side by side read as three
    // modules.
    //
    // Taken from the track's height *before* the letters take their band —
    // which is exact, because the letters only appear when the names do not,
    // and it is what keeps this out of a circle with `letterHeight` below.
    final trackHeight = size.height - (showReadouts ? readoutHeight : 0);
    final nameSize = math
        .min(
          _nameBaseSize + trackHeight * _nameOfTrack,
          math.min(
            barWidth * _nameOfBar / state._nameHeightPerPx,
            trackHeight * _nameRunOfTrack / state._nameWidthPerPx,
          ),
        )
        .clamp(0.0, _maximumNameSize)
        .toDouble();
    // The single letters under the bars are the fallback for a module too
    // small to carry the words even shrunk to the floor, and only that
    // fallback costs a band of height.
    final namesFit = nameSize >= _minimumNameSize;
    final letterHeight = namesFit ? 0.0 : OaaType.label.fontSize! + Space.xs;

    final track = Rect.fromLTRB(
      leftInset,
      0,
      size.width - graticule.gutter,
      size.height - letterHeight - (showReadouts ? readoutHeight : 0),
    );
    if (track.height < 24 || track.width < 24) return;

    // With the tube across each bar — the one meter that takes it, see
    // [MeterFill]: these are solid columns with their names printed up them.
    // The level fill takes the light down its centre as well, which is what
    // makes the column round rather than merely shaded at its sides and lights
    // the strip the name stands on. The over ink takes the tube alone: it is
    // already the brightest thing in the module, and it takes neither the ramp
    // nor the light for reasons on [MeterFill.prepare] and in the bars below.
    _fill.prepare(colors, color: _ink, tube: true, centre: true);
    _overFill.prepare(colors, color: _overInk, tube: true, ramp: false);

    // **A trough per bar, not one rectangle behind all three.** Painted as a
    // single background, the gap between two bars is the same colour as the
    // empty part of either, so the bars only separate where their fills stop —
    // and when they read alike, which is most of the time on steady programme,
    // they merge into one block. The gap has to show the module behind it to
    // be a gap.
    for (var bar = 0; bar < 3; bar++) {
      final left = track.left + bar * (barWidth + gap);
      canvas.drawRect(
        Rect.fromLTRB(left, track.top, left + barWidth, track.bottom),
        _track,
      );
    }

    // Over the troughs and under everything else: the scale belongs to the
    // meter as a whole, so it crosses the gaps the way the target rule does.
    graticule.paint(canvas, track);

    // --- Target band --------------------------------------------------------
    // A band rather than a line alone, because every delivery spec states a
    // tolerance and a target drawn as a hairline is a pass/fail on an
    // infinitely thin edge that no real programme lands on.
    final targetTop = _y(
      track,
      calibration.lufsTarget + calibration.lufsTolerance,
    );
    final targetBottom = _y(
      track,
      calibration.lufsTarget - calibration.lufsTolerance,
    );
    canvas.drawRect(
      Rect.fromLTRB(track.left, targetTop, track.right, targetBottom),
      _targetBand,
    );

    // --- Bars ---------------------------------------------------------------
    // **Split at the target line, not coloured by a verdict on the whole
    // bar.** A momentary reading standing over the target is not a delivery
    // failure and must not be painted as though something had classified it as
    // one — what carries the meaning is *how much* of the bar is above the
    // line, which is the same reading the Histogram and the Loudness
    // Distribution offer as an area.
    final targetY = _y(track, calibration.lufsTarget);
    final values = [momentary, short, integrated];
    for (var bar = 0; bar < 3; bar++) {
      final value = values[bar];
      if (value.isNaN) continue;
      final left = track.left + bar * (barWidth + gap);
      final top = _y(track, value);
      if (top >= track.bottom) continue;
      final fill = Rect.fromLTRB(left, top, left + barWidth, track.bottom);
      _fill.draw(canvas, fill);
      final split = targetY.clamp(track.top, track.bottom).toDouble();
      if (top < split) {
        // **The over part takes the tube and not the ramp.** It is the same
        // paint as the bar below — the tube across it at the same depth, so
        // the two halves are one solid lit from one side — and it is flat down
        // its height, where the bar deepens down its own.
        //
        // Both alternatives were drawn and both are worse. Ramped to its own
        // height, the overshoot gets a lit edge at the reading and a deepened
        // floor at the target line, which is the shape of a *bar*: two bars
        // stacked, with the line between them reading as a foot rather than as
        // a threshold. Ramped with the whole bar and cut at the line — so that
        // the two deepen together — it is invisible, because [MeterFill.plateau]
        // is the top three tenths of the fill and an overshoot big enough to
        // leave it is not a reading a loudness meter spends time at: a
        // programme at −12.8 against a −14 target drew the same flat red it
        // drew before, to the byte. What the deepening down a fill says is how
        // far the fill is from its own foot, and an overshoot has no foot —
        // its height is already the whole of what it has to say.
        _overFill.draw(
          canvas,
          Rect.fromLTRB(left, top, left + barWidth, split),
        );
      }
    }

    // --- The target line, over the bars, and its value on the axis ----------
    // Dashed where every other rule here is solid, so the one line that is a
    // decision rather than a measurement cannot be mistaken for a reading.
    if (_dashesFor != track || _dashesY != targetY) {
      final count = ((track.width) / (_dashOn + _dashOff)).ceil();
      _dashes = Float32List(count * 4);
      var i = 0;
      for (var d = 0; d < count; d++) {
        final x = track.left + d * (_dashOn + _dashOff);
        _dashes[i++] = x;
        _dashes[i++] = targetY;
        _dashes[i++] = math.min(x + _dashOn, track.right);
        _dashes[i++] = targetY;
      }
      _dashesFor = track;
      _dashesY = targetY;
    }
    canvas.drawRawPoints(ui.PointMode.lines, _dashes, _targetDash);

    canvas.drawParagraph(
      targetLabel,
      Offset(
        track.left - Space.xs - targetLabel.longestLine,
        targetY - targetLabel.height / 2,
      ),
    );

    // --- Names, up the bars — or letters under them --------------------------
    // A name runs up its bar in two inks: the text colour on the dark track
    // and the ground's colour on the lit fill, each clipped to its own part.
    // One ink cannot do it — the fill is the accent, which sits close to the
    // text colour in luminance, and a name in one ink lost its letters to
    // whichever half it did not suit as the bar moved through them. The
    // ground's colour stays the fill's ink now that the fill runs to its
    // deepened floor colour ([MeterFill]), where a name's foot stands: it was
    // tried in the text colour there and put back, because a name cut into
    // the bar reads better than one printed over it. The tube across the bar
    // helps: it is darkest at the edges and lit down the centre line, which is
    // where the name is.
    //
    // The two faces are built once per paint rather than once per bar, and a
    // `ValueParagraph` re-lays a name out only when one of them changes —
    // which is a resize or a skin, and never a frame. The tracking is scaled
    // with the size, which is what makes the size arithmetic above exact; see
    // `_nameWidthPerPx`.
    final nameStyle = namesFit
        ? OaaType.label.copyWith(
            color: colors.textPrimary,
            fontSize: nameSize,
            letterSpacing:
                OaaType.label.letterSpacing! *
                nameSize /
                OaaType.label.fontSize!,
          )
        : null;
    final nameOnFillStyle = nameStyle?.copyWith(color: colors.background);
    for (var bar = 0; bar < 3; bar++) {
      final left = track.left + bar * (barWidth + gap);
      if (namesFit) {
        final text = _LufsMeterModuleState.names[bar];
        final name = state._names[bar].of(text, nameStyle!);
        final value = values[bar];
        final fillTop = value.isNaN
            ? track.bottom
            : _y(track, value).clamp(track.top, track.bottom).toDouble();
        final x = left + (barWidth - name.height) / 2;
        _nameUpBar(
          canvas,
          name,
          x,
          track.bottom - Space.sm,
          Rect.fromLTRB(left, track.top, left + barWidth, fillTop),
        );
        _nameUpBar(
          canvas,
          state._namesOnFill[bar].of(text, nameOnFillStyle!),
          x,
          track.bottom - Space.sm,
          Rect.fromLTRB(left, fillTop, left + barWidth, track.bottom),
        );
      } else {
        final letter = state._letters[bar];
        canvas.drawParagraph(
          letter,
          Offset(
            left + (barWidth - letter.longestLine) / 2,
            track.bottom + Space.xxs,
          ),
        );
      }
    }

    if (!showReadouts) return;

    // --- The numbers ---------------------------------------------------------
    // One under each bar, centred on it. Momentary and short-term are
    // readings; integrated is the number that gets delivered, and it alone is
    // coloured by where it stands against the target — the same convention as
    // every readout in the application.
    // **The row sits at the foot of its band, so the band's slack is air above
    // the numbers rather than below them.** A reading is set on a line taller
    // than the digits it holds, and hung from the top of the band that slack
    // fell *under* the row — where the frame's own padding already is — while
    // the numbers stood against the troughs and read as part of them. Nothing
    // moves the bars: the band is the same height it was, only the row inside
    // it has changed ends.
    final readouts = [state._momentary, state._short, state._integrated];
    final texts = [momentaryText, shortText, integratedText];
    for (var bar = 0; bar < 3; bar++) {
      final style = bar == 2
          ? OaaType.reading(valueSize).copyWith(
              color: colorForState(
                classify(Metric.lufsIntegrated, integrated, calibration),
                colors,
              ),
            )
          : OaaType.reading(
              valueSize,
            ).copyWith(color: inkForReading(values[bar], colors));
      final paragraph = readouts[bar].of(texts[bar], style);
      final left = track.left + bar * (barWidth + gap);
      canvas.drawParagraph(
        paragraph,
        Offset(
          left + (barWidth - paragraph.longestLine) / 2,
          size.height - paragraph.height,
        ),
      );
    }
  }

  double _y(Rect track, double value) =>
      track.bottom - graticule.scale.fractionOf(value) * track.height;

  /// [name] rotated to read upwards, its foot at ([x], [foot]), and only the
  /// part of it inside [clip].
  void _nameUpBar(
    Canvas canvas,
    ui.Paragraph name,
    double x,
    double foot,
    Rect clip,
  ) {
    if (clip.isEmpty) return;
    canvas.save();
    canvas.clipRect(clip);
    canvas.translate(x, foot);
    canvas.rotate(-math.pi / 2);
    canvas.drawParagraph(name, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LufsMeterPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.calibration != calibration ||
      !identical(oldDelegate.engine, engine) ||
      !identical(oldDelegate.graticule, graticule);
}
