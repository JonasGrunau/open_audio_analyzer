// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'tokens.dart';

/// A meter's body: one painter, filling whatever room the frame gives it.
///
/// The `SizedBox.expand` is not decoration. A [CustomPaint] with no child has
/// no intrinsic size and collapses to nothing, and the symptom is a module that
/// draws its frame and its title and then nothing at all — which reads as a
/// broken meter rather than as a layout mistake. Every module used to write
/// this line; now none of them can forget it.
///
/// ---------------------------------------------------------------------------
/// The clip is not decoration either
///
/// **A `CustomPaint` does not clip its painter to its size.** The size handed to
/// `paint` is a statement about the room available, not a boundary that is
/// enforced, and a painter that draws outside it draws over the module's own
/// border, its title, and whatever module the canvas put next to it.
///
/// Nothing catches this. It is not an overflow — `RenderFlex` has no part in it,
/// so there is no debug stripe and no exception — and it only appears when the
/// signal makes it appear, which for the phase scope means a sample past full
/// scale. The engine deliberately does not clamp those (a float WAV may
/// legitimately exceed ±1.0, and those overshoots are the ones true-peak
/// metering exists to find), so the scope drew its points outside its own guide
/// circle and out through the side of the module, on exactly the material
/// somebody is looking at it to check.
///
/// Clipping here rather than in each painter is the same decision as the frame:
/// a module that owns its own boundary is a module that will drift from the
/// others, and eleven of the twelve that existed then had never clipped at all.
/// A painter that wants to draw a glow past its edge has to say so, and none
/// does.
class MeterBody extends StatelessWidget {
  const MeterBody({required this.painter, super.key});

  final MeterPainter painter;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: CustomPaint(painter: painter, child: const SizedBox.expand()),
  );
}

/// The base class every module painter extends.
///
/// It exists for one reason, and it is not shared behaviour — it is a default
/// in Flutter that is wrong for this application.
///
/// [CustomPainter.hitTest] returns `null` by default, and `RenderCustomPaint`
/// reads that as **true**: a `CustomPaint` with a background painter swallows
/// every pointer event that lands on it. That default is right for a painted
/// button and wrong for a meter. The canvas puts a module's drag, select and
/// context-menu affordances *behind* the module — so that the frame's own menu
/// button keeps priority without any gesture-arena arbitration — and a painter
/// that absorbs hits makes the whole body of the module dead to the mouse. You
/// can drag a meter by its title bar and not by its face, which reads as a bug
/// in the canvas rather than a default in the painter.
///
/// So meters are display surfaces and do not take input. A module that genuinely
/// needs it — scrubbing a histogram, dragging a spectrum cursor — takes it
/// deliberately, and there are two ways. Overriding [hitTest] again claims the
/// pixels outright, and the catcher behind the module stops seeing them. The
/// spectrum analyser's cursor does the other thing: a translucent `Listener`
/// laid over the plot, which sees the raw press without entering any gesture
/// arena, so the canvas's tap behind it still selects the module and its
/// secondary tap still opens the menu — one press, both effects. Prefer that
/// unless the module's gesture genuinely has to *beat* the canvas's.
abstract class MeterPainter extends CustomPainter {
  const MeterPainter({super.repaint});

  @override
  bool? hitTest(Offset position) => false;
}

