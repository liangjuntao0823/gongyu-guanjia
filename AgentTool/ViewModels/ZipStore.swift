import Foundation

// MARK: - v1.12 最小 ZIP 归档（STORE 无压缩模式）
// iOS 无内置 zip 归档 API（Compression 框架只支持单流压缩），为不引入第三方依赖，
// 自实现最小 zip 读写：本地文件头 + 中央目录 + EOCD，method=STORE（媒体多为 jpg/mov 已压缩格式，再压无意义）。
// 支持：整包写入、解析中央目录、按需提取单文件、全量解压到目录。

enum ZipEntry {
    let path: String
    let crc32: UInt32
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
}

enum ZipStore {
    /// 从「路径 → 数据」写一个 zip 到目标 URL（同一路径重复出现时后者覆盖前者）
    static func createZip(entries: [(path: String, data: Data)], to url: URL) throws {
        var body = Data()
        var central: [Data] = []
        var offset: UInt64 = 0
        var seen = Set<String>()

        for (path, data) in entries {
            let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            let nameData = Data(normalized.utf8)
            let crc = crc32(of: data)
            let size = UInt64(data.count)

            var lfh = localHeaderData(nameData: nameData, crc: crc, size: size, offset: &offset)
            lfh.append(data)
            body.append(lfh)
            central.append(centralRecordData(nameData: nameData, crc: crc, size: size, localHeaderOffset: offset - UInt64(lfh.count)))
        }

        var full = body
        appendCentralAndEOCD(central: central, bodyCount: body.count, centralRecords: &central, to: &full, startOffset: offset)
        try full.write(to: url, options: .atomic)
    }

    /// 从「归档路径 → 本地文件」流式写 zip（媒体全量备份用，避免大文件整包进内存）
    static func createZipStreamed(entries: [(path: String, fileURL: URL)], to url: URL, progress: ((Double) -> Void)? = nil) throws {
        var body = Data()
        var central: [Data] = []
        var offset: UInt64 = 0
        var seen = Set<String>()
        var totalBytes: Int64 = 0
        for entry in entries {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: entry.fileURL.path),
               let size = attrs[.size] as? Int64 {
                totalBytes += size
            }
        }
        var writtenBytes: Int64 = 0

        for (path, fileURL) in entries {
            let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            let nameData = Data(normalized.utf8)
            let fileData = try Data(contentsOf: fileURL)  // 媒体单文件通常 < 200MB，可接受；超大可再改分块
            let crc = crc32(of: fileData)
            let size = UInt64(fileData.count)

            var lfh = localHeaderData(nameData: nameData, crc: crc, size: size, offset: &offset)
            lfh.append(fileData)
            body.append(lfh)
            writtenBytes += Int64(fileData.count)
            progress?(Double(writtenBytes) / Double(max(totalBytes, 1)))
            central.append(centralRecordData(nameData: nameData, crc: crc, size: size, localHeaderOffset: offset - UInt64(lfh.count)))
        }

