// SPDX-License-Identifier: GPL-3.0-or-later
//
// Draws Open Audio Analyzer's mark at every size and in every shape the six
// platforms ask for.
//
// ---------------------------------------------------------------------------
// Why this is a program and not a folder of PNGs
//
// A pkg, a Windows installer, an AppImage, a flatpak, an iOS asset catalogue
// and an Android res tree each want the icon at a different set of sizes, in a
// different container, under a different filename — sixty-odd files in total.
// Exported by hand from a drawing they drift: somebody changes the mark,
// updates the four sizes they were looking at, and the icon in the Windows
// Start menu stays a year behind the one in the Dock. Generated, there is one
// description of the mark and everything else is a consequence.
//
// ---------------------------------------------------------------------------
// Where the artwork comes from, which is the opposite of what it used to be
//
// **`assets/brand/oaa-logo.svg` is the drawing, and this program reads it.**
// Until 0.10.0 the mark was four rounded rectangles whose numbers lived in a
// `_Mark` class here, and every vector twin in the repository was a hand-copied
// transcription of them that had to be brought across afterwards. That is
// backwards the moment the mark stops being four rectangles: a wave drawn in
// Inkscape has three hundred control points and nobody transcribes those.
//
// So the direction inverted. The Inkscape document is the master, this program
// parses the one path and the one gradient out of it, and everything else in
// the repository — including the other files in `assets/brand/` — is written
// from here. Nothing is copied by hand any more and there is no "bring it
// across afterwards" step left to forget. [_Art] is where the reading happens
// and what it insists on finding.
//
// ---------------------------------------------------------------------------
// Why there is a rasteriser here now, having promised there would not be
//
// The old header said there was no rasteriser because the shapes were
// rectangles, so "is this point inside" was four comparisons. A cubic path with
// a stroke on it is not that, and `package:image` is still not worth being the
// only dependency that exists for a build step and has to resolve on every
// release runner. What is actually needed is a scanline fill — flatten the
// cubics, intersect each subsample row, merge the intervals, accumulate
// coverage — which is the section below and is about a hundred and fifty lines.
//
// The stroke is unioned rather than offset. Offsetting a path correctly is a
// research problem; a stroke is exactly the union of a rectangle per segment
// and a disc per vertex, and this rasteriser works in intervals, where union is
// a sort. So the fill and the stroke are the same call and neither one has to
// know about the other.
//
// ---------------------------------------------------------------------------
// Why one mark is drawn in three shapes
//
// The desktop platforms want the artwork to *be* the rounded tile: it is what
// lands in the Dock, and the corners outside it have to be transparent or the
// icon has white notches on a dark shelf. Neither phone works that way, and
// each is wrong in its own direction, so the artwork takes three forms.
// [_Shape] names the two that are rasterised; Android's is a vector, built
// further down from the same path.
//
// iOS masks the icon itself, with its own curve — near enough to [_Tile.corner]
// now that both were measured off the same OS, but still its own — and it refuses
// an alpha channel outright — an icon with one
// is rejected on upload as ITMS-90717 rather than at build time. So its
// artwork is square, full bleed and written without an alpha channel at all.
// Rounding it here would round it twice, which shows as dark wedges in the
// four corners of every home screen.
//
// Android composites two layers and then masks them with whatever shape the
// launcher is set to — circle, squircle, teardrop — and reserves the outer
// 18dp of a 108dp canvas for the parallax it plays on scroll. Only the middle
// 72dp is guaranteed to survive. So its foreground is the wave alone on
// transparency, inset to that safe zone, over a background layer of its own.
// Both of its layers are VectorDrawables: nothing there needs a raster, and a
// vector cannot have the density somebody forgot to regenerate.
//
// ---------------------------------------------------------------------------
// Run:  dart run packaging/icon/make_icons.dart
//
// It writes into the platform directories, into `assets/brand/` and into
// `website/public/`, and the results are committed. A release runner does not
// run this.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// The drawing

/// The one file the artwork is drawn in.
///
/// An Inkscape document, edited by hand. Everything else this program touches
/// is derived from it, including the other three files beside it.
const String _source = 'assets/brand/oaa-logo.svg';

/// The mark and its ground, as read from [_source].
///
/// It insists on finding exactly one `<path>` and exactly one `<linearGradient>`
/// with stops, and says so loudly when it does not. That is deliberate: this
/// program is run by hand and its output is committed, so a parse that guessed
/// would commit sixty wrong files in silence, whereas a parse that stops is one
/// message and a re-export. Inkscape writes colours in a `style` attribute and
/// its "Optimised SVG" output writes them as presentation attributes, so both
/// spellings are accepted; anything else is a failure rather than a default.
class _Art {
  _Art({
    required this.canvas,
    required this.path,
    required this.strokeWidth,
    required this.stops,
  });

  /// The side of the square the drawing is laid out on — its `viewBox`.
  final double canvas;

  /// The wave, as it is written in the file. Kept verbatim so that every vector
  /// twin carries the artist's curves rather than this program's flattening of
  /// them.
  final String path;

  /// The stroke that fattens [path]. The drawing is a filled outline with a
  /// stroke of the same colour on it, so the visible ribbon is the union of the
  /// two; drawing the fill alone comes out visibly thin.
  final double strokeWidth;

  /// The ground, as (offset, colour) from the top of the canvas to the bottom.
  final List<(double, _Rgb)> stops;

  /// [path], flattened to polygons. Built once; every raster size reuses it,
  /// because the tolerance is in drawing units and 1024 px is the tightest
  /// anything here asks for.
  late final List<_Contour> contours = _flatten(path);

  static _Art read(String file) {
    final svg = File(file).readAsStringSync();

    double? viewBox;
    final vb = RegExp(r'viewBox="([^"]*)"').firstMatch(svg);
    if (vb != null) {
      final parts = vb.group(1)!.trim().split(RegExp(r'[\s,]+'));
      if (parts.length == 4) viewBox = double.parse(parts[3]);
    }
    if (viewBox == null) _fail('$file has no square viewBox');

    // Inkscape keeps hidden layers in the document — the logo file carries the
    // mark and the ground as separate objects, with the ones the export did not
    // want set to display:none. Those are the artist's working state, not
    // artwork, so anything hidden is skipped rather than drawn.
    final visible = RegExp(r'<path\b([^>]*?)/?>', dotAll: true)
        .allMatches(svg)
        .map((m) => m.group(1)!)
        .where((a) => !RegExp(r'display\s*:\s*none').hasMatch(a))
        .toList();
    if (visible.length != 1) {
      _fail(
        '$file has ${visible.length} visible <path> elements, expected 1. '
        'The mark is one path; hide or flatten the rest before exporting.',
      );
    }
    final attrs = visible.single;

    final d = RegExp(r'\sd="([^"]*)"').firstMatch(attrs);
    if (d == null) _fail('$file: the visible path has no d attribute');

    // No stroke is legitimate — a path that is already an outline needs none —
    // so an absent width is zero rather than an error. A present one that does
    // not parse is an error.
    var stroke = 0.0;
    final sw =
        RegExp(r'stroke-width\s*:\s*([0-9.eE+-]+)').firstMatch(attrs) ??
        RegExp(r'\sstroke-width="([0-9.eE+-]+)"').firstMatch(attrs);
    if (sw != null && !RegExp(r'stroke\s*:\s*none').hasMatch(attrs)) {
      stroke = double.parse(sw.group(1)!);
    }

    final stops = <(double, _Rgb)>[];
    for (final m in RegExp(
      r'<stop\b([^>]*?)/?>',
      dotAll: true,
    ).allMatches(svg)) {
      final a = m.group(1)!;
      final offset = RegExp(r'offset="([0-9.eE+-]+)"').firstMatch(a);
      final colour =
          RegExp(r'stop-color\s*:\s*#([0-9a-fA-F]{6})').firstMatch(a) ??
          RegExp(r'stop-color="#([0-9a-fA-F]{6})"').firstMatch(a);
      if (offset == null || colour == null) continue;
      stops.add((double.parse(offset.group(1)!), _Rgb.hex(colour.group(1)!)));
    }
    if (stops.length < 2) {
      _fail('$file has ${stops.length} gradient stops, expected at least 2');
    }
    stops.sort((a, b) => a.$1.compareTo(b.$1));

    return _Art(
      canvas: viewBox,
      path: d.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim(),
      strokeWidth: stroke,
      stops: stops,
    );
  }

