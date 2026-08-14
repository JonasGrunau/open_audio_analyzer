/// The Bel domain model.
///
/// SPDX-License-Identifier: MIT
///
/// This package deliberately depends on nothing. Not Flutter, not `dart:ffi`,
/// not even `bel_engine`. It describes *what* a measurement is, what a delivery
/// target is, and how a screen full of meters is laid out — never where any of
/// those numbers come from.
///
/// The reason is not architectural tidiness. Four different things need this
/// vocabulary: the desktop app, the tablet remote display, the `bel` CLI and the
/// plugin. Three of them have no engine of their own — the remote display reads
/// measurements off a socket — so the moment this package imports `bel_engine`,
/// those three drag a native library they never call into. Keeping it pure is
/// also what lets `dart test` run the entire domain layer with no toolchain and
/// no widget tree.
library;

export 'src/calibration.dart';
export 'src/layout.dart';
export 'src/metric.dart';
