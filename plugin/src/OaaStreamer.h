/*
 * OaaStreamer.h — the thread between the DAW and the Open Audio Analyzer app.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * ---------------------------------------------------------------------------
 * Why there is a thread here at all
 *
 * `oaa_engine_push` is synchronous: it runs the entire DSP graph — K-weighting,
 * true-peak oversampling, a 4096-point FFT — and returns once the block has
 * been measured. That is exactly the property the conformance suite needs, and
 * it is exactly the property that makes it unsafe to call from `processBlock`.
 *
 * The DAW's audio thread has a hard deadline measured in a couple of
 * milliseconds. Putting an FFT on it does not reliably break anything, which
 * is the problem: it works on the developer's machine at a 512-frame buffer and
 * produces dropouts on somebody else's at 64 frames under a full session, and
 * the report that comes back is "the plugin makes my project crackle".
 *
 * So this follows the same three-tier shape the rest of Open Audio Analyzer
 * uses, because it is the same problem:
 *
 *   DAW audio thread   copy into a lock-free FIFO, publish transport, return.
 *                      Microseconds. No allocation, no lock, no syscall.
 *   this thread        drain, measure, serialise, write to the socket.
 *   the app            draws.
 *
 * ---------------------------------------------------------------------------
 * Why the FIFO is JUCE's and not the engine's
 *
 * `engine/src/oaa_ring.c` is a working SPSC ring with precisely the right
 * semantics, and using it would avoid a second implementation of the same idea.
 * It is still the wrong choice, because its header lives in `engine/src` — it
 * is engine-internal, not part of `oaa.h`, and `oaa.h` says plainly that what
 * is not declared there is not part of the engine.
 *
 * A plugin reaching into the engine's private headers is a coupling that costs
 * nothing on the day it is written and quietly makes the engine's internals
 * un-refactorable afterwards. `juce::AbstractFifo` is already linked, is
 * lock-free, and is the thing JUCE plugins use for this. The MIT/AGPL boundary
 * stays exactly where the licence comment in CMakeLists.txt says it is: this
 * directory consumes liboaa's public C ABI and nothing else.
 */

#pragma once

#include <atomic>
#include <limits>
#include <vector>

#include <juce_audio_basics/juce_audio_basics.h>
#include <juce_core/juce_core.h>

#include <oaa/oaa.h>

#include "OaaTransportBox.h"
#include "OaaWire.h"

namespace oaa {

/*
 * Where the app listens for plugins.
 *
 * Two ports, not one, and the distinction is load-bearing. Open Audio Analyzer
 * speaks the same frames in both directions, but the two links dial in opposite
 * directions:
 *
 *   47821  a desktop app publishes, a tablet connects in    (remote display)
 *   47822  a plugin publishes, a desktop app accepts        (this)
 *
 * Sharing one port would make an accepted socket ambiguous about which end
 * sends HELLO first, and the failure mode of guessing wrong is not an error
 * anybody sees — it is both peers waiting for the other to speak, which
 * presents as "it connected, and then nothing happened". Two adjacent numbers
 * delete the question. See "Who talks, and on which port" in docs/WIRE.md.
 *
 * Loopback by default, because the overwhelmingly common case is the DAW and
 * the app on one desk. A hostname is accepted so a second machine can display
 * the session.
 */
inline constexpr int kDefaultPort = 47822;

class Streamer final : private juce::Thread {
public:
  Streamer();
  ~Streamer() override;

  /* Called from prepareToPlay. The host guarantees processBlock is not running
   * concurrently, which is what makes it safe to allocate and to rebuild the
   * engine here — and why none of it may happen anywhere else. */
  void prepare(double sampleRate, int channels, int hostBlockFrames);
  void release();

  /*
   * Audio thread. Real-time safe.
   *
   * Copies channel-wise rather than interleaving on the spot: the DAW's buffer
   * is already channel-separated, so a straight memcpy per channel is the
   * cheapest possible thing to do with the deadline, and interleaving is work
   * that the streaming thread can do at its leisure.
   */
  void pushAudio(const juce::AudioBuffer<float>& buffer) noexcept;

  void setDestination(const juce::String& host, int port);
  juce::String destinationHost() const;
  int destinationPort() const;

  /* Asks the engine to clear its integrating measurements. Honoured on the
   * streaming thread at the next push, because that is the thread that owns
   * the engine. */
  void requestReset() noexcept { resetRequested_.store(true, std::memory_order_relaxed); }

  /*
   * What the editor draws. Every member is written by the streaming thread and
   * read by the message thread, which is why they are atomics and why the
   * struct is assembled by value rather than handed out by reference — a
   * status that could tear would show a "connected" light next to the numbers
   * from a dead link.
   */
  struct Status {
    bool     connected      = false;
    bool     everConnected  = false;
    uint32_t droppedFrames  = 0;
    float    lufsIntegrated = std::numeric_limits<float>::quiet_NaN();
    double   elapsedSeconds = 0.0;
    uint32_t sampleRate     = 0;
    uint32_t channels       = 0;
    bool     hostGivesTransport = false;
  };
  Status status() const noexcept;

  TransportBox& transport() noexcept { return transport_; }

private:
  void run() override;

  /* Acquires the snapshot the last push published and sends it, with the
   * transport frame that describes the same instant. Called once per push —
   * see `run` for why it must not be once per drain. */
  void publish();

  bool ensureConnected();
  bool sendAll(const std::vector<uint8_t>& bytes);
  void rebuildEngine(double sampleRate, int channels);
  void destroyEngine();

  /* --- owned by the streaming thread ---------------------------------- */
  oaa_engine*          engine_   = nullptr;
  const oaa_snapshot*  snapshot_ = nullptr;
  uint64_t             lastGeneration_ = 0;

  juce::StreamingSocket socket_;
  std::vector<uint8_t>  frameBytes_;
  std::vector<float>    interleaved_;
  wire::Transport       lastTransport_{};
  uint32_t              reconnectDelayMs_ = 0;

  /* --- shared ---------------------------------------------------------- */
  TransportBox transport_;

  /* The FIFO. Channel-separated to match the DAW's buffer layout; the
   * streaming thread interleaves on the way out. */
  juce::AbstractFifo        fifo_{1};
  juce::AudioBuffer<float>  fifoBuffer_;

  std::atomic<uint32_t> droppedFrames_{0};
  std::atomic<bool>     resetRequested_{false};

  /* How many frames the engine wants per push. Pushing less does not change
   * any measurement — the windows are counted in samples — but every push
   * publishes a snapshot, so pushing tiny blocks would put fifty times more
   * frames on the socket than anybody can draw. */
  int pushBlockFrames_ = 1024;

  double preparedSampleRate_ = 0.0;
  int    preparedChannels_   = 0;

  mutable juce::CriticalSection destinationLock_;
  juce::String destinationHost_{"127.0.0.1"};
  int          destinationPort_ = kDefaultPort;

  std::atomic<bool>     connected_{false};
  std::atomic<bool>     everConnected_{false};
  std::atomic<float>    statusLufs_{std::numeric_limits<float>::quiet_NaN()};
  std::atomic<double>   statusElapsed_{0.0};
  std::atomic<uint32_t> statusSampleRate_{0};
  std::atomic<uint32_t> statusChannels_{0};

  JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(Streamer)
};

}  // namespace oaa
