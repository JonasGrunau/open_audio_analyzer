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
/// plain row it replaced. These eight earn their place by saying something the
/// text beside them does not —
///
/// - [broadcast] is a machine putting measurements on the network. It marks the
///   half of the remote panel that sends, and every host a search found.
/// - [display] is a screen showing somebody else's. It marks the half that
///   receives, and the two are otherwise a pair of near-identical text rows.
/// - [chevron] says a row opens something rather than selecting in place. A
///   `PanelListRow` is normally a choice among peers; a chevron is how the two
///   that push a panel say so before they are pressed.
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
/// Anything past these is a design decision to make here, not at a call site.
enum OaaMark {
  /// A source radiating: publishing, or a host that was found publishing.
  broadcast,

  /// A screen on a stand: this machine used as somebody else's display.
  display,

  /// This row opens something.
  chevron,

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
