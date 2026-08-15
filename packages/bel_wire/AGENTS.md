# packages/bel_wire/

The remote-display and plugin protocol, as Dart. **MIT**, and pure: no Flutter,
no `dart:ffi`, no I/O. It turns bytes into a `MeterSource` and back, and it does
not own a socket — `lib/src/remote/` does that, and the plugin's C++ does it at
the other end.

MIT rather than GPL on purpose. Somebody writing their own display should be
able to speak this protocol without their program becoming GPL; the value of a
published wire format is that things nobody asked for can talk to it.

| File | Contents |
|------|----------|
| `src/frame.dart` | The 12-byte header, the magic, the frame types, and the reader that skips what it does not recognise. |
| `src/hello.dart` | `HELLO` — the shape negotiation, and the rejection when two builds disagree about what a byte means. |
| `src/snapshot_codec.dart` | `0x0003 SNAPSHOT`. Every offset in the frozen table, as named constants. |
| `src/wire_snapshot.dart` | `WireSnapshot` — a decoded frame presented as a `MeterSource`, so the thirteen modules cannot tell it from an engine. |
| `src/daw_transport.dart` | `0x0010 DAW_TRANSPORT`, and the presence bits. |

## Rules

- **`docs/WIRE.md` is the specification and this is one implementation of it.**
  The C++ in `plugin/src/BelWire.h` is another, and it was not written against
  this code. If the two disagree, the document is right and **both** sides get
  looked at. Never fix a mismatch by editing one end until the test passes.

- **The byte tables are frozen per protocol version, not per ABI version.**
  `BEL_ABI_VERSION` is a private matter between the engine and what links it. A
  field appended to `bel_snapshot` bumps the ABI and changes nothing here. If
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

- **Nothing here decides *when* to send.** Rate, flow control and the two-second
  staleness rule live in `lib/src/remote/`. This package is a codec; giving it a
  timer would make it untestable without one.

## Testing

```sh
dart test packages/bel_wire
```

`test/wire_test.dart` covers framing, `HELLO` rejection and round-trips.
`test/plugin_golden_test.dart` decodes `plugin/test/golden/wire_v1.bin`, which
the C++ serialiser generated — the only test that catches the two
implementations drifting apart, because each one round-tripping against itself
would pass forever while they disagreed.
