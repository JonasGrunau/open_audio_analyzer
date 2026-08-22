/*
 * OaaWire.cpp — serialisers for the Open Audio Analyzer wire protocol.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The field order below is the normative table in `docs/WIRE.md`, which is
 * itself `oaa.h`'s declaration order read top to bottom — **including the
 * `reservedN` members**. Those look like padding worth skipping and are not:
 * they are named precisely so that adding a float later does not shift every
 * field after it, and a serialiser that quietly omitted them would shift the
 * entire remainder of the frame the first time one was put to use.
 *
 * Nothing here is on the audio thread. This runs on the streaming thread,
 * roughly fifty times a second, and the output vector is reused, so the steady
 * state allocates nothing after the first frame.
 */

#include "OaaWire.h"

#include <cmath>
#include <cstring>

namespace oaa::wire {

namespace {

/* Field counts, spelled out so the frame arithmetic below reads as the table
 * it is rather than as a series of unexplained constants. */
constexpr size_t kChannels  = OAA_MAX_CHANNELS;
constexpr size_t kBands     = OAA_SPECTRUM_BANDS;
constexpr size_t kScope     = OAA_SCOPE_POINTS * 2;
constexpr size_t kHistogram = OAA_HISTOGRAM_BINS;

}  // namespace

void writeHeader(std::vector<uint8_t>& out, FrameType type, uint32_t payloadBytes) {
  ByteWriter w(out);
  w.u32(kMagic);
  w.u16(kProtocolVersion);
  w.u16(static_cast<uint16_t>(type));
  w.u32(payloadBytes);
}

void writeSnapshotFrame(std::vector<uint8_t>& out, const oaa_snapshot& s,
                        uint32_t extraDroppedFrames) {
  out.clear();
  out.reserve(kHeaderBytes + kSnapshotBytes);
  writeHeader(out, FrameType::Snapshot, static_cast<uint32_t>(kSnapshotBytes));

  ByteWriter w(out);

  /* See the header: the plugin's FIFO can lose audio the engine never sees, and
   * `dropped_frames` is the field that means "audio lost before it was
   * measured". Saturating rather than wrapping, because a counter that rolls
   * over to a small number reports a trustworthy measurement over audio that
   * has a very large hole in it. */
  const uint64_t droppedSum =
      static_cast<uint64_t>(s.dropped_frames) + extraDroppedFrames;
  const auto dropped = static_cast<uint32_t>(
      droppedSum > 0xFFFFFFFFull ? 0xFFFFFFFFull : droppedSum);

  const uint32_t flags =
      dropped != 0 ? (s.flags | uint32_t(OAA_FLAG_OVERRUN)) : s.flags;

  w.u64(s.generation);
  w.f64(s.elapsed_seconds);

  w.u32(s.sample_rate);
  w.u32(s.channels);
  w.u32(flags);
  w.u32(dropped);

  w.f32(s.lufs_momentary);
  w.f32(s.lufs_short);
  w.f32(s.lufs_integrated);
  w.f32(s.lra);

  w.f32(s.true_peak);
  w.f32(s.true_peak_max);
  w.f32(s.sample_peak_max);
  w.f32(s.reserved1);

  w.f32(s.dr_short);
  w.f32(s.dr_integrated);
  w.f32(s.crest);
  w.f32(s.plr);
  w.f32(s.psr);
  w.f32(s.reserved2);

  w.f32(s.correlation);
  w.f32(s.balance);

  w.f32Array(s.peak, kChannels);
  w.f32Array(s.rms, kChannels);
  w.f32Array(s.vu, kChannels);
  w.u32Array(s.clip, kChannels);

  w.dbArray(s.spectrum, kBands);
  w.dbArray(s.spectrum_peak, kBands);

  w.f32(s.lra_low);
  w.f32(s.lra_high);
  w.f32(s.lra_gate);
  w.f32(s.reserved3);

  w.unitArray(s.spectrum_pan, kBands);
  w.fractionArray(s.histogram, kHistogram);

  /* Last, and length-prefixed. A plugin always sends exactly one block. */
  w.u32(static_cast<uint32_t>(kScopeFrames));
  w.sampleArray(s.scope, kScope);

  /* Cheap, and it catches the one bug this file can plausibly have: a field
   * transcribed in the wrong order still totals correctly, but a field *missed*
   * or duplicated does not. Serialising a frame of the wrong length is worse
   * than not sending it, because the consumer resynchronises on the next magic
   * and draws whatever it managed to parse.
   *
   * **This has to survive NDEBUG**, which a bare `assert` does not. The plugin
   * is configured `-DCMAKE_BUILD_TYPE=Release` everywhere it is built —
   * including in CI, which is the only place the C++ producer is exercised at
   * all — so the assert alone was compiled out of precisely the build it was
   * written to guard. Clearing the buffer is the action the comment above
   * argues for: `sendAll` on an empty vector writes nothing, so a
   * wrong-length frame is dropped rather than put on the socket, and the
   * consumer sees a missing frame instead of a plausible wrong one. The assert
   * stays as well, so a debug build stops at the cause. */
  if (out.size() != kHeaderBytes + kSnapshotBytes) {
    assert(false && "snapshot frame is the wrong length — a field is missing "
                    "or duplicated in writeSnapshotFrame");
    out.clear();
  }
}

void writeTransportFrame(std::vector<uint8_t>& out, const Transport& t) {
  out.clear();
  out.reserve(kHeaderBytes + kTransportBytes);
  writeHeader(out, FrameType::DawTransport, static_cast<uint32_t>(kTransportBytes));

  ByteWriter w(out);
  w.u32(t.flags);
  w.u32(t.frameRate);
  w.f64(t.timeSeconds);
  w.f64(t.ppqPosition);
  w.f64(t.ppqBarStart);
  w.f64(t.bpm);
  w.f64(t.editOriginSeconds);
  w.f64(t.loopStartPpq);
  w.f64(t.loopEndPpq);
  w.i64(t.timeSamples);
  w.u32(t.timeSigNumerator);
  w.u32(t.timeSigDenominator);
  w.u32(t.hostFrames);
  w.u32(t.reserved);

  /* Dropped rather than sent short — see the note in writeSnapshotFrame for
   * why this is not an `assert` alone. */
  if (out.size() != kHeaderBytes + kTransportBytes) {
    assert(false && "transport frame is the wrong length");
    out.clear();
  }
}

void writeHelloFrame(std::vector<uint8_t>& out, const char* producerName,
                     uint32_t abiVersion) {
  const size_t nameLength = std::strlen(producerName);
  const auto payload = static_cast<uint32_t>(kHelloFixedBytes + nameLength);

  out.clear();
  out.reserve(kHeaderBytes + payload);
  writeHeader(out, FrameType::Hello, payload);

  ByteWriter w(out);

  w.u16(kProtocolVersion);
  w.u16(0);  // flags, reserved

  /* This one refuses. A disagreement here means the two ends do not share a
   * frame layout, and the failure mode of continuing is a shifted read that
   * displays plausible wrong numbers rather than anything that looks broken. */
  w.u32(static_cast<uint32_t>(kSnapshotBytes));

  /* Informational. Shown in the app's link details, never a reason to refuse:
   * an additive ABI bump leaves every byte of this protocol untouched, and
   * refusing a link that would have worked perfectly is its own wrong answer. */
  w.u32(abiVersion);

  /* The array shapes.
   *
   * Redundant with the payload size in the sense that any disagreement would
   * also change it, and worth sending anyway: the size alone says *that* the
   * two ends disagree, and these say *how*. "This plugin sends 256 spectrum
   * bands and I expect 512" is a sentence somebody can act on; "the snapshot
   * is 7,000 bytes and I expected 15,056" is a puzzle. */
  w.u32(static_cast<uint32_t>(OAA_MAX_CHANNELS));
  w.u32(static_cast<uint32_t>(OAA_SPECTRUM_BANDS));
  w.u32(static_cast<uint32_t>(OAA_SCOPE_POINTS));
  w.u32(static_cast<uint32_t>(OAA_HISTOGRAM_BINS));

  w.u32(static_cast<uint32_t>(nameLength));
  for (size_t i = 0; i < nameLength; ++i)
    w.u8(static_cast<uint8_t>(producerName[i]));

  if (out.size() != kHeaderBytes + payload) {
    assert(false && "hello frame is the wrong length");
    out.clear();
  }
}

/*
 * The decoder. Reads little-endian by construction rather than by cast: the
 * frame is little-endian on every platform by specification, and a memcpy of a
 * double would be right on the two architectures this ships on and silently
 * wrong on the one it does not.
 */
bool decodeLufsMode(const uint8_t* payload, size_t bytes,
                    LufsModeRequest& out) {
  if (payload == nullptr || bytes < kLufsModeBytes) {
    return false;
  }

  const auto u32 = [payload](size_t offset) -> uint32_t {
    return static_cast<uint32_t>(payload[offset]) |
           (static_cast<uint32_t>(payload[offset + 1]) << 8) |
           (static_cast<uint32_t>(payload[offset + 2]) << 16) |
           (static_cast<uint32_t>(payload[offset + 3]) << 24);
  };
  const auto f64 = [payload](size_t offset) -> double {
    uint64_t bits = 0;
    for (size_t i = 0; i < 8; ++i) {
      bits |= static_cast<uint64_t>(payload[offset + i]) << (8 * i);
    }
    double value = 0.0;
    static_assert(sizeof(value) == sizeof(bits), "double is not 64 bits");
    std::memcpy(&value, &bits, sizeof(value));
    return value;
  };

  const uint32_t rawMode = u32(0);
  if (rawMode > static_cast<uint32_t>(LufsTimeMode::Timecode)) {
    /* A mode from a consumer newer than this build. Keep what we have. */
    return false;
  }

  LufsModeRequest request;
  request.mode = static_cast<LufsTimeMode>(rawMode);

  const uint32_t flags = u32(4);
  request.hasRegion = (flags & kLufsModeHasRegion) != 0;

  if (request.hasRegion) {
    request.startSeconds = f64(8);
    request.endSeconds   = f64(16);

    const bool finite = std::isfinite(request.startSeconds) &&
                        std::isfinite(request.endSeconds);
    if (!finite || request.startSeconds < 0.0 ||
        request.endSeconds <= request.startSeconds) {
      return false;
    }
  }

  /* Timecode without a region is malformed rather than defaultable — there is
   * no stretch of timeline it would be honest to substitute. */
  if (request.mode == LufsTimeMode::Timecode && !request.hasRegion) {
    return false;
  }

  out = request;
  return true;
}

}  // namespace oaa::wire
