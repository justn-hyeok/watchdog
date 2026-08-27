import Foundation

enum CommandRunnerError: LocalizedError, Sendable {
    case launchFailed(executable: String, message: String)
    case failed(executable: String, status: Int32, message: String)
    case timedOut(executable: String)
    case cancelled(executable: String)
    case resourceLimit(executable: String)

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
        case let .resourceLimit(executable):
            return "\(executable) 실행 대기 한도 초과"
        }
    }
}

enum CommandRunner {
    private static let admission = HelperProcessAdmission(capacity: 3)

    static func run(
        _ executable: String,
        arguments: [String],
        deadline: Duration
    ) async throws -> String {
        let state = ChildProcessState()

        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    guard state.install(continuation) else { return }
                    guard admission.acquire() else {
                        state.complete(
                            .failure(CommandRunnerError.resourceLimit(executable: executable))
                        )
                        return
                    }
                    DispatchQueue.global(qos: .utility).async {
                        defer { admission.release() }
                        do {
                            let result = try runChild(
                                executable,
                                arguments: arguments,
                                state: state
                            )
                            state.complete(.success(result))
                        } catch {
                            state.complete(.failure(error))
                        }
                    }
                    Task {
                        do {
                            try await ContinuousClock().sleep(for: deadline)
                            state.timeout(executable: executable)
                        } catch {
                            return
                        }
                    }
                }
            } onCancel: {
                state.cancel(executable: executable)
            }
        } catch is CancellationError {
            throw CommandRunnerError.cancelled(executable: executable)
        }
    }

#if DEBUG
    static var activeProcessCountPreview: Int { admission.activeCount }
#endif

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
        state.clear(process)

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

private final class HelperProcessAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var active = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func acquire() -> Bool {
        lock.withLock {
            guard active < capacity else { return false }
            active += 1
            return true
        }
    }

    func release() {
        lock.withLock {
            precondition(active > 0)
            active -= 1
        }
    }

    var activeCount: Int {
        lock.withLock { active }
    }
}

private final class ChildProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var continuation: CheckedContinuation<String, Error>?
    private var completion: Result<String, Error>?

    func register(_ process: Process) -> Bool {
        lock.withLock {
            guard completion == nil else { return false }
            self.process = process
            return true
        }
    }

    func install(_ continuation: CheckedContinuation<String, Error>) -> Bool {
        let result = lock.withLock { () -> Result<String, Error>? in
            if let completion {
                return completion
            }
            self.continuation = continuation
            return nil
        }
        if let result {
            continuation.resume(with: result)
            return false
        }
        return true
    }

    func terminateIfCancelled(_ process: Process) {
        let shouldTerminate = lock.withLock { completion != nil && self.process === process }
        if shouldTerminate, process.isRunning {
            process.terminate()
        }
    }

    func clear(_ process: Process) {
        lock.withLock {
            if self.process === process {
                self.process = nil
            }
        }
    }

    func complete(_ result: Result<String, Error>) {
        finish(with: result, terminate: false)
    }

    func timeout(executable: String) {
        finish(
            with: .failure(CommandRunnerError.timedOut(executable: executable)),
            terminate: true
        )
    }

    func cancel(executable: String) {
        finish(
            with: .failure(CommandRunnerError.cancelled(executable: executable)),
            terminate: true
        )
    }

    private func finish(with result: Result<String, Error>, terminate: Bool) {
        let resolved: (
            continuation: CheckedContinuation<String, Error>?,
            process: Process?
        ) = lock.withLock {
            guard completion == nil else {
                return (continuation: nil, process: nil)
            }
            completion = result
            let continuation = self.continuation
            self.continuation = nil
            return (continuation: continuation, process: terminate ? process : nil)
        }
        if let runningProcess = resolved.process, runningProcess.isRunning {
            runningProcess.terminate()
        }
        resolved.continuation?.resume(with: result)
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
