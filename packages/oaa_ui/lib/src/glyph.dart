// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'tokens.dart';

/// The marks Open Audio Analyzer draws where a word would be slower to read.
///
/// **Geometry, never a glyph, and never an icon font.** `▾` was typeset once,
/// in `PanelMenu`, and came out as a tofu box on every platform — it is in
/// neither Inter nor most of the fallback stack. Open Audio Analyzer bundles
/// two text faces and nothing else, so a mark that is a codepoint is a mark
/// that can go missing on a machine nobody built on, and it goes missing
/// silently. Sixteen pixels of path cannot.
///
/// **The set is closed, and it is short on purpose.** A vocabulary that gains a
/// mark per panel is one nobody learns: the reader has to stop and decode each
/// one, which is slower than the word it replaced and looks busier than the
/// plain row it replaced. Nine of these eleven earn their place by saying
/// something the text beside them does not —
///
/// - [broadcast] is a machine putting measurements on the network. It marks the
///   half of the remote panel that sends, and every host a search found.
/// - [display] is a screen showing somebody else's. It marks the half that
///   receives, and the two are otherwise a pair of near-identical text rows.
/// - [chevron] says a row opens something rather than selecting in place. A
///   `PanelListRow` is normally a choice among peers; a chevron is how the two
///   that push a panel say so before they are pressed.
/// - [check] marks the option a menu already holds. It is the one mark in this
///   set that is not saying what a row *does*, and the one whose absence is
///   also a statement: the rows without it, in a menu that has one, are the
///   options still open. See `OaaMenuRow`, which reserves its column in every
///   row of such a menu so that the labels do not step sideways as the value
///   moves.
/// - [qr] and [scan] are the two ends of pairing by camera: a code being shown
///   and a code being read. They are not each other's reflection the way the
///   pair below is, because they are not a pair a reader chooses between —
///   each one appears in the panel for its own direction, beside a row whose
///   words already say which. What the mark adds is that this row is about a
///   *camera* rather than about an address, which is the fact somebody with a
///   tablet in one hand is scanning the panel for.
/// - [warning] flags a note that is a problem rather than an explanation. Panels
///   are full of caption-sized prose in one grey, and the sentence that says the
///   link has no password may not read as one more line of it.
/// - [undo] and [redo] are each other's reflection, which is the whole of their
///   argument: `UNDO` and `REDO` differ by one letter in the middle of a word,
///   and the eye has a mirrored pair's direction before it has read anything.
///   They ride beside those two words rather than replacing them — a mark tells
///   the pair apart faster than the words do, and names neither on its own.
///
/// The last two are the exception to that rule and the argument for them is a
/// different one: [settings] and [restart] **replace** a word rather than
/// annotating one, which is the thing this set exists not to do.
///
/// - [settings] is two faders. It is the row of sliders and pickers the panel
///   it opens actually is, and it is one of the two or three marks a reader
///   already holds without being taught — which is the test that matters here,
///   because nothing beside it says the word.
/// - [restart] is a ring with a gap and a head on it: go round again. What it
///   opens is not a door but a decision, so it keeps the tooltip its word
///   carried, which named the scope the word could not.
///
/// What earns them the exception is arithmetic rather than taste. They sit in
/// the menu bar, which on macOS is the window's title bar, and that row's width
/// is what decides whether the open document's name can be centred in the window
/// at all: `SETTINGS` and `RESET` are 145 px of the 457 px the trailing group
/// came to, and two marks are 84. The 61 px is the difference between a name on
/// screen at the narrowest window the application supports and a name that needs
/// 1026 px before it can be drawn. A mark that costs a reader a beat of decoding
/// is a poor trade for 61 px in a panel, where a control has a row to itself;
/// it is a good one for the row that has to hold everything.
///
/// Anything past these is a design decision to make here, not at a call site.
enum OaaMark {
  /// A source radiating: publishing, or a host that was found publishing.
  broadcast,

