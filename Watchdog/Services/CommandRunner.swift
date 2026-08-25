import Foundation

enum CommandRunnerError: LocalizedError, Sendable {
    case launchFailed(executable: String, message: String)
    case failed(executable: String, status: Int32, message: String)
    case timedOut(executable: String)
    case cancelled(executable: String)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(executable, message):
            return "\(executable) 실행 실패: \(message)"
        case let .failed(executable, status, message):
            let detail = message.isEmpty ? "종료 코드 \(status)" : message
            return "\(executable) 실행 실패: \(detail)"
        case let .timedOut(executable):
            return "\(executable) 실행 시간 초과"
        case let .cancelled(executable):
            return "\(executable) 실행 취소됨"
        }
    }
}

enum CommandRunner {
    static func run(
        _ executable: String,
        arguments: [String],
        deadline: Duration
    ) async throws -> String {
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await execute(executable, arguments: arguments)
                }
                group.addTask {
                    try await ContinuousClock().sleep(for: deadline)
                    throw CommandRunnerError.timedOut(executable: executable)
                }

                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw CommandRunnerError.cancelled(executable: executable)
                }
                return result
            }
        } catch is CancellationError {
            throw CommandRunnerError.cancelled(executable: executable)
        }
    }

    private static func execute(
        _ executable: String,
        arguments: [String]
    ) async throws -> String {
        let state = ChildProcessState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try Task.checkCancellation()
                        let result = try runChild(
                            executable,
                            arguments: arguments,
                            state: state
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    private static func runChild(
        _ executable: String,
        arguments: [String],
        state: ChildProcessState
    ) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        guard state.register(process) else {
            close(standardOutput)
            close(standardError)
            throw CommandRunnerError.cancelled(executable: executable)
        }

        do {
            try process.run()
        } catch {
            state.clear(process)
            close(standardOutput)
            close(standardError)
            throw CommandRunnerError.launchFailed(
                executable: executable,
                message: error.localizedDescription
            )
        }

        let output = PipeDrain(pipe: standardOutput)
        let error = PipeDrain(pipe: standardError)
        output.start()
        error.start()
        state.terminateIfCancelled(process)
        process.waitUntilExit()
        let outputData = output.finish()
        let errorData = error.finish()
        let wasCancelled = state.clear(process)

        if wasCancelled {
            throw CommandRunnerError.cancelled(executable: executable)
        }

        return try decode(
            executable: executable,
            status: process.terminationStatus,
            output: outputData,
            error: errorData
        )
    }

    private static func decode(
        executable: String,
        status: Int32,
        output: Data,
        error: Data
    ) throws -> String {
        guard status == 0 else {
            throw CommandRunnerError.failed(
                executable: executable,
                status: status,
                message: String(decoding: error, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func close(_ pipe: Pipe) {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
}

private final class ChildProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func register(_ process: Process) -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            self.process = process
            return true
        }
    }

    func terminateIfCancelled(_ process: Process) {
        let shouldTerminate = lock.withLock { cancelled && self.process === process }
        if shouldTerminate, process.isRunning {
            process.terminate()
        }
    }

    @discardableResult
    func clear(_ process: Process) -> Bool {
        lock.withLock {
            if self.process === process {
                self.process = nil
            }
            return cancelled
        }
    }

    func cancel() {
        let runningProcess = lock.withLock {
            cancelled = true
            return process
        }
        if let runningProcess, runningProcess.isRunning {
            runningProcess.terminate()
        }
    }
}

private final class PipeDrain: @unchecked Sendable {
    private let pipe: Pipe
    private let queue = DispatchQueue(label: "watchdog.command-runner.pipe")
    private let group = DispatchGroup()
    private var data = Data()

    init(pipe: Pipe) {
        self.pipe = pipe
    }

    func start() {
        group.enter()
        queue.async { [self] in
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            try? pipe.fileHandleForReading.close()
            group.leave()
        }
        try? pipe.fileHandleForWriting.close()
    }

    func finish() -> Data {
        group.wait()
        return data
    }
}