  /// The ground at [t], a fraction of the way down the canvas.
  ///
  /// The gradient in the drawing runs top to bottom; this program assumes that
  /// rather than reading `x1`/`y1`/`x2`/`y2`, because every consumer below —
  /// Android's `<gradient>`, Apple's layer, the SVG twins — has to be told the
  /// direction as well, and a direction that is read in one place and written
  /// out in four is four chances to write it differently. A drawing whose ramp
  /// runs some other way is a change to this function and to those four.
  _Rgb groundAt(double t) {
    t = t.clamp(0.0, 1.0);
    for (var i = 0; i + 1 < stops.length; i++) {
      final (a, ca) = stops[i];
      final (b, cb) = stops[i + 1];
      if (t <= b) {
        final u = b > a ? (t - a) / (b - a) : 0.0;
        return _Rgb(
          (ca.r + (cb.r - ca.r) * u).round(),
          (ca.g + (cb.g - ca.g) * u).round(),
          (ca.b + (cb.b - ca.b) * u).round(),
        );
      }
    }
    return stops.last.$2;
  }
}

Never _fail(String message) {
  stderr.writeln('make_icons: $message');
  exit(1);
}

late final _Art _art;

/// The tile the desktop platforms are handed.
abstract final class _Tile {
  /// Corner radius, as a fraction of the side, and the exponent of the corner
  /// curve in `(dx/r)^n + (dy/r)^n = 1`.
  ///
  /// **These two were measured off this machine, not looked up.** macOS 26 and
  /// iOS 26 draw a rounder tile than every version before them, and the number
  /// everybody remembers — a corner of 22.37% on a curve of about 4, the shape
  /// iOS 7 introduced and iOS 18 still drew — now produces an icon that is
  /// visibly squarer than the ones beside it in the Dock. That is what this file
  /// shipped first and what a reader spotted on sight.
  ///
  /// What is here instead came from rendering three system icons through
  /// `NSWorkspace.icon(forFile:)` at 1024 px, taking the alpha silhouette, and
  /// fitting the two numbers to it. Calculator, Notes and Maps agree exactly:
  /// a body of 824 px in a 1024 canvas, a corner of 33.74% of that body, and an
  /// exponent of 2.74, to a root-mean-square residual of half a pixel. A third
  /// and 2.7 fit the same silhouette just as closely — 0.51 px against 0.50 —
  /// and are numbers a person can hold, so they are the ones written down.
  ///
  /// Redo the measurement rather than trusting this after an OS release: Apple
  /// has now changed the shape twice. Render an icon, threshold the alpha, fit.
  /// Safari is the one to avoid — it is a circle, not a tile, and it does not
  /// fit because it is not supposed to.
  static const double corner = 1 / 3;
  static const double squircle = 2.7;

  /// Android reserves the outer 18dp of a 108dp adaptive canvas, so only the
  /// middle 72 is certain to be drawn. The whole drawing is scaled into that
  /// square, which is what makes the adaptive icon and the desktop tile look
  /// like one icon after two different masks.
  static const double adaptiveSafe = 72 / 108;

  /// The thinnest the mark's stroke is allowed to get, in device pixels.
  ///
  /// The drawing's stroke is 1.4% of the canvas, so below about 73 px it is
  /// thinner than a pixel and antialiases to a grey smear — at 16 px the wave
  /// stopped being white at all. Holding it at one pixel keeps it white and
  /// keeps the excursions distinguishable down to about 24 px.
  ///
  /// **It does not make the mark survive 16 px.** The four bars it replaced
  /// did: they were two pixels wide with a one-pixel cap and still read as four
  /// bars at four heights. A wave with nine excursions across twelve pixels
  /// cannot, at any stroke width — thickening it past this closes the gaps and
  /// makes a blob. At 16 px what the icon has is the ground and a silhouette,
  /// and the sizes that decide it now are 32 and up.
  static const double strokeFloorPx = 1.0;
}

/// The two shapes the artwork is rasterised in, depending on who masks it.
///
/// Android's third shape — the wave alone, inset into its 72-of-108 safe zone —
/// is a VectorDrawable rather than a PNG, so it is not one of these.
enum _Shape {
  /// The rounded tile itself, with transparent corners. macOS, Windows, Linux,
  /// Android's pre-adaptive launcher, and the README.
  tile,

  /// Square, full bleed, every pixel opaque, written without an alpha channel.
  /// The Play Store's icon, which the console rounds in its own interface.
  /// Apple's platforms want the same thing and get it from the layered
  /// document instead, which `actool` flattens for them.
  bleed,
}

// ---------------------------------------------------------------------------
// Paths
//
// Enough of the `d` grammar to read what a drawing program writes, and no more:
// moveto, lineto, the two axis-aligned shorthands, cubics with their smooth
// form, quadratics with theirs, and closepath. Arcs are not here. Inkscape
// writes them for a rounded rectangle, so the day a drawing has one this stops
// with a message naming the command rather than dropping a corner silently.

/// A closed polyline. The flattened form of one subpath.
class _Contour {
  final List<double> xs = [];
  final List<double> ys = [];

  int get length => xs.length;

  void add(double x, double y) {
    if (xs.isNotEmpty &&
        (xs.last - x).abs() < 1e-9 &&
        (ys.last - y).abs() < 1e-9) {
      return;
    }
    xs.add(x);
    ys.add(y);
  }
}

final RegExp _pathToken = RegExp(
  r'[MmLlHhVvCcSsQqTtAaZz]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?',
);

