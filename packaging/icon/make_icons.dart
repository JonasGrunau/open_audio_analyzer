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
// different container, under a different filename — sixty-odd files in total. Exported by
// hand from a drawing they drift: somebody changes the mark, updates the four
// sizes they were looking at, and the icon in the Windows Start menu stays a
// year behind the one in the Dock. Generated, there is one description of the
// mark and everything else is a consequence.
//
// `packaging/icon/oaa.svg` is the same mark for the places that want a vector —
// Linux's `scalable` hicolor directory — and carries the same numbers as
// [_Mark] below. `assets/brand/` holds the logo, which is this mark with the
// tile taken away and the name set beside it; that file's header says what may
// not be changed there alone. All of them follow this one, never the reverse.
//
// ---------------------------------------------------------------------------
// Why one mark is drawn in three shapes
//
// The desktop platforms want the artwork to *be* the rounded tile: it is what
// lands in the Dock, and the corners outside it have to be transparent or the
// icon has white notches on a dark shelf. Neither phone works that way, and
// each is wrong in its own direction, so the artwork takes three forms.
// [_Shape] names the two that are rasterised; Android's is a vector, built
// further down from the same numbers.
//
// iOS masks the icon itself, with a superellipse that is not the same curve as
// [_Mark.corner], and it refuses an alpha channel outright — an icon with one
// is rejected on upload as ITMS-90717 rather than at build time. So its
// artwork is square, full bleed and written without an alpha channel at all.
// Rounding it here would round it twice, which shows as dark wedges in the
// four corners of every home screen.
//
// Android composites two layers and then masks them with whatever shape the
// launcher is set to — circle, squircle, teardrop — and reserves the outer
// 18dp of a 108dp canvas for the parallax it plays on scroll. Only the middle
// 72dp is guaranteed to survive. So its foreground is the bars alone on
// transparency, inset to that safe zone, over a background layer of its own.
// Both of its layers are VectorDrawables: nothing there needs a raster, and a
// vector cannot have the density somebody forgot to regenerate.
//
// ---------------------------------------------------------------------------
// Why it has no dependencies
//
// `package:image` would do this in ten lines. It would also be the first
// dependency in the repository that exists solely for a build step, and it
// would have to be resolvable on every release runner. What is actually needed
// is a PNG writer for opaque RGBA, which is a container format around
// `ZLibCodec` — about eighty lines, all of it below, none of it subtle. The
// shapes are rectangles and rounded rectangles, so there is no rasteriser here
// either: each pixel's coverage is computed directly, sampled four by four.
//
// Run:  dart run packaging/icon/make_icons.dart
//
// It writes into the platform directories as well as packaging/icon/out, and
// the results are committed. A release runner does not run this.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// The mark

/// Open Audio Analyzer's icon, as geometry on a unit square.
///
/// A meter, because that is what Open Audio Analyzer is: four bars at four
/// different heights, the tallest one topped in the over colour. Not a
/// letterform and not a waveform — a letter says nothing about what the
/// application does, and a waveform is what every audio editor on the machine
/// already looks like.
///
/// The heights go up, down and up again rather than climbing in order. Four
/// bars that climb in order are the cellular signal glyph, and it is the shape
/// the eye recognises, not the palette: teal bars in a graphite tile still read
/// as reception if they are stepped like reception. See [bars].
///
/// It survives 16 px, which is the size that decides an icon. At 16 px the bars
/// are two pixels wide and the red cap is one, and that is still four bars at
/// four heights with one of them in trouble.
abstract final class _Mark {
  /// The graphite the whole interface is drawn on — `OaaColors.background`.
  /// The bottom right corner of the tile, and the colour the gradient ends on.
  static const _Rgb background = _Rgb(0x0B, 0x0C, 0x0E);

