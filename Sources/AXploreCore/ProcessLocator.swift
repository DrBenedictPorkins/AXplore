import AppKit
import ApplicationServices
import Foundation

public struct ProcessLocator {
    public init() {}

    public func findByName(_ name: String) -> [AppProcess] {
        NSWorkspace.shared.runningApplications
            .filter {
                $0.localizedName?.localizedCaseInsensitiveContains(name) == true ||
                $0.bundleIdentifier?.localizedCaseInsensitiveContains(name) == true
            }
            .map { AppProcess(from: $0) }
    }

    public func findByBundleID(_ bundleID: String) -> [AppProcess] {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleID }
            .map { AppProcess(from: $0) }
    }

    public func findByPID(_ pid: Int32) -> [AppProcess] {
        NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier == pid }
            .map { AppProcess(from: $0) }
    }

    public static func printAllRunningApps() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        print("Running applications (\(apps.count)):")
        for app in apps {
            let name = app.localizedName ?? "?"
            let bundle = app.bundleIdentifier ?? "(no bundle id)"
            print("  \(name) | PID \(app.processIdentifier) | \(bundle)")
        }
    }
}

public extension AppProcess {
    init(from app: NSRunningApplication) {
        self.name = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        self.pid  = app.processIdentifier
        self.bundleIdentifier = app.bundleIdentifier
        self.bundlePath = app.bundleURL?.path

        // Quick accessibility probe — if we can read attribute names the process is AX-addressable
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var names: CFArray?
        let err = AXUIElementCopyAttributeNames(axApp, &names)
        self.isAccessible = (err == .success)
    }

    func printSummary() {
        print("  Name        : \(name)")
        print("  PID         : \(pid)")
        print("  Bundle ID   : \(bundleIdentifier ?? "N/A")")
        print("  Path        : \(bundlePath ?? "N/A")")
        print("  AX-accessible: \(isAccessible)")
    }
}
