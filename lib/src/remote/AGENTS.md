# lib/src/remote/

The remote display: both ends of it. GPL-3.0-or-later.

The same binary is the host on a desktop and the display on a tablet, so both
halves live here.

| Path | Purpose |
|------|---------|
| `display_host.dart` | The server. Publishes measurements to attached displays. |
| `display_client.dart` | The client. Decodes them into a `WireSnapshot`. |
| `display_screen.dart` | The tablet's UI: the host picker until there is a host, then that host's layout. |
| `host_picker.dart` | Choosing a host — what discovery found, the code a camera reads, and the address you type when neither worked. One panel, pushed by the desktop's ATTACH button and shown by the display screen itself. |
| `remote_display_service.dart` | The socket and the mDNS advertisement as one switch. |
| `pair_link.dart` | `oaa://host:port` — what a pairing code carries, and the one parser behind both it and the address somebody types. |
| `qr_scanner.dart` | The camera half of pairing: a viewfinder over `mobile_scanner`, and `canScanQrCodes`, which is why the row is absent on Windows and Linux rather than disabled. |
| `remote_control.dart` | `RemoteDisplayScope`, which drives the service and carries it, and the three controls the status bar shows: `PublishSwitch`, `PairingCodeButton`, `AttachButton`. |
| `publish_settings.dart` | `PublishSection` — everything about publishing except the switch — and `PairingCodePanel` behind it. |
| `mdns/dns_message.dart` | Just enough DNS to advertise and find one service. |
| `mdns/mdns_service.dart` | The responder, and the browser every platform but iOS uses. |
| `mdns/host_discovery.dart` | `DiscoveredHost`, the `HostDiscovery` interface the picker draws, and which of the two searches this platform is allowed to run. |
| `mdns/bonjour_discovery.dart` | The iOS search, over a channel to the system responder. Its native half is `ios/Runner/OaaBonjour.swift`. |
| `mdns/multicast_lock.dart` | The `WifiManager.MulticastLock` Android needs before anything multicast is delivered to it at all, reference counted so that overlapping searches hold one. A no-op everywhere else. Its native half is `android/.../OaaMulticastLock.kt`. |

`docs/WIRE.md` is the protocol and it is normative. The codec is
`packages/oaa_wire/`; nothing in here re-implements a byte of it.

## Rules

- **This directory owns a socket, not a design system.** `remote_control.dart`
  and `publish_settings.dart` are what a desktop user looks at — three controls
  in the status bar and one section of the settings panel — and the first of
  them was written twice over as stock Material — a `TextButton` in a row of
  `BarButton`s and an `AlertDialog` where every other panel is a
  `PanelScaffold`. The second one did not merely look wrong: a route pushed
  with `showDialog` is built by the `Navigator`, above `MaterialApp.home` —
  which is where the application's `OaaTheme` lived at the time — so the panel
  threw "No OaaTheme in scope" for the whole of Phase 6 and the button did
  nothing at all. Chrome
  here comes from `oaa_ui` and `lib/src/app/bar_controls.dart`; panels open
  through `showOaaPanel`, and how one is composed is specified in
  `packages/oaa_ui/AGENTS.md` § Panels. `test/panels_test.dart` opens this one
  by tapping the button, which is the only way that class of failure is caught.

  It happened a third time and outlasted both: the display's own connect screen
  was an `InkWell` over a hand-rolled `Container`, a stock `TextField` with an
  `OutlineInputBorder` and two Material `TextButton`s — a whole screen of the
  product that had never been near the design system, on the hardware the
  feature exists for. It is `host_picker.dart` now, and it is a `PanelScaffold`
  like everything else. **A screen is not exempt because it is not a dialog.**

- **Which end this machine is is not a question, because it is never asked of
  somebody who does not already know the answer.** Sending is a socket, a name
  and a rate on *this* machine; receiving is a search for somebody else's. They
  have nothing in common, and the first attempt made them one dialog with the
  receiving half behind a footer button marked "Use as display" — which put a
  whole second mode in the row where a panel says "the ways out of here are", so
  the tablet half of the feature was reachable only by pressing the button that
  looked most like Cancel. The second attempt asked the question on a panel of
  its own and pushed one of two answers, which fixed the footer and left both
  halves two presses deep behind a word.

  They are two controls in the status bar now — **PUBLISH**, a switch, and
  **ATTACH**, a button — and each does its whole half in one press. What the
  panel's Send row existed to carry, the switch carries better: publishing is
  legible from the bar without opening anything, because it is the bar.

  **The count of attached displays is not on the bar, and that is a decision
  with a cost.** It is in the switch's tooltip and written out in
  Settings → Publish. The bar has no room for a number that is usually zero,
  but "somebody is watching" is now a fact you hover or open a panel for, where
  "an unauthenticated port is open" is still a fact you glance at.

