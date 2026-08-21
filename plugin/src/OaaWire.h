/*
 * OaaWire.h — the Open Audio Analyzer wire protocol, producer side.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * ---------------------------------------------------------------------------
 * This file is not the specification
 *
 * `docs/WIRE.md` is. It is owned by the remote-display work, it defines the
 * byte layout normatively, and this file is one implementation of it — the
 * C++ producer. The Dart implementation in `packages/oaa_wire/` is another.
 * If the two ever disagree, the document is right and whichever of us drifted
 * is wrong. Do not "fix" a mismatch by editing only this file.
 *
 * ---------------------------------------------------------------------------
 * Why the snapshot is serialised field by field instead of memcpy'd
 *
 * `oaa_snapshot` is a plain-old-data struct with no pointers, and on every
 * platform Open Audio Analyzer targets it happens to contain no padding at all
 * — `oaa.h` puts its two 8-byte members first and everything after is 4-byte,
 * so the layout is dense and `sizeof` is exactly the wire size. A memcpy would
 * be correct today, and it would be measurably faster.
 *
 * It is still the wrong call, for a reason that has nothing to do with speed:
 * the other end of this socket may be a tablet running pure Dart with no
 * engine, no C compiler and no struct. It cannot memcpy anything. The moment
 * the wire is defined as "whatever the C struct happens to look like", the
 * protocol is no longer implementable by the consumer it exists to serve.
 *
 * So the wire has its own frozen layout, this writes it explicitly, and the
 * `static_assert` below is the tripwire: it does not make the memcpy safe, it
 * makes an *appended field* fail the build. That is the case worth catching.
 * A field added to `oaa_snapshot` must be a deliberate protocol-version
 * decision, never something the wire silently starts carrying — or stops.
 *
 * ---------------------------------------------------------------------------
 * NaN is data
 *
 * A measurement the engine did not compute is NaN in the snapshot, and it must
 * be NaN on the wire. Do not normalise it, clamp it, or substitute zero on the
 * way out: zero is a legitimate reading for correlation, balance and several dB
 * quantities, and a consumer that receives 0.0 has no way left to know nobody
 * measured it. Copying the bit pattern verbatim is the whole requirement.
 */

#pragma once

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

#include <oaa/oaa.h>

/* Deliberately free of any JUCE include.
 *
 * The protocol is the contract between the plugin and the app, and the app end
 * is Dart. Keeping this translation unit to liboaa and the standard library
 * means the wire format can be unit-tested by a plain C++ test binary with no
 * framework attached — which is what `plugin/test/` does, and which is the only
 * reason a byte-layout test is cheap enough to actually keep running. */

namespace oaa::wire {

/* --------------------------------------------------------------------- */
/* Envelope                                                               */
/* --------------------------------------------------------------------- */

/* 'O','A','A','W' read as little-endian. Present on every frame rather than
 * only at connect time, so a reader that joins a stream mid-flight — or one
 * that lost sync after a short write — can hunt forward for the next frame
 * boundary instead of tearing down the connection. */
inline constexpr uint32_t kMagic = 0x5741414Fu;

/* The protocol version, which is deliberately NOT OAA_ABI_VERSION.
 *
 * They move for different reasons and coupling them would be a mistake in both
 * directions: the engine's ABI changes when C callers must recompile, the wire
 * changes when the bytes on the socket change. An additive ABI bump that leaves
 * `oaa_snapshot` untouched — which is exactly what the file-decoding work is —
 * must not invalidate a link that would have worked perfectly. */
inline constexpr uint16_t kProtocolVersion = 2;

enum class FrameType : uint16_t {
  Hello        = 0x0001,
  Layout       = 0x0002,
  Snapshot     = 0x0003,
  Skin         = 0x0004,

