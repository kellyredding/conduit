import Foundation

/// Runs a subprocess and returns its output without ever parking a thread on
/// the child.
///
/// The structure here — event-driven pipe draining, a callback for exit, a
/// hard timeout, and a grace period for a lost termination notification — is
/// adapted from the runner in Galactic, another project by the same author,
/// which paid for these lessons in production. Conduit keeps its own copy
/// rather than depending on that package, because two of its requirements do
/// not fit there and would have to be pushed upstream:
///
///   - The child's environment must be overridable. Supplying a corrected HOME
///     is the whole reason this application exists.
///   - Output on standard *out* must survive a non-zero exit. The client this
///     drives reports its errors as a JSON envelope on stdout, so a runner that
///     keeps only stderr loses every error message it was asked to relay.
///
/// The lesson worth restating, since it is the reason for all of the below:
/// `readDataToEndOfFile()` followed by `waitUntilExit()` parks a worker thread
/// for the lifetime of every child. When a termination notification is lost —
/// which happens across sleep/wake transitions — that thread never comes back.
/// A polling application spawns a subprocess every few seconds and runs across
/// every sleep/wake cycle, so enough leak to exhaust the dispatch pool, after
/// which no new work can be scheduled and the app hangs with an idle main
/// thread. Everything here exists to make that impossible:
///
///   - Both pipes drain through `readabilityHandler`, which is an event source
///     rather than a parked thread, so they drain concurrently and the ~64KB
///     pipe-buffer deadlock cannot happen.
///   - Exit arrives via `terminationHandler`, never a blocking wait.
///   - A hard timeout bounds every run. On timeout the child is terminated,
///     then killed after a grace period; closing its pipes drives the reads to
///     EOF and tears everything down. Even if every notification is lost, a run
///     self-destructs after `timeout` seconds instead of leaking.
///
/// One instance is one cancellation domain: `cancelAll()` terminates every
/// child it launched and not those of any other instance.
final class ProcessRunner: @unchecked Sendable {
    private let defaultTimeout: TimeInterval

    private let registryLock = NSLock()
    private var live: [ObjectIdentifier: Process] = [:]

    init(defaultTimeout: TimeInterval = 15) {
        self.defaultTimeout = defaultTimeout
    }

    /// Terminate every in-flight subprocess this runner launched. Each
    /// terminated child closes its pipes, which drives its in-progress run to
    /// completion rather than leaving it hanging.
    func cancelAll() {
        registryLock.lock()
        let processes = Array(live.values)
        registryLock.unlock()
        for process in processes where process.isRunning {
            process.terminate()
        }
    }

    /// Spawn `executable` with `arguments` and return its standard output.
    ///
    /// `environment` is merged over the current process's environment rather
    /// than replacing it, so a caller overriding one variable does not have to
    /// reconstruct PATH and everything else the child may need.
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        try Task.checkCancellation()

