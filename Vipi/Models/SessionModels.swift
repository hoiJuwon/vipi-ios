import Foundation
import SwiftUI

enum AgentProvider: String, Codable, CaseIterable, Sendable {
    case pi, codex

    var displayName: String {
        switch self {
        case .pi: "Vipi"
        case .codex: "Codex"
        }
    }
}

enum SessionPhase: String, Codable, CaseIterable, Sendable {
    case idle, working, waitingForInput, completed, failed, offline

    var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .waitingForInput: "Needs input"
        case .completed: "Completed"
        case .failed: "Failed"
        case .offline: "Offline"
        }
    }

    var color: Color {
        switch self {
        case .working: VipiTheme.accent
        case .waitingForInput: VipiTheme.warning
        case .completed: VipiTheme.success
        case .failed: VipiTheme.danger
        case .idle: VipiTheme.cyan
        case .offline: VipiTheme.secondary
        }
    }
}

struct TmuxCoordinates: Codable, Hashable, Sendable {
    var session: String
    var window: String
    var paneID: String
}

struct RemoteSession: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var provider: AgentProvider? = nil
    var name: String
    var cwd: String
    var phase: SessionPhase
    var unread: Bool
    var lastActivityAt: Date
    var lastMessagePreview: String? = nil
    var model: String
    var thinkingLevel: String
    var branch: String?
    var contextPercent: Int
    var tmux: TmuxCoordinates
    var sessionFile: String?

    var agentProvider: AgentProvider { provider ?? .pi }

    var workspaceName: String {
        URL(fileURLWithPath: cwd).lastPathComponent.isEmpty ? cwd : URL(fileURLWithPath: cwd).lastPathComponent
    }
}

struct WorkspaceGroup: Identifiable, Hashable {
    var id: String { path }
    let path: String
    var sessions: [RemoteSession]
}

struct WorkspaceDirectoryListing: Equatable, Sendable {
    let path: String
    let parent: String?
    let directories: [String]
}

enum SessionCreationRequest: Equatable {
    case workspaces
    case browse
    case create(path: String, provider: AgentProvider)
}
