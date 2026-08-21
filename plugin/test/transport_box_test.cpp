/*
 * TransportBox: what it hands over, and how many times.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * ---------------------------------------------------------------------------
 * Why this exists as a unit test at all
 *
 * The box is a seqlock with an edge accumulator beside it, and the property
 * that matters — an edge is delivered *exactly* once — is the kind that a
 * running system confirms almost every time. The audio thread publishes more
 * often than the streaming thread reads, so a jump block is normally sampled
 * once and a duplicate never appears. It took a loaded CI runner, where the two
 * rates cross and two frames go out inside one audio block, to deliver a single
 * relocate twice: three laps of a loop arrived as four flagged frames.
 *
 * That failure was found by an end-to-end test that spawns a DAW, plays a file
 * through a real VST3 and counts frames off a socket — which is the right test
 * for "does the whole path work" and a hopeless one for this: it reproduced
 * roughly one run in six, and only under enough load to make the rates cross.
 *
 * Every case below is single-threaded and deterministic. `read` samples
 * whatever the payload currently holds, so calling it twice with no publish in
 * between *is* the loaded runner, reduced to two lines and no timing at all.
 *
 * Links `OaaWire.cpp` and nothing else — no JUCE, like the wire fixture beside
 * it, so CI pays a second for it rather than a plugin build.
 */

#include <cstdio>
#include <cstdlib>

#include "OaaTransportBox.h"

namespace {

int failures = 0;

void check(bool ok, const char* what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what);
    ++failures;
  }
}

/* A block the host is playing, at a position, with a tempo. */
oaa::wire::Transport rolling(double seconds) {
  oaa::wire::Transport t;
  t.flags = oaa::wire::kPlaying | oaa::wire::kHasTimeSeconds | oaa::wire::kHasBpm;
  t.timeSeconds = seconds;
  t.bpm = 120.0;
  return t;
}

/* The same, on the one block where the playhead did not arrive where the
 * previous block left it. */
oaa::wire::Transport jumped(double seconds) {
  oaa::wire::Transport t = rolling(seconds);
  t.flags |= oaa::wire::kDiscontinuity;
  return t;
}

bool discontinuous(const oaa::wire::Transport& t) {
  return (t.flags & oaa::wire::kDiscontinuity) != 0u;
}

/* ------------------------------------------------------------------------- */

void anEdgeIsDeliveredOnce() {
  oaa::TransportBox box;
  oaa::wire::Transport out;

  box.publish(jumped(0.0));

  check(box.read(out), "the first read succeeds");
  check(discontinuous(out), "the relocate reaches the reader");
  check(out.timeSeconds == 0.0, "it arrives beside the position it landed on");

  /* **The case that shipped.** No publish in between, so the payload is still
   * the jump block — which is exactly what a reader sees when the streaming
   * thread gets two turns inside one audio block. The edge has already gone
   * out; the flag must not be in the payload to be found a second time. */
  check(box.read(out), "the second read succeeds");
  check(!discontinuous(out), "the relocate is not delivered twice");
  check(out.timeSeconds == 0.0, "the position is still current, and is state");
}

void aRepeatedReadKeepsTheStateFlags() {
  oaa::TransportBox box;
  oaa::wire::Transport out;

  box.publish(jumped(1.5));
  check(box.read(out), "read");
  check(box.read(out), "read again");

  /* Stripping the edge must not strip anything beside it: playing, the presence
   * bits and the values are *state*, and the most recent one is the right
   * answer however many times it is asked for. */
  check((out.flags & oaa::wire::kPlaying) != 0u, "still playing");
  check((out.flags & oaa::wire::kHasTimeSeconds) != 0u, "still has a position");
  check((out.flags & oaa::wire::kHasBpm) != 0u, "still has a tempo");
  check(out.bpm == 120.0, "the tempo survives");
  check(out.timeSeconds == 1.5, "the position survives");
}

void everyEdgeBetweenTwoReadsSurvives() {
  oaa::TransportBox box;
  oaa::wire::Transport out;

  /* Two relocates inside one frame interval — a loop wrapping twice while the
   * streaming thread was busy. The accumulator is why the second one is not
   * lost, and it is an OR rather than a store for exactly this. */
  box.publish(jumped(0.0));
  box.publish(rolling(0.01));
  box.publish(jumped(0.0));
  box.publish(rolling(0.01));

  check(box.read(out), "read");
  check(discontinuous(out), "an edge raised between reads is not lost");

  check(box.read(out), "read again");
  check(!discontinuous(out), "and is not repeated afterwards");
}

void anEdgeAfterAnEdgeIsDeliveredAgain() {
  oaa::TransportBox box;
  oaa::wire::Transport out;

  box.publish(jumped(0.0));
  check(box.read(out), "read");
  check(discontinuous(out), "first relocate");

  box.publish(rolling(0.01));
  check(box.read(out), "read");
  check(!discontinuous(out), "no relocate here");

  /* A *second* relocate is a second edge, and must arrive. The bug this file
   * exists for was a duplicate; over-correcting into a swallowed edge would be
   * the worse half of the same mistake — an integrated reading that spans two
   * passes of the same music, with nothing on screen to say so. */
  box.publish(jumped(0.0));
  check(box.read(out), "read");
  check(discontinuous(out), "a later relocate is reported");
}

void nothingIsPublishedUntilSomethingIs() {
  oaa::TransportBox box;
  oaa::wire::Transport out;

  check(!box.hasEverPublished(), "a host that has said nothing is not claimed");
  box.publish(rolling(0.0));
  check(box.hasEverPublished(), "and is, once it has");
  check(box.read(out), "read");
  check(!discontinuous(out), "ordinary playback is not a relocate");
}

}  // namespace

int main() {
  anEdgeIsDeliveredOnce();
  aRepeatedReadKeepsTheStateFlags();
  everyEdgeBetweenTwoReadsSurvives();
  anEdgeAfterAnEdgeIsDeliveredAgain();
  nothingIsPublishedUntilSomethingIs();

  if (failures != 0) {
    std::fprintf(stderr, "%d check(s) failed\n", failures);
    return EXIT_FAILURE;
  }

  std::printf("transport_box: OK\n");
  return EXIT_SUCCESS;
}
