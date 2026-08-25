import Foundation

enum OrphanClassifier {
    static func classify(_ snapshots: [ProcessSnapshot]) -> [ProcessSnapshot] {
        let byPID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })

        return snapshots.map { snapshot in
            guard snapshot.kind == .agent else { return snapshot }

            var updated = snapshot
            updated.orphanReason = orphanReason(snapshot, in: byPID)
            return updated
        }
    }

    private static func orphanReason(
        _ snapshot: ProcessSnapshot,
        in byPID: [Int32: ProcessSnapshot]
    ) -> OrphanReason? {
        if snapshot.parentPID <= 1 {
            return .reparentedToLaunchd
        }

        var currentPID = snapshot.parentPID
        var visited: Set<Int32> = [snapshot.id]
        var depth = 0

        while currentPID > 1, depth < 24 {
            guard !visited.contains(currentPID) else { return .cyclicLineage }
            visited.insert(currentPID)

            guard let ancestor = byPID[currentPID] else {
                return .missingParent
            }

            if isSessionHost(ancestor) {
                return nil
            }

            currentPID = ancestor.parentPID
            depth += 1
        }

        return snapshot.tty == "??" ? .detachedSession : nil
    }

    private static func isSessionHost(_ snapshot: ProcessSnapshot) -> Bool {
        let value = snapshot.executablePath.lowercased()
        return [
            "orca helper",
            "terminal.app",
            "iterm",
            "wezterm",
            "alacritty",
            "kitty.app",
            "/tmux",
            "/zellij",
            "muxy",
        ].contains { value.contains($0) }
    }
}
