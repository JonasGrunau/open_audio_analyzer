/* SPDX-License-Identifier: LGPL-2.1-or-later */

/*
 * libusb's config.h, written by hand for the two platforms this package builds
 * libusb on — its own build would generate it with autoconf, and there is no
 * autoconf here. Derived from libusb's `Xcode/config.h` and `android/config.h`,
 * which are the same file for the same reason.
 */

#ifndef OAA_USB_LIBUSB_CONFIG_H
#define OAA_USB_LIBUSB_CONFIG_H

#define DEFAULT_VISIBILITY __attribute__((visibility("default")))
#define PRINTF_FORMAT(a, b) __attribute__((__format__(__printf__, a, b)))
#define PLATFORM_POSIX 1
#define HAVE_NFDS_T 1
#define HAVE_SYS_TIME_H 1

#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#if defined(__APPLE__)
#include <AvailabilityMacros.h>
#define HAVE_PTHREAD_THREADID_NP 1
#endif

#if defined(__linux__)
#define HAVE_ASM_TYPES_H 1
#define HAVE_CLOCK_GETTIME 1
#define HAVE_PIPE2 1
#endif

#endif