  /* 0x0010-0x001F belongs to the plugin. */
  DawTransport = 0x0010,
};

/* magic u32 | version u16 | type u16 | payload length u32 */
inline constexpr size_t kHeaderBytes = 12;

/* --------------------------------------------------------------------- */
/* Payload sizes, frozen at protocol version 1 and unchanged in version 2 */
/* --------------------------------------------------------------------- */

inline constexpr size_t kSnapshotBytes  = 15056;
inline constexpr size_t kTransportBytes = 88;

/* HELLO is the one variable-length frame: a fixed block, then a UTF-8 name. */
inline constexpr size_t kHelloFixedBytes = 32;

/*
 * If this fires, somebody appended a field to `oaa_snapshot`.
 *
 * That is allowed — `oaa.h` explicitly invites it — but it is a protocol event,
 * not a detail. Adding the field to the wire silently would leave every
 * already-built consumer reading a frame whose trailing bytes it does not know
 * about; omitting it silently would leave the wire quietly lagging the engine.
 * Neither is a decision to make by accident, which is why this is a build
 * failure and not a runtime check.
 *
 * The fix is to bump `kProtocolVersion`, add the field to the version-2 table
 * in docs/WIRE.md, and update both implementations together.
 */
static_assert(sizeof(oaa_snapshot) == kSnapshotBytes,
              "oaa_snapshot changed size. See the comment above: this is a "
              "wire-protocol version decision, not a mechanical fix.");

/* --------------------------------------------------------------------- */
/* DAW transport                                                          */
/* --------------------------------------------------------------------- */

/*
 * Transport is metadata, not measurement, which is why it lives here and not
 * in `oaa_snapshot`.
 *
 * The engine measures audio and knows nothing about hosts; giving it a
 * playhead field would mean every consumer that has no DAW — the device
 * capture path, the file analyser, the conformance suite — carries a field
 * that is permanently meaningless, and the engine would need an API to set it.
 * That API is the moment `engine/` learns what a DAW is, and it does not get
 * to know.
 */
enum TransportFlags : uint32_t {
  kPlaying        = 1u << 0,
  kRecording      = 1u << 1,
  kLooping        = 1u << 2,
  kHasTimeSeconds = 1u << 3,
  kHasPpq         = 1u << 4,
  kHasBpm         = 1u << 5,
  kHasTimeSig     = 1u << 6,
  kHasTimecode    = 1u << 7,
  kHasTimeSamples = 1u << 8,
  kHasLoopPoints  = 1u << 9,
  kHasBarStart    = 1u << 10,

  /*
   * The playhead did not arrive where the previous block left it: the user
   * relocated, looped, or scrubbed.
   *
   * This is the one transport flag that is about a *measurement* rather than
   * about the host, and it is here because nothing else can see it. Consider
   * somebody who plays bars 1–16, stops, drags back to bar 1 and plays again.
   * The engine has been fed both passes and its integrated loudness is now the
   * average of two takes of the same music, reported as one programme. Nothing
   * about that number looks wrong.
   *
   * It is the same class of problem as `dropped_frames` — an integrated reading
   * that describes different audio than the listener thinks — and it gets the
   * same treatment: say so, and let the consumer decide. The plugin does **not**
   * reset the engine on its own, because whether a relocate should restart the
   * integration is a property of the LUFS mode the user picked, and the mode
   * lives in the app. Continuous is supposed to span the whole session.
   *
   * Acting on this needs the app→plugin control channel (frame types
   * 0x0020–0x002F), which does not exist in protocol version 2. Until it does,
   * a consumer can report that the integrated reading spans a discontinuity,
   * which is considerably better than quietly averaging two takes.
   */
  kDiscontinuity  = 1u << 11,
};

/*
 * Every optional value carries a presence bit, and the reason is worth stating
 * because it looks like over-engineering until it bites.
 *
 * JUCE's `PositionInfo` returns an `Optional` from every getter, and hosts vary
 * enormously in what they actually fill in — plenty report a sample position
 * and no BPM, or a BPM and no timecode origin. A missing value that arrives as
 * 0.0 is indistinguishable from a real 0.0, and "bar 1, beat 1, 00:00:00:00"
 * is a perfectly plausible-looking readout to show somebody while the host is
 * parked at bar 57. That is an invented measurement in everything but name.
 *
 * So: bit clear means the host did not say, the field is zero, and the display
 * shows an em dash.
 */
/*
 * Timecode frame rate, using the values of `juce::AudioPlayHead::FrameRateType`
 * verbatim:
 *
 *   0 = 23.976   3 = 29.97      6 = 30 drop    99 = unknown
 *   1 = 24       4 = 30         7 = 60
 *   2 = 25       5 = 29.97 drop 8 = 60 drop
 *
 * Note that "unknown" is 99 and not 8 — 8 is a real rate. JUCE 8's own API has
 * moved on to a `FrameRate` class carrying a base rate plus drop and pull-down
 * flags, which is a better model; the plugin maps to these integers on the way
 * out so that the wire stays a plain `u32` that a Dart consumer can switch on
 * without reimplementing the class. The mapping lives in OaaPluginProcessor.cpp.
 */
inline constexpr uint32_t kFrameRateUnknown = 99;

struct Transport {
  uint32_t flags               = 0;
  uint32_t frameRate           = kFrameRateUnknown;
  double   timeSeconds         = 0.0;
  double   ppqPosition         = 0.0;
  double   ppqBarStart         = 0.0;
  double   bpm                 = 0.0;
  double   editOriginSeconds   = 0.0;
  double   loopStartPpq        = 0.0;
  double   loopEndPpq          = 0.0;
  int64_t  timeSamples         = 0;
  uint32_t timeSigNumerator    = 0;
  uint32_t timeSigDenominator  = 0;
  uint32_t hostFrames          = 0;
  uint32_t reserved            = 0;
};

/* --------------------------------------------------------------------- */
/* Writing                                                               */
/* --------------------------------------------------------------------- */

/*
 * Appends little-endian primitives to a byte vector.
 *
 * Explicitly little-endian rather than "whatever this compiler does", even
 * though every platform Open Audio Analyzer targets is little-endian today. The
 * cost is a few shifts on a path that runs fifty times a second; the
 * alternative is a protocol whose correctness rests on an unstated assumption,
 * which is the kind of thing that holds for years and then does not.
 */
class ByteWriter {
public:
  explicit ByteWriter(std::vector<uint8_t>& out) : out_(out) {}

