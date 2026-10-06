/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "oaa_usb.h"

#include <stdlib.h>
#include <string.h>

#include "libusb.h"

/* AOA's three requests. */
#define AOA_GET_PROTOCOL 51
#define AOA_SEND_STRING 52
#define AOA_START 53

static libusb_context *g_context = NULL;

struct oaa_usb_link {
  libusb_device_handle *handle;
  uint8_t in;
  uint8_t out;
  int interface;
};

/*
 * On Windows, only through UsbDk. An Android device that is not yet an
 * accessory belongs to Windows' MTP driver, which forwards no vendor request,
 * and once it is an accessory it belongs to no driver at all — so libusb's
 * WinUSB backend can open it at neither end. UsbDk is a filter driver that
 * lets libusb borrow a device from whatever owns it. Without it installed the
 * option is refused, so is the context, and the application offers the other
 * cables.
 */
int oaa_usb_init(void) {
  if (g_context != NULL) return 0;
#if defined(_WIN32)
  const struct libusb_init_option options[] = {
      {.option = LIBUSB_OPTION_USE_USBDK},
  };
  int status = libusb_init_context(&g_context, options, 1);
#else
  int status = libusb_init_context(&g_context, NULL, 0);
#endif
  if (status != 0) g_context = NULL;
  return status;
}

/*
 * Vendors that ship Android devices. A device from one of these, or one with an
 * interface that looks like MTP, PTP or adb, is worth asking — and a device that
 * is asked and does not speak the protocol stalls the request and nothing else.
 * The list keeps the asking to things that plausibly are Android: a keyboard or
 * an audio interface on the same bus is never sent a vendor request.
 */
static const uint16_t kAndroidVendors[] = {
    0x18D1, /* Google */   0x04E8, /* Samsung */ 0x17EF, /* Lenovo */
    0x2717, /* Xiaomi */   0x2A70, /* OnePlus */ 0x22B8, /* Motorola */
    0x12D1, /* Huawei */   0x0FCE, /* Sony */    0x1004, /* LG */
    0x0BB4, /* HTC */      0x0B05, /* Asus */    0x22D9, /* OPPO */
    0x2D95, /* vivo */     0x1949, /* Amazon */  0x0E8D, /* MediaTek */
    0x1BBB, /* TCL */      0x2B4C, /* ZTE */     0x05C6, /* Qualcomm */
    0x29A9, /* Nothing */  0x2A45, /* Meizu */   0x2AE5, /* Fairphone */
};

static int is_android_vendor(uint16_t vendor) {
  for (size_t i = 0; i < sizeof kAndroidVendors / sizeof kAndroidVendors[0]; i++) {
    if (kAndroidVendors[i] == vendor) return 1;
  }
  return 0;
}

static int has_android_interface(libusb_device *device) {
  struct libusb_config_descriptor *config = NULL;
  if (libusb_get_active_config_descriptor(device, &config) != 0) return 0;
  int found = 0;
  for (int i = 0; i < config->bNumInterfaces && !found; i++) {
    const struct libusb_interface *interface = &config->interface[i];
    for (int a = 0; a < interface->num_altsetting && !found; a++) {
      const struct libusb_interface_descriptor *alt = &interface->altsetting[a];
      /* PTP / MTP as still image; Android's MTP and adb as vendor-specific. */
      if (alt->bInterfaceClass == LIBUSB_CLASS_IMAGE) found = 1;
      if (alt->bInterfaceClass == LIBUSB_CLASS_VENDOR_SPEC &&
          (alt->bInterfaceSubClass == 0xFF || alt->bInterfaceSubClass == 0x42)) {
        found = 1;
      }
    }
  }
  libusb_free_config_descriptor(config);
  return found;
}

