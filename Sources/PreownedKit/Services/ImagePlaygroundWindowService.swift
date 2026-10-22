import AppKit
import Foundation
import Hummingbird
import ImagePlayground

/// Creates images in an Image Playground window
/// that a person, or Accessibility automation, accepts.
///
/// `ImagePlaygroundViewController` runs its UI in an app extension
/// and returns an image only after someone accepts it,
/// so each image opens a window and waits for the delegate.
/// The process must run an `NSApplication` main loop;
/// `preowned serve` starts one in the window modes.
///
/// A request for `n` images opens `n` windows, one after another.
/// Cancel and timeout give OpenAI-format errors.
public final class ImagePlaygroundWindowService: ImageService {
    /// Who accepts the image in the window.
    public enum Approval: Sendable, Equatable {
        /// A person at the Mac clicks the accept button.
        case person
        /// Accessibility automation presses the accept button.
        /// See ``AccessibilityApprover``.
        case accessibility
    }

    public let approval: Approval
    /// How long to wait for each image before the request fails.
    public let timeout: Duration
    private let isPlaygroundAvailable: Bool

    public init(approval: Approval, timeout: Duration = .seconds(120)) {
        self.approval = approval
        self.timeout = timeout
        self.isPlaygroundAvailable = ImagePlaygroundViewController.isAvailable
    }

    public var availability: ServiceAvailability {
        guard isPlaygroundAvailable else {
            return .unavailable(
                reason: "Image Playground is not available on this Mac. Check that Apple Intelligence is on."
            )
        }
        if approval == .accessibility, !AccessibilityApprover.isTrusted {
            return .unavailable(reason: AccessibilityApprover.untrustedReason)
        }
        return .available
    }

    public var availableStyles: [String] {
        ImagePlaygroundSupport.styleNames(ImagePlaygroundStyle.all)
    }

    public func generateImages(_ request: ImageGenerationRequest) async throws -> [GeneratedImage] {
        var images: [GeneratedImage] = []
        for _ in 0..<request.count {
            let url = try await ImagePlaygroundWindow.run(request, approval: approval, timeout: timeout)
            images.append(GeneratedImage(pngData: try ImagePlaygroundSupport.pngData(fromFile: url)))
        }
        return images
    }
}

extension OpenAIError {
    /// A 400 error for an image that the person at the Mac cancelled.
    static let imageCancelled = OpenAIError.invalidRequest(
        "The image was cancelled in the Image Playground window.",
        code: "image_generation_cancelled"
    )

    /// A 504 error for an image that nobody accepted in time.
    static func imageTimedOut(after timeout: Duration) -> OpenAIError {
        OpenAIError(
            status: .gatewayTimeout,
            message:
                "Nobody accepted an image in the Image Playground window within \(timeout.components.seconds) seconds.",
            type: "server_error",
            code: "timeout"
        )
    }
}

/// One Image Playground window, from opening to the delegate's answer.
@MainActor
final class ImagePlaygroundWindow: NSObject, ImagePlaygroundViewController.Delegate, NSWindowDelegate {
    /// The title of every window, which Accessibility automation looks for.
    static let title = "preowned: Image Playground"

    /// How long to wait for the extension's remote view to appear.
    static let connectionTimeout = Duration.seconds(10)
    /// How long to wait after the remote view appears before sending the concepts again.
    static let conceptDelay = Duration.seconds(2)

    private let request: ImageGenerationRequest
    private let controller = ImagePlaygroundViewController()
    private var window: NSWindow?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var tasks: [Task<Void, Never>] = []

    private init(request: ImageGenerationRequest) {
        self.request = request
    }

    /// Opens a window for a request and returns the URL of the accepted image.
    static func run(
        _ request: ImageGenerationRequest,
        approval: ImagePlaygroundWindowService.Approval,
        timeout: Duration
    ) async throws -> URL {
        let window = ImagePlaygroundWindow(request: request)
        return try await window.run(approval: approval, timeout: timeout)
    }

    private func run(approval: ImagePlaygroundWindowService.Approval, timeout: Duration) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            show()
            tasks.append(
                Task { [weak self] in
                    await self?.sendConceptsAfterConnecting()
                    if approval == .accessibility {
                        await self?.approveAutomatically()
                    }
                }
            )
            tasks.append(
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(OpenAIError.imageTimedOut(after: timeout)))
                }
            )
        }
    }

    private func show() {
        controller.delegate = self
        applyRequest()

        let window = NSWindow(contentViewController: controller)
        window.title = Self.title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Sets the concepts, style, source image, and size on the controller.
    private func applyRequest() {
        var concepts: [ImagePlaygroundConcept] = []
        if !request.prompt.isEmpty {
            concepts.append(ImagePlaygroundSupport.concept(for: request.prompt))
        }
        controller.concepts = concepts
        if let style = ImagePlaygroundSupport.style(named: request.style, in: ImagePlaygroundStyle.all) {
            controller.selectedGenerationStyle = style
        }
        if let data = request.sourceImage, let image = NSImage(data: data) {
            controller.sourceImage = image
        }
        if #available(macOS 27, *), let size = request.size {
            var options = controller.options
            options.sizeSpecification = .closest(to: CGSize(width: size.width, height: size.height))
            controller.options = options
        }
    }

    /// Sends the request again after the extension connects,
    /// because the remote view drops concepts that arrive earlier.
    private func sendConceptsAfterConnecting() async {
        let clock = ContinuousClock()
        let deadline = clock.now + Self.connectionTimeout
        while clock.now < deadline, !Task.isCancelled, !Self.containsRemoteView(controller.view) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: Self.conceptDelay)
        guard !Task.isCancelled, continuation != nil else { return }
        applyRequest()
    }

    private static func containsRemoteView(_ view: NSView) -> Bool {
        String(describing: type(of: view)).contains("RemoteView") || view.subviews.contains(where: containsRemoteView)
    }

    private func approveAutomatically() async {
        let approver = AccessibilityApprover(windowTitle: Self.title)
        while !Task.isCancelled, continuation != nil {
            let didPress = await approver.attempt()
            try? await Task.sleep(
                for: didPress ? AccessibilityApprover.pressInterval : AccessibilityApprover.pollInterval)
        }
    }

    private func finish(_ result: Result<URL, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        for task in tasks {
            task.cancel()
        }
        tasks = []
        controller.delegate = nil
        if let window {
            window.delegate = nil
            window.close()
        }
        window = nil
        if NSApplication.shared.windows.allSatisfy({ !$0.isVisible }) {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        continuation.resume(with: result)
    }

    // MARK: - ImagePlaygroundViewController.Delegate

    func imagePlaygroundViewController(
        _ imagePlaygroundViewController: ImagePlaygroundViewController,
        didCreateImageAt imageURL: URL
    ) {
        finish(.success(imageURL))
    }

    func imagePlaygroundViewControllerDidCancel(_ imagePlaygroundViewController: ImagePlaygroundViewController) {
        finish(.failure(OpenAIError.imageCancelled))
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        finish(.failure(OpenAIError.imageCancelled))
    }
}
