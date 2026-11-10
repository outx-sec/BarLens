import Foundation
import CMenuBarPrivate
import DividerIPC

// This process owns the assertion and no status items. Exiting releases every
// restriction, including when its parent crashes or its connection gets stuck.
func log(_ message: String) { NSLog("BarLensAgent: %@", message) }
let diagnostics = DiagnosticLog(source: .agent)
diagnostics.record(event: "agent.started")

guard MBPrivateAPIAvailable() else {
    log("MenuBarAgent's private API is unavailable")
    diagnostics.record(event: "agent.exit", details: ["reason": "private_api_unavailable", "status": "1"])
    diagnostics.flush()
    exit(1)
}

let assertion = MBMenuBarAssertion()
var state = AgentApplicationState()
var latestCommand: AgentCommand?
var latestStamp: AgentCommand.FileStamp?
var lastStatusWrite = Date.distantPast
let startedAt = Date()
var statusWriteFailure: String?

@Sendable func publishStatus(force: Bool = false) {
    // Both the polling timer and CMenuBarPrivate's completion contract run on
    // the main queue; state must never be read from an XPC reply thread.
    dispatchPrecondition(condition: .onQueue(.main))
    guard let command = latestCommand else { return }
    let now = Date()
    guard force || now.timeIntervalSince(lastStatusWrite) >= AgentCommand.heartbeatInterval else { return }
    let status = AgentStatus(sessionID: command.sessionID,
                             processID: ProcessInfo.processInfo.processIdentifier,
                             requestID: state.acknowledgedRequestID,
                             isApplying: state.isApplying,
                             error: state.error)
    do {
        try status.write()
        lastStatusWrite = now
        if statusWriteFailure != nil { diagnostics.record(event: "status.write_restored") }
        statusWriteFailure = nil
    } catch {
        let failure = "\((error as NSError).domain):\((error as NSError).code)"
        // A full disk or revoked permission should not log on every poll.
        if statusWriteFailure != failure {
            log("could not write status: \(error.localizedDescription)")
            diagnostics.record(event: "status.write_failed", details: ["error": failure])
            statusWriteFailure = failure
        }
    }
}

func tick() {
    let command: AgentCommand?
    if let stamp = AgentCommand.fileStamp() {
        if stamp == latestStamp, let cached = latestCommand {
            command = cached
        } else if let decoded = AgentCommand.read() {
            latestStamp = stamp
            command = decoded
        } else {
            command = latestCommand
        }
    } else {
        latestStamp = nil
        command = nil
    }
    guard let command else {
        if latestCommand != nil || Date().timeIntervalSince(startedAt) > 15 {
            assertion.deactivate()
            diagnostics.record(event: "agent.exit", details: ["reason": "missing_command", "status": "0"])
            diagnostics.flush()
            exit(0)
        }
        return
    }
    let isNewRequest = latestCommand?.requestID != command.requestID
        || latestCommand?.sessionID != command.sessionID
    latestCommand = command
    if command.isStale || command.mode == .stop {
        assertion.deactivate()
        diagnostics.record(event: "agent.exit", details: [
            "reason": command.isStale ? "stale_heartbeat" : "stop_requested", "status": "0"
        ])
        diagnostics.flush()
        exit(0)
    }
    // A missing private API callback is a broken connection, not an applied
    // restriction. Exit so the UI can establish a fresh connection.
    if state.activationTimedOut(now: Date()) {
        log("activation timed out; reconnecting")
        diagnostics.record(event: "activation.timeout", details: ["request": command.requestID])
        assertion.deactivate()
        diagnostics.flush()
        exit(2)
    }

    switch state.update(command, now: Date()) {
    case .none:
        if isNewRequest, command.mode == .suspend {
            diagnostics.record(event: "restriction.suspended", details: ["request": command.requestID])
        }
    case .deactivate:
        assertion.deactivate()
        diagnostics.record(event: "restriction.suspended", details: ["request": command.requestID])
        publishStatus(force: true)
    case .apply(let request, let token):
        let activationStarted = ProcessInfo.processInfo.systemUptime
        let requestID = request.requestID
        diagnostics.record(event: "activation.started", details: [
            "request": request.requestID, "allowedCount": String(request.allowed.count),
            "hiddenSystemCount": String(request.hiddenSystemItems.count)
        ])
        assertion.acquire(withAllowedBundles: request.allowed,
                          hiddenSystemItems: request.hiddenSystemItems.map(NSNumber.init(value:))) { error in
            let message = error.map { "菜单栏连接失败：\($0.localizedDescription)" }
            if state.complete(token: token, error: message, now: Date()) {
                if let message { log(message) }
                var details = ["request": requestID,
                               "elapsedMs": String(Int((ProcessInfo.processInfo.systemUptime - activationStarted) * 1000))]
                if let error {
                    details["error"] = "\((error as NSError).domain):\((error as NSError).code)"
                }
                diagnostics.record(event: error == nil ? "activation.succeeded" : "activation.failed",
                                   details: details)
                publishStatus(force: true)
            }
        }
        publishStatus(force: true)
    }
    publishStatus()
}

// Watch the command directory so atomic command writes wake the agent
// immediately instead of waiting for the next timer fire.
var directorySource: DispatchSourceFileSystemObject?
try? AgentCommand.ensureSecureDirectory()
AgentCommand.cleanupStaleTempFiles()
let dirFD = open(AgentCommand.directory.path, O_EVTONLY)
if dirFD >= 0 {
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFD,
                                                           eventMask: .write,
                                                           queue: .main)
    source.setEventHandler { tick() }
    source.setCancelHandler { close(dirFD) }
    source.resume()
    directorySource = source
}

// Watch the parent UI process so an unexpected crash releases the menu bar
// restriction immediately without waiting for the 10-second heartbeat timeout.
var parentSource: DispatchSourceProcess?
let parentPID = getppid()
if parentPID > 1 {
    let source = DispatchSource.makeProcessSource(identifier: parentPID,
                                                  eventMask: .exit,
                                                  queue: .main)
    source.setEventHandler {
        assertion.deactivate()
        diagnostics.record(event: "agent.exit", details: ["reason": "parent_exited", "status": "0"])
        diagnostics.flush()
        exit(0)
    }
    source.resume()
    parentSource = source
}

let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in tick() }
RunLoop.main.add(timer, forMode: .common)
tick()
RunLoop.main.run()