/// [d] flattened into polygons, to a tolerance in drawing units.
List<_Contour> _flatten(String d) {
  final tokens = _pathToken.allMatches(d).map((m) => m.group(0)!).toList();
  final contours = <_Contour>[];
  _Contour? cur;
  var x = 0.0, y = 0.0, sx = 0.0, sy = 0.0;
  double? cx, cy; // the previous cubic's second control, for S
  double? qx, qy; // the previous quadratic's control, for T
  var i = 0;
  var cmd = '';

  double next() => double.parse(tokens[i++]);

  _Contour open() {
    final c = _Contour();
    contours.add(c);
    c.add(x, y);
    return c;
  }

  void cubic(double x1, double y1, double x2, double y2, double x3, double y3) {
    _flattenCubic(cur ??= open(), x, y, x1, y1, x2, y2, x3, y3, 0);
    cx = x2;
    cy = y2;
    qx = null;
    x = x3;
    y = y3;
  }

  void quad(double x1, double y1, double x2, double y2) {
    // A quadratic is a cubic whose controls are two thirds of the way to it.
    cubic(
      x + 2 / 3 * (x1 - x),
      y + 2 / 3 * (y1 - y),
      x2 + 2 / 3 * (x1 - x2),
      y2 + 2 / 3 * (y1 - y2),
      x2,
      y2,
    );
    qx = x1;
    qy = y1;
    cx = null;
  }

  while (i < tokens.length) {
    final t = tokens[i];
    if (t.length == 1 && RegExp(r'[A-Za-z]').hasMatch(t)) {
      cmd = t;
      i++;
      if (i >= tokens.length && cmd.toUpperCase() != 'Z') break;
    } else if (cmd == 'M') {
      // A moveto with more than one pair is a moveto and then linetos.
      cmd = 'L';
    } else if (cmd == 'm') {
      cmd = 'l';
    }

    switch (cmd) {
      case 'M':
      case 'm':
        final nx = next(), ny = next();
        x = cmd == 'M' ? nx : x + nx;
        y = cmd == 'M' ? ny : y + ny;
        sx = x;
        sy = y;
        cur = open();
        cx = qx = null;
      case 'L':
      case 'l':
        final nx = next(), ny = next();
        x = cmd == 'L' ? nx : x + nx;
        y = cmd == 'L' ? ny : y + ny;
        (cur ??= open()).add(x, y);
        cx = qx = null;
      case 'H':
      case 'h':
        final nx = next();
        x = cmd == 'H' ? nx : x + nx;
        (cur ??= open()).add(x, y);
        cx = qx = null;
      case 'V':
      case 'v':
        final ny = next();
        y = cmd == 'V' ? ny : y + ny;
        (cur ??= open()).add(x, y);
        cx = qx = null;
      case 'C':
      case 'c':
        final bx = cmd == 'c' ? x : 0.0, by = cmd == 'c' ? y : 0.0;
        final x1 = bx + next(), y1 = by + next();
        final x2 = bx + next(), y2 = by + next();
        cubic(x1, y1, x2, y2, bx + next(), by + next());
      case 'S':
      case 's':
        final bx = cmd == 's' ? x : 0.0, by = cmd == 's' ? y : 0.0;
        final x1 = cx == null ? x : 2 * x - cx!;
        final y1 = cy == null ? y : 2 * y - cy!;
        final x2 = bx + next(), y2 = by + next();
        cubic(x1, y1, x2, y2, bx + next(), by + next());
      case 'Q':
      case 'q':
        final bx = cmd == 'q' ? x : 0.0, by = cmd == 'q' ? y : 0.0;
        final x1 = bx + next(), y1 = by + next();
        quad(x1, y1, bx + next(), by + next());
      case 'T':
      case 't':
        final bx = cmd == 't' ? x : 0.0, by = cmd == 't' ? y : 0.0;
        final x1 = qx == null ? x : 2 * x - qx!;
        final y1 = qy == null ? y : 2 * y - qy!;
        quad(x1, y1, bx + next(), by + next());
      case 'Z':
      case 'z':
        cur?.add(sx, sy);
        x = sx;
        y = sy;
        cur = null;
        cx = qx = null;
      default:
        _fail('$_source: unsupported path command "$cmd"');
    }
  }
  return contours;
}

/// Tolerance of the flattening, squared, in drawing units. The drawing is 500
/// units across and the largest raster is 1024 px, so a twentieth of a unit is
/// a tenth of a pixel at the size that matters most.
const double _flatness = 0.05;

void _flattenCubic(
  _Contour out,
  double x0,
  double y0,
  double x1,
  double y1,
  double x2,
  double y2,
  double x3,
  double y3,
  int depth,
) {
  // De Casteljau, subdividing until both controls are near the chord. The depth
  // cap is a backstop for a degenerate curve whose chord has no length.
  final dx = x3 - x0, dy = y3 - y0;
  final d1 = ((x1 - x3) * dy - (y1 - y3) * dx).abs();
  final d2 = ((x2 - x3) * dy - (y2 - y3) * dx).abs();
  final dd = d1 + d2;
  if (depth >= 16 || dd * dd <= _flatness * (dx * dx + dy * dy)) {
    out.add(x3, y3);
    return;
  }
  final x01 = (x0 + x1) / 2, y01 = (y0 + y1) / 2;
  final x12 = (x1 + x2) / 2, y12 = (y1 + y2) / 2;
  final x23 = (x2 + x3) / 2, y23 = (y2 + y3) / 2;
  final xa = (x01 + x12) / 2, ya = (y01 + y12) / 2;
  final xb = (x12 + x23) / 2, yb = (y12 + y23) / 2;
  final xm = (xa + xb) / 2, ym = (ya + yb) / 2;
  _flattenCubic(out, x0, y0, x01, y01, xa, ya, xm, ym, depth + 1);
  _flattenCubic(out, xm, ym, xb, yb, x23, y23, x3, y3, depth + 1);
}

// ---------------------------------------------------------------------------
// The rasteriser
//
// One scanline at a time, in intervals. Every shape here answers the same
// question — which stretches of this row are inside you — and the answers are
// merged, so a fill and a stroke and a tile are the same kind of thing and
// union is a sort. Coverage is exact horizontally and sampled [_subsamples]
// times vertically, which for shapes made of long smooth curves is a better
// use of the same work than sampling both ways.

/// A half-open stretch of one scanline.
class _Span {
  _Span(this.a, this.b);
  double a, b;
}

const int _subsamples = 8;

/// The stretches of row [y] inside [contours], by nonzero winding.
void _fillSpans(List<_Contour> contours, double y, List<_Span> out) {
  final xs = <double>[];
  final dir = <int>[];
  for (final c in contours) {
    for (var i = 0; i + 1 < c.length; i++) {
      final y0 = c.ys[i], y1 = c.ys[i + 1];
      if (y0 == y1) continue;
      // Half-open in y, so a vertex shared by two edges is counted once.
      if ((y >= y0 && y < y1) || (y >= y1 && y < y0)) {
        final t = (y - y0) / (y1 - y0);
        xs.add(c.xs[i] + t * (c.xs[i + 1] - c.xs[i]));
        dir.add(y1 > y0 ? 1 : -1);
      }
    }
  }
  if (xs.isEmpty) return;

  final order = List<int>.generate(xs.length, (i) => i)
    ..sort((a, b) => xs[a].compareTo(xs[b]));
  var winding = 0;
  var start = 0.0;
  for (final i in order) {
    final was = winding;
    winding += dir[i];
    if (was == 0 && winding != 0) {
      start = xs[i];
    } else if (was != 0 && winding == 0) {
      out.add(_Span(start, xs[i]));
    }
  }
}

