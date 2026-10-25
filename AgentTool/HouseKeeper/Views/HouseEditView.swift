import SwiftUI
import SwiftData
import PhotosUI

struct HouseEditView: View {
    /// 房源板块专属 context（独立 HouseStore 容器，由 App 注入）
    @Environment(\.houseModelContext) private var houseModelContext
    @Environment(\.dismiss) private var dismiss

    /// 当前可用的房源数据上下文（App 内必然已注入）
    private var modelContext: ModelContext {
        guard let ctx = houseModelContext else { fatalError("houseModelContext 未注入") }
        return ctx
    }

    /// 传入房源 = 编辑；nil = 新增
    let house: House?

    @State private var roomNo = ""
    @State private var tower = 1
    @State private var landlord = ""
    @State private var layout = ""
    @State private var priceText = ""
    @State private var password = ""
    @State private var remark = ""
    @State private var status: HouseStatus = .available
    @State private var mediaItems: [MediaItem] = []

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedVideos: [PhotosPickerItem] = []
    @State private var loadingMedia = false
    @State private var showError = false
    @State private var errorMessage = ""
    // v1.40 第10点：无网络保存确认
    @State private var showOfflineAlert = false
    // v1.42：保存后云端上传失败 → 提示「已存本机，待网络恢复自动补传」（此前静默入队，用户无感知）
    @State private var pendingUploadTip: String?

    /// 用户是否手动改过座号（改过后不再被房号前缀自动覆盖）
    @State private var towerTouched = false
    /// 编辑前原房号目录 key（房号变更时迁移媒体目录）
    @State private var originalRoomKey = ""
    /// v1.7：房号实时查重——输入时即提示（变红），与保存时校验同一口径
    @State private var duplicateHint: House?
    @State private var showDuplicateHint = false

    private var isEditing: Bool { house != nil }