- **There is one implementation of "choose a host".** `HostPickerPanel` is what
  the desktop pushes and what the display screen shows whenever it has no host,
  including after a Disconnect. Two of them would be two ideas about what to do
  when discovery is blocked, and that answer — always offer a typed address —
  is the whole reason the feature works in the rooms it was built for.

  It offers three ways in, in the order they cost the person holding the
  tablet: a host discovery found, a code the camera reads, and an address typed
  by hand. **All three end at the same `onConnect`** — the scanner pops itself
  and hands back a host and a port exactly as a tapped row does, and knows
  nothing about whether the caller will push a display screen or connect a
  client it already has. A scanner that knew which of those it was in would be
  the second implementation of the thing the rule above says there is one of.

- **A pairing code is an address, and `PairLink` is the only thing that reads
  one.** The field and the camera are the same question asked twice, and two
  parsers would be two opinions about whether a bare `studio-mac.local` means
  the default port — an answer a user discovers by the tablet either connecting
  or not.

  Three things about the format are load-bearing, and all three are refusals:

  - **The `oaa://` scheme.** A QR code is read by whatever camera is pointed at
    it, so the payload has to say what it is. Without a scheme, a phone's own
    camera app offers to web-search `192.168.1.20:5555`, and this scanner
    cannot tell a pairing code from the Wi-Fi code taped to the wall beside the
    desk — it finds a colon in `WIFI:S:Studio;T:WPA;…` and dials a host called
    `WIFI`.
  - **A host that does not look like a host is refused**, which is the other
    half of the same trap: `WIFI:…` carries no `://` for the scheme check to
    catch it by.
  - **A port that is not a port is a refusal, not a host name with a colon in
    it.** `192.168.1.20:70000` is a typo, and keeping the whole string as a
    name turns it into a lookup that fails several seconds later for a reason
    nobody can read. The picker says so instead — strictness with no feedback
    is a Connect button that swallows the press.

  It is **not** part of `docs/WIRE.md` and must not become part of it. The wire
  is what two machines say to each other once they are connected; this is one
  of the three ways a person points one at the other, and it belongs beside
  mDNS rather than beside the byte tables. Nothing in a code may ever configure
  anything: a display that scans one can still do nothing but watch.

- **The camera is a capability, and the row is absent where there is none.**
  `mobile_scanner` covers Android, iOS and macOS; Windows and Linux have no
  implementation and every call into it throws `UnimplementedError` from the
  platform interface. `canScanQrCodes` is asked before the section is built, so
  those two see the panel they always saw. A disabled row would be a feature
  that exists in the interface and not in the product, and a row that throws
  when pressed is worse.

- **A viewfinder is not a panel surface, so it does not take the skin's
  colours.** Every other surface here is one the palette chose, so a hairline
  at 3:1 against the panel is 3:1 wherever it lands. A camera image is a lit
  studio, a black rack, or somebody's white laptop lid filling the frame — a
  bracket in the light skin's `hairlineStrong` over the last of those is
  invisible at exactly the moment it is being used. The scrim and the brackets
  are fixed, the way a viewfinder's are, and the accent appears only for the
  moment a code has been accepted. `OaaQrCode` is the same rule from the other
  end and for a harder reason: dark-on-light is what a decoder thresholds for,
  so a code painted in a dark skin's panel colours is a picture of a QR code.

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

