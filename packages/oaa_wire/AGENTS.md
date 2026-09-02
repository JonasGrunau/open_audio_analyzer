# packages/oaa_wire/

The remote-display and plugin protocol, as Dart. **GPL-3.0-or-later**, and pure:
no Flutter, no `dart:ffi`, no I/O. It turns bytes into a `MeterSource` and back,
and it does not own a socket — `lib/src/remote/` does that, and the plugin's C++
does it at the other end.

This package was MIT through 0.13.0, so that somebody writing their own display
could speak the protocol without their program becoming GPL. The whole
repository is copyleft now, which costs that reader the *code* and not the
protocol: `docs/WIRE.md` is normative, freely implementable, and the reason
there are already three implementations of it that were not written against each
other. Keep the document that good and this package stops being the only way
in.

| File | Contents |
|------|----------|
| `src/frame.dart` | The 12-byte header, the magic, the frame types — including `0x0006`, the dynamics naming, added under version 5 because it changes no table — and the reader that skips what it does not recognise. |
| `src/hello.dart` | `HELLO` — the shape negotiation, and the rejection when two builds disagree about what a byte means. |
| `src/snapshot_codec.dart` | `0x0003 SNAPSHOT`. Every offset in the frozen table, as named constants — the version 5 one, `SnapshotWireV4` for the version 4 one and `SnapshotWireLegacy` for the version 1–3 one, both decode-only and kept because a plugin outlives an app upgrade. Version 5 is the eight per-source spectra between `histogram` and the scope run. |
| `src/quantise.dart` | The fixed-point encodings versions 4 and 5 carry the *plotted* arrays in, and the reserved codes that keep NaN distinct from a reading. Mirrored by hand in `plugin/src/OaaWire.h`; the two agree because they were both written against `docs/WIRE.md`. |
| `src/wire_snapshot.dart` | `WireSnapshot` — a decoded frame presented as a `MeterSource`, so the fourteen modules cannot tell it from an engine. **`decode` takes the frame's version and chooses the table by it, never by the length** — a version 4 relay frame with a long scope run is as long as a version 5 one — so every caller passes `FrameReader.version`. Carries the DAW's playhead too, written from outside as transport frames decode: it is not in the snapshot frame, and a module has nowhere else to read it. |
| `src/daw_transport.dart` | `0x0010 DAW_TRANSPORT`, and the presence bits. |
| `src/lufs_mode.dart` | `0x0020 SET_LUFS_MODE` — the one frame that travels consumer → producer, and the only one this package *encodes for sending to a producer*. Ingest port only; the reasoning is in `docs/WIRE.md` and it is the security model, not a detail. |
| `test/plugin_golden_test.dart` | This codec against bytes the C++ actually wrote. |
| `test/plugin_e2e_test.dart` | This codec against a *running* plugin: it spawns `plugin/host/`'s fake DAW headless and decodes what comes off the socket. Skips without a built plugin, which is every run outside `ci.yml`'s `plugin` job. |

## Rules

- **`docs/WIRE.md` is the specification and this is one implementation of it.**
  The C++ in `plugin/src/OaaWire.h` is another, and it was not written against
  this code. If the two disagree, the document is right and **both** sides get
  looked at. Never fix a mismatch by editing one end until the test passes.

- **The byte tables are frozen per protocol version, not per ABI version.**
  `OAA_ABI_VERSION` is a private matter between the engine and what links it. A
  field appended to `oaa_snapshot` bumps the ABI and changes nothing here. If
  editing an offset in `snapshot_codec.dart` ever looks like the fix for a
  failing test, it is not: the wire moved, which means the protocol version
  moved, which means every display in the field needs to know.

- **The offsets are named constants, and they are checked against a total.**
  A frame is a fixed length, so a field written into the wrong slot still
  parses — the app draws a spectrum out of the scope buffer and looks entirely
  plausible doing it. That is why the golden test exists and why it reads bytes
  the C++ actually produced rather than bytes this package round-tripped.

- **NaN and −∞ survive the codec unchanged.** NaN means nobody measured it, −∞
  means digital silence, and both have bit patterns a careless serialiser
  normalises — NaN through arithmetic, −∞ through a clamp. Substituting a zero
  for either puts a number on screen that nobody measured. Both are asserted.

- **Decoding is total.** Any sequence of bytes is a possible input: a truncated
  frame, a hostile length field, a version from the future. Nothing here throws
  on malformed input — it returns null and the caller drops the link. A payload
  over 1 MiB is refused rather than allocated, because a length field is an
  instruction to allocate.

- **A `FrameReader` belongs to a stream, not to the object that owns it.** It
  accumulates until a frame is whole, so a socket that dies mid-frame leaves
  bytes in it that are not a prefix of anything the next connection will send.
  Reading on reassembles the dead stream's head onto the live one at exactly the
  right length to decode — so the display draws an invented measurement instead
  of failing, and the leftovers survive the desync that follows, which makes
  every retry repeat it. **`reset()` on every path that ends a connection**;
  `DisplayClient._teardown` is the one place that does.

- **Nothing here decides *when* to send.** Rate, flow control and the two-second
  staleness rule live in `lib/src/remote/`. This package is a codec; giving it a
  timer would make it untestable without one.

## Testing

```sh
dart test packages/oaa_wire
```

`test/wire_test.dart` covers framing, `HELLO` rejection and round-trips.
`test/plugin_golden_test.dart` decodes the goldens the C++ serialiser wrote —
the only test that catches the two implementations drifting apart, because each
one round-tripping against itself would pass forever while they disagreed. It
reads four. `plugin/test/golden/wire_v5.bin` tracks the current serialiser.
`wire_v2.bin`, `wire_v3.bin` and `wire_v4.bin` are **frozen and never
regenerated**: bytes produced before a promise was made are the only thing that
can hold it, and today's build cannot prove anything about yesterday's.

The frozen files carry different promises, and each version change has
changed what the previous golden is *for*. The pair `v2`/`v3` proves that
version 3 moved a frame type and no table — a byte-level diff that comes out
as four version fields and nothing else. `v3` is also the only evidence that
the version 1–3 decode path works at all: version 4 moved every offset after
`clip`, so reading those bytes exercises `SnapshotWireLegacy` rather than the
normal table. `v4` is the same evidence for `SnapshotWireV4`, one version on:
version 5 inserted 8,192 bytes before the scope count, so reading its bytes
through the version 5 table would draw the mid spectrum as a waveform. Those
paths are what keep a plugin sitting in somebody's VST3 folder drawing after
they upgrade the app, and nothing else in the repository exercises them.
