/*
 * oaa_device.h — capture from real audio hardware, via miniaudio.
 *
 * SPDX-License-Identifier: MIT
 *
 * ---------------------------------------------------------------------------
 * The engine adopts the device's format; it never converts to its own
 *
 * miniaudio will happily resample and remix a device into whatever format is
 * asked of it, and for a playback engine that is the right thing to use. Here
 * it is not. A resampler in front of the measurement changes what is being
 * measured: it moves inter-sample peaks, so true peak reads differently, and it
 * band-limits, so the K-weighted energy shifts. The numbers would still look
 * plausible, which is the worst outcome available.
 *
 * So opening a device *reconfigures the engine* to the device's own sample rate
 * and channel count, and the DSP is rebuilt around them. Open Audio Analyzer
 * measures the stream the hardware actually produced.
 *
 * ---------------------------------------------------------------------------
 * What "capture" means per platform
 *
 * On Windows, WASAPI can capture the system's own output directly (loopback),
 * so metering whatever is playing works with no setup at all.
 *
 * On macOS 14.2 and later a Core Audio process tap does the same thing without
 * a driver, and this file offers it as OAA_DEVICE_ID_SYSTEM_OUTPUT — one extra
 * entry in the list that opens `oaa_tap.h` instead of miniaudio. Below 14.2
 * the entry is simply absent.
 *
 * On Linux, a PulseAudio or PipeWire monitor source already appears in this
 * list like any other input, so there is nothing to add: miniaudio's default
 * backend order tries PulseAudio before ALSA, which is what makes the monitors
 * visible.
 *
 * What remains uncovered is macOS below 14.2, where metering system audio
 * still needs a virtual loopback device — BlackHole, Loopback — which then
 * appears here like any other input and cannot be told apart from one.
 */

#ifndef OAA_DEVICE_H
#define OAA_DEVICE_H

#include "oaa/oaa.h"
#include "oaa_ring.h"

#include <stdint.h>

typedef struct oaa_device oaa_device;

/*
 * Negotiates a capture device and reports the format it settled on, **without
 * starting it**. `device_id` may be NULL for the system default.
 *
 * Opening and starting are separate for one specific reason: the ring's frame
 * stride has to match the device's channel count, and the channel count is not
 * known until the device has been negotiated. Starting inside open would let
 * the callback run against a ring sized for a different layout, which is a
 * buffer overread in real-time context — it crashed immediately on a 1-channel
 * built-in microphone, and on a 2-channel device it would have silently
 * corrupted memory instead.
 *
 * So: open, size the ring, then start.
 */
int32_t oaa_device_open(oaa_device **out, const char *device_id,
                        uint32_t *sample_rate, uint32_t *channels);

/* Attaches the ring and begins capture. The ring must have been created with
 * exactly the channel count `oaa_device_open` reported. */
int32_t oaa_device_start(oaa_device *device, oaa_ring *ring);

/* Stops capture if running and releases everything. Safe on NULL. */
void oaa_device_close(oaa_device *device);

/* Enumeration is declared in oaa/oaa.h, because unlike everything else here it
 * is part of the public ABI — a UI has to be able to offer the list before any
 * engine exists. */

#endif /* OAA_DEVICE_H */
