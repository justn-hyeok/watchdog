import Foundation

struct MemoryProcessTracker {
    private var base = SustainedProcessTracker<UInt64>()

    mutating func reset() {
        base.reset()
    }

    mutating func update(
        snapshots: [ProcessSnapshot],
        thresholdBytes: UInt64,
        sustainedFor duration: TimeInterval,
        ignoredProcesses: Set<ProcessIdentity>,
        at instant: ContinuousClock.Instant
    ) -> Set<ProcessIdentity> {
        base.update(
            snapshots: snapshots,
            metric: { $0.residentBytes },
            threshold: thresholdBytes,
            sustainedFor: duration,
            ignoredProcesses: ignoredProcesses,
            at: instant
        )
    }
}
