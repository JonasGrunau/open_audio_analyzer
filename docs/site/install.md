# Install

Every release publishes four installers and a command-line binary. Pick the one
for your machine; there is nothing else to set up.

| Platform | Download | Notes |
| --- | --- | --- |
| macOS 11+ | `Open.Audio.Analyzer-<version>-macos-<arch>.dmg` | Universal — Apple silicon and Intel. |
| Windows 10 1809+ | `Open.Audio.Analyzer-<version>-windows-x64.msix` | |
| Linux | `Open.Audio.Analyzer-<version>-<arch>.AppImage` | One file, no root. |
| Linux | `Open.Audio.Analyzer-<version>-<arch>.flatpak` | Sandboxed, updates in place. |
| Any | `oaa-cli-<platform>.tar.gz` / `.zip` | The command-line analyser. No Flutter runtime. |

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

This is the one place Open Audio Analyzer is honestly behind Decibel, which
ships its own signed monitoring driver. Open Audio Analyzer does not, so to
meter *what your Mac is playing* rather than what an input is hearing you need a
loopback device:

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
chmod +x Open.Audio.Analyzer-0.2.0-x86_64.AppImage
./Open.Audio.Analyzer-0.2.0-x86_64.AppImage
```

GTK 3 is expected from the host — every desktop Linux that can run a Flutter
application already has it — and everything else travels inside the file. The
AppImage is built on the oldest supported runner, because glibc is
forward-compatible and not backward-compatible: one built on a newer
distribution simply refuses to start on an older one.

### Flatpak

```sh
flatpak install --user Open.Audio.Analyzer-0.2.0-x86_64.flatpak
flatpak run dev.openaudioanalyzer.oaa
```

The flatpak carries its own runtime, so the glibc caveat above does not apply.
It is granted audio, network and filesystem access — [the manifest says why for
each](https://github.com/JonasGrunau/open_audio_analyzer/blob/main/packaging/linux/flatpak/dev.openaudioanalyzer.oaa.yml).

For system audio on either, PipeWire's own loopback or `pactl load-module
module-null-sink` gives you a monitor source Open Audio Analyzer can open.

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

The iPad is the exception to "a directory you can read": iOS gives an app a
private container, so the files are on the device but not reachable from the
Files app or from a Mac. Settings → Session prints the path. An Android tablet
persists nothing at all and says so at launch — Open Audio Analyzer cannot
locate its container without a platform channel it does not have.

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
open -a /Applications/oaa.app --args --config-dir=/path/to/config
```

## Uninstalling

Open Audio Analyzer writes nothing outside the configuration directory above.
Delete the application, delete that directory, and nothing of it remains.