  /// A screen on a stand: this machine used as somebody else's display.
  display,

  /// This row opens something.
  chevron,

  /// This row is the value the menu already holds.
  check,

  /// A pairing code to be shown: modules on a grid, three of them where a QR
  /// code's finders are.
  qr,

  /// A pairing code to be read: the reticle the scanner draws over its camera,
  /// at the size of a row's mark.
  scan,

  /// This note is a problem.
  warning,

  /// Step back through the layout history.
  undo,

  /// Step forward again.
  redo,

  /// Two faders: the settings panel, named by what is in it.
  settings,

  /// Start again — a ring with a gap and a head on it.
  restart,
}

/// One [OaaMark], painted at [size] in [color].
///
/// The stroke does not follow the size — see `_MarkPainter._weight`. A mark
/// beside a caption and a mark beside a title are the same weight of line as
/// every graticule in the application rather than two different ideas of
/// "thin".
class OaaGlyph extends StatelessWidget {
  const OaaGlyph(
    this.mark, {
    required this.color,
    this.size = Space.md,
    super.key,
  });

  final OaaMark mark;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: _MarkPainter(mark, color)),
  );
}

/// One painter for the set rather than one per mark.
///
/// [hitTest] returns false for the reason `MeterPainter` exists: a `CustomPaint`
/// with a background painter swallows every pointer event that lands on it, and
/// these marks sit inside rows and buttons that are the thing being pressed.
class _MarkPainter extends CustomPainter {
  const _MarkPainter(this.mark, this.color);

  final OaaMark mark;
  final Color color;

  @override
  bool? hitTest(Offset position) => false;

  /// The line weight, which is a property of what a mark *is* and not of how
  /// big it is drawn: a mark beside a caption and a mark beside a title are the
  /// same line as every graticule in the application, rather than two different
  /// ideas of "thin".
  ///
  /// One weight for all of them, because all of them annotate — every one sits
  /// beside the words that name the thing. [OaaMark.undo] and [OaaMark.redo]
  /// were briefly set at [OaaStroke.emphasis], which was right while they stood
  /// alone in the tab strip carrying an action with no word to be found by;
  /// back beside `UNDO` and `REDO` that weight is a mark shouting over its own
  /// label.
  static const double _weight = OaaStroke.mark;

  @override
  void paint(Canvas canvas, Size size) {
    // Every mark below is written in a unit square and scaled here, so one set
    // of coordinates serves whatever size a call site asks for.
    final s = size.shortestSide;
    Offset p(double x, double y) => Offset(x * s, y * s);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _weight
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color;

    switch (mark) {
      // A dot with two arcs to each side. Deliberately not the wifi fan, which
      // means "this device has a network" — this means "this machine is
      // sending", and it radiates both ways to say so.
      case OaaMark.broadcast:
        canvas.drawCircle(p(0.5, 0.5), s * 0.09, fill);
        for (final radius in const [0.26, 0.44]) {
          final box = Rect.fromCircle(center: p(0.5, 0.5), radius: s * radius);
          canvas.drawArc(box, -0.7, 1.4, false, stroke);
          canvas.drawArc(box, 3.1416 - 0.7, 1.4, false, stroke);
        }

      case OaaMark.display:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(0.08 * s, 0.14 * s, 0.92 * s, 0.68 * s),
            OaaRadius.xs,
          ),
          stroke,
        );
        canvas.drawLine(p(0.5, 0.68), p(0.5, 0.86), stroke);
        canvas.drawLine(p(0.28, 0.86), p(0.72, 0.86), stroke);