- **What this publishes may itself have arrived over a wire.** When a plugin is
  active the app points the host's source at that session's `WireSnapshot`, so
  the frame a tablet decodes is a *re-encode* of one the app decoded off the
  plugin's socket — the same codec twice, in opposite directions. It costs
  nothing to write, because `SnapshotFrame.encode` takes a `MeterSource` and
  `WireSnapshot` is one, and it is exactly the kind of path that fails one field
  at a time: `plugin_link_test.dart` and `remote_display_test.dart` both stay
  green while the tablet shows a dash where the desktop shows a number.
  `test/plugin_to_display_e2e_test.dart` is what holds it, by running a real
  VST3 in the fake DAW and comparing the display's readings against the app's
  field by field.

  **The DAW's transport makes the trip too, and it does not travel like a
  measurement.** `0x0010` is forwarded to displays, and three things about how
  are load-bearing:

  - **On change, not on the tick.** A session parked at bar 57 and a desktop
    metering a sound card both send one frame and then nothing. The cost of the
    alternative is not the bandwidth, it is that every host would be publishing
    "still nothing" thirty times a second for as long as the app is open.
  - **Replayed on connect**, therefore. A tablet that attaches to a parked
    session would otherwise show no position until somebody pressed play — which
    is exactly when nobody is looking at the tablet.
  - **The discontinuity bit is accumulated, never sampled.** `docs/WIRE.md`
    specifies it as an edge delivered once, and this host publishes thirty times
    a second against a DAW's ninety-odd blocks: two relocates in three would
    vanish if the relay asked "where is the playhead now?" on its own schedule.
    Every producer frame is written into `DisplayHost.transport` — that is why
    it is a setter and not a callback the publish timer calls — and
    `Transport.asDiscontinuous` is what carries the edge onto the frame that
    goes out. A display may count relocations, so a dropped one is a relocation
    that never happened as far as every screen in the building is concerned.

  It is cleared when the link goes quiet, with the measurements and for the same
  reason: a parked transport legitimately sends nothing for minutes, so a held
  position and a dead link are indistinguishable. `TransportReadout` is what
  draws it, and the desktop's status bar draws the same widget — a tablet with
  its own opinion about what a missing tempo looks like is the beginning of two
  meters that disagree.

  **The link bar gives that readout a slot only while the host has a playhead,
  and `DisplayClient.hasTransport` is the only part of a transport a widget may
  watch.** The readout is 232 px wide and draws nothing when there is nothing to
  draw, so a host with no DAW — a desktop metering a device or a file, which is
  most of them — left that much blank in the bar, reading as a control that had
  failed to lay out rather than as an empty readout. The bit follows what the
  host *stated*: a frame saying `Transport.none` takes the slot away, and
  `_checkStale` clears the reading but deliberately leaves the slot, because a
  parked transport on a flaky access point would otherwise reflow the bar every
  time the link went quiet.

  **The tab control comes before the readout in that row, and nothing that can
  appear, vanish or reserve room it is not using may be put in front of it.** It
  is the only control on a display anybody touches, so what fixes its distance
  from the host name is the name and nothing else. The readout is all three of
  those things at once: 232 px is room for a timecode, a tempo and a meter, and
  a host keeping fewer counters than that spends less of it — 182 px for a clock
  and a tempo, 160 for bars and beats, 58 for a clock alone. In front of the
  tabs, the remainder became a hole between the ink and the control, 66 px wide
  in the first case and 190 in the last, and the tabs read as floating in the
  middle of the bar. Behind them the same remainder lands against the row's
  slack, which is where every readout in this application puts it — see
  `TransportAlign` in `lib/src/app/transport_readout.dart`. `hasTransport`
  collapsing the slot is still right, and it is now the smaller half of the
  problem rather than the whole of it.

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

- **The `FrameReader` is reset on every path that ends a connection**, which is
  `_teardown` and only `_teardown`. The same splice as the rule above, through
  the receiving door: a socket that dies mid-frame leaves the head of that frame
  in the reader, and it outlives the socket. The next connection's bytes land
  behind them, reassemble at exactly the right length to decode, and the meters
  draw a measurement nobody took — then the stream desyncs, the link drops, and
  the leftovers survive *that* too, so every retry repeats it. A tablet that
  lost one frame to a Wi-Fi hiccup never came back, and reattaching by hand did
  not clear it because `connect` goes through the same `_teardown`. Held by
  `test/remote_display_test.dart`, which drops a real socket 6 kB into a
  snapshot and requires the display to recover.

- **A socket with a `flush` outstanding is a *bound* sink, and a bound sink
  refuses `add`, `flush` and `close` alike.** `IOSink.flush` raises the same
  flag `addStream` does and lowers it when the flush completes, so every write
  in `DisplayHost` has to know whether the last frame has landed. Both ways of
  not knowing shipped. `sendOnce` wrote a layout, a skin or a delivery target
  between a snapshot frame and its flush, was given
  `StateError("StreamSink is bound to a stream")` by `add`, and did the only
  thing it could with a throw there — closed the connection. Changing the skin
  at the desk dropped the tablet, the more reliably the slower the tablet was,
  because a display that is slow to read is a socket that spends longer
  flushing. And `close` threw the same error *synchronously*, before the future
  its `catchError` was attached to existed, from inside the socket's own
  `onDone` — which is precisely when a flush is most likely to be in flight, a
  display leaving mid-frame. That one reached the root zone as an unhandled
  exception in the host, and the `destroy` beneath it never ran. One-off frames
  now wait for the flush; teardown destroys and never closes.