/// The stretches of row [y] under a round-joined stroke of [width] on
/// [contours].
///
/// A rectangle per segment and a disc per vertex. Their union is the stroke
/// exactly — this is what a stroker computes the outline of, and computing that
/// outline is only necessary if the answer has to be a path. Here it does not.
void _strokeSpans(
  List<_Contour> contours,
  double width,
  double y,
  List<_Span> out,
) {
  if (width <= 0) return;
  final r = width / 2;
  for (final c in contours) {
    for (var i = 0; i < c.length; i++) {
      final dy = y - c.ys[i];
      if (dy.abs() < r) {
        final half = math.sqrt(r * r - dy * dy);
        out.add(_Span(c.xs[i] - half, c.xs[i] + half));
      }
      if (i + 1 >= c.length) continue;
      final ax = c.xs[i], ay = c.ys[i];
      final bx = c.xs[i + 1], by = c.ys[i + 1];
      final ex = bx - ax, ey = by - ay;
      final len = math.sqrt(ex * ex + ey * ey);
      if (len < 1e-12) continue;
      final nx = -ey / len * r, ny = ex / len * r;
      _quadSpan(
        ax + nx,
        ay + ny,
        bx + nx,
        by + ny,
        bx - nx,
        by - ny,
        ax - nx,
        ay - ny,
        y,
        out,
      );
    }
  }
}

/// One span from a convex quadrilateral: the leftmost and rightmost crossings.
void _quadSpan(
  double x0,
  double y0,
  double x1,
  double y1,
  double x2,
  double y2,
  double x3,
  double y3,
  double y,
  List<_Span> out,
) {
  final px = [x0, x1, x2, x3];
  final py = [y0, y1, y2, y3];
  var lo = double.infinity, hi = double.negativeInfinity;
  for (var i = 0; i < 4; i++) {
    final j = (i + 1) & 3;
    final a = py[i], b = py[j];
    if (a == b) continue;
    if ((y >= a && y < b) || (y >= b && y < a)) {
      final x = px[i] + (y - a) / (b - a) * (px[j] - px[i]);
      if (x < lo) lo = x;
      if (x > hi) hi = x;
    }
  }
  if (lo < hi) out.add(_Span(lo, hi));
}

/// [spans] sorted and overlaps collapsed, in place.
List<_Span> _union(List<_Span> spans) {
  if (spans.isEmpty) return spans;
  spans.sort((a, b) => a.a.compareTo(b.a));
  final out = <_Span>[spans.first];
  for (var i = 1; i < spans.length; i++) {
    final last = out.last;
    if (spans[i].a <= last.b) {
      if (spans[i].b > last.b) last.b = spans[i].b;
    } else {
      out.add(spans[i]);
    }
  }
  return out;
}

/// Adds the coverage of [spans], in pixels, into [row] at weight [weight].
void _accumulate(Float64List row, List<_Span> spans, double weight) {
  for (final s in spans) {
    var a = s.a, b = s.b;
    if (b <= 0 || a >= row.length) continue;
    if (a < 0) a = 0;
    if (b > row.length) b = row.length.toDouble();
    for (var i = a.floor(); i < b; i++) {
      final lo = math.max(a, i.toDouble());
      final hi = math.min(b, i + 1.0);
      if (hi > lo) row[i] += (hi - lo) * weight;
    }
  }
}

/// Coverage of the mark, at [size] px, with the drawing scaled by [scale] and
/// its origin at [offset] px.
Float64List _markCoverage(int size, double scale, double offset) {
  // The stroke is widened in drawing units so that it never falls below
  // [_Tile.strokeFloorPx] on screen. See that constant.
  final width = math.max(_art.strokeWidth, _Tile.strokeFloorPx / scale);
  final cov = Float64List(size * size);
  final row = Float64List(size);
  final spans = <_Span>[];

  for (var py = 0; py < size; py++) {
    row.fillRange(0, size, 0);
    for (var s = 0; s < _subsamples; s++) {
      final y = (py + (s + 0.5) / _subsamples - offset) / scale;
      spans.clear();
      _fillSpans(_art.contours, y, spans);
      _strokeSpans(_art.contours, width, y, spans);
      final merged = _union(spans.toList());
      for (final m in merged) {
        m.a = m.a * scale + offset;
        m.b = m.b * scale + offset;
      }
      _accumulate(row, merged, 1 / _subsamples);
    }
    for (var px = 0; px < size; px++) {
      cov[py * size + px] = row[px].clamp(0.0, 1.0);
    }
  }
  return cov;
}

/// Coverage of the tile: a square of side [size] with superelliptical corners.
///
/// Analytic, because the shape is `(dx/r)^n + (dy/r)^n = 1` and a row of it is
/// one interval. No polygon, no sampling in x.
Float64List _tileCoverage(int size) {
  final r = _Tile.corner;
  final n = _Tile.squircle;
  final cov = Float64List(size * size);
  final row = Float64List(size);

  for (var py = 0; py < size; py++) {
    row.fillRange(0, size, 0);
    for (var s = 0; s < _subsamples; s++) {
      final y = (py + (s + 0.5) / _subsamples) / size;
      final dy = y < r ? (r - y) / r : (y > 1 - r ? (y - (1 - r)) / r : 0.0);
      if (dy >= 1) continue;
      final k = math.pow(1 - math.pow(dy, n), 1 / n) as double;
      _accumulate(row, [
        _Span((r - k * r) * size, (1 - r + k * r) * size),
      ], 1 / _subsamples);
    }
    for (var px = 0; px < size; px++) {
      cov[py * size + px] = row[px].clamp(0.0, 1.0);
    }
  }
  return cov;
}

/// The mark at [size] px, as straight RGBA.
///
/// The ground is a vertical ramp, so it is one colour per row. The mark is
/// composited over it in straight alpha and the tile's coverage becomes the
/// alpha of the result, so the corners come out transparent rather than painted
/// onto an assumed white — an icon with baked-in corners is an icon with white
/// notches on a dark dock — and the colour under a partly covered edge pixel is
/// the full ground colour rather than a blend with it, which is what would show
/// as a dark fringe against anything pale.
Uint8List _render(int size, _Shape shape) {
  final mark = _markCoverage(size, size / _art.canvas, 0);
  final tile = shape == _Shape.tile ? _tileCoverage(size) : null;
  final pixels = Uint8List(size * size * 4);

  for (var py = 0; py < size; py++) {
    final ground = _art.groundAt((py + 0.5) / size);
    for (var px = 0; px < size; px++) {
      final i = py * size + px;
      final m = mark[i];
      final o = i * 4;
      pixels[o] = (ground.r + (255 - ground.r) * m).round();
      pixels[o + 1] = (ground.g + (255 - ground.g) * m).round();
      pixels[o + 2] = (ground.b + (255 - ground.b) * m).round();
      pixels[o + 3] = tile == null ? 255 : (tile[i] * 255).round();
    }
  }
  return pixels;
}

