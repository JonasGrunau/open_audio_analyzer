# The Open Audio Analyzer wire protocol

**Protocol version 2.** This document is normative. Where an implementation and
this file disagree, this file is right and the implementation has a bug.

Version 2 differs from version 1 in one field: the magic, which spells the
application's name and moved when the name did. Every other table below is the
version-1 table unchanged, byte for byte. The version still had to move — a
frozen table is frozen including its magic, and a display that read version 1
must refuse this stream rather than hunt for a frame boundary that will never
match.

There are three implementations of it and they were written by different people
against this page, not against each other:

| Producer / consumer | Language | Lives in |
|---|---|---|
| Desktop app → tablet display | Dart | `packages/oaa_wire/`, `lib/src/remote/` |
| VST3 / AU plugin → desktop app | C++ | `plugin/src/OaaWire.h` |
| Anything you write | yours | this page is the whole contract |

## What it is for

A Open Audio Analyzer host publishes what it is measuring so that another screen
can draw it. That is the entire feature. The protocol carries **measurements and
the layout to draw them in** — never audio, never control.

It is deliberately one-directional. A remote display in version 2 cannot reset
the host's integrated loudness, cannot change its device and cannot load a
preset on it. That is not an omission to be filled in later without thought: a
read-only stream has no attack surface beyond the measurements it already
publishes, and adding a control channel is the change that turns "a screen in
the live room shows the mix engineer's meters" into "anyone on the venue Wi-Fi
can reset the mix engineer's measurement". Frame types `0x0020`–`0x002F` are
reserved for that conversation if it is ever worth having, and it needs an
authentication story before it is.

**There is no authentication and no encryption.** Anyone who can reach the port
can read the measurements and the layout. That is an acceptable trade for a
LAN-only display feature, and it is the reason the host does not listen unless a
human turns it on.

## Who talks, and on which port

The protocol has a **producer** — whatever is measuring — and a **consumer**,
whatever is drawing. The producer sends `HELLO` first and then everything else;
the consumer sends nothing at all in version 2. Which of the two opened the TCP
connection is a separate question, and Open Audio Analyzer needs it both ways
round:

| port | service | listener | producer |
|---|---|---|---|
| 47821 | display | the Open Audio Analyzer app | the Open Audio Analyzer app |
| 47822 | producer ingest | the Open Audio Analyzer app | a plugin instance |

A desktop Open Audio Analyzer *publishes* to tablets, and a plugin *publishes*
to a desktop Open Audio Analyzer. Same frames, opposite direction of connection.

**They are two ports rather than one, and that is deliberate.** If both services
shared a port, an accepted socket would be ambiguous about which end is supposed
to speak first — and the failure mode of guessing wrong is two peers waiting for
each other's `HELLO` forever, which presents as a display that connects and then
shows nothing. Two adjacent numbers cost a line of configuration and remove the
question.

Both ports are configurable. Neither is registered with IANA; they sit in the
dynamic range where they collide with nothing.

### They do not have the same trust boundary

**47821 binds every interface. 47822 binds loopback.** That difference is the
whole of the security model, and it is why the answer to "may a control channel
exist here" is different for the two.

The display port is reachable by anything on the LAN — the point of it is a
tablet across the room — so it is strictly read-only and stays that way until
somebody designs authentication for it. A control channel there would turn "a
screen in the live room shows the engineer's meters" into "anyone on the venue
Wi-Fi can reset the engineer's measurement", and an integrated reading that was
silently restarted mid-programme is wrong in a way nothing on screen reveals.

The ingest port is a plugin in a DAW on the same machine. Bound to loopback, the
set of things that can connect is the set of things already running as this
user, which is a boundary that a password would not improve. Control frames
(`0x0020`–`0x002F`) are therefore permissible **on the ingest port only**, and
still need a protocol version bump and the same frozen-table discipline as
`0x0003`. Nothing in version 2 defines one.

A host that deliberately exposes ingest beyond loopback — a plugin on another
machine — is opting out of that reasoning and must not enable control frames.

## Framing

Every frame is a 12-byte header and a payload. **All integers and floats are
little-endian**, IEEE 754 for floats. Not "host order" — stated, so that a
big-endian consumer knows it has work to do rather than discovering it in a
picture that looks slightly wrong.

| off | type | field |
|---|---|---|
| 0 | `u8[4]` | magic, the ASCII bytes `O`, `A`, `A`, `W` |
| 4 | `u16` | protocol version, currently `2` |
| 6 | `u16` | frame type |
| 8 | `u32` | payload length in bytes |
| 12 | … | payload |

**A receiver skips a frame type it does not know, by length.** It does not error
and it does not close the connection. This is what lets a plugin that sends DAW
transport talk to a display build that predates transport — the frames it does
not understand cost it a `seek` and nothing else.

