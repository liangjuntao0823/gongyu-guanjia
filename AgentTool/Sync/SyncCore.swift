import Foundation

struct SyncConnectionInfo: Codable, Equatable {
    var host: String
    var port: Int = 8765
    var code: String

    var baseURL: URL? {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "http://" + value }
        guard var components = URLComponents(string: value) else { return nil }
        if components.port == nil { components.port = port }
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }

    var qrText: String {
        let data = try? JSONEncoder.syncEncoder.encode(self)
        return "zfgj://connect?data=" + (data?.base64EncodedString() ?? "")
    }

    static func parse(_ text: String) -> SyncConnectionInfo? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded: SyncConnectionInfo?
        if let components = URLComponents(string: trimmed),
           components.scheme?.lowercased() == "zfgj",
           components.host?.lowercased() == "connect",
           let encoded = components.queryItems?.first(where: { $0.name == "data" })?.value,
           let data = Data(base64Encoded: encoded) {
            decoded = try? JSONDecoder.syncDecoder.decode(Self.self, from: data)
        } else {
            decoded = try? JSONDecoder.syncDecoder.decode(Self.self, from: Data(trimmed.utf8))
        }
        guard let decoded,
              !decoded.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65_535).contains(decoded.port),
              decoded.code.count == 6,
              decoded.code.allSatisfy(\.isNumber) else { return nil }
        return decoded
    }
}

struct SyncPreflightRequest: Codable {
    let code: String
    let deviceId: UUID
    let protocolVersion: Int
    let schemaVersion: Int
    let cursor: String?
    let pendingUploadCount: Int
}
struct SyncPreflightResponse: Codable { let token: String; let expiresAt: Date; let remoteDeviceName: String; let pendingDownloadCount: Int; let serverCursor: String? }
struct SyncPushRequest: Codable { let changes: [PendingChangeDTO] }
struct SyncPushResponse: Codable { let acceptedIds: [UUID]; let conflicts: [SyncConflict]; let nextCursor: String? }
struct SyncPullResponse: Codable { let entities: [SyncEntityDTO]; let conflicts: [SyncConflict]; let nextCursor: String? }
struct SyncAckRequest: Codable { let changeIds: [UUID]; let cursor: String? }

struct SyncConflict: Codable, Identifiable, Equatable {
    let id: UUID
    let entityType: SyncEntityType
    let entityId: UUID
    let local: SyncEntityDTO?
    let remote: SyncEntityDTO?
    let reason: String
    let detectedAt: Date
}

enum SyncClientError: LocalizedError {
    case invalidAddress, tokenExpired, badResponse(Int, String?), invalidResponse, transport(String)
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "服务器地址无效"
        case .tokenExpired: return "连接令牌已过期，请重新预检"
        case .badResponse(let code, let detail):
            return detail.map { "服务器返回错误（HTTP \(code)）：\($0)" } ?? "服务器返回错误（HTTP \(code)）"
        case .invalidResponse: return "服务器响应格式无效"
        case .transport(let message): return "网络请求失败：\(message)"
        }
    }
}

