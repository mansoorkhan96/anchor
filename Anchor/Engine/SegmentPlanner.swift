import Foundation

/// Pure segment arithmetic used by the HTTP engine.
enum SegmentPlanner {
    static let minimumSegment: Int64 = 1 << 20 // 1 MiB
    /// Splitting a busy segment costs a reconnect when its connection reaches the new end, so each half must be
    /// at least this big to be worth it (only segments with 4 MiB or more left are split).
    static let minimumSplitHalf: Int64 = 2 << 20

    /// Splits `total` bytes into at most `connections` contiguous segments of at least `minimumSegment`.
    static func plan(total: Int64, connections: Int, minimumSegment: Int64 = minimumSegment) -> [Segment] {
        guard total > 0 else { return [] }
        let count = Int(max(1, min(Int64(max(1, connections)), total / max(1, minimumSegment))))
        let base = total / Int64(count)
        var segments: [Segment] = []
        var start: Int64 = 0
        for index in 0..<count {
            let end = index == count - 1 ? total - 1 : start + base - 1
            segments.append(Segment(start: start, end: end))
            start = end + 1
        }
        return segments
    }

    /// Index of the first segment that still needs bytes and has no connection working on it.
    static func nextPending(_ segments: [Segment], busy: Set<Int>) -> Int? {
        segments.indices.first { !segments[$0].isComplete && !busy.contains($0) }
    }

    /// Steals the back half of the busy segment with the most bytes left, appending it as a new segment.
    /// Returns the new segment's index, or nil when nothing is big enough to be worth splitting.
    static func splitLargest(_ segments: inout [Segment], busy: Set<Int>, minimumHalf: Int64 = minimumSplitHalf) -> Int? {
        guard let index = busy
            .filter({ segments.indices.contains($0) })
            .max(by: { segments[$0].remaining < segments[$1].remaining }),
            segments[index].remaining >= minimumHalf * 2
        else { return nil }

        let old = segments[index]
        let mid = old.nextOffset + old.remaining / 2
        segments[index].end = mid - 1
        segments.append(Segment(start: mid, end: old.end))
        return segments.count - 1
    }

    static func received(_ segments: [Segment]) -> Int64 {
        segments.reduce(0) { $0 + $1.received }
    }
}
