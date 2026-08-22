/*
 * wire_fixture.cpp — writes one transport frame and one snapshot frame, with
 * known values, to a file.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * ---------------------------------------------------------------------------
 * The bug this exists to catch
 *
 * There are two implementations of the Open Audio Analyzer wire protocol: this
 * one in C++ and
 * `packages/oaa_wire/` in Dart. They are written against `docs/WIRE.md` rather
 * than against each other, which is right — the Dart end must be implementable
 * by somebody who has never seen the C++ — and which means nothing in either
 * codebase forces them to agree.
 *
 * A disagreement between them does not fail to compile, does not throw, and
 * does not look broken. Every frame is a fixed length, so a field transcribed
 * in the wrong order still parses perfectly: the app draws a spectrum built
 * from the scope buffer, or reads loudness out of the peak array, and puts a
 * detailed, confident, entirely wrong picture on screen. In a tool somebody
 * makes delivery decisions from, that is the worst failure available.
 *
 * So: this writes a frame pair full of deliberately distinctive values, the
 * bytes are committed as a golden, and both ends assert against it. C++ drift
 * fails `wire_fixture_matches_golden`; Dart drift fails the codec test. A
 * deliberate protocol change fails both, which is the correct amount of
 * friction for a change that must be made in three places at once.
 *
 * Regenerating, after a *deliberate* protocol change only:
 *
 *   cmake --build plugin/build --target oaa_wire_fixture
 *   ./plugin/build/oaa_wire_fixture plugin/test/golden/wire_v4.bin
 *
 * `wire_v4.bin` is the one that tracks this serialiser, and the one
 * `wire_fixture_matches_golden` compares against. **Never regenerate
 * `wire_v2.bin`, and as of version 4 never `wire_v3.bin` either.** Bytes
 * written by today's build prove nothing about what yesterday's wrote, so
 * regenerating either destroys the only thing that holds a promise about the
 * past. `v2` against `v3` is the evidence that version 3 moved a frame type and
 * no table; `v3` on its own is now the only exercise of the version 1-3 decode
 * path, which is what lets an already-installed plugin survive an app
 * upgrade.
 *
 * The values below include a NaN and a negative infinity on purpose. Both have
 * bit patterns that a careless serialiser normalises — NaN through arithmetic,
 * infinity through a clamp — and both carry meaning here: NaN is "nobody
 * measured this" and −∞ is digital silence. A round trip that turns either into
 * a number is a bug that only shows up on real audio.
 */

#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <vector>

#include "../src/OaaWire.h"

