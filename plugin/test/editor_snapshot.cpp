/*
 * editor_snapshot.cpp — photographs the plugin's window, without a DAW.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The plugin's editor is the one surface in this repository that no test suite
 * can look at. `flutter test` renders the application's widgets to an image and
 * two of Phase 8's layout defects were found that way and by nothing else; the
 * plugin had no equivalent, so the only way to see this window was to load the
 * bundle in a DAW, and the only way to see its *interesting* states — dropped
 * frames, a host with no playhead, a link that came up and went away — was to
 * arrange for them.
 *
 * So this renders `StatusPanel` straight to a PNG. It needs no window server
 * surface, no screen-recording permission and no host: `createComponentSnapshot`
 * rasterises a component that was never added to a desktop. The states come
 * from a table below rather than from a running `Streamer`, which is the whole
 * reason the panel takes a `Status` by value.
 *
 *   ./oaa_editor_snapshot <output-directory> [path/to/plugin.vst3]
 *
 * ---------------------------------------------------------------------------
 * The sixth picture
 *
 * The five above are `StatusPanel` rendered directly, which is the drawing but
 * is not the product. The last one loads the **built VST3 bundle** through
 * JUCE's own VST3 host, asks the shipped factory for an editor and photographs
 * that — so what it shows is the thing a DAW would load, out of the bundle a
 * user would install, with the real processor and the real streaming thread
 * behind it. If the Open Audio Analyzer app happens to be listening on 47822
 * while it runs, the picture shows a live link rather than a mock of one.
 *
 * It is also the only check in this repository that the bundle *loads at all*.
 * `plugin/CMakeLists.txt` goes to some trouble over signing and architecture
 * because a bundle a DAW refuses and a bundle that is not installed are the
 * same event to the user — and until this, nothing short of opening a DAW would
 * notice. It is skipped rather than fatal when no bundle is found, so a build
 * with `-DOAA_BUILD_PLUGIN=ON` but no VST3 yet still writes the five.
 *
 * No audio device is opened anywhere here. That matters more than it sounds:
 * `AudioDeviceManager` is what the fake DAW's window path starts with, and a
 * machine whose `coreaudiod` is wedged blocks it forever before any window
 * appears.
 *
 * Nothing here ships.
 */

#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_gui_basics/juce_gui_basics.h>

#include "OaaPluginEditor.h"

