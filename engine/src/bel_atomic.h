/*
 * bel_atomic.h — the two atomic operations the seqlock needs, and nothing else.
 *
 * SPDX-License-Identifier: MIT
 *
 * Why this exists rather than a bare `#include <stdatomic.h>`: MSVC only
 * supports C11 atomics from VS2022 17.5 onwards and only when /std:c11 is
 * passed, and `native_toolchain_c` chooses the Windows compiler for us. Rather
 * than depend on a toolchain detail we do not control, the seqlock is written
 * against these four operations and they are implemented twice.
 *
 * The surface is deliberately tiny. If you find yourself wanting to add a
 * compare-and-swap here, you are probably about to write a lock-free data
 * structure, and that belongs in its own file with its own reasoning.
 */

#ifndef BEL_ATOMIC_H
#define BEL_ATOMIC_H

#include <stdint.h>

#if defined(_MSC_VER)

#include <intrin.h>

typedef volatile long bel_atomic_u32;

/* On x86/x64 and ARM64 under MSVC, aligned 32-bit loads and stores are already
 * atomic; what we need from the compiler is that it does not reorder them
 * across the payload accesses. _ReadWriteBarrier is the compiler-level fence,
 * and the Interlocked increment supplies the hardware-level one. */
static __forceinline uint32_t bel_atomic_load_acquire(const bel_atomic_u32 *p) {
  uint32_t v = (uint32_t)*p;
  _ReadWriteBarrier();
  return v;
}

static __forceinline void bel_atomic_store_release(bel_atomic_u32 *p,
                                                   uint32_t v) {
  _ReadWriteBarrier();
  *p = (long)v;
}

static __forceinline uint32_t bel_atomic_increment(bel_atomic_u32 *p) {
  return (uint32_t)_InterlockedIncrement(p);
}

static __forceinline uint32_t bel_atomic_add(bel_atomic_u32 *p, uint32_t v) {
  return (uint32_t)_InterlockedExchangeAdd(p, (long)v) + v;
}

#define BEL_ATOMIC_INIT(v) (v)

#else /* clang, gcc */

#include <stdatomic.h>

typedef _Atomic uint32_t bel_atomic_u32;

static inline uint32_t bel_atomic_load_acquire(const bel_atomic_u32 *p) {
  return atomic_load_explicit(p, memory_order_acquire);
}

static inline void bel_atomic_store_release(bel_atomic_u32 *p, uint32_t v) {
  atomic_store_explicit(p, v, memory_order_release);
}

static inline uint32_t bel_atomic_increment(bel_atomic_u32 *p) {
  return atomic_fetch_add_explicit(p, 1, memory_order_acq_rel) + 1;
}

static inline uint32_t bel_atomic_add(bel_atomic_u32 *p, uint32_t v) {
  return atomic_fetch_add_explicit(p, v, memory_order_acq_rel) + v;
}

#define BEL_ATOMIC_INIT(v) (v)

#endif

#endif /* BEL_ATOMIC_H */
