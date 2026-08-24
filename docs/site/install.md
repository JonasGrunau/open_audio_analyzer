# Install

Every release publishes five desktop downloads, a command-line binary and the
DAW plugin on its own. Pick the one for your machine; there is nothing else to
set up. The iPad display is the exception and goes through TestFlight — see
[iPadOS](#ipados) for why there is nothing to download.

**Three of them install the plugin for you**, behind a checkbox that starts
ticked. If you use a DAW, those are the ones to take.

| Platform | Download | Plugin | Notes |
| --- | --- | --- | --- |
| macOS 14.2+ | `Open.Audio.Analyzer-<version>-macos.pkg` | ✅ VST3 + AU | Universal — Apple silicon and Intel. |
| Windows 10 1809+ | `Open.Audio.Analyzer-<version>-windows-x64.exe` | ✅ VST3 | |
| Linux | `Open.Audio.Analyzer-<version>-linux-<arch>.tar.gz` | ✅ VST3 | Unpack and run `./install.sh`. No root needed. |
| Linux | `Open.Audio.Analyzer-<version>-<arch>.AppImage` | — | One file, no root. Application only. |
| Linux | `Open.Audio.Analyzer-<version>-<arch>.flatpak` | — | Sandboxed, updates in place. Application only. |
| Any | `oaa-cli-<platform>.tar.gz` / `.zip` | — | The command-line analyser. No Flutter runtime. |
| Any | `oaa-plugin-<platform>.tar.gz` / `.zip` | — | The bare bundles, for installing by hand. See [In a DAW](#in-a-daw). |

The AppImage and the flatpak cannot install a plugin, and that is a property of
the formats rather than something left undone: an AppImage never installs
anything, and a flatpak's plugin would be built against the sandbox's libraries
while the DAW that has to load it runs on the host's. If you want the plugin on
Linux, take the tarball.

Releases are on the
[releases page](https://github.com/JonasGrunau/open_audio_analyzer/releases).

The periods in those names are GitHub's: the build calls the file
`Open Audio Analyzer-<version>-…` and GitHub replaces the spaces when it
publishes it, so a file you download is dot-separated and one you build
yourself is not.

## macOS

Open the pkg and follow it through. It opens on its customisation pane, with
three rows:

| Row | Installs to | Default |
| --- | --- | --- |
| Open Audio Analyzer | `/Applications` | ticked, and cannot be unticked |
| VST3 plug-in | `/Library/Audio/Plug-Ins/VST3` | ticked |
| Audio Unit | `/Library/Audio/Plug-Ins/Components` | ticked |

Untick either plug-in row if you do not want it. The application row is fixed
because the plug-ins have nothing to talk to without it — they stream what they
measure to the app over loopback, on the same machine.

The application and both plug-ins need **macOS 14.2 or later**, so there is no
longer a version that can run one and not the others. Below it the installer
declines rather than placing files that could not load.

The installer needs an administrator password, because `/Library/Audio/Plug-Ins`
is shared by every user and every DAW on the machine.

**There is no uninstaller.** macOS packages do not come with one. To remove
everything:

```sh
sudo rm -rf "/Applications/Open Audio Analyzer.app" \
  "/Library/Audio/Plug-Ins/VST3/Open Audio Analyzer.vst3" \
  "/Library/Audio/Plug-Ins/Components/Open Audio Analyzer.component"
```

Your presets, skins and settings live in `~/Library/Application Support` and are
left alone by that.

**Open Audio Analyzer will ask for microphone permission the first time you
choose a capture device.** macOS treats any audio input as the microphone,
including a loopback device carrying your DAW's output. Declining it leaves Open
Audio Analyzer with the test tone and silence, and the reason is shown rather
than logged.

**Open Audio Analyzer will ask for local network permission the first time you
publish to a tablet,** and it needs it to announce itself. Declining leaves the
port open and the advertisement blocked, so the desktop says it is publishing
and no tablet ever lists it — the panel names this now, but the two facts are
genuinely separate: a display given the address by hand still connects and
works.

**Open Audio Analyzer will ask for camera permission the first time you scan a
pairing code,** and only then — nothing else in the application uses a camera.
The image is examined for a code and is never recorded, stored or sent
anywhere. Declining leaves the other two ways of finding a host untouched, and
the panel names the setting to change rather than showing a black rectangle.

**Upgrading from 0.5.0 or earlier revokes every permission the application
holds,** because 0.6.0 changed the bundle identifier from
`dev.openaudioanalyzer.oaa` to `com.openaudioanalyzer.oaa`, and macOS keys a
permission to the identifier rather than to the application. That is **Local
Network**, **Microphone**, **Camera** and — the one that fails without saying so
— **System Audio Recording**. Each old entry under **System Settings → Privacy &
Security** belongs to an application that no longer exists; allow the new one in
each. Nothing else about the upgrade needs anything: presets, skins and paired
hosts are keyed by name rather than by identifier and are all still there.

System audio is the one to check first, because it is the only one of the four
whose refusal is silent — see below.

**There is no Mac App Store build and there will not be one.** The store
requires the app sandbox, and a sandboxed application has its home directory
redirected into `~/Library/Containers`, which would put your presets, skins and
delivery targets somewhere no user goes looking and no override could escape.
Open Audio Analyzer is distributed directly, signed with a Developer ID and
notarised.

### System audio

**There is nothing to install.** Pick **System Output**
from the source menu in the status bar — it is the first entry, and it is named
after the output device it is metering, so you can see what you are listening
to. Open Audio Analyzer measures what is being sent to that device without
rerouting anything, so your audio keeps coming out of the speakers while it is
being metered.

This is a Core Audio process tap rather than a driver, which is why there is no
installer, no password prompt and no reboot.

Three things worth knowing:

- **macOS may ask for permission to record system audio** the first time you
  choose it. If you decline, the tap delivers silence rather than an error, so
  the meters sit at the floor — which looks exactly like genuinely quiet audio.
  Apple does this deliberately: every Core Audio call still returns success and
  the callbacks still arrive on schedule, carrying nothing but zeros, so that
  software cannot tell that it has been refused. There is no error for Open
  Audio Analyzer to show you.

  If the meters sit at the floor with something obviously playing, look under
  **System Settings → Privacy & Security → System Audio Recording**. Two things
  put an application there that cannot use it: **declining once** (the prompt
  does not come back on its own), and **upgrading from 0.5.0 or earlier**, which
  changed the bundle identifier and left the old grant naming an application
  that no longer exists — so the list can show an "Open Audio Analyzer" that is
  switched on while the one you are running has never been asked about. Remove
  the stale entry, then choose **System Output** again to raise a fresh prompt.
- **It follows your output device** when you change it, as long as the new one
  has the same sample rate and channel count. Swapping between two stereo
  devices at 48 kHz — speakers and headphones, say — just works. A device with a
  different format stops the tap instead, because the meters are built around
  one format and cannot be rebuilt mid-measurement; choose the source again to
  pick the new device up.
- **It captures every application at once,** mixed as your output device
  receives it. There is no per-application selection.

macOS 14.2 is where the tapping API arrived, and it is also Open Audio
Analyzer's minimum, so there is no supported version where the entry is missing.
The loopback route older versions needed — a Multi-Output Device in Audio MIDI
Setup pairing your real output with [BlackHole](https://existential.audio/blackhole/),
or an interface with a loopback channel — still works and is still a perfectly
good way to meter one specific path, but nothing requires it any more.

If you are metering a DAW, the [plugin](#in-a-daw) is better than any of these:
it takes the buffer directly and brings the transport with it.

## Windows

Run the `.exe`. On the Select Components page:

| Component | Installs to | Default |
| --- | --- | --- |
| Open Audio Analyzer | `C:\Program Files\Open Audio Analyzer` | ticked, and cannot be unticked |
| VST3 plug-in | `C:\Program Files\Common Files\VST3` | ticked |

The installer needs administrator rights for both of those, and it registers an
uninstaller under **Settings → Apps → Installed apps**, which removes the
plug-in too.

**Windows will warn you before it runs.** SmartScreen shows *"Windows protected
your PC"*; click **More info → Run anyway**. Windows may also flag the download
in your browser first. That is the current state of the installer and not a
sign that something is wrong with the file — releases are not yet signed with an
Authenticode certificate, and an ordinary certificate would not remove the
warning immediately anyway, since SmartScreen goes by a reputation the download
has to accumulate. Verify the file against the checksums on the release page if
you want certainty.

Open Audio Analyzer asks for microphone permission on first use of a capture
device, and Windows may also need it enabled under **Settings → Privacy →
Microphone** for desktop apps.

For system audio, use a WASAPI loopback-capable device or a virtual cable such
as [VB-Audio Cable](https://vb-audio.com/Cable/).

## Linux

### Tarball

The only Linux download that carries the plugin, and the one to take if you use
a DAW.

```sh
tar -xzf Open.Audio.Analyzer-0.10.1-linux-x86_64.tar.gz
cd "Open Audio Analyzer-0.10.1-linux-x86_64"
./install.sh
```

It asks one question — whether to install the VST3 into `~/.vst3` as well —
and the default is yes. Nothing here needs root: the application goes to
`~/.local/share`, the desktop entry and icons to `~/.local/share`, and every
DAW searches `~/.vst3` without being told to.

```sh
./install.sh --no-vst3        # application only, no question asked
./install.sh --vst3           # both, no question asked
sudo ./install.sh --system    # /opt and /usr/lib/vst3, for every user
./install.sh --uninstall      # removes what it installed
```

Piped or run from a script it takes the default rather than waiting for an
answer that is never coming. The uninstaller is a copy of the same script, left
next to what it installed.

### AppImage

```sh
chmod +x Open.Audio.Analyzer-0.10.1-x86_64.AppImage
./Open.Audio.Analyzer-0.10.1-x86_64.AppImage
```

GTK 3 is expected from the host — every desktop Linux that can run a Flutter
application already has it — and everything else travels inside the file. The
AppImage is built on the oldest supported runner, because glibc is
forward-compatible and not backward-compatible: one built on a newer
distribution simply refuses to start on an older one.

### Flatpak

```sh
flatpak install --user Open.Audio.Analyzer-0.10.1-x86_64.flatpak
flatpak run com.openaudioanalyzer.oaa
```

The flatpak carries its own runtime, so the glibc caveat above does not apply.
It is granted audio, network and filesystem access — [the manifest says why for
each](https://github.com/JonasGrunau/open_audio_analyzer/blob/main/packaging/linux/flatpak/com.openaudioanalyzer.oaa.yml).

For system audio on either, PipeWire's own loopback or `pactl load-module
module-null-sink` gives you a monitor source Open Audio Analyzer can open.

## iPadOS

The iPad build is a **display**, not a second analyser: it draws another
machine's meters over the local network, with the desktop application doing the
measuring. [Remote display](index.html) covers how the two find each other.

It needs **iPadOS 15 or later**, which costs no device: iPadOS 13, 14 and 15
run on the same iPads — every model back to the Air 2 and the mini 4 — so if
yours could run the display before, it can still run it after updating. The
floor is 15 because Apple stops accepting uploads built against anything lower
in Spring 2027, and a build nobody can upload is a build nobody can install.

The quickest of the three ways is the camera: on the desktop, the code button
beside PUBLISH in the status bar; on the iPad, Scan
a QR code. iPadOS asks for camera permission the first time, and refusing it
leaves the host list and the typed address exactly as they were.

It is distributed through **TestFlight** rather than from the releases page, and
that is not an oversight. An App Store signature provisions no devices, so an
IPA you downloaded could not be installed on your iPad by you or by anybody
else — there is no file here that would do you any good. Every tagged release
uploads a build; ask on the
[repository](https://github.com/JonasGrunau/open_audio_analyzer) for access, or
build it yourself, which needs a Mac with Xcode and no credentials beyond a free
Apple ID:

```sh
flutter run -d <your ipad>    # `flutter devices` names it
```

## In a DAW

The plugin is a **VST3** and an **Audio Unit** that draw nothing. They measure
the buffer your DAW gives them and stream it to the desktop application, which
displays it — so the app has to be running, and the plugin finds it by itself on
`127.0.0.1:47822` whichever of the two you start first.

**The installers above do this for you** — the macOS pkg, the Windows `.exe`
and the Linux tarball each carry the plugin and put it where your DAW looks, so
everything in this section is the manual route. Take it if you are installing
the plugin on a machine that already has the application, or if you deliberately
took the AppImage or the flatpak.

`oaa-plugin-<platform>` is an archive, not an installer. Copy the *bundle* — the
`.vst3` or `.component` itself, not the directory holding it — into the folder
your DAW scans. On a machine that has never had a plugin installed, that folder
does not exist yet:

| Platform | VST3 | Audio Unit |
| --- | --- | --- |
| macOS | `~/Library/Audio/Plug-Ins/VST3` | `~/Library/Audio/Plug-Ins/Components` |
| Windows | `%CommonProgramFiles%\VST3` | — |
| Linux | `~/.vst3` | — |

The installers use the machine-wide equivalents of those — `/Library/Audio/…`
on macOS, `C:\Program Files\Common Files\VST3` on Windows — which every DAW
scans as well. The per-user paths above are what you can write without a
password.

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
downloads, the mark survives being unpacked, and Gatekeeper then refuses to
load the bundle. What the refusal looks like depends on which macOS you are on,
and neither version of it names the real problem:

- **macOS 15 and later** put up a modal — *"Apple could not verify 'Open Audio
  Analyzer.vst3' is free of malware that may harm your Mac"*, or on some
  versions *"will damage your computer. You should move it to the Trash"* —
  **and there is nothing in System Settings to override it with.** The "Open
  Anyway" button under Privacy & Security is only ever populated for a blocked
  *launch*. A plugin is loaded *into* your DAW, which is a library load, so no
  button ever appears and the dialog's only other choice is Move to Trash. The
  `xattr` line is the only way past it.
- **Earlier versions** fail silently instead. The plugin is simply absent from
  the DAW's browser with nothing logged and no message anywhere, which is
  indistinguishable from having copied it to the wrong folder.

A plugin you built yourself has no flag to remove. A downloaded one needs
either the line above or a *notarised* bundle — a Developer ID signature alone
does not clear the flag, which is the part that surprises people. Whether a
given release is notarised depends on whether the project's signing credentials
were present when it was built; `packaging/macos/notarize.sh` documents them,
and `xattr` works either way.

**None of this applies to the pkg.** Files placed by an installer are not
quarantined, so a plugin installed that way carries no flag to remove — which
is the second reason the pkg exists.

**Ableton Live also has to be told to look there** — Preferences → Plug-Ins →
*Use VST3 Plug-In System Folders*. It then appears under **Open Audio
Analyzer**. Live rescans on launch; a plugin copied in while it is open needs a
restart.

Insert it on a track, a bus or the master. Its own window is a status panel and
nothing else — the meters are in the app, and the panel says so. What it shows
is a diagram of the three places the path can break: the host's audio, the
host's playhead, and the socket to the app. Each run is lit when something is
travelling down it and dark when nothing is, and the socket's dashes move while
frames are being sent, so a link that has quietly stopped does not look like one
that is working. Under it, the sample rate and channel count the host is giving
it, how long it has been measuring, the integrated loudness, and one line naming
whatever is wrong. Several inserts can be connected at once and the most
recently added is the one on screen, because adding it is the act of choosing
it.

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