        var full = body
        appendCentralAndEOCD(central: central, bodyCount: body.count, centralRecords: &central, to: &full, startOffset: offset)
        try full.write(to: url, options: .atomic)
        progress?(1.0)
    }

    /// 解析 zip 中央目录，返回条目列表（失败抛错）
    static func listEntries(at url: URL) throws -> [ZipEntry] {
        let data = try Data(contentsOf: url)
        return try parseCentralDirectory(data)
    }

    /// 按路径提取单个文件数据（STORE 模式）
    static func extract(at url: URL, path: String) throws -> Data {
        let data = try Data(contentsOf: url)
        let entries = try parseCentralDirectory(data)
        guard let entry = entries.first(where: { $0.path == path }) else {
            throw ZipError.entryNotFound(path)
        }
        let start = Int(entry.localHeaderOffset)
        guard start + 30 <= data.count else { throw ZipError.corrupted }
        // 解析 local header 的 nameLen/extraLen
        let nameLen = Int(le16Value(data, at: start + 26))
        let extraLen = Int(le16Value(data, at: start + 28))
        let dataStart = start + 30 + nameLen + extraLen
        let length = Int(entry.uncompressedSize)
        guard dataStart + length <= data.count else { throw ZipError.corrupted }
        return data.subdata(in: dataStart..<(dataStart + length))
    }

    /// 全量解压到目录（media 恢复用）：跳过目录项，覆盖已存在文件；流式读避免大文件进内存
    static func extractAll(at url: URL, to directory: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let totalSize = try handle.seekToEnd()
        try handle.seek(toFileOffset: 0)

        // 尾部 64KB 内找 EOCD
        let tailLen = Int(min(totalSize, 65557))
        try handle.seek(toFileOffset: totalSize - UInt64(tailLen))
        let tail = handle.readData(ofLength: tailLen)
        var eocdPos = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50, i + 3 < tail.count, tail[i+1] == 0x4B, tail[i+2] == 0x05, tail[i+3] == 0x06 {
                eocdPos = i
                break
            }
            i -= 1
        }
        guard eocdPos >= 0 else { throw ZipError.corrupted }
        let totalEntries = Int(le16Value(tail, at: eocdPos + 10))
        let cdSize = Int(le32Value(tail, at: eocdPos + 12))
        let cdOffset = Int(le32Value(tail, at: eocdPos + 16))
        guard cdOffset >= 0, cdSize >= 0 else { throw ZipError.corrupted }

        // 读中央目录
        try handle.seek(toFileOffset: UInt64(cdOffset))
        let cdData = handle.readData(ofLength: cdSize)
        guard cdData.count == cdSize else { throw ZipError.corrupted }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var pos = 0
        for _ in 0..<totalEntries {
            guard pos + 46 <= cdData.count, le32Value(cdData, at: pos) == 0x02014B50 else { throw ZipError.corrupted }
            let method = le16Value(cdData, at: pos + 10)
            let usize = Int(le32Value(cdData, at: pos + 24))
            let nameLen = Int(le16Value(cdData, at: pos + 28))
            let extraLen = Int(le16Value(cdData, at: pos + 30))
            let commentLen = Int(le16Value(cdData, at: pos + 32))
            let localOffset = Int(le32Value(cdData, at: pos + 42))
            let nameStart = pos + 46
            guard nameStart + nameLen <= cdData.count else { throw ZipError.corrupted }
            let path = String(data: cdData.subdata(in: nameStart..<(nameStart + nameLen)), encoding: .utf8) ?? ""
            pos = nameStart + nameLen + extraLen + commentLen

            guard !path.hasSuffix("/") else { continue }
            guard method == 0 else { throw ZipError.corrupted }  // 本工具只支持 STORE 条目
            let safePath = normalizeArchivePath(path)
            let target = directory.appendingPathComponent(safePath)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

            // 读 local header（30 字节 + nameLen + extraLen）定位数据起点
            try handle.seek(toFileOffset: UInt64(localOffset))
            let lfh = handle.readData(ofLength: 30)
            guard lfh.count == 30, le32Value(lfh, at: 0) == 0x04034B50 else { throw ZipError.corrupted }
            let actualNameLen = Int(le16Value(lfh, at: 26))
            let actualExtraLen = Int(le16Value(lfh, at: 28))
            let dataStart = localOffset + 30 + actualNameLen + actualExtraLen
            try handle.seek(toFileOffset: UInt64(dataStart))

            if !FileManager.default.fileExists(atPath: target.path) {
                FileManager.default.createFile(atPath: target.path, contents: nil)
            }
            guard let out = FileHandle(forWritingAtPath: target.path) else { throw ZipError.corrupted }
            defer { try? out.close() }
            var remaining = usize
            while remaining > 0 {
                let chunk = handle.readData(ofLength: min(1_048_576, remaining))
                guard !chunk.isEmpty else { throw ZipError.corrupted }
                out.write(chunk)
                remaining -= chunk.count
            }
        }
    }

    static func isZip(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 4)
        guard data.count == 4 else { return false }
        return data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04
    }

    // MARK: - 内部实现

    private static func localHeaderData(nameData: Data, crc: UInt32, size: UInt64, offset: inout UInt64) -> Data {
        var lfh = Data()
        lfh.append(le32(0x04034B50))
        lfh.append(le16(20))
        lfh.append(le16(0))
        lfh.append(le16(0))               // method: STORE
        lfh.append(le16(0))
        lfh.append(le16(0x21))            // mod date
        lfh.append(le32(crc))
        lfh.append(le32(UInt32(size)))
        lfh.append(le32(UInt32(size)))
        lfh.append(le16(UInt16(nameData.count)))
        lfh.append(le16(0))
        lfh.append(nameData)
        let recordSize = UInt64(30 + nameData.count)
        _ = recordSize
        offset += UInt64(30 + nameData.count + Int(size))
        return lfh
    }

    private static func centralRecordData(nameData: Data, crc: UInt32, size: UInt64, localHeaderOffset: UInt64) -> Data {
        var cd = Data()
        cd.append(le32(0x02014B50))
        cd.append(le16(20))
        cd.append(le16(20))
        cd.append(le16(0))
        cd.append(le16(0))
        cd.append(le16(0))
        cd.append(le16(0x21))
        cd.append(le32(crc))
        cd.append(le32(UInt32(size)))
        cd.append(le32(UInt32(size)))
        cd.append(le16(UInt16(nameData.count)))
        cd.append(le16(0))
        cd.append(le16(0))
        cd.append(le16(0))
        cd.append(le16(0))
        cd.append(le32(0))
        cd.append(le32(UInt32(localHeaderOffset)))
        cd.append(nameData)
        return cd
    }

    private static func appendCentralAndEOCD(central: [Data], bodyCount: Int, centralRecords: inout [Data], to full: inout Data, startOffset: UInt64) {
        let cdStart = startOffset
        var cdData = Data()
        for cd in central { cdData.append(cd) }
        let cdSize = UInt64(cdData.count)
        full.append(cdData)

        var eocd = Data()
        eocd.append(le32(0x06054B50))
        eocd.append(le16(0))
        eocd.append(le16(0))
        eocd.append(le16(UInt16(central.count)))
        eocd.append(le16(UInt16(central.count)))
        eocd.append(le32(UInt32(cdSize)))
        eocd.append(le32(UInt32(cdStart)))
        eocd.append(le16(0))
        full.append(eocd)
    }

    private static func parseCentralDirectory(_ data: Data) throws -> [ZipEntry] {
        // 从尾部找 EOCD（最后 65557 字节内）
        let minSearch = max(0, data.count - 65557)
        var eocdPos = -1
        var i = data.count - 22
        while i >= minSearch {
            if data[i] == 0x50, i + 3 < data.count, data[i+1] == 0x4B, data[i+2] == 0x05, data[i+3] == 0x06 {
                eocdPos = i
                break
            }
            i -= 1
        }
        guard eocdPos >= 0 else { throw ZipError.corrupted }
        let totalEntries = Int(le16Value(data, at: eocdPos + 10))
        let cdSize = Int(le32Value(data, at: eocdPos + 12))
        let cdOffset = Int(le32Value(data, at: eocdPos + 16))
        guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= data.count else { throw ZipError.corrupted }

        var entries: [ZipEntry] = []
        var pos = cdOffset
        for _ in 0..<totalEntries {
            guard pos + 46 <= data.count, le32Value(data, at: pos) == 0x02014B50 else { throw ZipError.corrupted }
            let method = le16Value(data, at: pos + 10)
            let crc = le32Value(data, at: pos + 16)
            let csize = le64Value(le32Value(data, at: pos + 20))
            let usize = le64Value(le32Value(data, at: pos + 24))
            let nameLen = Int(le16Value(data, at: pos + 28))
            let extraLen = Int(le16Value(data, at: pos + 30))
            let commentLen = Int(le16Value(data, at: pos + 32))
            let localOffset = le64Value(le32Value(data, at: pos + 42))
            let nameStart = pos + 46
            guard nameStart + nameLen <= data.count else { throw ZipError.corrupted }
            let path = String(data: data.subdata(in: nameStart..<(nameStart + nameLen)), encoding: .utf8) ?? ""
            entries.append(ZipEntry(path: path, crc32: crc, compressedSize: csize, uncompressedSize: usize, localHeaderOffset: localOffset))
            pos = nameStart + nameLen + extraLen + commentLen
        }
        return entries
    }

    private static func normalizeArchivePath(_ path: String) -> String {
        // 去掉开头的 / 与 ./，过滤 .. 段，防止 zip 内恶意路径逃逸目录
        let parts = path.split(separator: "/").map(String.init)
        var safe: [String] = []
        for part in parts {
            if part == ".." || part.isEmpty || part == "." { continue }
            safe.append(part)
        }
        return safe.joined(separator: "/")
    }

    // MARK: - CRC32

    private static var crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[n] = c
        }
        return table
    }()

    static func crc32(of data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - 字节序

    private static func le16(_ v: UInt16) -> Data {
        var v = v
        return Data(bytes: &v, count: 2)
    }

    private static func le32(_ v: UInt32) -> Data {
        var v = v
        return Data(bytes: &v, count: 4)
    }

    private static func le16Value(_ data: Data, at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func le32Value(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func le64Value(_ v: UInt32) -> UInt64 { UInt64(v) }
}

enum ZipError: LocalizedError {
    case corrupted
    case entryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .corrupted: return "备份文件已损坏或格式不正确"
        case .entryNotFound(let path): return "备份中缺少文件：\(path)"
        }
    }
}
