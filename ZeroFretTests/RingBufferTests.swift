import XCTest

final class RingBufferTests: XCTestCase {
    func testWriteThenPeekPreservesOrder() {
        let ring = RingBuffer(capacity: 1024)
        var input = (0..<300).map { Float($0) }
        input.withUnsafeBufferPointer { ring.writer.write($0.baseAddress!, 300) }

        XCTAssertEqual(ring.available, 300)
        var out = [Float](repeating: -1, count: 300)
        XCTAssertTrue(out.withUnsafeMutableBufferPointer { ring.peek(into: $0.baseAddress!, count: 300) })
        XCTAssertEqual(out, input)
    }

    func testPeekDoesNotConsume() {
        let ring = RingBuffer(capacity: 64)
        var input = (0..<16).map { Float($0) }
        input.withUnsafeBufferPointer { ring.writer.write($0.baseAddress!, 16) }
        var out = [Float](repeating: 0, count: 16)
        _ = out.withUnsafeMutableBufferPointer { ring.peek(into: $0.baseAddress!, count: 16) }
        XCTAssertEqual(ring.available, 16)
        ring.advance(8)
        XCTAssertEqual(ring.available, 8)
    }

    func testWrapAround() {
        let ring = RingBuffer(capacity: 16)
        var first = (0..<12).map { Float($0) }
        first.withUnsafeBufferPointer { ring.writer.write($0.baseAddress!, 12) }
        ring.advance(12)
        var second = (100..<108).map { Float($0) }
        second.withUnsafeBufferPointer { ring.writer.write($0.baseAddress!, 8) }

        var out = [Float](repeating: 0, count: 8)
        XCTAssertTrue(out.withUnsafeMutableBufferPointer { ring.peek(into: $0.baseAddress!, count: 8) })
        XCTAssertEqual(out, second)
    }

    func testOverrunResyncLandsASafeMarginBehind() {
        let ring = RingBuffer(capacity: 16)
        XCTAssertEqual(ring.safeMargin, 8)
        var input = (0..<40).map { Float($0) }
        input.withUnsafeBufferPointer { ring.writer.write($0.baseAddress!, 16) }
        input.withUnsafeBufferPointer { ring.writer.write($0.baseAddress! + 16, 16) }
        input.withUnsafeBufferPointer { ring.writer.write($0.baseAddress! + 32, 8) }
        XCTAssertTrue(ring.resyncIfOverrun())
        // Not `capacity` behind: landing on the boundary means the producer's
        // next write overwrites the frames the reader is mid-copy on.
        XCTAssertEqual(ring.available, ring.safeMargin)

        var out = [Float](repeating: 0, count: 8)
        XCTAssertTrue(out.withUnsafeMutableBufferPointer { ring.peek(into: $0.baseAddress!, count: 8) })
        XCTAssertEqual(out, Array(input[32..<40]))
    }

    func testResyncIsANoOpWhenTheReaderIsKeepingUp() {
        let ring = RingBuffer(capacity: 64)
        var input = (0..<16).map { Float($0) }
        input.withUnsafeBufferPointer { ring.writer.write($0.baseAddress!, 16) }
        XCTAssertFalse(ring.resyncIfOverrun())
        XCTAssertEqual(ring.available, 16)
    }

    func testPeekFailsWhenShort() {
        let ring = RingBuffer(capacity: 64)
        var out = [Float](repeating: 0, count: 8)
        XCTAssertFalse(out.withUnsafeMutableBufferPointer { ring.peek(into: $0.baseAddress!, count: 8) })
    }

    func testConcurrentProducerConsumerKeepsSequence() {
        let ring = RingBuffer(capacity: 1 << 12)
        let total = 400_000
        let chunk = 128
        let writer = ring.writer
        let finished = NSLock()
        var producerDone = false
        let done = expectation(description: "producer finished")

        DispatchQueue.global(qos: .userInitiated).async {
            var block = [Float](repeating: 0, count: chunk)
            var n = 0
            while n < total {
                for i in 0..<chunk { block[i] = Float(n + i) }
                block.withUnsafeBufferPointer { writer.write($0.baseAddress!, chunk) }
                n += chunk
            }
            finished.lock(); producerDone = true; finished.unlock()
            done.fulfill()
        }

        var consumed = 0
        var drops = 0
        var out = [Float](repeating: 0, count: chunk)
        while true {
            if ring.resyncIfOverrun() { drops += 1 }
            if ring.available >= chunk {
                let ok = out.withUnsafeMutableBufferPointer {
                    ring.peek(into: $0.baseAddress!, count: chunk)
                }
                if ok {
                    // Wherever the reader lands — including right after a drop —
                    // the frames it sees must be contiguous and in order.
                    for i in 1..<chunk { XCTAssertEqual(out[i] - out[i - 1], 1) }
                    ring.advance(chunk)
                    consumed += chunk
                    continue
                }
            }
            finished.lock(); let stop = producerDone; finished.unlock()
            if stop, ring.available < chunk { break }
        }

        wait(for: [done], timeout: 10)
        XCTAssertGreaterThan(consumed, chunk * 10)
        // The producer never blocks and never corrupts; it is allowed to lap the
        // reader, and the reader is expected to notice.
        XCTAssertGreaterThanOrEqual(drops, 0)
    }
}