/// The shading every filled meter body is painted with: the ink over the top
/// three tenths of the fill, running from there to [OaaColors.deepen]'s floor
/// colour — and, where a meter asks for it, a tube across its width, darkest
/// at both edges.
///
/// One recipe rather than one per module, because the shading is doing a job
/// and not decorating: it keeps a tall fill from reading as a solid block of
/// paint, so the *top edge* — the measurement — is the lightest thing in the
/// bar and the floor the deepest. Modules that invent their own stops end up
/// with two bars side by side whose fills disagree about how loud "bright" is.
///
/// **The ramp is Decibel's, measured** — see [OaaColors.deepen] for the
/// colours. Down the centre of one of its bars the top [plateau] is one flat
/// colour and the rest is a straight run to the floor colour; across it the
/// lightness falls to about half at either edge on a `1 − sin(πx)` curve, and
/// there is no highlight on the centre line. Two earlier recipes here got the
/// shape wrong in ways worth recording. Through 0.14 one ramp dimmed from the
/// reading downward and reached its darkest a full track below it, so a bar
/// at two thirds of its track — where a level meter spends its time — was one
/// flat colour with a lit edge. Then a shade of the ink was laid over the
/// foot, which read as a bar standing in shadow: the reference's floor is
/// darker *and more saturated*, a deeper colour rather than a darker one, and
/// no amount of black produces that.
///
/// **The ramp is proportional to the fill**, not anchored to the track or to
/// the tip: whatever the reading, the top of the bar is the ink and its floor
/// is the floor colour. A track-anchored ramp leaves a quiet channel entirely
/// in its deep end, so its reading has no lit edge and the two channels of one
/// meter look like different instruments; a tip-anchored one never reaches
/// its floor colour on a bar that is not at full scale. Whether Decibel's is
/// proportional cannot be told from bars that stand at the same height, and
/// this one is because it is the reading that has to look right.
///
/// **The tube is the second layer, and only the LUFS Meter takes it** (`tube:`
/// on [prepare]). It is the ink's shade at both edges, gone well before the
/// centre line, at the reference's depth and on its curve pulled towards the
/// edges by [sideFalloff]. It makes a bar a solid rather than a rectangle of
/// paint and lights exactly the strip a name printed up the bar stands on,
/// which is the LUFS Meter's case and nobody else's: the Digital Meter's
/// segmented columns and the Super Meter's rings were drawn with it for an
/// afternoon and went back, because their bars are already articulated and
/// the tube on them was ornament.
///
/// **The light down the centre is not the reference's**, and it is asked for
/// separately (`centre:` on [prepare]). Decibel's bar leaves its centre line
/// at the ink; this one lifts it — [centreLift] of HSL lightness, at
/// [centreAlpha] on the line itself and gone by the edges on the mirror of the
/// tube's curve — so the bar reads as a round solid lit from the front rather
/// than a flat one shaded at its sides. Only the LUFS Meter's level fill takes
/// it, and its overshoot above the target deliberately does not: that stretch
/// is already the one thing in the module wearing [OaaColors.over], and
/// lighting its middle too competes with the edge that carries the reading.
///
/// The light rides in the tube's own gradient rather than in a layer of its
/// own. Source-over composition is associative, so the shade under the light
/// over the fill is the same paint as the shade and the light composited with
/// each other once and laid on together — which is arithmetic in
/// [sideColorsOf], done on a cache miss, instead of a third full-bar rectangle
/// per bar per frame.
///
/// A shader proportional to the fill would normally mean building one per
/// bar per frame — an allocation on the frame path — so instead each layer is
/// built once, a unit square, and the canvas is *scaled* to the fill under
/// it: the same object, stretched, exact, and free.
class MeterFill {
  final Paint _ramp = Paint();
  final Paint _side = Paint();

  bool _ready = false;
  Color? _base;
  OaaColors? _colors;
  bool _tube = false;
  bool _ramped = true;
  bool _centre = false;

  /// How far down the fill the ink runs flat before the ramp to the floor
  /// colour begins, as a fraction of the fill's height — or, on a ring, of
  /// the dial. Measured: the top three tenths of the reference bar are one
  /// colour.
  static const double plateau = 0.3;

  /// The tube's darkness: the ink's shade at [sideLightness] of its lightness,
  /// laid on at [sideAlpha] on the edges and falling to nothing on the centre
  /// line as `(1 − sin(πx))` to [sideFalloff]. The reference lands its edge at
  /// about half the centre's lightness; this is much gentler — a curve of the
  /// bar, not a pipe — for two reasons that arrived a version apart. At the
  /// measured depth the edge competed with the deepening down the bar, and the
  /// two together read as a bar in a box. Then the centre light was added, and
  /// half of what the tube was doing became its job: a round bar needs a
  /// difference between its middle and its sides, and it no longer matters
  /// which end of that difference supplies it. Lit in the middle *and* shaded
  /// hard at the edges, the bar had a range across its width wider than the
  /// one down its height, and the reading — which is the top edge — stopped
  /// being the thing the eye went to. So the sides came up until the shading
  /// is a fall-off at the very edge and nothing more, and the light down the
  /// middle carries the shape.
  ///
  /// [sideLightness] is untouched at either strength: how dark the shade
  /// *colour* is decides the hue of the edge, and it is the alpha that decides
  /// how much of it lands.
  static const double sideLightness = 0.4;
  static const double sideAlpha = 0.12;

  /// The power the tube's curve is raised to, which is what keeps the shading
  /// on the *edges*. The plain `1 − sin(πx)` still carries a quarter of the
  /// edge's darkness a quarter of the way in, so the ink over the middle of
  /// the bar — the strip a name is printed up — was dimmer than the same ink
  /// on a meter with no tube, and two bars side by side read as different
  /// colours rather than as the same colour lit differently. Above one the
  /// curve leaves the edge exactly where it was measured and gives the middle
  /// back: a quarter of the way in the tube is under a fifth of its depth
  /// rather than three tenths of it.
  static const double sideFalloff = 1.4;

  /// The centre light's lift, in HSL lightness, and how much of it lands on
  /// the centre line. The mirror of the tube in every respect: the ink lifted
  /// rather than shaded, brightest where the tube is gone and gone where the
  /// tube is deepest, on `sin(πx)` to [centreFalloff].
  ///
  /// A lift rather than a wash of white ([OaaColors.lift], not an overlay), so
  /// the light is the bar's own colour brighter and not the bar's colour going
  /// pale — the same reasoning that makes the fill's floor a [OaaColors.deepen]
  /// rather than a shade. Gentler than the tube is deep, because the eye reads
  /// a highlight as nearer than it reads a shadow as farther, and matched
  /// strengths gave a bar that bulged.
  static const double centreLift = 0.14;
  static const double centreAlpha = 0.4;