  /// The top left corner — `OaaColors.hairline`.
  ///
  /// It was `OaaColors.meterTrack` (0x32, 0x39, 0x42) first, which lifted the
  /// corner far enough that the tile read as lit rather than as graphite. One
  /// step down the same palette keeps the ramp visible and keeps the icon dark,
  /// which is what it is: the application is a dark instrument, and an icon
  /// whose corner glows is describing a different program.
  ///
  /// The tile used to be flat [background] with a hairline of
  /// `OaaColors.hairlineStrong` around it, which was there to give it an edge
  /// on a pale desktop. Both are gone. The hairline is a one-pixel detail that
  /// survives nothing: iOS masks it off with its own curve, Android's launcher
  /// crops it, and at 16 px it is the same pixel as the corner antialiasing. A
  /// gradient does the job it was doing — the tile has a top and a bottom, so
  /// it reads as a solid on any wallpaper — and does it at every size, because
  /// it is the whole face rather than its border.
  static const _Rgb backgroundLift = _Rgb(0x1F, 0x23, 0x28);

  /// `OaaColors.accent`, the one signal hue.
  static const _Rgb accent = _Rgb(0x35, 0xE0, 0xC4);

  /// `OaaColors.over`. One bar is over, which is the only state a meter has
  /// that you can read across a room.
  static const _Rgb over = _Rgb(0xFF, 0x4D, 0x4D);

  static const double corner = 0.2;
  static const double inset = 0.2;

  /// Android reserves the outer 18dp of a 108dp adaptive canvas, so only the
  /// middle 72 is certain to be drawn. The bars are laid out to fill the same
  /// fraction of *that* square as [inset] leaves them on a desktop tile, which
  /// is what makes the two look like one icon after two different masks.
  static const double adaptiveSafe = 72 / 108;
  static const double adaptiveInset = 0.5 - (1 - 2 * inset) * adaptiveSafe / 2;

  /// Bar heights as a fraction of the drawable height, left to right.
  ///
  /// They rose monotonically once — 0.34, 0.55, 0.74, 1.00 — and that was the
  /// cellular signal glyph, which is drawn exactly that way and sits in the
  /// status bar of every phone this icon would appear on. Four bars that climb
  /// in order read as reception no matter what colour they are. A meter goes up
  /// *and down*: the valley at the third bar is the whole difference, and it is
  /// what stops the eye filing this under connectivity.
  static const List<double> bars = [0.62, 1.0, 0.44, 0.80];

  /// A bar's width relative to the gap between two of them.
  static const double barToGap = 2.0;

  /// Corner radius of a bar, as a fraction of its width. Slight on purpose:
  /// at 0.3 the bars become lozenges and at 16 px they are dots, and at 0.1 it
  /// is a rounding nobody sees paid for at every size.
  static const double barRadius = 0.2;

  /// How much of the tallest bar is over.
  static const double cap = 0.22;

  /// Which bar carries the over cap. The tallest, wherever [bars] puts it.
  static int get tallest {
    var best = 0;
    for (var i = 1; i < bars.length; i++) {
      if (bars[i] > bars[best]) best = i;
    }
    return best;
  }
}

/// The two shapes the artwork is rasterised in, depending on who masks it.
///
/// Android's third shape — the bars alone, inset into its 72-of-108 safe zone —
/// is a VectorDrawable rather than a PNG, so it is not one of these.
enum _Shape {
  /// The rounded tile itself, with transparent corners. macOS, Windows, Linux,
  /// and Android's pre-adaptive launcher.
  tile,

  /// Square, full bleed, every pixel opaque, written without an alpha channel.
  /// The Play Store's icon, which the console rounds in its own interface.
  /// Apple's platforms want the same thing and get it from the layered
  /// document instead, which `actool` flattens for them.
  bleed,
}