- **A state a widget builds from is published before the first `await`, not
  after it.** `DisplayClient.connect` is called from
  `RemoteDisplayScreen.initState`, and that screen draws `HostPickerPanel` for
  as long as the link is idle — so `connecting`, set after a suspension, was
  set after the screen's first build. A display handed a host built a picker
  nobody asked for, and a picker starts a search in its own `initState`: a
  panel flashing on the way in, and a second browse opened and torn down a
  frame later. The same shape as the `dispose` rule below, from the other side.

- **Everything about discovery is best-effort and nothing about it throws.**
  Multicast is the first thing a guest network blocks and the first thing a
  corporate image disables. Every failure path ends in "discovery does not work
  here", and the typed-address field is always offered — a display that only
  worked when discovery worked would fail in exactly the rooms it exists for.

  **Best-effort is not silent, and both ends say so.** `MdnsBrowser.failure` has
  carried the searching half since Phase 8; `MdnsResponder.failure` and
  `RemoteDisplayService.advertisementFailure` carry the advertising half, which
  had nothing and is the half that goes wrong. All three of the responder's
  failure paths were discarded — the bind error, a send that threw, and the
  socket's `onError`, which was an empty closure and is where a refused
  local-network permission actually arrives, because **Dart reports a datagram
  socket's send errors through the stream rather than from `send`**.

  Two sentences rather than one, because the two ends do not have the same way
  out: a display that cannot search is handed a field to type an address into,
  and a host that cannot announce itself *is* the thing being looked for.
  `describeAdvertisementFailure` is the second of them. And
  `advertisementFailure` is deliberately not folded into
  `RemoteDisplayService.failure`: publishing is a socket on this machine,
  announcing is a packet leaving it, and only the second one failed.

- **Best-effort is not the same as silent, and for eight phases it was.** Every
  send sat in a `catch` that discarded the error, the socket's `onError` was an
  empty function, and `isBrowsing` meant "the socket bound" while the panel
  presented it as "a search is running". So a device that could not search
  showed *Looking for hosts on this network…* for as long as anybody was
  willing to wait, and the two ends of the feature were indistinguishable from
  a host that was switched off. `HostDiscovery.failure` is the fix and it is
  not optional: anything that stops a search working puts a sentence there, and
  the sentence names the thing the person has to go and change.

- **`dispose` releases a search; it does not publish the end of one.** Both
  implementations of `HostDiscovery` own three `ValueNotifier`s and a resource,
  and `stop()` gives back the resource *and* publishes an empty list. Calling it
  from `dispose` reads as tidy and is a use-after-dispose: `BonjourDiscovery`
  suspends on the channel's `cancel`, so the publishing half resumed after the
  notifiers had been disposed one line later and threw from the framework, most
  reliably on a hot restart. Teardown calls the releasing half only, and
  anything `stop` publishes it publishes *before* it awaits. `MdnsBrowser` never
  threw, because its `stop` happens not to await — which is one added `await`
  away from the same defect, and why both are written the same way.

- **An `EventChannel` holds one sink, so Open Audio Analyzer subscribes to the
  Bonjour channel once and shares it.** The companion trap to the one above, and
  it hides better, because both halves of it are silent. A second `listen` on a
  channel that already has a sink calls the *native* handler's `onCancel` before
  installing the new one — so an arriving reader tears down the browse the
  leaving one is still showing — and a `cancel` that arrives with no sink set is
  answered `PlatformException(error, No active stream to cancel)` from inside
  the framework's own `onCancel`, where nothing in Open Audio Analyzer can catch
  it. Two host pickers overlap by a frame every time one replaces another,
  because a route's `initState` runs before the outgoing route's `dispose`, and
  that frame was enough: the panel on screen searched a browse that had already
  been cancelled and then logged the exception on its way out. `_SharedBrowse`
  in `mdns/bonjour_discovery.dart` reference-counts the readers, replays the
  last list to one that attaches mid-browse, and cancels when the last lets go.
  The engine's rule is `SetStreamHandlerMessageHandlerOnChannel` in
  `FlutterChannels.mm`; a second channel added here inherits the same rule.

