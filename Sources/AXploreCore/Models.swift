import Foundation
import CoreGraphics

// MARK: - Process Info

public struct AppProcess: Codable {
    public let name: String
    public let pid: Int32
    public let bundleIdentifier: String?
    public let bundlePath: String?
    public let isAccessible: Bool
}

// MARK: - Permission

public struct PermissionResult: Codable {
    public let isGranted: Bool
    public let message: String

    public func printStatus() {
        if isGranted {
            print("[OK] Accessibility permission granted.")
        } else {
            print("[MISSING] Accessibility permission not granted.")
            print("  Grant it: System Settings > Privacy & Security > Accessibility")
        }
    }
}

// MARK: - Traversal Mode

// ExpressibleByArgument conformance is in AXploreCommand.swift (requires ArgumentParser import)
public enum TraversalMode: String, CaseIterable, Codable {
    case app
    case shallow
    case deep
    case focusedWindow = "focused-window"
    case focusedElement = "focused-element"
}

// MARK: - Geometry Snapshots (Codable wrappers for CoreGraphics types)

public struct PointSnap: Codable {
    public let x: Double
    public let y: Double
    public init(_ p: CGPoint) { x = p.x; y = p.y }
}

public struct SizeSnap: Codable {
    public let width: Double
    public let height: Double
    public init(_ s: CGSize) { width = s.width; height = s.height }
}

// MARK: - Element Snapshot

public struct AXElementSnapshot: Codable {
    public let id: Int
    public let depth: Int
    public let role: String?
    public let subrole: String?
    public let title: String?
    public let elementDescription: String?
    public let help: String?
    public let value: String?
    public let placeholderValue: String?
    public let identifier: String?
    public let enabled: Bool?
    public let focused: Bool?
    public let selected: Bool?
    public let position: PointSnap?
    public let size: SizeSnap?
    public let actions: [String]
    public let attributeNames: [String]
    public let childCount: Int           // actual child count from AX (may exceed snapshotted children)
    public let children: [AXElementSnapshot]
    public let notes: [String]           // analysis annotations added during walk
    public let axErrors: [String: String]
}

// MARK: - Focused Context

public struct FocusedContext: Codable {
    public let focusedAppName: String?
    public let focusedWindowTitle: String?
    public let focusedElementRole: String?
    public let focusedElementTitle: String?
    public let focusedElementDescription: String?
}

// MARK: - Analysis

public struct RoleCount: Codable {
    public let role: String
    public let count: Int
}

public struct FeasibilityNote: Codable {
    public let area: String
    public let observation: String
    // "accessible" | "likely-accessible" | "opaque" | "unknown"
    public let verdict: String
}

public struct AXAnalysis: Codable {
    public let totalNodes: Int
    public let windowCount: Int
    public let roleHistogram: [RoleCount]
    public let elementsWithLabels: Int
    public let elementsWithoutLabels: Int
    public let elementsWithActions: Int
    public let unlabeledLargeElements: Int
    public let standardControls: [String: Int]
    public let opaqueRegionNotes: [String]
    public let feasibilityNotes: [FeasibilityNote]
    public let commonActions: [String: Int]
}

// MARK: - Top-level Scan Result

public struct AXScanResult: Codable {
    public let processInfo: AppProcess
    public let permissionStatus: PermissionResult
    public let traversalMode: String
    public let maxDepth: Int
    public let maxNodes: Int
    public let timestamp: String
    public let totalNodeCount: Int
    public let focusedContext: FocusedContext?
    public let analysis: AXAnalysis
    public let screenshotPaths: [String]
    public let searchQuery: String?
    public let searchResults: [AXElementSnapshot]?
    public let roots: [AXElementSnapshot]
}


// MARK: - Factory (memberwise init is internal for Codable structs; use this cross-module)

public extension AXScanResult {
    static func build(
        processInfo: AppProcess,
        permissionStatus: PermissionResult,
        traversalMode: String,
        maxDepth: Int,
        maxNodes: Int,
        timestamp: String,
        totalNodeCount: Int,
        focusedContext: FocusedContext?,
        analysis: AXAnalysis,
        screenshotPaths: [String],
        searchQuery: String?,
        searchResults: [AXElementSnapshot]?,
        roots: [AXElementSnapshot]
    ) -> AXScanResult {
        AXScanResult(
            processInfo:      processInfo,
            permissionStatus: permissionStatus,
            traversalMode:    traversalMode,
            maxDepth:         maxDepth,
            maxNodes:         maxNodes,
            timestamp:        timestamp,
            totalNodeCount:   totalNodeCount,
            focusedContext:   focusedContext,
            analysis:         analysis,
            screenshotPaths:  screenshotPaths,
            searchQuery:      searchQuery,
            searchResults:    searchResults,
            roots:            roots
        )
    }
}