/// Colour of the mark at a point on the unit square, or null for transparent.
///
/// Everything is axis-aligned, so "is this point inside" is four comparisons
/// and one corner test. Antialiasing is by supersampling in [_render] rather
/// than by computing coverage analytically: at 4x4 it is exact enough for a
/// shape made of straight edges, and it keeps this a predicate over a point,
/// which is the whole reason there is no rasteriser in this file.
_Rgb? _colorAt(double x, double y, _Shape shape) {
  // The ground first: it is what a point inside the tile but not on a bar gets,
  // and what the corner test decides is outside the icon altogether.
  final ground = switch (shape) {
    _Shape.tile =>
      _insideRoundedSquare(x, y, _Mark.corner) ? _backgroundAt(x, y) : null,
    _Shape.bleed => _backgroundAt(x, y),
  };

  final left = _Mark.inset;
  final right = 1 - _Mark.inset;
  final top = left;
  final bottom = right;
  if (x < left || x > right || y < top || y > bottom) return ground;

  final count = _Mark.bars.length;
  final span = right - left;
  // count bars and count-1 gaps, with a bar barToGap times a gap.
  final unit = span / (count * _Mark.barToGap + (count - 1));
  final barWidth = unit * _Mark.barToGap;
  final radius = barWidth * _Mark.barRadius;

  for (var i = 0; i < count; i++) {
    final barLeft = left + i * (barWidth + unit);
    if (x < barLeft || x > barLeft + barWidth) continue;

    final height = (bottom - top) * _Mark.bars[i];
    final barTop = bottom - height;
    if (!_insideRoundedRect(
      x,
      y,
      barLeft,
      barTop,
      barLeft + barWidth,
      bottom,
      radius,
    )) {
      return ground;
    }

    // Only the tallest bar is over, and only its top. The cap is a region of
    // the bar rather than a shape on top of it, so it takes the bar's rounded
    // corners and meets the accent on a straight line.
    if (i == _Mark.tallest && y < barTop + height * _Mark.cap) {
      return _Mark.over;
    }
    return _Mark.accent;
  }

  return ground;
}

/// The tile's ground: a linear ramp along the leading diagonal, from
/// [_Mark.backgroundLift] at the top left to [_Mark.background] at the bottom
/// right.
_Rgb _backgroundAt(double x, double y) {
  final t = ((x + y) / 2).clamp(0.0, 1.0);
  int mix(int a, int b) => (a + (b - a) * t).round();
  return _Rgb(
    mix(_Mark.backgroundLift.r, _Mark.background.r),
    mix(_Mark.backgroundLift.g, _Mark.background.g),
    mix(_Mark.backgroundLift.b, _Mark.background.b),
  );
}

/// Whether a point is inside an axis-aligned rectangle with [r] on every
/// corner. The same corner test as [_insideRoundedSquare], without the
/// assumption that the rectangle is the unit square.
bool _insideRoundedRect(
  double x,
  double y,
  double left,
  double top,
  double right,
  double bottom,
  double r,
) {
  if (x < left || x > right || y < top || y > bottom) return false;
  // A bar can be shorter than two radii; then it is as round as it can be.
  final radius = r.clamp(0.0, (bottom - top) / 2).toDouble();
  if (radius <= 0) return true;

  final dx = x < left + radius
      ? left + radius - x
      : (x > right - radius ? x - (right - radius) : 0.0);
  final dy = y < top + radius
      ? top + radius - y
      : (y > bottom - radius ? y - (bottom - radius) : 0.0);
  return dx * dx + dy * dy <= radius * radius;
}

bool _insideRoundedSquare(
  double x,
  double y,
  double radius, {
  double inset = 0,
}) {
  final lo = inset;
  final hi = 1 - inset;
  if (x < lo || x > hi || y < lo || y > hi) return false;

  final r = radius - inset;
  if (r <= 0) return true;

  // Only the four corner boxes need a distance test.
  final dx = x < lo + r ? lo + r - x : (x > hi - r ? x - (hi - r) : 0.0);
  final dy = y < lo + r ? lo + r - y : (y > hi - r ? y - (hi - r) : 0.0);
  return dx * dx + dy * dy <= r * r;
}