- **An instance name is one label, and the writer splits on dots.** Those two
  facts together are a trap that cost a phase. `Platform.localHostname` is
  `studio-mac.local` on a plain network and `studio-mac.fritz.box` on any
  network whose DHCP server hands out a domain — which is most routers — and
  advertising that produced `studio-mac` `fritz` `box` `_oaa` `_tcp` `local`:
  six labels where DNS-SD defines four. **Open Audio Analyzer's own reader
  accepted it**, since `_instanceOf` takes everything before `_oaa._tcp.local`,
  so desktop found desktop and the feature looked healthy; the system responder
  drops the record, so `dns-sd -B` and every iPad saw nothing while the host sat
  there answering every query on the wire. `MdnsResponder.instanceLabel` is the
  single place that guarantees the label, and the friendly name — free-form,
  dots and all — travels in the TXT record's `name`, which is what a picker
  shows.

  The corollary is the SRV target. Sanitising the instance into a host name
  yields the machine's own `.local` name, which the system responder owns and
  **defends**: an address record it did not announce, for a name it owns, is a
  conflict, and RFC 6762 says the loser renames itself. Open Audio Analyzer
  announces every interface's address on every interface, so its set differs
  from the system's as soon as a machine has two, and the machine that would get
  renamed is the user's. The target is `<name>-oaa.local`, which nothing else
  claims.

- **The DNS reader must survive anything.** Port 5353 carries every device on
  the network announcing services Open Audio Analyzer has never heard of, some
  of it malformed and some of it hostile. `decodeMessage` returns null rather
  than throwing, compression pointers must point backwards and have a jump
  budget, and an unknown record type advances the cursor to the end of its rdata
  so the records after it still parse.

## Platform notes

- **The camera is asked for in four places and refused in three ways.** iOS and
  macOS each want an `NSCameraUsageDescription` in their `Info.plist`, macOS
  wants `com.apple.security.device.camera` in *both* entitlement files, and
  Android wants `android.permission.CAMERA` — which `mobile_scanner`'s own
  manifest would supply, and which is declared in the application's as well so
  that a permission a user is asked for at runtime is findable in the manifest
  of the application that asks.

  The macOS entitlement is the one that looks unnecessary and is not: this
  application is deliberately **not** sandboxed, but a Developer ID build is
  signed with the hardened runtime, and the hardened runtime withholds the
  camera from a process that has not asked for it. It is the same trap as
  `com.apple.security.device.audio-input` beside it, and it fails the same way —
  a camera that produces no frame, with nothing logged. All three refusals look
  identical from inside the process, which is why `QrScannerPanel` names the
  platform's own settings path in the sentence it prints rather than reporting
  that the camera did not start.

- **macOS needs both entitlements and a usage string.** The same binary listens
  and connects, so `com.apple.security.network.server` *and* `.client` are set
  in both entitlement files. `NSLocalNetworkUsageDescription` and
  `NSBonjourServices` (`_oaa._tcp`) are in both `Info.plist`s; without them the
  OS silently drops multicast and the symptom is a host nobody can find, with
  nothing logged.

  A refused Local Network permission looks like this from inside the process:
  the bind succeeds, the group join succeeds, `NetworkInterface.list` reports
  the Wi-Fi address, the routing table has a route for 224.0.0/4, and every
  send is refused with `EHOSTUNREACH` — errno 65, "No route to host", on a
  machine that plainly has one. That errno on a multicast send is the
  signature; `describeDiscoveryFailure` and `describeAdvertisementFailure` turn
  it into the sentence that names System Settings.

  **The permission is keyed to the bundle identifier, so changing that revokes
  it — and 0.6.0 changed it.** `dev.openaudioanalyzer.oaa` became
  `com.openaudioanalyzer.oaa`, and every Mac that upgraded became, to TCC, a
  machine running an application it had never been asked about; the entry
  granted to the old identifier still sits in System Settings naming an
  application that no longer exists. Nothing prompts loudly enough to notice and
  nothing is logged. Treat an identifier as a permission grant: **moving one
  means telling users to re-allow every TCC permission the app holds**, which
  here is Local Network and the microphone.

  It is hard to place because **the permission gates outgoing multicast and not
  an inbound connection.** The display port stays open, `nc` reaches it from
  another machine, a display handed the address by hand connects and draws
  meters perfectly — and only the announcement is gone. So the desk looks
  healthy from the desk and the failure is visible only from the tablet, which
  is the one screen with no diagnostics on it. What splits it in two from
  outside is `dns-sd -B _oaa._tcp local` on any Mac on the network: Apple's
  responder sees the whole segment, so a host it cannot see is a host that is
  not announcing, and registering a decoy with `dns-sd -R` proves the browsing
  end and the network separately.

  **It is also how a terminal poisons a test.** macOS attributes the permission
  to the *responsible* process, so a build launched from a shell inherits the
  shell's answer: `flutter test` and a bare
  `Open Audio Analyzer.app/Contents/MacOS/Open Audio Analyzer` are denied while
  the same code inside `open -a "Open Audio Analyzer.app"` is allowed. A
  discovery test that opens a real socket therefore fails on a machine where the
  feature works. `launch_options.dart` records the same trap for the microphone.

