import Foundation

struct HotProcessTracker {
    private var base = SustainedProcessTracker<Double>()

    mutating func reset() {
        base.reset()
    }

    mutating func update(
        snapshots: [ProcessSnapshot],
        threshold: Double,
        sustainedFor duration: TimeInterval,
        ignoredProcesses: Set<ProcessIdentity>,
        at instant: ContinuousClock.Instant
    ) -> Set<ProcessIdentity> {
        base.update(
            snapshots: snapshots,
            metric: { $0.cpuPercent },
            threshold: threshold,
            sustainedFor: duration,
            ignoredProcesses: ignoredProcesses,
            at: instant
        )
    }
}
