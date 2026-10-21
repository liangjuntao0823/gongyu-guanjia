import Foundation

/// 跨端协议版本。它与 DataBackupManager 的旧备份 schemaVersion 相互独立。
enum SyncProtocol {
    static let protocolVersion = 1
    static let schemaVersion = 1
}

enum SyncOperation: String, Codable {
    case upsert
    case delete
}

enum SyncEntityType: String, Codable, CaseIterable {
    case property
    case rentMonthRecord
    case utilityQuarterRecord
    case dealRecord
    case miscIncome
    case miscExpense
    case payoutRecord
    case payoutMonthRecord
    case payoutUtilityRecord
    case profitCalculation
}

/// payload 保持 JSON 类型，同时避免直接序列化 SwiftData 模型。
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case integer(Int64)
    case boolean(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .boolean(v) }
        else if let v = try? value.decode(Int64.self) { self = .integer(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .integer(let v): try value.encode(v)
        case .boolean(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
}

struct SyncEntityDTO: Codable, Identifiable, Equatable {
    let entityType: SyncEntityType
    let id: UUID
    let revision: Int64
    let createdAt: Date
    let updatedAt: Date
    let updatedByDeviceId: UUID
    let isDeleted: Bool
    let deletedAt: Date?
    let deletedByDeviceId: UUID?
    let deleteRevision: Int64?
    let payload: [String: JSONValue]
}

struct SyncSnapshotDTO: Codable, Equatable {
    let protocolVersion: Int
    let schemaVersion: Int
    let appVersion: String
    let exportedAt: Date
    let sourceDeviceId: UUID
    let sourceDeviceName: String
    let entities: [SyncEntityDTO]
}

struct PendingChangeDTO: Codable, Identifiable, Equatable {
    let id: UUID
    let entityType: SyncEntityType
    let entityId: UUID
    let baseRevision: Int64
    let operation: SyncOperation
    let payload: [String: JSONValue]?
    let createdAt: Date
    var retryCount: Int
}

struct SyncResultSummary: Codable, Equatable {
    let uploaded: Int
    let downloaded: Int
    let merged: Int
    let conflicts: Int
    let failed: Int
}

extension JSONEncoder {
    static var syncEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var syncDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }

            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) { return date }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "不支持的 ISO 8601 日期格式：\(value)"
            )
        }
        return decoder
    }
}