- **iOS and iPadOS cannot use the socket at all, and this is not a
  permission.** On real hardware, custom multicast requires
  `com.apple.developer.networking.multicast`, a restricted entitlement Apple
  grants per team on request — so a project people build for themselves cannot
  have one. `NSLocalNetworkUsageDescription` and `NSBonjourServices` do **not**
  cover it; they cover Bonjour through the system responder, which is why
  `BonjourDiscovery` and `ios/Runner/OaaBonjour.swift` exist and need no
  entitlement of any kind. The **simulator is exempt from the restriction**,
  which is how a tablet shipped with a browser that had never found anything:
  it works on a simulator and fails on the iPad, silently, for a phase.

- **Android needs a lock, not a different browser.** `CHANGE_WIFI_MULTICAST_STATE`
  in the manifest is what *allows* the `WifiManager.MulticastLock` to be taken;
  it is not what lifts the Wi-Fi driver's multicast filter. Taking the lock is a
  platform call, `mdns/multicast_lock.dart` over
  `android/.../OaaMulticastLock.kt`, and the browser takes it **before the
  bind** and gives it back with the socket. Without it the socket binds, joins
  224.0.0.251, sends its query and receives nothing, for ever, with no error on
  any path — which is how an Android tablet shipped browsing an empty network
  under *Looking for hosts on this network…*, the exact state
  `HostDiscovery.failure` exists to make impossible, reached through the one
  door that had no error to report.

  Two things about it are load-bearing:

  - **The count is on the Dart side and the native lock is not counted at all.**
    Two searches overlap every time one picker replaces another, and a desktop
    browses while it advertises; a release counted per caller takes multicast
    away from whoever is still looking. The native lock stays uncounted so that
    a hot restart cannot leave it several acquisitions deep with nobody holding
    it.
  - **A refused lock is reported and then ignored.** It does not stop the
    browse: a device with no Wi-Fi hardware has nothing filtering multicast, and
    a wired tablet finds hosts without any lock at all. So the sentence goes to
    `failure` while the search runs, and `host_picker.dart` shows a reason in
    preference to "Looking for hosts" whenever there is one — a search that is
    running and deaf must not wear the face of one that is about to succeed.

  **`NsdManager` was not used, deliberately.** It is a third implementation of
  DNS-SD, and three implementations are three opinions about what is on the
  network; the lock is one platform call and leaves Android browsing with the
  same code, and the same tests, as the desktops.

  **Neither the emulator nor a unit test can show you any of this working.** An
  Android emulator sits behind NAT that does not carry the LAN's multicast, so
  it finds nothing whether the lock is held or not — the same trap as the iOS
  simulator, in the opposite direction. What the suite holds is that the lock is
  asked for, that overlapping searches share one, and that a refusal becomes a
  sentence; that packets arrive is checked on hardware and nowhere else. What an
  emulator *can* show is the half that is not about packets: `adb shell dumpsys
  wifi` lists `Multicaster{Open Audio Analyzer mDNS}` while a picker is open and
  nothing when it closes, and `WifiService` logs the acquire and the release by
  tag. That is the check to run after touching either side of this channel.

  **`reusePort` is not supported on Android, and Dart says so on stderr.**
  `Dart Socket ERROR: … reusePort not supported on this platform` appears in
  logcat on every bind and is *not* a failure: `_bindMulticast` asks for the
  option, is refused, and rebinds with `reuseAddress` alone — which is the whole
  point of it trying twice. Windows refuses it the same way. Do not go looking
  for a bug in discovery because that line is in the log.
