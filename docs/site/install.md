# Install

Every release publishes four installers and a command-line binary. Pick the one
for your machine; there is nothing else to set up.

| Platform | Download | Notes |
| --- | --- | --- |
| macOS 11+ | `Bel-<version>-macos-<arch>.dmg` | Universal — Apple silicon and Intel. |
| Windows 10 1809+ | `Bel-<version>-windows-x64.msix` | |
| Linux | `Bel-<version>-<arch>.AppImage` | One file, no root. |
| Linux | `Bel-<version>-<arch>.flatpak` | Sandboxed, updates in place. |
| Any | `bel` / `bel.exe` | The command-line analyser, standalone. |

Releases are on the
[releases page](https://github.com/JonasGrunau/open_music_analyzer/releases).

## macOS

Open the dmg and drag **Bel** to Applications.

**Bel will ask for microphone permission the first time you choose a capture
device.** macOS treats any audio input as the microphone, including a loopback
device carrying your DAW's output. Declining it leaves Bel with the test tone
and silence, and the reason is shown rather than logged.

**There is no Mac App Store build and there will not be one.** The store
requires the app sandbox, and a sandboxed application has its home directory
redirected into `~/Library/Containers`, which would put your presets, skins and
delivery targets somewhere no user goes looking and no override could escape.
Bel is distributed directly, signed with a Developer ID and notarised.

### System audio

This is the one place Bel is honestly behind Decibel, which ships its own
signed monitoring driver. Bel does not, so to meter *what your Mac is playing*
rather than what an input is hearing you need a loopback device:

- [BlackHole](https://existential.audio/blackhole/) — free, and the usual
  answer. Create a Multi-Output Device in Audio MIDI Setup containing both your
  real output and BlackHole, then select BlackHole as Bel's source.
- Loopback, SoundSource, or any interface with a loopback channel.

If you are metering a DAW, the [plugin](#in-a-daw) is better than any of these:
it takes the buffer directly and brings the transport with it.

## Windows

Double-click the msix.

**An unsigned msix will not install.** Windows refuses one outright, with a
message that does not say so clearly. Release builds are signed; if you built
your own, see [Building](building.html#installers).

Bel asks for microphone permission on first use of a capture device, and
Windows may also need it enabled under **Settings → Privacy → Microphone** for
desktop apps.

For system audio, use a WASAPI loopback-capable device or a virtual cable such
as [VB-Audio Cable](https://vb-audio.com/Cable/).

## Linux

### AppImage

```sh
chmod +x Bel-0.1.0-x86_64.AppImage
./Bel-0.1.0-x86_64.AppImage
```

GTK 3 is expected from the host — every desktop Linux that can run a Flutter
application already has it — and everything else travels inside the file. The
AppImage is built on the oldest supported runner, because glibc is
forward-compatible and not backward-compatible: one built on a newer
distribution simply refuses to start on an older one.

### Flatpak

```sh
flatpak install --user Bel-0.1.0-x86_64.flatpak
flatpak run dev.belmeter.bel
```

The flatpak carries its own runtime, so the glibc caveat above does not apply.
It is granted audio, network and filesystem access —
[the manifest says why for each](https://github.com/JonasGrunau/open_music_analyzer/blob/main/packaging/linux/flatpak/dev.belmeter.bel.yml).

For system audio on either, PipeWire's own loopback or `pactl load-module
module-null-sink` gives you a monitor source Bel can open.

## The command-line analyser

`bel` is a single standalone binary with no Flutter runtime and no shared
libraries to install. Put it on your `PATH`:

```sh
chmod +x bel
sudo mv bel /usr/local/bin/
```

It is the same measurement code the application runs. See
[Analysing files](analysing-files.html).

## Where Bel keeps your configuration

Settings, presets, delivery targets and skins are plain JSON, one file each, in
a directory you can read, edit, copy between machines and put in a repository:

| Platform | Directory |
| --- | --- |
| macOS | `~/Library/Application Support/Bel` |
| Windows | `%APPDATA%\Bel` |
| Linux | `$XDG_CONFIG_HOME/bel`, or `~/.config/bel` |

Two overrides, in order of precedence:

```sh
bel --config-dir /path/to/config     # or the application, via --config-dir
export BEL_CONFIG_DIR=/path/to/config
```

The flag wins over the variable, and the variable wins over the convention. On
macOS the flag is the one that works for a `.app`: passing an environment
variable means launching the binary inside the bundle, and a bare binary launch
changes how macOS attributes the microphone request — so the variable and
device capture cannot be used in the same run.

```sh
open -a /Applications/bel.app --args --config-dir=/path/to/config
```

## Uninstalling

Bel writes nothing outside the configuration directory above. Delete the
application, delete that directory, and nothing of it remains.
