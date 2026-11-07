import SwiftUI
import UIKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import Photos

// MARK: - v2.20 云端同步未读标记

/// 云端同步把房源「新增」或「被云端覆盖修改」后，卡片画红框提示；打开一次详情页即清除。
/// 存 UserDefaults（房号 key 数组），不占 SwiftData schema，升级无需迁移。
enum UnreadCloudHouseStore {
    private static let storageKey = "unread_cloud_house_keys"
    static let didChange = Notification.Name("unreadCloudHouseKeysChanged")

    static func all() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
    }

    static func isUnread(_ roomKey: String) -> Bool {
        all().contains(roomKey)
    }

    static func mark(_ roomKeys: [String]) {
        guard !roomKeys.isEmpty else { return }
        var set = all()
        for key in roomKeys where !key.isEmpty { set.insert(key) }
        UserDefaults.standard.set(Array(set), forKey: storageKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func clear(_ roomKey: String) {
        var set = all()
        guard set.contains(roomKey) else { return }
        set.remove(roomKey)
        UserDefaults.standard.set(Array(set), forKey: storageKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

// MARK: - v2.24 同步失败标记

/// 房源「账本推送云端失败」的轻量标记（存 UserDefaults，成功推送后自动清除）。
/// 用途：卡片上标「未同步」，让用户知道这次编辑只落在本机、云端还没收到。
enum SyncFailStore {
    private static let storageKey = "house_sync_failed_keys"
    static let didChange = Notification.Name("houseSyncFailedKeysChanged")

    static func all() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? []) }
    static func isFailed(_ roomKey: String) -> Bool { all().contains(roomKey) }

    static func mark(_ roomKey: String) {
        guard !roomKey.isEmpty else { return }
        var set = all(); set.insert(roomKey)
        UserDefaults.standard.set(Array(set), forKey: storageKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func clear(_ roomKey: String) {
        var set = all()
        guard set.contains(roomKey) else { return }
        set.remove(roomKey)
        UserDefaults.standard.set(Array(set), forKey: storageKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

// MARK: - 主题色（合体后统一跟随主 App 深绿主题：主题绿主色 + 主题绿强调 + 统一底色）

enum AppTheme {
    /// 深绿主色（对齐主板块 themeSidebar）
    static let primary = Color.themeSidebar
    /// 统一底色（对齐主板块 themeBg）
    static let background = Color.themeBg
    /// 价格强调（对齐主板块 themeAccent）
    static let accent = Color.themeAccent
}

// MARK: - 状态徽章

struct StatusBadge: View {
    let status: HouseStatus

    var body: some View {
        Text(status.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundColor(.white)
            .background(badgeColor)
            .clipShape(Capsule())
    }

    private var badgeColor: Color {
        switch status {
        case .available: return Color(red: 0.24, green: 0.58, blue: 0.34)
        case .rented: return Color(red: 0.47, green: 0.49, blue: 0.55)
        }
    }
}

// MARK: - 视频首帧缩略图（异步提取第一帧，避免灰色占位）

struct VideoThumbnailView: View {
    let url: URL
    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.gray.opacity(0.2)
                    ProgressView()
                }
            }
        }
        .onAppear(perform: loadFirstFrame)
    }

    private func loadFirstFrame() {
        guard thumbnail == nil else { return }
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
            guard let cgImage else { return }
            DispatchQueue.main.async {
                thumbnail = UIImage(cgImage: cgImage)
            }
        }
    }
}

// MARK: - 媒体缩略图

struct MediaThumbView: View {
    let media: MediaItem
    let roomKey: String

    var body: some View {
        if media.kind == "video" {
            ZStack {
                VideoThumbnailView(url: MediaStore.url(for: media.fileName, roomKey: roomKey))
                // 播放三角：缩小 + 半透明，不遮挡画面
                Image(systemName: "play.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.72))
                    .shadow(radius: 2)
            }
        } else {
            thumbImage
        }
    }

    private var thumbImage: some View {
        Group {
            if let image = UIImage(contentsOfFile: MediaStore.url(for: media.fileName, roomKey: roomKey).path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.gray.opacity(0.2)
                    Image(systemName: "photo")
                        .foregroundColor(.gray)
                }
            }
        }
    }
}

// MARK: - v1.42 房源上传/同步动态进度（卡片底部细进度条）
// 单例发布器：保存上传媒体、云端同步下载/补传时写入进度，房源卡片按房号匹配后显示细进度条。
@MainActor
final class HouseSyncProgress: ObservableObject {
    static let shared = HouseSyncProgress()
    @Published var roomKey: String?
    @Published var direction: Direction = .upload
    @Published var progress: Double = 0     // 0...1
    @Published var label: String = ""

    enum Direction {
        case upload      // 本机 → 云端（上传）
        case download    // 云端 → 本机（同步下载）
        var text: String { self == .upload ? "上传中" : "同步中" }
    }

    /// 活跃任务计数：并发上传/同步各自 begin 一次 +1，全部结束（end 归零）才清空显示。
    /// v2.4 修复：此前「保存上传媒体」与「同步云端账本」两个并发 Task 共用单例，
    /// 先完成的 Task 调 clear() 会把仍在进行中的媒体上传进度误清 → 卡片底部进度条「不见了」。
    private var activeTasks = 0

    /// 任务开始：计数 +1 并写入初始值（线程安全，内部切主线程）
    func begin(roomKey: String?, direction: Direction, progress: Double = 0, label: String = "") {
        Task { @MainActor in
            activeTasks += 1
            self.roomKey = roomKey
            self.direction = direction
            self.progress = max(0, min(1, progress))
            self.label = label
        }
    }

    /// 推进：写入最新进度。若无活跃任务则视为任务开始（自动计数 1），保证旧调用点语义兼容。
    func update(roomKey: String?, direction: Direction, progress: Double, label: String = "") {
        Task { @MainActor in
            if activeTasks == 0 { activeTasks = 1 }
            self.roomKey = roomKey
            self.direction = direction
            self.progress = max(0, min(1, progress))
            self.label = label
        }
    }

    /// 任务结束：计数 -1；仅当全部活跃任务都结束时才真正清空（并发的另一任务进度不被误清）
    func end() {
        Task { @MainActor in
            activeTasks = max(0, activeTasks - 1)
            if activeTasks == 0 {
                roomKey = nil
                label = ""
            }
        }
    }

    /// 直接清空（兼容旧调用；新代码统一用 begin/end）
    func clear() {
        Task { @MainActor in
            roomKey = nil
            label = ""
        }
    }
}

// MARK: - 房源卡片
// 布局：左上封面 + 右侧信息
//  第一行：房号（加大加粗）+ 价格（加大加粗），状态徽章在右上角
//  第二行：户型 + 实拍图情况
//  第三行：密码
//  第四行：备注

struct HouseCardView: View {
    let house: House

    // v1.42：卡片底部上传/同步进度条——订阅全局进度发布器，仅当正在操作本房源时显示
    @ObservedObject private var sync = HouseSyncProgress.shared

    @State private var previewRoute: PhotoPreviewRoute? = nil
    @State private var playingVideo: MediaItem? = nil
    // v2.20：云端同步新增/修改过、还没点开详情 → 红框
    @State private var isUnread = false
    // v2.24：账本推云端失败的房源 → 标「未同步」
    @State private var syncFailed = false

    /// 本房源是否正在上传/同步（匹配房号）
    private var isSyncingThis: Bool {
        sync.roomKey == house.mediaRoomKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
            // 封面：有视频 → 视频缩略图 + 播放；无视频 → 首图，点击放大左右滑动浏览全部照片
            Button {
                openCover()
            } label: {
                coverView
            }
            .buttonStyle(.plain)
            .frame(width: 92, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                // 第一行：房号 + 价格（b106：自适应胶囊，不破坏原布局），最右侧是状态徽章（已租/待租）
                HStack(alignment: .center, spacing: 6) {
                    Text(house.displayRoomNo)
                        .font(.title3.weight(.bold))
                        .foregroundColor(.primary)
                        // v2.2（需求①）：房号强制不换行，过长时缩放兜底
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Color(.systemGray6))
                        .clipShape(Capsule())
                    // v2.2（需求①）：租金只显示金额数字（去掉「元/月」）
                    Text(house.priceAmountText)
                        // v1.72（#3）：租金恢复 headline 加粗 + 主题色（v1.71 #96 曾改 title3，用户要求回退）
                        .font(.headline.weight(.bold))
                        .foregroundColor(AppTheme.accent)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(AppTheme.accent.opacity(0.1))
                        .clipShape(Capsule())
                    Spacer(minLength: 0)
                    StatusBadge(status: house.status)
                }

                // 第二行：户型 + 有无实拍图，最右侧是双端标识（本地/云端/双端）
                HStack(spacing: 6) {
                    Text(house.layout.isEmpty ? "户型未填" : house.layout)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    if house.hasPhoto || house.hasVideo {
                        Image(systemName: "photo.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(mediaSummary)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        Text("无实拍图")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    if syncFailed {
                        Text("未同步")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.red)
                    }
                    Spacer(minLength: 0)
                    CloudBadge(status: house.cloudStatus)
                }

                // v1.19 补全：第三行 = 备注（备注与密码互换位置）
                Text("备注：\(house.remark.isEmpty ? "—" : house.remark)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                // v1.19 补全：第四行 = 密码（左）+ 更新于（右下角）
                HStack(alignment: .center, spacing: 8) {
                    Text("密码：\(house.password.isEmpty ? "—" : house.password)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Text("更新于 \(HouseCardView.timeText(house.lastUpdatedAt ?? house.updatedAt))")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }
            .padding(.vertical, 2)
            }
            // v1.42：卡片最底部动态进度条——上传到云端 / 云端同步到本地，细条从左到右跑进度
            if isSyncingThis {
                VStack(spacing: 3) {
                    ProgressView(value: sync.progress)
                        .progressViewStyle(.linear)
                        .frame(height: 4)
                        .tint(AppTheme.accent)
                        .scaleEffect(x: 1, y: 0.55, anchor: .center)   // 压细
                    HStack {
                        Text("\(sync.direction.text) \(Int(sync.progress * 100))%\(sync.label.isEmpty ? "" : " · \(sync.label)")")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
        // v2.20：云端同步带来过变更、还没点开详情 → 红框提示（点开详情后自动消失）
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.red.opacity(0.85), lineWidth: isUnread ? 2 : 0)
        )
        .onAppear {
            isUnread = UnreadCloudHouseStore.isUnread(house.mediaRoomKey)
            syncFailed = SyncFailStore.isFailed(house.mediaRoomKey)
        }
        .onChange(of: house.mediaRoomKey) { _, newKey in
            isUnread = UnreadCloudHouseStore.isUnread(newKey)
        }
        .onReceive(NotificationCenter.default.publisher(for: UnreadCloudHouseStore.didChange)) { _ in
            isUnread = UnreadCloudHouseStore.isUnread(house.mediaRoomKey)
        }
        .onReceive(NotificationCenter.default.publisher(for: SyncFailStore.didChange)) { _ in
            syncFailed = SyncFailStore.isFailed(house.mediaRoomKey)
        }
        .fullScreenCover(item: $previewRoute) { route in
            PhotoPreviewView(photos: house.photos, startIndex: route.index, roomKey: house.mediaRoomKey)
        }
        .fullScreenCover(item: $playingVideo) { media in
            FullScreenVideoPlayer(media: media, roomKey: house.mediaRoomKey)
        }
    }

    private var mediaSummary: String {
        if house.hasPhoto && house.hasVideo { return "照片+视频" }
        return house.hasPhoto ? "有实拍图" : "有视频"
    }

    private var coverView: some View {
        Group {
            if let firstVideo = house.videos.first {
                ZStack {
                    MediaThumbView(media: firstVideo, roomKey: house.mediaRoomKey)
                    // 播放三角：缩小 + 半透明，不遮挡画面
                    Image(systemName: "play.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.72))
                        .shadow(radius: 2)
                }
            } else if let first = house.photos.first {
                MediaThumbView(media: first, roomKey: house.mediaRoomKey)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(AppTheme.primary.opacity(0.08))
                    Image(systemName: "house.fill")
                        .font(.system(size: 26))
                        .foregroundColor(AppTheme.primary.opacity(0.35))
                }
            }
        }
    }

    /// 点封面：优先播放视频；没有视频则放大首图，可左右滑动浏览全部照片
    private func openCover() {
        if let firstVideo = house.videos.first {
            playingVideo = firstVideo
        } else if !house.photos.isEmpty {
            previewRoute = PhotoPreviewRoute(index: 0)
        }
    }

    /// v1.19：最后更新时间格式化
    static func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }
}

// MARK: - v1.19 云端三态标识徽章（本地 / 云端 / 双端）

struct CloudBadge: View {
    let status: House.CloudStatus
    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
    private var label: String {
        switch status {
        case .local: return "本地"
        case .cloud: return "云端"
        case .both: return "双端"
        }
    }
    private var color: Color {
        switch status {
        case .local: return .gray
        case .cloud: return .blue
        case .both: return .green
        }
    }
}

// MARK: - 详情页视频条目（缩略图 + 播放三角，点击全屏播放，播放界面长按可保存视频到相册）

struct HouseDetailVideoItem: View {
    let media: MediaItem
    let roomKey: String
    @State private var playing = false

    var body: some View {
        Button {
            playing = true
        } label: {
            MediaThumbView(media: media, roomKey: roomKey)
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $playing) {
            FullScreenVideoPlayer(media: media, roomKey: roomKey)
        }
    }
}

// MARK: - 全屏视频播放器（卡片点封面播放用，长按保存视频到相册）

struct FullScreenVideoPlayer: View {
    let media: MediaItem
    let roomKey: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var saveMessage: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    // 长按播放界面：保存视频到相册
                    .contextMenu {
                        Button {
                            saveVideoToAlbum()
                        } label: {
                            Label("保存到相册", systemImage: "square.and.arrow.down")
                        }
                    }
            }

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
        .onAppear {
            if player == nil {
                player = AVPlayer(url: MediaStore.url(for: media.fileName, roomKey: roomKey))
                player?.play()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    /// 保存当前视频到系统相册（仅新增写入权限）
    private func saveVideoToAlbum() {
        let url = MediaStore.url(for: media.fileName, roomKey: roomKey)
        guard FileManager.default.fileExists(atPath: url.path) else {
            saveMessage = "视频文件不存在，无法保存"
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            switch status {
            case .authorized, .limited:
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
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

// MARK: - 系统分享面板（UIActivityViewController 封装，可分享到微信）

struct HouseShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - v2.26：分享面板改从最顶层控制器直呈
//
// 此前用 SwiftUI 的 .sheet 包住 UIActivityViewController。第二次弹面板时，微信这类第三方
// 分享扩展拿不到有效的呈现上下文，点了没反应（「拷贝」「存储到文件」这类系统项不受影响），
// 表现为单套偶发点微信不动、多套发完第一套后第二套点微信仍不动，App 本身没卡死。
// 现改为从当前最顶层控制器直接 present，并把「面板已关闭」改成 completion 回调驱动队列。

enum SharePresenter {
    static func present(items: [Any], completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            guard !items.isEmpty else { completion?(); return }
            // 上一次面板还挂在层级上（极少数）：先关掉再弹，避免 present 被系统静默忽略
            if let top = topViewController(), top is UIActivityViewController {
                top.dismiss(animated: false) {
                    DispatchQueue.main.async { presentNow(items: items, completion: completion) }
                }
                return
            }
            presentNow(items: items, completion: completion)
        }
    }

    private static func presentNow(items: [Any], completion: (() -> Void)?) {
        guard let host = topViewController() else { completion?(); return }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async { completion?() }
        }
        if let pop = vc.popoverPresentationController {
            pop.sourceView = host.view
            pop.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        host.present(vc, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        guard var top = window?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        if let nav = top as? UINavigationController { top = nav.visibleViewController ?? nav }
        if let tab = top as? UITabBarController { top = tab.selectedViewController ?? tab }
        return top
    }
}

// MARK: - 空状态

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(AppTheme.primary.opacity(0.4))
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        // v1.32：恢复撑满列表区域（maxHeight: .infinity），空态占据筛选栏以下的剩余空间并居中，
        // 首页内容块不再整体收缩被居中顶到页面中间（修复「搜索无结果时空态下沉」）
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
}

// MARK: - v2.17：只分享视频（微信按视频消息接收，收到即显示缩略图、点开直接播放）

/// 系统分享面板把「文件地址」交给微信时，微信只当文件附件；只有给视频素材（AVAsset）且容器是 mp4，
/// 微信才按视频消息处理。这里统一做三件事：转 mp4（mov 也能播）、组装素材、顺手在相册留一份兜底。
enum VideoOnlyShare {
    /// 本地视频 → 可直接交给系统分享面板的 mp4 文件地址（已是 mp4 直接用；mov 先转封装）。
    /// 注意必须给「文件地址」，不能给 AVAsset 对象：给对象时分享面板识别不出类型，
    /// 微信等扩展会整条消失，只剩备忘录这类万能接收项。
    /// v2.31：照相册分享的做法——先把视频「准备」成一段系统导出的兼容 mp4（有进度），再弹分享面板。
    /// 相册里能发、App 里发不出去的大视频，差别就在这一步：相册是系统先导出（转码成 H.264/mp4，体积可控）再交给微信；
    /// App 直接把原始大文件丢给微信扩展，扩展读不动就闪退（点了没反应）。
    static func prepareFiles(from urls: [URL], progress: ((Double, String) -> Void)? = nil) async -> [URL] {
        var files: [URL] = []
        let total = max(urls.count, 1)
        for (idx, url) in urls.enumerated() {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let base = Double(idx) / Double(total)
            let span = 1.0 / Double(total)
            if await isWeChatReady(url) {
                files.append(url)
                progress?(base + span, "跳过压缩（\(idx + 1)/\(total)）")
                continue
            }
            progress?(base, "正在压缩视频（\(idx + 1)/\(total)）…")
            if let compact = await compressForWeChat(url, progress: { p, msg in
                progress?(base + p * span, msg)
            }) {
                files.append(compact)
            } else if let mp4 = await exportMP4(from: url) {
                files.append(mp4)
            } else {
                files.append(url)   // 全都失败：退回原文件，不让分享中断
            }
        }
        progress?(1.0, "压缩完成")
        return files
    }

    /// 按系统相册的「导出再分享」思路压缩：依次尝试 720p → 540p → 低质量预设，
    /// 体积降到 12MB 以内就停（微信扩展读取快、不会超时），都不达标再用自定义码率兜底到 8MB。
    static func compressForWeChat(_ url: URL, progress: ((Double, String) -> Void)? = nil) async -> URL? {
        let asset = AVURLAsset(url: url)
        let target: Int64 = 12 * 1024 * 1024
        let presets: [String] = [
            AVAssetExportPreset1280x720,
            AVAssetExportPreset960x540,
            AVAssetExportPresetLowQuality
        ]
        for (i, preset) in presets.enumerated() {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("wx_share_\(UUID().uuidString).mp4")
            session.outputURL = out
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            let base = Double(i) / Double(presets.count)
            let span = 1.0 / Double(presets.count)
            let label = "正在压缩视频（第 \(i + 1)/\(presets.count) 档）"
            let ok = await runExport(session: session) { p in
                progress?(base + p * span, "\(label) \(Int(p * 100))%")
            }
            if ok {
                let attrs = try? FileManager.default.attributesOfItem(atPath: out.path)
                let size = (attrs?[.size] as? Int64) ?? 0
                if size > 0, size <= target {
                    return out
                }
            }
            try? FileManager.default.removeItem(at: out)
        }
        // 兜底：自定义码率压到 8MB
        return await transcodeToCompatible(url, maxBytes: 8 * 1024 * 1024, progress: progress)
    }

    /// 跑一次 AVAssetExportSession，边跑边回报进度（0…1）
    private static func runExport(session: AVAssetExportSession,
                                  progress: @escaping (Double) -> Void) async -> Bool {
        let ticker = Task {
            while !Task.isCancelled {
                if session.status != .exporting { break }
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        ticker.cancel()
        progress(1.0)
        return session.status == .completed
    }

    /// 微信能直接吃的判断：mp4 容器 + 首条视频轨是 H.264 + 体积不超过 18MB。
    private static func isWeChatReady(_ url: URL) async -> Bool {
        guard url.pathExtension.lowercased() == "mp4" else { return false }
        let asset = AVURLAsset(url: url)
        guard let track = (try? await asset.loadTracks(withMediaType: .video))?.first else { return false }
        let descs = (try? await track.load(.formatDescriptions)) ?? []
        guard let first = descs.first else { return false }
        let subType = CMFormatDescriptionGetMediaSubType(first)
        // 'avc1' = H.264（HEVC 是 'hvc1'/'hev1'，微信部分机型不认）
        guard subType == 0x61766331 else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? Int.max
        return size <= 12 * 1024 * 1024
    }

    /// 转成微信一定能发的 mp4：长边 1280（720p）、H.264、AAC 96kbps，码率按「整片约 18MB」反算。
    /// 输出到临时目录，调用方用完不用删（系统会回收；文件被微信扩展复制后再删也无所谓）。
    static func transcodeToCompatible(_ url: URL,
                                      maxBytes: Int64 = 8 * 1024 * 1024,
                                      progress: ((Double, String) -> Void)? = nil) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = (try? await asset.loadTracks(withMediaType: .video))?.first else { return nil }
        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? CGSize(width: 1280, height: 720)
        let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let duration = (try? await asset.load(.duration)) ?? CMTime(value: 1, timescale: 1)
        let seconds = max(CMTimeGetSeconds(duration), 0.1)
        let nominalFPS = (try? await videoTrack.load(.nominalFrameRate)) ?? 30
        let audioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first

        let longSide = max(naturalSize.width, naturalSize.height)
        guard longSide > 0 else { return nil }
        let shrink = min(1280.0 / Double(longSide), 1.0)
        var outW = Int((Double(naturalSize.width) * shrink).rounded())
        var outH = Int((Double(naturalSize.height) * shrink).rounded())
        outW -= outW % 2
        outH -= outH % 2
        outW = max(outW, 2)
        outH = max(outH, 2)

        // 目标整片体积：码率 = 目标字节 * 8 / 时长，夹在 500kbps–2.2Mbps
        let targetBits = Double(maxBytes) * 8
        let bitrate = Int(min(max(targetBits / seconds, 500_000), 2_200_000))
        let fps = nominalFPS > 1 ? max(Int(nominalFPS.rounded()), 15) : 30

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: true
            ] as [String: Any]
        ]

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("wx_share_\(UUID().uuidString).mp4")
        if FileManager.default.fileExists(atPath: out.path) { try? FileManager.default.removeItem(at: out) }

        guard let writer = try? AVAssetWriter(outputURL: out, fileType: .mp4),
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else { return nil }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outW,
                kCVPixelBufferHeightKey as String: outH
            ] as [String: Any]
        )

        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { return nil }
        reader.add(videoOutput)

        var audioInput: AVAssetWriterInput?
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let pcmSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 96_000
            ]
            let o = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
            o.alwaysCopiesSampleData = false
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
            i.expectsMediaDataInRealTime = false
            if reader.canAdd(o), writer.canAdd(i) {
                reader.add(o)
                writer.add(i)
                audioOutput = o
                audioInput = i
            }
        }

        guard writer.startWriting(), reader.startReading() else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let outRect = CGRect(x: 0, y: 0, width: outW, height: outH)

        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue(label: "wx.video.transcode").async {
                var good = true
                let deadline = Date().addingTimeInterval(600)

                func drainAudio() {
                    guard let i = audioInput, let o = audioOutput else { return }
                    while i.isReadyForMoreMediaData, let sample = o.copyNextSampleBuffer() {
                        if !i.append(sample) { good = false; return }
                    }
                }

                while good {
                    if Date() > deadline { good = false; break }
                    if !videoInput.isReadyForMoreMediaData {
                        drainAudio()
                        Thread.sleep(forTimeInterval: 0.002)
                        continue
                    }
                    guard let sample = videoOutput.copyNextSampleBuffer() else { break }
                    autoreleasepool {
                        guard let srcBuffer = CMSampleBufferGetImageBuffer(sample),
                              let pool = adaptor.pixelBufferPool else { good = false; return }
                        var dstRef: CVPixelBuffer?
                        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dstRef) == kCVReturnSuccess,
                              let dst = dstRef else { good = false; return }
                        let srcImage = CIImage(cvPixelBuffer: srcBuffer)
                        let sx = CGFloat(outW) / CGFloat(CVPixelBufferGetWidth(srcBuffer))
                        let sy = CGFloat(outH) / CGFloat(CVPixelBufferGetHeight(srcBuffer))
                        let scaled = srcImage.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                        ciContext.render(scaled, to: dst, bounds: outRect, colorSpace: colorSpace)
                        if !adaptor.append(dst, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sample)) {
                            good = false
                        }
                    }
                    drainAudio()
                }

                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                if good, writer.status == .writing {
                    writer.endSession(atSourceTime: duration)
                    writer.finishWriting {
                        let done = writer.status == .completed
                        cont.resume(returning: done)
                    }
                } else {
                    writer.cancelWriting()
                    cont.resume(returning: false)
                }
            }
        }
        let outAttrs = try? FileManager.default.attributesOfItem(atPath: out.path)
        let outSize = (outAttrs?[.size] as? Int) ?? 0
        guard ok, outSize > 0 else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }

    /// 把 mp4 文件包成「影片」类型的分享项：系统按类型标签匹配微信扩展，
    /// 只给文件地址时微信拿到的是「文件」标签，就当附件发；显式声明 public.movie 才按视频消息发。
    /// v2.28：微信只有拿到「系统数据包」形式的影片才按视频消息接收；
    /// 直接给文件地址（v2.27）在微信里会变成文件附件。这里恢复 provider 形式，只注册影片类型、不带 suggestedName。
    static func movieItems(from files: [URL]) -> [Any] {
        files.map { url in
            let provider = NSItemProvider()
            provider.registerFileRepresentation(forTypeIdentifier: UTType.movie.identifier,
                                                fileOptions: [],
                                                visibility: .all) { completion in
                completion(url, false, nil)
                return nil
            }
            return provider
        }
    }

    /// 静默在系统相册留一份（只申请新增权限）。
    /// 保存前先把视频内的拍摄时间改写成「现在」：相册「图库」是按拍摄日期分组排序的，
    /// 沿用原片日期会被排到几个月前的位置，只能在「精选集 → 最近保存」里看到。
    static func saveToAlbumQuietly(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return }
        var copies: [URL] = []
        for url in urls {
            if let dated = await exportMP4(from: url, retagDate: true) { copies.append(dated) }
            else { copies.append(url) }
        }
        try? await PHPhotoLibrary.shared().performChanges {
            for url in copies {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
        }
    }

    /// mov → mp4：先 passthrough（不重编码、秒级完成、画质零损失），不适用时回退最高质量重编码。
    /// retagDate = true 时顺带把拍摄时间改写成当前时间（只用于存相册的副本）。
    private static func exportMP4(from url: URL, retagDate: Bool = false) async -> URL? {
        let asset = AVURLAsset(url: url)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("share_video_\(UUID().uuidString).mp4")
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            if FileManager.default.fileExists(atPath: out.path) {
                try? FileManager.default.removeItem(at: out)
            }
            session.outputURL = out
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            if retagDate {
                let now = ISO8601DateFormatter().string(from: Date())
                var items: [AVMetadataItem] = []
                for key in ["com.apple.quicktime.creationdate", "com.apple.quicktime.creationtime"] {
                    let item = AVMutableMetadataItem()
                    item.key = key as NSString
                    item.keySpace = .quickTimeMetadata
                    item.value = now as NSString
                    items.append(item)
                }
                session.metadata = items
            }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { cont.resume() }
            }
            if session.status == .completed, FileManager.default.fileExists(atPath: out.path) {
                return out
            }
        }
        return nil
    }
}
