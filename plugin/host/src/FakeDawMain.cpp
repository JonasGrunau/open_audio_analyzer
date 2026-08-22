/*
 * FakeDawMain.cpp — both ways of running the fake DAW.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * ---------------------------------------------------------------------------
 * One binary, two lifetimes
 *
 * With a window: open a device, show the controls, let a person press Play and
 * look at what the app draws. That is how a meter gets judged — the note in
 * `CLAUDE.md` about running the app and looking at a module before calling it
 * finished applies to the plugin too, and until now there was no way to do it
 * short of launching a DAW.
 *
 * Without one (`--headless`): no window, no sound card, and a plain loop
 * pushing blocks through the plugin on a background thread. That is what lets a
 * test drive the whole path — file, plugin, socket, decoder — on a CI runner
 * that has neither a screen nor an audio interface.
 *
 * The exit code is the product in headless mode: zero means the requested
 * amount of audio went through the plugin, anything else means the run did not
 * happen and stderr says why. A test that reads only the socket cannot tell
 * "the plugin sent nothing" from "the host never started".
 */

#include <juce_gui_extra/juce_gui_extra.h>

#include <atomic>
#include <iostream>
#include <memory>

#include "FakeDawComponent.h"
#include "FakeDawEngine.h"
#include "FakeDawOptions.h"

namespace oaa::host {

namespace {

/*
 * How long to keep the plugin alive after the last block.
 *
 * The plugin measures and sends on its own thread, draining a FIFO the audio
 * thread filled — so at the moment the transport stops there is still up to a
 * few hundred milliseconds of audio that has been played but not yet measured,
 * and a frame that has been serialised but not yet written to the socket.
 * Destroying the plugin immediately throws that away, and a test asking for two
 * seconds of audio would receive rather less than two seconds of frames for
 * reasons that have nothing to do with the protocol.
 */
constexpr int kLingerMs = 750;

/* Picks the plugin to host when `--plugin` was not given: the VST3 from a build
 * tree above this executable. Not the Audio Unit — macOS will not load one out
 * of a build tree, and guessing wrong produces a confusing error rather than
 * no error. */
juce::File defaultPluginFile() {
  const auto built = FakeDawEngine::findBuiltPlugins();

  for (const auto& file : built)
    if (file.getFileName().endsWithIgnoreCase(".vst3"))
      return file;

  return built.isEmpty() ? juce::File() : built.getFirst();
}

}  // namespace

/*
 * Renders offline on a thread of its own, because `runOffline` blocks for the
 * length of the run and the message thread has to stay free: the VST3 hosting
 * layer posts to it, and a plugin whose editor or state callbacks never get
 * serviced is a plugin behaving differently under test than in a DAW.
 */
class OfflineRunner final : private juce::Thread {
public:
  OfflineRunner(FakeDawEngine& engine,
                const FakeDawEngine::OfflineRun& run,
                std::function<void()> onFinished)
      : juce::Thread("oaa fake daw offline"),
        engine_(engine),
        run_(run),
        onFinished_(std::move(onFinished)) {
    startThread();
  }

  ~OfflineRunner() override {
    stopFlag_.store(true, std::memory_order_relaxed);
    stopThread(5000);
  }

  void requestStop() { stopFlag_.store(true, std::memory_order_relaxed); }

private:
  void run() override {
    engine_.runOffline(run_, stopFlag_);

    const auto readout = engine_.readout();
    std::cout << "fake-daw: rendered blocks=" << readout.blocks << std::endl;

    /* Let the plugin's own thread finish measuring and sending what the audio
     * thread already handed it. See kLingerMs. */
    for (int waited = 0; waited < kLingerMs && !threadShouldExit(); waited += 50)
      wait(50);

    std::cout << "fake-daw: done" << std::endl;

    if (onFinished_)
      juce::MessageManager::callAsync(onFinished_);
  }

  FakeDawEngine&            engine_;
  FakeDawEngine::OfflineRun run_;
  std::function<void()>     onFinished_;
  std::atomic<bool>         stopFlag_ { false };
};

class FakeDawApplication final : public juce::JUCEApplication {
public:
  const juce::String getApplicationName() override { return "Open Audio Analyzer Fake DAW"; }
  const juce::String getApplicationVersion() override { return "0.5.0"; }
  bool moreThanOneInstanceAllowed() override { return true; }

  void initialise(const juce::String&) override {
    const auto options = parseOptions(getCommandLineParameterArray());

    if (options.help) {
      std::cout << usageText() << std::flush;
      quit();
      return;
    }

    if (options.error.isNotEmpty()) {
      fail(options.error);
      return;
    }

    engine_ = std::make_unique<FakeDawEngine>();

    if (options.headless)
      startHeadless(options);
    else
      startWindowed(options);
  }

  void shutdown() override {
    runner_.reset();
    window_.reset();
    engine_.reset();
  }

