import Foundation
import Testing

@testable import PreownedKit

@Suite("Image Playground window service")
struct ImagePlaygroundWindowServiceTests {
    @Test("Cancel and timeout errors use OpenAI's shapes")
    func errors() {
        #expect(OpenAIError.imageCancelled.status == .badRequest)
        #expect(OpenAIError.imageCancelled.type == "invalid_request_error")
        #expect(OpenAIError.imageCancelled.code == "image_generation_cancelled")
        let timeout = OpenAIError.imageTimedOut(after: .seconds(30))
        #expect(timeout.status == .gatewayTimeout)
        #expect(timeout.type == "server_error")
        #expect(timeout.code == "timeout")
        #expect(timeout.message.contains("30 seconds"))
    }

    @Test("The service offers the on-device styles")
    func styles() {
        let service = ImagePlaygroundWindowService(approval: .person)
        #expect(service.availableStyles.contains("illustration"))
        #expect(!service.availableStyles.contains(ImagePlaygroundSupport.externalProviderID))
    }

    @Test("Auto-approve is unavailable without the Accessibility permission")
    func accessibility() {
        let automatic = ImagePlaygroundWindowService(approval: .accessibility)
        let person = ImagePlaygroundWindowService(approval: .person)
        if AccessibilityApprover.isTrusted || !person.availability.isAvailable {
            #expect(automatic.availability == person.availability)
        } else {
            #expect(automatic.availability == .unavailable(reason: AccessibilityApprover.untrustedReason))
        }
    }
}
