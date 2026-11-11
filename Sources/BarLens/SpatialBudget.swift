import AppKit
import Foundation

/// Policy governing how BarLens budgets top menu bar space for `.visible` items
/// so icons never get swallowed by a MacBook Notch or a wide application menu bar.
enum SpatialBudgetPolicy: String, CaseIterable, Identifiable, Codable {
    case off        = "off"
    case notchGuard = "notchGuard"
    case compact5   = "compact5"
    case balanced8  = "balanced8"
    case spacious12 = "spacious12"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:        return tr("关闭", "Off")
        case .notchGuard: return tr("防遮挡自动", "Auto Guard")
        case .compact5:   return tr("精简 · 5 席", "Compact · 5")
        case .balanced8:  return tr("均衡 · 8 席", "Balanced · 8")
        case .spacious12: return tr("宽裕 · 12 席", "Spacious · 12")
        }
    }

    var symbol: String {
        switch self {
        case .off:        return "rectangle.slash"
        case .notchGuard: return "shield.lefthalf.filled"
        case .compact5:   return "rectangle.compress.vertical"
        case .balanced8:  return "slider.horizontal.below.rectangle"
        case .spacious12: return "rectangle.expand.vertical"
        }
    }

    /// Optional hard ceiling on how many `.visible` third-party apps stay on the top bar at once.
    var maxVisibleAppSlots: Int? {
        switch self {
        case .off, .notchGuard: return nil
        case .compact5:         return 5
        case .balanced8:        return 8
        case .spacious12:       return 12
        }
    }
}

/// Why one or more `.visible` applications were temporarily tucked into the Floating Bar Lens.
enum SpatialDemotionReason: Equatable {
    case physicalSpace
    case slotCap
}

/// Geometry snapshot of the primary menu bar display used to compute right-side status item capacity.
struct DisplayMenuBarGeometry: Equatable {
    let displayID: DisplayID
    let screenMinX: CGFloat
    let screenMaxX: CGFloat
    /// Right-of-notch rect on MacBook displays (`NSScreen.auxiliaryTopRightArea`); `nil` on unnotched screens.
    let auxiliaryTopRightMinX: CGFloat?
    let auxiliaryTopRightMaxX: CGFloat?

    var hasPhysicalNotch: Bool {
        guard let minX = auxiliaryTopRightMinX, let maxX = auxiliaryTopRightMaxX else { return false }
        return maxX > minX && minX > screenMinX + 40
    }

    /// Computes horizontal space available on the right side of the menu bar for status items.
    func availableRightWidth(frontmostMenuWidth: CGFloat?) -> CGFloat {
        let menuLeftWidth = max(140, frontmostMenuWidth ?? 340)
        let appMenuRightX = screenMinX + menuLeftWidth
        if let auxMinX = auxiliaryTopRightMinX, let auxMaxX = auxiliaryTopRightMaxX, auxMaxX > auxMinX {
            let obstacleX = max(auxMinX, appMenuRightX)
            return max(0, auxMaxX - obstacleX)
        }
        return max(0, screenMaxX - appMenuRightX)
    }
}

/// One `.visible` third-party application competing for top-bar space.
struct SpatialCandidate: Equatable {
    let bundleID: String
    /// Measured total horizontal width of this app's status item(s) on the bar (fallback ~30pt).
    let estimatedWidth: CGFloat
    /// User-pinned exemption: never demoted by Spatial Budget.
    let isExempt: Bool
    /// Explicitly assigned to `.visible` by the user rather than inheriting `unclassifiedSection`.
    let isExplicitlyVisible: Bool
    /// Monotonic/epoch timestamp of the user's most recent interaction via BarLens (`0` if untouched).
    let lastInteractedAt: TimeInterval
    /// Last observed `frame.minX` on the menu bar (`nil` if never measured on this display).
    /// Larger `minX` means closer to the right edge (Control Center/Clock); smaller means closer to Notch/menus.
    let menuBarMinX: CGFloat?
}

struct SpatialBudgetEvaluation: Equatable {
    let demotedBundleIDs: Set<String>
    let reasonsByBundleID: [String: SpatialDemotionReason]
    let usedWidth: CGFloat
    let availableWidth: CGFloat?