  void systemRequestedQuit() override {
    if (runner_ != nullptr)
      runner_->requestStop();

    quit();
  }

private:
  void fail(const juce::String& message) {
    std::cerr << "fake-daw: " << message << std::endl;
    setApplicationReturnValue(2);
    quit();
  }

  /* ------------------------------------------------------------------- */

  void startWindowed(const Options& options) {
    const auto deviceError = engine_->openAudioDevice();

    window_ = std::make_unique<MainWindow>(getApplicationName(), *engine_);
    window_->component().applyOptions(options);

    if (deviceError.isNotEmpty()) {
      /* Not fatal. Everything except monitoring works without a device, and
       * the plugin does not need one to measure — so the run continues and the
       * window says what happened. */
      window_->component().reportProblem("No audio device: " + deviceError
                                         + "\nThe plugin still runs, but nothing is audible.");
    }
  }

  /* ------------------------------------------------------------------- */

  void startHeadless(const Options& options) {
    auto error = engine_->loadTrack(options.track);
    if (error.isNotEmpty()) {
      fail(error);
      return;
    }

    engine_->setTempo(options.bpm);
    engine_->setTimeSignature(options.timeSigNumerator, options.timeSigDenominator);
    engine_->setFrameRate(options.haveFrameRate, options.frameRate);
    engine_->setRecording(options.record);
    engine_->setSupplyPosition(options.supplyPosition);
    engine_->setMuted(true);  /* there is no device to monitor to */

    const auto pluginFile = options.plugin != juce::File() ? options.plugin : defaultPluginFile();
    if (pluginFile == juce::File()) {
      fail("No plugin given and none found above this executable. "
           "Pass --plugin=<path/to/Open Audio Analyzer.vst3>.");
      return;
    }

    error = engine_->loadPluginFromFile(pluginFile);
    if (error.isNotEmpty()) {
      fail(error);
      return;
    }

    const double loopEnd = options.loopEnd >= 0.0 ? options.loopEnd
                                                  : engine_->trackLengthSeconds();
    engine_->setLoopRegion(options.loopStart, loopEnd);
    engine_->setLooping(options.loop);

    FakeDawEngine::OfflineRun run;
    run.sampleRate  = options.sampleRate;
    run.blockFrames = options.blockFrames;
    run.seconds     = options.seconds;
    run.speed       = options.speed;
    run.roll        = !options.parked;
    run.relocateAtSeconds = options.relocateAt;

    const auto description = engine_->pluginDescription();

    /* One line per fact, prefixed, so that a person reading a CI log and a test
     * grepping for a value want the same output. */
    std::cout << "fake-daw: plugin=" << description.name
              << " format=" << description.pluginFormatName << "\n"
              << "fake-daw: track=" << engine_->trackFile().getFileName()
              << " rate=" << engine_->trackSampleRate()
              << " channels=" << engine_->trackChannels()
              << " length=" << engine_->trackLengthSeconds() << "\n"
              << "fake-daw: rendering seconds="
              << (options.seconds > 0.0 ? options.seconds : engine_->trackLengthSeconds())
              << " block=" << run.blockFrames
              << " speed=" << run.speed
              << " loop=" << (options.loop ? 1 : 0)
              << " roll=" << (run.roll ? 1 : 0)
              << " relocateAt=" << run.relocateAtSeconds
              << std::endl;

    /* No capture: `JUCEApplication::quit` is static, and asking for `this` in a
     * callback that outlives nothing is a warning the recommended flags treat
     * as noise worth removing. */
    runner_ = std::make_unique<OfflineRunner>(*engine_, run, [] { quit(); });
  }

  /* ------------------------------------------------------------------- */

  class MainWindow final : public juce::DocumentWindow {
  public:
    MainWindow(const juce::String& name, FakeDawEngine& engine)
        : juce::DocumentWindow(name,
                               juce::Desktop::getInstance().getDefaultLookAndFeel().findColour(
                                   juce::ResizableWindow::backgroundColourId),
                               juce::DocumentWindow::allButtons) {
      setUsingNativeTitleBar(true);

      auto* content = new FakeDawComponent(engine);
      component_ = content;
      setContentOwned(content, true);

      setResizable(true, false);
      setResizeLimits(640, 420, 1600, 1200);
      centreWithSize(getWidth(), getHeight());
      setVisible(true);
    }

    FakeDawComponent& component() { return *component_; }

    void closeButtonPressed() override {
      juce::JUCEApplication::getInstance()->systemRequestedQuit();
    }

  private:
    FakeDawComponent* component_ = nullptr;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(MainWindow)
  };

  std::unique_ptr<FakeDawEngine>  engine_;
  std::unique_ptr<MainWindow>     window_;
  std::unique_ptr<OfflineRunner>  runner_;
};

}  // namespace oaa::host

START_JUCE_APPLICATION(oaa::host::FakeDawApplication)
