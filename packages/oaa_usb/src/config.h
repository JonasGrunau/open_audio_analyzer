/* SPDX-License-Identifier: LGPL-2.1-or-later */

/*
 * libusb's config.h, written by hand for the three platforms this package
 * builds libusb on — its own build would generate it with autoconf, and there
 * is no autoconf here. Derived from libusb's `Xcode/config.h`,
 * `android/config.h` and `msvc/config.h`, which are the same file for the
 * same reason.
 */

#ifndef OAA_USB_LIBUSB_CONFIG_H
#define OAA_USB_LIBUSB_CONFIG_H

#if defined(_WIN32)

#define PLATFORM_WINDOWS 1
#define DEFAULT_VISIBILITY /**/

#if defined(_MSC_VER)
/* The warnings libusb's own MSVC build silences, for the same code. */
#if (_MSC_VER >= 1900)
#define _TIMESPEC_DEFINED 1
#endif
#pragma warning(disable : 4127)
#pragma warning(disable : 4200)
#pragma warning(disable : 4201)
#pragma warning(disable : 4324)
#pragma warning(disable : 4996)
#if (_MSC_VER > 1800)
#pragma warning(disable : 5287)
#endif
#define PRINTF_FORMAT(a, b) /**/
#else
#define PRINTF_FORMAT(a, b) __attribute__((__format__(__printf__, a, b)))
#endif

#else /* POSIX */

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

#endif
