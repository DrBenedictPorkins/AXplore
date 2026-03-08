import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Captures screenshots of an application's on-screen windows.
///
/// Requires Screen Recording permission (System Settings > Privacy & Security > Screen Recording).
/// On macOS 14+ CGWindowListCreateImage is deprecated but still functional with the permission.
/// If permission is absent the images will be blank/black — we save them anyway so the
/// output set is complete and the issue is obvious on inspection.
public enum ScreenshotCapture {

    public static func captureWindows(for pid: pid_t, outputDir: String) -> (paths: [String], diagnostic: String) {
        let screenshotsDir = (outputDir as NSString).appendingPathComponent("screenshots")
        try? FileManager.default.createDirectory(atPath: screenshotsDir,
                                                  withIntermediateDirectories: true)

        guard let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID) as? [[String: Any]] else {
            return ([], "CGWindowListCopyWindowInfo returned nil — Screen Recording permission may not be granted for axmcp.")
        }

        let appWindows = windowList.filter { info in
            (info[kCGWindowOwnerPID as String] as? Int32) == pid
        }

        if appWindows.isEmpty {
            let allPIDs = windowList.compactMap { $0[kCGWindowOwnerPID as String] as? Int32 }
            let appIsVisible = allPIDs.contains(pid)
            let reason = appIsVisible
                ? "App (PID \(pid)) has windows in the list but none passed the on-screen filter — the window may be minimized or off-screen."
                : "No windows found for PID \(pid) — the app may not have any visible windows."
            return ([], reason)
        }

        var paths: [String] = []
        var lastFailReason = ""

        for (index, info) in appWindows.enumerated() {
            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID else { continue }

            // Resolve the window's on-screen rect so we capture only that window.
            // CGRect.null is unreliable on multi-monitor setups and can return the full desktop.
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let windowRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            guard var cgImage = CGWindowListCreateImage(
                    windowRect,
                    .optionIncludingWindow,
                    windowID,
                    .nominalResolution) else {
                lastFailReason = "CGWindowListCreateImage returned nil for window \(windowID) (\(Int(windowRect.width))x\(Int(windowRect.height))). The app may be using a protected/DRM surface."
                continue
            }

            // Scale down to max 1440px wide so the image is reasonable over MCP
            cgImage = scaled(cgImage, maxWidth: 1440)

            let rawName = info[kCGWindowName as String] as? String ?? "window"
            let safeName = rawName
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "-")
                .prefix(50)

            let filename = "\(index)_\(safeName).png"
            let path = (screenshotsDir as NSString).appendingPathComponent(filename)

            if savePNG(cgImage, to: path) {
                paths.append(path)
            }
        }

        if paths.isEmpty && !lastFailReason.isEmpty {
            return ([], lastFailReason)
        }
        return (paths, "")
    }

    // MARK: - Private

    private static func scaled(_ image: CGImage, maxWidth: Int) -> CGImage {
        guard image.width > maxWidth else { return image }
        let scale  = CGFloat(maxWidth) / CGFloat(image.width)
        let width  = maxWidth
        let height = Int(CGFloat(image.height) * scale)
        guard let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    private static func savePNG(_ image: CGImage, to path: String) -> Bool {
        let url  = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