      // **Five filled cells of a three-by-three grid, not a drawing of a QR
      // code.** Five filled cells in a 3x3 grid were tried first, on the
      // reasoning that a filled cell holds its edge at any size where a ring
      // does not — and what it actually reads as is a dice face. A QR code is
      // recognised by its three finders and by nothing else, so a mark without
      // them is a grid, whatever it is called.
      case OaaMark.qr:
        // Laid out on the 24-unit grid Material Symbols uses, so the shape is
        // the one everybody has already learnt to read: three finders and a
        // scatter of data cells, in the proportions of `qr_code`.
        //
        // **The finders are rings cut by an even-odd fill, not stroked
        // squares.** A stroke has one weight whatever the mark is drawn at, so
        // the hole closes as the glyph shrinks and three grey blobs are left;
        // a cut ring keeps the QR code's own 2:8 proportion at every size and
        // cannot close at all. That was the objection to the literal version
        // and it was an objection to the stroke rather than to the shape.
        double u(double units) => units / 24 * s;

        for (final (x, y) in const [(3.0, 3.0), (3.0, 13.0), (13.0, 3.0)]) {
          canvas.drawPath(
            Path()
              ..fillType = PathFillType.evenOdd
              ..addRect(Rect.fromLTWH(u(x), u(y), u(8), u(8)))
              ..addRect(Rect.fromLTWH(u(x + 2), u(y + 2), u(4), u(4))),
            fill,
          );
        }

        for (final (x, y) in const [
          (13.0, 13.0),
          (15.0, 15.0),
          (13.0, 17.0),
          (15.0, 19.0),
          (17.0, 17.0),
          (17.0, 13.0),
          (19.0, 15.0),
          (19.0, 19.0),
        ]) {
          canvas.drawRect(Rect.fromLTWH(u(x), u(y), u(2), u(2)), fill);
        }

      // Four corner brackets, which is the same reticle the scanner draws over
      // its camera image — one shape for "a code goes here", at two sizes.
      case OaaMark.scan:
        const inset = 0.09;
        const arm = 0.30;
        for (final (x, y) in const [(0, 0), (1, 0), (0, 1), (1, 1)]) {
          // Written once for the top-left corner and reflected, so the four
          // cannot drift apart by a hundredth of a unit square.
          final ox = x == 0 ? inset : 1 - inset;
          final oy = y == 0 ? inset : 1 - inset;
          final dx = x == 0 ? arm : -arm;
          final dy = y == 0 ? arm : -arm;
          canvas.drawPath(
            Path()
              ..moveTo(ox * s, (oy + dy) * s)
              ..lineTo(ox * s, oy * s)
              ..lineTo((ox + dx) * s, oy * s),
            stroke,
          );
        }

      case OaaMark.chevron:
        canvas.drawPath(
          Path()
            ..moveTo(0.36 * s, 0.20 * s)
            ..lineTo(0.66 * s, 0.50 * s)
            ..lineTo(0.36 * s, 0.80 * s),
          stroke,
        );

      // Two strokes, and the long one is steeper than the short one is — a
      // check whose arms meet at a right angle reads as a tick drawn by a
      // machine, which is what the first attempt looked like beside text.
      // The elbow sits below the middle of the box so the mark is optically
      // centred against a line of type rather than geometrically centred in
      // its own square.
      case OaaMark.check:
        canvas.drawPath(
          Path()
            ..moveTo(0.16 * s, 0.53 * s)
            ..lineTo(0.39 * s, 0.76 * s)
            ..lineTo(0.84 * s, 0.24 * s),
          stroke,
        );

      case OaaMark.warning:
        canvas.drawPath(
          Path()
            ..moveTo(0.5 * s, 0.10 * s)
            ..lineTo(0.95 * s, 0.86 * s)
            ..lineTo(0.05 * s, 0.86 * s)
            ..close(),
          stroke,
        );
        canvas.drawLine(p(0.5, 0.38), p(0.5, 0.58), stroke);
        canvas.drawCircle(p(0.5, 0.72), OaaStroke.hairline, fill);

      case OaaMark.undo:
        _uturn(canvas, s, stroke, mirrored: false);
      case OaaMark.redo:
        _uturn(canvas, s, stroke, mirrored: true);

