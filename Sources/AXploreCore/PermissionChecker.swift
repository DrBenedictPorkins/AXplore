import ApplicationServices

public enum PermissionChecker {
    /// Check whether this process has been granted Accessibility access.
    /// We check without prompting — the caller decides whether to tell the user.
    public static func check() -> PermissionResult {
        let trusted = AXIsProcessTrusted()
        return PermissionResult(
            isGranted: trusted,
            message: trusted
                ? "Accessibility access granted."
                : "Accessibility access not granted. Add this terminal/binary in System Settings > Privacy & Security > Accessibility."
        )
    }
}
