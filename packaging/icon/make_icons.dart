// SPDX-License-Identifier: GPL-3.0-or-later
//
// Draws Bel's mark at every size the four installers ask for.
//
// ---------------------------------------------------------------------------
// Why this is a program and not a folder of PNGs
//
// A dmg, an msix, an AppImage and a flatpak each want the icon at a different
// set of sizes, in a different container, under a different filename — thirty-
// odd files in total. Exported by hand from a drawing they drift: somebody
// changes the mark, updates the four sizes they were looking at, and the icon
// in the Windows Start menu stays a year behind the one in the Dock. Generated,
// there is one description of the mark and everything else is a consequence.
//
// `packaging/icon/bel.svg` is the same mark for the places that want a vector —
// Linux's `scalable` hicolor directory — and carries the same numbers as
// [_Mark] below. It is the one duplicate here and it is annotated as such.
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

/// Bel's icon, as geometry on a unit square.
///
/// A meter, because that is what Bel is: four bars rising left to right, the
/// tallest one topped in the over colour. Not a letterform and not a waveform —
/// a `b` says nothing about what the application does, and a waveform is what
/// every audio editor on the machine already looks like.
///
/// It survives 16 px, which is the size that decides an icon. At 16 px the
/// bars are two pixels wide and the red cap is one, and that is still four
/// bars, rising, with the top one in trouble.
abstract final class _Mark {
  /// The graphite the whole interface is drawn on — `BelColors.background`.
  static const _Rgb background = _Rgb(0x0B, 0x0C, 0x0E);

  /// `BelColors.accent`, the one signal hue.
  static const _Rgb accent = _Rgb(0x35, 0xE0, 0xC4);

  /// `BelColors.over`. One bar is over, which is the only state a meter has
  /// that you can read across a room.
  static const _Rgb over = _Rgb(0xFF, 0x4D, 0x4D);

  /// `BelColors.hairlineStrong`, so the tile has an edge on a white desktop.
  static const _Rgb edge = _Rgb(0x2E, 0x34, 0x3C);

  static const double corner = 0.2;
  static const double inset = 0.2;

  /// Bar heights as a fraction of the drawable height, left to right.
  static const List<double> bars = [0.34, 0.55, 0.74, 1.0];

  /// A bar's width relative to the gap between two of them.
  static const double barToGap = 2.0;

  /// How much of the tallest bar is over.
  static const double cap = 0.22;
}

