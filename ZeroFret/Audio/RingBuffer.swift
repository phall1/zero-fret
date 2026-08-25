//  RingBuffer.swift
//  Zero Fret
//
//  Lock-free single-producer / single-consumer float ring.
//
//  Producer is the AVAudioEngine tap, which runs on a real-time thread. Its only
//  operations here are two `memcpy`s into preallocated storage and one atomic
//  store — no allocation, no locks, no ARC. See spec §2 (Tap).
//
//  Consumer is the detection queue. Indices are monotonic sample counts rather
//  than wrapped offsets so that "how far behind am I" is a subtraction and
//  overrun detection is trivial.

import Foundation

/// Pointer-only view of a `RingBuffer` that the audio thread captures by value.
///
/// Capturing the `RingBuffer` object itself would put a class reference in the
/// tap closure's context; touching it from the render thread risks ARC traffic.
/// This struct is trivial, so the capture is a plain copy of five words.
struct RingWriter {
    fileprivate let data: UnsafeMutablePointer<Float>
    fileprivate let capacity: Int
    fileprivate let mask: Int
    fileprivate let writeIndex: UnsafeMutablePointer<Int64>

    /// Real-time safe. Overruns the reader rather than blocking; the reader
    /// detects the overrun and resynchronises.
    func write(_ src: UnsafePointer<Float>, _ count: Int) {
        guard count > 0, count <= capacity else { return }
        let w = Int(zf_atomic_load_i64_relaxed(writeIndex))
        let start = w & mask
        let first = min(count, capacity - start)
        memcpy(data + start, src, first * MemoryLayout<Float>.size)
        if count > first {
            memcpy(data, src + first, (count - first) * MemoryLayout<Float>.size)
        }
        zf_atomic_store_i64(writeIndex, Int64(w + count))
    }
}

final class RingBuffer {
    let capacity: Int
    private let mask: Int
    private let data: UnsafeMutablePointer<Float>
    private let writeIndex: UnsafeMutablePointer<Int64>
    private let readIndex: UnsafeMutablePointer<Int64>

    /// - Parameter capacity: must be a power of two.
    init(capacity: Int) {
        precondition(capacity > 0 && capacity & (capacity - 1) == 0,
                     "RingBuffer capacity must be a power of two")
        self.capacity = capacity
        self.mask = capacity - 1
        data = .allocate(capacity: capacity)
        data.initialize(repeating: 0, count: capacity)
        writeIndex = .allocate(capacity: 1)
        writeIndex.initialize(to: 0)
        readIndex = .allocate(capacity: 1)
        readIndex.initialize(to: 0)
    }

    deinit {
        data.deallocate()
        writeIndex.deallocate()
        readIndex.deallocate()
    }

    var writer: RingWriter {
        RingWriter(data: data, capacity: capacity, mask: mask, writeIndex: writeIndex)
    }

    /// Total frames written since construction. Consumer-side view.
    var written: Int { Int(zf_atomic_load_i64(writeIndex)) }

    /// Frames the consumer has not yet stepped past.
    var available: Int {
        Int(zf_atomic_load_i64(writeIndex)) - Int(zf_atomic_load_i64_relaxed(readIndex))
    }

    /// The reader must stay within this many frames of the write cursor. Landing
    /// exactly `capacity` behind is not safe: the producer's next write would
    /// overwrite the oldest frames while `peek` is still copying them, and the
    /// reader would silently splice two unrelated regions together. Resyncing to
    /// half the ring leaves the reader a full `capacity / 2` of slack.
    var safeMargin: Int { capacity / 2 }

    /// If the producer has lapped us, jump forward to a safe distance behind the
    /// write cursor. Returns `true` when frames were dropped.
    @discardableResult
    func resyncIfOverrun() -> Bool {
        let w = Int(zf_atomic_load_i64(writeIndex))
        let r = Int(zf_atomic_load_i64_relaxed(readIndex))
        guard w - r > safeMargin else { return false }
        zf_atomic_store_i64(readIndex, Int64(w - safeMargin))
        return true
    }

    /// Copies `count` frames starting at the read cursor without consuming them.
    @discardableResult
    func peek(into dst: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        guard count <= capacity, available >= count else { return false }
        let r = Int(zf_atomic_load_i64_relaxed(readIndex))
        let start = r & mask
        let first = min(count, capacity - start)
        memcpy(dst, data + start, first * MemoryLayout<Float>.size)
        if count > first {
            memcpy(dst + first, data, (count - first) * MemoryLayout<Float>.size)
        }
        return true
    }

    /// Steps the read cursor forward by `count` frames.
    func advance(_ count: Int) {
        let r = Int(zf_atomic_load_i64_relaxed(readIndex))
        zf_atomic_store_i64(readIndex, Int64(r + count))
    }

    /// Drops everything currently buffered. Used after a route change, when the
    /// samples in flight belong to the old device at the old sample rate.
    func clear() {
        zf_atomic_store_i64(readIndex, zf_atomic_load_i64(writeIndex))
    }
}
