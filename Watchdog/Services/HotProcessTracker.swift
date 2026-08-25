import Foundation

struct HotProcessTracker {
    private struct State {
        var since: ContinuousClock.Instant
        var lastSeen: ContinuousClock.Instant
    }

    private var states: [ProcessIdentity: State] = [:]
    let continuityGap: Duration

    init(continuityGap: Duration = .seconds(5)) {
        self.continuityGap = continuityGap
    }

    mutating func reset() {
        states.removeAll(keepingCapacity: true)
    }

    mutating func update(
        snapshots: [ProcessSnapshot],
        threshold: Double,
        sustainedFor duration: TimeInterval,
        ignoredProcesses: Set<ProcessIdentity>,
        at instant: ContinuousClock.Instant
    ) -> Set<ProcessIdentity> {
        let liveIdentities = Set(snapshots.map(\.identity))
        states = states.filter { liveIdentities.contains($0.key) }

        var hotProcesses: Set<ProcessIdentity> = []

        for snapshot in snapshots {
            guard snapshot.canControl,
                  !ignoredProcesses.contains(snapshot.identity),
                  snapshot.cpuPercent >= threshold
            else {
                states.removeValue(forKey: snapshot.identity)
                continue
            }

            let state: State
            if var existing = states[snapshot.identity] {
                let gap = existing.lastSeen.duration(to: instant)
                if gap < .zero || gap > continuityGap {
                    state = State(since: instant, lastSeen: instant)
                } else {
                    existing.lastSeen = instant
                    state = existing
                }
            } else {
                state = State(since: instant, lastSeen: instant)
            }
            states[snapshot.identity] = state

            if state.since.duration(to: instant) >= .seconds(duration) {
                hotProcesses.insert(snapshot.identity)
            }
        }

        return hotProcesses
    }
}
