/// The Bel design system.
///
/// SPDX-License-Identifier: GPL-3.0-or-later
///
/// Two rules hold the visual language together, and both are enforced here
/// rather than in review:
///
///   1. Every spatial value comes from [Space]. No widget in this repository
///      writes a raw number for padding, margin or gap.
///   2. Every number on screen is monospaced with tabular figures. A readout
///      whose digits change width jitters while you watch it, which is the
///      fastest way to make a measurement tool look untrustworthy.
///   3. Every control Bel paints itself is built through [BelFocusable]. A
///      painted control is not reachable by keyboard and not visible to
///      assistive technology unless something puts that back, and nothing
///      about the rendered result reveals the omission.
///
/// Everything else — the palette, the radii, the single hairline border weight,
/// the absence of shadows — follows from the Precision Instrument direction and
/// is swappable per skin.
library;

export 'src/drag_devices.dart';
export 'src/focusable.dart';
export 'src/glyph.dart';
export 'src/grid_geometry.dart';
export 'src/meter_painter.dart';
export 'src/module_frame.dart';
export 'src/panel.dart';
export 'src/point_buckets.dart';
export 'src/readout.dart';
export 'src/scale.dart';
export 'src/skin_palette.dart';
export 'src/text_cache.dart';
export 'src/theme.dart';
export 'src/tokens.dart';