class _Rgb {
  const _Rgb(this.r, this.g, this.b);

  factory _Rgb.hex(String six) => _Rgb(
    int.parse(six.substring(0, 2), radix: 16),
    int.parse(six.substring(2, 4), radix: 16),
    int.parse(six.substring(4, 6), radix: 16),
  );

  final int r, g, b;
}

// ---------------------------------------------------------------------------
// PNG

/// A PNG of [size] x [size] straight RGBA pixels.
///
/// With [opaque] the alpha channel is dropped and the file is written as plain
/// RGB. That is not an optimisation: iOS rejects an app icon that *has* an
/// alpha channel, whatever is in it, and does so on upload with ITMS-90717
/// rather than at build time — so an icon that is fully opaque but still four
/// channels wide passes every check on this machine and fails the one that
/// happens months later in front of the store.
Uint8List _png(int size, Uint8List rgba, {bool opaque = false}) {
  final channels = opaque ? 3 : 4;
  final stride = size * channels;
  final raw = Uint8List((stride + 1) * size);

  for (var y = 0; y < size; y++) {
    final line = y * (stride + 1);
    raw[line] = 0; // filter: none
    for (var x = 0; x < size; x++) {
      final src = (y * size + x) * 4;
      final dst = line + 1 + x * channels;
      raw[dst] = rgba[src];
      raw[dst + 1] = rgba[src + 1];
      raw[dst + 2] = rgba[src + 2];
      if (!opaque) raw[dst + 3] = rgba[src + 3];
    }
  }

  final ihdr = BytesBuilder()
    ..add(_be32(size))
    ..add(_be32(size))
    ..addByte(8) // bit depth
    ..addByte(opaque ? 2 : 6) // colour type: RGB or RGBA
    ..addByte(0) // deflate
    ..addByte(0) // adaptive filtering
    ..addByte(0); // no interlace

  return (BytesBuilder()
        ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ..add(_chunk('IHDR', ihdr.takeBytes()))
        ..add(_chunk('IDAT', ZLibCodec(level: 9).encode(raw)))
        ..add(_chunk('IEND', const [])))
      .takeBytes();
}

Uint8List _chunk(String type, List<int> data) {
  final body = <int>[...ascii.encode(type), ...data];
  return (BytesBuilder()
        ..add(_be32(data.length))
        ..add(body)
        ..add(_be32(_crc32(body))))
      .takeBytes();
}

Uint8List _be32(int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

// ---------------------------------------------------------------------------
// ICO

/// A Windows .ico holding one PNG per size.
///
/// PNG-compressed entries rather than the old BMP-with-AND-mask form: every
/// Windows since Vista reads them, and the BMP form needs an inverted mask
/// plane that is a classic source of icons with black corners.
Uint8List _ico(Map<int, Uint8List> pngsBySize) {
  final sizes = pngsBySize.keys.toList()..sort();
  final header = BytesBuilder()
    ..add(_le16(0)) // reserved
    ..add(_le16(1)) // type: icon
    ..add(_le16(sizes.length));

  var offset = 6 + sizes.length * 16;
  final directory = BytesBuilder();
  for (final size in sizes) {
    final png = pngsBySize[size]!;
    directory
      ..addByte(size >= 256 ? 0 : size) // 0 means 256
      ..addByte(size >= 256 ? 0 : size)
      ..addByte(0) // palette
      ..addByte(0) // reserved
      ..add(_le16(1)) // colour planes
      ..add(_le16(32)) // bits per pixel
      ..add(_le32(png.length))
      ..add(_le32(offset));
    offset += png.length;
  }

  final out = BytesBuilder()
    ..add(header.takeBytes())
    ..add(directory.takeBytes());
  for (final size in sizes) {
    out.add(pngsBySize[size]!);
  }
  return out.takeBytes();
}

Uint8List _le16(int value) =>
    Uint8List.fromList([value & 0xFF, (value >> 8) & 0xFF]);

Uint8List _le32(int value) => Uint8List.fromList([
  value & 0xFF,
  (value >> 8) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 24) & 0xFF,
]);

// ---------------------------------------------------------------------------

final Map<String, Uint8List> _cache = {};

/// A PNG of the mark at [size], drawn in [shape]. Cached, because the desktop
/// sets overlap heavily and a 1024 render is the slow part of this program.
Uint8List _pngOf(int size, [_Shape shape = _Shape.tile]) =>
    _cache['$size.${shape.name}'] ??= _png(
      size,
      _render(size, shape),
      opaque: shape == _Shape.bleed,
    );

void _write(String path, List<int> bytes) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
  stdout.writeln('  ${bytes.length.toString().padLeft(7)}  $path');
}

void _delete(String path) {
  final file = File(path);
  if (!file.existsSync()) return;
  file.deleteSync();
  stdout.writeln('  ${'removed'.padLeft(7)}  $path');
}

void main() {
  _art = _Art.read(_source);
  stdout.writeln(
    'Open Audio Analyzer icons, from $_source '
    '(${_art.canvas.toStringAsFixed(0)} units, '
    '${_art.contours.length} contour(s), '
    '${_art.stops.length} stops)',
  );

  // The other three files in `assets/brand/`, so that the mark on its own and
  // the ground on its own cannot disagree with the drawing they came from.
  _write('assets/brand/oaa-mark.svg', utf8.encode(_brandMark()));
  _write('assets/brand/oaa-logo-background.svg', utf8.encode(_brandGround()));
  _write('assets/brand/oaa-icon.svg', utf8.encode(_iconSvg()));

  // The app icon as an image, for the README and anywhere else the project is
  // shown. The tile's corners are transparent, which is the whole point: it is
  // an app icon rather than a teal square, and it sits on GitHub's page in
  // either theme without a rectangle around it.
  _write('assets/brand/oaa-icon.png', _pngOf(512));

  // `packaging/icon/oaa.svg` was the one hand-maintained duplicate in this
  // repository and is now written from the same path as everything else.
  _write('packaging/icon/oaa.svg', utf8.encode(_iconSvg()));

  // The two Apple platforms take one layered document each instead of a set of
  // flat PNGs, and `actool` renders every size from it — including the flat
  // ones an older macOS or iOS still wants. See the Apple section below.
  _writeAppleIcon('macos/Runner');
  _writeAppleIcon('ios/Runner');

  // Windows: the runner's icon resource, which Inno Setup also uses as the
  // installer's own icon. The msix logos were generated here until the Inno
  // installer replaced that package — an msix cannot write the shared VST3
  // directory, so it could never have carried the plug-in.
  _write(
    'windows/runner/resources/app_icon.ico',
    _ico({
      for (final size in [16, 32, 48, 64, 128, 256]) size: _pngOf(size),
    }),
  );

  // Linux: hicolor sizes for the flatpak, and the one the AppImage puts at the
  // root of its AppDir.
  for (final size in [16, 32, 48, 64, 128, 256, 512]) {
    _write(
      'packaging/linux/icons/${size}x$size/com.openaudioanalyzer.oaa.png',
      _pngOf(size),
    );
  }

  // Android, twice over.
  //
  // The PNGs are the legacy launcher icon, for anything below API 26, and they
  // are the tile — nothing masks them, so the artwork has to be the shape.
  const android = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
  };
  for (final entry in android.entries) {
    _write(
      'android/app/src/main/res/${entry.key}/ic_launcher.png',
      _pngOf(entry.value),
    );
  }

  // API 26 and up take the adaptive icon instead, and pick it automatically:
  // `anydpi-v26` outranks every density directory on a new enough launcher, so
  // the manifest keeps pointing at @mipmap/ic_launcher and needs no edit.
  _write(
    'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml',
    utf8.encode(_adaptiveIcon()),
  );

  // Both of the layers under it are vectors on a 108dp canvas: nothing about
  // the drawing needs a raster, and a vector has no density for somebody to
  // forget to regenerate. The foreground and the monochrome layer are now the
  // same drawable — see [_androidWave].
  final wave = utf8.encode(_androidWave());
  _write('android/app/src/main/res/drawable/ic_launcher_foreground.xml', wave);
  _write('android/app/src/main/res/drawable/ic_launcher_monochrome.xml', wave);
  _write(
    'android/app/src/main/res/drawable/ic_launcher_background.xml',
    utf8.encode(_androidGround()),
  );

  // The Play Console asks for this one by hand at upload time; it is not built
  // into the aab. Full bleed, because the store rounds it in its own UI.
  _write('packaging/android/play_store_icon.png', _pngOf(512, _Shape.bleed));

  // open-audio-analyzer.com. Nothing in `ci.yml` builds the site, so these were
  // copied across by hand and were the next thing certain to go stale.
  _write('website/public/oaa.svg', utf8.encode(_iconSvg()));
  _write('website/public/favicon.svg', utf8.encode(_iconSvg()));
  // `apple-touch-icon` is full bleed for the same reason the app icon on that
  // platform is: iOS rounds a web clip with its own curve, so one drawn here
  // would be rounded twice and show the page behind it in the four corners.
  _write('website/public/icon-180.png', _pngOf(180, _Shape.bleed));

  // The four-bar mark's layer, which was called `bars`. Left behind, `actool`
  // would carry an asset no `icon.json` names.
  for (final dir in ['macos/Runner', 'ios/Runner']) {
    _delete('$dir/AppIcon.icon/Assets/bars.svg');
  }

  stdout.writeln('Done. Every file above is written from $_source.');
}

