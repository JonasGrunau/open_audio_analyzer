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
#include <cmath>
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
inline constexpr uint16_t kProtocolVersion = 5;

/* The oldest version this build can still decode. Version 3 added a frame type
 * and moved no table, so a version-2 peer is a peer whose every table this
 * build froze unchanged. Version 1 is excluded because its magic differs — a
 * version-1 stream fails on byte zero and never reaches a version check. */
inline constexpr uint16_t kMinimumVersion = 2;

/* Refuse a version above ours: a later one may have moved a table we would then
 * misread, and misreading a measurement table is how a meter draws a confident
 * wrong number. Accept one below, for the reason above. */
inline constexpr bool isKnownVersion(uint16_t version) noexcept {
  return version >= kMinimumVersion && version <= kProtocolVersion;
}

enum class FrameType : uint16_t {
  Hello        = 0x0001,
  Layout       = 0x0002,
  Snapshot     = 0x0003,
  Skin         = 0x0004,

  /* 0x0010-0x001F belongs to the plugin. */
  DawTransport = 0x0010,

  /* 0x0020-0x002F is the control range, and this is the only member of it.
   * Consumer -> producer, so the plugin *receives* this one rather than sending
   * it, and it is the only frame that travels that way. Permitted because the
   * ingest port binds loopback; see docs/WIRE.md on the trust boundary. */
  SetLufsMode  = 0x0020,
};

/* magic u32 | version u16 | type u16 | payload length u32 */
inline constexpr size_t kHeaderBytes = 12;

/* --------------------------------------------------------------------- */
/* Payload sizes                                                          */
/* --------------------------------------------------------------------- */

/* Version 5. The arrays a module *plots* — spectrum, spectrum_peak,
 * spectrum_pan, histogram, scope, and since version 5 the eight per-source
 * spectra — are fixed point rather than float32; every scalar a person reads
 * as a number is still float32. See `quantise` below and the version 5 table
 * in docs/WIRE.md.
 *
 * `scope` is **variable length and last**, carrying however much audio
 * elapsed rather than a fixed block, so that a relay publishing more slowly
 * than the engine measures can still send a contiguous waveform. A plugin is
 * never that relay — it publishes once per analysis block — so what it writes
 * is always exactly one block and `kSnapshotBytes` is a constant here. The
 * per-source spectra sit between `histogram` and the scope count, which is
 * why the base grew by 8,192 from version 4's 3,556. */
inline constexpr size_t kScopeFrames    = 1024;
inline constexpr size_t kSnapshotBase   = 11748;
inline constexpr size_t kSnapshotBytes  = kSnapshotBase + kScopeFrames * 4;

/* What versions 1 to 3 sent. A consumer accepts it — an older plugin outlives
 * an app upgrade — but nothing here writes it any more, and it has not been
 * the size of the C struct since ABI 6 appended the per-source spectra. */
inline constexpr size_t kSnapshotLegacyBytes = 15056;

/* What version 4 sent: the same table as version 5 without the eight
 * per-source arrays. Decode-only on the app side, like the legacy size. */
inline constexpr size_t kSnapshotV4Bytes = 7652;

/* The C struct today — ABI 6, with the eight per-source arrays appended. Not a
 * wire size at any version; see the static_assert below for what it is for. */
inline constexpr size_t kSnapshotStructBytes = 31440;

inline constexpr size_t kTransportBytes = 88;

/* New at protocol version 3. mode u32 | flags u32 | start f64 | end f64 */
inline constexpr size_t kLufsModeBytes  = 24;

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
 * The fix is to bump `kProtocolVersion`, add the field to the current table
 * in docs/WIRE.md, and update both implementations together — which is what
 * version 5 did when ABI 6 appended the per-source spectra, and why the
 * number below moved from 15,056 to 31,440 in the same change.
 *
 * Note what this does not say. Up to version 3 the wire happened to be
 * `sizeof(oaa_snapshot)` and a producer could memcpy the struct behind this
 * assert; since version 4 it cannot, because the plotted arrays are two bytes
 * per element on the wire and four in the struct. The guard is still worth
 * having for exactly the reason above — it is the tripwire on the struct, not
 * on the frame — so it is written against the struct's own size.
 */
static_assert(sizeof(oaa_snapshot) == kSnapshotStructBytes,
              "oaa_snapshot changed size. See the comment above: this is a "
              "wire-protocol version decision, not a mechanical fix.");

/* --------------------------------------------------------------------- */
/* Fixed point, for the arrays that are only ever drawn                   */
/* --------------------------------------------------------------------- */

/*
 * The other half of `packages/oaa_wire/lib/src/quantise.dart`. That file
 * carries the reasoning — which consumer set each width, and why a display
 * cannot tell the difference; this is the same arithmetic so that two
 * implementations written against the document produce the same bytes.
 *
 * **The rule is narrow on purpose: a number a person reads stays exact.** Every
 * scalar, and `peak`/`rms`/`vu`/`clip`, are still float32. Only the five
 * plotted arrays are quantised.
 *
 * **NaN survives.** An unmeasured quantity travels as NaN and is drawn as an em
 * dash — zero is a real reading for several of these — so each encoding
 * reserves a code that is outside its value range.
 */
inline constexpr uint16_t kDbNaN       = 0xFFFF;
inline constexpr uint16_t kDbMax       = 0xFFFE;
inline constexpr float    kDbOrigin    = -160.0f;
inline constexpr float    kDbStep      = 256.0f;

inline constexpr int16_t  kUnitNaN     = -32768;
inline constexpr int32_t  kUnitScale   = 32767;

