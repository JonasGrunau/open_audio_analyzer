/// The Open Audio Analyzer domain model.
///
/// SPDX-License-Identifier: GPL-3.0-or-later
///
/// This package deliberately depends on nothing. Not Flutter, not `dart:ffi`,
/// not even `oaa_engine`. It describes *what* a measurement is, what a delivery
/// target is, and how a screen full of meters is laid out — never where any of
/// those numbers come from.
///
/// The reason is not architectural tidiness. Four different things need this
/// vocabulary: the desktop app, the tablet remote display, the `oaa` CLI and the
/// plugin. Three of them have no engine of their own — the remote display reads
/// measurements off a socket — so the moment this package imports `oaa_engine`,
/// those three drag a native library they never call into. Keeping it pure is
/// also what lets `dart test` run the entire domain layer with no toolchain and
/// no widget tree.
library;

export 'src/calibration.dart';
export 'src/config_locations.dart';
export 'src/grid.dart';
export 'src/layout.dart';
export 'src/meter_source.dart';
export 'src/metric.dart';
export 'src/report.dart';
export 'src/report_export.dart';
export 'src/settings.dart';
export 'src/skin.dart';
export 'src/skin_contrast.dart';
export 'src/spectrum_source.dart';
export 'src/transport.dart';
export 'src/weighting.dart';
