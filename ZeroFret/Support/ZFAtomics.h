//  ZFAtomics.h
//  Zero Fret
//
//  Minimal release/acquire atomics for the lock-free SPSC hand-off between the
//  real-time audio render thread and the detection queue.
//
//  Why this file exists: the spec forbids third-party dependencies, the app
//  deploys to iOS 17, and Swift's `Synchronization.Atomic` is iOS 18+. A plain
//  `UnsafeMutablePointer<Int64>.pointee` store is atomic on arm64 at the
//  hardware level but carries no ordering guarantee against the compiler, which
//  is exactly the guarantee a ring-buffer index needs. Twenty lines of C buys
//  the correct fences without a package.

#ifndef ZF_ATOMICS_H
#define ZF_ATOMICS_H

#include <stdatomic.h>
#include <stdint.h>

/// Release-ordered store. Publishes every prior write to the ring's storage.
static inline void zf_atomic_store_i64(int64_t *p, int64_t value) {
    atomic_store_explicit((_Atomic(int64_t) *)p, value, memory_order_release);
}

/// Acquire-ordered load. Pairs with `zf_atomic_store_i64` on the other thread.
static inline int64_t zf_atomic_load_i64(const int64_t *p) {
    return atomic_load_explicit((const _Atomic(int64_t) *)p, memory_order_acquire);
}

/// Relaxed load, for a thread reading an index only it is allowed to write.
static inline int64_t zf_atomic_load_i64_relaxed(const int64_t *p) {
    return atomic_load_explicit((const _Atomic(int64_t) *)p, memory_order_relaxed);
}

#endif /* ZF_ATOMICS_H */
