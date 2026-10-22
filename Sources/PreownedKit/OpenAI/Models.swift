/// A model object from `GET /v1/models`.
public struct ModelObject: Codable, Sendable, Equatable {
    public var id: String
    public var object: String
    public var created: Int
    public var ownedBy: String

    public init(id: String, created: Int = 0, ownedBy: String = "apple") {
        self.id = id
        self.object = "model"
        self.created = created
        self.ownedBy = ownedBy
    }

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case created
        case ownedBy = "owned_by"
    }
}

/// The list from `GET /v1/models`.
public struct ModelList: Codable, Sendable, Equatable {
    public var object: String
    public var data: [ModelObject]

    public init(data: [ModelObject]) {
        self.object = "list"
        self.data = data
    }
}