namespace {

oaa_snapshot makeSnapshot() {
  oaa_snapshot s;
  std::memset(&s, 0, sizeof(s));

  s.generation      = 0x0123456789ABCDEFull;
  s.elapsed_seconds = 123.456;
  s.sample_rate     = 48000;
  s.channels        = 2;
  s.flags           = OAA_FLAG_RUNNING;
  s.dropped_frames  = 7;

  /* Not measured. Must survive as NaN, not as zero. */
  s.lufs_momentary  = std::numeric_limits<float>::quiet_NaN();
  s.lufs_short      = -18.5f;
  s.lufs_integrated = -14.0f;
  s.lra             = 7.25f;

  /* Digital silence. Must survive as −∞, not as the dB floor. */
  s.true_peak       = -std::numeric_limits<float>::infinity();
  s.true_peak_max   = -0.5f;
  s.sample_peak_max = -0.8f;
  s.reserved1       = 0.0f;

  s.dr_short        = 12.5f;
  s.dr_integrated   = 13.0f;
  s.crest           = 14.0f;
  s.plr             = 15.0f;
  s.psr             = 16.0f;
  s.reserved2       = 0.0f;

  s.correlation     = 0.5f;
  s.balance         = -0.25f;

  for (int i = 0; i < OAA_MAX_CHANNELS; ++i) {
    s.peak[i] = -static_cast<float>(i);
    s.rms[i]  = -10.0f - static_cast<float>(i);
    s.vu[i]   = static_cast<float>(i) * 0.5f;
    s.clip[i] = static_cast<uint32_t>(i);
  }

  /* Distinct per-array patterns, so that an array serialised in the wrong slot
   * is caught rather than merely being the wrong length. */
  for (int i = 0; i < OAA_SPECTRUM_BANDS; ++i) {
    s.spectrum[i]      = -static_cast<float>(i % 100);
    s.spectrum_peak[i] = -static_cast<float>(i % 100) + 1.0f;
    s.spectrum_pan[i]  = static_cast<float>(i % 3) - 1.0f;
  }

  s.lra_low   = -20.0f;
  s.lra_high  = -12.0f;
  s.lra_gate  = -34.0f;
  s.reserved3 = 0.0f;

  for (int i = 0; i < OAA_SCOPE_POINTS * 2; ++i)
    s.scope[i] = static_cast<float>(i % 7) / 7.0f - 0.5f;

  for (int i = 0; i < OAA_HISTOGRAM_BINS; ++i)
    s.histogram[i] = static_cast<float>(i) / 120.0f;

  return s;
}

oaa::wire::Transport makeTransport() {
  oaa::wire::Transport t;
  t.flags = oaa::wire::kPlaying | oaa::wire::kHasTimeSeconds |
            oaa::wire::kHasPpq | oaa::wire::kHasBpm |
            oaa::wire::kHasTimeSig | oaa::wire::kHasTimecode |
            oaa::wire::kHasTimeSamples | oaa::wire::kHasLoopPoints |
            oaa::wire::kHasBarStart | oaa::wire::kDiscontinuity;

  t.frameRate          = 5;  /* 29.97 drop */
  t.timeSeconds        = 61.5;
  t.ppqPosition        = 8.25;
  t.ppqBarStart        = 8.0;
  t.bpm                = 120.0;
  t.editOriginSeconds  = 3600.0;
  t.loopStartPpq       = 4.0;
  t.loopEndPpq         = 12.0;
  t.timeSamples        = 2952000;
  t.timeSigNumerator   = 7;
  t.timeSigDenominator = 8;
  t.hostFrames         = 512;
  return t;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: oaa_wire_fixture <output-path>\n");
    return 2;
  }

  std::vector<uint8_t> out;
  std::vector<uint8_t> frame;

  /* HELLO is in the golden too, and it is the frame that most needs to be:
   * it is the only variable-length one, and it is the one whose fields decide
   * what every *later* byte means. A HELLO that misparses does not produce a
   * bad handshake, it produces a compatibility check performed against numbers
   * read out of the wrong offsets. */
  /* The ABI is pinned to 3 rather than taken from this build, and it is
   * deliberately *not* the current one.
   *
   * Two things fall out of that. The golden stops depending on an engine ABI
   * bump, which is an event with no effect whatsoever on these bytes — coupling
   * them would mean an unrelated header change failed a wire test. And the
   * frame itself then demonstrates the rule the handshake is built on: a
   * producer whose ABI differs from the consumer's is accepted, because the
   * payload size is what decides whether the bytes can be read, and refusing a
   * link that would have worked is its own kind of wrong answer. */
  oaa::wire::writeHelloFrame(frame, "Open Audio Analyzer plugin — fixture", 3);
  out.insert(out.end(), frame.begin(), frame.end());

  oaa::wire::writeTransportFrame(frame, makeTransport());
  out.insert(out.end(), frame.begin(), frame.end());

  const oaa_snapshot snapshot = makeSnapshot();
  oaa::wire::writeSnapshotFrame(frame, snapshot);
  out.insert(out.end(), frame.begin(), frame.end());

  std::FILE* file = std::fopen(argv[1], "wb");
  if (file == nullptr) {
    std::fprintf(stderr, "oaa_wire_fixture: cannot open %s\n", argv[1]);
    return 1;
  }

  const size_t written = std::fwrite(out.data(), 1, out.size(), file);
  std::fclose(file);

  if (written != out.size()) {
    std::fprintf(stderr, "oaa_wire_fixture: short write\n");
    return 1;
  }

  std::printf("%zu bytes\n", out.size());
  return 0;
}