  /// The power the centre light's curve is raised to, which is what keeps it
  /// off the edges. Above one for the same reason [sideFalloff] is: the plain
  /// `sin(πx)` is still at two thirds a sixth of the way in, which lights most
  /// of the bar rather than its middle and leaves the tube nothing to be the
  /// edge of.
  static const double centreFalloff = 1.8;

  /// Across the bar, edge to edge, at every thirty-second of the width. A
  /// gradient is straight between its stops and the curve is not, and the
  /// knots show: at eight stops a bar a hundred and fifty pixels wide had
  /// faint vertical bands down it where the slope changed, one per stop. At
  /// thirty-two the change of slope at any knot is under a hundredth of the
  /// range and the eye cannot find it.
  static final List<double> sideStops = List.unmodifiable([
    for (var i = 0; i <= 32; i++) i / 32,
  ]);

  /// The cross-bar layer's colours over [base] at [sideStops], one edge to the
  /// other: the tube always, and the centre light composited into the same
  /// stops when [centre] is asked for. Allocates; built on a cache miss in
  /// [prepare], never in `draw`.
  static List<Color> sideColorsOf(Color base, {bool centre = false}) {
    final shade = OaaColors.shade(base, sideLightness);
    final lit = OaaColors.lift(base, centreLift);
    return [
      for (final x in sideStops)
        _over(
          lit.withValues(
            alpha: centre
                ? centreAlpha *
                      math.pow(math.sin(math.pi * x), centreFalloff).toDouble()
                : 0,
          ),
          shade.withValues(
            alpha:
                sideAlpha *
                math.pow(1 - math.sin(math.pi * x), sideFalloff).toDouble(),
          ),
        ),
    ];
  }

  /// [top] laid over [bottom], as one translucent colour that paints the two
  /// of them in a single pass. Source-over, in the same channels the canvas
  /// would have blended them in.
  static Color _over(Color top, Color bottom) {
    final alpha = top.a + bottom.a * (1 - top.a);
    if (alpha <= 0) return const Color(0x00000000);
    double channel(double t, double b) =>
        (t * top.a + b * bottom.a * (1 - top.a)) / alpha;
    return Color.from(
      alpha: alpha,
      red: channel(top.r, bottom.r),
      green: channel(top.g, bottom.g),
      blue: channel(top.b, bottom.b),
      colorSpace: bottom.colorSpace,
    );
  }

  /// Rebuilds the cached shaders if the palette or [color] changed. Call once
  /// per paint, before [draw]. [tube] asks for the layer across the bar and
  /// [centre] for the light down the middle of it — see the class comment for
  /// who takes each. [centre] without [tube] paints nothing: the light is a
  /// stop in the tube's gradient, not a layer of its own.
  ///
  /// **[ramp] turns the shading down the fill off**, leaving the ink flat and
  /// the tube, if asked for, across it. One caller wants that and it is worth
  /// stating why, because everything above argues for the ramp: the LUFS
  /// Meter's overshoot is a *segment* of a bar rather than a bar, and a
  /// segment shaded like one carries a lit edge at the reading and a floor at
  /// the target line, which reads as a second bar stacked on the first. The
  /// deepening down a fill says how far it is from its own foot; an overshoot
  /// has no foot of its own to be far from, and its height already says how
  /// far over it is. So it takes the tube, which is what makes a bar look like
  /// a solid, and not the ramp, which is what makes one look tall.
  void prepare(
    OaaColors colors, {
    Color? color,
    bool tube = false,
    bool ramp = true,
    bool centre = false,
  }) {
    final base = color ?? colors.meterFill;
    if (_ready &&
        _base == base &&
        _colors == colors &&
        _tube == tube &&
        _ramped == ramp &&
        _centre == centre) {
      return;
    }
    _ready = true;
    _base = base;
    _colors = colors;
    _tube = tube;
    _ramped = ramp;
    _centre = centre;
    // Down a unit square: the ink flat to [plateau], then to the floor.
    _ramp.shader = ramp
        ? ui.Gradient.linear(
            Offset.zero,
            const Offset(0, 1),
            [base, base, OaaColors.deepen(base)],
            const [0, plateau, 1],
          )
        : null;
    _ramp.color = base;
    // Across it.
    _side.shader = tube
        ? ui.Gradient.linear(
            Offset.zero,
            const Offset(1, 0),
            sideColorsOf(base, centre: centre),
            sideStops,
          )
        : null;
  }

  /// The colour at the reading — for the marks that must match the fill they
  /// annotate, like a bar's own peak cap.
  Color get bright => _base ?? const Color(0x00000000);

  /// Paints [fill] with the ramp stretched to its height and, if [prepare]
  /// was asked for it, the tube stretched to its width.
  void draw(Canvas canvas, Rect fill) {
    if (!_ready || fill.isEmpty) return;
    canvas.save();
    canvas.clipRect(fill);
    canvas.translate(fill.left, fill.top);
    canvas.scale(fill.width, fill.height);
    const unit = Rect.fromLTWH(0, 0, 1, 1);
    canvas.drawRect(unit, _ramp);
    if (_tube) canvas.drawRect(unit, _side);
    canvas.restore();
  }
}
