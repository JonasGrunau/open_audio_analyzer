/*
 * oaa_tap.h — capturing the system's own output on macOS, with no driver.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * ---------------------------------------------------------------------------
 * Why this exists
 *
 * On Windows, WASAPI captures the system's output directly. On macOS there was
 * no such thing for years: an input device was a microphone or a line input,
 * and metering what you were listening to meant installing a virtual loopback
 * driver — BlackHole, Loopback — routing your output through it, and losing
 * your speakers in the process. That was the largest usability gap between
 * Open Audio Analyzer and Decibel, which ships a signed monitoring driver.
 *
 * macOS 14.2 closed it. Core Audio process taps capture what is going *to* an
 * output device, in that device's own format, with no driver, no installer, no
 * root and — the part that matters most — no rerouting: the audio still reaches
 * the speakers. `CATapUnmuted` is not a default we are accepting, it is the
 * whole point.
 *
 * ---------------------------------------------------------------------------
 * The shape of the thing
 *
 * A tap is not a device and cannot be read from. It is an object you attach to
 * a *private aggregate device*, which is then an ordinary Core Audio device
 * with an input stream carrying the tapped audio. So opening one is four steps
 * that all have to be undone in reverse:
 *
 *   default output device -> its UID
 *   CATapDescription      -> AudioHardwareCreateProcessTap    -> tap object
 *   aggregate description -> AudioHardwareCreateAggregateDevice -> device
 *   AudioDeviceCreateIOProcIDWithBlock + AudioDeviceStart
 *
 * The tap is bound to one *stream* of one output device rather than being a
 * global mixdown, because `initExcludingProcesses:andDeviceUID:withStream:`
 * produces the device's native format and the global variants fold everything
 * to stereo. A 7.1 output metered as stereo is a measurement of a programme
 * nobody played, and this engine has eight bars to draw.
 *
 * ---------------------------------------------------------------------------
 * What it does not do, stated plainly
 *
 * A tap is bound to the device it was created against. When the default output
 * changes — headphones plugged in — this file rebuilds the tap on the new
 * device if its format matches the one the engine was configured with, because
 * the engine's sample rate and channel count are fixed at creation and cannot
 * move underneath a running measurement. If the format does *not* match, the
 * tap stops rather than following.
 *
 * The alternative — following anyway and resampling — is the one thing this
 * engine must never do. See the header of oaa_device.h.
 *
 * ---------------------------------------------------------------------------
 * A tap that has stopped says so
 *
 * The paragraph above used to end "and the meters fall to their floor exactly
 * as they do when any capture device stops delivering. Reselecting the source
 * picks up the new device." Both halves were wrong, and together they were the
 * bug this section exists to explain.
 *
 * Meters do not fall to their floor when a producer stops. Nothing falls
 * anywhere: the analysis thread paces itself against a monotonic clock, so it
 * goes on publishing an empty ring at the same rate and every meter *holds*.
 * The application looks alive — the window, the menus, the canvas — with a
 * frozen picture in it, and pressing reset moves the readings to their floors
 * and then holds those instead. There was no signal anywhere in the interface
 * that the audio had gone.
 *
 * And reselecting the source did not pick anything up, because selecting the
 * source that is already selected changes no setting, so the application's
 * source listener never fired. What actually recovered it was choosing a
 * *different* source and coming back, which rebuilds the engine twice by
 * side-effect. That is what a user reported: "the meters freeze, reset does
 * nothing, and it only comes back when I switch to another source."
 *
 * So a stopped tap is now a state the engine can see and act on, through the
 * two calls below. `oaa_tap_running` is polled a few times a second;
 * `oaa_tap_revive` rebuilds against whatever the default output is *now*, at
 * the format the engine was built for. When the format has moved, revive keeps
 * failing — as it must — and OAA_FLAG_SOURCE_STOPPED stays set so the
 * application can throw the engine away and open a new one, which is the only
 * thing that can adopt a new rate.
 */

#ifndef OAA_TAP_H
#define OAA_TAP_H

#include "oaa_ring.h"

#include <stddef.h>
#include <stdint.h>

/* Compiled only where the API exists. iOS is excluded by Apple, not by us:
 * AudioHardwareTapping.h is API_UNAVAILABLE(ios). */
#if defined(__APPLE__)
#include <TargetConditionals.h>
#if defined(TARGET_OS_OSX) && TARGET_OS_OSX
#define OAA_TAP_SUPPORTED 1
#endif
#endif