// ---------------------------------------------------------------------------
// Writing vectors
//
// Four consumers want the artwork as a vector — Android's two layers, Apple's
// two, the SVG twins and the favicon — and they differ only in the element the
// geometry hangs on. So the pieces are built once here and formatted several
// times below. Two emitters that each walked the drawing separately would be
// two chances to walk it differently, which is the whole failure this program
// exists to prevent.

String _hex(_Rgb c) =>
    '#${c.r.toRadixString(16).padLeft(2, '0')}'
            '${c.g.toRadixString(16).padLeft(2, '0')}'
            '${c.b.toRadixString(16).padLeft(2, '0')}'
        .toUpperCase();

/// A number with no more precision than the canvas can use, and no trailing
/// zeroes. Path data is inlined into a favicon's data URI on every page of the
/// documentation site, where a character costs three.
String _n(double v) {
  var s = v.toStringAsFixed(3);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return s == '-0' ? '0' : s;
}

/// The tile's outline as path data on a square of side [side].
///
/// Straight edges with a quarter superellipse at each corner. The corner has no
/// exact Bézier form, so each one is fitted through points on the true curve
/// with the end tangents clamped to the edges it meets — which makes the joins
/// exactly tangent, so the outline has no visible kink at any size.
///
/// The rasterised icons do not go through this: [_tileCoverage] evaluates the
/// real curve, because a scanline of it is one interval and there is nothing to
/// approximate. This is for the consumers that want a path, and it is only ever
/// shown at 512 px and below.
String _tilePath(double side) {
  final r = _Tile.corner * side;
  final n = _Tile.squircle;

  // One corner, from the point where it leaves an edge to where it meets the
  // next, as (x, y) offsets from the corner of the bounding box.
  //
  // Six cubics per corner. The residual against the true curve is 0.07% of the
  // side — an eighth of a pixel at 180 px, which is the largest any consumer of
  // this path draws it. Three cubics is 0.29%; eight is 0.04% and 350 bytes
  // more, and the documentation site inlines this on every page.
  const pieces = 6;
  final pts = <(double, double)>[
    for (var i = 0; i <= pieces; i++)
      (
        r - r * math.pow(math.cos(i / pieces * math.pi / 2), 2 / n).toDouble(),
        r - r * math.pow(math.sin(i / pieces * math.pi / 2), 2 / n).toDouble(),
      ),
  ];
  final out = StringBuffer();

  /// Emits one corner, mapped by [place] from the top-left corner's frame into
  /// this corner's, and entered at the point [place] gives for `pts.first`.
  void corner((double, double) Function(double, double) place) {
    // Hermite tangents: chord-length at the ends, Catmull-Rom in between, so
    // the first and last segments leave along the straight edges they touch.
    final p = [for (final q in pts) place(q.$1, q.$2)];
    final m = <(double, double)>[];
    for (var i = 0; i < p.length; i++) {
      if (i == 0) {
        final d = _dist(p[0], p[1]);
        final u = _unit(_sub(p[1], p[0]));
        // Leaving the edge: the tangent is the edge's own direction.
        m.add(_scale(_axis(u), d));
      } else if (i == p.length - 1) {
        final d = _dist(p[i - 1], p[i]);
        final u = _unit(_sub(p[i], p[i - 1]));
        m.add(_scale(_axis(u), d));
      } else {
        m.add(_scale(_sub(p[i + 1], p[i - 1]), 0.5));
      }
    }
    for (var i = 0; i + 1 < p.length; i++) {
      final c1 = _add(p[i], _scale(m[i], 1 / 3));
      final c2 = _sub(p[i + 1], _scale(m[i + 1], 1 / 3));
      out.write(
        'C${_n(c1.$1)},${_n(c1.$2)} ${_n(c2.$1)},${_n(c2.$2)} '
        '${_n(p[i + 1].$1)},${_n(p[i + 1].$2)}',
      );
    }
  }

  // Clockwise from the top left, starting where the left edge ends.
  out.write('M0,${_n(r)}');
  corner((x, y) => (x, y)); // top left
  out.write('H${_n(side - r)}');
  corner((x, y) => (side - y, x)); // top right
  out.write('V${_n(side - r)}');
  corner((x, y) => (side - x, side - y)); // bottom right
  out.write('H${_n(r)}');
  corner((x, y) => (y, side - x)); // bottom left
  out.write('Z');
  return out.toString();
}

(double, double) _add((double, double) a, (double, double) b) =>
    (a.$1 + b.$1, a.$2 + b.$2);
(double, double) _sub((double, double) a, (double, double) b) =>
    (a.$1 - b.$1, a.$2 - b.$2);
(double, double) _scale((double, double) a, double k) => (a.$1 * k, a.$2 * k);
double _dist((double, double) a, (double, double) b) =>
    math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2));