**A payload longer than 1 MiB is rejected and the connection is dropped.** A
length field is an instruction to allocate, and a corrupt or hostile one that
says four gigabytes must not be obeyed. Nothing in version 2 comes close to the
cap; the largest legitimate frame is a snapshot at 15,068 bytes.

## Frame types

| type | name | direction | when |
|---|---|---|---|
| `0x0001` | `HELLO` | host → client | first frame on every connection |
| `0x0002` | `LAYOUT` | host → client | after `HELLO`, and whenever the layout changes |
| `0x0003` | `SNAPSHOT` | host → client | at the publish rate |
| `0x0004` | `SKIN` | host → client | after `HELLO`, and whenever the skin changes |
| `0x0005` | `CALIBRATION` | host → client | after `HELLO`, and whenever the target changes |
| `0x0010`–`0x001F` | plugin transport | producer → app | see [DAW transport](#0x0010--daw_transport) |
| `0x0020`–`0x002F` | *reserved* | — | a control channel that does not exist in v1 |

### `0x0001` — HELLO

Sent once, immediately on accept, before anything else.

| off | type | field |
|---|---|---|
| 0 | `u16` | protocol version, repeated |
| 2 | `u16` | flags, reserved, zero |
| 4 | `u32` | snapshot payload length this producer will send |
| 8 | `u32` | producer ABI version (`OAA_ABI_VERSION`) |
| 12 | `u32` | `maxChannels` |
| 16 | `u32` | `spectrumBands` |
| 20 | `u32` | `scopePoints` |
| 24 | `u32` | `histogramBins` |
| 28 | `u32` | producer name length in bytes |
| 32 | … | producer name, UTF-8 |

The version is repeated inside the payload on purpose. A client that has
mis-parsed the header — wrong offset, wrong endianness, a proxy that ate four
bytes — reads garbage here and fails on the first frame with something a human
can act on, instead of drawing a spectrum that is subtly shifted.

**A mismatch in the protocol version, the snapshot payload length, or any of the
four array dimensions rejects the connection.** These are the numbers that make
two builds disagree about *what a byte means*, and a display that guesses at
them draws a plausible, wrong picture — the single failure this project can
least afford. Rejecting is the honest outcome; the UI names the two values.

**The producer ABI version is informational and never rejects.** It is shown in
the link details and it is useful when reading a bug report, but a host at ABI 4
and a display at ABI 3 whose snapshot layouts are identical must be allowed to
talk to each other. Refusing a link that would have worked is its own wrong
answer. The payload length is what catches a real reordering.

### `0x0002` — LAYOUT

Payload is UTF-8 JSON: exactly `PresetSpec.toJson()` from
`packages/oaa_core/lib/src/layout.dart`.

The remote display renders the same `ModuleSpec` tree with the same painters, so
it needs the same description of it, and there is already exactly one — the
preset format, which is screen-independent because it is expressed in grid cells
rather than pixels. Inventing a second layout format for the wire would create a
second thing to keep in step with the modules; a tablet rendering a preset the
desktop cannot open is a bug that could not otherwise exist.

`TabSpec.displayTargetId` selects which tabs a given remote display shows. A
client sends nothing to choose it — the *host* decides what to publish where,
because the host is where a human is sitting.

### `0x0004` — SKIN

Payload is UTF-8 JSON of the active `Skin`, or a zero-length payload meaning
"the built-in skin".

Needed because `PresetSpec.skinId` names a skin the tablet may not have: a
user-authored skin is a file on the host's disk. Shipping the resolved token set
rather than the id means the display looks like the desktop it is displaying.
Sending an id and hoping is how the two ends come to render the same session in
different colours.

### `0x0005` — CALIBRATION

Payload is UTF-8 JSON of the active `Calibration`, from
`packages/oaa_core/lib/src/calibration.dart`.

Resolved rather than named, for the same reason as the skin — and with more at
stake. A reading is drawn green, amber or red by comparing it against a target,
so a display holding a different target renders the same measurement in a
different colour. A master that reads "in spec" on the tablet and "over" on the
desktop is worse than a display that shows nothing at all, because one of the
two is going to be believed.

### `0x0003` — SNAPSHOT

**Payload is exactly 15,056 bytes at protocol version 2.**

The layout was *derived* mechanically, so that two hand-written serialisers
cannot drift: take `oaa_snapshot` from `engine/include/oaa/oaa.h` at
`OAA_ABI_VERSION` 3, walk it top to bottom in declaration order, emit every
member including the `reservedN` padding members, each in its natural width,
little-endian, with no alignment padding between members.

**That derivation produced the table below, and the table is what is
normative — not the current contents of `oaa.h`.** The distinction is the whole
reason this is not a struct copy. `oaa_snapshot` will grow: fields get appended
and `OAA_ABI_VERSION` is bumped, which is a private matter between the engine
and the things that link it. The wire layout changes only when the *protocol*
version changes. If the two were the same thing, every engine change would
silently break every remote display in the field, and it would break them by
drawing wrong numbers rather than by failing.

| off | type | field | | off | type | field |
|---|---|---|---|---|---|---|
| 0 | `u64` | `generation` | | 88 | `f32` | `correlation` |
| 8 | `f64` | `elapsed_seconds` | | 92 | `f32` | `balance` |
| 16 | `u32` | `sample_rate` | | 96 | `f32[8]` | `peak` |
| 20 | `u32` | `channels` | | 128 | `f32[8]` | `rms` |
| 24 | `u32` | `flags` | | 160 | `f32[8]` | `vu` |
| 28 | `u32` | `dropped_frames` | | 192 | `u32[8]` | `clip` |
| 32 | `f32` | `lufs_momentary` | | 224 | `f32[512]` | `spectrum` |
| 36 | `f32` | `lufs_short` | | 2272 | `f32[512]` | `spectrum_peak` |
| 40 | `f32` | `lufs_integrated` | | 4320 | `f32` | `lra_low` |
| 44 | `f32` | `lra` | | 4324 | `f32` | `lra_high` |
| 48 | `f32` | `true_peak` | | 4328 | `f32` | `lra_gate` |
| 52 | `f32` | `true_peak_max` | | 4332 | `f32` | `reserved3` |
| 56 | `f32` | `sample_peak_max` | | 4336 | `f32[512]` | `spectrum_pan` |
| 60 | `f32` | `reserved1` | | 6384 | `f32[2048]` | `scope` |
| 64 | `f32` | `dr_short` | | 14576 | `f32[120]` | `histogram` |
| 68 | `f32` | `dr_integrated` | | | | |
| 72 | `f32` | `crest` | | **15056** | | **total** |
| 76 | `f32` | `plr` | | | | |
| 80 | `f32` | `psr` | | | | |
| 84 | `f32` | `reserved2` | | | | |

`flags` are the `OAA_FLAG_*` bits from `oaa.h`: `1<<0` running, `1<<1` loudness
unavailable, `1<<2` spectrum unavailable, `1<<3` overrun.

Reserved members are transmitted and ignored. Carrying them means a future
field that fills a reserved slot moves nothing, and a receiver that ignores them
costs nothing.

Because `oaa.h` declares its 8-byte members first and everything after is
4-byte, `sizeof(oaa_snapshot)` is *also* 15,056 with no internal padding on
every platform Open Audio Analyzer targets. A C or C++ producer may therefore
`memcpy` the struct instead of walking it — but only behind
`static_assert(sizeof(oaa_snapshot) == 15056)`, so that the day the two stop
agreeing is a build failure rather than a shifted frame.

#### NaN is data

**A quantity the producer did not measure is transmitted as NaN**, and it
arrives as NaN. Not zero, not the dB floor, not omitted.
Zero is a legitimate reading for correlation, balance and several dB quantities,
so it cannot double as "no data", and a display that draws a substituted zero is
showing a number nobody measured. The receiving end renders an em dash.

This is the one rule in this document that is worth breaking a build over.

### `0x0010` — DAW_TRANSPORT

Where the audio sits on a DAW's timeline. Emitted by a plugin producer
immediately before each `0x0003 SNAPSHOT`; absent entirely when the producer has
no DAW. Payload is 88 bytes.

Transport is metadata, not measurement, which is why it rides in its own frame
and never in `oaa_snapshot`: the engine must not learn what a DAW is.

| off | type | field | meaning |
|---|---|---|---|
| 0 | `u32` | `flags` | see below |
| 4 | `u32` | `frame_rate` | timecode rate enum |
| 8 | `f64` | `time_seconds` | playhead at block start, seconds from timeline origin |
| 16 | `f64` | `ppq_position` | playhead in quarter-notes |
| 24 | `f64` | `ppq_bar_start` | quarter-notes at the start of the current bar |
| 32 | `f64` | `bpm` | |
| 40 | `f64` | `edit_origin_seconds` | timeline zero → session start; add for wall-clock timecode |
| 48 | `f64` | `loop_start_ppq` | |
| 56 | `f64` | `loop_end_ppq` | |
| 64 | `i64` | `time_samples` | playhead in samples |
| 72 | `u32` | `time_sig_numerator` | |
| 76 | `u32` | `time_sig_denominator` | |
| 80 | `u32` | `host_frames` | frames in the block this position describes |
| 84 | `u32` | `reserved`, zero | |

```
1<<0 PLAYING       1<<1 RECORDING     1<<2 LOOPING
1<<3 HAS_TIME_SECONDS                 1<<4 HAS_PPQ
1<<5 HAS_BPM                          1<<6 HAS_TIME_SIG
1<<7 HAS_TIMECODE (frame_rate valid)  1<<8 HAS_TIME_SAMPLES
1<<9 HAS_LOOP_POINTS                  1<<10 HAS_BAR_START
1<<11 DISCONTINUITY
```

`DISCONTINUITY` is set when the playhead did not arrive where the previous block
left it — a relocate, a loop wrapping, a scrub — detected with a half-block
tolerance so ordinary playback never sets it.

Two things about it are producer behaviour rather than layout, and a consumer
depends on both.

It is only evaluated **while the transport is rolling**. A stopped host still
runs its graph and reports the position it is parked at, unchanged, on every
block; against a prediction of one block further on that is a mismatch of
exactly one block, so a producer that tested it unconditionally would raise a
relocate continuously for as long as the transport sat still. The prediction is
carried across the stop rather than rebuilt from the parked position, which is
what makes the bars 1–16 case below detectable at all.

It is an **edge, delivered once**, not a state to be sampled. The producer knows
about the jump for a single audio block, and frames go out far less often than
blocks arrive, so it must accumulate the bit between frames rather than copy
whatever the block in front of it happens to say. Set it on the first frame at or
after the block where the jump happened, alongside the position the playhead
landed on rather than the one it left; clear it on the next frame unless another
jump has happened since.

A consumer may therefore count relocations by counting the frames that carry the
bit, for as long as the link holds — an edge raised while a frame cannot be sent
is lost with the connection, and a consumer that has just reconnected knows
nothing about what happened while it was away regardless.

It is the only bit in this frame that is about the *measurement* rather than
about the host, and it belongs to the same family as `dropped_frames`. Play bars
1–16, stop, drag back to bar 1, play again: the engine has been fed both passes
and its integrated loudness is now the average of two takes of the same music,
reported as one programme. Nothing about that number looks wrong. So it is
stated rather than inferred, and the producer does **not** act on it — whether a
relocate should restart the integration depends on which LUFS mode the user
picked, and the mode lives in the app.

`frame_rate`, mirroring `juce::AudioPlayHead::FrameRateType`:

| | | | |
|---|---|---|---|
| `0` | 23.976 | `5` | 29.97 drop |
| `1` | 24 | `6` | 30 drop |
| `2` | 25 | `7` | 60 |
| `3` | 29.97 | `8` | 60 drop |
| `4` | 30 | `99` | unknown |

**Unknown is `99`, not `8`** — `8` is 60 drop, a real rate. JUCE 8's modern API
returns a `FrameRate` class rather than this enum; the producer maps to the
table above, and the table is normative, not JUCE's class.

A host that gives no timecode leaves `HAS_TIMECODE` clear *and* sends `99`. Both
signals agree; do not rely on only one.

**A clear `HAS_` bit means the host did not supply that value**, the field is
zero, and it must not be rendered. DAWs vary enormously in what they fill in,
and a zero the host never gave you is an invented measurement like any other.
The presence bits and NaN do the same job for different kinds of field; keep
both. (`f64` transport fields could carry NaN and do not, because a `u32` frame
count and a `u32` time signature have no NaN to carry — one mechanism for the
whole frame beats two.)

## Rate and flow control

The host publishes snapshots at its configured remote rate — 15, 30 or 60 Hz,
default 30 — which is a property of the link and not of either screen's refresh
rate.

**If a client's socket still has an unflushed write when the next frame comes
round, that client's frame is dropped rather than queued.** A meter is a picture
of *now*. A display that has fallen behind and then works through a backlog is
showing, with total confidence, what the signal did half a second ago — and
unlike a dropped frame, nothing about it looks wrong. Dropping is the honest
failure and it is also self-correcting: the next frame the client can take is
current.

**A client that has received no `SNAPSHOT` for 2 seconds declares the link
stale.** Every reading becomes unavailable, the meters go to em dashes, and the
UI says the link is stale. It does not keep the last frame on screen. A frozen
meter is indistinguishable from a quiet passage, which means a display left
running after the host slept would show a plausible reading of a signal that
stopped existing.

## Discovery

The host advertises `_oaa._tcp.local` over mDNS / DNS-SD (RFC 6762, 6763) with
the instance name the user gave it. TXT records:

| key | value |
|---|---|
| `v` | protocol version, decimal |
| `name` | the host's display name, UTF-8 |
| `sr` | sample rate in Hz, decimal, or absent if not yet settled |
| `ch` | channel count, decimal |

The port comes from the SRV record. Typing an IP address is also supported and
always will be: multicast is the first thing a guest network blocks, and a
display that only works when discovery works is a display that fails in exactly
the rooms it is needed in.
