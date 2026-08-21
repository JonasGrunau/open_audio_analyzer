/*
 * FakeDawOptions.h — the command line.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * ---------------------------------------------------------------------------
 * Every switch here exists so that something can be automated
 *
 * A window with buttons is what you want when you are looking at a meter and
 * deciding whether it is right. It is useless as a gate: nothing in CI can
 * click Play, and a test that needs a person is a test that runs once.
 *
 * So the same host takes its whole configuration from argv and, with
 * `--headless`, needs neither a window nor a sound card. Everything the plugin
 * can observe about a host is reachable from here, including the two cases a
 * real DAW will not do on request: withholding the transport entirely, and
 * looping a one-second region so that a relocate happens three times a
 * minute rather than when somebody remembers to drag the playhead.
 */

#pragma once

#include <juce_audio_basics/juce_audio_basics.h>
#include <juce_core/juce_core.h>

#include <cstdlib>

namespace oaa::host {

struct Options {
  juce::File plugin;
  juce::File track;

  double bpm                = 120.0;
  int    timeSigNumerator   = 4;
  int    timeSigDenominator = 4;

  bool                               haveFrameRate = true;
  juce::AudioPlayHead::FrameRateType frameRate     = juce::AudioPlayHead::fps25;

  bool   loop           = false;
  double loopStart      = 0.0;
  double loopEnd        = -1.0;  /* negative = the end of the track */
  bool   supplyPosition = true;
  bool   record         = false;
  bool   mute           = false;
  bool   play           = false;

  bool   headless    = false;
  bool   parked      = false;  /* render, but leave the transport stopped */
  double relocateAt  = 0.0;    /* stop, jump to the start, play again */
  double seconds     = 0.0;    /* 0 = the whole track */
  double speed       = 1.0;    /* 0 = as fast as it will go */
  int    blockFrames = 512;
  double sampleRate  = 0.0;    /* 0 = follow the track */

  bool         help = false;
  juce::String error;
};

/*
 * ASCII only, deliberately.
 *
 * An em dash in here reached the terminal as a stray `\xe2` and two unprintable
 * bytes. The cause is not `std::cout`: `juce::String`'s `const char*`
 * constructor reads its argument through `CharPointer_ASCII`, one byte to one
 * codepoint, so a UTF-8 literal is mangled on the way *in* and faithfully
 * re-encoded on the way out. `juce::String::fromUTF8` is the fix where the
 * typography matters — see `Streamer::ensureConnected`, where the same mistake
 * put mojibake in the application's title bar.
 *
 * Here it does not matter: help text has no need for an em dash, and ASCII owns
 * no encoding question at all in a tool whose whole purpose is to be
 * trustworthy while something else is being debugged.
 */
inline juce::String usageText() {
  return
R"(Open Audio Analyzer - fake DAW

A host that plays an audio file through the Open Audio Analyzer VST3 or Audio
Unit and gives it a transport, so that the plugin can be exercised without
opening a real DAW.

  oaa-fake-daw [options]

What to load
  --plugin=<path>       VST3 bundle, or an installed Audio Unit's .component.
                        Omitted: the newest build found above this executable.
  --track=<path>        Audio file to play. WAV, AIFF, FLAC and Ogg always
                        work; MP3 and the Apple formats depend on the platform.

Where the plugin streams to is the plugin's own business: 127.0.0.1:47822 unless
its editor says otherwise, which is the same port the application listens on.
There is deliberately no switch for it here - see FakeDawEngine.h.

The transport the plugin is told about
  --bpm=<number>        Default 120.
  --time-sig=<n>/<d>    Default 4/4.
  --frame-rate=<name>   23.976, 24, 25, 29.97, 29.97d, 30, 30d, 60, 60d, or
                        none. Default 25. "none" reports no timecode rate,
                        which is a thing real hosts do.
  --loop                Loop the region below, which raises the plugin's
                        discontinuity flag once per lap.
  --loop-start=<s>      Default 0.
  --loop-end=<s>        Default the end of the track.
  --record              Set the recording flag while rolling.
  --no-playhead         Supply no transport at all. The plugin's display should
                        fall back to dashes rather than showing bar 1.

Running it
  --play                Start rolling as soon as everything is loaded.
  --mute                Do not send the audio to the output device.
  --headless            No window and no audio device: render blocks on a
                        background thread. This is the mode a test uses.
  --parked              Headless: render blocks with the transport stopped.
                        A DAW runs its graph whether or not it is playing, and
                        this is the state it spends most of its time in.
  --relocate-at=<s>     Headless: play until here, stop, park, jump back to the
                        start and play again. The gesture docs/WIRE.md names as
                        the reason the discontinuity bit exists.
  --seconds=<s>         Headless: how much transport time to render.
  --speed=<x>           Headless: 1 is real time, 0 is as fast as it will go.
  --block=<frames>      Headless: block size. Default 512.
  --rate=<hz>           Headless: sample rate. Default the track's.
  --help                This.
)";
}