  void u8(uint8_t v)   { out_.push_back(v); }
  void u16(uint16_t v) { for (int i = 0; i < 2; ++i) out_.push_back(uint8_t(v >> (8 * i))); }
  void u32(uint32_t v) { for (int i = 0; i < 4; ++i) out_.push_back(uint8_t(v >> (8 * i))); }
  void u64(uint64_t v) { for (int i = 0; i < 8; ++i) out_.push_back(uint8_t(v >> (8 * i))); }
  void i64(int64_t v)  { u64(static_cast<uint64_t>(v)); }

  /* Bit-cast, not a numeric conversion — see the NaN note in the file header.
   * A float that is NaN must arrive as the same NaN, and anything that goes
   * through arithmetic on the way risks quieting a signalling NaN or, worse,
   * being "helpfully" clamped by an optimiser. */
  void f32(float v)  { uint32_t b; std::memcpy(&b, &v, 4); u32(b); }
  void f64(double v) { uint64_t b; std::memcpy(&b, &v, 8); u64(b); }

  void f32Array(const float* v, size_t n) { for (size_t i = 0; i < n; ++i) f32(v[i]); }
  void u32Array(const uint32_t* v, size_t n) { for (size_t i = 0; i < n; ++i) u32(v[i]); }

private:
  std::vector<uint8_t>& out_;
};

/* Writes the 12-byte envelope for a payload of `payloadBytes`. */
void writeHeader(std::vector<uint8_t>& out, FrameType type, uint32_t payloadBytes);

/*
 * Serialises `snapshot` into `out` as a complete SNAPSHOT frame, envelope
 * included. `out` is cleared first and reused across calls — it is owned by the
 * streaming thread and sized once, so the steady state allocates nothing.
 *
 * `extraDroppedFrames` is added to the snapshot's own `dropped_frames`, and
 * sets OAA_FLAG_OVERRUN when it is non-zero. It exists because in a plugin the
 * engine cannot see every way audio can be lost.
 *
 * The engine's counter reports what *its* capture ring dropped, and in push
 * mode that ring is not used at all — the host hands us the audio directly.
 * The loss that can actually happen here is in the plugin's own FIFO, between
 * the DAW's audio thread and the streaming thread, and the engine has no way
 * to learn about it.
 *
 * Folding it in is not editing a measurement. `dropped_frames` is defined as
 * "audio lost before it was measured, since the last reset", and that is
 * exactly what these frames are; the only thing peculiar about them is which
 * component noticed. Reporting them separately would mean a consumer had to
 * know to add two numbers together to find out whether the integrated reading
 * is trustworthy, and a consumer that did not know would show a clean meter
 * over audio with a hole in it.
 */
void writeSnapshotFrame(std::vector<uint8_t>& out, const oaa_snapshot& snapshot,
                        uint32_t extraDroppedFrames = 0);

/* Likewise for DAW_TRANSPORT. Sent immediately before the snapshot frame it
 * describes, so a consumer that has both applies them to the same instant. */
void writeTransportFrame(std::vector<uint8_t>& out, const Transport& transport);

/*
 * The HELLO frame, sent once on connect.
 *
 * Carries the snapshot payload size and the producer's ABI version, and the
 * asymmetry between them is intentional. A **size** mismatch means the two ends
 * disagree about the byte layout of a frame, which produces a shifted read and
 * plausible wrong numbers — so it refuses the connection. An **ABI** mismatch
 * means the engines were built from different headers, which is worth showing
 * a human but is not by itself a reason to refuse: an additive ABI bump leaves
 * the wire byte-identical, and rejecting a link that would have worked is its
 * own kind of wrong answer.
 */
/*
 * `abiVersion` defaults to this build's and should be left alone outside the
 * fixture, which pins it so that an engine ABI bump — an event with no effect
 * whatsoever on these bytes — cannot fail a wire test. That the two numbers can
 * be pinned apart is the point being made: they move for different reasons.
 */
void writeHelloFrame(std::vector<uint8_t>& out, const char* producerName,
                     uint32_t abiVersion = OAA_ABI_VERSION);

}  // namespace oaa::wire