static uint8_t classify(libusb_device *device,
                        const struct libusb_device_descriptor *descriptor) {
  if (descriptor->idVendor == OAA_USB_ACCESSORY_VID &&
      (descriptor->idProduct == 0x2D00 || descriptor->idProduct == 0x2D01)) {
    return OAA_USB_ACCESSORY;
  }
  if (descriptor->bDeviceClass == LIBUSB_CLASS_HUB) return OAA_USB_OTHER;
  if (descriptor->idVendor == 0x05AC) return OAA_USB_OTHER; /* Apple */
  if (is_android_vendor(descriptor->idVendor) || has_android_interface(device)) {
    return OAA_USB_CANDIDATE;
  }
  return OAA_USB_OTHER;
}

int oaa_usb_scan(oaa_usb_device *out, int capacity) {
  int status = oaa_usb_init();
  if (status != 0) return status;

  libusb_device **list = NULL;
  ssize_t count = libusb_get_device_list(g_context, &list);
  if (count < 0) return (int)count;

  int found = 0;
  for (ssize_t i = 0; i < count; i++) {
    struct libusb_device_descriptor descriptor;
    if (libusb_get_device_descriptor(list[i], &descriptor) != 0) continue;
    uint8_t kind = classify(list[i], &descriptor);
    if (kind == OAA_USB_OTHER) continue;
    if (found < capacity) {
      out[found].vendor_id = descriptor.idVendor;
      out[found].product_id = descriptor.idProduct;
      out[found].bus = libusb_get_bus_number(list[i]);
      out[found].address = libusb_get_device_address(list[i]);
      out[found].kind = kind;
      out[found].reserved = 0;
    }
    found++;
  }
  libusb_free_device_list(list, 1);
  return found;
}

/* The device at `bus`/`address`, referenced, or NULL. */
static libusb_device *find(uint8_t bus, uint8_t address) {
  libusb_device **list = NULL;
  ssize_t count = libusb_get_device_list(g_context, &list);
  if (count < 0) return NULL;
  libusb_device *match = NULL;
  for (ssize_t i = 0; i < count; i++) {
    if (libusb_get_bus_number(list[i]) == bus &&
        libusb_get_device_address(list[i]) == address) {
      match = libusb_ref_device(list[i]);
      break;
    }
  }
  libusb_free_device_list(list, 1);
  return match;
}

static int send_string(libusb_device_handle *handle, uint16_t index,
                       const char *value) {
  if (value == NULL) value = "";
  /* The terminating NUL is part of the string the protocol sends. */
  int length = (int)strlen(value) + 1;
  int sent = libusb_control_transfer(
      handle, LIBUSB_ENDPOINT_OUT | LIBUSB_REQUEST_TYPE_VENDOR, AOA_SEND_STRING,
      0, index, (unsigned char *)value, (uint16_t)length, 1000);
  return sent < 0 ? sent : 0;
}

int oaa_usb_switch(uint8_t bus, uint8_t address, const char *manufacturer,
                   const char *model, const char *description,
                   const char *version, const char *uri, const char *serial) {
  int status = oaa_usb_init();
  if (status != 0) return status;

  libusb_device *device = find(bus, address);
  if (device == NULL) return LIBUSB_ERROR_NO_DEVICE;
  libusb_device_handle *handle = NULL;
  status = libusb_open(device, &handle);
  libusb_unref_device(device);
  if (status != 0) return status;

  unsigned char protocol[2] = {0, 0};
  int read = libusb_control_transfer(
      handle, LIBUSB_ENDPOINT_IN | LIBUSB_REQUEST_TYPE_VENDOR, AOA_GET_PROTOCOL,
      0, 0, protocol, sizeof protocol, 1000);
  int version_number = read == 2 ? (protocol[0] | (protocol[1] << 8)) : 0;
  if (version_number < 1) {
    libusb_close(handle);
    /* A stall is the answer of a device that is not Android: not an error. */
    return read < 0 && read != LIBUSB_ERROR_PIPE ? read : 0;
  }

  const char *strings[6] = {manufacturer, model, description,
                            version,      uri,   serial};
  for (uint16_t i = 0; i < 6; i++) {
    status = send_string(handle, i, strings[i]);
    if (status != 0) {
      libusb_close(handle);
      return status;
    }
  }
  status = libusb_control_transfer(
      handle, LIBUSB_ENDPOINT_OUT | LIBUSB_REQUEST_TYPE_VENDOR, AOA_START, 0, 0,
      NULL, 0, 1000);
  libusb_close(handle);
  /* The device may drop off the bus before it acknowledges START. */
  if (status < 0 && status != LIBUSB_ERROR_NO_DEVICE &&
      status != LIBUSB_ERROR_IO && status != LIBUSB_ERROR_PIPE) {
    return status;
  }
  return version_number;
}

