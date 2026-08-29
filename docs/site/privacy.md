# Privacy and data handling

**Open Audio Analyzer collects nothing.** There is no account, no sign-in, no
analytics, no telemetry, no crash reporting, no advertising and no third-party
service of any kind. The application makes no connection to the internet at
all — not to check for updates, not to fetch anything, not to report that it
ran. Every measurement it takes is computed on your machine and discarded when
the next one replaces it.

This page is the whole of it, written out rather than summarised, because a
metering tool asks for a microphone and a camera and a local network and the
honest thing to do is say what it does with each. It is also the privacy policy
for the iPadOS listing on the App Store, for the desktop builds on macOS,
Windows and Linux, for the `oaa` command-line analyser, for the VST3 and Audio
Unit plugin, and for this website.

Everything below is checkable. The application is free software and the whole
of it is public — the network code is in
[`lib/src/remote/`](https://github.com/JonasGrunau/open_audio_analyzer/tree/main/lib/src/remote),
the protocol it speaks is specified in [the wire protocol](wire.html), and the
only code in the application that touches the filesystem is one file,
[`config_store.dart`](https://github.com/JonasGrunau/open_audio_analyzer/blob/main/lib/src/storage/config_store.dart).
A claim on this page that the source contradicts is a bug; please
[report it](https://github.com/JonasGrunau/open_audio_analyzer/issues).

Last updated 24 August 2026, for version 0.11.0.

## The short version

| | |
| --- | --- |
| Personal data collected | None |
| Data sent off your device | None, except measurements you explicitly publish to another device on your own network |
| Accounts | None |
| Analytics or telemetry | None |
| Advertising or tracking | None |
| Third-party services in the app | None |
| Audio recorded or stored | Never |
| Camera images recorded or stored | Never |
| Data shared or sold | None. There is none to share |

## The microphone, and the audio it measures

The application measures a signal — that is what it is for. On iPadOS and on
Android it asks for the microphone permission the first time you choose an
input; on the desktop it opens the input device you choose. A tablet that only
ever draws another machine's meters is never asked, because the question is
raised by choosing an input and not by launching the app.

**Audio is measured and discarded.** Samples are pushed into the measurement
engine, which reduces them to numbers — loudness, peak level, a spectrum, a
correlation coefficient — and the buffer is reused for the next block. Nothing
is written to disk, nothing is kept in memory beyond the moment, and nothing
is transmitted anywhere by this. There is no recording feature, and adding one
would be a change to this page as much as to the application.

The permission is asked for once, when you first start metering, and both iPadOS
and Android let you withdraw it at any time in Settings. Withdrawing it stops the
live meters; nothing else in the application depends on it.

## The camera

On iPadOS, Android and macOS the host picker offers **Scan a QR code**, which
reads a pairing code shown on the screen of the machine you want to watch. That
is the only thing the camera is used for.

Frames from the camera are examined for a QR symbol and then dropped. Nothing
is recorded, stored, uploaded or kept, and no image is ever written to disk. The
code being scanned carries one thing — an address of the form
`oaa://host:port` — and nothing else.

The scanner uses [`mobile_scanner`](https://pub.dev/packages/mobile_scanner),
the one dependency in this project with a native component that is not vendored
here. It runs entirely in-process and makes no network connection. It is absent
on Windows and Linux, which is why the row is not shown there.

## The local network

The remote display feature draws one machine's meters on another screen — a
desktop publishing to an iPad, or a DAW plugin publishing to the desktop
application. This is the only networking in the product, and all of it stays on
your own network.

**Nothing is published until you turn it on.** The desktop application does not
listen on any port until you switch on `PUBLISH`; a plugin instance connects
only to the machine it is running on. There is no default that shares anything.

When publishing is on:

- The application advertises a service of type `_oaa._tcp` over multicast DNS
  on the local network, so that a tablet can find it without anybody typing an
  address. The advertisement carries a **name**, which defaults to your
  computer's hostname and is editable in the publish settings — set it to
  whatever you like. It is visible to anything else on the same network that is
  browsing for services, which is how service discovery works everywhere.
- Port **47821** carries measurements and the canvas layout from the
  application to a connected display. Port **47822** carries measurements from
  a plugin instance to the application on the same machine.
- What travels is numbers and the description of a layout: loudness values,
  peak levels, spectrum bins, the transport position the DAW reported, the
  names of your tabs and modules, the colours of the skin you are using and the
  delivery target you have selected. **Audio never travels.** There is no
  frame in the protocol that can carry it, which is a property of the format
  rather than a promise about the code — see [the wire protocol](wire.html).
- Nothing leaves your network. Both ends are on the same LAN by construction:
  the address is discovered by multicast, which does not cross a router, or
  typed in by you.

On iPadOS the local network permission is requested the first time you look for
a host, and can be withdrawn in Settings. Withdrawing it stops discovery and
nothing else.

One thing that looks worse in a permission list than it is: the Android build
declares `android.permission.INTERNET`. Android requires that permission to
open *any* socket, including one to a machine in the same room, and it is the
only way to reach a host on your own network. It is not used to reach anything
beyond it. The Android build also declares `CHANGE_WIFI_MULTICAST_STATE`, which
is what lets it receive the mDNS answers it would otherwise have filtered out,
and deliberately does not declare `NEARBY_WIFI_DEVICES` — scanning and managing
Wi-Fi networks is something this application never does.

### The link is not encrypted, and it is not authenticated

Stated plainly because it is the one thing on this page that is a limitation
rather than a reassurance: **the display link has no encryption and no
authentication.** Anyone who can reach port 47821 on your machine while
publishing is on can read the measurements and the layout.

That is a deliberate trade for a feature that is LAN-only, and it is why the
host does not listen at all unless a person switches it on. It is also why the
link is one-directional: a connected display can draw the meters and can change
nothing — the protocol has no frame that lets it, and the port rejects one if it
arrives. The reasoning is written out in full under
[**They do not have the same trust boundary**](wire.html#they-do-not-have-the-same-trust-boundary).

What follows from that, practically: publish on a network you trust. On a shared
or public network — a venue, a hotel, a rehearsal room with an open access
point — leave `PUBLISH` off, or expect that anybody on it who is looking can see
what your meters read.

## Files you analyse

Opening a file for offline analysis reads it from your disk, measures it, and
shows you the report. The file is not copied, not modified and not uploaded.
Exporting a report writes it where you choose and nowhere else.

## What is stored on your device

Your configuration, and nothing else. It is plain JSON you can read, and it
contains only what you set up:

- Settings, the canvas layout, your tabs and modules
- Presets, delivery targets, skins and any meter calibrations you save
- The path of the preset file the canvas is open on, so that `Save` writes back
  to it after a restart
- The name and port used for publishing, and the address of a host you last
  connected to

No measurement is ever written to it. No identifier is generated, stored, or
derived from your hardware — there is no installation id, no device
fingerprint, and nothing that could distinguish one copy of this application
from another.

Where it lives:

| Platform | Location |
| --- | --- |
| macOS | `~/Library/Application Support/Open Audio Analyzer` |
| Windows | `%APPDATA%\Open Audio Analyzer` |
| Linux | `$XDG_CONFIG_HOME/oaa`, or `~/.config/oaa` |
| iPadOS | `Library/Application Support/Open Audio Analyzer`, inside the app's own container |
| Android | `oaa`, inside the app's private files directory |

Deleting the application removes it on iPadOS and Android. On the desktop,
delete the directory above. There is nothing anywhere else to delete, and
nothing held by anybody else that could be deleted on request — see
[**Your rights**](#your-rights) for why that section is short.

## Children

The application is rated 4+ and is suitable for all ages. It collects nothing
from anyone, so it collects nothing from children either. There is no user
content, no messaging, no social feature and no link out of the application to
anything that is not this project's own documentation or source code.

## Apple's App Privacy answers

The listing declares **Data Not Collected** in every category, which is
accurate: no data of any kind is transmitted off the device by the application.
For completeness, against Apple's own list —

| Apple's category | Collected? |
| --- | --- |
| Contact info, identifiers, purchases, financial info | No |
| Location | No |
| Contacts, user content, browsing or search history | No |
| Usage data, diagnostics, product interaction | No |
| Audio data | **No.** Audio is measured in memory and discarded; it is never recorded, stored, or transmitted |
| Camera | **No.** Frames are examined for a QR code and dropped; no image is retained or transmitted |
| Sensitive info, health, fitness | No |

The application uses no third-party SDK, so there is no partner disclosure to
make. `ITSAppUsesNonExemptEncryption` is declared `false` in the bundle: the
application contains no encryption.

## This website

`open-audio-analyzer.com` is a static site with no analytics, no tracking
pixels, no advertising and no cookies. Nothing is stored in your browser and
nothing about your visit is recorded by this project.

Three things are worth naming anyway, because a site that claims to send
nothing anywhere should account for every request a browser makes:

- **Hosting.** The site is served by [Cloudflare](https://www.cloudflare.com/),
  which as a hosting provider processes the request — including your IP
  address — in order to deliver the page, and keeps operational logs of it for
  a short period. This project has no analytics product enabled on that account
  and reads no per-visitor data from it. Cloudflare's own handling is described
  in their [privacy policy](https://www.cloudflare.com/privacypolicy/).
- **Fonts.** None. The three typefaces the site is set in are served from
  `open-audio-analyzer.com` itself, so reading a page here sends no request to
  anybody else for them. They used to be loaded from Google Fonts, which meant
  your browser contacted Google and Google saw your IP address; they were moved
  onto this site in the same change that recorded this sentence.
- **The live demo.** Pressing the button on the front page that starts the
  running analyzer loads a graphics renderer from `www.gstatic.com`, which is
  the same kind of request. It happens only when you press it; a reader who
  does not press it makes no such request.

Nothing on this site asks for personal data. There is no form, no comment
field, no newsletter and no login.

## Your rights

Under the GDPR you have the right to know what personal data is held about you,
to have it corrected or erased, to object to its processing, and to have it
handed to you in a portable form.

**This project holds no personal data about you**, so in practice there is
nothing to disclose, correct, erase or export. The rights are stated here
because you have them, not because there is a database behind them. If you
believe otherwise, ask — see below — and if the answer does not satisfy you,
you may complain to a supervisory authority in the country you live in.

## Contact

Questions about this page, or about anything in the application that appears to
contradict it, go to the issue tracker:

**<https://github.com/JonasGrunau/open_audio_analyzer/issues>**

It is public, which is the point: a question about what a program does with a
microphone is worth answering where the next person can read the answer. An
issue is also the fastest way to get a correction made, since the page and the
code it describes are in the same repository.

## Changes to this page

This page is versioned with the application and lives in the repository as
[`docs/site/privacy.md`](https://github.com/JonasGrunau/open_audio_analyzer/blob/main/docs/site/privacy.md).
Every revision is in the commit history with its date and its reason, so what
this page said on any given day is a matter of record rather than of trust.

A change that affects what the software does with your data will be noted in
[the changelog](changelog.html) in the same release, and the date at the top of
this page will move.
