/// A service that reports more about its state for `preowned inventory`,
/// such as the locales or voices that it has on this Mac.
public protocol InventoryReporting: Sendable {
    /// Lines that describe the service's state, without indentation.
    func inventoryDetails() async -> [String]
}

extension ServiceRegistry {
    /// The inventory details of a capability's service, if it reports any.
    public func inventoryDetails(of capability: Capability) async -> [String] {
        let service: (any Sendable)? =
            switch capability {
            case .chat: chat
            case .images: images
            case .embeddings: embeddings
            case .transcription: transcription
            case .speech: speech
            }
        guard let reporting = service as? any InventoryReporting else {
            return []
        }
        return await reporting.inventoryDetails()
    }
}