#ifndef OAA_TAP_SUPPORTED
#define OAA_TAP_SUPPORTED 0
#endif

/*
 * The deployment floor, asserted rather than assumed.
 *
 * `CATapDescription` is an Objective-C *class*, and a class reference is not
 * weak-imported the way the tapping functions are — `nm -m` shows
 * `_AudioHardwareCreateProcessTap` as `weak external` and
 * `_OBJC_CLASS_$_CATapDescription` as plain `external`. Below 14.2 that class
 * does not exist, so dyld cannot resolve the symbol, and what fails is not the
 * tap: it is the load of the whole engine library, which every meter in the
 * application goes through. The application died at launch on any macOS older
 * than the class it never intended to use, and the `@available` checks this
 * file used to carry could not help — they gate the *call*, and the symbol is
 * resolved before a line of it runs.
 *
 * So the floor is the fix, and this is here because a deployment target is set
 * in two build descriptions that know nothing about each other
 * (`plugin/CMakeLists.txt` and `macos/Runner.xcodeproj`) and lowering either
 * would bring the crash back with nothing to catch it. A compile error is
 * cheaper than a launch failure on somebody else's Mac.
 */
#if OAA_TAP_SUPPORTED
#if defined(__MAC_OS_X_VERSION_MIN_REQUIRED) && \
    __MAC_OS_X_VERSION_MIN_REQUIRED < 140200
#error "oaa_tap needs a macOS deployment target of 14.2 or later: the strong \
reference to CATapDescription makes the engine library unloadable below it."
#endif
#endif

/* Declared on every platform, defined on one. A handle to an incomplete type
 * costs nothing, and it keeps `#if` out of the struct in oaa_device.c — which
 * carries the field unconditionally and leaves it NULL everywhere else. */
typedef struct oaa_tap oaa_tap;

#if OAA_TAP_SUPPORTED

/*
 * Reports what a tap of the current default output device would produce,
 * without creating one — which is what enumeration needs, and enumeration runs
 * every time the source menu opens.
 *
 * `name` receives a human-readable label naming the device that would be
 * tapped, so that what is being metered is visible rather than implied.
 *
 * Returns OAA_ERR_UNSUPPORTED on macOS below 14.2 and when there is no default
 * output device at all. Both are ordinary states: the caller omits the entry
 * from the device list and the user sees the same menu they saw before.
 */
int32_t oaa_tap_probe(uint32_t *sample_rate, uint32_t *channels, char *name,
                      size_t name_capacity);

/*
 * Creates the tap and its aggregate device and reports the format, **without
 * starting it** — the same split as oaa_device_open, and for the same reason:
 * the ring's frame stride has to match the channel count, and nobody knows the
 * channel count until the tap exists.
 */
int32_t oaa_tap_open(oaa_tap **out, uint32_t *sample_rate, uint32_t *channels);

/* Attaches the ring and starts the IO proc. The ring must have been created
 * with exactly the channel count `oaa_tap_open` reported. */
int32_t oaa_tap_start(oaa_tap *tap, oaa_ring *ring);

/*
 * Whether the IO proc is still running.
 *
 * Cheap: it reads one flag under a try-lock and asks Core Audio nothing. A
 * rebuild in flight holds that lock, and a caller who cannot take it is told
 * the tap is running — somebody is already fixing it, and a second opinion
 * arrived 250 ms too early is not worth blocking the analysis thread for.
 */
int32_t oaa_tap_running(oaa_tap *tap);

/*
 * Rebuilds a stopped tap against the current default output device, at the
 * format the engine was built around, and starts it.
 *
 * This is what makes the default-output listener's failure recoverable. That
 * listener tears the chain down and builds a new one, and when the build or the
 * start fails — a format that moved, a device that vanished between the
 * notification and the query, an aggregate Core Audio declined to create — it
 * used to leave no producer at all and nothing that would ever try again.
 *
 * Returns OAA_OK when the tap is running by the time it returns, including when
 * it already was. Failure is an ordinary outcome and the caller is expected to
 * try again later or give up and reopen.
 */
int32_t oaa_tap_revive(oaa_tap *tap);

/* Stops and releases everything, in the reverse of the order it was built.
 * Safe on NULL. */
void oaa_tap_close(oaa_tap *tap);

#endif /* OAA_TAP_SUPPORTED */

#endif /* OAA_TAP_H */
