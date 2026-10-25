import SwiftUI
import SwiftData
import AVKit
import Photos

struct HouseDetailView: View {
    /// 房源板块专属 context（独立 HouseStore 容器，由 App 注入）
    @Environment(\.houseModelContext) private var houseModelContext
    /// v1.17 需求1：主容器 context（DealRecord/Property 等经营数据所在容器）。
    /// 闪退根因：成交/在租/退租的关联查询此前误用了 houseModelContext（HouseStore 只注册 House/MediaItem），
    /// 在独立容器查未注册模型触发 SwiftData 崩溃——必须用主容器查。
    @Environment(\.modelContext) private var mainCtx
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
    // v1.15 需求1：一键保存到相册（独立状态，避免与多选「保存选中」的 saveTip/alert 冲突）
    @State private var showSaveConfirm = false
    @State private var isSavingMedia = false
    @State private var saveAllTip: String?
    // v1.36 需求2：详情页「成交/在租/退租」关联查看（只读）
    @State private var recordViewItem: RecordViewItem? = nil
    @State private var recordPickKind: RecordPickKind? = nil
    @State private var recordPickList: [RecordViewItem] = []
    // v1.36 需求1：彻底删除（本地+云端）
    @State private var isDeletingCloud = false
    // v1.19：纯云端房源下载到本地
    @State private var isDownloading = false
    @State private var cloudDeleteMessage: String?
    @State private var deleteResultMessage: String?   // v1.19 补全：删除成功提示（区分 本地/本地+云端/云端）

    // v1.19：把滚动主体拆为独立子视图，避免 Swift 编译器对整个 body 一次类型检查超时
    private var detailScroll: some View {
        ScrollView {
            VStack(spacing: 14) {
                mediaSection
                infoCard
                actionCard
            }
            .padding(16)
        }
    }