      // Two faders on their rails, at different settings — a mixer's own
      // picture of a preference. Two rather than the three Material's `tune`
      // draws: at sixteen pixels the third rail closes the gaps between them
      // and the mark reads as a hatch pattern.
      //
      // The knobs are filled dots rather than the vertical caps a fader
      // actually has, because a cap is the same weight of line as the rail it
      // crosses and the two merge; a dot is the one shape in this set that
      // cannot be mistaken for the stroke it sits on. They are off-centre in
      // opposite directions, which is what says these are *set* to something
      // rather than being a pair of lines.
      case OaaMark.settings:
        for (final (y, x) in const [(0.32, 0.36), (0.68, 0.64)]) {
          canvas.drawLine(p(0.08, y), p(0.92, y), stroke);
          canvas.drawCircle(p(x, y), s * 0.13, fill);
        }

      // A ring interrupted at the top, with an arrowhead standing in the
      // interruption: the measurement starts again from here. Drawn clockwise
      // because that is the direction a clock runs and this restarts one.
      //
      // Smaller than the square it is drawn in, unlike the two faders above: a
      // ring reads bigger than its own bounds where two horizontal rules read
      // smaller than theirs, so matching the geometry would leave the two
      // buttons looking mismatched. 0.30 is the radius at which they weigh the
      // same.
      //
      // **`Icons.refresh` is the canonical shape and it was compared against
      // this one, at 16 px, side by side.** It costs nothing to use —
      // `uses-material-design: true` already pays for the font, and Flutter
      // tree-shakes it to the glyphs a build actually draws — and it is not
      // adopted for the reason `tab_strip.dart` gives about `Icons.undo`: it is
      // drawn on a 24 dp grid at Material's own ink weight, which is heavier
      // than the hairlines everything else in this interface is made from, and
      // it would sit in the same 40 px row as `qr` and one seam from `undo`.
      // Two vocabularies in one row is worse than either. What the comparison
      // *did* settle is the size of the head below: it is Material's, because a
      // head small enough to be tasteful is a head nobody reads as an arrow.
      //
      // **The head is a filled triangle, not two strokes turned off the arc.**
      // Two barbs were tried and are wrong at both ends of the size range for
      // the reason `_weight` exists: the stroke is a fixed 1.5 px whatever the
      // mark is drawn at, so barbs long enough to read at 16 px are a pair of
      // whiskers half the radius long at 96, and barbs short enough to look
      // right at 96 are one pixel of ink each in a row. A silhouette has no
      // stroke width to be out of proportion with, and it is the shape
      // everything else in this set uses when a mark has to hold at a row's
      // size — see [qr]'s cut rings.
      case OaaMark.restart:
        // **The head is level: its tip sits exactly halfway up its own
        // height.** That is the property, and it is what the two attempts
        // before this one did not have — the tip was a hair above the base's
        // lower corner, so a triangle that is geometrically fine read as an
        // arrow pointing steeply down out of the ring rather than round it.
        //
        // Level and *on the circle* at the same time takes a vertical base
        // standing behind the tip, not a radial one: with a radial base the tip
        // can be level or it can be on the circle, never both — solve
        // `sin(θ) = -1` and the tip lands on the base's own midpoint. So the
        // base is a vertical chord [length] behind the tip, which crosses the
        // ring rather than sitting on it, and the arc's ink stops at that
        // crossing so its round cap ends underneath the head.
        //
        // Every coordinate comes out of the angle and the radius, so the tip
        // cannot leave the ring the way a head built off the *tangent* does: at
        // this size that one sat 0.048 outside a radius of 0.30, a sixth of the
        // radius, and read exactly as an arrow that had come off its own path.
        const radius = 0.30;

