# The Open Audio Analyzer wire protocol

**Protocol version 4.** This document is normative. Where an implementation and
this file disagree, this file is right and the implementation has a bug.

**Version 4 is the first version to change a measurement table**, and it is the
first that a version-3 consumer cannot read. The five arrays a module *plots* —
`spectrum`, `spectrum_peak`, `spectrum_pan`, `scope`, `histogram` — are
fixed point rather than `float32`, which takes the snapshot payload from 15,056
bytes to **7,652** for one analysis block: 95 % of the frame was those five
arrays, and none of their values is ever shown to a person as a number.
Everything that *is* shown as a number — every scalar, and `peak`, `rms`, `vu`,
`clip` — is still `float32`. See
[Fixed point](#fixed-point-the-arrays-that-are-only-ever-drawn).

**Version 4 also makes `scope` variable-length, and moves it last.** A frame
carries the audio that actually elapsed since the previous one instead of a
fixed 1,024 frames, because a link running slower than the engine measures
cannot otherwise send a contiguous waveform — see
[The scope run](#the-scope-run). Every other offset is fixed.

A version-4 consumer still reads the version 1–3 table, and must: see
[Version compatibility](#version-compatibility). A version-3 *consumer* meeting
a version-4 producer refuses at the handshake, on the payload size, which is
the designed behaviour and produces a sentence naming both numbers.

Version 2 differed from version 1 in one field: the magic, which spells the
application's name and moved when the name did. Every other table was the
version-1 table unchanged, byte for byte. The version still had to move — a
frozen table is frozen including its magic, and a display that read version 1
must refuse this stream rather than hunt for a frame boundary that will never
match.

**Version 3 adds the first frame that travels from consumer to producer**:
`0x0020 SET_LUFS_MODE`, which is what makes the Elapsed and Timecode loudness
modes possible. Every version-2 table below is unchanged, byte for byte — v3
adds a frame type and changes no existing one — so a version-2 frame is a valid
version-3 frame and the compatibility rule below is what lets the two meet.
It is permitted **on the ingest port only**, for the reasons in
[trust boundary](#they-do-not-have-the-same-trust-boundary).

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

**The display port is deliberately one-directional.** A remote display cannot
reset the host's integrated loudness, cannot change its device and cannot load a
preset on it, in version 4 exactly as in versions 2 and 3. That is not an omission to
be filled in later without thought: a read-only stream has no attack surface
beyond the measurements it already publishes, and adding a control channel there
is the change that turns "a screen in the live room shows the mix engineer's
meters" into "anyone on the venue Wi-Fi can reset the mix engineer's
measurement". It needs an authentication story before it happens, and it does
not have one.

The **ingest** port is the other case, and version 3 is where the distinction
starts to pay. It is loopback, the peer is a plugin running as this user, and
`0x0020` travels app → plugin over it. The frame range `0x0020`–`0x002F` remains
closed to the display port at every version.

**There is no authentication and no encryption.** Anyone who can reach the port
can read the measurements and the layout. That is an acceptable trade for a
LAN-only display feature, and it is the reason the host does not listen unless a
human turns it on.

## Who talks, and on which port

The protocol has a **producer** — whatever is measuring — and a **consumer**,
whatever is drawing. The producer sends `HELLO` first and then everything else.
The consumer sends nothing at all on the display port, and on the ingest port
sends only `0x0020`. Which of the two opened the TCP connection is a separate
question, and Open Audio Analyzer needs it both ways round:

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
`0x0003`. Version 2 defined none; version 3 defines exactly one,
[`0x0020`](#0x0020--set_lufs_mode).

**A consumer must not send `0x0020` on the display port, and a producer must
reject it there.** The rule is enforced at the port rather than trusted to the
sender, because the whole argument above rests on which interface the socket is
bound to and nothing else.

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
| 4 | `u16` | protocol version, currently `3` |
| 6 | `u16` | frame type |
| 8 | `u32` | payload length in bytes |
| 12 | … | payload |

**A receiver skips a frame type it does not know, by length.** It does not error
and it does not close the connection. This is what lets a plugin that sends DAW
transport talk to a display build that predates transport — the frames it does
not understand cost it a `seek` and nothing else.

**A payload longer than 1 MiB is rejected and the connection is dropped.** A
length field is an instruction to allocate, and a corrupt or hostile one that
says four gigabytes must not be obeyed. Nothing in version 4 comes close to the
cap; the largest legitimate frame is a snapshot at 19,952 bytes — a full 4,096-
pair scope run — and 7,664 in the ordinary one-block case.

### Version compatibility

**A receiver accepts any version it knows and refuses the ones it does not.**
Concretely: a frame whose version is greater than the receiver's own is refused
and the connection dropped, because a higher version may have moved a table the
receiver would then misread. A frame whose version is *lower* is accepted, and
decoded with that version's tables — which for 2 against 3 are the same tables,
and for 1–3 against 4 are the frozen table in
[the version 1–3 snapshot](#the-version-13-snapshot-table).

This replaces the equality check versions 1 and 2 used, and it is a change to
the framing rules rather than to any byte layout. Equality was survivable while
the app and the display shipped as one binary from one release. It stopped being
survivable at version 3, because the **plugin does not**: it is copied into the
DAW's own plugin folder by hand and stays there across app upgrades, so an app
one version ahead of the plugin in somebody's VST3 directory is the normal case
and not an edge one. Under equality, the first app to speak version 3 would
have refused every plugin already installed — with the plugin retrying forever
against a port that hangs up on it, which looks exactly like the bug where the
port was never bound at all.

**The peer's version is remembered, and it gates what may be sent to it.** A
producer announces its version in `HELLO`; the consumer records it and must not
send a frame the producer is too old to understand. A version-2 plugin never
reads its socket, so `0x0020` sent to one would not be refused — it would be
silently ignored, which is worse: the app would believe a mode was in force and
the plugin would go on measuring continuously, and the reading on screen would
be wrong with nothing anywhere saying so. So the modes that need `0x0020` are
reported **unavailable** against a version-2 producer rather than requested.

## Frame types

| type | name | direction | when |
|---|---|---|---|
| `0x0001` | `HELLO` | host → client | first frame on every connection |
| `0x0002` | `LAYOUT` | host → client | after `HELLO`, and whenever the layout changes |
| `0x0003` | `SNAPSHOT` | host → client | at the publish rate |
| `0x0004` | `SKIN` | host → client | after `HELLO`, and whenever the skin changes |
| `0x0005` | `CALIBRATION` | host → client | after `HELLO`, and whenever the target changes |
| `0x0010`–`0x001F` | plugin transport | producer → app, app → client | see [DAW transport](#0x0010--daw_transport) |
| `0x0020` | `SET_LUFS_MODE` | app → producer | ingest port only; on change, and once per connection |
| `0x0021`–`0x002F` | *reserved* | — | the rest of the control range, undefined |

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

**Payload is `3,556 + 4 x scope_frames` bytes at protocol version 4** — 7,652
for the one analysis block every measuring producer sends — and was exactly
15,056 at versions 1 to 3. A consumer must accept both shapes and decode each
with its own table; a producer writes only its own version's.

A payload that is neither 15,056 nor `3,556 + 4n` for some `0 <= n <= 4096` is
refused, and so is one whose `scope_frames` disagrees with its length. The
length and the count are two statements of the same fact and a receiver must not
pick one: reading past the payload draws whatever the previous frame left
there.

The version 1–3 layout was *derived* mechanically, so that two hand-written
serialisers could not drift: take `oaa_snapshot` from `engine/include/oaa/oaa.h`
at `OAA_ABI_VERSION` 3, walk it top to bottom in declaration order, emit every
member including the `reservedN` padding members, each in its natural width,
little-endian, with no alignment padding between members.

**That derivation produced the tables below, and the tables are what is
normative — not the current contents of `oaa.h`.** The distinction is the whole
reason this is not a struct copy. `oaa_snapshot` will grow: fields get appended
and `OAA_ABI_VERSION` is bumped, which is a private matter between the engine
and the things that link it. The wire layout changes only when the *protocol*
version changes. If the two were the same thing, every engine change would
silently break every remote display in the field, and it would break them by
drawing wrong numbers rather than by failing.

**Version 4 ends the coincidence that made a struct copy possible at all.** The
five plotted arrays are two bytes an element on the wire and four in the struct,
so a producer must walk the fields. Field *order* is unchanged; every offset
after `clip` moved.

#### The version 4 snapshot table

| off | type | field | | off | type | field |
|---|---|---|---|---|---|---|
| 0 | `u64` | `generation` | | 88 | `f32` | `correlation` |
| 8 | `f64` | `elapsed_seconds` | | 92 | `f32` | `balance` |
| 16 | `u32` | `sample_rate` | | 96 | `f32[8]` | `peak` |
| 20 | `u32` | `channels` | | 128 | `f32[8]` | `rms` |
| 24 | `u32` | `flags` | | 160 | `f32[8]` | `vu` |
| 28 | `u32` | `dropped_frames` | | 192 | `u32[8]` | `clip` |
| 32 | `f32` | `lufs_momentary` | | 224 | `u16[512]` | `spectrum` |
| 36 | `f32` | `lufs_short` | | 1248 | `u16[512]` | `spectrum_peak` |
| 40 | `f32` | `lufs_integrated` | | 2272 | `f32` | `lra_low` |
| 44 | `f32` | `lra` | | 2276 | `f32` | `lra_high` |
| 48 | `f32` | `true_peak` | | 2280 | `f32` | `lra_gate` |
| 52 | `f32` | `true_peak_max` | | 2284 | `f32` | `reserved3` |
| 56 | `f32` | `sample_peak_max` | | 2288 | `i16[512]` | `spectrum_pan` |
| 60 | `f32` | `reserved1` | | 3312 | `u16[120]` | `histogram` |
| 64 | `f32` | `dr_short` | | 3552 | `u32` | `scope_frames` |
| 68 | `f32` | `dr_integrated` | | 3556 | `i16[2n]` | `scope` |
| 72 | `f32` | `crest` | | | | |
| 76 | `f32` | `plr` | | **3556+4n** | | **total** |
| 80 | `f32` | `psr` | | | | |
| 84 | `f32` | `reserved2` | | | | |

#### The scope run

`scope_frames` is the number of stereo pairs in `scope`, and `scope` is `2 x
scope_frames` `i16` samples, interleaved x=left, y=right, oldest first. At most
**4,096** pairs.

**A producer that measures sends one analysis block — 1,024 pairs — and nothing
else.** The plugin is always that, and so is the app's own engine: a snapshot is
published once per block.

**A producer that relays sends what elapsed.** The app publishing to a remote
display is the only one, and it is why this field exists. Its link runs at 15,
30 or 60 Hz while the engine measures at about 47, so at the default 30 Hz one
frame stands for 1,600 frames of audio at 48 kHz where a block carries 1,024. A
relay that forwarded the newest block would deliver 64 % of the waveform, and
the consuming oscilloscope — which works out how much audio arrived from
`elapsed_seconds` — would correctly conclude its buffer was no longer
contiguous and reset it. On every frame. So a relay accumulates what it measured
between two sends and says how much that was.

**The cap is a real limit, not a formality.** 4,096 pairs covers 48 kHz at the
slowest link rate with headroom, and does not cover 96 kHz there. Past it the
run is truncated **oldest-first** — a display drawing the recent past is right
and one drawing a stale window is not — and the consumer, finding less audio
than elapsed, draws the shortfall as the gap it is rather than inventing
samples.

`HELLO` advertises the payload size for a *one-block* frame, so that two builds
still compare a single integer.

#### The version 1–3 snapshot table

Frozen. A version-4 consumer decodes a producer that announces 15,056 bytes with
this table, which is what keeps a plugin working across an app upgrade.

| off | type | field | | off | type | field |
|---|---|---|---|---|---|---|
| 0–223 | | *identical to the table above* | | 4320 | `f32` | `lra_low` |
| 224 | `f32[512]` | `spectrum` | | 4324 | `f32` | `lra_high` |
| 2272 | `f32[512]` | `spectrum_peak` | | 4328 | `f32` | `lra_gate` |
| 4336 | `f32[512]` | `spectrum_pan` | | 4332 | `f32` | `reserved3` |
| 6384 | `f32[2048]` | `scope` | | | | |
| 14576 | `f32[120]` | `histogram` | | **15056** | | **total** |

At versions 1–3, `sizeof(oaa_snapshot)` was *also* 15,056 with no internal
padding on every platform Open Audio Analyzer targets, so a C or C++ producer
could `memcpy` the struct behind
`static_assert(sizeof(oaa_snapshot) == 15056)`. **That is no longer true at
version 4** and the assert in `plugin/src/OaaWire.h` is now a tripwire on the
struct rather than a licence to copy it.

#### Fixed point: the arrays that are only ever drawn

**The rule is narrow: a number a person reads stays exact.** Every scalar, and
`peak`, `rms`, `vu` and `clip`, are `float32` at version 4 exactly as before —
those are what a delivery decision is made from, and they are 128 bytes. The
five quantised arrays are never displayed as numbers; they become pixels.

| array | code | encoding | resolution |
|---|---|---|---|
| `spectrum`, `spectrum_peak` | `u16` | `round((dB + 160) * 256)`, clamped to `0..0xFFFE` | 1/256 dB |
| `spectrum_pan` | `i16` | `round(v * 32767)`, clamped to `±32767` | 3.1e-5 |
| `scope` | `i16` | Q1.14: `round(v * 16384)`, clamped to `±32767` | 6.1e-5, range ±1.9999 |
| `histogram` | `u16` | `round(v * 0xFFFE)`, clamped to `0..0xFFFE` | 1.5e-5 |

Each width was chosen against the widest consumer rather than rounded to a
convenient number. The spectrum analyser resolves about 0.204 dB per pixel at a
default size on a 1920-wide canvas and the spectrogram quantises to 1.625 dB
itself, against a 1/256 dB step here. A goniometer needs about ten bits to put a
sample on the right pixel, against Q1.14's fourteen.

`scope` keeps headroom past full scale deliberately: a float file may
legitimately exceed it, and folding an intersample peak back inside the circle
would draw a limiter that is not there.

**Clamp before rounding.** `-INFINITY` is an ordinary value here — it is what
digital silence is — and rounding it is undefined in C and throws in Dart.

**Each encoding reserves a code for NaN, outside its value range:** `0xFFFF` for
the two unsigned encodings, `0x8000` (−32768) for the two signed ones. See
below, and note that this is the only thing about version 4 that could have
broken the rule the protocol is built on.

`flags` are the `OAA_FLAG_*` bits from `oaa.h`: `1<<0` running, `1<<1` loudness
unavailable, `1<<2` spectrum unavailable, `1<<3` overrun.

Reserved members are transmitted and ignored. Carrying them means a future
field that fills a reserved slot moves nothing, and a receiver that ignores them
costs nothing.

#### NaN is data

**A quantity the producer did not measure is transmitted as NaN**, and it
arrives as NaN. Not zero, not the dB floor, not omitted.
Zero is a legitimate reading for correlation, balance and several dB quantities,
so it cannot double as "no data", and a display that draws a substituted zero is
showing a number nobody measured. The receiving end renders an em dash.

This is the one rule in this document that is worth breaking a build over, and
version 4 is where it was nearly lost: fixed point has no NaN of its own, so
each encoding above reserves a code for it and excludes that code from its value
range. A band that arrived as the floor instead would draw a spectrum flat along
the bottom — a picture of silence, which is a measurement nobody took.

### `0x0010` — DAW_TRANSPORT

Where the audio sits on a DAW's timeline. Emitted by a plugin producer
immediately before each `0x0003 SNAPSHOT`; absent entirely when the producer has
no DAW. Payload is 88 bytes.

Transport is metadata, not measurement, which is why it rides in its own frame
and never in `oaa_snapshot`: the engine must not learn what a DAW is.

**It travels in both directions, and not on the same schedule.** An app that is
metering a plugin relays the playhead to its displays, because a tablet showing
a DAW's meters and no position is a tablet that cannot be used to say where the
session is. On the display port the frame is the same 88 bytes and the rules
around it differ:

| | producer → app | app → client |
|---|---|---|
| when | before every `0x0003` | on change, and once on connect |
| `flags == 0` | never sent — the producer omits the frame | sent, meaning "there is no playhead here" |

Sending on change is what keeps a parked session and a machine with no DAW at
all off the wire; the replay on connect is what stops a display that attached to
a parked session from showing nothing until somebody presses play. A `flags == 0`
frame is how a relay says the playhead has *gone* — the plugin was removed, or
the app went back to metering a sound card — and it must be sent, because a
display that is told nothing holds the last position it was given.

**A consumer must not assume it has seen every producer frame.** The relay
samples: the app publishes at the display rate, which is slower than a DAW's
block rate, so intermediate positions do not survive the hop. The one thing that
does is `DISCONTINUITY`, and the paragraphs below say why that is not optional.

Neither direction of *this* frame needed a version past 2, and neither has
changed in 3. A display that predates transport skips the frame by length and is
otherwise unaffected, and a display that expects one and never receives it is
looking at a host with no DAW, which is a state it already has to draw. What
version 3 adds is a frame in the opposite direction, on the other port —
`0x0020`, which consumes this one.

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

**Anything that forwards transport is a producer for the purposes of both rules
above.** A relay publishes less often than it is fed, exactly as a plugin does,
so it must accumulate the bit between the frames it sends rather than copy
whatever the last one it received happened to say — and clear it once it has
gone out. The app does this in `DisplayHost`, which is why every producer frame
is written to it rather than the publish timer asking for the current position:
at thirty frames a second against a DAW's ninety-odd blocks, two relocates in
three would otherwise be a position that moved and nothing else.

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

### `0x0020` — SET_LUFS_MODE

**Consumer → producer, ingest port only.** What a LUFS integration counts from.
Payload is 24 bytes. New in protocol version 3; a producer that speaks version 2
must never be sent one — see
[version compatibility](#version-compatibility).

| off | type | field | meaning |
|---|---|---|---|
| 0 | `u32` | `mode` | the enum below |
| 4 | `u32` | `flags` | `1<<0 HAS_REGION`; other bits reserved, zero |
| 8 | `f64` | `region_start_seconds` | timeline seconds, same origin as `time_seconds` |
| 16 | `f64` | `region_end_seconds` | timeline seconds, exclusive |

| `mode` | name | counts from |
|---|---|---|
| `0` | `CONTINUOUS` | the last manual reset. The only mode a producer with no transport can honour |
| `1` | `SYSTEM` | the first audio after silence, restarting when the signal stops |
| `2` | `ELAPSED` | the transport starting to roll, holding while it is parked |
| `3` | `TIMECODE` | entry into `[region_start_seconds, region_end_seconds)` |

The values are normative here and the `LufsTimeMode` enum in
`packages/oaa_core/lib/src/transport.dart` is declared in this order so that its
index is its wire value. That coupling is deliberate and load-bearing: it is
also the reason a mode may only ever be *appended* to that enum.

**A region is required for `TIMECODE` and ignored otherwise.** `HAS_REGION`
clear with `mode == 3` is a malformed frame; the producer refuses the frame and
keeps the mode it had, because the alternative is measuring a region nobody
specified. `region_end_seconds` must be greater than `region_start_seconds`.

**"Holding" is not a mode of the analyser — it is the producer declining to feed
it.** A parked transport in `ELAPSED`, or a playhead outside the region in
`TIMECODE`, means the producer stops pushing audio into its engine and goes on
publishing snapshots of it. The integration therefore freezes at the value it
had and stays on screen, rather than either advancing over audio outside the
window or blanking. That is what keeps both transport-driven modes out of
`engine/` entirely: the analyser needs no notion of a playhead to be *not fed*,
and so it still does not know what a DAW is.

`SYSTEM` is the one mode a producer hands to its engine rather than implementing
above it, because silence is a property of audio and not of a host — one
implementation in `engine/` serves the plugin and a local sound card both, and
two would eventually disagree about when a track began.

**Reset points, per mode.** A reset clears every integrating measurement — the
integrated loudness, LRA, the peak maxima, the clip counters — and restarts the
elapsed clock. `CONTINUOUS` resets only when a human asks. `SYSTEM` resets on
the first audio after the silence hold expires. `ELAPSED` resets on the
transport's rolling edge and on `DISCONTINUITY`, because a reading spanning a
relocate is the average of two passes of the same music. `TIMECODE` resets when
the playhead enters the region, from either direction.

**Sent on change, and once per connection**, the second being what makes a
plugin that reconnects mid-session come back in the mode the module is showing
rather than in `CONTINUOUS`.

**A repeated frame carrying the mode already in force does nothing.** Not "resets
again" — nothing. A consumer is allowed to be careless about resending, and a
producer that reset on every arrival would let a redundant send silently restart
a measurement somebody was in the middle of taking. The comparison is over the
whole payload, so a changed region in the same mode *is* a change and does
re-arm.

**A producer with no transport honours `CONTINUOUS` and `SYSTEM` and refuses the
other two**, because it has no clock to tie them to. It keeps the mode it had
and the consumer is expected to know this already from the absence of `0x0010`;
the refusal is the backstop, not the mechanism.

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
