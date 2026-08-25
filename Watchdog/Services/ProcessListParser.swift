import Foundation

enum ProcessListParser {
    static func parse(_ output: String) -> [ProcessSnapshot] {
        output
            .split(whereSeparator: \Character.isNewline)
            .compactMap { parseLine(String($0)) }
    }

    static func parseLine(_ line: String) -> ProcessSnapshot? {
        let fields = line.split(
            maxSplits: 8,
            omittingEmptySubsequences: true,
            whereSeparator: \Character.isWhitespace
        )

        guard fields.count == 9,
              let pid = Int32(fields[0]),
              let parentPID = Int32(fields[1]),
              let processGroupID = Int32(fields[2]),
              let userID = UInt32(fields[3]),
              let residentKilobytes = UInt64(fields[5])
        else {
            return nil
        }

        return ProcessSnapshot(
            id: pid,
            parentPID: parentPID,
            processGroupID: processGroupID,
            userID: userID,
            tty: String(fields[4]),
            cpuPercent: 0,
            residentBytes: residentKilobytes * 1_024,
            state: String(fields[6]),
            elapsed: String(fields[7]),
            executablePath: String(fields[8]),
            workingDirectory: nil
        )
    }
}
