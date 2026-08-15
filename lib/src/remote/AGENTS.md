# lib/src/remote/

The remote display: both ends of it. GPL-3.0-or-later.

The same binary is the host on a desktop and the display on a tablet, so both
halves live here.

| Path | Purpose |
|------|---------|
| `display_host.dart` | The server. Publishes measurements to attached displays. |
| `display_client.dart` | The client. Decodes them into a `WireSnapshot`. |
| `display_screen.dart` | The tablet's UI: find a host, then draw its layout. |
| `remote_display_service.dart` | The socket and the mDNS advertisement as one switch. |
| `remote_control.dart` | The status-bar entry and its panel. Phase 6's whole footprint in the desktop app. |
| `mdns/dns_message.dart` | Just enough DNS to advertise and find one service. |
| `mdns/mdns_service.dart` | The responder and the browser. |

`docs/WIRE.md` is the protocol and it is normative. The codec is
`packages/bel_wire/`; nothing in here re-implements a byte of it.

## Rules

- **There is no tablet rendering path, and there must never be one.** The
  display hands a `MeterSource` and a `PresetSpec` to the same `ModuleHost` the
  desktop canvas uses. A remote display whose meters were written a second time
  would eventually disagree with the desktop about what the signal did, and then
  neither screen could be trusted. If something cannot be drawn from a
  `MeterSource`, the fix is to the interface, not to a second painter.

- **A display shows; it does not touch.** Version 1 of the protocol is
  one-directional. Nothing here may gain a way to reset, retarget or
  reconfigure the host — see the trust-boundary section of `docs/WIRE.md` for
  why the answer is different on the plugin's loopback port.

- **A link that has gone quiet says so, and drops what it was showing.** After
  two seconds without a frame the client calls `markStale()`: every reading
  becomes NaN, both availability flags go false, and the arrays are filled with
  NaN rather than the dB floor. Keeping the last frame on screen is the tempting
  version and it is the wrong one — a frozen meter is indistinguishable from a
  quiet passage, so a display left running after its host slept shows a
  confident, detailed picture of a signal that stopped existing.

- **Filling a spectrum with the dB floor is not "no data", it is silence.**
  Silence is a measurement. NaN is the absence of one.

- **A client that falls behind loses frames; it never queues them.**
  `DisplayHost` skips any client whose last write has not flushed. A display
  working through a backlog shows what the signal did half a second ago with
  total confidence, and unlike a dropped frame nothing about it looks wrong.

- **The host refreshes the source itself and the clock compares generations.**
  A `Ticker` stops when the window is occluded, which is exactly when the tablet
  is the screen being used. `MeterClock` therefore decides "is there something
  new" from `source.generation` rather than from what `refresh()` returned,
  because `refresh` answers "is this new *to whoever asked*" — with two askers,
  the first consumes the answer and the second is told nothing happened, so one
  of the two screens silently stops repainting. Do not put that back.

- **`Socket.add` keeps the buffer it is given.** The snapshot frame is reused,
  so the host holds a ring of four and does not touch one until its write has
  flushed. Overwriting a pending buffer splices half of one measurement onto
  half of another, and the frame still parses.

- **Everything about discovery is best-effort and nothing about it throws.**
  Multicast is the first thing a guest network blocks and the first thing a
  corporate image disables. Every failure path ends in "discovery does not work
  here", and the typed-address field is always offered — a display that only
  worked when discovery worked would fail in exactly the rooms it exists for.

- **The DNS reader must survive anything.** Port 5353 carries every device on
  the network announcing services Bel has never heard of, some of it malformed
  and some of it hostile. `decodeMessage` returns null rather than throwing,
  compression pointers must point backwards and have a jump budget, and an
  unknown record type advances the cursor to the end of its rdata so the records
  after it still parse.

## Platform notes

- **macOS and iOS need both entitlements and a usage string.** The same binary
  listens and connects, so `com.apple.security.network.server` *and*
  `.client` are set in both entitlement files. `NSLocalNetworkUsageDescription`
  and `NSBonjourServices` (`_bel._tcp`) are in both `Info.plist`s; without them
  the OS silently drops multicast and the symptom is a host nobody can find,
  with nothing logged. A refused permission surfaces as the failure string in
  the remote panel rather than as an empty list.

- **Android discovery is not solved.** `CHANGE_WIFI_MULTICAST_STATE` is
  declared, but on Wi-Fi Android also requires a `WifiManager.MulticastLock`,
  which is a platform call Dart cannot make. Until that is a plugin, an Android
  tablet browses nothing and must be given an address. The UI says so rather
  than showing an empty list, which is the honest version of the same fact.
  This is listed in the README's gaps.
