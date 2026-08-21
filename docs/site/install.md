# Install

Every release publishes four installers, a command-line binary and the DAW
plugin. Pick the one for your machine; there is nothing else to set up.

| Platform | Download | Notes |
| --- | --- | --- |
| macOS 11+ | `Open.Audio.Analyzer-<version>-macos-<arch>.dmg` | Universal — Apple silicon and Intel. |
| Windows 10 1809+ | `Open.Audio.Analyzer-<version>-windows-x64.msix` | |
| Linux | `Open.Audio.Analyzer-<version>-<arch>.AppImage` | One file, no root. |
| Linux | `Open.Audio.Analyzer-<version>-<arch>.flatpak` | Sandboxed, updates in place. |
| Any | `oaa-cli-<platform>.tar.gz` / `.zip` | The command-line analyser. No Flutter runtime. |
| Any | `oaa-plugin-<platform>.tar.gz` / `.zip` | The VST3 and Audio Unit. Not an installer — see [In a DAW](#in-a-daw). |

Releases are on the
[releases page](https://github.com/JonasGrunau/open_audio_analyzer/releases).

The periods in those names are GitHub's: the build calls the file
`Open Audio Analyzer-<version>-…` and GitHub replaces the spaces when it
publishes it, so a file you download is dot-separated and one you build
yourself is not.

## macOS

Open the dmg and drag **Open Audio Analyzer** to Applications.

**Open Audio Analyzer will ask for microphone permission the first time you
choose a capture device.** macOS treats any audio input as the microphone,
including a loopback device carrying your DAW's output. Declining it leaves Open
Audio Analyzer with the test tone and silence, and the reason is shown rather
than logged.

**There is no Mac App Store build and there will not be one.** The store
requires the app sandbox, and a sandboxed application has its home directory
redirected into `~/Library/Containers`, which would put your presets, skins and
delivery targets somewhere no user goes looking and no override could escape.
Open Audio Analyzer is distributed directly, signed with a Developer ID and
notarised.

### System audio

**On macOS 14.2 and later there is nothing to install.** Pick **System Output**
from the source menu in the status bar — it is the first entry, and it is named
after the output device it is metering, so you can see what you are listening
to. Open Audio Analyzer measures what is being sent to that device without
rerouting anything, so your audio keeps coming out of the speakers while it is
being metered.

This is a Core Audio process tap rather than a driver, which is why there is no
installer, no password prompt and no reboot. Decibel ships a signed monitoring
driver to do the same job; the tap did not exist when it was written.

Three things worth knowing:

- **macOS may ask for permission to record system audio** the first time you
  choose it. If you decline, the tap delivers silence rather than an error, so
  the meters sit at the floor — which looks exactly like genuinely quiet audio.
  If that happens with something obviously playing, look under **System Settings
  → Privacy & Security**.
- **It follows your output device** when you change it, as long as the new one
  has the same sample rate and channel count. Swapping between two stereo
  devices at 48 kHz — speakers and headphones, say — just works. A device with a
  different format stops the tap instead, because the meters are built around
  one format and cannot be rebuilt mid-measurement; choose the source again to
  pick the new device up.
- **It captures every application at once,** mixed as your output device
  receives it. There is no per-application selection.

**Below macOS 14.2** the entry is absent, because the API is not there. Use a
loopback device instead:

- [BlackHole](https://existential.audio/blackhole/) — free, and the usual
  answer. Create a Multi-Output Device in Audio MIDI Setup containing both your
  real output and BlackHole, then select BlackHole as Open Audio Analyzer's
  source.
- Loopback, SoundSource, or any interface with a loopback channel.

If you are metering a DAW, the [plugin](#in-a-daw) is better than any of these:
it takes the buffer directly and brings the transport with it.

## Windows

Double-click the msix.

**An unsigned msix will not install.** Windows refuses one outright, with a
message that does not say so clearly. Release builds are signed; if you built
your own, see [Building](building.html#installers).

Open Audio Analyzer asks for microphone permission on first use of a capture
device, and Windows may also need it enabled under **Settings → Privacy →
Microphone** for desktop apps.

For system audio, use a WASAPI loopback-capable device or a virtual cable such
as [VB-Audio Cable](https://vb-audio.com/Cable/).

## Linux

### AppImage

```sh
chmod +x Open.Audio.Analyzer-0.4.0-x86_64.AppImage
./Open.Audio.Analyzer-0.4.0-x86_64.AppImage
```

GTK 3 is expected from the host — every desktop Linux that can run a Flutter
application already has it — and everything else travels inside the file. The
AppImage is built on the oldest supported runner, because glibc is
forward-compatible and not backward-compatible: one built on a newer
distribution simply refuses to start on an older one.

### Flatpak

```sh
flatpak install --user Open.Audio.Analyzer-0.4.0-x86_64.flatpak
flatpak run dev.openaudioanalyzer.oaa
```

The flatpak carries its own runtime, so the glibc caveat above does not apply.
It is granted audio, network and filesystem access — [the manifest says why for
each](https://github.com/JonasGrunau/open_audio_analyzer/blob/main/packaging/linux/flatpak/dev.openaudioanalyzer.oaa.yml).

For system audio on either, PipeWire's own loopback or `pactl load-module
module-null-sink` gives you a monitor source Open Audio Analyzer can open.

## In a DAW

The plugin is a **VST3** and an **Audio Unit** that draw nothing. They measure
the buffer your DAW gives them and stream it to the desktop application, which
displays it — so the app has to be running, and the plugin finds it by itself on
`127.0.0.1:47822` whichever of the two you start first.

`oaa-plugin-<platform>` is an archive, not an installer. Copy the *bundle* — the
`.vst3` or `.component` itself, not the directory holding it — into the folder
your DAW scans. On a machine that has never had a plugin installed, that folder
does not exist yet:

| Platform | VST3 | Audio Unit |
| --- | --- | --- |
| macOS | `~/Library/Audio/Plug-Ins/VST3` | `~/Library/Audio/Plug-Ins/Components` |
| Windows | `%CommonProgramFiles%\VST3` | — |
| Linux | `~/.vst3` | — |

```sh
# macOS
mkdir -p ~/Library/Audio/Plug-Ins/VST3 ~/Library/Audio/Plug-Ins/Components
cp -R "VST3/Open Audio Analyzer.vst3"    ~/Library/Audio/Plug-Ins/VST3/
cp -R "AU/Open Audio Analyzer.component" ~/Library/Audio/Plug-Ins/Components/
xattr -dr com.apple.quarantine \
  ~/Library/Audio/Plug-Ins/VST3/"Open Audio Analyzer.vst3" \
  ~/Library/Audio/Plug-Ins/Components/"Open Audio Analyzer.component"
```

**The `xattr` line is not optional on macOS.** Your browser marks every file it
downloads, the mark survives being unpacked, and Gatekeeper then refuses to load
the bundle — silently. The plugin is simply absent from the DAW's browser, with
nothing logged and no message anywhere, which is indistinguishable from having
copied it to the wrong place. The bundles are signed, but ad-hoc rather than
notarised: enough for macOS to load them, not enough to clear the flag for you.
A plugin you built yourself has no flag to remove.

**Ableton Live also has to be told to look there** — Preferences → Plug-Ins →
*Use VST3 Plug-In System Folders*. It then appears under **Open Audio
Analyzer**. Live rescans on launch; a plugin copied in while it is open needs a
restart.

Insert it on a track, a bus or the master. Its own window is a status panel —
connected or not, sample rate, channel count, and whether the host is giving it
a playhead — and nothing else; the meters are in the app. Several inserts can be
connected at once and the most recently added is the one on screen, because
adding it is the act of choosing it.

The host's transport comes across with the audio, so the app's status bar reads
back the DAW's position, tempo and time signature, and relays them to an
attached tablet.

## The command-line analyser

`oaa` needs no Flutter runtime and nothing installed. It is an archive of two
files — the executable and the engine as a shared library beside it — and the
executable finds the library by its own location, so keep them together and
link to the executable rather than copying it out:

```sh
tar -xzf oaa-cli-Linux.tar.gz -C ~/.local/opt/oaa
sudo ln -s ~/.local/opt/oaa/bin/oaa /usr/local/bin/oaa
```

It is the same measurement code the application runs. See
[Analysing files](analysing-files.html).

## Where Open Audio Analyzer keeps your configuration

Settings, presets, delivery targets and skins are plain JSON, one file each, in
a directory you can read, edit, copy between machines and put in a repository:

| Platform | Directory |
| --- | --- |
| macOS | `~/Library/Application Support/Open Audio Analyzer` |
| Windows | `%APPDATA%\Open Audio Analyzer` |
| Linux | `$XDG_CONFIG_HOME/oaa`, or `~/.config/oaa` |
| iPadOS | `Library/Application Support/Open Audio Analyzer` inside the app's own container |
| Android | `oaa` inside the app's own `files` directory |

The two tablets are the exception to "a directory you can read": both systems
give an app a private directory, so the files are on the device but not
reachable from a file manager or from a desktop. Settings → Session prints the
path. Android's comes from `getFilesDir()`, because nothing in an Android
process names a directory it is allowed to write to, and it is removed with the
app.

Two overrides, in order of precedence:

```sh
oaa --config-dir /path/to/config     # or the application, via --config-dir
export OAA_CONFIG_DIR=/path/to/config
```

The flag wins over the variable, and the variable wins over the convention. On
macOS the flag is the one that works for a `.app`: passing an environment
variable means launching the binary inside the bundle, and a bare binary launch
changes how macOS attributes the microphone request — so the variable and
device capture cannot be used in the same run.

```sh
open -a "/Applications/Open Audio Analyzer.app" --args --config-dir=/path/to/config
```

## Uninstalling

Open Audio Analyzer writes nothing outside the configuration directory above.
Delete the application, delete that directory, and nothing of it remains.
