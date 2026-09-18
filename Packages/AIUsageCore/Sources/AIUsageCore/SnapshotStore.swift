import Foundation

/// 앱이 쓰고 위젯이 읽는 App Group 스냅샷 파일.
public enum SnapshotStore {
    /// Info.plist `AIUsageAppGroup` (= `$(TeamIdentifierPrefix)com.typostudio.aiusage`)
    public static var appGroupID: String? {
        Bundle.main.object(forInfoDictionaryKey: "AIUsageAppGroup") as? String
    }

    public static var fileURL: URL? {
        guard let id = appGroupID,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) else { return nil }
        return dir.appendingPathComponent("snapshot.json")
    }

    public static func load(from url: URL? = fileURL) -> Snapshot {
        guard let url, let data = try? Data(contentsOf: url),
              let s = try? decoder.decode(Snapshot.self, from: data) else { return .empty }
        return s
    }

    public static func save(_ snapshot: Snapshot, to url: URL? = fileURL) throws {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    public static let staleInterval: TimeInterval = 10 * 60

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
