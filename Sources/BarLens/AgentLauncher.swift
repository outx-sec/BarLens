import AppKit
import DividerIPC

/// Keeps at most one helper alive and backs off after unexpected exits. The
/// engine owns retries so it always refreshes the command before starting one.
final class AgentLauncher {
    struct Exit {
        let processID: Int32
        let status: Int32
        let wasSignalled: Bool
        let expected: Bool
        let retryAt: Date?

        var description: String {
            wasSignalled
                ? tr("菜单栏助手被信号 \(status) 终止", "Helper terminated by signal \(status)")
                : tr("菜单栏助手退出（代码 \(status)）", "Helper exited (code \(status))")
        }
    }

    private var process: Process?
    private var wantsRunning = false
    private var isTerminating = false
    private var retryPolicy = AgentRestartPolicy()
    private let executableURL: () -> URL?
    private let arguments: [String]
    private let now: () -> Date
    private let diagnostics: DiagnosticLog

    var onFailure: ((String) -> Void)?
    var onStarted: ((Int32) -> Void)?
    var onExit: ((Exit) -> Void)?
    private(set) var lastExitDescription: String?

    init(executableURL: @escaping () -> URL? = {
        Bundle.main.url(forAuxiliaryExecutable: "BarLensAgent")
    }, arguments: [String] = [], now: @escaping () -> Date = Date.init,
         diagnostics: DiagnosticLog = DiagnosticLog(source: .app)) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.now = now
        self.diagnostics = diagnostics
    }

    func start() {
        wantsRunning = true
        guard canStartNow else { return }
        launch()
    }

    func restart(resetBackoff: Bool = false) {
        wantsRunning = true
        if resetBackoff {
            retryPolicy.reset()
            lastExitDescription = nil
            diagnostics.record(event: "helper.manual_retry")
        }
        if let process {
            if process.isRunning { terminate(process) }
            // If it already exited, let its handler reap and classify it first.
            // The next engine heartbeat then observes the retry deadline.
            return
        }
        if canStartNow { launch() }
    }

    func stop() {
        wantsRunning = false
        if let process, process.isRunning { terminate(process) }
    }

    func noteHealthy() {
        guard isRunning, !isTerminating else { return }
        let previousFailures = retryPolicy.consecutiveFailures
        retryPolicy.noteHealthy(at: now())
        if previousFailures > 0, retryPolicy.consecutiveFailures == 0 {
            lastExitDescription = nil
            diagnostics.record(event: "helper.stable", details: ["pid": String(processID ?? 0)])
        }
    }

    var isRunning: Bool { process?.isRunning ?? false }
    // A fresh acknowledgement from the predecessor must not complete a
    // recovery that is waiting for its replacement to start.
    var processID: Int32? { isRunning && !isTerminating ? process?.processIdentifier : nil }
    var consecutiveFailures: Int { retryPolicy.consecutiveFailures }
    var nextRetryAt: Date? { retryPolicy.nextRetryAt }
    var canStartNow: Bool {
        process == nil && !isTerminating && retryPolicy.canAttempt(at: now())
    }

    private func terminate(_ task: Process) {
        guard !isTerminating else { return }
        isTerminating = true
        diagnostics.record(event: "helper.stop_requested", details: [
            "pid": String(task.processIdentifier), "restart": String(wantsRunning)
        ])
        task.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak task] in
            guard let self, let task, self.process === task, task.isRunning else { return }
            self.diagnostics.record(event: "helper.force_stop", details: ["pid": String(task.processIdentifier)])
            kill(task.processIdentifier, SIGKILL)
        }
    }

    private func launchFailed(_ message: String, reason: String) {
        let delay = retryPolicy.recordFailure(at: now())
        lastExitDescription = message
        diagnostics.record(event: "helper.launch_failed", details: [
            "reason": reason, "retrySeconds": String(Int(delay)),
            "failures": String(retryPolicy.consecutiveFailures)
        ])
        onFailure?(message)
    }

    private func launch() {
        guard wantsRunning, canStartNow else { return }
        guard let url = executableURL() else {
            launchFailed(tr("找不到菜单栏助手，请重新安装完整的 App。", "Menu bar helper executable is missing; please reinstall BarLens."), reason: "missing_executable")
            return
        }
        let task = Process()
        task.executableURL = url
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        // Keep stderr attached for Console, in addition to bounded event files.
        task.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.process === finished else { return }
                let expected = self.isTerminating || !self.wantsRunning
                self.process = nil
                self.isTerminating = false
                if !expected { self.retryPolicy.recordFailure(at: self.now()) }
                let event = Exit(processID: finished.processIdentifier,
                                 status: finished.terminationStatus,
                                 wasSignalled: finished.terminationReason == .uncaughtSignal,
                                 expected: expected,
                                 retryAt: expected ? nil : self.retryPolicy.nextRetryAt)
                if !expected { self.lastExitDescription = event.description }
                self.diagnostics.record(event: "helper.exited", details: [
                    "pid": String(event.processID), "status": String(event.status),
                    "signal": String(event.wasSignalled), "expected": String(expected),
                    "failures": String(self.retryPolicy.consecutiveFailures),
                    "retrySeconds": String(max(0, Int((event.retryAt ?? self.now()).timeIntervalSince(self.now()))))
                ])
                self.onExit?(event)
                // A requested replacement resumes here, still respecting any
                // existing delay. Unexpected exits wait for the engine.
                if self.wantsRunning && expected && self.canStartNow { self.launch() }
            }
        }
        do {
            try task.run()
            process = task
            retryPolicy.didLaunch()
            diagnostics.record(event: "helper.started", details: [
                "pid": String(task.processIdentifier), "failures": String(retryPolicy.consecutiveFailures)
            ])
            onStarted?(task.processIdentifier)
        } catch {
            let nsError = error as NSError
            launchFailed(tr("无法启动菜单栏助手：\(error.localizedDescription)", "Failed to launch menu bar helper: \(error.localizedDescription)"),
                         reason: "\(nsError.domain):\(nsError.code)")
        }
    }
}
