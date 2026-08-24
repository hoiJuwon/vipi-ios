import Foundation

enum ChatRole: String, Codable, Sendable { case user, assistant, system }

enum ToolState: String, Codable, Sendable { case running, succeeded, failed }

struct ToolActivity: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var summary: String
    var detail: String?
    var state: ToolState
    var changedFiles: Int?
}

struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var role: ChatRole
    var text: String
    var timestamp: Date
    var isStreaming: Bool = false
    var tools: [ToolActivity] = []
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