(double, double) _unit((double, double) a) {
  final len = math.sqrt(a.$1 * a.$1 + a.$2 * a.$2);
  return len < 1e-12 ? (0.0, 0.0) : (a.$1 / len, a.$2 / len);
}

/// The nearer axis to [u]. A corner's first and last tangent is the direction
/// of the straight edge it joins, and that edge is always axis-aligned.
(double, double) _axis((double, double) u) =>
    u.$1.abs() >= u.$2.abs() ? (u.$1.sign, 0.0) : (0.0, u.$2.sign);

/// The drawing's path, moved onto a canvas of side [side] and inset so that the
/// whole drawing occupies [fraction] of it, centred.
String _wavePath(double side, {double fraction = 1.0}) {
  final k = side / _art.canvas * fraction;
  final t = side * (1 - fraction) / 2;
  return _transformPath(_art.path, k, t);
}

/// [d] with every coordinate scaled by [k] and translated by [t].
///
/// The path is rewritten rather than wrapped in a `transform`, because a
/// VectorDrawable's `pathData` takes no transform of its own and a `<group>`
/// around it would be a second place the number lives.
///
/// The canvas is square and the inset is the same on every side, so x and y
/// take the same scale and the same offset and no coordinate has to be told
/// which axis it is on. Two things are not that forgiving:
///
///  * A *relative* command takes the scale and no translation, because a
///    displacement has no origin to move. An absolute one takes both.
///  * **The first moveto is absolute even when it is written `m`.** SVG says
///    so, and Inkscape writes `m`. It still comes out as `m` here: the current
///    point starts at the origin, so a relative move of the absolute value
///    lands in the same place.
///
/// Both are a path that is subtly the wrong shape rather than one that fails,
/// which is why they are spelled out.
String _transformPath(String d, double k, double t) {
  final tokens = _pathToken.allMatches(d).map((m) => m.group(0)!).toList();
  final out = StringBuffer();
  var cmd = '';
  var index = 0; // position within the current command's argument list
  var first = true; // the first moveto has not finished its arguments
  var afterNumber = false;

  /// How many numbers one repetition of [c] takes. Only used to find the end
  /// of that first moveto.
  int arityOf(String c) => switch (c.toUpperCase()) {
    'H' || 'V' => 1,
    'C' => 6,
    'S' || 'Q' => 4,
    'Z' => 0,
    _ => 2,
  };

  for (final token in tokens) {
    if (token.length == 1 && RegExp(r'[A-Za-z]').hasMatch(token)) {
      if (token.toUpperCase() == 'A') {
        _fail(
          '$_source: this path has an arc ($token), which is not moved here. '
          'Export it with arcs converted to curves.',
        );
      }
      cmd = token;
      index = 0;
      out.write(token);
      afterNumber = false;
      continue;
    }
    final v = double.parse(token);
    // Lower case is relative — except for the very first moveto, which SVG
    // defines as absolute whichever case it is written in.
    final relative = cmd == cmd.toLowerCase() && !first;
    final moved = relative ? v * k : v * k + t;
    final s = _n(moved);
    // A number that does not begin with a minus needs a separator, always. A
    // repeated command restarts its argument list without a letter between, so
    // "is this the first argument" is not the question.
    if (afterNumber && !s.startsWith('-')) out.write(' ');
    out.write(s);
    afterNumber = true;
    index++;
    if (index == arityOf(cmd)) {
      index = 0;
      first = false;
    }
  }
  return out.toString();
}

/// The stroke the drawing puts on its path, at a canvas of side [side].
double _strokeAt(double side, {double fraction = 1.0}) =>
    _art.strokeWidth * side / _art.canvas * fraction;

// ---------------------------------------------------------------------------
// assets/brand/

const String _brandHeader = '''
<!--
  SPDX-License-Identifier: GPL-3.0-or-later

  Generated by packaging/icon/make_icons.dart from assets/brand/oaa-logo.svg.
  Do not edit: run `dart run packaging/icon/make_icons.dart` instead.

  Keep runs of hyphens out of any comment added here. Two in a row end an XML
  comment and every renderer that loads the file through an img element then
  shows a broken image with no error anywhere.
-->''';

/// The mark on its own: the wave, white, on nothing.
///
/// For a dark surface, and only a dark surface. It carries no ground, and the
/// artwork is white, so on a pale page it is invisible — which the four bars it
/// replaced were not, being teal. Anywhere the background is not known, the
/// file to reach for is `oaa-icon.svg`.
String _brandMark() =>
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '$_brandHeader\n'
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"\n'
    '     width="1024" height="1024" role="img" aria-labelledby="oaa-mark-title">\n'
    '  <title id="oaa-mark-title">Open Audio Analyzer</title>\n'
    '  <path d="${_wavePath(1024)}" fill="#FFFFFF" stroke="#FFFFFF"\n'
    '        stroke-width="${_n(_strokeAt(1024))}"/>\n'
    '</svg>\n';

/// The ground on its own, full bleed and square.
String _brandGround() =>
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '$_brandHeader\n'
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"\n'
    '     width="1024" height="1024" role="img" aria-labelledby="oaa-ground-title">\n'
    '  <title id="oaa-ground-title">Open Audio Analyzer</title>\n'
    '${_gradientDefs()}'
    '  <rect width="1024" height="1024" fill="url(#oaa-ground)"/>\n'
    '</svg>\n';

String _gradientDefs() {
  final stops = _art.stops
      .map(
        (s) =>
            '      <stop offset="${_n(s.$1)}" stop-color="${_hex(s.$2)}"/>\n',
      )
      .join();
  return '  <defs>\n'
      '    <linearGradient id="oaa-ground" x1="0" y1="0" x2="0" y2="1">\n'
      '$stops'
      '    </linearGradient>\n'
      '  </defs>\n';
}

/// The app icon as a vector: the tile, the ground and the wave.
///
/// The one file to reach for when the background is not known — a favicon, a
/// README, an avatar. `oaa-mark.svg` is white on nothing and disappears on a
/// pale page; this one brings its own ground and reads anywhere.
///
/// It names itself with a `<title>`, which is what an `<img>` wants. The
/// documentation site inlines it into a header that is already labelled and
/// takes the title back off — see `_brandMark` in `tool/docs.dart`.
String _iconSvg() =>
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '$_brandHeader\n'
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"\n'
    '     width="1024" height="1024" role="img" aria-labelledby="oaa-icon-title">\n'
    '  <title id="oaa-icon-title">Open Audio Analyzer</title>\n'
    '${_gradientDefs()}'
    '  <path d="${_tilePath(1024)}" fill="url(#oaa-ground)"/>\n'
    '  <path d="${_wavePath(1024)}" fill="#FFFFFF" stroke="#FFFFFF"\n'
    '        stroke-width="${_n(_strokeAt(1024))}"/>\n'
    '</svg>\n';

// ---------------------------------------------------------------------------
// Android's adaptive icon
//
// Three layers on a 108x108 canvas. `monochrome` is what Android 13 tints for
// a themed home screen; without it the launcher falls back to shrinking the
// full-colour icon inside a grey circle, which looks like a bug in the app.

