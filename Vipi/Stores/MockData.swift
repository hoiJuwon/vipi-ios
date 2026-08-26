import Foundation

enum MockData {
    static let markdownTablePreview = """
    | 판타지 군 | 예시 관계·상황 | 수량 |
    |---|---|---:|
    | 가까운 사람 | best friend, neighbor, friend’s sibling | 10 |
    | 적대적 긴장 | rival, enemy, adult bully, competing coworker | 10 |
    | 권력·지위 | boss, billionaire, heir, royalty | 10 |
    """

    static let sessions: [RemoteSession] = [
        .init(id: "mobile", name: "개발 / 모바일 세션 앱", cwd: "/Users/choijuwon/vipi-ios", phase: .working, unread: false, lastActivityAt: .now, model: "GPT-5.6", thinkingLevel: "Medium", branch: "main", contextPercent: 28, tmux: .init(session: "base", window: "3", paneID: "%101"), sessionFile: nil),
        .init(id: "ui", name: "UI / 선택 강조 개선", cwd: "/Users/choijuwon", phase: .completed, unread: true, lastActivityAt: .now.addingTimeInterval(-180), model: "GPT-5.6", thinkingLevel: "Medium", branch: nil, contextPercent: 63, tmux: .init(session: "base", window: "1", paneID: "%28"), sessionFile: nil),
        .init(id: "hello", name: "개발 / Pi 설정 패키지화", cwd: "/Users/choijuwon", phase: .idle, unread: false, lastActivityAt: .now.addingTimeInterval(-720), model: "GPT-5.6", thinkingLevel: "Medium", branch: nil, contextPercent: 41, tmux: .init(session: "base", window: "2", paneID: "%55"), sessionFile: nil),
        .init(id: "drama", name: "개발 / 채팅 API 안정화", cwd: "/Users/choijuwon/Desktop/development/works/if-drama-chat", phase: .waitingForInput, unread: true, lastActivityAt: .now.addingTimeInterval(-1250), model: "GPT-5.4", thinkingLevel: "High", branch: "fix/socket-retry", contextPercent: 76, tmux: .init(session: "if-dev", window: "1", paneID: "%9"), sessionFile: nil)
    ]

    static let messages: [String: [ChatMessage]] = [
        "mobile": [
            .init(id: "m0u", role: .user, text: "모바일 앱의 기본 방향을 정리해줘.", timestamp: .now.addingTimeInterval(-700)),
            .init(id: "m0a", role: .assistant, text: "터미널 세부 정보는 숨기고 일반적인 채팅 흐름에 집중하겠습니다.", timestamp: .now.addingTimeInterval(-650)),
            .init(id: "m1", role: .user, text: "모바일에서는 Vim UX 없이 좋은 채팅앱처럼 만들고 싶어. tmux 세션을 그대로 연결해줘.", timestamp: .now.addingTimeInterval(-520)),
            .init(id: "m2", role: .assistant, text: "## 작업 흐름\n\n모바일은 tmux를 노출하지 않고 다음 흐름에 집중합니다.\n\n- **세션 목록**에서 작업 선택\n- 채팅에서 요청 전송\n- `Thinking` 상태로 진행 확인\n\n> 호스트가 Pi 프로세스 생명주기를 유지하고 앱은 Tailscale로 세션 이벤트만 받습니다.", timestamp: .now.addingTimeInterval(-470)),
            .init(id: "m3", role: .user, text: "앱의 초안을 실제로 만들어줘.", timestamp: .now.addingTimeInterval(-210)),
            .init(id: "m4", role: .assistant, text: "현재 앱 셸과 연결 프로토콜을 구성하고 있습니다.", timestamp: .now.addingTimeInterval(-170), isStreaming: true)
        ],
        "ui": [
            .init(id: "u1", role: .user, text: "선택된 세션이 더 분명하게 보이도록 해줘.", timestamp: .now.addingTimeInterval(-900)),
            .init(id: "u2", role: .assistant, text: "선택 상태의 배경과 상태 아이콘 대비를 높였습니다. 작은 화면에서도 현재 세션을 빠르게 구분할 수 있습니다.", timestamp: .now.addingTimeInterval(-820))
        ]
    ]

    static let branches: [String: [BranchNode]] = [
        "mobile": [
            .init(id: "b1", title: "모바일 접근 방식 조사", subtitle: "기존 Pi remote 프로젝트 비교", isActive: false, depth: 0),
            .init(id: "b2", title: "SwiftUI 네이티브 앱", subtitle: "현재 대화", isActive: true, depth: 1),
            .init(id: "b3", title: "PWA 대안 검토", subtitle: "보관된 분기", isActive: false, depth: 1)
        ]
    ]

    static let activity: [ActivityItem] = [
        .init(id: "a1", sessionName: "개발 / 모바일 세션 앱", title: "write", detail: "Vipi SwiftUI 앱 파일 생성", status: .working, date: .now),
        .init(id: "a2", sessionName: "UI / 선택 강조 개선", title: "완료", detail: "도구 6개 실행 · 파일 3개 변경", status: .completed, date: .now.addingTimeInterval(-180)),
        .init(id: "a3", sessionName: "개발 / 채팅 API 안정화", title: "응답 필요", detail: "재시도 정책을 선택해주세요", status: .waitingForInput, date: .now.addingTimeInterval(-1250))
    ]
}

struct ActivityItem: Identifiable, Hashable {
    var id: String
    var sessionName: String
    var title: String
    var detail: String
    var status: SessionPhase
    var date: Date
}