/// Colour of the mark at a point on the unit square, or null for transparent.
///
/// Everything is axis-aligned, so "is this point inside" is four comparisons
/// and one corner test. Antialiasing is by supersampling in [_render] rather
/// than by computing coverage analytically: at 4x4 it is exact enough for a
/// shape made of straight edges, and it keeps this function a predicate.
_Rgb? _colorAt(double x, double y) {
  if (!_insideRoundedSquare(x, y, _Mark.corner)) return null;

  const left = _Mark.inset;
  const right = 1 - _Mark.inset;
  const top = _Mark.inset;
  const bottom = 1 - _Mark.inset;

  // The tile's own edge: a hairline just inside the rounded square.
  const edgeWidth = 0.012;
  if (!_insideRoundedSquare(x, y, _Mark.corner, inset: edgeWidth)) {
    return _Mark.edge;
  }

  if (x < left || x > right || y < top || y > bottom) return _Mark.background;

  final count = _Mark.bars.length;
  const span = right - left;
  // count bars and count-1 gaps, with a bar barToGap times a gap.
  final unit = span / (count * _Mark.barToGap + (count - 1));
  final barWidth = unit * _Mark.barToGap;

  for (var i = 0; i < count; i++) {
    final barLeft = left + i * (barWidth + unit);
    if (x < barLeft || x > barLeft + barWidth) continue;

    final height = (bottom - top) * _Mark.bars[i];
    final barTop = bottom - height;
    if (y < barTop) return _Mark.background;

    // Only the tallest bar is over, and only its top.
    final isTallest = i == count - 1;
    if (isTallest && y < barTop + height * _Mark.cap) return _Mark.over;
    return _Mark.accent;
  }

  return _Mark.background;
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
/// Sampled 4x4 per pixel. The alpha is the coverage of the rounded square, so
/// the corners are transparent rather than painted onto an assumed white — an
/// icon with baked-in corners is an icon with white notches on a dark dock.
Uint8List _render(int size) {
  const samples = 4;
  final pixels = Uint8List(size * size * 4);

  for (var py = 0; py < size; py++) {
    for (var px = 0; px < size; px++) {
      var r = 0.0, g = 0.0, b = 0.0, hits = 0;

      for (var sy = 0; sy < samples; sy++) {
        for (var sx = 0; sx < samples; sx++) {
          final x = (px + (sx + 0.5) / samples) / size;
          final y = (py + (sy + 0.5) / samples) / size;
          final color = _colorAt(x, y);
          if (color == null) continue;
          r += color.r;
          g += color.g;
          b += color.b;
          hits++;
        }
      }

      final offset = (py * size + px) * 4;
      if (hits == 0) continue;

      // Averaged over the samples that hit, then multiplied out by coverage:
      // the colour is the mark's colour and the alpha is how much of the pixel
      // the mark covers. Averaging over all samples instead would darken the
      // edge towards black, which is a halo on a light background.
      pixels[offset] = (r / hits).round();
      pixels[offset + 1] = (g / hits).round();
      pixels[offset + 2] = (b / hits).round();
      pixels[offset + 3] = (255 * hits / (samples * samples)).round();
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
Uint8List _png(int size, Uint8List rgba) {
  final out = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  final ihdr = BytesBuilder()
    ..add(_be32(size))
    ..add(_be32(size))
    ..add(const [8, 6, 0, 0, 0]); // 8-bit, RGBA, no interlace
  out.add(_chunk('IHDR', ihdr.takeBytes()));

  // One filter byte per scanline, always 0. Filtering would compress better;
  // an icon is a few kilobytes either way and "none" is one less thing that can
  // be wrong.
  final raw = BytesBuilder();
  for (var y = 0; y < size; y++) {
    raw.addByte(0);
    raw.add(Uint8List.sublistView(rgba, y * size * 4, (y + 1) * size * 4));
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

final Map<int, Uint8List> _cache = {};

Uint8List _pngOf(int size) => _cache[size] ??= _png(size, _render(size));

void _write(String path, List<int> bytes) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
  stdout.writeln('  ${bytes.length.toString().padLeft(7)}  $path');
}

void main() {
  stdout.writeln('Bel icons');

  // macOS. The names are Xcode's, and Contents.json in the asset catalogue
  // already refers to them.
  const macos = {
    'app_icon_16.png': 16,
    'app_icon_32.png': 32,
    'app_icon_64.png': 64,
    'app_icon_128.png': 128,
    'app_icon_256.png': 256,
    'app_icon_512.png': 512,
    'app_icon_1024.png': 1024,
  };
  for (final entry in macos.entries) {
    _write(
      'macos/Runner/Assets.xcassets/AppIcon.appiconset/${entry.key}',
      _pngOf(entry.value),
    );
  }

  // Windows: the runner's icon resource, and the msix logos.
  _write(
    'windows/runner/resources/app_icon.ico',
    _ico({
      for (final size in [16, 32, 48, 64, 128, 256]) size: _pngOf(size),
    }),
  );
  const msix = {
    'Square44x44Logo.png': 44,
    'Square150x150Logo.png': 150,
    'StoreLogo.png': 50,
  };
  for (final entry in msix.entries) {
    _write('packaging/windows/images/${entry.key}', _pngOf(entry.value));
  }

  // Linux: hicolor sizes for the flatpak, and the one the AppImage puts at the
  // root of its AppDir.
  for (final size in [16, 32, 48, 64, 128, 256, 512]) {
    _write(
      'packaging/linux/icons/${size}x$size/dev.belmeter.bel.png',
      _pngOf(size),
    );
  }

  stdout.writeln(
    'Done. bel.svg is the vector twin — keep its numbers in step.',
  );
}
