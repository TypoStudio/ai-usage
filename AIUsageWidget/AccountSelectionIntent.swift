import AIUsageCore
import AppIntents
import WidgetKit

/// small 위젯에서 보여 줄 계정. 프로바이더마다 목록이 달라 엔티티·인텐트를 둘로 나눈다.
protocol ProviderAccountIntent: WidgetConfigurationIntent {
    static var provider: ProviderKind { get }
    var accountID: String? { get }
}

private func accountEntities(_ p: ProviderKind) -> [(id: String, label: String, email: String?)] {
    SnapshotStore.load().accounts(for: p).map { ($0.id, $0.label, $0.email) }
}

struct ClaudeAccountEntity: AppEntity {
    var id: String
    var label: String
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Claude 계정"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(label)") }
    static let defaultQuery = ClaudeQuery()

    struct ClaudeQuery: EntityQuery {
        func entities(for identifiers: [String]) async throws -> [ClaudeAccountEntity] {
            try await suggestedEntities().filter { identifiers.contains($0.id) }
        }
        func suggestedEntities() async throws -> [ClaudeAccountEntity] {
            accountEntities(.claude).map { a in ClaudeAccountEntity(id: a.id, label: a.email.map { "\(a.label) · \($0)" } ?? a.label) }
        }
    }
}

struct CodexAccountEntity: AppEntity {
    var id: String
    var label: String
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Codex 계정"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(label)") }
    static let defaultQuery = CodexQuery()

    struct CodexQuery: EntityQuery {
        func entities(for identifiers: [String]) async throws -> [CodexAccountEntity] {
            try await suggestedEntities().filter { identifiers.contains($0.id) }
        }
        func suggestedEntities() async throws -> [CodexAccountEntity] {
            accountEntities(.codex).map { a in CodexAccountEntity(id: a.id, label: a.email.map { "\(a.label) · \($0)" } ?? a.label) }
        }
    }
}

struct ClaudeAccountIntent: ProviderAccountIntent {
    static let title: LocalizedStringResource = "Claude 계정 선택"
    static let description = IntentDescription("small 크기에서 보여 줄 계정. 비우면 첫 번째 계정.")
    @Parameter(title: "계정") var account: ClaudeAccountEntity?
    static var provider: ProviderKind { .claude }
    var accountID: String? { account?.id }
}

struct CodexAccountIntent: ProviderAccountIntent {
    static let title: LocalizedStringResource = "Codex 계정 선택"
    static let description = IntentDescription("small 크기에서 보여 줄 계정. 비우면 첫 번째 계정.")
    @Parameter(title: "계정") var account: CodexAccountEntity?
    static var provider: ProviderKind { .codex }
    var accountID: String? { account?.id }
}
