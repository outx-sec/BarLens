import Foundation

/// Keeps positive knowledge across transient AX failures. Only an owner that
/// was successfully read can lose its old items; exited apps are removed even
/// when the rest of the scan fails. An entirely empty bar needs confirmation.
struct MenuBarScanState {
    private(set) var owners: Set<String> = []
    private var completeEmptySamples = 0
    private var pendingAbsences: Set<String> = []

    init(owners: Set<String> = []) { self.owners = owners }

    /// Sleep or a new scan generation breaks the continuity of observations.
    /// Keep positive knowledge, but never combine absences across that gap.
    mutating func resetAbsenceConfirmation() {
        completeEmptySamples = 0
        pendingAbsences = []
    }

    /// Returns whether another bounded scan is needed before trusting absence.
    @discardableResult
    mutating func accept(_ result: ItemScanResult, running: Set<String>) -> Bool {
        owners.formIntersection(running)
        guard result.permissionGranted, !result.cancelled else {
            resetAbsenceConfirmation()
            return false
        }
        let observed = Set(result.items.map(\.ownerBundleID)).intersection(running)
        // A successful but momentarily empty AX tree is possible during wake.
        // Confirm each disappearance twice, even when other apps already read
        // correctly. A failure between samples breaks that confirmation.
        let missing = owners.intersection(result.completedOwners).subtracting(observed)
        let confirmedMissing = missing.intersection(pendingAbsences)
        let unconfirmedMissing = missing.subtracting(pendingAbsences)
        var next = owners.subtracting(confirmedMissing).union(observed)
        pendingAbsences = missing
        let relevantFailures = result.failedOwners.subtracting(SectionModel.notClassifiable)
        let complete = !result.timedOut && relevantFailures.isEmpty

        if observed.isEmpty && complete {
            completeEmptySamples += 1
            if completeEmptySamples < 2 { next.formUnion(owners) }
        } else {
            completeEmptySamples = 0
            if observed.isEmpty && !complete { next.formUnion(owners) }
        }
        owners = next.intersection(running)
        return !complete || !unconfirmedMissing.isEmpty || (observed.isEmpty && completeEmptySamples < 2)
    }
}

/// Resolves the dot from the same fully revealed snapshot used for classifying
/// applications. A coordinate captured before revealing is never an input.
enum BulkAssignmentBoundary {
    enum Failure: Error, CustomStringConvertible {
        case incomplete
        case missingDot
        case ambiguousDot

        var description: String {
            switch self {
            case .incomplete: return tr("菜单栏尚未读取完整，已保留原有划分，请稍后重试。", "Menu bar scan was incomplete; keeping previous sections.")
            case .missingDot: return tr("当前屏幕上找不到菜单栏圆点，已保留原有划分。", "Menu bar trigger icon was not found on this display; keeping previous sections.")
            case .ambiguousDot: return tr("无法确认菜单栏圆点的位置，已保留原有划分。", "Could not determine the trigger icon's position; keeping previous sections.")
            }
        }
    }

    static func resolve(in snapshot: ItemScanResult, on display: DisplayID) throws -> MenuBarItem {
        guard snapshot.permissionGranted, !snapshot.cancelled, !snapshot.timedOut,
              snapshot.failedOwners.subtracting(SectionModel.notClassifiable).isEmpty else {
            throw Failure.incomplete
        }
        let dots = snapshot.items.filter {
            $0.axIdentifier == "BarLens.dot" && $0.display == display
                && $0.frame.minX.isFinite && $0.frame.width > 0 && $0.frame.height > 0
        }
        guard !dots.isEmpty else { throw Failure.missingDot }
        guard dots.count == 1 else { throw Failure.ambiguousDot }
        return dots[0]
    }
}