oaa_usb_link *oaa_usb_open(uint8_t bus, uint8_t address) {
  if (oaa_usb_init() != 0) return NULL;
  libusb_device *device = find(bus, address);
  if (device == NULL) return NULL;

  struct libusb_config_descriptor *config = NULL;
  if (libusb_get_active_config_descriptor(device, &config) != 0) {
    libusb_unref_device(device);
    return NULL;
  }

  /* Interface 0 is the accessory's: two bulk endpoints, one each way. */
  uint8_t in = 0, out = 0;
  const struct libusb_interface_descriptor *alt = config->interface[0].altsetting;
  for (int e = 0; e < alt->bNumEndpoints; e++) {
    const struct libusb_endpoint_descriptor *endpoint = &alt->endpoint[e];
    if ((endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) !=
        LIBUSB_TRANSFER_TYPE_BULK) {
      continue;
    }
    if (endpoint->bEndpointAddress & LIBUSB_ENDPOINT_IN) {
      in = endpoint->bEndpointAddress;
    } else {
      out = endpoint->bEndpointAddress;
    }
  }
  int interface_number = alt->bInterfaceNumber;
  libusb_free_config_descriptor(config);
  if (in == 0 || out == 0) {
    libusb_unref_device(device);
    return NULL;
  }

  libusb_device_handle *handle = NULL;
  int status = libusb_open(device, &handle);
  libusb_unref_device(device);
  if (status != 0) return NULL;
  libusb_set_auto_detach_kernel_driver(handle, 1);
  if (libusb_claim_interface(handle, interface_number) != 0) {
    libusb_close(handle);
    return NULL;
  }

  oaa_usb_link *link = calloc(1, sizeof *link);
  if (link == NULL) {
    libusb_release_interface(handle, interface_number);
    libusb_close(handle);
    return NULL;
  }
  link->handle = handle;
  link->in = in;
  link->out = out;
  link->interface = interface_number;
  return link;
}

int oaa_usb_read(oaa_usb_link *link, uint8_t *buffer, int capacity,
                 unsigned timeout_ms) {
  if (link == NULL) return LIBUSB_ERROR_INVALID_PARAM;
  int transferred = 0;
  int status = libusb_bulk_transfer(link->handle, link->in, buffer, capacity,
                                    &transferred, timeout_ms);
  if (status == LIBUSB_ERROR_TIMEOUT) return transferred;
  return status == 0 ? transferred : status;
}

int oaa_usb_write(oaa_usb_link *link, const uint8_t *bytes, int length,
                  unsigned timeout_ms) {
  if (link == NULL) return LIBUSB_ERROR_INVALID_PARAM;
  int written = 0;
  while (written < length) {
    int transferred = 0;
    int status = libusb_bulk_transfer(link->handle, link->out,
                                      (unsigned char *)bytes + written,
                                      length - written, &transferred,
                                      timeout_ms);
    written += transferred;
    if (status != 0) return status;
  }
  return written;
}

void oaa_usb_close(oaa_usb_link *link) {
  if (link == NULL) return;
  libusb_release_interface(link->handle, link->interface);
  libusb_close(link->handle);
  free(link);
}
