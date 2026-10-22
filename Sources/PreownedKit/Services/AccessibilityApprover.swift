import ApplicationServices
import Foundation

/// Presses the accept button in an Image Playground window
/// through the Accessibility API.
///
/// This is a hack.
/// It looks through the window's Accessibility tree,
/// which includes the extension's remote view,
/// for an enabled button with an English accept label, such as "Done",
/// and performs its press action.
/// The labels and the tree come from Apple's private UI,
/// so any macOS update can break it.
/// It needs the Accessibility permission
/// for the process that starts `preowned`, such as Terminal.
public struct AccessibilityApprover: Sendable {
    /// Button labels that accept the image, in order of preference.
    public static let acceptLabels = ["Done"]

    /// How often to look for the button.
    static let pollInterval = Duration.seconds(1)
    /// How long to wait for the delegate after a press before pressing again.
    static let pressInterval = Duration.seconds(5)

    /// Whether this process has the Accessibility permission.
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks macOS to show the Accessibility permission prompt if the process lacks it,
    /// and returns whether the process has it now.
    @discardableResult
    public static func requestTrust() -> Bool {
        // The value of `kAXTrustedCheckOptionPrompt`,
        // which Swift 6 treats as shared mutable state.
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The reason that auto-approve mode is unavailable without the permission.
    public static let untrustedReason =
        "--images=auto-approve needs the Accessibility permission. "
        + "Add the app that runs preowned, such as Terminal, in System Settings > "
        + "Privacy & Security > Accessibility, or use --images=interactive."

    let windowTitle: String
    let processIdentifier: pid_t
    let isDebugging: Bool

    init(
        windowTitle: String,
        processIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        isDebugging: Bool = ProcessInfo.processInfo.environment["PREOWNED_AX_DEBUG"] == "1"
    ) {
        self.windowTitle = windowTitle
        self.processIdentifier = processIdentifier
        self.isDebugging = isDebugging
    }

    /// Looks for the accept button once, off the main thread, and presses it if it is enabled.
    ///
    /// The search runs on another thread
    /// because Accessibility requests to this process are answered on the main thread.
    ///
    /// - Returns: Whether the approver pressed a button.
    func attempt() async -> Bool {
        let approver = self
        return await Task.detached { approver.pressAcceptButton() }.value
    }

    private func pressAcceptButton() -> Bool {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 2)
        let windows: [AXUIElement] = attribute(application, kAXWindowsAttribute) ?? []
        for window in windows where attribute(window, kAXTitleAttribute) as String? == windowTitle {
            var candidates: [(label: String, element: AXUIElement)] = []
            var queue = [window]
            var visited = 0
            while !queue.isEmpty, visited < 5000 {
                let element = queue.removeFirst()
                visited += 1
                if attribute(element, kAXRoleAttribute) as String? == kAXButtonRole as String {
                    let labels = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap {
                        attribute(element, $0) as String?
                    }
                    let isEnabled = attribute(element, kAXEnabledAttribute) as Bool? ?? false
                    if isDebugging {
                        log("button labels=\(labels) enabled=\(isEnabled)")
                    }
                    if isEnabled, let label = labels.first(where: Self.acceptLabels.contains) {
                        candidates.append((label, element))
                    }
                }
                queue += attribute(element, kAXChildrenAttribute) as [AXUIElement]? ?? []
            }
            let ranked = candidates.sorted {
                Self.acceptLabels.firstIndex(of: $0.label)! < Self.acceptLabels.firstIndex(of: $1.label)!
            }
            if let button = ranked.first {
                let error = AXUIElementPerformAction(button.element, kAXPressAction as CFString)
                log("pressed \"\(button.label)\" result=\(error.rawValue)")
                return error == .success
            }
            if isDebugging {
                log("no enabled accept button among \(visited) elements")
            }
        }
        return false
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("preowned auto-approve: \(message)\n".utf8))
    }
}
