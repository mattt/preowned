import AppKit
import ArgumentParser
import PreownedKit

/// How `serve` creates images, from `--images`.
enum ImageMode: String, CaseIterable, ExpressibleByArgument {
    /// `ImageCreator` without UI, which works on macOS 26.
    case `default`
    /// An Image Playground window that a person accepts.
    case interactive
    /// An Image Playground window that Accessibility automation accepts.
    case autoApprove = "auto-approve"

    static var allValueStrings: [String] {
        allCases.map(\.rawValue)
    }

    /// Whether the mode shows windows and so needs an `NSApplication` main loop.
    var usesWindow: Bool {
        self != .default
    }

    /// The image service for this mode.
    func makeService(timeout: Duration = .seconds(120)) async -> any ImageService {
        switch self {
        case .default:
            await ImageCreatorService.probe()
        case .interactive:
            ImagePlaygroundWindowService(approval: .person, timeout: timeout)
        case .autoApprove:
            ImagePlaygroundWindowService(approval: .accessibility, timeout: timeout)
        }
    }

    /// A line about the Accessibility permission that auto-approve mode needs.
    static var accessibilityLine: String {
        let status = AccessibilityApprover.isTrusted ? "granted" : "not granted"
        return "Accessibility permission (for --images=auto-approve): \(status)"
    }
}

/// Runs the AppKit main loop that Image Playground windows need.
///
/// The server keeps running on the cooperative thread pool.
/// The main loop must not start inside a main-actor job,
/// because a main-actor job that blocks in `NSApplication.run()`
/// stops every later main-actor job,
/// so the loop starts from a run loop block instead.
enum WindowHost {
    static func startApplication() {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                let application = NSApplication.shared
                // The process has no Dock icon until a window opens.
                application.setActivationPolicy(.accessory)
                application.run()
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
