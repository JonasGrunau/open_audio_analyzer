/// The Open Audio Analyzer wire protocol.
///
/// SPDX-License-Identifier: GPL-3.0-or-later
///
/// `docs/WIRE.md` is the normative specification. This package is one
/// implementation of it and not the definition — the plugin's C++ sender is
/// another, written against the same page, and the two have to agree
/// byte-for-byte without ever having seen each other's code.
///
/// Pure Dart on purpose. It depends on `oaa_core` for [MeterSource] and on
/// nothing else, which is what lets `dart test` round-trip a frame with no
/// toolchain, no native library and no widget tree — and what lets the tablet
/// decode measurements it has no engine to produce.
library;

export 'src/daw_transport.dart';
export 'src/frame.dart';
export 'src/hello.dart';
export 'src/lufs_mode.dart';
export 'src/quantise.dart';
export 'src/snapshot_codec.dart';
export 'src/wire_snapshot.dart';
