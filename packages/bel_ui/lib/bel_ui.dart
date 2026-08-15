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
///
/// Everything else — the palette, the radii, the single hairline border weight,
/// the absence of shadows — follows from the Precision Instrument direction and
/// is swappable per skin.
library;

export 'src/grid_geometry.dart';
export 'src/meter_painter.dart';
export 'src/module_frame.dart';
export 'src/persistence_layer.dart';
export 'src/readout.dart';
export 'src/scale.dart';
export 'src/text_cache.dart';
export 'src/theme.dart';
export 'src/tokens.dart';
