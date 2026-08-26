import CryptoKit
import Foundation

enum ChatRole: String, Codable, Sendable { case user, assistant, system }

enum RemoteInteractionKind: String, Codable, Sendable {
    case confirm, select, input
}

struct RemoteInteraction: Identifiable, Codable, Hashable, Sendable {
    let requestID: String
    let sessionID: String
    let kind: RemoteInteractionKind
    let title: String
    let message: String?
    let options: [String]?
    let placeholder: String?

    var id: String { requestID }
}

struct ChatAnnotation: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let messageID: String
    let text: String

    init(id: String = UUID().uuidString, messageID: String, text: String) {
        self.id = id
        self.messageID = messageID
        self.text = text
    }
}

enum ProgressActivity: String, Codable, Sendable {
    case thinking, reading, editing, running, searching

    var title: String {
        switch self {
        case .thinking: "Thinking"
        case .reading: "Reading"
        case .editing: "Editing"
        case .running: "Running"
        case .searching: "Searching"
        }
    }
}

struct ChatImageAttachment: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let mimeType: String
}

struct DraftImageAttachment: Identifiable, Hashable, Sendable {
    let id: String
    let mimeType: String
    let data: Data

    init(data: Data, mimeType: String = "image/jpeg") {
        self.data = data
        self.mimeType = mimeType
        id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var chatAttachment: ChatImageAttachment { ChatImageAttachment(id: id, mimeType: mimeType) }
}

enum ChatImageCache {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appending(path: "Vipi/Attachments", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
        return directory
    }()

    static func store(_ attachment: DraftImageAttachment) throws {
        try attachment.data.write(
            to: fileURL(for: attachment.chatAttachment),
            options: [.atomic, .completeFileProtection]
        )
    }

    static func data(for attachment: ChatImageAttachment) -> Data? {
        try? Data(contentsOf: fileURL(for: attachment), options: .mappedIfSafe)
    }

    private static func fileURL(for attachment: ChatImageAttachment) -> URL {
        directory.appending(path: attachment.id).appendingPathExtension("jpg")
    }
}

struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var role: ChatRole
    var text: String
    var timestamp: Date
    var isStreaming: Bool = false
    var attachments: [ChatImageAttachment] = []
}

struct BranchNode: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var subtitle: String?
    var isActive: Bool
    var depth: Int
}

enum PromptDelivery: String, Codable, Sendable {
    case prompt, steer, followUp
}

struct QueuedPrompt: Identifiable, Hashable, Sendable {
    let id: String
    let text: String
}