    // v1.19 补全：把两个大块 overlay 提出为独立 @ViewBuilder，避免 body 一次类型检查超时
    @ViewBuilder private var shareOverlayView: some View {
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
    @ViewBuilder private var saveOverlayView: some View {
        if isSavingMedia {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text("正在保存到相册…")
                        .font(.footnote)
                        .foregroundColor(.white)
                }
                .padding(20)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        } else if let tip = saveAllTip {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.green)
                    Text(tip)
                        .font(.footnote)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                    Button("好") { saveAllTip = nil }
                        .font(.footnote)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 6)
                        .background(Color.white)
                        .foregroundColor(.black)
                        .clipShape(Capsule())
                }
                .padding(20)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var sheetLayer: some View {
        detailScroll
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
    }

    private var dialogLayer: some View {
        sheetLayer
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
                Button("彻底删除", role: .destructive) { deleteHouse() }
                Button("取消", role: .cancel) {}
            } message: {
                // v1.19 补全：删除确认提示按当前存储位置动态显示（是否删云端一目了然）
                Text(deleteConfirmMessage)
            }
            .confirmationDialog("选择分享方式", isPresented: $showShareModePicker, titleVisibility: .visible) {
                // v1.21：脱敏版隐藏房号/价格/房东，发给找房客户；完整版显示全部信息，发给同事
                Button("发给客户（隐藏版）") { startShare(mode: .masked) }
                Button("发给同事（完整版）") { startShare(mode: .full) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("隐藏版只显示户型、位置和您的联系方式；完整版额外显示房号、价格、房东和密码。")
            }
            // v1.15 需求1：一键保存确认（显示将保存的照片/视频数量）
            .confirmationDialog("保存到手机相册？", isPresented: $showSaveConfirm, titleVisibility: .visible) {
                Button("保存", role: .destructive) { saveAllToAlbum() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将把本房源全部 \(house.photos.count) 张照片、\(house.videos.count) 个视频保存到系统相册。")
            }
            .fullScreenCover(item: $previewRoute) { route in
                PhotoPreviewView(photos: house.photos, startIndex: route.index, roomKey: house.mediaRoomKey)
            }
            .overlay {
                shareOverlayView
            }
            // v1.15 需求1：一键保存中 + 保存完成提示（overlay 卡片，不占 alert 链，避开 iOS 17 多弹窗覆盖问题）
            .overlay {
                saveOverlayView
            }
    }

    var body: some View {
        dialogLayer
        .alert("无法分享", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(shareError ?? "")
        }
        // v1.36 需求2：多条关联记录时弹窗选择打开哪条
        .confirmationDialog("选择记录", isPresented: Binding(
            get: { recordPickKind != nil },
            set: { if !$0 { recordPickKind = nil } }
        ), titleVisibility: .visible) {
            ForEach(recordPickList) { item in
                Button(item.title) { recordViewItem = item }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该房号关联到多条记录，选择要查看的一条")
        }
        .sheet(item: $recordViewItem) { item in
            NavigationStack {
                RecordViewerContainer(item: item)
            }
            .presentationDetents([.medium, .large])
        }
        // v1.36 需求1：本地已删、云端删除失败的分开提示（下载/自动下载提示也走这里，不关闭页面）
        .alert("提示", isPresented: Binding(
            get: { cloudDeleteMessage != nil },
            set: { if !$0 { cloudDeleteMessage = nil } }
        )) {
            Button("好") {}
        } message: {
            Text(cloudDeleteMessage ?? "")
        }
        // v1.19 补全：删除成功提示（区分 本地 / 本地+云端 / 云端），点「好」返回列表
        .alert("删除房源", isPresented: Binding(
            get: { deleteResultMessage != nil },
            set: { if !$0 { deleteResultMessage = nil } }
        )) {
            Button("好") { dismiss() }
        } message: {
            Text(deleteResultMessage ?? "")
        }
        .overlay {
            if isDeletingCloud {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("本地已删除，正在同步删除云端…")
                            .font(.footnote)
                            .foregroundColor(.white)
                    }
                    .padding(20)
                    .background(Color.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
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
                ensureLocalMedia {
                    shareHouseCard()
                }
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)

            // v1.19：纯云端房源 → 下载到本地（下载后可编辑/分享/保存）
            if house.cloudStatus == .cloud {
                Button {
                    downloadHouseToLocal()
                } label: {
                    Label(isDownloading ? "下载中…" : "下载到本地", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .disabled(isDownloading)
            }

            // v1.15 需求1：一键保存（全部图片+视频保存到手机相册，先弹确认）
            Button {
                ensureLocalMedia {
                    confirmSaveToAlbum()
                }
            } label: {
                // v1.15 需求1：转存到微信 → 一键保存（全部图片+视频保存到手机相册）
                Label("一键保存", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .disabled(isSavingMedia)

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("删除房源", systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)

            // v1.36 需求2：成交/在租/退租（按房号关联；无记录置灰；多条弹窗选择；打开只读表单）
            HStack(spacing: 8) {
                recordButton("成交", kind: .deal, icon: "doc.text")
                recordButton("在租", kind: .renting, icon: "house")
                recordButton("退租", kind: .terminated, icon: "arrow.backward.circle")   // v1.37b：door.left.handled 是 iOS16+ 符号，旧系统显示空白 → 换 iOS13+ 就有
            }
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 操作

    private func setStatus(_ newStatus: HouseStatus) {
        house.status = newStatus
        house.updatedAt = Date()
        // v1.19：切换状态也刷新最后更新时间并同步云端
        house.lastUpdatedAt = Date()
        try? modelContext.save()
        NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
        if let config = CosConfig.load() {
            let record = CloudHouseSync.record(from: house, username: CloudUser.username)
            Task {
                try? await CloudHouseSync.upload(record: record, config: config)
            }
        }
    }

    // MARK: - v1.19 纯云端房源：下载到本地 / 操作前自动下载

    /// 手动下载：把云端 h/<房号>/ 的媒体拉到本地（纯云端房源专用）
    private func downloadHouseToLocal() {
        guard let config = CosConfig.load() else {
            cloudDeleteMessage = "未配置云存储，无法下载云端房源";
            return
        }
        isDownloading = true
        let roomKey = house.mediaRoomKey
        Task {
            do {
                let files = try await CosUploader.downloadHouseMedia(roomKey: roomKey, config: config)
                await MainActor.run {
                    for f in files {
                        let item = MediaItem(fileName: f.fileName, kind: f.kind)
                        item.house = house
                        modelContext.insert(item)
                    }
                    house.cloudStatus = .both
                    try? modelContext.save()
                    isDownloading = false
                    cloudDeleteMessage = "已下载 \(files.count) 个媒体到本地，现在可以编辑、分享或一键保存了。";
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    cloudDeleteMessage = "下载失败：\(error.localizedDescription)";
                }
            }
        }
    }

    /// 操作前自动下载：分享 / 一键保存 / 编辑前若为纯云端房源，先自动拉到本地（v1.19 需求11）
    private func ensureLocalMedia(_ action: @escaping () -> Void) {
        if !house.mediaItems.isEmpty || house.cloudStatus != .cloud {
            action()
            return
        }
        guard let config = CosConfig.load() else { action(); return }
        isDownloading = true
        let roomKey = house.mediaRoomKey
        Task {
            do {
                let files = try await CosUploader.downloadHouseMedia(roomKey: roomKey, config: config)
                await MainActor.run {
                    for f in files {
                        let item = MediaItem(fileName: f.fileName, kind: f.kind)
                        item.house = house
                        modelContext.insert(item)
                    }
                    house.cloudStatus = .both
                    try? modelContext.save()
                    isDownloading = false
                    cloudDeleteMessage = "云端房源已自动下载到本地，请再点一次刚才的操作。";
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    cloudDeleteMessage = "下载失败：\(error.localizedDescription)";
                }
            }
        }
    }

    /// v1.19 补全：删除确认文案按当前存储位置动态生成（本地/云端/双端一目了然）
    private var deleteConfirmMessage: String {
        switch house.cloudStatus {
        case .both:
            return "将删除「本地 + 云端」：本地照片视频、数据库记录，以及云端 h/\(house.mediaRoomKey)/ 目录一并清除，不可恢复。备份镜像 backups/media 保留。"
        case .local:
            return "将删除本地房源（未上传云端）：本地照片视频、数据库记录一并清除，不可恢复。备份镜像 backups/media 保留。"
        case .cloud:
            return "将删除云端同步副本：该房本机无媒体，将从云端 h/\(house.mediaRoomKey)/ 清除，不可恢复。"
        }
    }

    private func deleteHouse() {
        // v1.36 需求1：删除 = 彻底删除（本地文件+数据库记录+云端桶 h/<房号>/ 一并删除，不可恢复）
        // 保留二次确认弹窗；backups/media 镜像保留（自动备份 zip 引用，删了旧备份恢复缺图）
        guard let ctx = houseModelContext else { return }
        let roomKey = house.mediaRoomKey
        let config = CosConfig.load()
        let wasCloud = house.cloudStatus   // v1.19 补全：记录删除前存储位置，用于成功提示
        // 1) 本地彻底删除：整个房号目录 + 分享缓存 + 数据库记录
        MediaStore.deleteHouseDirectory(roomKey: roomKey)
        ctx.delete(house)
        try? ctx.save()
        NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
        // 2) 云端删除（异步；本地成功云端失败 → 分开提示 + 写操作日志）
        guard let config = config, config.isValid else {
            BackupLogStore.log(category: "删除", action: "删除云端房源", result: "跳过", detail: "未配置云存储 \(roomKey)", cloud: true)
            // v1.19 补全：删除成功提示区分存储位置
            deleteResultMessage = wasCloud == .both ? "已删除本地 + 云端房源" : "已删除本地房源"
            return
        }
        isDeletingCloud = true
        Task {
            do {
                try await CloudBackupService.deleteHouseRemoteFolder(roomKey: roomKey, config: config)
                try? await CloudHouseSync.delete(roomKey: roomKey, config: config)   // v1.19 补全：同步从云端账本移除
                BackupLogStore.log(category: "删除", action: "删除云端房源", result: "成功", detail: roomKey, cloud: true)
                await MainActor.run {
                    isDeletingCloud = false
                    deleteResultMessage = wasCloud == .cloud ? "已删除云端房源" : "已删除本地 + 云端房源"
                }
            } catch {
                BackupLogStore.log(category: "删除", action: "删除云端房源", result: "失败", detail: "\(roomKey) \(error.localizedDescription)", cloud: true)
                await MainActor.run {
                    isDeletingCloud = false
                    cloudDeleteMessage = "本地已删除；云端删除失败：\(error.localizedDescription)。可在「管理后台 → 桶管理」手动清理 h/\(roomKey)/"
                }
            }
        }
    }

    // MARK: - v1.36 需求2：成交/在租/退租 关联查看（只读）

    private func recordButton(_ title: String, kind: RecordPickKind, icon: String) -> some View {
        let count = recordCount(kind)
        return Button {
            openRecord(kind)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 15))
                Text(title).font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            // v1.37b：恢复「有记录/无记录」颜色区分（有记录深底、无记录浅底置灰），形状统一胶囊
            .background(count > 0 ? Color(.secondarySystemBackground) : Color(.tertiarySystemFill))
            .foregroundStyle(count > 0 ? Color.primary : Color.secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
    }

    /// 按房号统计关联记录数（成交 / 在租 / 退租；单小区按房号精确匹配，去空格容错）
    private func recordCount(_ kind: RecordPickKind) -> Int {
        switch kind {
        case .deal: return fetchDeals(room: house.displayRoomNo).count
        case .renting: return fetchProperties(room: house.displayRoomNo, terminated: false).count
        case .terminated: return fetchProperties(room: house.displayRoomNo, terminated: true).count
        }
    }

    private func openRecord(_ kind: RecordPickKind) {
        let items: [RecordViewItem]
        switch kind {
        case .deal: items = fetchDeals(room: house.displayRoomNo).map { RecordViewItem(kind: .deal($0)) }
        case .renting: items = fetchProperties(room: house.displayRoomNo, terminated: false).map { RecordViewItem(kind: .property($0)) }
        case .terminated: items = fetchProperties(room: house.displayRoomNo, terminated: true).map { RecordViewItem(kind: .property($0)) }
        }
        if items.isEmpty { return }
        if items.count == 1 { recordViewItem = items[0] }
        else { recordPickList = items; recordPickKind = kind }
    }

    private func fetchDeals(room: String) -> [DealRecord] {
        let normalized = Self.normalizedRoom(room)
        let desc = FetchDescriptor<DealRecord>(predicate: #Predicate<DealRecord> { $0.isDeleted == false })
        // v1.17 需求1：用主容器查询（DealRecord 在主容器；HouseStore 无此模型）
        let all = (try? mainCtx.fetch(desc)) ?? []
        return all.filter { Self.normalizedRoom($0.roomNumber) == normalized }
    }

    private func fetchProperties(room: String, terminated: Bool) -> [Property] {
        let normalized = Self.normalizedRoom(room)
        let desc = FetchDescriptor<Property>(predicate: #Predicate<Property> { $0.isDeleted == false })
        // v1.17 需求1：用主容器查询（Property 在主容器）
        let all = (try? mainCtx.fetch(desc)) ?? []
        return all.filter { $0.isTerminated == terminated && Self.normalizedRoom($0.roomNumber) == normalized }
    }

    private static func normalizedRoom(_ s: String) -> String {
        s.filter { !$0.isWhitespace }
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

    // MARK: - v1.15 需求1：一键保存（全部图片+视频保存到手机相册）

    /// 确认弹窗：统计本房源可保存的照片/视频数量，弹窗确认后写入相册
    private func confirmSaveToAlbum() {
        guard !house.mediaItems.isEmpty else {
            shareError = "这套房源还没有照片或视频，先编辑添加素材再保存"
            return
        }
        showSaveConfirm = true
    }

    /// 一键保存：全部照片 + 全部视频（不再是前 9 张）保存到系统相册。
    /// 用 Photos 框架的 performChanges 批量创建资源（add-only 权限即可，无需读图占内存）。
    private func saveAllToAlbum() {
        let imageURLs = house.photos
            .map { MediaStore.url(for: $0.fileName, roomKey: house.mediaRoomKey) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let videoURLs = house.videos
            .map { MediaStore.url(for: $0.fileName, roomKey: house.mediaRoomKey) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let urls = imageURLs + videoURLs
        guard !urls.isEmpty else {
            shareError = "照片或视频文件不存在，请重新添加"
            return
        }
        isSavingMedia = true
        Task {
            do {
                try await saveMediaUrls(urls)
                await MainActor.run {
                    isSavingMedia = false
                    saveAllTip = "已保存到相册：\(imageURLs.count) 张照片、\(videoURLs.count) 个视频"
                }
            } catch {
                await MainActor.run {
                    isSavingMedia = false
                    shareError = "保存失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 请求相册写入权限（add-only 仅需「添加照片」权限），通过后批量写入
    private func saveMediaUrls(_ urls: [URL]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw BackupV5Error.invalidBackup("未获得相册权限，请到「设置 → 隐私 → 照片」允许本 App 添加照片")
        }
        try await PHPhotoLibrary.shared().performChanges {
            for url in urls {
                if url.pathExtension.lowercased() == "mp4" || url.pathExtension.lowercased() == "mov" || url.pathExtension.lowercased() == "m4v" {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }
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

// MARK: - v1.36 需求2：成交/在租/退租 只读记录查看

/// 记录查看目标（成交记录 / 收租记录），sheet(item:) 需要 Identifiable
struct RecordViewItem: Identifiable {
    let id = UUID()
    let kind: Kind
    enum Kind { case deal(DealRecord), property(Property) }

    var title: String {
        switch kind {
        case .deal(let d): return "成交记录 · \(d.roomNumber)"
        case .property(let p): return "收租记录 · \(p.roomNumber)（\(p.isTerminated ? "退租" : "在租")）"
        }
    }
}

enum RecordPickKind { case deal, renting, terminated }

/// 只读记录表单容器（按类型渲染；不可编辑）
struct RecordViewerContainer: View {
    let item: RecordViewItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch item.kind {
            case .deal(let d): DealRecordViewer(deal: d)
            case .property(let p): PropertyViewer(property: p)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("关闭") { dismiss() }
            }
        }
    }
}

/// 成交记录只读表单
struct DealRecordViewer: View {
    let deal: DealRecord

    private func yuan(_ v: Double) -> String {
        v == 0 ? "—" : "¥\(String(format: "%.0f", v))"
    }

    var body: some View {
        Form {
            Section("成交记录") {
                LabeledContent("房号", value: deal.roomNumber)
                LabeledContent("成交日期", value: deal.date.formatted(date: .numeric, time: .omitted))
                LabeledContent("房东", value: deal.landlord.isEmpty ? "—" : deal.landlord)
                LabeledContent("户型", value: deal.unitType.isEmpty ? "—" : deal.unitType)
            }
            Section("租约") {
                LabeledContent("起租日期", value: deal.leaseStart.formatted(date: .numeric, time: .omitted))
                LabeledContent("到期日期", value: deal.leaseEnd.formatted(date: .numeric, time: .omitted))
                LabeledContent("租期", value: deal.leaseDuration.isEmpty ? "—" : deal.leaseDuration)
                if let due = deal.rentDueDay {
                    LabeledContent("交租日", value: "每月 \(due) 号")
                }
            }
            Section("费用") {
                LabeledContent("月租金", value: yuan(deal.rent))
                LabeledContent("押金", value: yuan(deal.deposit))
                LabeledContent("业主中介费", value: yuan(deal.agentFeeLandlord))
                LabeledContent("租客中介费", value: yuan(deal.agentFeeTenant))
                LabeledContent("总费用", value: yuan(deal.totalFee))
            }
            Section("其他") {
                LabeledContent("经纪人", value: deal.manager.isEmpty ? "—" : deal.manager)
                LabeledContent("来源", value: deal.source.isEmpty ? "—" : deal.source)
                if !deal.notes.isEmpty {
                    LabeledContent("备注", value: deal.notes)
                }
            }
        }
        .navigationTitle("成交记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 收租房源（在租/退租）只读表单
struct PropertyViewer: View {
    let property: Property

    private func yuan(_ v: Double) -> String {
        v == 0 ? "—" : "¥\(String(format: "%.0f", v))"
    }

    var body: some View {
        Form {
            Section("状态") {
                LabeledContent("状态", value: property.isTerminated ? "已退租" : "在租中")
                if property.isTerminated {
                    if let date = property.terminationDate {
                        LabeledContent("退租日期", value: date.formatted(date: .numeric, time: .omitted))
                    }
                    LabeledContent("退租原因", value: property.terminationReason.isEmpty ? "—" : property.terminationReason)
                }
            }
            Section("基本信息") {
                LabeledContent("房号", value: property.roomNumber)
                LabeledContent("房东", value: property.landlord.isEmpty ? "—" : property.landlord)
                LabeledContent("户型", value: property.unitType.isEmpty ? "—" : property.unitType)
                LabeledContent("管理类型", value: property.typeDisplayName)
            }
            Section("租约与费用") {
                LabeledContent("月租金", value: yuan(property.rent))
                LabeledContent("押金", value: yuan(property.deposit))
                LabeledContent("预付", value: yuan(property.prepayment))
                LabeledContent("起租日期", value: property.leaseStart.isEmpty ? "—" : property.leaseStart)
                LabeledContent("到期日期", value: property.leaseEnd.isEmpty ? "—" : property.leaseEnd)
                LabeledContent("租期", value: property.leaseDuration.isEmpty ? "—" : property.leaseDuration)
                LabeledContent("交租日", value: "每月 \(property.rentDueDay) 号")
            }
            Section("计量底数") {
                LabeledContent("水表底数", value: "\(property.waterMeterBase)")
                LabeledContent("电表底数", value: "\(property.electricMeterBase)")
            }
            if !property.notes.isEmpty {
                Section("备注") {
                    Text(property.notes)
                }
            }
        }
        .navigationTitle("收租记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}