    var body: some View {
        NavigationStack {
            formContent
                .navigationTitle(isEditing ? "编辑房源" : "登记房源")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") { save() }
                            .fontWeight(.semibold)
                    }
                }
                .onChange(of: selectedPhotos) { _, newValue in
                    guard !newValue.isEmpty else { return }
                    Task { await loadPhotos(from: newValue) }
                }
                .onChange(of: selectedVideos) { _, newValue in
                    guard !newValue.isEmpty else { return }
                    Task { await loadVideos(from: newValue) }
                }
                .alert("无法保存", isPresented: Binding(
                    get: { showError },
                    set: { showError = $0 }
                )) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(errorMessage)
                }
                // v1.40 第10点：无网络时保存新增/编辑房源 → 先提示「仅存本机」，确认后才落盘（联网后可同步云端）
                .alert("当前无网络", isPresented: $showOfflineAlert) {
                    Button("仅存本机", role: .destructive) { performSave() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("检测不到网络连接，本次保存只会存在本机，不会同步到云端。联网后可在房源列表刷新同步。")
                }
                // v1.42：保存后上传云端失败 → 提示已存本机、待网络恢复自动补传（媒体已入队，账本恢复后刷新同步）
                .alert("已保存到本机", isPresented: Binding(
                    get: { pendingUploadTip != nil },
                    set: { if !$0 { pendingUploadTip = nil } }
                )) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(pendingUploadTip ?? "")
                }
                .onAppear(perform: loadFromHouse)
        }
    }

    /// v1.42：Form 主体拆分为独立计算属性——body 的导航栏/多个 alert 链叠加在超大 Form 类型上
    /// 触发编译器「unable to type-check this expression in reasonable time」（报错 49:25），
    /// 拆分后 body 与各链的类型推断负担大幅下降。
    private var formContent: some View {
        Form {
                Section("基本信息") {
                    HStack {
                        Text("房号")
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)
                        // v1.13 需求18：房号输入不允许含空格（避免不小心加空格导致信息重复/查重失效）
                        TextField("如 2334 或 2-1418", text: Binding(
                            get: { roomNo },
                            set: { roomNo = $0.replacingOccurrences(of: " ", with: "") }
                        ))
                            .keyboardType(.numbersAndPunctuation)
                            .foregroundColor(showDuplicateHint ? .red : .primary)
                            .onChange(of: roomNo) { _, newValue in
                                guard !towerTouched else { return }
                                if newValue.hasPrefix("2-") || newValue.hasPrefix("2－") {
                                    tower = 2
                                } else if !newValue.isEmpty {
                                    tower = 1
                                }
                            }
                            .onChange(of: roomNo) { _, newValue in
                                // v1.7：输入房号时实时查重（同座同房号视为重复，变红提示）
                                checkDuplicate(for: newValue)
                            }
                    }
                    // v1.7：重复房号实时提示（类似注册账号检测是否可用）
                    if showDuplicateHint, let dup = duplicateHint {
                        Text("该房号已收录：\(dup.tower == 2 ? "2-" : "")\(dup.roomNo)（\(dup.layout.isEmpty ? "户型未填" : dup.layout)，\(dup.status.label)）\n同一座同一房号不能重复添加")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.leading, 64)
                    }

                    HStack {
                        Text("座号")
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)
                        Picker("座号", selection: $tower) {
                            Text("1座").tag(1)
                            Text("2座").tag(2)
                        }
                        .labelsHidden()
                        .onChange(of: tower) {
                            towerTouched = true
                        }
                    }

                    HStack {
                        Text("房东")
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)
                        TextField("房东姓名", text: $landlord)
                    }

                    HStack {
                        Text("户型")
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)
                        TextField("如 单间 / 复式", text: $layout)
                    }

                    HStack {
                        Text("价格")
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)
                        TextField("元/月", text: $priceText)
                            .keyboardType(.numberPad)
                        Spacer()
                        if !priceText.isEmpty {
                            Text("\(Int(priceText) ?? 0)元/月")
                                .font(.footnote)
                                .foregroundColor(AppTheme.accent)
                        }
                    }

                    HStack {
                        Text("密码")
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)
                        TextField("进门密码", text: $password)
                    }

                    // v1.23：备注行移入「基本信息」板块，放在密码下方（与上下输入框对齐）
                    HStack(alignment: .top) {
                        Text("备注")
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)
                        TextField("如 采光好 / 带阳台 / 近电梯", text: $remark, axis: .vertical)
                            .lineLimit(1...4)
                    }
                }

                Section("状态") {
                    Picker("房源状态", selection: $status) {
                        Text("待租").tag(HouseStatus.available)
                        Text("已租").tag(HouseStatus.rented)
                    }
                    .pickerStyle(.segmented)
                    Text(status == .available ? "待租：可带看" : "已租：已租出，手动更新状态即可")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 9, matching: .images) {
                                Label("添加照片", systemImage: "photo.badge.plus")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.bordered)

                            PhotosPicker(selection: $selectedVideos, maxSelectionCount: 3, matching: .videos) {
                                Label("添加视频", systemImage: "video.badge.plus")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.bordered)

                            if loadingMedia {
                                ProgressView()
                                    .padding(.leading, 4)
                            }
                        }

                        if mediaItems.isEmpty {
                            Text("还没添加照片或视频，添加后可实时预览")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                                // 用唯一的 fileName 作标识（不用 MediaItem.id：SwiftData 新对象 id 不可靠）
                                ForEach(mediaItems, id: \.fileName) { media in
                                    ZStack(alignment: .topTrailing) {
                                        // 固定正方形格子，内容缩放裁切填满，横屏照片不重叠
                                        Color.clear
                                            .aspectRatio(1, contentMode: .fit)
                                            .overlay(
                                                MediaThumbView(media: media, roomKey: originalRoomKey.isEmpty ? currentRoomKey : originalRoomKey)
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .contentShape(RoundedRectangle(cornerRadius: 8))

                                        // 删除按钮：必须限定尺寸 + borderless 样式，防止点击区域扩大到整格
                                        // （此前 Button 直接放 ZStack 无约束，Form+LazyVGrid 下整格都会被判定为按钮，
                                        //   导致「点图片任意区域就触发删除」）
                                        Button {
                                            // 单条删除：只移除 fileName 完全匹配的这一条，其余不受影响
                                            removeMedia(fileName: media.fileName)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 18))
                                                .foregroundColor(.white)
                                                .shadow(radius: 2)
                                        }
                                        .buttonStyle(.borderless)
                                        .frame(width: 32, height: 32)
                                        .contentShape(Rectangle())
                                        .padding(3)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("照片 / 视频")
                } footer: {
                    Text("照片和视频保存在本机，分享时随房源信息一起发送。")
                }
            }
    }

    // MARK: - 载入 / 保存

    /// 当前房号对应的媒体目录 key（新增时用临时 key，保存后正式按房号）
    private var currentRoomKey: String {
        let trimmed = roomNo.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "2－", with: "2-")
        let clean = trimmed.hasPrefix("2-") ? String(trimmed.dropFirst(2)) : trimmed
        let key = tower == 2 ? "2-\(clean)" : clean
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return key.components(separatedBy: illegal).joined(separator: "-")
    }

    private func loadFromHouse() {
        guard let house else { return }
        roomNo = house.roomNo
        tower = house.tower
        landlord = house.landlord
        layout = house.layout
        priceText = house.price > 0 ? "\(house.price)" : ""
        password = house.password
        remark = house.remark
        status = house.status
        // 关键：拷贝构造新数组，与 house.mediaItems（SwiftData 关系数组，引用语义）彻底断开共享，
        // 避免编辑期间的任何增删直接改动数据库关系，导致删除行为异常
        mediaItems = Array(house.mediaItems)
        towerTouched = true
        originalRoomKey = house.mediaRoomKey
    }

    // MARK: - v1.7 房号查重（实时提示 + 保存校验同一口径）

    /// 房号归一化：剥离「2- / 2－ / 1-」座号前缀，只留房号本体（2座保留前缀语义由 tower 承载）
    private func normalizedRoom(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "2－", with: "2-")
        if t.hasPrefix("2-") { t = String(t.dropFirst(2)) }
        if t.hasPrefix("1-") { t = String(t.dropFirst(2)) }
        return t
    }

    /// 查重：同座同房号视为重复；排除自己与已进回收站的房源
    private func duplicateCheck(for rawRoomNo: String, tower: Int = 0) -> House? {
        let clean = normalizedRoom(rawRoomNo)
        guard !clean.isEmpty else { return nil }
        guard let ctx = houseModelContext else { return nil }
        let effectiveTower = tower > 0 ? tower : self.tower
        let all = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
        return all.first { other in
            if other.isDeleted == true { return false }
            let isSelf = house.map { other.id == $0.id } ?? false
            guard !isSelf else { return false }
            return other.tower == effectiveTower && normalizedRoom(other.roomNo) == clean
        }
    }

    /// 输入时实时检测：命中重复 → 变红提示；清空或无重复 → 复位
    private func checkDuplicate(for rawRoomNo: String) {
        guard !normalizedRoom(rawRoomNo).isEmpty else {
            showDuplicateHint = false
            duplicateHint = nil
            return
        }
        if let dup = duplicateCheck(for: rawRoomNo) {
            showDuplicateHint = true
            duplicateHint = dup
        } else {
            showDuplicateHint = false
            duplicateHint = nil
        }
    }

    private func save() {
        // v1.40 第10点：无稳定网络 → 先提示「仅存本机」，用户确认后再保存（避免静默只存本地造成误解）
        if !NetworkMonitor.shared.isReachable {
            showOfflineAlert = true
            return
        }
        performSave()
    }

    private func performSave() {
        let trimmedRoomNo = roomNo.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "2－", with: "2-")
        let cleanRoomNo = trimmedRoomNo.hasPrefix("2-") ? String(trimmedRoomNo.dropFirst(2)) : trimmedRoomNo

        guard !cleanRoomNo.isEmpty else {
            errorMessage = "请填写房号"
            showError = true
            return
        }

        // v1.30：登记查重——以房号为唯一标准（同一座、同一房号视为同一套，禁止重复收录）。
        // v1.7：实时提示与保存校验统一走 duplicateCheck（归一化房号 + 排除自身 + 排除回收站房源）。
        if let duplicate = duplicateCheck(for: roomNo, tower: tower) {
            errorMessage = "这套房源已收录过：\(duplicate.tower == 2 ? "2-" : "")\(duplicate.roomNo)（\(duplicate.layout.isEmpty ? "户型未填" : duplicate.layout)，\(duplicate.status.label)）\n同一座同一房号不能重复添加"
            showError = true
            return
        }

        let target: House
        if let house {
            target = house
        } else {
            target = House()
            modelContext.insert(target)
        }

        // 编辑时：真正删除「已被移除」的旧媒体（文件 + 记录 + 云端对象）
        // 只在保存时执行 → 点「取消」不会落盘，删除可完整回滚
        // v1.41：删除媒体同时删云端对象（图片原名 / 视频 .mp4 + 用户区首帧图），
        //        并清除该文件的上传队列——保证「我删了照片，别人也看不到」（此前只删本地是致命缺陷）
        if let house {
            let removed = house.mediaItems.filter { old in
                !mediaItems.contains { $0.fileName == old.fileName }
            }
            for old in removed {
                let rk = originalRoomKey.isEmpty ? house.mediaRoomKey : originalRoomKey
                MediaStore.delete(fileName: old.fileName, roomKey: rk)
                modelContext.delete(old)
                HouseMediaUploadQueue.remove(roomKey: rk, fileName: old.fileName)
                if let config = CosConfig.load(), config.isValid {
                    let kind = old.kind
                    Task {
                        do {
                            try await CosUploader.deleteRemoteMedia(fileName: old.fileName, kind: kind, roomKey: rk, config: config)
                            BackupLogStore.log(category: "房源", action: "删除媒体（本地→云端）", result: "成功", detail: "\(rk)/\(old.fileName)", cloud: true)
                        } catch {
                            BackupLogStore.log(category: "房源", action: "删除媒体（本地→云端）", result: "失败", detail: "\(rk)/\(old.fileName) \(error.localizedDescription)", cloud: true)
                        }
                    }
                }
            }
        }

        // 编辑时房号变更 → 媒体目录整体迁移，文件不丢失
        if isEditing, let house {
            let newRoomKey: String = {
                let key = house.tower == 2 ? "2-\(cleanRoomNo)" : cleanRoomNo
                let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
                return key.components(separatedBy: illegal).joined(separator: "-")
            }()
            MediaStore.migrateHouseDirectory(from: originalRoomKey, to: newRoomKey)
        }

        target.roomNo = cleanRoomNo
        target.tower = tower
        target.landlord = landlord.trimmingCharacters(in: .whitespacesAndNewlines)
        target.layout = layout.trimmingCharacters(in: .whitespacesAndNewlines)
        target.price = Int(priceText) ?? 0
        target.password = password
        target.remark = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        target.status = status
        target.updatedAt = Date()
        // v1.19：最后更新时间（首次录入 / 编辑保存时刷新）
        target.lastUpdatedAt = Date()

        for item in mediaItems where item.house == nil {
            item.house = target
            modelContext.insert(item)
        }

        try? modelContext.save()
        // v1.41：保存后把该房全部媒体即时上传到桶（新增/替换照片视频立即云端可见，
        //        别的设备同步就能看到最新照片视频）；上传失败自动入队，启动/回前台自动补传
        pushHouseMediaToCloud(target)
        // v1.54：保存后自动生成/更新该房源的脱敏版 H5（删旧生成新）——
        //        保证「新增了房源就自动有分享页」，选房链接里点卡片即可打开完整详情；
        //        编辑保存时旧 H5 立即失效、生成新 H5（内容与最新房源信息一致）
        if let config = CosConfig.load(), config.isValid {
            let files = target.mediaItems.map { ShareMediaFile(name: $0.fileName, kind: $0.kind) }
            let profile = CosUploader.loadShareProfile()
            let info = ShareHouseInfo(
                displayRoomNo: target.displayRoomNo,
                towerLabel: target.towerLabel,
                layout: target.layout,
                statusLabel: target.status.label,
                priceText: target.priceText,
                landlord: target.landlord,
                password: target.password,
                remark: target.remark,
                name: profile.name,
                phone: profile.phone
            )
            let roomKey = target.mediaRoomKey
            Task {
                _ = try? await CosUploader.autoRegenerateMaskedShare(mediaFiles: files, roomKey: roomKey, info: info, config: config)
            }
        }
        // v1.19：新增 / 编辑保存后同步到云端账本（共享房源）
        pushHouseToCloud(target)
        NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
        dismiss()
    }

    // MARK: - v1.19 云端双写

    /// v1.41：房源媒体即时上传——保存后把全部媒体传到桶 h/<房号>/（桶内已有则幂等跳过）。
    /// 上传失败自动入 HouseMediaUploadQueue，App 启动/回前台自动补传；写云端操作日志。
    /// 与分享上传、队列补传共用 CosUploader.uploadHouseMedia（视频转 mp4 + 用户区首帧图），行为一致。
    private func pushHouseMediaToCloud(_ house: House) {
        guard let config = CosConfig.load(), config.isValid else { return }
        let roomKey = house.mediaRoomKey
        let compress = shareCompressionEnabled
        let media = house.mediaItems
        guard !media.isEmpty else { return }
        Task {
            var success = 0, failed = 0
            let total = media.count
            // v1.42：卡片底部进度条——按文件推进（上传中 x%）
            HouseSyncProgress.shared.update(roomKey: roomKey, direction: .upload, progress: 0)
            for (idx, item) in media.enumerated() {
                let url = MediaStore.url(for: item.fileName, roomKey: roomKey)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    HouseMediaUploadQueue.enqueue(roomKey: roomKey, fileName: item.fileName, kind: item.kind)
                    failed += 1
                    HouseSyncProgress.shared.update(roomKey: roomKey, direction: .upload, progress: Double(idx + 1) / Double(total))
                    continue
                }
                do {
                    try await CosUploader.uploadHouseMedia(fileName: item.fileName, kind: item.kind, roomKey: roomKey, config: config, compress: compress)
                    HouseMediaUploadQueue.remove(roomKey: roomKey, fileName: item.fileName)
                    success += 1
                } catch {
                    HouseMediaUploadQueue.enqueue(roomKey: roomKey, fileName: item.fileName, kind: item.kind)
                    failed += 1
                }
                HouseSyncProgress.shared.update(roomKey: roomKey, direction: .upload, progress: Double(idx + 1) / Double(total))
            }
            HouseSyncProgress.shared.clear()
            if failed > 0 {
                BackupLogStore.log(category: "房源", action: "上传媒体（本地→云端）", result: "部分失败", detail: "\(house.displayRoomNo)：成功\(success) 失败\(failed)（已入队自动补传）", cloud: true)
                await MainActor.run {
                    if pendingUploadTip == nil {
                        pendingUploadTip = "房源已保存到本机；媒体上传云端失败（共 \(failed) 个），已自动排队，网络恢复后自动补传。"
                    }
                }
            } else if success > 0 {
                BackupLogStore.log(category: "房源", action: "上传媒体（本地→云端）", result: "成功", detail: "\(house.displayRoomNo)：\(success) 个媒体", cloud: true)
            }
        }
    }

    /// 保存后把房源推到云端账本（读改写，同房号覆盖）。无云存储配置则跳过（仅本地）。
    private func pushHouseToCloud(_ house: House) {
        guard let config = CosConfig.load() else { return }
        let record = CloudHouseSync.record(from: house, username: CloudUser.username)
        Task {
            do {
                try await CloudHouseSync.upload(record: record, config: config)
                await MainActor.run {
                    house.cloudStatus = .both
                    try? modelContext.save()
                }
                BackupLogStore.log(category: "房源", action: "同步房源（本地→云端）", result: "成功", detail: house.displayRoomNo, cloud: true)
            } catch {
                BackupLogStore.log(category: "房源", action: "同步房源（本地→云端）", result: "失败", detail: "\(house.displayRoomNo)：\(error.localizedDescription)", cloud: true)
                // v1.42：保存成功但账本上传失败 → 提示待网络恢复后刷新同步（此前只写日志，用户无感知）
                await MainActor.run {
                    if pendingUploadTip == nil {
                        pendingUploadTip = "房源已保存到本机；同步云端失败（网络不通），联网后在房源列表下拉刷新即可补传。"
                    }
                }
            }
        }
    }

    // MARK: - 媒体处理

    /// 删除单条媒体：用「重建数组」方式移除，绝不修改任何共享数组引用，也不依赖模型对象引用
    /// - 已有记录（在 house.mediaItems 里）：只从暂存数组移除，点「保存」才真正删除，点「取消」完整回滚
    /// - 新增媒体（不在 house.mediaItems 里）：立即清理已写盘的文件
    private func removeMedia(fileName target: String) {
        // 判断是否为「已有记录」
        let isExisting = house?.mediaItems.contains(where: { $0.fileName == target }) ?? false
        // 记录被移除条目的文件名（若存在）
        let removedFile = mediaItems.first(where: { $0.fileName == target })?.fileName

        // 重建数组：只排除 fileName 完全匹配的这一条，其余原样保留
        mediaItems = mediaItems.filter { $0.fileName != target }

        // 新增媒体：文件已写盘但尚未关联房源 → 立即清理该文件，避免残留孤儿文件
        if let removedFile, !isExisting {
            MediaStore.delete(fileName: removedFile, roomKey: originalRoomKey.isEmpty ? currentRoomKey : originalRoomKey)
        }
    }

    private func loadPhotos(from items: [PhotosPickerItem]) async {
        loadingMedia = true
        defer { loadingMedia = false }

        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data),
               let jpeg = image.jpegData(compressionQuality: 0.85) {
                let fileName = MediaStore.save(data: jpeg, ext: "jpg", roomKey: currentRoomKey)
                mediaItems.append(MediaItem(fileName: fileName, kind: "image"))
            }
        }
        selectedPhotos = []
    }

    private func loadVideos(from items: [PhotosPickerItem]) async {
        loadingMedia = true
        defer { loadingMedia = false }

        for item in items {
            var savedName: String?

            // 方式一：URL（安全作用域访问后拷贝临时文件）
            if let url = try? await item.loadTransferable(type: URL.self) {
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                if FileManager.default.fileExists(atPath: url.path) {
                    savedName = MediaStore.saveFile(from: url, roomKey: currentRoomKey)
                }
            }

            // 方式二：直接读数据（URL 方式拿不到时兜底）
            if savedName == nil,
               let data = try? await item.loadTransferable(type: Data.self) {
                savedName = MediaStore.save(data: data, ext: "mov", roomKey: currentRoomKey)
            }

            if let savedName {
                mediaItems.append(MediaItem(fileName: savedName, kind: "video"))
            }
        }
        selectedVideos = []
    }
}