inline constexpr int16_t  kSampleNaN   = -32768;
inline constexpr float    kSampleScale = 16384.0f;
inline constexpr int32_t  kSampleMax   = 32767;

inline constexpr uint16_t kFractionNaN = 0xFFFF;
inline constexpr int32_t  kFractionMax = 0xFFFE;

/* std::lround and Dart's num.round() both round half away from zero, which is
 * what makes these two implementations agree on the boundary cases. */
inline uint16_t quantiseDb(float v) {
  if (std::isnan(v)) return kDbNaN;
  /* Clamped before rounding: std::lround of an infinity is undefined, and
   * -INFINITY is an ordinary reading here — it is what digital silence is. */
  const double scaled = (double(v) - kDbOrigin) * kDbStep;
  if (!(scaled > 0.0)) return 0;
  if (scaled >= double(kDbMax)) return kDbMax;
  return static_cast<uint16_t>(std::lround(scaled));
}

inline int16_t quantiseUnit(float v) {
  if (std::isnan(v)) return kUnitNaN;
  const double scaled = double(v) * kUnitScale;
  if (scaled <= double(-kUnitScale)) return static_cast<int16_t>(-kUnitScale);
  if (scaled >= double(kUnitScale)) return static_cast<int16_t>(kUnitScale);
  return static_cast<int16_t>(std::lround(scaled));
}

inline int16_t quantiseSample(float v) {
  if (std::isnan(v)) return kSampleNaN;
  const double scaled = double(v) * kSampleScale;
  if (scaled <= double(-kSampleMax)) return static_cast<int16_t>(-kSampleMax);
  if (scaled >= double(kSampleMax)) return static_cast<int16_t>(kSampleMax);
  return static_cast<int16_t>(std::lround(scaled));
}

inline uint16_t quantiseFraction(float v) {
  if (std::isnan(v)) return kFractionNaN;
  const double scaled = double(v) * kFractionMax;
  if (!(scaled > 0.0)) return 0;
  if (scaled >= double(kFractionMax)) return static_cast<uint16_t>(kFractionMax);
  return static_cast<uint16_t>(std::lround(scaled));
}

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
   * Acting on it arrived with protocol version 3 and `SetLufsMode`: in Elapsed
   * the plugin now resets on this edge, because a reading spanning a relocate is
   * the average of two passes of the same music. In Continuous it still does
   * nothing at all — Continuous is supposed to span the whole session — and a
   * consumer that only reports the discontinuity remains correct for that mode.
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

  void i16(int16_t v) { u16(static_cast<uint16_t>(v)); }

  /* The version 4 arrays. See `quantise*` above. */
  void dbArray(const float* v, size_t n) { for (size_t i = 0; i < n; ++i) u16(quantiseDb(v[i])); }
  void unitArray(const float* v, size_t n) { for (size_t i = 0; i < n; ++i) i16(quantiseUnit(v[i])); }
  void sampleArray(const float* v, size_t n) { for (size_t i = 0; i < n; ++i) i16(quantiseSample(v[i])); }
  void fractionArray(const float* v, size_t n) { for (size_t i = 0; i < n; ++i) u16(quantiseFraction(v[i])); }

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
/* --------------------------------------------------------------------- */
/* SET_LUFS_MODE — the one frame that arrives                             */
/* --------------------------------------------------------------------- */

/*
 * What a LUFS integration counts from. New at protocol version 3.
 *
 * The integers are the wire values and docs/WIRE.md freezes them; the Dart
 * `LufsTimeMode` is declared in this order so that its index matches. Append
 * only — reordering these is a protocol change wearing the clothes of a
 * tidy-up.
 */
enum class LufsTimeMode : uint32_t {
  Continuous = 0,
  System     = 1,
  Elapsed    = 2,
  Timecode   = 3,
};

inline constexpr uint32_t kLufsModeHasRegion = 1u << 0;

/* A decoded SET_LUFS_MODE. */
struct LufsModeRequest {
  LufsTimeMode mode      = LufsTimeMode::Continuous;
  bool         hasRegion = false;
  double       startSeconds = 0.0;
  double       endSeconds   = 0.0;

  /* Whole-payload equality, because a producer must not reset on a frame that
   * asks for the mode already in force — a consumer is allowed to be careless
   * about resending, and resetting on every arrival would let a redundant send
   * silently restart a measurement somebody was in the middle of taking. A
   * *moved region* in the same mode is a change and does re-arm, which is why
   * this compares the region too. */
  bool operator==(const LufsModeRequest& other) const noexcept {
    return mode == other.mode && hasRegion == other.hasRegion &&
           startSeconds == other.startSeconds && endSeconds == other.endSeconds;
  }
  bool operator!=(const LufsModeRequest& other) const noexcept {
    return !(*this == other);
  }
};

/*
 * Decodes a SET_LUFS_MODE payload. False means the frame cannot be honoured and
 * the caller must keep the mode it already had.
 *
 * False rather than a default, in every failing case: an unknown mode (a
 * consumer newer than this build), a Timecode request with no region, or a
 * region that is empty or reversed. A default would measure a window nobody
 * asked for, and an integrated reading over the wrong window is wrong with
 * nothing on screen to say so — which is the failure this whole protocol is
 * written to avoid.
 */
bool decodeLufsMode(const uint8_t* payload, size_t bytes,
                    LufsModeRequest& out);

void writeHelloFrame(std::vector<uint8_t>& out, const char* producerName,
                     uint32_t abiVersion = OAA_ABI_VERSION);

}  // namespace oaa::wire
