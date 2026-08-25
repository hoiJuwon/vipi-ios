import Foundation

enum ChatRole: String, Codable, Sendable { case user, assistant, system }

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

struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var role: ChatRole
    var text: String
    var timestamp: Date
    var isStreaming: Bool = false
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
