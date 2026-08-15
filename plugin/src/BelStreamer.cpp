/*
 * BelStreamer.cpp — drain, measure, serialise, send.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * See BelStreamer.h for why the work is on this thread rather than the DAW's.
 */

#include "BelStreamer.h"

/* Only for `PluginHostType`, which names the host in the HELLO frame so the
 * app's link details can say "Logic Pro" rather than "a plugin". */
#include <juce_audio_processors/juce_audio_processors.h>

namespace bel {

namespace {

/* How much audio the FIFO holds, in seconds.
 *
 * The same half-second the engine's own capture ring uses, and for the same
 * reason its header gives: the producer runs at whatever buffer size the DAW
 * chose and the consumer at roughly the display rate, so a few hundred
 * milliseconds of slack absorbs every ordinary scheduling hiccup for a
 * negligible amount of memory. At 48 kHz stereo this is 192 kB.
 *
 * Sizing it tightly would save nothing worth having and would turn a hiccup
 * into lost audio, which is the one thing a measurement cannot absorb — a
 * dropped second does not make the integrated reading stale, it makes it an
 * average of a different programme than the one that played. */
constexpr double kFifoSeconds = 0.5;

/* Idle poll interval. The audio thread cannot wake us — signalling a
 * WaitableEvent is a syscall, and syscalls are exactly what `processBlock` is
 * not allowed to make — so this thread polls instead.
 *
 * 2 ms is far finer than the ~21 ms at which a snapshot is actually published,
 * so it adds no latency worth measuring, and a 2 ms sleep on a background
 * thread costs nothing anybody can find in a profile. */
constexpr int kPollMs = 2;

/* Reconnect backoff. Starts immediate and settles at a second.
 *
 * A plugin loaded in a DAW before the Bel app has been started must not spin
 * on connect() — that is a busy-loop inside somebody's session. Equally it
 * must not wait ten seconds after the app appears, because the user has just
 * pressed something and expects the link to come up. */
constexpr uint32_t kReconnectMinMs = 0;
constexpr uint32_t kReconnectMaxMs = 1000;
constexpr uint32_t kConnectTimeoutMs = 200;

int clampChannels(int channels) {
  return juce::jlimit(1, static_cast<int>(BEL_MAX_CHANNELS), channels);
}

}  // namespace

Streamer::Streamer() : juce::Thread("Bel streamer") {}

Streamer::~Streamer() {
  release();
}

/* --------------------------------------------------------------------- */
/* Lifecycle                                                              */
/* --------------------------------------------------------------------- */

void Streamer::prepare(double sampleRate, int channels, int hostBlockFrames) {
  release();

  preparedSampleRate_ = sampleRate;
  preparedChannels_   = clampChannels(channels);

  /* The engine's own default. Matching it means the plugin publishes at the
   * rate the rest of Bel was tuned around — roughly 47 Hz at 48 kHz — rather
   * than at whatever buffer size this particular host happens to use. */
  pushBlockFrames_ = 1024;

  /* A host running an unusually large buffer must still be able to deposit a
   * whole block without the FIFO refusing it, or the plugin would drop audio
   * on every callback and report an overrun for a machine that is keeping up
   * perfectly well. */
  const int fifoFrames = juce::nextPowerOfTwo(juce::jmax(
      static_cast<int>(sampleRate * kFifoSeconds),
      hostBlockFrames * 4,
      pushBlockFrames_ * 4));

  fifoBuffer_.setSize(preparedChannels_, fifoFrames, false, true, false);
  fifo_.setTotalSize(fifoFrames);
  fifo_.reset();

  interleaved_.assign(static_cast<size_t>(pushBlockFrames_) *
                      static_cast<size_t>(preparedChannels_), 0.0f);

  /* Sized once so the steady state never reallocates. */
  frameBytes_.reserve(wire::kHeaderBytes + wire::kSnapshotBytes);

  droppedFrames_.store(0, std::memory_order_relaxed);
  statusSampleRate_.store(static_cast<uint32_t>(sampleRate), std::memory_order_relaxed);
  statusChannels_.store(static_cast<uint32_t>(preparedChannels_), std::memory_order_relaxed);

  rebuildEngine(sampleRate, preparedChannels_);

  startThread(juce::Thread::Priority::normal);
}

void Streamer::release() {
  /* Stop the thread before the engine goes, not after: it is the only thread
   * that touches the engine, and destroying a `bel_engine` underneath a live
   * `bel_snapshot_acquire` is a use-after-free that would present as garbage
   * measurements rather than as a crash. */
  signalThreadShouldExit();
  stopThread(2000);

  socket_.close();
  connected_.store(false, std::memory_order_relaxed);

  destroyEngine();
}

void Streamer::rebuildEngine(double sampleRate, int channels) {
  destroyEngine();

  bel_config cfg;
  bel_config_defaults(&cfg);
  cfg.source       = BEL_SOURCE_PUSH;
  cfg.sample_rate  = static_cast<uint32_t>(sampleRate);
  cfg.channels     = static_cast<uint32_t>(channels);
  cfg.block_frames = static_cast<uint32_t>(pushBlockFrames_);

  engine_ = bel_engine_create(&cfg);
  if (engine_ == nullptr)
    return;

  /* Never moves for the engine's lifetime, so it is fetched once. */
  snapshot_ = bel_snapshot_buffer(engine_);
  lastGeneration_ = 0;

  /* A no-op for a pushed source beyond setting BEL_FLAG_RUNNING — there is no
   * thread to start, the caller is the clock. Called anyway so that a consumer
   * that connects before the first block arrives sees a running engine rather
   * than one that looks stopped. */
  bel_engine_start(engine_);
}

void Streamer::destroyEngine() {
  if (engine_ != nullptr) {
    bel_engine_destroy(engine_);
    engine_   = nullptr;
    snapshot_ = nullptr;
  }
}

/* --------------------------------------------------------------------- */
/* Audio thread                                                           */
/* --------------------------------------------------------------------- */

void Streamer::pushAudio(const juce::AudioBuffer<float>& buffer) noexcept {
  const int frames   = buffer.getNumSamples();
  const int channels = juce::jmin(buffer.getNumChannels(), fifoBuffer_.getNumChannels());

  if (frames <= 0 || channels <= 0)
    return;

  int start1, size1, start2, size2;
  fifo_.prepareToWrite(frames, start1, size1, start2, size2);

  for (int ch = 0; ch < channels; ++ch) {
    if (size1 > 0)
      fifoBuffer_.copyFrom(ch, start1, buffer, ch, 0, size1);
    if (size2 > 0)
      fifoBuffer_.copyFrom(ch, start2, buffer, ch, size1, size2);
  }

  /* A host that supplies fewer channels than the engine was built for leaves
   * the remainder holding the previous block. Silence is the honest reading
   * for a channel that carried nothing. */
  for (int ch = channels; ch < fifoBuffer_.getNumChannels(); ++ch) {
    if (size1 > 0) fifoBuffer_.clear(ch, start1, size1);
    if (size2 > 0) fifoBuffer_.clear(ch, start2, size2);
  }

  fifo_.finishedWrite(size1 + size2);

  /* Whatever would not fit is gone. Counted, not swallowed: see the note in
   * BelWire.h on why this ends up in `dropped_frames` rather than in a log
   * nobody reads. */
  if (const int lost = frames - (size1 + size2); lost > 0)
    droppedFrames_.fetch_add(static_cast<uint32_t>(lost), std::memory_order_relaxed);
}

/* --------------------------------------------------------------------- */
/* Destination                                                            */
/* --------------------------------------------------------------------- */

void Streamer::setDestination(const juce::String& host, int port) {
  {
    const juce::ScopedLock lock(destinationLock_);
    if (destinationHost_ == host && destinationPort_ == port)
      return;
    destinationHost_ = host;
    destinationPort_ = port;
  }

  /* Drop the current link so the change takes effect now rather than whenever
   * the far end next happens to disappear. */
  connected_.store(false, std::memory_order_relaxed);
}

juce::String Streamer::destinationHost() const {
  const juce::ScopedLock lock(destinationLock_);
  return destinationHost_;
}

int Streamer::destinationPort() const {
  const juce::ScopedLock lock(destinationLock_);
  return destinationPort_;
}

/* --------------------------------------------------------------------- */
/* Status                                                                 */
/* --------------------------------------------------------------------- */

Streamer::Status Streamer::status() const noexcept {
  Status s;
  s.connected           = connected_.load(std::memory_order_relaxed);
  s.everConnected       = everConnected_.load(std::memory_order_relaxed);
  s.droppedFrames       = droppedFrames_.load(std::memory_order_relaxed);
  s.lufsIntegrated      = statusLufs_.load(std::memory_order_relaxed);
  s.elapsedSeconds      = statusElapsed_.load(std::memory_order_relaxed);
  s.sampleRate          = statusSampleRate_.load(std::memory_order_relaxed);
  s.channels            = statusChannels_.load(std::memory_order_relaxed);
  s.hostGivesTransport  = transport_.hasEverPublished();
  return s;
}

/* --------------------------------------------------------------------- */
/* The streaming thread                                                   */
/* --------------------------------------------------------------------- */

bool Streamer::ensureConnected() {
  if (socket_.isConnected())
    return true;

  connected_.store(false, std::memory_order_relaxed);

  if (reconnectDelayMs_ > 0) {
    wait(static_cast<int>(juce::jmin<uint32_t>(reconnectDelayMs_, 100u)));
    if (threadShouldExit())
      return false;
    reconnectDelayMs_ -= juce::jmin<uint32_t>(reconnectDelayMs_, 100u);
    if (reconnectDelayMs_ > 0)
      return false;
  }

  juce::String host;
  int port;
  {
    const juce::ScopedLock lock(destinationLock_);
    host = destinationHost_;
    port = destinationPort_;
  }

  socket_.close();
  if (!socket_.connect(host, port, kConnectTimeoutMs)) {
    /* Doubling backoff, capped. The app simply may not be running, which is a
     * completely ordinary state and not an error to shout about. */
    reconnectDelayMs_ = reconnectDelayMs_ == 0
        ? 125
        : juce::jmin(reconnectDelayMs_ * 2, kReconnectMaxMs);
    return false;
  }

  reconnectDelayMs_ = kReconnectMinMs;

  /* The handshake. If the far end dislikes what it hears it closes the socket,
   * which this thread discovers on the next write and treats as any other
   * disconnect — v1 is a one-directional display stream, so there is no reply
   * to wait for and nothing this end could usefully do with one. */
  const juce::String name = juce::String("Bel plugin — ")
      + juce::PluginHostType().getHostDescription();
  wire::writeHelloFrame(frameBytes_, name.toRawUTF8());
  if (!sendAll(frameBytes_))
    return false;

  connected_.store(true, std::memory_order_relaxed);
  everConnected_.store(true, std::memory_order_relaxed);
  return true;
}

bool Streamer::sendAll(const std::vector<uint8_t>& bytes) {
  size_t sent = 0;
  while (sent < bytes.size()) {
    const int wrote = socket_.write(bytes.data() + sent,
                                    static_cast<int>(bytes.size() - sent));
    if (wrote <= 0) {
      socket_.close();
      connected_.store(false, std::memory_order_relaxed);
      return false;
    }
    sent += static_cast<size_t>(wrote);
  }
  return true;
}

void Streamer::run() {
  while (!threadShouldExit()) {
    if (engine_ == nullptr) {
      wait(kPollMs);
      continue;
    }

    if (resetRequested_.exchange(false, std::memory_order_relaxed)) {
      bel_engine_reset(engine_);
      droppedFrames_.store(0, std::memory_order_relaxed);
    }

    /* Drain in engine-sized blocks.
     *
     * Every push publishes a snapshot, so pushing whatever happens to be in
     * the FIFO would tie the publish rate to this thread's poll interval and
     * put fifty times more frames on the socket than anything can draw. A
     * fixed block keeps the rate at the engine's own ~47 Hz, and the
     * measurements are identical either way because the 400 ms and 3 s windows
     * are counted in samples, not in calls. */
    bool measured = false;
    while (fifo_.getNumReady() >= pushBlockFrames_ && !threadShouldExit()) {
      int start1, size1, start2, size2;
      fifo_.prepareToRead(pushBlockFrames_, start1, size1, start2, size2);

      const int channels = fifoBuffer_.getNumChannels();
      float* dst = interleaved_.data();

      for (int i = 0; i < size1; ++i)
        for (int ch = 0; ch < channels; ++ch)
          *dst++ = fifoBuffer_.getSample(ch, start1 + i);

      for (int i = 0; i < size2; ++i)
        for (int ch = 0; ch < channels; ++ch)
          *dst++ = fifoBuffer_.getSample(ch, start2 + i);

      fifo_.finishedRead(size1 + size2);

      bel_engine_push(engine_, interleaved_.data(),
                      static_cast<uint32_t>(size1 + size2));
      measured = true;
    }

    if (!measured) {
      wait(kPollMs);
      continue;
    }

    const uint64_t generation = bel_snapshot_acquire(engine_);
    if (generation == lastGeneration_) {
      wait(kPollMs);
      continue;
    }
    lastGeneration_ = generation;

    statusLufs_.store(snapshot_->lufs_integrated, std::memory_order_relaxed);
    statusElapsed_.store(snapshot_->elapsed_seconds, std::memory_order_relaxed);
    statusSampleRate_.store(snapshot_->sample_rate, std::memory_order_relaxed);
    statusChannels_.store(snapshot_->channels, std::memory_order_relaxed);

    if (!ensureConnected())
      continue;

    /* Transport first, then the snapshot it describes, so a consumer holding
     * both applies them to the same instant. A failed read leaves
     * `lastTransport_` in place, which is the right answer for one frame of a
     * continuously-moving value. */
    transport_.read(lastTransport_);

    wire::writeTransportFrame(frameBytes_, lastTransport_);
    if (!sendAll(frameBytes_))
      continue;

    wire::writeSnapshotFrame(frameBytes_, *snapshot_,
                             droppedFrames_.load(std::memory_order_relaxed));
    sendAll(frameBytes_);
  }
}

}  // namespace bel