String _adaptiveIcon() => '''
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by packaging/icon/make_icons.dart. Do not edit. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background"/>
    <foreground android:drawable="@drawable/ic_launcher_foreground"/>
    <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>
</adaptive-icon>
''';

/// The background layer: the drawing's own ramp, every stop of it.
///
/// A `<vector>` with an `aapt:attr` gradient rather than the `<shape>` this was
/// until 0.10.0. A shape drawable's `<gradient>` takes a start, a centre and an
/// end and nothing else, and it quantises the angle to 45 degrees; the drawing
/// has four stops at offsets that are not halves. A vector's gradient takes
/// `<item>` stops at any offset and an exact direction, so the launcher gets
/// the ramp that was drawn instead of a three-stop approximation of it.
String _androidGround() {
  final stops = _art.stops
      .map(
        (s) =>
            '                <item android:offset="${_n(s.$1)}"\n'
            '                      android:color="${_hex(s.$2)}"/>\n',
      )
      .join();
  return '''
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by packaging/icon/make_icons.dart. Do not edit. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
        xmlns:aapt="http://schemas.android.com/aapt"
        android:width="108dp"
        android:height="108dp"
        android:viewportWidth="108"
        android:viewportHeight="108">
    <path android:pathData="M0,0h108v108h-108z">
        <aapt:attr name="android:fillColor">
            <gradient android:type="linear"
                      android:startX="54" android:startY="0"
                      android:endX="54" android:endY="108">
$stops            </gradient>
        </aapt:attr>
    </path>
</vector>
''';
}

/// The wave on Android's 108dp canvas, scaled into the safe zone.
///
/// **The foreground layer and the monochrome layer are the same file.** They
/// were not while the mark was four bars: the foreground capped the tallest one
/// in the over colour and the monochrome layer left it off, because a launcher
/// that tints a drawable takes its alpha and throws the colours away, so a
/// two-colour mark arrived as one silhouette with the cap invisible. The wave
/// is one colour, so there is nothing left for the two to disagree about — and
/// they stay two files because the adaptive icon names them separately and a
/// launcher does different things with them.
///
/// `strokeWidth` is written rather than baked into the path because a
/// VectorDrawable strokes the centre of a path exactly as SVG does, and the
/// drawing is a filled outline with a stroke on it. Flattening the two here
/// would be this program's idea of the artist's line rather than the artist's.
String _androidWave() {
  const side = 108.0;
  const fraction = _Tile.adaptiveSafe;
  return '''
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by packaging/icon/make_icons.dart. Do not edit. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
        android:width="108dp"
        android:height="108dp"
        android:viewportWidth="108"
        android:viewportHeight="108">
    <path android:fillColor="#FFFFFF"
          android:strokeColor="#FFFFFF"
          android:strokeWidth="${_n(_strokeAt(side, fraction: fraction))}"
          android:pathData="${_wavePath(side, fraction: fraction)}"/>
</vector>
''';
}

// ---------------------------------------------------------------------------
// Apple's layered icon
//
// macOS 26 and iOS 26 do not display an app icon, they render one. The system
// lights the layers below itself — a specular edge, a shadow, a rim highlight
// — and it derives the dark and the tinted appearance from the same document.
// A flat PNG cannot take part in any of that: it is composited already, so
// there is nothing left to light and nothing to re-tint, and the system falls
// back to masking it and leaving it alone.
//
// That is also why there is no `appearances` block anywhere in this
// repository. It is the older, flatter way of saying the same thing — a second
// set of PNGs for dark and a third for tinted, hand-listed in a Contents.json
// — and `actool` already derives all three from this one document. Two sources
// for one appearance is exactly the drift this program exists to prevent.
//
// It back-deploys, which is the part worth knowing before deleting anything:
// compiled with `--minimum-deployment-target 13.0` it also emits the flat
// renditions an older iOS wants, and against macOS 10.15 it emits a classic
// `.icns`. So this replaces the appiconset rather than sitting beside it, and
// two assets both called AppIcon would be a build error rather than a choice.
//
// The bundle is a directory: `icon.json` beside a folder of 1024-unit SVGs.
// The ground is full bleed and square, with no rounded corners of its own —
// the system masks to its own shape, and a corner drawn here would be rounded
// twice, which is the mistake [_Shape.bleed] exists to avoid on the flat path.

/// The wave, as Apple's front layer.
String _iconWave() =>
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"\n'
    '     width="1024" height="1024">\n'
    '  <path d="${_wavePath(1024)}" fill="#FFFFFF" stroke="#FFFFFF"\n'
    '        stroke-width="${_n(_strokeAt(1024))}"/>\n'
    '</svg>\n';

/// The ground, as the bottom layer rather than as a fill.
///
/// `icon.json` has a `fill`, but it names a system material — the light or the
/// dark glass the OS supplies — and it takes no custom gradient. Handed one,
/// `actool` does not reject it: it throws an exception and dies with a
/// backtrace. So the ramp is a layer, which is what Apple's own sample icons do
/// with their backgrounds too.
String _iconGround() =>
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"\n'
    '     width="1024" height="1024">\n'
    '${_gradientDefs()}'
    '  <rect width="1024" height="1024" fill="url(#oaa-ground)"/>\n'
    '</svg>\n';

/// The document. Groups are front to back, so the wave is named first.
///
/// `glass` is what puts the system's material on the wave, and `specular`
/// gives the group its lit edge. The ground takes neither: it is the thing the
/// light falls on, and a ground with its own highlight reads as a second pane
/// of glass behind the first.
String _iconJson() =>
    '{\n'
    '  "fill" : "automatic",\n'
    '  "groups" : [\n'
    '    {\n'
    '      "blur-material" : null,\n'
    '      "layers" : [\n'
    '        {\n'
    '          "glass" : true,\n'
    '          "hidden" : false,\n'
    '          "image-name" : "wave.svg",\n'
    '          "name" : "wave",\n'
    '          "opacity" : 1\n'
    '        }\n'
    '      ],\n'
    '      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },\n'
    '      "specular" : true,\n'
    '      "translucency" : { "enabled" : false, "value" : 0 }\n'
    '    },\n'
    '    {\n'
    '      "blur-material" : null,\n'
    '      "layers" : [\n'
    '        {\n'
    '          "hidden" : false,\n'
    '          "image-name" : "ground.svg",\n'
    '          "name" : "ground"\n'
    '        }\n'
    '      ],\n'
    '      "shadow" : { "kind" : "none", "opacity" : 0 },\n'
    '      "specular" : false,\n'
    '      "translucency" : { "enabled" : false, "value" : 0 }\n'
    '    }\n'
    '  ],\n'
    '  "supported-platforms" : { "squares" : "shared" }\n'
    '}\n';

/// Writes one `AppIcon.icon` bundle. Both Apple projects get their own copy,
/// the same way both already had their own asset catalogue: this program
/// writes them from one description, so two directories cannot drift.
void _writeAppleIcon(String dir) {
  _write('$dir/AppIcon.icon/icon.json', utf8.encode(_iconJson()));
  _write('$dir/AppIcon.icon/Assets/ground.svg', utf8.encode(_iconGround()));
  _write('$dir/AppIcon.icon/Assets/wave.svg', utf8.encode(_iconWave()));
}