/// The mark at [size] px, as straight RGBA.
///
/// Supersampled 4x4 over [_colorAt]. The alpha of the result is the coverage of
/// the rounded square, so the corners come out transparent rather than painted
/// onto an assumed white — an icon with baked-in corners is an icon with white
/// notches on a dark dock.
Uint8List _render(int size, _Shape shape) {
  const samples = 4;
  const total = samples * samples;
  final pixels = Uint8List(size * size * 4);

  for (var py = 0; py < size; py++) {
    for (var px = 0; px < size; px++) {
      var r = 0.0, g = 0.0, b = 0.0, hits = 0;

      for (var sy = 0; sy < samples; sy++) {
        for (var sx = 0; sx < samples; sx++) {
          final x = (px + (sx + 0.5) / samples) / size;
          final y = (py + (sy + 0.5) / samples) / size;
          final colour = _colorAt(x, y, shape);
          if (colour == null) {
            continue;
          }
          r += colour.r;
          g += colour.g;
          b += colour.b;
          hits++;
        }
      }

      if (hits == 0) continue;
      // Averaged over the samples that hit, with coverage in alpha. Averaging
      // over all samples instead would drag the edge towards black, which is a
      // dark fringe wherever the icon meets something pale.
      final offset = (py * size + px) * 4;
      pixels[offset] = (r / hits).round();
      pixels[offset + 1] = (g / hits).round();
      pixels[offset + 2] = (b / hits).round();
      pixels[offset + 3] = (hits * 255 / total).round();
    }
  }

  return pixels;
}

class _Rgb {
  const _Rgb(this.r, this.g, this.b);
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
  final out = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  final ihdr = BytesBuilder()
    ..add(_be32(size))
    ..add(_be32(size))
    // 8-bit, RGB or RGBA, no interlace.
    ..add([8, opaque ? 2 : 6, 0, 0, 0]);
  out.add(_chunk('IHDR', ihdr.takeBytes()));

  // One filter byte per scanline, always 0. Filtering would compress better;
  // an icon is a few kilobytes either way and "none" is one less thing that can
  // be wrong.
  final raw = BytesBuilder();
  for (var y = 0; y < size; y++) {
    raw.addByte(0);
    if (opaque) {
      // Drop the fourth byte of each pixel rather than compositing: a bleed
      // render has no transparent pixel in it, so there is nothing to composite
      // against and every alpha is already 255.
      for (var x = 0; x < size; x++) {
        final offset = (y * size + x) * 4;
        raw
          ..addByte(rgba[offset])
          ..addByte(rgba[offset + 1])
          ..addByte(rgba[offset + 2]);
      }
    } else {
      raw.add(Uint8List.sublistView(rgba, y * size * 4, (y + 1) * size * 4));
    }
  }
  out.add(_chunk('IDAT', ZLibCodec(level: 9).encode(raw.takeBytes())));
  out.add(_chunk('IEND', Uint8List(0)));

  return out.takeBytes();
}

Uint8List _chunk(String type, List<int> data) {
  final body = BytesBuilder()
    ..add(ascii.encode(type))
    ..add(data);
  final bytes = body.takeBytes();

  return (BytesBuilder()
        ..add(_be32(data.length))
        ..add(bytes)
        ..add(_be32(_crc32(bytes))))
      .takeBytes();
}

Uint8List _be32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value);

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final byte in bytes) {
    c = _crcTable[(c ^ byte) & 0xFF] ^ (c >> 8);
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

  var offset = 6 + 16 * sizes.length;
  final directory = BytesBuilder();
  for (final size in sizes) {
    final png = pngsBySize[size]!;
    directory
      // 256 is written as 0. A byte cannot hold it, and every reader knows.
      ..addByte(size >= 256 ? 0 : size)
      ..addByte(size >= 256 ? 0 : size)
      ..addByte(0) // palette size
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
    Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.little);

Uint8List _le32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);

// ---------------------------------------------------------------------------

final Map<String, Uint8List> _cache = {};

/// A PNG of the mark at [size], drawn in [shape]. Cached, because the desktop
/// sets overlap heavily and a 1024 render is the slow part of this program.
Uint8List _pngOf(int size, [_Shape shape = _Shape.tile]) {
  final opaque = shape == _Shape.bleed;
  return _cache['$size.${shape.name}'] ??= _png(
    size,
    _render(size, shape),
    opaque: opaque,
  );
}

void _write(String path, List<int> bytes) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
  stdout.writeln('  ${bytes.length.toString().padLeft(7)}  $path');
}