        return try await withCheckedThrowingContinuation { continuation in
            Self.drive(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: timeout ?? defaultTimeout,
                onLaunch: { self.register($0) },
                onFinish: { self.deregister($0) },
                completion: { continuation.resume(with: $0) }
            )
        }
    }

    // MARK: - Core

    private static func drive(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout limit: TimeInterval,
        onLaunch: ((Process) -> Void)?,
        onFinish: ((Process) -> Void)?,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()

        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe

        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, override in override }
        }

        let binary = executable.lastPathComponent

        // All completion state is mutated only on this serial queue, so the
        // three event sources — stdout EOF, stderr EOF, termination — and the
        // timeout can never race.
        let coord = DispatchQueue(label: "conduit.processrunner.\(binary)")

        // Held in a reference box rather than as locals. The handlers below
        // outlive this function, and a pointer to a local variable must not
        // escape it — capturing the box is what makes the shared mutation both
        // legal and visible to every handler.
        let state = RunState()

        let timer = DispatchSource.makeTimerSource(queue: coord)
        timer.schedule(deadline: .now() + limit)

        func finish(_ result: Result<Data, Error>) {
            if state.finished { return }
            state.finished = true
            timer.cancel()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            onFinish?(process)
            completion(result)
        }

        // Resolve once both pipes have hit EOF and the process has terminated,
        // so the exit status is valid and all output has been drained.
        func completeIfReady() {
            guard !state.finished, state.pending == 0 else { return }
            let status = process.terminationStatus
            if status == 0 {
                finish(.success(state.outBuf))
            } else {
                // Both streams are carried. Which one holds the explanation is
                // the callee's convention, not this runner's business, and
                // guessing wrong silently discards the only error message.
                finish(
                    .failure(
                        ProcessRunError.exited(
                            binary: binary,
                            status: status,
                            standardOutput: state.outBuf,
                            standardError: state.errBuf
                        )
                    )
                )
            }
        }

        // Both pipes reached EOF — the child closed its descriptors, so it has
        // exited — but the termination callback never fired. Most likely the
        // notification was lost across a sleep/wake transition. Give it a short
        // grace, then resolve with the fully drained output rather than waiting
        // out the hard timeout. The status is unknown, so success is assumed: a
        // process that died mid-write yields output its caller fails to parse,
        // which is a better failure than a stall.
        func armEofGrace() {
            guard !state.finished, state.outDone, state.errDone else { return }
            coord.asyncAfter(deadline: .now() + 2.0) {
                guard !state.finished else { return }
                finish(.success(state.outBuf))
            }
        }

        func drain(_ pipe: Pipe, isStandardOutput: Bool) {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                // Stop EOF re-firing: the source stays readable at EOF until
                // the handler is cleared.
                if chunk.isEmpty { handle.readabilityHandler = nil }
                coord.async {
                    guard !state.finished else { return }
                    if chunk.isEmpty {
                        if isStandardOutput {
                            guard !state.outDone else { return }
                            state.outDone = true
                        } else {
                            guard !state.errDone else { return }
                            state.errDone = true
                        }
                        state.pending -= 1
                        completeIfReady()
                        armEofGrace()
                    } else if isStandardOutput {
                        state.outBuf.append(chunk)
                    } else {
                        state.errBuf.append(chunk)
                    }
                }
            }
        }

        drain(outPipe, isStandardOutput: true)
        drain(errPipe, isStandardOutput: false)

        process.terminationHandler = { _ in
            coord.async {
                guard !state.finished else { return }
                state.pending -= 1
                completeIfReady()
            }
        }

        timer.setEventHandler {
            guard !state.finished else { return }
            if process.isRunning { process.terminate() }
            let pid = process.processIdentifier
            coord.asyncAfter(deadline: .now() + 2.0) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
            finish(
                .failure(ProcessRunError.timedOut(binary: binary, seconds: limit))
            )
        }

        do {
            try process.run()
        } catch {
            timer.cancel()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            completion(
                .failure(
                    ProcessRunError.launchFailed(binary: binary, underlying: error)
                )
            )
            return
        }

        onLaunch?(process)

        // Armed on `coord` so it is ordered against a process that finishes
        // before this line runs, in which case `finished` is already set and
        // the timer — cancelled by finish() — never activates.
        coord.async {
            guard !state.finished else { return }
            timer.activate()
        }
    }

    // MARK: - Registry

    private func register(_ process: Process) {
        registryLock.lock()
        live[ObjectIdentifier(process)] = process
        registryLock.unlock()
    }

    private func deregister(_ process: Process) {
        registryLock.lock()
        live[ObjectIdentifier(process)] = nil
        registryLock.unlock()
    }
}

/// Mutable state shared by the handlers driving one run. Every field is
/// touched only on that run's coordination queue, which is what makes a plain
/// class safe here without any locking of its own.
private final class RunState {
    var outBuf = Data()
    var errBuf = Data()
    var pending = 3
    var outDone = false
    var errDone = false
    var finished = false
}

enum ProcessRunError: Error, LocalizedError {
    case launchFailed(binary: String, underlying: Error)

    /// Carries both streams rather than choosing one. The client this runner
    /// drives writes its error envelope to standard output, so a case that
    /// kept only standard error would discard every message worth showing.
    case exited(
        binary: String,
        status: Int32,
        standardOutput: Data,
        standardError: Data
    )

    case timedOut(binary: String, seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let binary, let underlying):
            return "\(binary) failed to launch: \(underlying.localizedDescription)"
        case .exited(let binary, let status, _, _):
            return "\(binary) exited with status \(status)"
        case .timedOut(let binary, let seconds):
            return "\(binary) timed out after \(Int(seconds))s"
        }
    }
}
