import Foundation
import SwiftData

/// 房源状态：纯房源管理，只有「待租 / 已租」两档，由用户手动切换
enum HouseStatus: String, Codable, CaseIterable, Identifiable {
    case available = "available"
    case rented = "rented"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .available: return "待租"
        case .rented: return "已租"
        }
    }
}

/// 房源模型
@Model
final class House {
    @Attribute(.unique) var id: UUID
    var roomNo: String
    var tower: Int              // 1 = 1座，2 = 2座
    var landlord: String
    var layout: String
    var price: Int
    var password: String
    var remark: String
    var statusRaw: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \MediaItem.house)
    var mediaItems: [MediaItem]

    var status: HouseStatus {
        get { HouseStatus(rawValue: statusRaw) ?? .available }
        set { statusRaw = newValue.rawValue }
    }

    init(
        roomNo: String = "",
        tower: Int = 1,
        landlord: String = "",
        layout: String = "",
        price: Int = 0,
        password: String = "",
        remark: String = "",
        status: HouseStatus = .available
    ) {
        self.id = UUID()
        self.roomNo = roomNo
        self.tower = tower
        self.landlord = landlord
        self.layout = layout
        self.price = price
        self.password = password
        self.remark = remark
        self.statusRaw = status.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
        self.mediaItems = []
    }
}

/// 房源媒体（照片 / 视频），文件存 Documents/Media，模型只存文件名
@Model
final class MediaItem {
    @Attribute(.unique) var id: UUID
    var fileName: String
    var kind: String            // "image" / "video"
    var house: House?

    init(fileName: String, kind: String) {
        self.id = UUID()
        self.fileName = fileName
        self.kind = kind
    }
}

// MARK: - 展示与分享辅助

extension House {
    var towerLabel: String { "\(tower)座" }

    /// 房号展示：2座带「2-」前缀，1座不带（1座若录入时带了「1-」前缀则原样显示，兼容历史数据）
    var displayRoomNo: String {
        if tower == 2 && !roomNo.hasPrefix("2-") { return "2-\(roomNo)" }
        return roomNo
    }

    /// 媒体存储目录名（按房号，去除文件系统非法字符）
    var mediaRoomKey: String {
        let raw = tower == 2 ? "2-\(roomNo)" : roomNo
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\u{22}<>") 
        return raw.components(separatedBy: illegal).joined(separator: "-")
    }

    /// 房号数字串（兼容「1-2334」「2-1006」「634上」「2355下」等写法：
    /// 从末尾开始提取第一段连续数字，忽略座号前缀与「上/下/层」等后缀文字）
    private var sortDigits: String {
        var collected = ""
        for ch in roomNo.reversed() {
            if ch.isNumber {
                collected.append(ch)
            } else if !collected.isEmpty {
                break
            }
        }
        return String(collected.reversed())
    }

    /// 楼层（用于首页按「座号 + 楼层 + 房号」升序排序）：
    ///  - 3 位房号（如 634）：第 1 位是楼层 → 6楼34号
    ///  - 4 位房号（如 1420）：前 2 位是楼层 → 14楼20号
    /// 统一规则：数字最后 2 位是房号，前面剩余位是楼层
    var floorNumber: Int {
        let s = sortDigits
        guard s.count >= 3 else { return Int(s) ?? 0 }
        return Int(s.dropLast(2)) ?? 0
    }

    /// 房号数字（数字部分最后 2 位，如 634 → 34，1420 → 20）
    var roomNumber: Int {
        let s = sortDigits
        guard s.count >= 2 else { return Int(s) ?? 0 }
        return Int(s.suffix(2)) ?? 0
    }

    var priceText: String { "\(price)元/月" }

    var hasPhoto: Bool { mediaItems.contains { $0.kind == "image" } }
    var hasVideo: Bool { mediaItems.contains { $0.kind == "video" } }
    var photos: [MediaItem] { mediaItems.filter { $0.kind == "image" } }
    var videos: [MediaItem] { mediaItems.filter { $0.kind == "video" } }

    /// 分享给客户的核心信息：房号 + 租金 + 房东
    var briefShareText: String {
        var text = "【房源】\(towerLabel)\(roomNo)  \(priceText)"
        if !landlord.isEmpty { text += "  房东：\(landlord)" }
        return text
    }

    /// 完整房源信息
    var fullShareText: String {
        var lines: [String] = []
        lines.append("房源信息")
        lines.append("房号：\(displayRoomNo)")
        lines.append("座号：\(towerLabel)")
        lines.append("房东：\(landlord.isEmpty ? "—" : landlord)")
        lines.append("户型：\(layout.isEmpty ? "—" : layout)")
        lines.append("价格：\(priceText)")
        if !password.isEmpty { lines.append("密码：\(password)") }
        if !remark.isEmpty { lines.append("备注：\(remark)") }
        lines.append("状态：\(status.label)\(status == .available ? "（可带看）" : "")")
        return lines.joined(separator: "\n")
    }
}

// MARK: - 首次启动示例数据（可直接删除）

enum SampleData {
    @MainActor
    static func seedIfNeeded(_ container: ModelContainer) {
        let context = container.mainContext
        let existing = (try? context.fetch(FetchDescriptor<House>())) ?? []
        guard existing.isEmpty else { return }

        let samples: [(roomNo: String, tower: Int, landlord: String, layout: String, price: Int, status: HouseStatus)] = [
            ("2334", 1, "康", "单间", 1100, .available),
            ("2325", 1, "康", "单间", 1000, .available),
            ("1418", 2, "业主", "单间", 900, .rented),
            ("1006", 2, "业主", "复式", 1500, .available)
        ]

        for item in samples {
            let house = House(
                roomNo: item.roomNo,
                tower: item.tower,
                landlord: item.landlord,
                layout: item.layout,
                price: item.price,
                status: item.status
            )
            context.insert(house)
        }
        try? context.save()
    }
}