void main() {
  stdout.writeln('Open Audio Analyzer icons');

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

  // Both of the layers under it are vectors on a 108dp canvas: the mark is
  // rectangles and arcs, so nothing about it needs a raster, and a vector has
  // no density for somebody to forget to regenerate.
  _write(
    'android/app/src/main/res/drawable/ic_launcher_foreground.xml',
    utf8.encode(_foregroundVector()),
  );
  _write(
    'android/app/src/main/res/drawable/ic_launcher_monochrome.xml',
    utf8.encode(_monochromeVector()),
  );
  _write(
    'android/app/src/main/res/drawable/ic_launcher_background.xml',
    utf8.encode(_backgroundGradient()),
  );

  // The Play Console asks for this one by hand at upload time; it is not built
  // into the aab. Full bleed, because the store rounds it in its own UI.
  _write('packaging/android/play_store_icon.png', _pngOf(512, _Shape.bleed));

  stdout.writeln(
    'Done. oaa.svg is the vector twin — keep its numbers in step.',
  );
}

// ---------------------------------------------------------------------------
// Android's adaptive icon
//
// Three layers on a 108x108 canvas. `monochrome` is what Android 13 tints for
// a themed home screen; without it the launcher falls back to shrinking the
// full-colour icon inside a grey circle, which looks like a bug in the app.

String _hex(_Rgb c) =>
    '#${c.r.toRadixString(16).padLeft(2, '0')}'
            '${c.g.toRadixString(16).padLeft(2, '0')}'
            '${c.b.toRadixString(16).padLeft(2, '0')}'
        .toUpperCase();

String _adaptiveIcon() => '''
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by packaging/icon/make_icons.dart. Do not edit. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background"/>
    <foreground android:drawable="@drawable/ic_launcher_foreground"/>
    <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>
</adaptive-icon>
''';

/// The background layer: the same diagonal ramp [_backgroundAt] draws.
///
/// A shape drawable rather than a colour resource, because the ground is a
/// gradient now. `android:angle` is quantised to 45 degrees and measures
/// anticlockwise from east, so 315 puts the start colour at the top left and
/// runs it to the bottom right — the same direction as everywhere else.
String _backgroundGradient() =>
    '''
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by packaging/icon/make_icons.dart. Do not edit. -->
<shape xmlns:android="http://schemas.android.com/apk/res/android"
       android:shape="rectangle">
    <gradient android:type="linear"
              android:angle="315"
              android:startColor="${_hex(_Mark.backgroundLift)}"
              android:endColor="${_hex(_Mark.background)}"/>
</shape>
''';

/// The bars as path data on a square [canvas], inset by [inset] on every side.
///
/// Path data and nothing else, because three files want the same curves. An
/// Android VectorDrawable and an SVG both take the `M … a … h … v … z` grammar
/// and differ only in the attribute the string hangs on, so the geometry is
/// produced once here and formatted twice below. Two emitters that each walked
/// [_Mark] separately would be two chances to walk it differently.
///
/// With [cap] false the over cap is left off and every bar is one colour. That
/// is Android's monochrome layer: the launcher takes the alpha of that drawable
/// and throws its colours away, so a two-colour mark would arrive as a single
/// silhouette with the cap invisible anyway.
List<(String, _Rgb)> _barPaths({
  required double canvas,
  required double inset,
  required bool cap,
}) {
  final left = inset * canvas;
  final right = (1 - inset) * canvas;
  final bottom = right;
  final span = right - left;

  final count = _Mark.bars.length;
  final unit = span / (count * _Mark.barToGap + (count - 1));
  final barWidth = unit * _Mark.barToGap;
  final r = barWidth * _Mark.barRadius;

  String n(double v) {
    final s = v.toStringAsFixed(3);
    return s.contains('.')
        ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
        : s;
  }

  /// A bar: rounded on all four corners.
  String bar(double x, double y, double w, double h) {
    final rr = r.clamp(0.0, h / 2);
    return 'M${n(x)},${n(y + rr)}a${n(rr)},${n(rr)} 0 0 1 ${n(rr)},${n(-rr)}'
        'h${n(w - 2 * rr)}a${n(rr)},${n(rr)} 0 0 1 ${n(rr)},${n(rr)}'
        'v${n(h - 2 * rr)}a${n(rr)},${n(rr)} 0 0 1 ${n(-rr)},${n(rr)}'
        'h${n(2 * rr - w)}a${n(rr)},${n(rr)} 0 0 1 ${n(-rr)},${n(-rr)}z';
  }

  /// The over cap: the top of the tallest bar. Rounded above, where it takes
  /// the bar's own corners, and square below, where it meets the accent — so
  /// the radius comes from the bar's full height, not from the cap's.
  String capOf(double x, double y, double w, double h, double capHeight) {
    final rr = r.clamp(0.0, h / 2);
    return 'M${n(x)},${n(y + rr)}a${n(rr)},${n(rr)} 0 0 1 ${n(rr)},${n(-rr)}'
        'h${n(w - 2 * rr)}a${n(rr)},${n(rr)} 0 0 1 ${n(rr)},${n(rr)}'
        'v${n(capHeight - rr)}h${n(-w)}z';
  }

  final out = <(String, _Rgb)>[];
  for (var i = 0; i < count; i++) {
    final x = left + i * (barWidth + unit);
    final height = span * _Mark.bars[i];
    final top = bottom - height;
    // On the monochrome layer the colour is thrown away by the launcher;
    // accent is written anyway, because a drawable has to say something and it
    // is what makes the file readable on its own.
    out.add((bar(x, top, barWidth, height), _Mark.accent));
    if (cap && i == _Mark.tallest) {
      out.add((
        capOf(x, top, barWidth, height, height * _Mark.cap),
        _Mark.over,
      ));
    }
  }
  return out;
}

