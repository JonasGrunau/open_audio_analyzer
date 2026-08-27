// Hand written FFI declarations, for the one call that runs every frame.
//
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ffi';

import '../oaa_engine_bindings_generated.dart' show oaa_engine;

/// The asset produced by `hook/build.dart`.
///
/// A bare `@Native()` annotation derives the asset id from the URI of the
/// library it appears in, which for this file would be
/// `package:oaa_engine/src/oaa_ffi.dart` — not what the build hook emitted.
/// ffigen's generated file happens to sit at the right URI and so gets away
/// without naming it; anything hand written has to be explicit.
const _assetId = 'package:oaa_engine/oaa_engine_bindings_generated.dart';

/// Refresh the engine's snapshot and return its generation.
///
/// This is the same symbol ffigen already bound, redeclared for one reason:
/// `isLeaf`.
///
/// A normal FFI call transitions the VM into a state where the native code is
/// allowed to call back into Dart, allocate handles, or trigger a GC
/// safepoint. That bookkeeping costs tens of nanoseconds and it is entirely
/// wasted here — `oaa_snapshot_acquire` does an atomic load, a memcpy and a
/// second atomic load, and cannot re-enter Dart even in principle. Declaring it
/// leaf removes the transition and leaves roughly a direct call.
///
/// The trade is that a leaf call must never block and must never call back into
/// the runtime. `oaa_snapshot_acquire` satisfies both by construction: it is a
/// seqlock read with a bounded retry count and no waiting of any kind. If that
/// ever stops being true, this declaration becomes a way to hang the UI thread
/// with no diagnostic, so the invariant is restated in oaa.h next to the
/// function itself.
@Native<Uint64 Function(Pointer<oaa_engine>)>(
  symbol: 'oaa_snapshot_acquire',
  assetId: _assetId,
  isLeaf: true,
)
external int oaaSnapshotAcquireLeaf(Pointer<oaa_engine> engine);
