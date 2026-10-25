import SwiftUI
import UIKit
import AVKit
import Photos

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

    /// 开始/推进：线程安全（内部切主线程）
    func update(roomKey: String?, direction: Direction, progress: Double, label: String = "") {
        Task { @MainActor in
            self.roomKey = roomKey
            self.direction = direction
            self.progress = max(0, min(1, progress))
            self.label = label
        }
    }

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
                // 第一行：房号 + 价格，最右侧是状态徽章（已租/待租）
                HStack(alignment: .top, spacing: 8) {
                    Text(house.displayRoomNo)
                        .font(.title3.weight(.bold))
                        .foregroundColor(.primary)
                    Text(house.priceText)
                        .font(.headline.weight(.bold))
                        .foregroundColor(AppTheme.accent)
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