    static let none = SpatialBudgetEvaluation(
        demotedBundleIDs: [],
        reasonsByBundleID: [:],
        usedWidth: 0,
        availableWidth: nil
    )
}

/// Pure, hysteresis-stabilized solver that prevents menu bar status items from colliding
/// with a physical camera Notch or frontmost application menus without oscillating across scans.
enum SpatialBudgetPlanner {
    /// Minimum horizontal clearance kept between the leftmost visible status item and the Notch / app menu.
    static let safetyMargin: CGFloat = 18
    /// Extra clearance required before restoring a previously demoted item back to the top bar,
    /// guaranteeing zero flicker between consecutive AX scans.
    static let restoreHysteresis: CGFloat = 20
    /// Conservative width assumed for a status-bar app before its first visible frame measurement.
    static let defaultItemWidth: CGFloat = 30

    static func evaluate(policy: SpatialBudgetPolicy,
                         candidates: [SpatialCandidate],
                         fixedOverheadWidth: CGFloat,
                         availableRightWidth: CGFloat?,
                         previouslyDemoted: Set<String>) -> SpatialBudgetEvaluation {
        guard policy != .off, !candidates.isEmpty else {
            return SpatialBudgetEvaluation(
                demotedBundleIDs: [],
                reasonsByBundleID: [:],
                usedWidth: fixedOverheadWidth,
                availableWidth: availableRightWidth
            )
        }

        // Order from HIGHEST keep-priority (stay on top bar) to LOWEST keep-priority (tuck into Lens first).
        let prioritized = candidates.sorted { lhs, rhs in
            if lhs.isExempt != rhs.isExempt {
                return lhs.isExempt && !rhs.isExempt
            }
            let lhsTouched = lhs.lastInteractedAt > 0
            let rhsTouched = rhs.lastInteractedAt > 0
            if lhsTouched != rhsTouched {
                return lhsTouched && !rhsTouched
            }
            if lhsTouched && rhsTouched && abs(lhs.lastInteractedAt - rhs.lastInteractedAt) > 1.0 {
                return lhs.lastInteractedAt > rhs.lastInteractedAt
            }
            if lhs.isExplicitlyVisible != rhs.isExplicitlyVisible {
                return lhs.isExplicitlyVisible && !rhs.isExplicitlyVisible
            }
            if let lx = lhs.menuBarMinX, let rx = rhs.menuBarMinX, abs(lx - rx) > 1.0 {
                // Rightmost items stay; leftmost edge items closest to Notch tuck first.
                return lx > rx
            }
            if (lhs.menuBarMinX != nil) != (rhs.menuBarMinX != nil) {
                return lhs.menuBarMinX != nil
            }
            return lhs.bundleID < rhs.bundleID
        }

        var usedWidth = max(0, fixedOverheadWidth)
        var keptSlots = 0
        var demoted: Set<String> = []
        var reasons: [String: SpatialDemotionReason] = [:]

        for candidate in prioritized {
            let itemWidth = max(14, candidate.estimatedWidth)
            if candidate.isExempt {
                usedWidth += itemWidth
                keptSlots += 1
                continue
            }

            if let maxSlots = policy.maxVisibleAppSlots, keptSlots >= maxSlots {
                demoted.insert(candidate.bundleID)
                reasons[candidate.bundleID] = .slotCap
                continue
            }

            if let budget = availableRightWidth {
                let extraClearance = previouslyDemoted.contains(candidate.bundleID)
                    ? (safetyMargin + restoreHysteresis)
                    : safetyMargin
                if usedWidth + itemWidth + extraClearance > budget {
                    demoted.insert(candidate.bundleID)
                    reasons[candidate.bundleID] = .physicalSpace
                    continue
                }
            }

            usedWidth += itemWidth
            keptSlots += 1
        }

        return SpatialBudgetEvaluation(
            demotedBundleIDs: demoted,
            reasonsByBundleID: reasons,
            usedWidth: usedWidth,
            availableWidth: availableRightWidth
        )
    }
}
