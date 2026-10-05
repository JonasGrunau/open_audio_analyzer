/* SPDX-License-Identifier: GPL-3.0-or-later */

/*
 * The Android Open Accessory protocol, desktop side, over libusb.
 *
 * Everything the application needs to turn an Android tablet on a cable into
 * a byte stream, with no USB debugging and no adb: find the devices, ask one to
 * become an accessory, and read and write the two bulk endpoints it comes back
 * with. The protocol is AOSP's — https://source.android.com/docs/core/interaction/accessories/aoa —
 * and it is three vendor control requests long.
 *
 * Nothing here knows what is carried. The stream is `docs/WIRE.md` § USB
 * carriage, read and written by `lib/src/remote/usb_relay.dart`.
 *
 * Every call is synchronous. The Dart side runs reads and writes on isolates
 * of their own, so a blocking bulk transfer never holds the UI thread.
 */

#ifndef OAA_USB_H
#define OAA_USB_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define OAA_USB_EXPORT __declspec(dllexport)
#else
#define OAA_USB_EXPORT __attribute__((visibility("default")))
#endif

/* Google's ids for a device in accessory mode: 2D00, or 2D01 with adb too. */
#define OAA_USB_ACCESSORY_VID 0x18D1

/* What a scan found. `kind` is one of the three below. */
typedef struct oaa_usb_device {
  uint16_t vendor_id;
  uint16_t product_id;
  uint8_t bus;
  uint8_t address;
  uint8_t kind;
  uint8_t reserved;
} oaa_usb_device;

/* Not worth asking: a hub, a keyboard, an Apple device. */
#define OAA_USB_OTHER 0
/* Might be an Android device that can become an accessory. */
#define OAA_USB_CANDIDATE 1
/* Already an accessory, ready to open. */
#define OAA_USB_ACCESSORY 2

/* Starts libusb. Zero on success, a libusb error code otherwise. Idempotent. */
OAA_USB_EXPORT int oaa_usb_init(void);

/*
 * Fills `out` with up to `capacity` devices and answers how many there are,
 * which may be more than fit. Negative on a libusb error.
 */
OAA_USB_EXPORT int oaa_usb_scan(oaa_usb_device *out, int capacity);

/*
 * Asks the device at `bus`/`address` to become an accessory: GET_PROTOCOL,
 * the six identifying strings, START. Answers the device's protocol version
 * (1 or 2) once it has been told to switch — it then leaves the bus and comes
 * back as 18D1:2D00 — or a negative libusb error, or 0 for a device that does
 * not speak the protocol at all.
 */
OAA_USB_EXPORT int oaa_usb_switch(uint8_t bus, uint8_t address,
                                  const char *manufacturer, const char *model,
                                  const char *description, const char *version,
                                  const char *uri, const char *serial);

typedef struct oaa_usb_link oaa_usb_link;

/* Opens an accessory-mode device and claims its interface. NULL on failure. */
OAA_USB_EXPORT oaa_usb_link *oaa_usb_open(uint8_t bus, uint8_t address);

/*
 * One bulk read of at most `capacity` bytes. Answers the bytes read, 0 on a
 * timeout, or a negative libusb error — after which the link is finished.
 */
OAA_USB_EXPORT int oaa_usb_read(oaa_usb_link *link, uint8_t *buffer,
                                int capacity, unsigned timeout_ms);

/* Writes all of `length` bytes, or answers a negative libusb error. */
OAA_USB_EXPORT int oaa_usb_write(oaa_usb_link *link, const uint8_t *bytes,
                                 int length, unsigned timeout_ms);

/* Releases the interface and closes the device. NULL is ignored. */
OAA_USB_EXPORT void oaa_usb_close(oaa_usb_link *link);

#ifdef __cplusplus
}
#endif

#endif
