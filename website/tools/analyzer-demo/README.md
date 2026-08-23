# analyzer-demo

The canvas the website loads when a reader presses the still: eight of the
application's real meter modules, running in a browser.

Not an application, and not a demo in the sense of a mock-up. `pubspec.yaml`
depends on `oaa` by path and this imports `package:oaa/src/canvas/module_host.dart`
directly, so every module here is the one the desktop draws — the same
`ModuleFrame`, the same painters, laid out on the same `GridGeometry` and
repainting from one `MeterClock`, exactly as the desktop canvas and the tablet's
remote display do. Nothing was rewritten to put it on a web page.

## Where the numbers come from

Not from an engine. `dart:ffi` has no web implementation, so there cannot be one
here — but the readings are still the engine's, because the engine took them
somewhere else. `website/tools/oaa_record` links it by FFI, pushes a real track
through it and writes down every frame; `ReplaySource` replays that file. It is
the fourth `MeterSource`, beside the native one, the socket the tablet reads and
the mock this replaced.

The mock was replaced because invented numbers look invented. A spectrum built
out of noise fields is smooth in the wrong places, a loudness curve made of sine
waves repeats, and a stereo field that never collapses is not a stereo field.
What is on screen now is 45 seconds of a CC BY 3.0 track measured by the real
engine — which fails the −14 LUFS streaming target it is shown against, on
loudness and on true peak, because the track masters at about −8. Nothing was
tuned to make that come out well.

    web/programme.oaa.gz    what the engine measured
    web/programme.m4a       the same seconds, to listen to

Both are written by `npm run record` and git-ignored, and both live in `web/`
because that is what `flutter build web` copies into the build.

## The audio

The excerpt plays, and the meters read the position of the audio clock rather
than a timer of their own — so the picture and the sound are one instant by
construction.

It starts silent. A browser will not play audio until somebody has interacted
with *that* document, and the press that opened this analyzer happened in the
page above, in a different document; so the canvas offers the sound in a corner
and takes over the timekeeping from the silent clock when it is accepted,
continuing from the position it had reached rather than jumping.

Decoding, unlike playing, needs no interaction — so it happens on load. That is
what lets the oscilloscope and the phase scope draw from the first frame: they
read the last 1024 stereo frames, which is the audio itself, and it is
deliberately not in the recording. Storing it would have been sending a browser
a second copy of what it is already playing, at 8 kB a frame.

## Running it by hand

```sh
npm run record            # from website/, once
flutter run -d chrome --web-port 4404
```

    ?seconds=32   freeze after this much programme, for a screenshot

Without it the programme runs, and loops. With it the frames are stepped by a
counter rather than by a clock, so the same picture comes out on a fast machine
and a slow one, and `globalThis.oaaRenderReady` goes up when it is done — which
is what `website/scripts/render-analyzer.mjs` waits for.

It also takes the **play-the-audio button off the canvas**, and that is the one
difference between the two modes that is not about time. The audio is still
decoded — the oscilloscope and the phase scope draw from it — but a photograph of
a control is not a control, and the still is the whole of what the front page
shows a phone: no facade button there either, so the only play mark left on a
phone's screen would have been one inside a picture.