        /// Where the tip sits, clockwise from twelve o'clock, in radians.
        ///
        /// One o'clock: far enough round that the head lies across the top
        /// right, which is the corner every refresh mark in every toolkit puts
        /// it in, and the one the eye reads as "and round again".
        const lead = 0.6;

        /// How far behind the tip the base stands, and half its height.
        ///
        /// The two are a shape rather than two sizes: 0.26 by 0.29 is an
        /// arrowhead, 0.26 by 0.20 is a dart and 0.15 by 0.29 is a wedge. The
        /// head is drawn at 16 px in the menu bar and nowhere else, so both are
        /// large — a matched pair much under this disappears at that size, and
        /// this one was twice measured against `Icons.refresh` in the same
        /// 24 px button.
        const length = 0.26;
        const half = 0.145;

        /// The opening left between the tip and where the ring resumes, so it
        /// reads as interrupted rather than closed. The head breaks most of it.
        const gap = 0.5;

        const stops = -math.pi / 2;
        const tipAngle = stops + lead;
        final tipX = math.cos(tipAngle) * radius;
        final tipY = math.sin(tipAngle) * radius;
        final baseX = tipX - length;

        // The upper crossing of the base's line with the circle. Negative y is
        // above the centre, which is the half the head is in.
        final endAngle = math.atan2(
          -math.sqrt(radius * radius - baseX * baseX),
          baseX,
        );

        canvas.drawArc(
          Rect.fromCircle(center: p(0.5, 0.5), radius: radius * s),
          tipAngle + gap,
          endAngle + 2 * math.pi - tipAngle - gap,
          false,
          stroke,
        );

        Offset at(double x, double y) => p(0.5 + x, 0.5 + y);
        canvas.drawPath(
          Path()
            ..moveTo(at(tipX, tipY).dx, at(tipX, tipY).dy)
            ..lineTo(at(baseX, tipY - half).dx, at(baseX, tipY - half).dy)
            ..lineTo(at(baseX, tipY + half).dx, at(baseX, tipY + half).dy)
            ..close(),
          fill,
        );
    }
  }

  /// A u-turn: a short tail along the bottom running right, a half turn up
  /// around the right, and a long shaft back to the left ending in a head.
  /// Undo points left because that is the direction history runs in; redo is
  /// the same path reflected, so the two can never drift apart.
  ///
  /// The mark is naturally wider than it is tall, so it fills the square's
  /// width and takes about two thirds of its height. [topY] and [bottomY] are
  /// *solved* rather than chosen, so that the head's point and the tail sit
  /// equally far from the middle of the box: a mark whose ink is off-centre
  /// inside its own bounds cannot be aligned with anything by centring it, and
  /// half a pixel out is the amount that reads as wrong without reading as
  /// broken.
  void _uturn(Canvas canvas, double s, Paint stroke, {required bool mirrored}) {
    const radius = 0.18;
    const barb = 0.20;
    const topY = (1 + barb - 2 * radius) / 2;
    const bottomY = (1 + barb + 2 * radius) / 2;
    const turnX = 0.74;
    const tipX = 0.08;

    if (mirrored) {
      canvas.save();
      canvas.translate(s, 0);
      canvas.scale(-1, 1);
    }

    canvas.drawPath(
      Path()
        ..moveTo((turnX - radius * 1.6) * s, bottomY * s)
        ..lineTo(turnX * s, bottomY * s)
        ..arcTo(
          Rect.fromCircle(
            center: Offset(turnX * s, (topY + bottomY) / 2 * s),
            radius: radius * s,
          ),
          math.pi / 2,
          -math.pi,
          false,
        )
        ..lineTo(tipX * s, topY * s)
        ..moveTo((tipX + barb) * s, (topY - barb) * s)
        ..lineTo(tipX * s, topY * s)
        ..lineTo((tipX + barb) * s, (topY + barb) * s),
      stroke,
    );

    if (mirrored) canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkPainter oldDelegate) =>
      oldDelegate.mark != mark || oldDelegate.color != color;
}