namespace {

using Status = oaa::Streamer::Status;

struct Shot {
  const char* name;
  Status      status;
};

Status waiting() {
  return Status{};
}

Status connected() {
  Status s;
  s.connected          = true;
  s.everConnected      = true;
  s.sampleRate         = 48000;
  s.channels           = 2;
  s.elapsedSeconds     = 3742.0;
  s.lufsIntegrated     = -14.3f;
  s.hostGivesTransport = true;
  return s;
}

Status reconnecting() {
  Status s = connected();
  s.connected          = false;
  s.lufsIntegrated     = -9.8f;
  s.elapsedSeconds     = 61.0;
  return s;
}

Status noPlayhead() {
  Status s = connected();
  s.hostGivesTransport = false;
  s.lufsIntegrated     = -23.7f;
  s.elapsedSeconds     = 12.0;
  return s;
}

Status dropping() {
  Status s = connected();
  s.droppedFrames      = 2048;
  s.lufsIntegrated     = -11.2f;
  s.elapsedSeconds     = 205.0;
  return s;
}

/* What the held window is called, so a shell can find it in the window list. */
constexpr const char* kBundleWindowTitle = "Open Audio Analyzer VST3";

/* Writes `image` to `dir/name.png`, or returns false having said why. */
bool writePng(const juce::Image& image, const juce::File& dir,
              const juce::String& name) {
  const juce::File file = dir.getChildFile(name + ".png");
  file.deleteFile();

  juce::FileOutputStream stream(file);
  if (!stream.openedOk()) {
    std::fprintf(stderr, "cannot write %s\n", file.getFullPathName().toRawUTF8());
    return false;
  }

  juce::PNGImageFormat png;
  if (!png.writeImageToStream(image, stream)) {
    std::fprintf(stderr, "cannot encode %s\n", file.getFullPathName().toRawUTF8());
    return false;
  }

  std::printf("%s\n", file.getFullPathName().toRawUTF8());
  return true;
}

/* The VST3 this build produced, beside the executable. */
juce::File builtBundle() {
  const auto exe = juce::File::getSpecialLocation(juce::File::currentExecutableFile);

  for (auto dir = exe.getParentDirectory(); dir.exists() && !dir.isRoot();
       dir = dir.getParentDirectory()) {
    const auto candidate = dir.getChildFile("OaaPlugin_artefacts")
                               .getChildFile("Release")
                               .getChildFile("VST3")
                               .getChildFile("Open Audio Analyzer.vst3");
    if (candidate.exists())
      return candidate;
  }

  return {};
}

/*
 * Loads the bundle, puts its editor on screen, and leaves it there.
 *
 * **On screen is not optional, and finding that out cost a black PNG.** JUCE's
 * VST3 host hands back a `VST3PluginWindow`: a component of *this* process
 * wrapping a native view that the plugin's `IPlugView` is attached to. The
 * attach happens when the wrapper becomes visible, and the plugin builds its
 * editor inside its own JUCE instance on the far side of it. So a wrapper that
 * was never shown has no plugin editor in it at all, and
 * `createComponentSnapshot` — which walks *this* process's component tree —
 * renders the empty wrapper and nothing else. That is the difference between
 * the five pictures above and this one: those are a component, this is a
 * loaded bundle, and only one of the two can be photographed off-screen.
 *
 * So the window is real, and capturing it is the caller's job:
 * `screencapture -l <window-id>` from a shell, or a person looking at it. The
 * hold is what gives them time.
 *
 * `runDispatchLoopUntil` rather than a sleep, because everything here arrives
 * on the message loop: the attach, the editor's `juce::Timer`, and the
 * streaming thread's news about whether it found the app.
 */
bool shootBundle(const juce::File& bundle, int holdMs) {
  juce::VST3PluginFormat format;

  juce::OwnedArray<juce::PluginDescription> found;
  format.findAllTypesForFile(found, bundle.getFullPathName());
  if (found.isEmpty()) {
    std::fprintf(stderr, "no plugin in %s\n", bundle.getFullPathName().toRawUTF8());
    return false;
  }

  juce::AudioPluginFormatManager plugins;
  plugins.addFormat(new juce::VST3PluginFormat());

  juce::String error;
  auto instance = plugins.createPluginInstance(*found.getFirst(), 48000.0, 512, error);
  if (instance == nullptr) {
    std::fprintf(stderr, "cannot load: %s\n", error.toRawUTF8());
    return false;
  }

  /* Not a formality. `prepareToPlay` is what builds the engine and starts the
   * streaming thread, and the panel has nothing to report until it has. */
  instance->prepareToPlay(48000.0, 512);

  auto* editor = instance->createEditorIfNeeded();
  if (editor == nullptr) {
    std::fprintf(stderr, "the plugin offered no editor\n");
    instance->releaseResources();
    return false;
  }

  editor->setOpaque(true);
  /* Borderless, and that is a finding rather than a preference: with
   * `windowHasTitleBar` a window manager on this machine snapped the window to
   * the top-left corner and shortened it to 252, which reads exactly like the
   * plugin misreporting its own size. Given no title bar it stays where it is
   * put at the 440 x 316 the editor asks for. Nothing here needs a title bar —
   * the window lives for the length of the hold and a DAW draws its own frame
   * around this anyway. */
  editor->addToDesktop(0);
  editor->setTopLeftPosition(140, 140);
  editor->setVisible(true);
  editor->toFront(true);

  if (auto* peer = editor->getPeer())
    peer->setTitle(kBundleWindowTitle);

  /* Let the attach settle before reporting a size: the wrapper is sized from
   * `IPlugView::getSize`, which the plugin cannot answer until it has one. */
  juce::MessageManager::getInstance()->runDispatchLoopUntil(600);
  editor->setSize(editor->getWidth(), editor->getHeight());

  std::printf("editor %d x %d\n", editor->getWidth(), editor->getHeight());
  std::printf("%s is on screen for %d ms — capture it by title \"%s\"\n",
              bundle.getFileName().toRawUTF8(), holdMs, kBundleWindowTitle);
  std::fflush(stdout);

  juce::MessageManager::getInstance()->runDispatchLoopUntil(holdMs);

  editor->removeFromDesktop();
  instance->editorBeingDeleted(editor);
  delete editor;
  instance->releaseResources();
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  juce::ScopedJuceInitialiser_GUI gui;

  const juce::File out = argc > 1
      ? juce::File::getCurrentWorkingDirectory().getChildFile(argv[1])
      : juce::File::getCurrentWorkingDirectory();
  out.createDirectory();

  const Shot shots[] = {
      {"waiting", waiting()},
      {"connected", connected()},
      {"reconnecting", reconnecting()},
      {"no-playhead", noPlayhead()},
      {"dropping", dropping()},
  };

  for (const auto& shot : shots) {
    oaa::StatusPanel panel;
    panel.setSize(oaa::StatusPanel::kWidth, oaa::StatusPanel::kHeight);
    panel.setStatus(shot.status);

    if (!writePng(panel.createComponentSnapshot(panel.getLocalBounds(), false, 2.0f),
                  out, shot.name))
      return 1;
  }

  /* Off by default: loading the bundle puts a window on screen, and the common
   * use of this tool is the five off-screen pictures. `--hold=<ms>` asks for
   * the sixth. */
  int holdMs = 0;
  juce::File bundle;
  for (int i = 2; i < argc; ++i) {
    const juce::String argument(argv[i]);
    if (argument.startsWith("--hold="))
      holdMs = juce::jlimit(500, 120000, argument.fromFirstOccurrenceOf("=", false, false)
                                             .getIntValue());
    else
      bundle = juce::File::getCurrentWorkingDirectory().getChildFile(argument);
  }

  if (holdMs == 0)
    return 0;

  if (bundle == juce::File())
    bundle = builtBundle();

  if (!bundle.exists()) {
    std::fprintf(stderr, "no VST3 bundle found\n");
    return 1;
  }

  return shootBundle(bundle, holdMs) ? 0 : 1;
}
