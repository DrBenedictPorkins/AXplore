import Foundation

public struct AXSummaryAnalyzer {

    public let nodes: [AXElementSnapshot]

    public init(nodes: [AXElementSnapshot]) { self.nodes = nodes }

    // Roles that map to standard, well-known macOS controls
    private static let standardRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
        "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem",
        "AXTabGroup", "AXTab",
        "AXTable", "AXRow", "AXColumn",
        "AXOutline",
        "AXList",
        "AXSlider",
        "AXPopUpButton", "AXComboBox",
        "AXSplitGroup", "AXSplitter",
        "AXToolbar",
        "AXScrollArea", "AXScrollBar",
        "AXStaticText",
        "AXLink",
        "AXImage",
        "AXProgressIndicator",
        "AXColorWell",
        "AXStepper",
        "AXDisclosureTriangle",
    ]

    public func analyze() -> AXAnalysis {
        var roleCounts:    [String: Int] = [:]
        var actionCounts:  [String: Int] = [:]
        var standardCtrl:  [String: Int] = [:]
        var withLabels    = 0
        var withoutLabels = 0
        var withActions   = 0
        var unlabeledLarge = 0
        var windowCount   = 0

        for node in nodes {
            let role = node.role ?? "AXUnknown"
            roleCounts[role, default: 0] += 1

            if ["AXWindow", "AXSheet", "AXDrawer", "AXFloatingWindow"].contains(role) {
                windowCount += 1
            }

            let hasLabel = node.title != nil || node.elementDescription != nil
            if hasLabel { withLabels += 1 } else { withoutLabels += 1 }

            if !node.actions.isEmpty {
                withActions += 1
                for action in node.actions {
                    actionCounts[action, default: 0] += 1
                }
            }

            if node.notes.contains("large-unnamed-container") {
                unlabeledLarge += 1
            }

            if Self.standardRoles.contains(role) {
                standardCtrl[role, default: 0] += 1
            }
        }

        // Opaque-region heuristics
        var opaqueNotes: [String] = []

        let unlabeledGroups = nodes.filter {
            $0.role == "AXGroup" && $0.title == nil && $0.elementDescription == nil
        }.count
        let totalGroups = roleCounts["AXGroup"] ?? 0
        if totalGroups > 10, unlabeledGroups > totalGroups / 2 {
            opaqueNotes.append(
                "\(unlabeledGroups)/\(totalGroups) AXGroup elements are unlabeled — likely custom-rendered regions (e.g. timeline, canvas)."
            )
        }

        if unlabeledLarge > 3 {
            opaqueNotes.append(
                "\(unlabeledLarge) large unnamed containers (>400x150 px) found — these areas may not be keyboard-navigable."
            )
        }

        let unknownCount = (roleCounts["AXUnknown"] ?? 0) + nodes.filter { $0.role == nil }.count
        if unknownCount > 0 {
            opaqueNotes.append(
                "\(unknownCount) elements with no/unknown role — likely non-accessible custom views."
            )
        }

        // Feasibility notes
        var feasibility: [FeasibilityNote] = []

        let menuBarCount = (roleCounts["AXMenuBar"] ?? 0) + (roleCounts["AXMenuBarItem"] ?? 0) + (roleCounts["AXMenuItem"] ?? 0)
        if menuBarCount > 0 {
            feasibility.append(FeasibilityNote(
                area: "Menu bar",
                observation: "\(menuBarCount) menu-related elements accessible",
                verdict: "accessible"
            ))
        }

        if let btnCount = standardCtrl["AXButton"], btnCount > 0 {
            feasibility.append(FeasibilityNote(
                area: "Buttons",
                observation: "\(btnCount) AXButton elements found",
                verdict: "accessible"
            ))
        }

        if let tfCount = standardCtrl["AXTextField"], tfCount > 0 {
            feasibility.append(FeasibilityNote(
                area: "Text fields",
                observation: "\(tfCount) AXTextField elements exposed",
                verdict: "accessible"
            ))
        }

        if let tbCount = standardCtrl["AXToolbar"], tbCount > 0 {
            feasibility.append(FeasibilityNote(
                area: "Toolbar",
                observation: "\(tbCount) toolbar element(s) found",
                verdict: "likely-accessible"
            ))
        }

        if let tableCount = standardCtrl["AXTable"], tableCount > 0 {
            feasibility.append(FeasibilityNote(
                area: "Tables / lists",
                observation: "\(tableCount) table(s) found — rows may be selectable",
                verdict: "likely-accessible"
            ))
        }

        if !opaqueNotes.isEmpty {
            feasibility.append(FeasibilityNote(
                area: "Custom / opaque regions",
                observation: opaqueNotes.joined(separator: " "),
                verdict: "opaque"
            ))
        }

        if actionCounts["AXPress"] ?? 0 > 0 {
            feasibility.append(FeasibilityNote(
                area: "Pressable elements",
                observation: "\(actionCounts["AXPress"]!) elements expose AXPress",
                verdict: "accessible"
            ))
        }

        let roleHistogram = roleCounts
            .sorted { $0.value > $1.value }
            .map { RoleCount(role: $0.key, count: $0.value) }

        return AXAnalysis(
            totalNodes:            nodes.count,
            windowCount:           windowCount,
            roleHistogram:         roleHistogram,
            elementsWithLabels:    withLabels,
            elementsWithoutLabels: withoutLabels,
            elementsWithActions:   withActions,
            unlabeledLargeElements: unlabeledLarge,
            standardControls:      standardCtrl,
            opaqueRegionNotes:     opaqueNotes,
            feasibilityNotes:      feasibility,
            commonActions:         actionCounts
        )
    }
}

// MARK: - Console printer

public extension AXAnalysis {
    func printConsole() {
        print("\n=== AX Analysis Summary ===")
        print("Total nodes    : \(totalNodes)")
        print("Windows        : \(windowCount)")
        print("With labels    : \(elementsWithLabels) / \(totalNodes)")
        print("Expose actions : \(elementsWithActions)")

        print("\nTop 12 roles:")
        for rc in roleHistogram.prefix(12) {
            print("  \(rc.role.padding(toLength: 30, withPad: " ", startingAt: 0)) \(rc.count)")
        }

        if !standardControls.isEmpty {
            print("\nStandard controls:")
            for (role, count) in standardControls.sorted(by: { $0.key < $1.key }) {
                print("  \(role.padding(toLength: 30, withPad: " ", startingAt: 0)) \(count)")
            }
        }

        if !commonActions.isEmpty {
            print("\nActions exposed (across all elements):")
            for (action, count) in commonActions.sorted(by: { $0.value > $1.value }) {
                print("  \(action.padding(toLength: 30, withPad: " ", startingAt: 0)) \(count)")
            }
        }

        if !opaqueRegionNotes.isEmpty {
            print("\nOpaque / custom regions detected:")
            for note in opaqueRegionNotes { print("  - \(note)") }
        }

        print("\n=== Automation Feasibility ===")
        for fn in feasibilityNotes {
            let marker: String
            switch fn.verdict {
            case "accessible":        marker = "[YES   ]"
            case "likely-accessible": marker = "[LIKELY]"
            case "opaque":            marker = "[OPAQUE]"
            default:                  marker = "[?     ]"
            }
            print("\(marker) \(fn.area): \(fn.observation)")
        }
    }
}