namespace detail {

/*
 * `juce::String::getDoubleValue` answers 0.0 for anything it cannot read.
 *
 * That turns `--seconds=ten` into `--seconds=0`, which this host reads as
 * "render the whole track" — so the switch is silently ignored, and a test that
 * asked for a bounded run gets an unbounded one and passes for the wrong
 * reason. It is the failure the note above `parseOptions` had already committed
 * to refusing, wearing a different hat: an unrecognised *value* is no better
 * than an unrecognised key.
 */
inline bool readNumber(const juce::String& text, double minimum, double& out) {
  const auto trimmed = text.trim();
  if (trimmed.isEmpty())
    return false;

  char*        end    = nullptr;
  const double parsed = std::strtod(trimmed.toRawUTF8(), &end);

  /* `end` stopping short of the terminator is the whole check: it is what tells
   * "12" from "12kg", and strtod happily reports the second as 12. */
  if (end == nullptr || *end != '\0')
    return false;

  /* Written as `>=` rather than `<` so that NaN — which "3-2" does not produce
   * but "nan" does — fails every comparison and is refused. */
  if (!(parsed >= minimum))
    return false;

  out = parsed;
  return true;
}

inline bool matchFrameRate(const juce::String& name,
                           bool& have,
                           juce::AudioPlayHead::FrameRateType& out) {
  using FR = juce::AudioPlayHead;

  have = true;

  if (name == "none")    { have = false; return true; }
  if (name == "23.976")  { out = FR::fps23976;    return true; }
  if (name == "24")      { out = FR::fps24;       return true; }
  if (name == "25")      { out = FR::fps25;       return true; }
  if (name == "29.97")   { out = FR::fps2997;     return true; }
  if (name == "29.97d")  { out = FR::fps2997drop; return true; }
  if (name == "30")      { out = FR::fps30;       return true; }
  if (name == "30d")     { out = FR::fps30drop;   return true; }
  if (name == "60")      { out = FR::fps60;       return true; }
  if (name == "60d")     { out = FR::fps60drop;   return true; }

  return false;
}

}  // namespace detail

/*
 * Anything unrecognised is an error rather than a shrug. A host that silently
 * ignores `--secconds=10` renders the whole track and the test that asked for
 * ten seconds passes for the wrong reason.
 */
inline Options parseOptions(const juce::StringArray& args) {
  Options options;

  const auto fail = [&options](const juce::String& message) {
    if (options.error.isEmpty())
      options.error = message;
  };

  for (const auto& raw : args) {
    const auto argument = raw.unquoted();

    if (argument == "--help" || argument == "-h") {
      options.help = true;
      continue;
    }
    if (argument == "--headless")    { options.headless = true;       continue; }
    if (argument == "--parked")      { options.parked = true;         continue; }
    if (argument == "--play")        { options.play = true;           continue; }
    if (argument == "--loop")        { options.loop = true;           continue; }
    if (argument == "--record")      { options.record = true;         continue; }
    if (argument == "--mute")        { options.mute = true;           continue; }
    if (argument == "--no-playhead") { options.supplyPosition = false; continue; }

    if (!argument.startsWith("--") || !argument.contains("=")) {
      fail("Unrecognised argument: " + argument);
      continue;
    }

    const auto key   = argument.upToFirstOccurrenceOf("=", false, false);
    const auto value = argument.fromFirstOccurrenceOf("=", false, false);

    if (key == "--plugin")     options.plugin = juce::File::getCurrentWorkingDirectory().getChildFile(value);
    else if (key == "--track") options.track  = juce::File::getCurrentWorkingDirectory().getChildFile(value);
    else if (key == "--bpm") {
      if (!detail::readNumber(value, 1.0, options.bpm))
        fail("--bpm wants a number of at least 1.");
    } else if (key == "--time-sig") {
      const auto numerator   = value.upToFirstOccurrenceOf("/", false, false).getIntValue();
      const auto denominator = value.fromFirstOccurrenceOf("/", false, false).getIntValue();
      if (numerator <= 0 || denominator <= 0)
        fail("--time-sig wants something like 7/8.");
      else {
        options.timeSigNumerator   = numerator;
        options.timeSigDenominator = denominator;
      }
    } else if (key == "--frame-rate") {
      if (!detail::matchFrameRate(value, options.haveFrameRate, options.frameRate))
        fail("--frame-rate does not know \"" + value + "\". See --help.");
    }
    else if (key == "--loop-start") {
      if (!detail::readNumber(value, 0.0, options.loopStart))
        fail("--loop-start wants a number of seconds, zero or more.");
    } else if (key == "--loop-end") {
      if (!detail::readNumber(value, 0.0, options.loopEnd))
        fail("--loop-end wants a number of seconds, zero or more.");
    } else if (key == "--seconds") {
      if (!detail::readNumber(value, 0.0, options.seconds))
        fail("--seconds wants a number of seconds, zero or more.");
    } else if (key == "--relocate-at") {
      if (!detail::readNumber(value, 0.0, options.relocateAt))
        fail("--relocate-at wants a number of seconds, zero or more.");
    } else if (key == "--speed") {
      if (!detail::readNumber(value, 0.0, options.speed))
        fail("--speed wants a multiplier of zero or more, where 0 is unpaced.");
    } else if (key == "--block") {
      double frames = 0.0;
      if (!detail::readNumber(value, 16.0, frames) || frames > 8192.0)
        fail("--block wants a frame count between 16 and 8192.");
      else
        options.blockFrames = static_cast<int>(frames);
    } else if (key == "--rate") {
      if (!detail::readNumber(value, 8000.0, options.sampleRate))
        fail("--rate wants a sample rate of at least 8000.");
    } else {
      fail("Unrecognised option: " + key);
    }
  }

  if (options.headless && !options.track.exists() && options.error.isEmpty())
    fail("--headless needs a --track: there is no device to fall back to and "
         "nothing to measure without one.");

  return options;
}

}  // namespace oaa::host
