import SwiftUI
import SwiftData
import AVKit
import Photos

struct HouseDetailView: View {
    /// 房源板块专属 context（独立 HouseStore 容器，由 App 注入）
    @Environment(\.houseModelContext) private var houseModelContext
    @Environment(\.dismiss) private var dismiss

    /// 当前可用的房源数据上下文（App 内必然已注入）
    private var modelContext: ModelContext {
        guard let ctx = houseModelContext else { fatalError("houseModelContext 未注入") }
        return ctx
    }

    let house: House

    @State private var showEdit = false
    @State private var showShare = false
    @State private var showDeleteConfirm = false
    @State private var showStatusConfirm = false
    @State private var showShareModePicker = false    // v1.21：分享前先选「脱敏 / 完整」
    @State private var previewRoute: PhotoPreviewRoute? = nil
    @State private var shareItems: [Any] = []
    @State private var isSelecting = false          // 多选模式
    @State private var selectedMediaNames = Set<String>()   // 用唯一 fileName 标记选中
    @State private var saveTip: String?
    @State private var isSharing = false           // 生成分享卡片中
    @State private var shareProgress = 0.0         // v1.13 需求13：上传百分比进度
    @State private var shareError: String?
    // v1.13 需求11：转发朋友圈——有视频+图片时弹二级菜单选「图片 / 视频」
    @State private var showForwardMenu = false
    @State private var isForwarding = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                mediaSection
                infoCard
                actionCard
            }
            .padding(16)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle(house.displayRoomNo)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") { showEdit = true }
            }
        }
        .sheet(isPresented: $showEdit) {
            HouseEditView(house: house)
        }
        .sheet(isPresented: $showShare) {
            // 注意：UIActivityViewController 不能加 presentationDetents，否则弹分享面板会闪退
            HouseShareSheet(items: shareItems)
        }
        .confirmationDialog("转发到朋友圈", isPresented: $showForwardMenu, titleVisibility: .visible) {
            // v1.13 需求11：有视频+图片时选择转发内容；图片自动取前 9 张（不足取全部）
            Button("分享图片（前 9 张）") { forwardImages() }
            Button("分享视频") { forwardVideos() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这套房源同时有照片和视频，选择要转发到朋友圈的内容。")
        }
        .confirmationDialog("切换房源状态", isPresented: $showStatusConfirm, titleVisibility: .visible) {
            if house.status == .available {
                Button("标记为已租", role: .destructive) { setStatus(.rented) }
            } else {
                Button("标记为待租") { setStatus(.available) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(house.status == .available ? "确认这套已租出？" : "确认这套恢复可带看？")
        }
        .confirmationDialog("删除这套房源？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除房源", role: .destructive) { deleteHouse() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后进入「设置 → 回收站」可恢复；照片和视频保留在本地，彻底删除时才会移除。")
        }
        .confirmationDialog("选择分享方式", isPresented: $showShareModePicker, titleVisibility: .visible) {
            // v1.21：脱敏版隐藏房号/价格/房东，发给找房客户；完整版显示全部信息，发给同事
            Button("发给客户（隐藏版）") { startShare(mode: .masked) }
            Button("发给同事（完整版）") { startShare(mode: .full) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("隐藏版只显示户型、位置和您的联系方式；完整版额外显示房号、价格、房东和密码。")
        }
        .fullScreenCover(item: $previewRoute) { route in
            PhotoPreviewView(photos: house.photos, startIndex: route.index, roomKey: house.mediaRoomKey)
        }
        .overlay {
            if isSharing {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView(value: shareProgress)
                            .progressViewStyle(.linear)
                            .tint(.white)
                        Text("正在上传照片和视频…")
                            .font(.footnote)
                            .foregroundColor(.white)
                        Text("\(Int(shareProgress * 100))%")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .padding(20)
                    .background(Color.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .alert("无法分享", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(shareError ?? "")
        }
    }

    // MARK: - 媒体预览

    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label {
                    Text("实拍照片与视频")
                        .font(.headline)
                } icon: {
                    Image(systemName: "camera.fill")
                        .foregroundColor(AppTheme.primary)
                }
                Spacer()
                if house.hasPhoto || house.hasVideo {
                    if isSelecting {
                        // 多选模式：全选（已全选时点击清空）+ 取消按钮（同款品牌色胶囊）
                        HStack(spacing: 8) {
                            Button {
                                toggleSelectAll()
                            } label: {
                                Label(selectedMediaNames.count == house.mediaItems.count ? "取消全选" : "全选", systemImage: "checkmark.circle")
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(AppTheme.primary)
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            Button {
                                exitSelecting()
                            } label: {
                                Label("取消", systemImage: "xmark")
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(AppTheme.primary)
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        // 多选入口（胶囊形，大小随文字自适应）
                        Button {
                            isSelecting = true
                        } label: {
                            Label("多选", systemImage: "checkmark.circle")
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(AppTheme.primary)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if house.photos.isEmpty && house.videos.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundColor(.secondary)
                    Text("暂无照片和视频，点「编辑」添加")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                if !house.photos.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        // 用唯一 fileName 作标识（MediaItem.id 在 SwiftData 新对象上可能相同）
                        ForEach(Array(house.photos.enumerated()), id: \.element.fileName) { index, media in
                            // 固定正方形格子，内容缩放裁切填满，横屏照片也不会溢出重叠
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(
                                    MediaThumbView(media: media, roomKey: house.mediaRoomKey)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .topLeading) {
                                    if isSelecting {
                                        Image(systemName: selectedMediaNames.contains(media.fileName) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 20))
                                            .foregroundColor(.white)
                                            .shadow(radius: 2)
                                            .padding(5)
                                    }
                                }
                                .onTapGesture {
                                    if isSelecting {
                                        toggleSelect(media)
                                    } else {
                                        previewRoute = PhotoPreviewRoute(index: index)
                                    }
                                }
                        }
                    }
                }

                if !house.videos.isEmpty {
                    ForEach(house.videos, id: \.fileName) { media in
                        if isSelecting {
                            // 多选模式下视频显示为缩略图，点击选中
                            Color.clear
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                .overlay(
                                    MediaThumbView(media: media, roomKey: house.mediaRoomKey)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(alignment: .topLeading) {
                                    Image(systemName: selectedMediaNames.contains(media.fileName) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundColor(.white)
                                        .shadow(radius: 2)
                                        .padding(5)
                                }
                                .onTapGesture {
                                    toggleSelect(media)
                                }
                        } else {
                            // 视频条目：缩略图 + 播放三角（竖版视频完整显示首帧，不再被误认成图片），点击全屏播放
                            HouseDetailVideoItem(media: media, roomKey: house.mediaRoomKey)
                                .frame(height: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }

                // 多选模式：底部保存按钮
                if isSelecting {
                    Button {
                        saveSelectedToAlbum()
                    } label: {
                        Label(selectedMediaNames.isEmpty ? "请选择要保存的照片或视频" : "保存到相册（\(selectedMediaNames.count)）", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.primary)
                    .disabled(selectedMediaNames.isEmpty)
                }
            }
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .alert("保存到相册", isPresented: Binding(
            get: { saveTip != nil },
            set: { if !$0 { saveTip = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(saveTip ?? "")
        }
    }

    // MARK: - 多选 / 保存到相册

    /// v1.30：多选模式一键全选 / 取消全选（已全选时再点则清空）
    private func toggleSelectAll() {
        let all = Set(house.mediaItems.map { $0.fileName })
        if !all.isEmpty, selectedMediaNames.count == all.count {
            selectedMediaNames.removeAll()
        } else {
            selectedMediaNames = all
        }
    }

    private func toggleSelect(_ media: MediaItem) {
        if selectedMediaNames.contains(media.fileName) {
            selectedMediaNames.remove(media.fileName)
        } else {
            selectedMediaNames.insert(media.fileName)
        }
    }

    private func exitSelecting() {
        isSelecting = false
        selectedMediaNames.removeAll()
    }

    private func saveSelectedToAlbum() {
        let selected = house.mediaItems.filter { selectedMediaNames.contains($0.fileName) }
        guard !selected.isEmpty else { return }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            switch status {
            case .authorized, .limited:
                PHPhotoLibrary.shared().performChanges {
                    for media in selected {
                        let url = MediaStore.url(for: media.fileName, roomKey: house.mediaRoomKey)
                        if media.kind == "image",
                           let image = UIImage(contentsOfFile: url.path) {
                            PHAssetChangeRequest.creationRequestForAsset(from: image)
                        } else if media.kind == "video",
                                  FileManager.default.fileExists(atPath: url.path) {
                            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                        }
                    }
                } completionHandler: { success, error in
                    DispatchQueue.main.async {
                        if success {
                            saveTip = "已保存 \(selected.count) 个到相册"
                            exitSelecting()
                        } else {
                            saveTip = "保存失败：\(error?.localizedDescription ?? "未知错误")"
                        }
                    }
                }
            default:
                DispatchQueue.main.async {
                    saveTip = "没有相册写入权限，请在 设置 → 隐私与安全 → 照片 中允许"
                }
            }
        }
    }

    // MARK: - 房源信息

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(house.displayRoomNo)
                        .font(.title2.weight(.bold))
                        .foregroundColor(AppTheme.primary)
                    Text("\(house.towerLabel) · \(house.layout.isEmpty ? "户型未填" : house.layout)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                StatusBadge(status: house.status)
            }
            .padding(.bottom, 12)

            Divider()

            infoRow(icon: "person.fill", title: "房东", value: house.landlord.isEmpty ? "—" : house.landlord)
            infoRow(icon: "yensign", title: "价格", value: house.priceText)
            infoRow(icon: "key.fill", title: "密码", value: house.password.isEmpty ? "—" : house.password)
            infoRow(icon: "text.alignleft", title: "备注", value: house.remark.isEmpty ? "—" : house.remark)
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func infoRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundColor(AppTheme.primary)
                .frame(width: 22)
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 9)
    }

    // MARK: - 操作区（三个按钮上下继续缩窄）

    private var actionCard: some View {
        VStack(spacing: 8) {
            Button {
                showStatusConfirm = true
            } label: {
                Label {
                    Text(house.status == .available ? "标记为已租" : "标记为待租")
                } icon: {
                    Image(systemName: house.status == .available ? "checkmark.circle" : "arrow.uturn.backward.circle")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(house.status == .available ? Color(red: 0.24, green: 0.58, blue: 0.34) : Color(red: 0.47, green: 0.49, blue: 0.55))

            Button {
                shareHouseCard()
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)

            // v1.13 需求11：一键转发朋友圈（图片自动取前 9 张；有视频+图片时弹二级菜单选择）
            Button {
                forwardToMoments()
            } label: {
                Label("转发朋友圈", systemImage: "heart.circle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .disabled(isForwarding)

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("删除房源", systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 操作

    private func setStatus(_ newStatus: HouseStatus) {
        house.status = newStatus
        house.updatedAt = Date()
        try? modelContext.save()
        NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
    }

    private func deleteHouse() {
        // v1.7：删除改为软删除进回收站——不再同步删除照片/视频文件；
        // 文件（整个房号目录 + 分享缓存）在「设置 → 回收站」彻底删除该房源时才移除
        guard let ctx = houseModelContext else { return }
        house.isDeleted = true
        house.deletedAt = Date()
        try? ctx.save()
        NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
        dismiss()
    }

    /// 分享入口（v1.21）：先做前置校验（配置 / 素材），再弹「脱敏 / 完整」选择器
    private func shareHouseCard() {
        guard let config = CosConfig.load(), config.isValid else {
            shareError = "请先到「设置 → 房源分享 → 远程配置」填写云存储配置（腾讯云 COS），再分享卡片链接"
            return
        }
        guard !house.mediaItems.isEmpty else {
            shareError = "这套房源还没有照片或视频，先编辑添加素材再分享"
            return
        }
        showShareModePicker = true
    }

    /// 按模式生成分享卡片链接并弹系统分享面板
    /// 注意：Task 内只传值类型（fileName/kind 数组 + 字符串字段），绝不直接访问 SwiftData @Model，
    /// 否则跨线程读取模型会闪退（分享闪退修复根因）
    private func startShare(mode: ShareMode) {
        guard let config = CosConfig.load(), config.isValid else {
            shareError = "请先到「设置 → 房源分享 → 远程配置」填写云存储配置（腾讯云 COS），再分享卡片链接"
            return
        }
        // 先在主线程把所有数据拷成值类型，Task 里不再触碰 SwiftData 模型
        let files = house.mediaItems.map { ShareMediaFile(name: $0.fileName, kind: $0.kind) }
        let roomKey = house.mediaRoomKey
        let profile = CosUploader.loadShareProfile()
        let info = ShareHouseInfo(
            displayRoomNo: house.displayRoomNo,
            towerLabel: house.towerLabel,
            layout: house.layout,
            statusLabel: house.status.label,
            priceText: house.priceText,
            landlord: house.landlord,
            password: house.password,
            remark: house.remark,
            name: profile.name,
            phone: profile.phone
        )
        isSharing = true
        shareProgress = 0
        Task {
            do {
                let url = try await CosUploader.shareCard(mediaFiles: files, roomKey: roomKey, info: info, mode: mode, config: config) { p in
                    Task { @MainActor in self.shareProgress = p }
                }
                await MainActor.run {
                    isSharing = false
                    shareItems = [url]
                    showShare = true
                }
            } catch {
                await MainActor.run {
                    isSharing = false
                    shareError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - v1.13 需求11：转发朋友圈

    /// 转发朋友圈入口：有照片+视频 → 弹二级菜单选择；只有照片 → 直接分享前 9 张图片；只有视频 → 直接分享视频
    private func forwardToMoments() {
        guard !house.mediaItems.isEmpty else {
            shareError = "这套房源还没有照片或视频，先编辑添加素材再转发"
            return
        }
        let hasImages = house.photos.count > 0
        let hasVideos = house.videos.count > 0
        if hasImages && hasVideos {
            showForwardMenu = true
        } else if hasImages {
            forwardImages()
        } else {
            forwardVideos()
        }
    }

    /// 转发图片：自动取前 9 张（不足 9 张取全部），走系统分享面板
    private func forwardImages() {
        let images = house.photos.prefix(9)
        guard !images.isEmpty else {
            shareError = "这套房源没有照片"
            return
        }
        let urls = images.map { MediaStore.url(for: $0.fileName, roomKey: house.mediaRoomKey) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            shareError = "照片文件不存在，请重新添加"
            return
        }
        isForwarding = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isForwarding = false
            shareItems = urls
            showShare = true
        }
    }

    /// 转发视频：分享全部视频文件，走系统分享面板
    private func forwardVideos() {
        let urls = house.videos.map { MediaStore.url(for: $0.fileName, roomKey: house.mediaRoomKey) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            shareError = "视频文件不存在，请重新添加"
            return
        }
        isForwarding = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isForwarding = false
            shareItems = urls
            showShare = true
        }
    }
}

// MARK: - 分享值类型（Task 内安全传递 + 分享缓存 JSON 编解码，不触碰 SwiftData 模型）

struct ShareMediaFile: Hashable, Codable {
    let name: String
    let kind: String
}

struct ShareHouseInfo: Equatable, Codable {
    let displayRoomNo: String
    let towerLabel: String
    let layout: String
    let statusLabel: String
    let priceText: String
    let landlord: String
    let password: String
    let remark: String
    let name: String?   // v1.21：分享名片姓名（设置页可编辑；Optional 兼容旧版缓存 JSON，缺失时按默认值渲染）
    let phone: String?  // v1.21：分享名片电话
}

// MARK: - 照片大图预览路由

struct PhotoPreviewRoute: Identifiable {
    let id = UUID()
    let index: Int
}

// MARK: - 照片大图预览

struct PhotoPreviewView: View {
    let photos: [MediaItem]
    let startIndex: Int
    let roomKey: String
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var saveMessage: String?

    init(photos: [MediaItem], startIndex: Int, roomKey: String) {
        self.photos = photos
        self.startIndex = startIndex
        self.roomKey = roomKey
        _currentIndex = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(photos.enumerated()), id: \.element.fileName) { index, media in
                    if let image = UIImage(contentsOfFile: MediaStore.url(for: media.fileName, roomKey: roomKey).path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .tag(index)
                            // 长按弹出菜单：保存到相册（和微信一致）
                            .contextMenu {
                                Button {
                                    saveImageToAlbum(image)
                                } label: {
                                    Label("保存到相册", systemImage: "square.and.arrow.down")
                                }
                            }
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(18)
            }
        }
        .statusBarHidden()
        .alert("保存到相册", isPresented: Binding(
            get: { saveMessage != nil },
            set: { if !$0 { saveMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(saveMessage ?? "")
        }
    }

    /// 保存当前图片到系统相册（仅新增写入权限）
    private func saveImageToAlbum(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            switch status {
            case .authorized, .limited:
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                } completionHandler: { success, error in
                    DispatchQueue.main.async {
                        saveMessage = success
                            ? "已保存到相册"
                            : "保存失败：\(error?.localizedDescription ?? "未知错误")"
                    }
                }
            default:
                DispatchQueue.main.async {
                    saveMessage = "没有相册写入权限，请在 设置 → 隐私与安全 → 照片 中允许"
                }
            }
        }
    }
}