/// Android's 108dp canvas, inset to the safe zone the launcher guarantees.
List<(String, _Rgb)> _androidBars({required bool cap}) =>
    _barPaths(canvas: 108, inset: _Mark.adaptiveInset, cap: cap);

String _vector(List<(String, _Rgb)> paths) {
  final body = paths
      .map(
        (p) =>
            '    <path android:fillColor="${_hex(p.$2)}"\n'
            '          android:pathData="${p.$1}"/>',
      )
      .join('\n');
  return '<?xml version="1.0" encoding="utf-8"?>\n'
      '<!-- Generated by packaging/icon/make_icons.dart. Do not edit. -->\n'
      '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
      '        android:width="108dp"\n'
      '        android:height="108dp"\n'
      '        android:viewportWidth="108"\n'
      '        android:viewportHeight="108">\n'
      '$body\n'
      '</vector>\n';
}

String _foregroundVector() => _vector(_androidBars(cap: true));

String _monochromeVector() => _vector(_androidBars(cap: false));

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

/// One layer of the Apple icon: paths on the 1024 canvas Icon Composer uses.
String _iconLayer(List<(String, _Rgb)> paths) {
  final body = paths
      .map((p) => '  <path d="${p.$1}" fill="${_hex(p.$2)}"/>')
      .join('\n');
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"\n'
      '     width="1024" height="1024">\n'
      '$body\n'
      '</svg>\n';
}

/// The ground, as the bottom layer rather than as a fill.
///
/// `icon.json` has a `fill`, but it names a system material — the light or the
/// dark glass the OS supplies — and it takes no custom gradient. Handed one,
/// `actool` does not reject it: it throws an exception and dies with a
/// backtrace. So the graphite is a layer, which is what Apple's own sample
/// icons do with their backgrounds too.
String _iconGround() =>
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"\n'
    '     width="1024" height="1024">\n'
    '  <defs>\n'
    '    <linearGradient id="ground" x1="0" y1="0" x2="1" y2="1">\n'
    '      <stop offset="0" stop-color="${_hex(_Mark.backgroundLift)}"/>\n'
    '      <stop offset="1" stop-color="${_hex(_Mark.background)}"/>\n'
    '    </linearGradient>\n'
    '  </defs>\n'
    '  <rect width="1024" height="1024" fill="url(#ground)"/>\n'
    '</svg>\n';

/// The document. Groups are front to back, so the bars are named first.
///
/// `glass` is what puts the system's material on the bars, and `specular`
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
    '          "image-name" : "bars.svg",\n'
    '          "name" : "bars",\n'
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
  _write(
    '$dir/AppIcon.icon/Assets/bars.svg',
    utf8.encode(
      _iconLayer(_barPaths(canvas: 1024, inset: _Mark.inset, cap: true)),
    ),
  );
}