actor ManualSyncClient {
    private let session: URLSession
    private var baseURL: URL?
    private var token: String?
    private var tokenExpiresAt: Date?
    private let pageSize = 100
    private let maximumRetries = 2

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func preflight(connection: SyncConnectionInfo, deviceId: UUID, cursor: String?, pendingUploadCount: Int) async throws -> SyncPreflightResponse {
        guard let url = connection.baseURL else { throw SyncClientError.invalidAddress }
        baseURL = url
        let body = SyncPreflightRequest(
            code: connection.code,
            deviceId: deviceId,
            protocolVersion: SyncProtocol.protocolVersion,
            schemaVersion: SyncProtocol.schemaVersion,
            cursor: cursor,
            pendingUploadCount: pendingUploadCount
        )
        let response: SyncPreflightResponse = try await request(path: "/api/sync/preflight", method: "POST", body: body, authenticated: false)
        guard response.expiresAt > Date() else { throw SyncClientError.tokenExpired }
        token = response.token
        tokenExpiresAt = response.expiresAt
        return response
    }

    func push(_ changes: [PendingChangeDTO]) async throws -> (accepted: [UUID], conflicts: [SyncConflict]) {
        var accepted: [UUID] = []; var conflicts: [SyncConflict] = []
        for start in stride(from: 0, to: changes.count, by: pageSize) {
            let page = Array(changes[start..<min(start + pageSize, changes.count)])
            let response: SyncPushResponse = try await request(path: "/api/sync/push", method: "POST", body: SyncPushRequest(changes: page))
            accepted += response.acceptedIds; conflicts += response.conflicts
        }
        return (accepted, conflicts)
    }

    func pull(cursor: String?) async throws -> (entities: [SyncEntityDTO], conflicts: [SyncConflict], cursor: String?) {
        var all: [SyncEntityDTO] = []; var conflicts: [SyncConflict] = []
        var requestCursor = cursor
        var finalCursor = cursor
        var seen = Set<String>()
        for _ in 0..<1_000 {
            var components = URLComponents()
            components.path = "/api/sync/pull"
            components.queryItems = [URLQueryItem(name: "limit", value: String(pageSize))]
            if let requestCursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: requestCursor)) }
            guard let path = components.string else { throw SyncClientError.invalidAddress }
            let response: SyncPullResponse = try await request(path: path, method: "GET", body: Optional<String>.none)
            all += response.entities; conflicts += response.conflicts
            guard let next = response.nextCursor else { break }
            guard seen.insert(next).inserted else { throw SyncClientError.invalidResponse }
            finalCursor = next; requestCursor = next
        }
        return (all, conflicts, finalCursor)
    }

    func ack(changeIds: [UUID], cursor: String?) async throws {
        let _: EmptyResponse = try await request(path: "/api/sync/ack", method: "POST", body: SyncAckRequest(changeIds: changeIds, cursor: cursor))
    }

    private func request<Response: Decodable, Body: Encodable>(path: String, method: String, body: Body?, authenticated: Bool = true) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw SyncClientError.invalidAddress }
        if authenticated, tokenExpiresAt.map({ $0 <= Date() }) ?? true { throw SyncClientError.tokenExpired }
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated, let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder.syncEncoder.encode(body) }
        var lastError: Error?
        for attempt in 0...maximumRetries {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw SyncClientError.invalidResponse }
                guard (200...299).contains(http.statusCode) else {
                    let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    var detail = raw
                    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        detail = (object["error"] as? String) ?? (object["title"] as? String) ?? raw
                    }
                    if detail?.isEmpty == true { detail = nil }
                    throw SyncClientError.badResponse(http.statusCode, detail)
                }
                if Response.self == EmptyResponse.self, data.isEmpty { return EmptyResponse() as! Response }
                return try JSONDecoder.syncDecoder.decode(Response.self, from: data)
            } catch {
                lastError = error
                if attempt < maximumRetries { try await Task.sleep(for: .milliseconds(300 * (1 << attempt))) }
            }
        }
        if let error = lastError as? SyncClientError { throw error }
        throw SyncClientError.transport(lastError?.localizedDescription ?? "未知错误")
    }
}

struct EmptyResponse: Codable { init() {} }

actor SyncStore {
    static let shared = SyncStore()
    private struct State: Codable {
        var pending: [PendingChangeDTO] = []
        var conflicts: [SyncConflict] = []
        var cursor: String?
        var revisions: [String: Int64] = [:]

        private enum CodingKeys: String, CodingKey {
            case pending, conflicts, cursor, revisions
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pending = try container.decodeIfPresent([PendingChangeDTO].self, forKey: .pending) ?? []
            conflicts = try container.decodeIfPresent([SyncConflict].self, forKey: .conflicts) ?? []
            cursor = try container.decodeIfPresent(String.self, forKey: .cursor)
            revisions = try container.decodeIfPresent([String: Int64].self, forKey: .revisions) ?? [:]
        }
    }
    private var state = State()
    private let url: URL

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ManualSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("sync-state.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder.syncDecoder.decode(State.self, from: data) { state = decoded }
    }

    func snapshot() -> (pending: [PendingChangeDTO], conflicts: [SyncConflict], cursor: String?, revisions: [String: Int64]) {
        (state.pending, state.conflicts, state.cursor, state.revisions)
    }
    static func entityKey(entityType: SyncEntityType, entityId: UUID) -> String {
        "\(entityType.rawValue)|\(entityId.uuidString.lowercased())"
    }
    func enqueue(_ change: PendingChangeDTO) throws { state.pending.removeAll { $0.id == change.id }; state.pending.append(change); try save() }
    func markAccepted(_ ids: [UUID], from changes: [PendingChangeDTO]) throws {
        let accepted = changes.filter { ids.contains($0.id) }
        for change in accepted {
            state.revisions[Self.entityKey(entityType: change.entityType, entityId: change.entityId)] = change.baseRevision + 1
        }
        state.pending.removeAll { ids.contains($0.id) }
        try save()
    }
    func incrementRetry(_ ids: [UUID]) throws { for index in state.pending.indices where ids.contains(state.pending[index].id) { state.pending[index].retryCount += 1 }; try save() }
    func addConflicts(_ values: [SyncConflict]) throws { for value in values { state.conflicts.removeAll { $0.id == value.id }; state.conflicts.append(value) }; try save() }
    func resolveConflict(_ id: UUID) throws { state.conflicts.removeAll { $0.id == id }; try save() }
    func setCursor(_ cursor: String?) throws { state.cursor = cursor; try save() }

    private func save() throws {
        let data = try JSONEncoder.syncEncoder.encode(state)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
