import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PhotosUI

// v1.9：设置页滚动偏移监听——用 UIKit KVO 观察 Form 滚动容器的 contentOffset（不再往 Form 里塞标记行，
// 之前 v1.7/v1.8 用 Color.clear 行做滚动标记，即使行高压到 0 仍残留系统行占位，导致设置页顶部一大块空白）
private struct SettingsScrollViewReader: UIViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let probe = UIView(frame: .zero)
        probe.backgroundColor = .clear
        DispatchQueue.main.async {
            // 沿 superview 链找到 Form 的滚动容器（UITableView/UICollectionView 均为 UIScrollView 子类）
            var view: UIView? = probe
            while let current = view {
                if let scroll = current as? UIScrollView {
                    context.coordinator.attach(scroll, onScroll: onScroll)
                    break
                }
                view = current.superview
            }
        }
        return probe
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var onScroll: ((CGFloat) -> Void)?
        private var observation: NSKeyValueObservation?

        func attach(_ scrollView: UIScrollView, onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
            observation = scrollView.observe(\.contentOffset, options: [.new, .initial]) { [weak self] scrollView, _ in
                self?.onScroll?(scrollView.contentOffset.y)
            }
        }
    }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.houseModelContext) private var houseModelContext
    @State private var showMessage = ""
    @State private var showAlert = false
    @State private var showClearSheet = false
    @State private var clearType: DataBackupManager.BackupType? = nil
    @State private var showClearConfirm = false
    @State private var showVersionHistory = false
    @State private var showManualSync = false
    @State private var showMigration = false
    @State private var showBillTemplate = false
    @State private var showTrash = false   // v1.3：回收站入口从工作台移至设置页
    // v1.12：备份体系重构——统一备份/恢复入口（替代旧分板块备份/恢复；旧 JSON 备份在查看器中保留）
    @State private var showBackupKindSheet = false   // 备份方式选择（快速/全量）
    @State private var showOfflineRestoreConfirm = false   // v1.75：离线重建房源二次确认
    @State private var showBackupCenterBrowse = false // 备份文件查看器
    @State private var showBackupCenterRestore = false // 恢复选择器
    @State private var showLogsView = false           // 操作日志
    @State private var showCrashLogsView = false      // v1.17 需求2：崩溃日志查看器（内置，右上角导出 txt）
    @AppStorage("autoBackupRetentionDays") private var backupRetentionDays = 7   // 自动备份保留天数（默认7天，可调）
    @State private var autoBackupEnabled = false
    @State private var backupFrequency = "day"
    @State private var backupHour = 23
    @State private var settingsScrollY: CGFloat = 0   // v1.7：设置页滚动检测（顶部标题横线动态显示）
    // v1.6：房源分享设置合并进主设置（原房源板块独立设置页取消）
    @State private var showHouseCacheConfirm = false
    /// v1.98：AI 产物清空二级确认（设置页「AI对话缓存」行）
    @State private var showAICacheConfirm = false
    @State private var houseCacheTip: String?
    @State private var roomsLinkExpiry = 2   // v1.55：选房链接有效期（天），默认 2，onAppear 从 UserDefaults 读取
    @State private var watermarkSubtitle = ""   // v1.41：分享水印入口副标题（onAppear 刷新，返回设置页即显示最新开关状态）
    // v1.84：电表监控设置（链接/数据源/阈值/定时刷新/提醒）
    @EnvironmentObject private var meterStore: MeterStore
    @State private var meterLinkInput = ""
    @State private var meterLinkTip: String?

    /// v1.41：刷新分享水印入口副标题（返回设置页 / 页面出现时读取最新 store，立即反映开关状态）
    private func refreshWatermarkSubtitle() {
        let wm = WatermarkSettingsStore.current
        watermarkSubtitle = wm.enabled ? "已开启 · \(wm.text)" : "已关闭"
    }
    @AppStorage("notificationSound_rent") private var rentSound = "system"
    @AppStorage("notificationSound_expiry") private var expirySound = "system"
    @AppStorage("notificationSound_payout") private var payoutSound = "system"
    @AppStorage("notificationSound_todo") private var todoSound = "system"
    @AppStorage("defaultElectricPrice") private var defaultElectricPrice = "0.8"
    @AppStorage("defaultWaterPrice") private var defaultWaterPrice = "5.5"
    @AppStorage("defaultUtilityPrepayment") private var defaultUtilityPrepayment = "0"

    private let backupManager = DataBackupManager.shared

    /// v1.12：已收录房源统计口径——以房源库为准（排除回收站）；容器不可用时回退目录计数
    private var houseCountText: Int {
        if let ctx = houseModelContext,
           let all = try? ctx.fetch(FetchDescriptor<House>()) {
            return all.filter { !($0.isDeleted ?? false) }.count
        }
        return MediaStore.houseCount()
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// v1.6：房源分享设置（合并自原房源板块独立设置页）
    /// v1.70：小字说明恢复为仅讲云端配置口径——不再掺入版本更新/同步机制等内容
    /// （v1.69 曾误并入同步机制、待补传媒体、房号前缀规范等版本更新内容，已还原）
    private static let houseShareFooter = "云端配置：腾讯云 COS 存储桶、密钥、自定义域名与云函数地址（后台网址），用于上传房源图片/视频生成微信分享卡片链接，以及打开云端管理后台；可导出部署包给别的房东自建后台。名片信息：分享 H5 页面和微信卡片上显示的姓名与电话。压缩上传开启后，新增/编辑房源的图片视频上传云端与分享 H5 都会压缩（视频压到 720p、图片轻压缩），上传更快更省流量。房源数据（数据库、图片视频、二维码）默认存放在「公寓管家」文件夹内的「备份」「media」两个子文件夹（v1.40 起重建），长按拷贝/共享即为备份，重装后放回原位即可还原。"
    private var houseShareSection: some View {
        Section {
            NavigationLink {
                CosConfigView()
            } label: {
                Label("云端配置", systemImage: "server.rack")
            }
            NavigationLink {
                ShareProfileView()
            } label: {
                Label("名片信息", systemImage: "person.crop.circle")
            }
            // v1.47：公开选房 H5——复制/分享给租客的实时选房链接（只显示户型，实时读云端账本）
            NavigationLink {
                RoomsShareView()
            } label: {
                Label("公开选房链接", systemImage: "globe.asia.australia")
            }
            // v1.55：选房链接有效期（默认 2 天，可动态调整）——到期后旧链接失效，需重新生成
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("选房链接有效期")
                        Text("到期后旧链接失效，需重新生成")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "clock.badge.xmark")
                }
                Spacer()
                Picker("", selection: $roomsLinkExpiry) {
                    Text("1 天").tag(1)
                    Text("2 天").tag(2)
                    Text("3 天").tag(3)
                    Text("7 天").tag(7)
                    Text("15 天").tag(15)
                    Text("30 天").tag(30)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: roomsLinkExpiry) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "roomsLinkExpiryDays")
                    showMessage = "已设为 \(newValue) 天：下次「重新生成链接」按新有效期生效"
                    showAlert = true
                }
            }
            // v1.36 需求3：分享水印设置（开关/文本/字号/透明度/位置/预览/保存/清除）
            // v1.41：入口副标题改为 onAppear 刷新——从水印页返回设置页时立即显示最新开关状态（此前静态文本可能不重算）
            NavigationLink {
                WatermarkSettingsView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("分享水印")
                        Text(watermarkSubtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "camera.aperture")
                }
            }
            .onAppear { refreshWatermarkSubtitle() }
            // v1.36 需求7：管理后台口令（网页版登录；App 内免登录）
            NavigationLink {
                AdminPasswordView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("管理后台口令")
                        Text("网页版登录用 · App 内自动免登录")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield")
                }
            }
            // v1.51：压缩开关同时作用于「房源媒体上传云端」与「分享 H5」，文案明确（默认开启：图片压到长边≤1600、视频压到 720p，上传更快更省流量）
            Toggle("压缩上传媒体（房源+分享）", isOn: Binding(
                get: { shareCompressionEnabled },
                set: { UserDefaults.standard.set($0, forKey: "compressOnShare") }
            ))
            Button {
                showHouseCacheConfirm = true
            } label: {
                Label("刷新分享缓存", systemImage: "arrow.clockwise.circle")
            }
            HStack {
                Label("数据文件夹大小", systemImage: "externaldrive")
                Spacer()
                Text(houseDocumentsSizeText())
                    .foregroundColor(.secondary)
            }
            // v1.98：AI 产物统一存沙盒根目录「AI产物」文件夹；此处仿「数据文件夹大小」展示占用，单击二级确认后清空
            Button {
                showAICacheConfirm = true
            } label: {
                HStack {
                    Label("AI对话缓存", systemImage: "bubble.left.and.bubble.right")
                    Spacer()
                    Text(aiCacheSizeText())
                        .foregroundColor(.secondary)
                }
            }
            Text("AI 生成的账单图片、导出表格等产物统一存放于沙盒根目录「AI产物」文件夹，点上方可查看占用并一键清空（清空不影响对话记录与 App 数据）")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Label {
                    Text(verbatim: "已收录房源")
                } icon: {
                    Image(systemName: "building.2")
                }
                Spacer()
                // v1.12：统计口径统一——以房源库为准（排除回收站），不再用 Media 目录计数（删进回收站的房子不再计入）
                Text("\(houseCountText) 套")
                    .foregroundColor(.secondary)
            }
            Button {
                openHouseDataFolder()
            } label: {
                Label("打开「文件」App 查看数据文件夹", systemImage: "folder")
            }
        } footer: {
            Text(RemoteConfig.help("houseShareFooter", Self.houseShareFooter))
        }
    }

    // MARK: - 设置页 Section 分组（v1.6 拆分，避免 Form 表达式 type-check 超时）
    // v1.7：备份/恢复仅针对租房数据（成交/收租/包租/汇总/待办），房源数据走「房源分享 → 数据文件夹」整文件夹备份
    /// v1.11：打开「文件」App 直达房源数据 media 文件夹（Documents/备份/Media）。
    /// 优先直接打开该目录的 file:// URL（配合 LSSupportsOpeningDocumentsInPlace，iOS 会定位到该文件夹）；
    /// 个别系统版本不支持定位子目录时兜底打开文件 App 根目录。
    private func openHouseDataFolder() {
        let mediaURL = MediaStore.mediaDirectory()
        UIApplication.shared.open(mediaURL) { success in
            if !success, let root = URL(string: "shareddocuments://") {
                UIApplication.shared.open(root)
            }
        }
    }
    // v1.12：数据管理统一为「快速/全量」备份体系（替代旧分板块备份/恢复）；
    // 旧版分板块 JSON 备份在「查看备份文件 → 旧版备份（JSON）」分组里保留查看/恢复/删除，数据不丢失。
    private var dataSection: some View {
        Section {
            Button { showBackupKindSheet = true } label: {
                Label("备份数据", systemImage: "square.and.arrow.down")
            }
            Button { showBackupCenterRestore = true } label: {
                Label("恢复数据", systemImage: "square.and.arrow.up")
            }
            // v1.75：离线重建房源——无需联网，从本地账本（media/<房号>/info.json）重建房源记录
            // v1.80：入口显隐由云端远程配置控制（features.showOfflineRestore），小字说明也可云端改
            if RemoteConfig.feature("showOfflineRestore", true) {
                VStack(alignment: .leading, spacing: 3) {
                    Button { showOfflineRestoreConfirm = true } label: {
                        Label("离线重建房源", systemImage: "arrow.clockwise.circle")
                    }
                    Text(RemoteConfig.help("offlineRestoreIntro", "无需联网：从本机 media 文件夹的账本（每套 info.json）重建房源记录，数据库丢失或断网时可用，不删除现有数据。"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            // v1.12：备份文件查看器（快速/全量 zip + 云端 + 旧版 JSON）
            Button { showBackupCenterBrowse = true } label: {
                Label("查看备份文件", systemImage: "folder")
            }
            // v1.12：操作日志（备份/恢复/上传/删除/同步）
            Button { showLogsView = true } label: {
                HStack {
                    Label("操作日志", systemImage: "list.bullet.rectangle")
                    Spacer()
                    // v1.19 补全 #7：日志占用显示在入口右侧
                    Text(ByteCountFormatter.string(fromByteCount: Int64(BackupLogStore.sizeBytes()), countStyle: .file))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            // v1.12：崩溃日志（自建日志文件，不依赖第三方）v1.17 需求2：内置查看器 + 右上角导出（App 根目录生成 txt）
            Button { showCrashLogsView = true } label: {
                Label("查看 / 导出崩溃日志", systemImage: "ladybug")
            }
            // v1.14 需求7：清空数据移到导出崩溃日志下方（板块末位）
            Button { showClearSheet = true } label: {
                HStack {
                    Label("清空数据", systemImage: "trash")
                        .foregroundColor(.red)
                    Spacer()
                    Text("按板块清空")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        } footer: {
            Text(RemoteConfig.help("backupIntro", "备份数据 = 快速备份（账本 + 媒体清单，不含房源与照片视频，自动上传云端；房源统一从云端同步恢复）或全量备份（额外含全部房源与照片视频）。恢复会覆盖当前数据，恢复前自动打包当前数据做安全备份，失败自动还原。旧版分板块 JSON 备份仍可在「查看备份文件」中恢复，不会丢失。"))
        }
    }

    private var syncSection: some View {
        Section {
            Button { showManualSync = true } label: {
                HStack {
                    Label("数据同步", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Text("手动")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            Button { showMigration = true } label: {
                Label("备份与迁移", systemImage: "iphone.and.arrow.forward")
            }
            NavigationLink {
                MediaPendingView()
            } label: {
                Label("待补传媒体", systemImage: "arrow.clockwise.icloud")
            }
        } footer: {
            Text("跨端同步和迁移只会在你主动操作后执行，不会自动联网。")
        }
    }

    private var autoBackupSection: some View {
        Section {
            HStack {
                Label("启用自动备份", systemImage: "clock")
                Spacer()
                // v1.42：显式 Binding——set 时立即更新 @State 并落盘（不依赖 onChange 闭包捕获时序），
                //        与分享水印开关同款修法，拨动即保存、返回再进入即显示最新状态
                Toggle("", isOn: Binding(
                    get: { autoBackupEnabled },
                    set: { newValue in
                        autoBackupEnabled = newValue
                        saveAutoSettings()
                    }
                ))
                .labelsHidden()
            }
            if autoBackupEnabled {
                HStack {
                    Label("备份频率", systemImage: "calendar")
                    Spacer()
                    Picker("", selection: $backupFrequency) {
                        Text("每天").tag("day")
                        Text("每周").tag("week")
                        Text("每月").tag("month")
                    }
                    .pickerStyle(.menu)
                    .tint(.secondary)
                    .labelsHidden()
                    .onChange(of: backupFrequency) { _, _ in saveAutoSettings() }
                }
                HStack {
                    Label("备份时间", systemImage: "timer")
                    Spacer()
                    Button { if backupHour > 0 { backupHour -= 1 } } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    Text(String(format: "%02d:00", backupHour))
                        .font(.system(size: 16, weight: .semibold))
                        .frame(minWidth: 58)
                        .multilineTextAlignment(.center)
                    Button { if backupHour < 23 { backupHour += 1 } } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .onChange(of: backupHour) { _, _ in saveAutoSettings() }
                // v1.12：自动备份保留天数可配置（默认 7 天）
                // v1.13 需求9：天数放在 - + 号中间（与备份时间行同款布局）
                HStack {
                    Label("保留天数", systemImage: "archivebox")
                    Spacer()
                    Button { if backupRetentionDays > 1 { backupRetentionDays -= 1 } } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    Text("\(backupRetentionDays) 天")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(minWidth: 58)
                        .multilineTextAlignment(.center)
                    Button { if backupRetentionDays < 60 { backupRetentionDays += 1 } } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .onChange(of: backupRetentionDays) { _, _ in saveAutoSettings() }
            }
        } footer: {
            Text(RemoteConfig.help("autoBackupIntro", "自动备份 = 快速备份（账本 + 房源 + 清单），备份成功后自动上传云端；超过保留天数（默认 7 天）的自动备份会自动清理，手动备份不会被删除。若到点 App 未在前台，会等下次打开 App 时自动补做。"))
        }
    }

    private var utilitySection: some View {
        Section {
            HStack {
                Label("电费单价", systemImage: "bolt")
                Spacer()
                TextField("0.8", text: $defaultElectricPrice)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
            HStack {
                Label("水费单价", systemImage: "drop")
                Spacer()
                TextField("5.5", text: $defaultWaterPrice)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
            HStack {
                Label("默认总预存", systemImage: "wallet.pass")
                Spacer()
                TextField("0", text: $defaultUtilityPrepayment)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
        } footer: {
            Text("默认单价和预存仅用于新增房源，不影响已生成的结算记录。")
        }
    }

    // MARK: - v1.84 电表监控设置

    private var meterSection: some View {
        Section {
            NavigationLink {
                MeterSettingsDetailView()
            } label: {
                Label("电表监控", systemImage: "bolt.batteryblock.fill")
                Spacer()
                if meterStore.settings.openId.isEmpty {
                    Text("未配置链接")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                } else {
                    Text(meterStore.settings.provider == .webView ? "网页抓取" : "直连接口")
                        .font(.system(size: 12))
                        .foregroundColor(.themeText3)
                }
            }
        } header: {
            Text("电表监控")
        } footer: {
            Text("设置官方电表查询链接、数据源方案、低电量阈值与定时刷新。仅读取展示电量数据，充值仍走官方页面。")
        }
    }

    // MARK: - v1.86 安居客后台 + AI 助手设置

    private var ajkSection: some View {
        Section {
            NavigationLink {
                AjkSettingsDetailView()
            } label: {
                Label("安居客后台", systemImage: "building.2.fill")
                Spacer()
                Text("预警/抓取")
                    .font(.system(size: 12))
                    .foregroundColor(.themeText3)
            }
        } header: {
            Text("安居客后台")
        } footer: {
            Text("推广房源数据抓取：登录一次持久、房态≥N天实地核验预警、已编辑≥N天下架预警、翻页数与历史快照。只读展示，不做发布操作。")
        }
    }

    private var aiSection: some View {
        Section {
            NavigationLink {
                AIAssistantSettingsView()
            } label: {
                Label("AI 助手", systemImage: "sparkles")
                Spacer()
                if KeychainHelper.exists(key: "ai.volcengine.apiKey") {
                    Text("已配置")
                        .font(.system(size: 12))
                        .foregroundColor(.themeAccent)
                } else {
                    Text("未配置 Key")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
            }
        } header: {
            Text("AI 助手")
        } footer: {
            Text("火山方舟豆包对话。API Key 只存本机钥匙串（Keychain），不上传不备份；模型、接口端点、偏好模板均可修改，不做死。")
        }
    }

    private var billSection: some View {
        Section {
            Button { showBillTemplate = true } label: {
                HStack {
                    Label("账单模板设置", systemImage: "textformat.alt")
                    Spacer()
                    Text("文本/收款码/预览")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var ringtoneSection: some View {
        Section {
            HStack {
                Label("收租提醒", systemImage: "bell")
                Spacer()
                Picker("", selection: $rentSound) {
                    Text("系统音").tag("system")
                    Text("自定义音").tag("custom")
                }
                .pickerStyle(.menu)
                .tint(.secondary)
                .labelsHidden()
            }
            HStack {
                Label("到期提醒", systemImage: "alarm")
                Spacer()
                Picker("", selection: $expirySound) {
                    Text("系统音").tag("system")
                    Text("自定义音").tag("custom")
                }
                .pickerStyle(.menu)
                .tint(.secondary)
                .labelsHidden()
            }
            HStack {
                Label("包租提醒", systemImage: "bell.badge")
                Spacer()
                Picker("", selection: $payoutSound) {
                    Text("系统音").tag("system")
                    Text("自定义音").tag("custom")
                }
                .pickerStyle(.menu)
                .tint(.secondary)
                .labelsHidden()
            }
            HStack {
                Label("待办提醒", systemImage: "list.bullet.clipboard")
                Spacer()
                Picker("", selection: $todoSound) {
                    Text("系统音").tag("system")
                    Text("自定义音").tag("custom")
                }
                .pickerStyle(.menu)
                .tint(.secondary)
                .labelsHidden()
            }
        } footer: {
            Text("自定义音使用APP内置铃声；文件不可用时iOS会自动使用系统音。")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Label("应用名称", systemImage: "app")
                Spacer()
                Text("公寓管家")
                    .foregroundColor(.secondary)
            }
            HStack {
                Label("版本", systemImage: "number")
                Spacer()
                Text(appVersion)
                    .foregroundColor(.secondary)
            }
            HStack {
                Label("开发者", systemImage: "person")
                Spacer()
                Text("豆包And涛哥")
                    .foregroundColor(.secondary)
            }
            HStack {
                Label("软件说明", systemImage: "doc.text")
                Spacer()
                Text("米兰公馆中介和二房东工作平台")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Label("数据安全", systemImage: "lock.shield")
                Spacer()
                Text("本机加密存储；跨端操作仅手动触发")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Button { showVersionHistory = true } label: {
                HStack {
                    Label("版本更新介绍", systemImage: "doc.plaintext")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            settingsFormFull
        }
    }

    /// v1.6：设置页主体拆为独立属性（避免 body 表达式 type-check 超时）
    /// v1.7：tint 改为 iOS 原生蓝（房源管家风格设置页配色）；顶部横线随滚动动态显示
    private var settingsForm: some View {
        Form {
                dataSection
                syncSection
                autoBackupSection
                utilitySection
                meterSection
                ajkSection
                aiSection
                billSection
                houseShareSection
                ringtoneSection
                aboutSection
            }
            // v1.9：背景挂载滚动监听（不占任何 Form 行/间距，顶部不再有空白行）
            .background(
                SettingsScrollViewReader { y in
                    settingsScrollY = y
                }
            )
            .tint(Color(red: 0.0, green: 0.478, blue: 1.0))   // iOS 系统蓝 #007AFF
            .overlay(alignment: .top) {
                // v1.7：页面在顶部时不显示横线；向下滑动（顶栏固定）才出现分隔线
                Rectangle()
                    .fill(Color.themeBorder)
                    .frame(height: 0.5)
                    .opacity(settingsScrollY < -1 ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: settingsScrollY < -1)
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // v1.3：回收站入口在设置页右上角（图标+文字）
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showTrash = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash.fill")
                            Text("回收站")
                        }
                        .font(.subheadline)
                    }
                }
            }
            .onAppear {
                loadAutoSettings()
                // v1.55：读取选房链接有效期设置（默认 2 天）
                let d = UserDefaults.standard.integer(forKey: "roomsLinkExpiryDays")
                roomsLinkExpiry = d > 0 ? d : Int(RemoteConfig.param("roomsLinkExpiryDays", 2))
            }
            .alert("提示", isPresented: $showAlert) {
                Button("确定", role: .cancel) { }
            } message: {
                Text(showMessage)
            }
            // v1.12：备份方式选择（快速备份=账本+房源+清单自动传云端；全量备份=含照片视频）
            .confirmationDialog("选择备份方式", isPresented: $showBackupKindSheet, titleVisibility: .visible) {
                Button("快速备份（推荐）") { performNewBackup(kind: .fast) }
                Button("全量备份（含照片视频）") { performNewBackup(kind: .full) }
                Button("取消", role: .cancel) { }
            } message: {
                Text("快速备份：账本 + 媒体清单（不含房源与照片视频文件），备份后自动上传云端；房源从云端同步恢复。\n全量备份：账本 + 房源 + 全部照片视频，备份后可在「查看备份文件」中手动上传云端。")
            }
            .alert("离线重建房源", isPresented: $showOfflineRestoreConfirm) {
                Button("取消", role: .cancel) { }
                Button("开始重建") { runOfflineRestore() }
            } message: {
                Text("将扫描本机 media 文件夹中的所有账本（每套 info.json）并重建房源记录。无需联网；已有房源按账本刷新，缺失房源自动补齐，不删除任何现有数据。")
            }
            .confirmationDialog("选择要清空的板块", isPresented: $showClearSheet, titleVisibility: .visible) {
                Button("清空成交数据") { clearType = .deals; showClearConfirm = true }
                Button("清空收租数据") { clearType = .properties; showClearConfirm = true }
                Button("清空包租数据") { clearType = .payouts; showClearConfirm = true }
                Button("清空全部数据", role: .destructive) { clearType = .total; showClearConfirm = true }
                Button("取消", role: .cancel) { }
            }
            .alert("确认清空", isPresented: $showClearConfirm) {
                Button("取消", role: .cancel) { clearType = nil }
                Button("确定清空", role: .destructive) {
                    if let type = clearType {
                        clearData(type: type)
                    }
                    clearType = nil
                }
            } message: {
                if let type = clearType {
                    Text(type == .total ? "确定要清空所有数据吗？此操作不可恢复，建议先备份数据。" : "确定要清空\(type == .deals ? "成交数据" : type == .properties ? "收租数据" : "包租数据")吗？此操作不可恢复。")
                } else {
                    Text("")
                }
            }
    }

    /// v1.12：挂载链拆分（避免单一表达式 type-check 超时）
    private var settingsFormFull: some View {
        settingsForm
            .sheet(isPresented: $showVersionHistory) {
                VersionHistoryView()
            }
            .sheet(isPresented: $showManualSync) {
                ManualSyncView()
            }
            .sheet(isPresented: $showMigration) {
                MigrationView()
            }
            .sheet(isPresented: $showBillTemplate) {
                BillTemplateSettingsView()
            }
            .sheet(isPresented: $showTrash) {
                TrashView()
            }
            // v1.12：备份文件查看器（快速/全量 zip + 云端备份 + 旧版 JSON）
            .sheet(isPresented: $showBackupCenterBrowse) {
                BackupFileBrowseViewV5(mode: .browse)
            }
            // v1.12：恢复选择器（本地 zip / 云端备份 / 旧版 JSON）
            .sheet(isPresented: $showBackupCenterRestore) {
                BackupFileBrowseViewV5(mode: .restore)
            }
            // v1.12：操作日志
            .sheet(isPresented: $showLogsView) {
                BackupLogsView()
            }
            // v1.12：崩溃日志（v1.17 需求2：内置查看器，右上角导出 txt 到 App 根目录）
            .sheet(isPresented: $showCrashLogsView) {
                CrashLogsView()
            }
            // v1.12：备份中心消息通道（查看器/恢复器内的提示复用本页 alert）
            .onReceive(NotificationCenter.default.publisher(for: .backupCenterMessage)) { note in
                if let text = note.userInfo?["message"] as? String {
                    showMessage = text
                    showAlert = true
                }
            }
            // v1.6：房源分享缓存刷新（二级确认，防止误触导致全部链接失效）
            // v1.54：升级为「全量重建」——云端旧分享页全部删除（旧链接立即失效），并给每间房重新生成最新 H5
            .confirmationDialog("刷新分享缓存", isPresented: $showHouseCacheConfirm, titleVisibility: .visible) {
                Button("清空并重建全部", role: .destructive) {
                    ShareCacheStore.clearAll()
                    rebuildAllShareH5()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将重建全部房源的分享链接：云端旧分享页全部删除（旧链接立即失效），并为每间房重新生成最新 H5。确定继续吗？")
            }
            .alert("刷新分享缓存", isPresented: Binding(
                get: { houseCacheTip != nil },
                set: { if !$0 { houseCacheTip = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(houseCacheTip ?? "")
            }
            // v1.98：AI 对话缓存清空（二级确认，删除「AI产物」文件夹全部内容）
            .alert("清空 AI 产物？", isPresented: $showAICacheConfirm) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    AIToolExecutor.clearAIArtifacts()
                    showMessage = "AI 产物已清空"
                    showAlert = true
                }
            } message: {
                Text("将删除「AI产物」文件夹里的全部账单图片与导出表格（AI 对话历史与 App 数据不受影响）。确定清空吗？")
            }
    }

    // MARK: - 逻辑

    // v1.54：全量重建全部房源的脱敏版分享 H5——
    // 云端旧分享页全部删除（旧链接立即失效）+ 每间房重新生成最新 H5（无媒体房源只删旧页不生成）
    private func rebuildAllShareH5() {
        guard let ctx = houseModelContext,
              let config = CosConfig.load(), config.isValid else {
            houseCacheTip = "请先到「云端配置」填写 COS 配置并验证通过"
            return
        }
        let houses = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
        let active = houses.filter { !($0.isDeleted ?? false) }
        let profile = CosUploader.loadShareProfile()
        // 主线程先拷贝全部值类型，Task 内不再触碰 SwiftData 模型
        let items = active.map { h -> (files: [ShareMediaFile], roomKey: String, info: ShareHouseInfo) in
            (
                h.mediaItems.map { ShareMediaFile(name: $0.fileName, kind: $0.kind) },
                h.mediaRoomKey,
                ShareHouseInfo(
                    displayRoomNo: h.displayRoomNo,
                    towerLabel: h.towerLabel,
                    layout: h.layout,
                    statusLabel: h.status.label,
                    priceText: h.priceText,
                    landlord: h.landlord,
                    password: h.password,
                    remark: h.remark,
                    name: profile.name,
                    phone: profile.phone
                )
            )
        }
        houseCacheTip = "正在重建 \(active.count) 套房源的分享链接…"
        Task {
            var ok = 0, fail = 0
            for it in items {
                do {
                    _ = try await CosUploader.autoRegenerateMaskedShare(mediaFiles: it.files, roomKey: it.roomKey, info: it.info, config: config)
                    ok += 1
                } catch {
                    fail += 1
                }
            }
            await MainActor.run {
                houseCacheTip = "分享链接已全部重建：\(ok) 间成功" + (fail > 0 ? "，\(fail) 间失败（可再次刷新重试）" : "") + "\n旧分享链接已全部失效"
            }
        }
    }

    // v1.75：离线重建房源——无需联网，从本机 media 账本（每套 info.json）重建/刷新房源记录
    private func runOfflineRestore() {
        guard let houseCtx = houseModelContext else {
            showMessage = "房源数据容器不可用，请重启 App 后重试"
            showAlert = true
            return
        }
        let n = LocalHouseLedger.restoreAll(houseContext: houseCtx)
        if n > 0 {
            showMessage = "离线重建完成：已从本地账本恢复 \(n) 套房源"
            showAlert = true
            NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
        } else {
            showMessage = "未找到本地账本（media 文件夹中没有 info.json）。请先联网同步一次生成账本，或使用「恢复数据」。"
            showAlert = true
        }
    }

    // v1.12：统一备份（快速/全量），复用备份中心逻辑
    private func performNewBackup(kind: BackupKindV5) {
        guard let houseCtx = houseModelContext else {
            showMessage = "房源数据容器不可用，请重启 App 后重试"
            showAlert = true
            return
        }
        if kind == .fast {
            if let url = BackupV5Manager.createFastBackup(mainContext: modelContext, houseContext: houseCtx) {
                BackupLogStore.log(category: "备份", action: "快速备份", result: "成功", detail: url.lastPathComponent, checksum: BackupV5Manager.sha1OfFile(at: url) ?? "")
                Task {
                    await CloudBackupService.autoUploadFastBackup(zipURL: url, config: nil)
                }
                showMessage = RemoteConfig.tip("quickBackupOk", "快速备份成功：{file}\n已自动上传云端（若网络失败会在下次打开 App 时自动重试）").replacingOccurrences(of: "{file}", with: url.lastPathComponent)
            } else {
                showMessage = "快速备份失败，请检查存储空间"
            }
            showAlert = true
        } else {
            if !BackupV5Manager.hasFreeSpace(needed: BackupV5Manager.collectMediaFileEntries().reduce(0) { $0 + (BackupV5Manager.fileSize(at: $1.fileURL)) }) {
                showMessage = RemoteConfig.tip("fullBackupSpace", "存储空间不足，全量备份至少需要与照片视频等量的剩余空间")
                showAlert = true
                return
            }
            showMessage = "正在生成全量备份…"
            showAlert = true
            Task {
                let url = await BackupV5Manager.createFullBackup(mainContext: modelContext, houseContext: houseCtx) { _ in }
                await MainActor.run {
                    if let url = url {
                        BackupLogStore.log(category: "备份", action: "全量备份", result: "成功", detail: url.lastPathComponent, checksum: BackupV5Manager.sha1OfFile(at: url) ?? "")
                        showMessage = RemoteConfig.tip("fullBackupOk", "全量备份成功：{file}\n可在「查看备份文件」中手动上传到云端").replacingOccurrences(of: "{file}", with: url.lastPathComponent)
                    } else {
                        showMessage = "全量备份失败，请检查存储空间"
                    }
                    showAlert = true
                }
            }
        }
    }

    // v1.17 需求2：崩溃日志改为内置查看器（CrashLogsView），此函数不再使用，删除以避免系统分享表单空白。
    // 原逻辑：无日志时提示；有日志则弹系统分享面板（UIActivityViewController 在部分机型空白）。

    // 清空数据
    private func clearData(type: DataBackupManager.BackupType) {
        let success: Bool
        switch type {
        case .deals: success = backupManager.clearDeals(modelContext: modelContext)
        case .properties: success = backupManager.clearProperties(modelContext: modelContext)
        case .payouts: success = backupManager.clearPayouts(modelContext: modelContext)
        case .total: success = backupManager.clearAll(modelContext: modelContext)
        }
        showMessage = success ? (type == .total ? "全部数据已清空" : "\(type.rawValue)已清空") : "清空失败，原数据已保留，请重试"
        showAlert = true
    }

    private func saveAutoSettings() {
        let previous = UserDefaults.standard.data(forKey: "autoBackupSettings").flatMap { try? JSONDecoder().decode(AutoBackupSettings.self, from: $0) }
        let settings = AutoBackupSettings(enabled: autoBackupEnabled, frequency: backupFrequency, hour: backupHour, minute: 0, lastBackupDate: previous?.lastBackupDate)
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "autoBackupSettings")
            UserDefaults.standard.removeObject(forKey: "autoBackupCompletedSlot")
            UserDefaults.standard.synchronize()
            NotificationCenter.default.post(name: .autoBackupSettingsChanged, object: nil)
        }
    }

    private func loadAutoSettings() {
        if let data = UserDefaults.standard.data(forKey: "autoBackupSettings"),
           let settings = try? JSONDecoder().decode(AutoBackupSettings.self, from: data) {
            autoBackupEnabled = settings.enabled
            backupFrequency = settings.frequency
            backupHour = settings.hour
        }
    }
}

// MARK: - v1.17 需求2 崩溃日志内置查看器（替代系统分享面板；右上角导出 txt 到 App 根目录）

struct CrashLogsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files = CrashLogCollector.logFiles()
    @State private var exportTip: String?

    var body: some View {
        NavigationStack {
            List {
                if files.isEmpty {
                    Text("暂无崩溃日志")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(files, id: \.self) { file in
                        NavigationLink {
                            CrashLogDetailView(fileURL: file)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.lastPathComponent)
                                    .font(.subheadline.weight(.medium))
                                Text(firstLine(of: file))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .navigationTitle("崩溃日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                // v1.17 需求2：右上角「导出」→ 直接生成崩溃日志 txt 到 App 根目录（Documents）
                ToolbarItem(placement: .topBarTrailing) {
                    Button("导出") { exportAll() }
                        .disabled(files.isEmpty)
                }
            }
            .alert("导出崩溃日志", isPresented: Binding(
                get: { exportTip != nil },
                set: { if !$0 { exportTip = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(exportTip ?? "")
            }
        }
    }

    /// 取日志首行摘要（时间/异常标题）
    private func firstLine(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: "\n").first ?? ""
    }

    /// v1.17 需求2：把所有崩溃日志合并导出为一个 txt，命名「崩溃日志_导出日期.txt」，落盘 App 根目录
    private func exportAll() {
        guard !files.isEmpty else {
            exportTip = "暂无崩溃日志可导出"
            return
        }
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        df.locale = Locale(identifier: "en_US_POSIX")
        let fileName = "崩溃日志_\(df.string(from: Date())).txt"
        var lines = ["公寓管家 · 崩溃日志", "导出时间：\(Date())", "共 \(files.count) 份", "=================="]
        for url in files {
            lines.append("")
            lines.append("【\(url.lastPathComponent)】")
            let body = (try? String(contentsOf: url, encoding: .utf8)) ?? "(读取失败)"
            lines.append(body)
        }
        let fileURL = DataRoot.url().appendingPathComponent(fileName)
        do {
            try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            exportTip = "已导出到：\n\(fileURL.lastPathComponent)\n\n（App 根目录 / 数据文件夹）"
        } catch {
            exportTip = "导出失败：\(error.localizedDescription)"
        }
    }
}

/// 单份崩溃日志详情（展示完整内容）
struct CrashLogDetailView: View {
    let fileURL: URL
    @State private var content = ""

    var body: some View {
        ScrollView {
            Text(content.isEmpty ? "（内容读取失败或为空）" : content)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(fileURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }
    }
}

// MARK: - v1.17 需求10 三端互通详细介绍及使用说明

struct InterconnectionInfoView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("你的公寓管家由三个端协同工作：")
                        .font(.subheadline)
                    Text("① 手机 App（本地经营数据 + 房源分享）\n② 腾讯云函数 gongyu-stats（云端统计与后台网关）\n③ 云端后台网页（网页 / App 内打开的后台）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("三端是什么")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• 每次生成新的分享 H5 链接，访客点开时页面会自动、静默地向云函数发一次访问记录（房号 + 模式 + 来源）。").font(.footnote)
                    Text("• 云函数把记录追加写入云端桶 statistics/ 下的按日文件，后台的获客统计由这些真实记录聚合而来。").font(.footnote)
                    Text("• 房源文字 + 媒体存云端桶 h/；云端操作记录（带用户名）存 h/_ops.json，同桶多用户可见是谁在操作。").font(.footnote)
                    Text("• 后台可「清空访问统计」一键删除所有埋点记录（含 test101 等测试数据）。").font(.footnote)
                }
            } header: {
                Text("数据是怎么流动的")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• App 内「管理后台」= 云端后台网页，直接用 App 打开，免登录（自动带口令哈希）。").font(.footnote)
                    Text("• 网页版打开同一地址需输入后台口令。口令可在 App 设置里修改，保存后自动同步到云函数与云端后台。").font(.footnote)
                    Text("• 分享记录按用户名隔离存云端桶（h/_share_records_<用户名>.json），各用户只看自己发的分享。").font(.footnote)
                    Text("• 桶文件管理逐级浏览，点进房源文件夹会自动展开 media/ 直接看媒体文件；顶部有「储存用量」卡片显示总占用与分项。").font(.footnote)
                }
            } header: {
                Text("后台怎么打开")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• 单用户：填好云函数地址 + 桶配置 + 用户名即可，房源/备份自动上传云端，后台看统计与用量。").font(.footnote)
                    Text("• 多用户：几台手机填同一套桶配置、各自填不同用户名，房源云端共享（一台录入另一台下拉同步可见）；名片/水印/统计/备份按用户名隔离，互不读取。").font(.footnote)
                    Text("• 操作日志分「本机 / 云端」两区：本机操作记本地，本机发起的云端操作记到云端区；云端区显示操作者用户名。").font(.footnote)
                }
            } header: {
                Text("单用户 / 多用户")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• 分享 H5 的缓存存在本地，「刷新分享缓存」只清理本机缓存，不影响云端。").font(.footnote)
                    Text("• 房源板块下拉刷新 / 左上角手动同步都是拉取云端房源到本地，效果一致。").font(.footnote)
                    Text("• 云端后台每个板块顶部有「刷新」按钮；操作日志云端区可下拉刷新。").font(.footnote)
                    Text("• 版本更新记录在「设置 → 关于」查看；本说明随 v1.37 提供。").font(.footnote)
                }
            } header: {
                Text("缓存与刷新")
            }
        }
        .navigationTitle("三端互通说明")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 版本更新介绍
struct VersionHistoryView: View {
    let versions: [(version: String, date: String, changes: [String])] = [
        ("v1.99", "2026-10-30", ["新增：AI【抄表精准化】——指定某几个表号/房号抄表时只刷新指定电表（不再误触发全量刷新）；表号不在绑定列表时自动拉取云端绑定、加入清单后再抄，逐台汇报结果", "新增：AI【账单图片多张全发】——一次生成多套房账单时生成几张就在对话里展示几张，每张标对应房号；长按图片可分享到微信或保存相册", "新增：AI【可教学规则】——可用指令一步步教 AI 完成代码里没有的复合操作（操作名+步骤存本地），之后说出操作名 AI 直接展开执行", "新增：AI【历史记录展示图片】——历史列表展示 AI 生成的账单图等产物，单击可放大", "优化：AI【思考过程细化】——「正在思考…」改为展示具体执行步骤（如正在抄表 012030（2/3）、正在生成账单图片、正在整理回复…）", "新增：AI【图片单击放大】——对话与历史中 AI 产物图片单击全屏查看", "新增：AI【产物统一存储+缓存管理】——账单图片/导出表格统一存沙盒根目录「AI产物」文件夹；设置页新增「AI对话缓存」行（样式同数据文件夹大小），显示占用、二级确认清空", "优化：电表【总刷新并发提速】——刷新全部电表由逐台串行（每台间隔1.5秒）改为并发3路+交错启动限速，34台约51秒提速至20秒内完成", "新增：工作台【单月收租统计】——快捷操作新增「收租统计」入口：选择年月列出全部房源（房号+房东+交租日+当月含水电结算标记），多选自动算实收合计，按模板生成「X月份租金合计」文案（无预存/有预存/含水电结算+合计等式），一键复制"]),
        ("v1.98", "2026-11-03", ["新增：AI【历史查看】——AI 助手顶栏新增历史按钮（时钟图标），弹出全部对话历史列表（含执行标签/账单图标记/时间），可一键清空", "修复：工作台【待收租「收」按钮保存无效】——新建月度收租记录未先写入数据容器导致保存被静默丢弃；修复后保存失败会明确报错（红字显示在弹窗内）且弹窗不关闭", "修复：工作台【快捷收租跨月写错期】——1号交租提前几天出现在待收租列表时（如10月显示11月应交），原代码把租金写入当前月导致点收无效；现按提醒应收期（年+月）写入，弹窗明示应收期，提前交下期租也能正确入账", "修复：AI【联网搜索改百度主通道】——主用百度搜索（国内真实可用），必应 RSS、DuckDuckGo 降级为备用，百度搜不到时才切换", "新增：AI【直接生成账单图片】——AI 生成账单时复用收租页手动生成版式渲染高清账单图，直接显示在对话气泡里，长按可保存分享", "优化：AI【回复提速】——云端用量拉取加缓存且超时减半；历史注入精简；回复加长度上限，首字更快", "优化：AI【页面定位与历史】——进入对话页自动定位到最新消息；历史页正序展示、进入后自动滚到最新、支持搜索；历史保留最近 1 年", "修复：工作台【收租后待收租提醒不消失】——当月已收只看下月、不校验下月是否已收导致提前收的下期租仍显示提醒；现滚动找第一个未收期，收完即消失", "新增：AI【历史长消息展开/收起】——长消息默认折叠3行，单击展开全文/再单击收起", "修复：账单分享【点微信卡死+面板不自动关闭】——分享改为先压缩写临时JPEG文件再以文件URL分享，并在分享完成回调强制关闭弹层，三处分享统一生效"]),
        ("v1.97", "2026-11-01", ["新增：AI【安居客全量明细分析】——每套房源明细（今日/累计点击、租金、户型、推广状态、房态）全量注入，支持点击排名/推广/房态按指令分析", "修复：AI【生成账单超时】——请求超时 120s→240s + 新增「生成 XX 房 XX 月账单」工具动作，账单由合同数据直接生成，不再靠模型编长文", "新增：AI【任务后台化】——对话页关闭不中断执行中任务，App 划掉才终止；确认框挂起重开自动弹出", "新增：AI【思考期间可继续发送排队】——发送按钮不再被转圈取代，排队自动发出并显示角标", "修复：AI【房源操作日志改云端】——AI 改房源状态/信息的日志记云端（共享），与手动操作一致", "修复：AI【电表全量列出】——去掉 15 台上限，34 台完整展示，电量从低到高排序", "新增：AI【微信式双气泡】——AI 回复加灰色底气泡，用户绿底白字，双方均有气泡", "新增：AI【生成 Excel/CSV】——可导出电表/安居客/房源/欠租/收租汇总/杂项，保存到沙盒根目录", "新增：AI【回复预选项】——每轮回答给 2-3 个下一指令快捷 chips，点击直接发送", "新增：AI【联网搜索】——支持搜索公开资料返回标题/链接/摘要", "新增：AI【欢迎页 10 分钟冷却重现】——超 10 分钟无对话再次进入自动重展示问候语与场景", "新增：AI【默认偏好模板】——房产中介场景定制模板首次自动写入，设置页可一键填入/修改"]),
        ("v1.96", "2026-10-30", ["新增：AI 助手【工具调用全量接入】——6 大领域工具 34 个动作，AI 可直接操作 App：新增/编辑房源、切换待租已租（支持批量）、移入回收站/还原、标记收租/取消、修改收租设置、记成交、记杂项收支、管理待办、刷新电表/安居客、新建快速/全量备份、设置电表预警与定时刷新、查询欠租/租约到期/收租汇总", "新增：AI 写操作【系统确认框】——执行前弹窗列出全部动作明细（删除/覆盖类按钮标红），点「执行」才落地，点「取消」不执行任何更改", "新增：AI 执行动作【气泡标签】——回复气泡展示实际执行过的动作小标签（如「房源·2334 已租」「收租·2-1006 已收」），一眼可追溯", "新增：AI 操作日志【AI 标识】——AI 执行的写操作动作名带「（AI）」后缀，与手动操作区分留痕", "新增：AI 执行结果【汇报机制】——写操作后 AI 用大白话汇报改了什么（房号/谁）、多少钱、什么时间、结果如何", "新增：工具执行过程【可视化】——思考气泡按阶段显示「思考中/等待你确认/正在执行」，确认框弹起时提示待确认项数"]),
        ("v1.95", "2026-10-29", ["修复：崩溃弹窗只弹一次——只对「新增」的崩溃日志弹，同一日志不再每次启动重复弹", "修复：AI「正在思考」指示改为动态转圈（ProgressView 旋转动画）", "新增：AI 对话文字可长按复制", "新增：AI 助手接入云端用量——发送前实时拉取腾讯云桶占用（文件数/MB），云端监控场景可直接回答", "新增：电表盯防真正落地——全局定时器按设定间隔自动刷新电表（此前开关未接定时器等于没生效）；AI「电表盯防」场景一键开启（每 2 小时 + 低电量通知）"]),
        ("v1.94", "2026-10-29", ["新增：AI 助手【全量数据接入】——系统提示除房源快照外新增 App 经营数据快照：本月应收/已收/未收租金、未结清水电结算、本月杂项收支、未完成待办、电表余量（合闸/拉闸/低电量预警）、安居客统计（今日点击/推广/端口/套餐/神奇分/房产币/全城排名），五大快捷场景（云端监控/用量查询/电表盯防/批量账单/数据问答）均可读取真实数据回答", "修复：设置页 AI 模型列表编译失败——Xcode 26.3 Release 模式 body 类型检查超时，已把设置页 Form 拆分为 4 个独立子视图，编译通过"]),
        ("v1.93", "2026-10-29", ["新增：AI 助手设置页模型列表【开通状态标注】——每个模型后标注「已开通 / 未开通」（火山方舟控制台 2026-10-29 实测核实），模型说明框同步显示状态；当前账号已开通 3 个：turbo / 2.1-lite / Evolving，其余需到控制台「开通管理」页开通后方可调用", "修复：AI 错误提示【中文化】——模型未开通（ModelNotOpen 404）、额度不足（QuotaExhausted/429）、Key 无效（401/403）、服务繁忙、模型不存在等常见错误全部映射为中文提示，不再甩英文 JSON", "修复：AI 输入框【等待回答时不锁死】——发送后仍可继续输入文字/选相册/文件，回答完成后可直接发送"]),
        ("v1.92", "2026-10-29", ["修复：AI 发消息闪退根治——根因是 AI 助手用房源数据时错误地用了主容器 ModelContext（主容器 schema 不含 House 实体，fetch 抛 NSInternalInconsistencyException 直接崩溃），已改为房源专用容器 houseModelContext", "修复：崩溃日志信号处理器彻底去动态分配——信号回调内不再调用任何堆分配（malloc/数组构造），全部改为 install 时预初始化的静态缓冲 + 纯 C 接口，杜绝崩溃现场二次崩溃", "调整：取消安居客页头部固定——概览卡/预警卡/工具行回到 ScrollView 内随列表整体滚动", "调整：取消电表管理页头部固定——统计卡/工具行回到 ScrollView 内随列表整体滚动", "补全设置页版本更新介绍 v1.87-v1.91 条目"]),
        ("v1.91", "2026-10-29", ["修复：AI 发消息闪退——崩溃日志信号处理器本身存在二次崩溃隐患，已改为纯 C 接口写入日志", "调整：安居客概览卡删除「刷新时间」行（数据抓取时间保留在导航栏副标题）", "调整：安居客房源卡片推广状态改为【封面左上角胶囊】——58 同城与安居客推广同步合并，同时含「精选」时只显示精选、否则显示普通推广", "调整：安居客页面【头部固定】——概览卡/预警卡/排序工具行固定，仅房源列表滚动", "调整：电表管理页面【头部固定】——统计卡与工具行固定，仅电表列表滚动", "新增：AI 助手模型列表全量接入火山方舟账号已开通模型（共 22 个对话模型，全部带免费额度）：豆包系列 9 个 + DeepSeek 系列 4 个 + Kimi/GLM/Qwen 系列 9 个，附中文说明，设置页直接切换", "调整：房源卡片字段显示精简——去掉「顺德-龙江」前缀与面积；实地核验只显示「核验成功」；点击量行保留显示"]),
        ("v1.90", "2026-10-29", ["修复：崩溃日志全面升级——信号崩溃（SIGABRT 等）写入【完整调用栈】（信号安全接口 backtrace_symbols_fd）；日志改为【无限记录】（不再删除旧文件，同秒多次崩溃自动加序号各存一份）", "修复：安居客顶栏配色与 AI 助手/电表监控统一（深绿渐变 + 白色按钮），高度收窄（96 → 62）", "新增：安居客概览卡第一栏改为 6 项——今日点击/推广房源/剩余端口/套餐剩余(天)/神奇分/房产币（后两项从后台页面自动抓取）", "新增：安居客房源列表显示【封面图】——抓取时自动收集每套房封面缩略图并下载到本地", "调整：房源卡片点击量行（今日点击加粗深绿/累计/较上次±N 分色 + 平台胶囊 + 维护人）恢复显示；推广状态改为平台锚定精确提取并合并显示"]),
        ("v1.89", "2026-10-29", ["修复：AI 助手顶栏与聊天区连体——顶栏改深绿渐变（与 App 主题一致）、按钮改白色高对比", "修复：AI 助手输入框整体下移贴底（背景延伸到屏幕底部安全区）", "修复：对话内编辑文字闪退风险——附件图片移除按钮越界加固", "修复：安居客后台点「读取」报「执行JavaScript返回结果的类型不受支持」——抓取脚本末尾返回 void，经 messageHandler 异步回传", "修复：安居客后台顶栏配色——深绿渐变改为安居客品牌蓝渐变（主页面与登录页统一）", "新增：AI 助手设置模型列表支持云端扩展——内置已开通模型并附说明，「远程配置 → AI 模型清单」可追加其他已开通模型（含免费）"]),
        ("v1.88", "2026-10-29", ["AI 助手六项升级：①顶栏改浅色配色、高度收窄；②支持多轮对话（自动携带上下文）；③接入 App 本地房源数据——提问自动把房源快照注入系统提示，问「有几套未出租」直接据实回答；④回答前显示「正在思考」气泡；⑤对话历史自动保留（最近 60 条，顶栏可一键清空）；⑥支持发送图片/视频（自动截首帧）/文件（txt/md/json/csv/pdf 自动提取文本）", "修复：快捷操作「排序」页改版——上区点减号收进「更多」、下区点加号移回工作台，拖拽排序保留，改动即时保存"]),
        ("v1.87", "2026-10-29", ["修复：AI 助手设置改为「输入即保存」——API Key/模型/接口端点/偏好模板改动立即生效，移除旧「保存」按钮", "修复：设置里默认模型名改为火山方舟正确模型 ID（doubao-seed-2-1-turbo-260628，旧短名自动迁移）", "修复：自定义模型 ID 保存后再次进入设置自动回填显示", "修复：电表管理批量导出记录全选按钮支持反选（已全选时变为「取消全选」）", "修复：工作台「更多」面板关闭后切换板块不再重复弹出"]),
        ("v1.86", "2026-10-29", ["修复：工作台快捷操作补入「安居客」「AI 助手」两个入口（旧版本安装自动迁移，打开 App 即可见，排序可自行调整）", "新增：设置页加入「安居客后台」设置入口（后台 URL / 实地核验预警天数 / 下架预警天数 / 最大翻页数 / 历史快照开关）", "新增：设置页加入「AI 助手」设置入口（API Key 存钥匙串、模型选择、接口端点、偏好模板），入口显示 Key 配置状态"]),
        ("v1.85", "2026-10-29", ["新增「安居客后台」板块（工作台 → 安居客，移动经纪人真实图标）：读取你自己的安居客/58 移动经纪人推广房源数据（今日/累计点击、房态天数、已编辑天数、推广平台、核验/维护/视频/质量），本地保存、历史快照留痕（最近 30 次），只读展示、绝不做任何发布操作", "登录方式：App 内嵌后台页面，登录一次持久（cookie 保留），之后点「读取」直接抓取", "预警：房态 ≥ 7 天（默认可改）标红提醒「需实地核验」；已编辑 ≥ 90 天（默认可改）标红提醒「将自动下架」，支持「只看预警」筛选", "概览卡：今日点击 / 推广房源 / 剩余端口 / 套餐剩余天数", "排序：今日点击 / 累计点击 / 房态天数 / 已编辑天数；点击量旁显示较上次快照的增量", "安居客设置：后台 URL、两个预警阈值、最大翻页数、历史快照开关均可修改", "新增「AI 助手」（工作台 → AI 助手，豆包 logo）：火山方舟豆包模型对话，5 个快捷场景一键带入（云端监控 / 用量查询 / 电表盯防 / 批量账单 / 数据问答）", "API Key 只存本机钥匙串（Keychain），不上传不备份；模型、接口端点、偏好模板（调教）都在设置页可改，不做死", "工作台快捷操作升级：默认两行 8 个（成交/收入/支出/收租 + 待办/电表管理/安居客/AI 助手），「更多」收纳后台管理/包租/水电结算/新增房源"]),
        ("v1.84", "2026-10-28", ["修复官方电表接口联调根因：官方接口只认表单格式，App 请求已全部改为表单发送，同步修正数据解析，直连模式全链路实测通过", "新增「电表监控」板块（工作台 → 电表管理）：集中查看全部电表余额/累计用量/状态/抄表时间，进入自动刷新、串行限速查询，仅读取展示、充值仍走官方页面", "双数据源可切换（设置 → 电表监控）：直连接口（默认）+ 网页抓取兜底", "电表管理：一键导入当前微信身份绑定的全部电表 + 手动增删 + 备注房号", "电表卡片三行布局：户号+房号+状态 / 剩余电量+记录充值 / 累计+抄表时间+单表刷新；低电量与拉闸时户号、房号、电量同步变红；单台刷新有刷新中/完成提示", "排序 + 筛选（低于 X 度可输入 + 拉闸）", "充值记录按表查看（进入自动刷新 + 手动刷新按钮）+ 用电趋势（每次刷新自动积累剩余电量走势，原生折线图）", "导出 CSV：自动同步官方绑定（关系始终准确）、默认不勾选、全选只增不减、支持排序与搜索、手动输户号一行一个", "顶栏新增搜索（放大镜）：按户号或房号快速查找电表", "低电量提醒（阈值可配，每天每户最多一次）+ 可选定时自动刷新（默认关）", "电表查询链接自定义更换入口：换微信换链接即更新 openId 并重置会话", "工作台快捷操作改版：两行新布局 + 「更多」收纳 + 自定义排序实时保存"]),
        ("v1.83", "2026-10-28", ["媒体预检优化：无变化刷新时从「逐房号串行列桶」改为「一次整桶拉取比对」，房源再多刷新也只发 1 次云端请求，明显提速", "同步下载限流：账本下载改为每次最多并发 8 套，房源多时不再因瞬时并发过高触发云端限流", "同步失败自动重试一次：弱网/信号切换导致的瞬断会自动补一次，不再手动反复点刷新", "后台功耗优化：通知重建与小组件同步改为「数据保存时」触发，不再每 30 秒空转", "公告链接安全：只放行 http/https 链接，异常 scheme 一律忽略", "崩溃留痕与提示：数据库异常等致命错误自动写入崩溃日志，下次启动提示「上次异常退出」，设置页可导出定位", "媒体补传进度文件级：进度条显示当前房号「本套 x/y 个文件」，一眼分清是图多还是卡住", "云函数请求超时参数化：列桶/用量统计等大操作放宽到 30 秒，不再因大桶超时失败", "新增自动化测试：云函数 19 项核心逻辑测试（口令/签名/超时/路径防护/埋点去重）+ Swift 核心逻辑自测脚本（Mac 上 swift 一键运行）"]),
        ("v1.82", "2026-10-28", ["远程配置页全面中文化：功能开关/数值参数/提示文案/帮助说明全部显示中文名称，英文 key 以小字副标题展示便于对照", "远程配置页排版优化：分区图标化（基础设置/功能开关/数值参数/提示文案/帮助说明/版本更新记录）、公告开关联动显示文字与链接、更新日志支持左滑删除、底部增加保存按钮"]),
        ("v1.81", "2026-10-28", ["远程配置原生化：App 内管理后台新增第 4 个「远程配置」页，公告/功能开关/参数/提示文案/帮助文本/更新日志全部可在 App 内直接编辑保存，不再需要跳网页后台、不再下载文件", "原生远程配置页与云端网页后台同源：加载=云端 configGet，保存=云端 configSave（自动版本+1），保存后同步写本地缓存，断网仍用最新配置"]),
        ("v1.80", "2026-10-27", ["新增「远程配置中心」：云端后台可可视化编辑提示文案/功能开关/参数/公告/最低版本/帮助说明/版本更新记录，保存后 App 启动或同步即生效，无需重新安装", "新增公告横幅：后台填写公告 → App 房源页顶部即时显示（可带链接）", "新增最低版本检查：云端可设置最低版本，低于该版本启动提示更新", "远程配置三级兜底：云端 → 本地缓存 → 内置默认；断网时用本地缓存，首次安装用内置默认，功能不受影响", "提示文案（同步/删除/备份/离线重建等 20+ 条）改为云端可配，不再需要发版改文案"]),
        ("v1.79", "2026-10-27", ["修复账本增量未真正生效：增量对比从「字节全等」改为「业务字段+媒体清单语义」判断，updatedAt 等元数据不再干扰，真正无变化的房源刷新时零写入、不记日志"]),
        ("v1.78", "2026-10-27", ["本地账本镜像改为增量同步：每次刷新逐套与现有账本对比，有差异才写入、无差异跳过（房源再多也只写变化的套数），提示与实际写入套数一致"]),
        ("v1.77", "2026-10-27", ["本地账本镜像改为仅在「左上角云端同步」后重建（下拉刷新不再触发），重建完成有提示并写入操作日志（同步-重建本地账本镜像）"]),
        ("v1.76", "2026-10-27", ["修复「刷新同步提示无变化时未把账本同步到本地」：下拉刷新、云端同步、同步完成的全部成功路径都会重建本地账本镜像（media/<房号>/info.json），保证每次刷新后本地账本与云端一致"]),
        ("v1.75", "2026-10-27", ["新增「离线重建房源」（设置→数据管理）：无需联网，从本机 media 账本（每套 info.json）一键重建/刷新全部房源记录，数据库丢失或断网时可用，不删除现有数据", "修复同步误删「本地账本镜像」：同步对账把每套的 media/<房号>/info.json 当成多余媒体删掉（实测一次删 7 套）——现已排除该文件，不再误删", "同步完成后自动重建/刷新全部本地账本镜像，与云端完全一致", "（说明：房源图片命名自带唯一ID（如 1-2059-JPG-A3F9C2-1.jpg），删除旧图换新图文件名必不同，其他设备刷新可正确同步新图）"]),
        ("v1.73", "2026-10-27", ["刷新/同步结果提示改为原生悬浮横幅：顶部轻量胶囊、自动消失（替代原来占半个屏幕的居中弹窗）", "删除、批量标记等操作结果同样改为悬浮横幅提示", "需要你确认的操作（同步变更确认/删除确认）仍保留弹窗"]),
        ("v1.72", "2026-10-27", ["刷新提示框重做：点刷新立即显示「正在刷新…」横幅+按钮转圈，比对完成才出结果（不再干点没反应）", "修正「版本更新介绍」顺序：改为按日期倒序（v1.71 置顶，此前 v1.50-1.53 误排最前）", "房源卡片租金字体/颜色恢复原样（headline 加粗 + 主题色）", "批量恢复/导入后不再自动上传云端（此前导入即自动传媒体且不建账本）；改为等手动点「刷新同步」先比对再统一补传，并清空自动补传队列", "操作日志动作细化：编辑保存按实际改动字段命名（修改租金同步/修改户型同步/修改状态同步…），不再笼统记「同步房源」", "本地房源账本改一房一账本：与云端同构，每套 media/<房号>/info.json（保存/导入/同步/恢复联动），删除整套=删 media/<房号>/ 文件夹一步到位", "任何涉及云端同步的动作都显示卡片进度条：纯文字编辑保存、状态切换、补传账本均有「同步中」反馈"]),
        ("v1.71", "2026-10-27", ["云端账本改为一房一文件（h/<房号>/info.json）：改一套写一套、并发不再互相覆盖，删除整套=删 h/<房号>/ 文件夹一步到位", "删除一致性：单套/批量删除同删 h/ 与私有区（分享页+首帧图）", "编辑保存只在媒体有变化时才触发上传（纯文字修改不再全量重传媒体）", "媒体上传失败自动重试一次，日志带具体错误原因", "批量删除云端加同步进度条，云端删完才弹完成提示", "刷新进度条完成后自动收起；修复最小化后新任务不显示", "完成提示框全局化：离开房源板块也能点「好」", "房源卡片租金字体与房号一样大", "批量恢复文件选择框白屏缓解", "修复编辑换图后媒体落盘无前缀目录（卡片黑图）"]),
        ("v1.70", "2026-10-27", ["修复「刷新标识不会自己收起」：同步/媒体补传进度条任务完成后 1.2 秒自动收起，不再需要手动点「完成」", "修复「批量恢复媒体后卡片不显示缩略图/显示无实拍图，必须重启才正常」：列表刷新时强制重载每套房源对象（含媒体关系），恢复后立即显示", "云端配置小字说明还原为仅讲配置口径（v1.69 曾误并入版本更新内容，已撤销）"]),
        ("v1.69", "2026-10-26", ["修复批量删除不彻底：此前每套房源并发读改写云端账本互相覆盖，删除 7 套后账本仍残留 3 套，且删除日志只记 4/7、有的只记「删文件夹」；改为单任务串行删除 + 每套一条「彻底删除（本地+云端）」完整日志", "修复同步弹窗/日志显示无前缀房号（1417上 等）：所有弹窗、提示、日志、同步详情一律真实引用完整房号（带 1-/2- 前缀），不再去前缀简化", "新增房源表单房号强制带座号前缀（1- 或 2-），不带前缀无法保存并红字提示；输入时实时红字提示", "批量恢复/清单导入/媒体包导入/扫描补录强制带前缀：无前缀房号不识别到列表，并提示哪些房号不符合规范；删除无前缀目录兼容逻辑（v1.62 遗留回退），减少幽灵房源", "全量备份恢复房号归一：备份中历史带前缀脏数据恢复后统一为「无前缀+座号」内部结构，媒体目录/显示仍带前缀", "房源列表「全部户型」筛选固定在最左，不随右侧户型横向滚动", "更新设置页「云端配置」小字说明（同步机制、待补传媒体、房号前缀规范）"]),
        ("v1.68", "2026-10-26", ["同步/媒体补传改为「确认后执行」：先干跑检查云端缺哪些媒体的详情弹确认框，确认后才开始上传（不再静默后台跑）", "新增同步任务进度条（房源页顶部）+ 可最小化收起到「待补传媒体」页随时查看进度", "修复数据文件夹大小统计漏掉 media 媒体目录（v1.40 起媒体独立目录）", "操作日志颜色修正：云端日志结果字段不总是「成功/失败」，改为明确失败词才标红"]),
        ("v1.67", "2026-10-26", ["修复左上角刷新「点击没反应」：云端媒体对账/补传在后台线程访问 SwiftData 模型导致崩溃，改为主线程提取值快照、后台只做网络请求", "媒体补传与云端对账改为线程安全（SwiftData 属性仅主线程访问）"]),
        ("v1.66", "2026-10-26", ["修复保存房源偶发误报离线（NWPathMonitor 瞬态误判，改为短时等待确认）", "新增「待补传媒体」后补任务页：集中查看上传失败/待补传媒体，一键全部重试、左滑清除"]),
        ("v1.65", "2026-10-26", ["同步补传房源后自动上传本地媒体（幂等+刷新分享页，与批量导入同机制）", "同步「已刷新，无变化」时自动做云端媒体对账：本地有媒体但云端桶缺失的自动补传并提示明细，桶齐才提示无变化"]),
        ("v1.64", "2026-10-26", ["修复批量恢复后同步死循环/云端房源丢失：本地多套房补传云端时改为聚合一次写账本（此前逐个并发「读改写」同一账本文件，最后一次写回覆盖其他结果，实测 7 套只剩 2309 一套；补传失败保持「仅本地」并提示，不再误标「双端」）", "媒体下载兼容 v1.62 及更早的无前缀云端目录（h/2309上/）：账本带 1- 前缀但旧媒体在无前缀目录时也能找到，避免「本地缺媒体」反复循环"]),
        ("v1.63", "2026-10-26", ["房号/媒体目录统一保留座号前缀：1 座、2 座都显示与存储为 1-xxx / 2-xxx（恢复清单、媒体文件夹、列表显示一致；存量无前缀目录扫描/导入时自动迁移归位）", "恢复（云端/本地/旧版 JSON 备份）完成后发刷新通知：媒体也一并恢复后房源列表立即更新，无需退出重进", "云端操作记录不再提供一键清空，改为左上角「多选」勾选后删除（仅本机日志可清空）", "批量导入/批量恢复接入本地操作日志（操作日志-本机操作可查）", "房源板块下拉刷新改成本地刷新：自动检测并补全缺失的媒体记录（磁盘有记录无 → 补建），有变化列出明细、无变化提示「已刷新，无变化」；左上角刷新按钮保持云端同步不变", "批量导入模板示例改为带前缀写法（1-2334上 / 2-1418下），页面说明同步更新"]),
        ("v1.62", "2026-10-26", ["修复批量录入后房源列表不刷新（需退出重进才显示）：导入完成即通知列表刷新", "修复媒体恢复错乱：1 座房号带「1-」前缀（如 1-2245上）与 App 存储的无前缀目录（2245上）不一致，导致媒体读不到、双目录并存——导入/扫描自动归一目录并迁移存量错乱目录，读取兼容带前缀目录", "批量导入/扫描时对带 1- 前缀的目录自动合并到无前缀目录（点一次扫描补录即可修复存量错乱）"]),
        ("v1.61", "2026-10-26", ["批量录入媒体包兼容性加强：zip 支持 DEFLATE 压缩（电脑 WinRAR/发送到压缩文件夹压的 zip 现在能识别），中文文件名编码兼容（GBK 回退）", "媒体包可直接选文件夹（无需压缩）：zip 或文件夹均可，文件夹内按房号分子目录即可", "清单导入预览回显原始输入（1-2245上 不再被删成 2245上）：CSV 写什么预览显示什么；座号留空时房号带 2- 前缀自动判 2 座，状态留空默认待租（页面说明已注明）"]),
        ("v1.60", "2026-10-26", ["导出房源模板 CSV 加 UTF-8 BOM：在 Windows 的 Excel/记事本打开不再乱码", "导入 CSV 编码自动识别：支持 UTF-8（含BOM）/ GBK（Excel 中文版另存）/ Unicode，电脑填好的清单发回手机也能正常读取"]),
        ("v1.59", "2026-10-26", ["批量录入优化：①清单导入新增「导出模板」按钮（生成带表头+示例行的 CSV，可存到文件/发微信）；②「从文件选择 CSV / zip」改用系统文档选择器，修复点击无反应；③媒体包导入增加解析预览（每行显示动作）；④扫描补录/解析预览每行写清动作（新建房源 / 补挂 K 个 / 媒体齐全 / 重复跳过）", "修复扫描补录反复提示补媒体的 bug：扫描模式文件已在正式目录，改为只补建缺失的媒体记录（不再复制文件），确认后再次扫描不再误报", "房源板块导航栏：多选按钮从右上角移到左上角刷新按钮旁边；右上角保留批量导入 + 新增"]),
        ("v1.58", "2026-10-26", ["新增「批量录入」功能（房源列表右上角 ⬇ 图标）：①清单导入——粘贴或选择 CSV（房号,座号,房东,户型,租金,密码,备注,状态），解析预览后一次导入；②媒体包导入——选择 zip（根目录下按房号建文件夹放照片视频），自动挂媒体到已有房、未收录房号自动新建房源；③扫描补录——扫描 Documents/media/ 下已按房号建好的文件夹，自动建房源/补媒体记录", "开启文件共享（UIFileSharingEnabled）：电脑连接后可在访达/文件里看到「公寓管家」的 Documents，把按房号分好的照片视频文件夹拖入 media/ 下，回 App 点「扫描补录」一键录入", "批量导入的房源自动触发：媒体上传云端 + 自动生成分享 H5（与新增/编辑保存后同机制）", "CSV 支持中文逗号/制表符分隔、表头自动识别、重复房号自动跳过并提示"]),
        ("v1.57", "2026-10-26", ["全量备份补齐房源字段：新增导出/导入 cloudStatusRaw（云端状态）与 lastUpdatedAt（最后更新时间）——修复「全量备份恢复后所有房源变『仅本地』，再同步时把云端已删房源当作本地新增补传回云端（已删房源复活）」的隐患", "备份房源结构 schemaVersion 5 → 6（兼容旧备份：缺这两个字段的旧备份恢复时维持原行为）"]),
        ("v1.56", "2026-10-26", ["快速备份不再包含房源字段：快速备份 = 账本 + 媒体清单 + 日志（不含房源、不含照片视频），房源统一从云端同步恢复——彻底解决「恢复旧快速备份后，已删除房源因变成仅本地而被重新上传回云端（复活）」的问题", "恢复快速备份时跳过房源导入（即使旧版备份含房源 JSON 也不再导入），恢复后房源列表需从云端同步拉回；全量备份保持不变（账本 + 房源 + 照片视频）"]),
        ("v1.55", "2026-10-25", ["公开选房链接增加有效期（默认 2 天）：可在「设置 → 房源分享 → 选房链接有效期」调整为 1/2/3/7/15/30 天；重新生成链接会先删除旧壳（旧链接立即失效），到期后旧链接自动打不开", "选房页访问计入获客统计：选房页每次打开/刷新埋点（按用户名分文件），网页后台登录自己的用户名即可看到选房页访问数据", "云端部署包：选房壳内嵌云函数地址不再硬编码，改为自动取当前云函数地址或环境变量 FUNC_URL（同一桶多用户/多部署互不串地址）"]),
        ("v1.54", "2026-10-25", ["新增/编辑房源保存后自动生成脱敏版分享 H5（删旧生成新），选房链接里每间房点开即有完整详情页", "「刷新分享缓存」升级为全量重建：云端旧分享页全部删除（旧链接立即失效）+ 每间房重新生成最新 H5", "选房页名片区永远沉底显示（默认梁涛/13288251132，云端名片更新实时刷新），无房源时中间留白名片沉底", "选房壳模板统一为名片沉底新版布局"]),
        ("v1.53", "2026-10-25", ["选房页 JS 根治：onerror 改为无引号嵌套写法，任何版本生成的壳脚本都不会再坏", "线上壳直接修复为可用版本（脚本正常 + og 签名有效），不再依赖重新生成即可显示房源"]),
        ("v1.52", "2026-10-25", ["修复选房页打开一直「加载中」：封面 onerror 单引号未转义导致脚本解析失败，已修复 JS 转义", "微信卡片提示：分享必须用 App「分享给租客」或微信内右上角分享，复制粘贴链接只显示纯链接"]),
        ("v1.51", "2026-10-25", ["修复选房页封面不显示：封面从 CSS 背景图改为 <img> 标签加载（微信兼容更好），加载失败自动隐藏占位", "卡片点击有反应：有分享 H5 的房源点击直接打开完整详情页；没有的全屏放大封面预览", "修复微信分享卡片无信息：og:url 改用壳自身自定义域名签名链接，og:image 改用第一套房封面（此前指向不存在的 qrcode.jpg 导致微信只显示纯链接）", "设置压缩开关改名「压缩上传媒体（房源+分享）」：新增/编辑房源媒体上传云端与分享 H5 都会压缩（图片长边≤1600、视频 720p），上传更快", "云函数 rooms_json 新增 share 字段（每套房分享 H5 的自定义域名签名链接）"]),
        ("v1.50", "2026-10-25", ["选房链接彻底对齐单房分享H5：App本地生成选房静态壳上传COS，链接用自定义域名签名（与单房H5同机制），微信内正常打开不再下载", "分享出微信卡片：壳内og标题/描述/封面图全走自定义域名，微信分享渲染成卡片（房源实拍图+米兰公馆·在租房源）", "云函数rooms_json支持cd参数：选房页封面/二维码签名URL全部走自定义域名", "未配置自定义域名时App内明确提示（与单房分享H5相同要求）"]),
        ("v1.49", "2026-10-25", ["修复微信打开选房链接变「下载文件」：链接改走 COS 域名（与单房分享 H5 同机制），云函数生成静态壳存桶 users/用户名/rooms/ 并返回 COS 签名链接，微信内直接打开正常显示", "选房页数据仍实时：页面 JS 每次打开/刷新实时拉云端房源/名片/二维码，改房源改名片后租客刷新即最新", "修复云函数中文路径 COS 签名（users/涛/… 此前 403）：原始路径签名+编码路径发送；选房页封面签名改 10 年长效"]),
        ("v1.48", "2026-10-25", ["「公开选房链接」页内新增「编辑名片 / 二维码」直达入口：修改名片/换二维码不用再退回上级菜单，保存后租客刷新选房页即最新", "选房页补微信卡片信息（og 元数据）：微信里分享链接渲染成卡片，浏览器打开为完整网页（修复旧版打开下载数据文件）"]),
        ("v1.47", "2026-10-25", ["新增「公开选房链接」：设置 → 房源分享 → 公开选房链接，一键复制/分享给租客——对方打开实时看到所有待租房源（只显示户型，房东/密码/备注隐藏），新增/下架房源、改租金后刷新即最新", "名片/二维码实时同步云端：名片保存后上传云端 profile.json，二维码保持实时上传 qrcode.jpg；公开选房页每次刷新都读最新名片与二维码", "选房页卡片 2 列正方形网格，封面为视频预览图/实拍图，带完整防保存机制（禁右键/禁长按/图片背景图渲染，与单房分享 H5 一致）"]),
        ("v1.46", "2026-10-25", ["获客统计按用户名隔离（云端）：分享 H5 埋点带用户名，云端按用户分文件记录；后台统计、清空都只操作当前用户名名下的数据，多个用户共用同一云函数地址互不干扰", "App 内获客分析页明确显示统计归属当前用户名；分享记录说明同步更新为实际路径"]),
        ("v1.45", "2026-10-25", ["「打开『文件』App 查看数据文件夹」点击直达房源图片视频所在 media 文件夹：Info.plist 补上 LSSupportsOpeningDocumentsInPlace（此前 iOS 无法定位子目录，只落到文件 App 根目录）", "云端配置页保存用户名 / 云函数地址后返回再进立即显示最新值：页面出现时从存储重读全部配置字段（与分享水印开关、微信二维码同款修法，不再需要退出 App 重进）"]),
        ("v1.44", "2026-10-25", ["详情页自动下载后即时显示：删除媒体/缺文件后自动补缺，下载完成立即刷新媒体区，不再空白占位等重启", "配置备份补全云函数地址与用户名（此前备份只含桶/地域/密钥/域名，换机还原后后台连不上）", "文件 App「用其他 App 打开」导入配置备份被识别：自动复制进备份目录并弹提示，可一键还原", "「从其他位置选择」备份文件按钮修复：文件选择器在列表视图内自挂，点击立即弹出"]),
        ("v1.43", "2026-10-25", ["同步「下载2个删2个」死循环根治：下载只认云端账本名单（不再把视频首帧图/旧分享页等未登记对象当媒体下载），本地多余残留一次清理收敛", "本地删 media 文件后同步刷不回：账本/本地记录/磁盘真实文件三名单对账，缺媒体自动从云端回补、多余跟随删除", "视频 .mov/.mp4 两套名字打架：归一化等价比较（去扩展名小写），下载落盘名与账本完全一致", "日志操作记录区分方向：同步房源（云端→本地）/（本地→云端）、上传媒体（本地→云端）、删除媒体（本地→云端）等明确标注", "详情页打开自动补缺：记录在但磁盘文件缺失且云端有，自动下载回补；云函数配置按钮样式对齐 COS 按钮"]),
        ("v1.42", "2026-10-25", ["断网刷新不再误删本地房源：云端账本读取拆分明细，网络/解析失败必须抛错中止，只有服务端明确 404 才视为云端无数据", "完全断网保存必出提示：实时网络判定 + 媒体上传失败立即弹「已保存到本机，媒体将自动补传」并入队，联网自动上传", "同步提示/日志统一逐套列房号：新增/更新/删除/补传/媒体差异只要有对比差异就列出具体房号（如「新增 1-2036」「云端删除 1-101」）", "后台分享记录读不到修复：云函数 do_shares 双重编码 + 中文路径 COS 签名 403 根因修复（签名按原始未编码路径、发送用百分号编码 URL），分享记录正常返回", "房源卡片底部细进度条实时展示「上传中/同步中 x%」，覆盖上传云端与同步本地两条链路", "微信二维码保存即时生效：保存/清除立即同步桶内 users/<用户名>/qrcode.jpg，已发 H5 动态引用即更新", "全 App 开关即时生效统一排查：按水印开关修法（显式 Binding 写入）修复自动备份开关等同类开关"]),
        ("v1.41", "2026-10-25", ["水印开关即时生效：显式 Binding 拨动即存，设置页入口副标题 onAppear 刷新返回即显示最新", "同步无变化不再弹确认：更新判定改字段级对比（房号/房东/户型/租金/密码/备注/状态/媒体清单，任一不同才算变化）", "后台分享记录空记录不再一直转圈：加载完成标志 + 空态显示「暂无分享记录」", "云端操作日志核对：确认日志真实记录在云端桶（带用户名），全局共享可见为有意设计（多人协作审计）", "媒体同步细粒度（核心）：媒体文件名带唯一 ID，删光旧照片重加新照片不再撞名；编辑保存后媒体即时上传/删除同步删云端；双向 reconcile 媒体差异；恢复备份后视频打不开修复", "快速备份恢复统计去房源字段（房源/照片/视频只在全量备份恢复时展示）；云函数配置三按钮合并为「保存并验证 + 清空地址」；清空全部配置补清云函数地址与用户名"]),
        ("v1.40", "2026-10-25", ["云端私有数据全部收进 users/<用户名>/（分享页/封面/缩略图/二维码/分享记录/备份/媒体镜像），删房连带删用户分享页——多用户数据隔离基础", "本地根目录重建：备份 + media 两平级文件夹，启动幂等迁移；全量恢复 media 解压到 Documents 根（修复 media/media 套层 + 详情乱套）", "云端同步先弹变化确认（含新增房号 / 他人修改者 / 删除 / 补传明细），确认后才应用", "新增/编辑房源无网络先提示仅存本机；房源媒体上传失败入队自动补传（联网自动补）", "水印开关即改即存；分享 H5 媒体上传前 HEAD 探测去重、视频首帧图每次重新生成；H5 缓存命中简化", "桶管理删除仅删云端对象（本机文件保留）；云函数 track 服务端 30 秒去重；后台 401/失败统一文案；操作日志 + 崩溃日志并入快速/全量备份", "云函数地址独立保存/验证/清空、口令入钥匙串；部署包下载改 App 内图文教程；分享记录写新路径并清旧路径；全量备份媒体完整性校验；旧备份兼容 + 上传幂等"]),
        ("v1.24", "2026-10-24", ["多用户数据隔离：云端备份按用户名分目录（backups/<用户名>/），各用户只看得见自己的备份，另一台手机读不到你的经营数据；媒体镜像按内容去重共享（不含隐私）", "分享记录按用户名隔离（h/_share_records_<用户名>.json），各用户只看自己发的分享；网页后台同步按用户名读取", "用户名不设默认（不预填「涛」），保存时强制非空；云端保存时若没设用户名会提醒，未设名时备份/分享统一归到「未设置」名下，不会误覆盖别人数据"]),
        ("v1.23", "2026-10-24", ["桶管理修复：文件行的「复制下载链接」与「删除」按钮独立区分（此前 iOS 17 列表手势会误触发删除），复制不再误弹删除框", "桶管理顶部新增「访问腾讯云储存桶」图标：一键跳浏览器腾讯云 COS 控制台（登录后可直接管理桶）", "桶储存用量卡片移到桶管理页顶部（原在获客分析），获客分析保留「清空访问统计」按钮"]),
        ("v1.22", "2026-10-24", ["App 内管理后台补齐为完整最新版：获客分析页新增「桶储存用量」卡片（总占用 + 分项，可刷新）+「清空访问统计」按钮（一键删除 test101 等测试埋点，重新累计）", "桶管理改走云函数接口（与网页后台一致）：点进房源文件夹自动展开 media/，图片视频直接显示，不再空白", "以后网页后台每次改动，App 内后台同步生效；浏览器版作为可选补充"]),
        ("v1.21", "2026-10-24", ["设置页云端配置新增「刷新网页后台缓存」：以后网页后台每次改动（重新部署云函数）后，点一下这个按钮就清掉网页缓存、换新版本戳，再打开后台立即是最新版，不用重新构建 App", "管理后台右上角 Safari 打开网页后台时，改用动态版本参数强制浏览器取最新页，网页改完不会再看到旧版"]),
        ("v1.20", "2026-10-24", ["云端后台时间改为北京时间（此前显示像美国时区），新增「清空访问统计」一键删除 test101 等测试埋点，可重新统计", "桶管理点进房源文件夹自动展开 media/ 直接显示媒体文件，少点一层；新增「储存用量」卡片显示总占用与分项（访问统计/房源媒体/房源分享/云端备份）", "操作日志分「本机操作 / 云端操作」两区：本机操作记本地，本机发起的云端操作直接记到云端区（不重复显示）；云端区显示操作者用户名，同桶多用户的桶操作会同步显示", "操作日志支持左滑删除 + 多选删除（进入编辑模式勾选后删除）；云端区删除走云端记录，下拉可刷新", "云端配置板块新增「使用说明」：单用户 / 多用户详细操作说明（展开块式，大白话），三端互通说明移入云端配置", "分享 H5 缓存口径统一：缓存存本地，刷新只清本地，不影响云端"]),
        ("v1.19", "2026-10-24", ["一套配置、多人使用：房源在云端共享（新增/编辑/状态变更自动双写云端），两台手机或两个人用同一个桶可互相看到房源", "房源卡片新增三态标识「本地 / 云端 / 双端」，卡片显示最后更新时间（首次录入时间，改已租/待租时刷新）", "房源板块新增下拉刷新 + 左上角手动同步（拉取云端房源），共享房源以「最后保存的为准」", "纯云端房源（别人录入的）可一键下载到本地；编辑/分享/一键保存会自动先下载再操作", "删除房源提示是否同步删除云端；操作日志全面接入成交/收租/包租/水电/分享/导出等所有动作", "操作日志：保留 45 天、显示操作者用户名（云端多用户可见是谁操作的）、查看器加搜索框、设置页显示日志占用空间", "设置页新增「多用户」：填用户名 + 一键导出「给别人用」的配置（bucket/密钥/域名/云函数/用户名），发给别人填上即可共享"]),
        ("v1.18", "2026-10-23", ["云端后台统一成一套自适应（responsive）：手机 / 桌面同一网址，浏览器与 App 打开同一个后台，排版随屏幕自动适配", "设置页新增「云端配置」板块（合并原远程配置）：云函数地址（后台网址）、COS 存储桶/密钥/域名、后台口令、下载云端部署包集中在一处", "首页「管理后台」入口链接改为可设置：随「云端配置 → 云函数地址」走，别人部署后填自己的地址即可打开他自己的后台", "新增「下载云端部署包」：把一键部署脚本 + 图文说明（zip）导出到本地，发给房东在电脑上运行即可在自己的腾讯云部署云端后台", "取消单机 / 云端模式切换构想：保持「本地数据 + 云端桶/云函数」既有结构，本地记账数据始终保存在本地"]),
        ("v1.17", "2026-10-23", ["修复点房源卡片闪退：成交/在租/退租的关联查询改用主容器，不再在房源独立容器查未注册模型", "崩溃日志改为内置查看器：逐份查看完整内容，右上角「导出」直接生成 txt 到 App 根目录（命名「崩溃日志_导出日期」）", "操作日志右上角「完成」改为「导出」：直接生成 txt，命名「操作日志_导出日期」，存 App 根目录", "分享水印改为叠加在每张图片的右下角（不再是页面右下角）；预览同步为多张图片、每张各自带水印", "App 内「管理后台」直接换成云端后台（网页 WebView），免登录打开", "设置里修改「管理后台口令」保存后自动同步云函数（云端后台、网页后台立即用新口令）", "云端后台去掉演示/示例，全部通真实数据：获客统计、分享记录、桶文件管理均读取云函数实时数据", "三端互通非实时处补「刷新」按钮：云端后台每个板块顶部都有刷新，桶文件支持逐级浏览/下载/删除", "App 版本记录更新到 v1.17", "设置页新增「三端互通」详细介绍与使用说明"]),
        ("v1.14", "2026-10-23", ["云端下载备份直接用原名落盘，下载的备份在「查看备份文件」里直接可见可恢复（不再带「下载_」前缀被列表过滤；旧的「下载_」文件自动识别归组显示）", "外部导入备份弹「立即恢复 / 稍后再说」二级确认；立即恢复走完整恢复流程，完成弹窗显示恢复口径（成交/在租/有效房源/照片视频等分行统计 + 全部核对无误）", "恢复云端备份时明确提示来源：本地已有同名则直接用本地恢复、本地没有则自动下载到本地后恢复，完成弹窗与操作日志均写明", "快速备份与全量备份都支持手动上传到云端（快速只传 zip 本体，全量再传照片视频增量）", "房源详情「一键转发朋友圈」改为「转存到微信」：图片（前 9 张）+ 视频全部进分享面板，到微信里选「收藏」后再自行转发朋友圈", "修复房源左滑「删除」确认无反应：合并多个弹窗为单一确认弹窗，消除 iOS 17 弹窗互相覆盖问题", "设置页「清空数据」移到「导出崩溃日志」下方（板块末位）", "本地备份与云端备份一样提供手动刷新按钮", "版本更新介绍补全 v1.12 / v1.13 两条记录"]),
        ("v1.13", "2026-10-23", ["设置页「查看备份文件」全新排版：快速备份 / 全量备份两大板块切换，每个板块内分本地备份、云端备份两组，原有功能全部保留", "备份成功弹提示；修复恢复数据卡死在 38% 的问题", "「打开备份文件夹」直达文件 App；旧版 JSON 备份收纳进折叠入口", "完成按钮移到右上角；云端备份支持实时刷新桶内文件并同步显示", "操作日志只保留一个月；自动备份保留天数数字放在 - + 号中间", "云端只保留最新 10 份自动备份（手动备份、手动上传的全量备份不清理）", "云端下载逐文件 CRC 校验；下载前先检查本地是否已有同名备份，有则直接复用", "分享房源上传到桶时显示百分比进度；房源板块删除到回收站，回收站删房源同步删除桶里的房源文件夹", "系统「用其他 App 打开」zip 可导入公寓管家识别；房号输入自动去空格", "根目录只保留一个「备份」文件夹（快速备份 / 全量备份 / cos 配置备份等子文件夹细分）"]),
        ("v1.9", "2026-10-23", ["设置页顶部空白彻底移除：滚动检测不再用占位行（v1.7/v1.8 残留行占位），改为 UIKit 监听滚动容器偏移，不占任何布局", "修复点「房源」板块闪退：房源软删除字段为可选属性，iOS 17 SwiftData 谓词翻译可选 Bool 会崩溃；改为全量拉取 + 内存过滤，兼容旧库且不再走有风险的谓词", "汇总页 KPI 胶囊改为动态宽度：标题/数值胶囊随文本长度自适应（¥70447 与 ¥20688 宽度不同，不再固定最小宽/被压缩）"]),
        ("v1.8", "2026-10-23", ["修复存储异常：房源模型软删除字段改为可选属性（v1.7 加非可选字段触发 iOS 17 SwiftData 自动迁移失败，打不开旧房源库导致整 App 进入临时模式）", "启动自动找回被隔离的主库文件（此前容器初始化失败时移入沙箱 backup 文件夹的经营数据会自动归位，无需手动恢复）", "设置页顶部空白行移除（滚动检测标记行不再占位）", "页面背景统一为 iOS 系统分组灰（与设置页一致，各功能板块不再偏绿）", "房源板块标题改为「房源管理」"]),
        ("v1.7", "2026-10-23", ["品牌全局统一：所有「房源管家 / 租房管家」残留文案替换为「公寓管家」（含备份提示、数据文件夹说明）", "房源板块底色统一为主 App 深绿主题（背景 / 主色 / 强调色对齐，不再暖白/深墨蓝/琥珀）", "设置页图标与字体配色改为 iOS 原生蓝（房源管家风格）", "设置页顶部横线动态化：页面在顶部不显示，向下滑动、顶栏固定后才显示分隔线", "登记房源房号实时查重：输入即检测，重复房号变红提示（与保存时校验同口径，兼容 1- / 2- 前缀）", "房源板块：移除左上角设置按钮（已合并至主设置）；右上角 + 按钮样式与其他板块统一", "房源卡片左滑菜单：编辑 / 分享 / 删除（删除二次确认后移入回收站，不再直接删照片视频文件）", "回收站：新增房源板块（软删除房源可还原/彻底删除，彻底删除才移除本地文件）；顶部增加板块分类标签筛选；清空支持清空单个板块或全部", "备份/恢复文案更新：「备份租房数据（不含房源）」「恢复租房数据（不含房源）」，补充房源数据备份/恢复说明", "新增「查看备份文件」：设置页数据管理与远程配置备份 COS 处均可用内部浏览组件查看备份文件，不再跳文件 App"]),
        ("v1.11", "2026-10-22", ["设置页两处「查看备份文件」（数据管理 + 远程配置 COS）支持左滑删除，删除前二次确认，删除后列表自动刷新", "「打开『文件』App 查看数据文件夹」点击直接打开房源图片/视频所在 Media 文件夹（不再只打开文件 App 根目录）", "房源卡片左滑：编辑 / 状态按钮改为双色区分（编辑保持 iOS 蓝，状态切换用绿色，不再连排同色）", "房源卡片左滑状态按钮按当前状态动态显示：待租房源左滑显示「已租」（点击改为已租），已租房源左滑显示「待租」（点击改回待租）"]),
        ("v1.10", "2026-10-22", ["房源卡片左滑菜单改为 iOS 原生 swipeActions：样式与其他板块（成交/收租/包租/待办）完全一致，滑动更流畅，不再用自定义拖拽组件", "左滑菜单「分享」替换为「已租」：左滑一键把房源切换为已租状态并保存，默认列表（待租）即时刷新，无需进详情页操作"]),
        ("v1.6", "2026-10-22", ["设置统一：房源板块独立设置页取消，全部合并进主 App「设置 → 房源分享」分组（远程配置/名片信息/分享压缩/刷新缓存/房源数据）", "房源板块左上角设置按钮：一键跳转主「设置」页，全 App 只保留一个设置入口", "UI 按房源管家设置页原生 iOS 风格统一（Form 分组 + 小字说明）", "配色恢复为原租房管家深绿主题"]),
        ("v1.4", "2026-10-22", ["回收站入口调整：移至设置页右上角（图标+文字按钮），不再占用数据管理列表", "工作台「新增房源」：不再跳转房源板块，改为直接弹出登记表单（与新增收租/新增成交一致），保存后房源列表自动刷新"]),
        ("v1.3", "2026-10-22", ["房源板块：户型筛选支持多选（可同时筛选多种户型）", "房源设置：刷新分享缓存增加二次确认，防止误触", "房源设置：移除底部版本号", "分享压缩开关默认开启（此前默认关闭，视频按原文件上传）", "工作台：回收站入口移至设置页，空位新增「新增房源」入口"]),
        ("v1.2", "2026-10-22", ["修复：房源板块闪退（根治）——租房管家与房源管家数据改为两个独立存储容器，房源页面使用专属数据上下文，规避 iOS 17 早期版本多存储配置崩溃问题", "房源数据仍独立存放 Documents/备份/（housekeeper.store），拷贝还原方式不变"]),
        ("v1.1", "2026-10-22", ["修复：与旧租房管家彻底隔离——App Group 改为全新 group.com.gj.tg.shared，桌面小组件/同步数据不再与旧应用互通", "优化：房源板块移至第二个 Tab（工作台之后），通知提醒跳转同步更新"]),
        ("v5.29", "2026-10-21", ["备份数据与恢复数据分开两行显示", "设置页每一行补上系统小图标（与备份/恢复/清空同风格）", "修复备份频率与自定义铃声标题重复显示的问题", "移除设置页底部版本号", "自动备份说明补充：按天自动备份超过7天自动清理，手动备份保留"]),
        ("v5.28", "2026-10-21", ["设置页面改为 iOS 原生清爽风格（Form 分组 + 小字说明），整体更简洁、字体图标回归系统默认大小", "应用名称更新为租房管家"]),
        ("v5.27", "2026-10-21", ["设置页面微信风格：浅灰背景、白色圆角分组卡片、镂空线条图标、行间浅灰分隔线", "备份/数据同步/自动备份/水电单价/自定义铃声各板块增加小字使用说明", "构建流程增加 Release 发布通道，IPA 可通过 GitHub Release 下载", "应用名称更新为租房管家"]),
        ("v5.26", "2026-10-21", ["设置页面改为微信风格：浅灰背景、白色圆角分组卡片、镂空线条图标、行间浅灰分隔线，上下间距、字体大小、色调、背景色按微信设置页统一", "备份/数据同步/自动备份/水电单价/自定义铃声各板块增加小字使用说明", "构建流程增加 Release 发布通道，IPA 可通过 GitHub Release 下载"]),
        ("v1.0", "2026-10-21", ["公寓管家正式版：租房管家（经营工具）与房源管家（获客分享）合体", "完整保留租房管家全部功能：工作台/成交/收租/包租/汇总/设置/回收站/待办/备忘录/账单模板/自动备份", "新增房源管家板块：房源库/实拍图视频/微信卡片分享/H5脱敏页/腾讯云COS远程配置", "房源数据独立存储（备份文件夹），可直接拷贝还原", "全新应用ID（com.gj.tg），与旧应用完全隔离，可并行安装"]),
        ("v5.25", "2026-10-14", ["包租水电结算退出自动保存，不再丢失", "新增待办默认置顶显示", "待办接入回收站，支持还原与永久删除", "水电计算历史支持长按复制"]),
        ("v5.24", "2026-10-14", ["成交金额/杂项收支/汇总净收入补齐纯数字输出，全App金额无千分位点号"]),
        ("v5.23", "2026-10-14", ["账单金额全部改为纯数字输出，彻底消除千分位点号（如 1,500 → 1500）"]),
        ("v5.22", "2026-10-14", ["待办排序稳定化，拖动不再卡死", "首页工作台待办手动排序生效，结果持久保存", "全部待办已办结默认按完成日期降序"]),
        ("v5.19", "2026-10-13", ["完全移除未收租提醒进度条，仅保留提醒列表", "收租管理导出Excel补充预存金额、本月应收、本月状态与收租明细", "分享账单图片金额去除千位点号，出账日期字体加大加粗", "设置新增账单模板设置：固定提示文本可修改、收款码可更换、支持预览", "修复备忘录拖动排序退出APP后复原，手动排序持久保存"]),
        ("v5.18", "2026-10-13", ["修复13号交租水电结算后账单不显示水电结算：账单按结算日期匹配，结算单为空但有金额时显示电费/水费明细", "修复只写水费无电费时累计水电不统计", "修复包租房卡片已付租金统计金额不对：只统计合法期数月记录", "修复工作台首页付租按钮无效：付款记录月统一，保存后立即刷新", "修复收租卡片关闭详情表单后跳到顶部，保留滚动位置", "修复1号交租28号未显示未收租提醒（按下一应收期判断）", "水电结算写入后收租计划金额实时更新", "未收租提醒进度条改为只统计提醒列表内房源数据"]),
        ("v5.17", "2026-09-22", ["成交板块三个标签（成交记录/杂项收入/杂项支出）与收租板块（在租/退租）增加本页数量统计，跟随筛选实时变化", "退租卡片左滑还原增加确认弹窗；退租房源详情页点编辑改为编辑退租信息", "包租详情页右上角改为编辑、左上角改为关闭", "收租计划已打勾后金额锁定不可修改；水电结算金额随时可编辑，取消结算需确认弹窗", "修复备份恢复后回收站记录全部复活的问题（备份补存删除状态）", "汇总统计增加过滤双保险，回收站记录不再计入任何统计"]),
        ("v5.16", "2026-09-22", ["工作台快捷操作新增回收站入口（第4个功能）", "回收站右滑还原增加二级确认弹窗，与永久删除一样先确认再执行", "成交、收租、杂项收入支出、包租删除的记录统一进入回收站，支持右滑还原/永久删除、多选批量还原/删除、一键清空"]),
        ("v5.15", "2026-09-22", ["修复从水电结算表单（详情页左上角、列表页、工作台入口）写入水电后返回界面不刷新的问题", "写入水电成功后自动刷新对应页面（月度收租金额、收租列表、工作台数据）"]),
        ("v5.14", "2026-09-22", ["修复收租详情页写入水电后月度收租金额不即时刷新的问题（水电保存后自动重建月度计划行）", "水电结算输入改为防抖保存（停止输入0.35秒后保存），输入与滑动更流畅", "水电结算计划列表排序去重改为缓存、日期标题格式化静态化，滑动更流畅", "月度收租打勾、改金额后立即保存，避免数据丢失"]),
        ("v5.13", "2026-09-22", ["修复收租计划金额负数结余计算错误：水电结算写入和账单更新时结余符号由加改为减，结余为负（预存用超）时正确相加", "快捷收租、快捷付租弹窗高度改为直接作用于弹窗根视图，确保360紧凑高度生效", "快捷收租默认金额直接读取收租计划当月金额（不再重复加预存）"]),
        ("v5.12", "2026-09-21", ["快捷收租、快捷付租弹窗高度调整到与日期轮盘一致的紧凑高度", "修复未收租提醒卡片不显示水电提示的问题：当月有未结算水电计划时，卡片金额下方显示「需结算水电」"]),
        ("v5.11", "2026-09-21", ["快捷收租、快捷付租弹窗改为自适应紧凑高度（不再半屏）", "未收租提醒金额直接读取收租计划的当月金额（与结算后的计划一致），不再单独计算", "收租计划金额的水电结余匹配统一改为按结算计划日期当月匹配，与提醒判断口径一致"]),
        ("v5.10", "2026-09-21", ["未收租提醒水电判断改为直接读取收租表单的当月结算计划（有记录且未结算才提示需结算，已结算或无记录不提示），不再推算", "快捷收租表单删除水电结算输入项，水电统一在收租详情表单的结算计划中维护"]),
        ("v5.9", "2026-09-21", ["新增/编辑成交表单：房号、房东、租期、管理人、客源改为左右布局", "新增/编辑收租表单：房号、房东、租期改为左右布局", "新增/编辑包租表单：房号、管理人、租期、免租期、水电底数改为左右布局", "包租详情水电结算日期改为轮盘选择（半屏弹出）", "收租详情收租计划日期显示完整年月日且不换行", "修复桌面小组件包租应付读不到数据的问题", "恢复备份时增加确认弹窗，防止误覆盖数据"]),
        ("v5.8", "2026-09-21", ["成交、收租、包租详情表单及快捷收租/付租表单右侧数据由灰色改为黑色加粗显示", "设置页整体优化：除清空数据外所有选项改为白色底色，全部文字改为黑色加粗"]),
        ("v5.7", "2026-09-21", ["户型选择新增复式独立厨房", "水电结算已结算改未结算增加确认提示，防止误触", "修复从收租详情进入水电结算时默认总预存与设置页不一致", "收租卡片已收未收状态改为按下一期交租日提前3天转为未收"]),
        ("v5.6.2", "2026-09-21", ["水电计划使用完整日期显示", "备份恢复和字段稳定修复"]),
        ("v5.6.1", "2026-09-21", ["修复通知角标调度问题"]),
        ("v5.6", "2026-09-21", ["新增手动租金和水电计划编辑", "账单排版优化和支付码并排显示", "桌面小组件数据同步和刷新修复"]),
        ("v5.5", "2026-09-19", ["账单顶部安全间距和副标题压缩", "上下账单统一字号并完整换行", "Widget与主App打包前注入App Group无证书签名"]),
        ("v5.4", "2026-09-19", ["账单字体与完整换行统一", "支付宝微信双收款码并排", "新增出账时间和人工录入提示"]),
        ("v5.3.1", "2026-09-19", ["水电计划随房源信息变化自动更新", "收租金额公式修正", "附加费分享状态修复", "账单排版与小组件同步优化"]),
        ("v5.3", "2026-09-19", ["按HTML样式重做账单图片", "水电结算文字完整显示", "月季结算日期及最后一期修正", "小组件刷新修复"]),
        ("v5.2", "2026-09-19", ["新增收租闪退修复", "水电未结算清空与空值隐藏", "金额支持全删", "取消分享预览"]),
        ("v5.1", "2026-09-19", ["水电计划左右UI及可编辑结算文本", "计划去重排序和新增收租修复", "工作台结余金额修复", "收租账单附加费用和紧凑排版", "所有图片分享增加预览"]),
        ("v5.0", "2026-09-19", ["水电计划去重和账单分享", "收款码账单图片", "桌面小组件打包"]),
        ("v4.9", "2026-09-19", ["全量备份稳定ID", "水电月季计划和详情写回修复", "写入成功关闭表单", "历史降序搜索", "成交联动收租修复", "工作台金额修复"]),
        ("v4.8", "2026-09-19", ["水电保存提示与微信跳转", "收租快捷水电结算与周期写入", "按月按季水电计划及结余联动", "支持单独水费或电费结算", "水电默认单价和预存设置", "在租退租动作调整及成交联动收租"]),
        ("v4.7", "2026-09-19", ["通知角标及打开APP清零", "四类通知独立铃声设置", "水电结算支持带/不带总表及整数结算", "新增结算单复制、保存、历史、编辑删除排序预览和图片分享", "结算历史纳入总备份恢复"]),
        ("v4.6", "2026-09-19", [
            "修复同一时间多个待办只收到一条通知的问题，通知重建改为串行且每条使用唯一ID",
            "收租、包租付租和租期到期通知改为每间房独立发送，并按绿点未逾期、红点已逾期显示",
            "业务通知按未来7天每天11点预排，控制在iOS通知数量上限内",
            "新增通知计划账本，启动或回前台时补发最近6小时应发但未确认的提醒",
            "补发单次最多10条，避免打开APP时集中弹出过多通知"
        ]),
        ("v4.5", "2026-09-19", [
            "设置提醒的未办事项卡片左侧新增黄色发光点",
            "待办事项改为最新添加的优先显示",
            "前台通知支持横幅、通知中心列表和提示音",
            "收租、包租付租和租期到期改为每天11点分组提醒，区分即将到期与已逾期",
            "待办到达提醒时间后每小时持续提醒，归档或删除后自动取消"
        ]),
        ("v4.4", "2026-09-19", [
            "所有公共日期轮盘改为固定高度底部弹窗，不再全屏显示",
            "新增本地通知授权及收租提前3天、包租付款提前3天、租期到期提前7天提醒",
            "待办表单新增可选年月日时分提醒时间",
            "点击业务通知可自动切换到工作台、收租或包租板块",
            "待办提醒时间纳入总备份和恢复逻辑"
        ]),
        ("v4.3", "2026-09-19", [
            "快捷操作和KPI看板统一使用下方板块同款标题栏组件",
            "统一六个工作台板块折叠状态的上下内边距和高度",
            "修复KPI看板标题略微靠右，与其他板块标题左侧对齐",
            "保持快捷操作网格和KPI展开内容布局不变"
        ]),
        ("v4.2", "2026-09-19", [
            "工作台待办改成与全部待办相同的原生List和onMove排序配置",
            "不再强制永久编辑模式，默认不显示右侧排序手柄",
            "取消工作台待办最多显示5条的限制，有多少未办事项就显示多少",
            "列表高度根据待办数量和长文本自动扩展，不再截断内容"
        ]),
        ("v4.1", "2026-09-19", [
            "隐藏工作台待办右侧排序图标，保留整行长按拖动排序",
            "自动备份增加运行期间每30秒检查，不再要求重启APP才能触发",
            "设置变更后立即清理旧时间槽并重新检查计划",
            "使用实际自动备份文件校验本期是否完成，避免错误跳过",
            "自动备份成功提醒改为全局根视图弹窗"
        ]),
        ("v4.0", "2026-09-19", [
            "退租信息保存后自动关闭退租表单和房源详情",
            "工作台待办改用与全部待办一致的原生拖动排序",
            "取消工作台折叠箭头，改为点击区域标题栏空白处折叠或展开",
            "重构自动补偿备份：启动和回前台检查计划时间槽，漏备立即补做并防止重复",
            "自动备份成功后在APP任意页面显示全局提醒"
        ]),
        ("v3.6", "2026-09-19", [
            "修正收租与退租切换位置，优化退租卡片内容和日期显示",
            "退租及待办表单统一使用成交表单同款日期选择器",
            "工作台待办支持拖动排序，全部待办调整搜索布局并放大已办状态字体",
            "工作台四个提醒区域统一折叠，收租进度合并到未收租提醒",
            "修复设置页备份恢复重复弹层、选择无效及自动备份启动补偿逻辑"
        ]),
        ("v3.5", "2026-09-19", [
            "优化收租与退租切换、退租胶囊卡片、退租时间折叠及还原在租流程",
            "完善待办搜索、排序、编辑预览、恢复未办理及删除二次确认",
            "工作台提醒区域支持折叠，收租进度合并到未收租提醒，并对调收支图标颜色",
            "总备份完整包含已办和未办待办，自动备份支持错过计划时间后启动补备份",
            "设置页移除Excel转备份，备份与恢复按钮改为同一行"
        ]),
        ("v3.4", "2026-09-18", [
            "收租新增在租与退租双页，支持退租登记、编辑、删除和分享",
            "退租详情顶部展示退租时间、原因、押金、房损、水电及联系人信息",
            "新增待办事项，支持新增时间、办理日期、拖动排序和未办/已办归档",
            "工作台新增待办区域与快捷入口，完成待办时增加二次确认",
            "快捷操作改为每行4个共2行，并支持快捷操作和 KPI 看板收起"
        ]),
        ("v3.3", "2026-09-18", [
            "iPhone 与 Windows 电脑版版本统一升级至3.3",
            "电脑版整体界面按手机版视觉规范重新设计",
            "统一顶部品牌栏、底部六栏导航、浅灰绿背景和白色圆角卡片",
            "统一按钮、输入框、状态标签及业务编辑表单样式",
            "保留数据导入、业务增删改查、局域网同步和备份迁移功能"
        ]),
        ("v3.2", "2026-09-18", [
            "iPhone 与 Windows 电脑版版本统一升级至3.2",
            "修复 iPhone 向电脑版同步时可能出现 HTTP 400 的问题",
            "补齐 Windows 窗口、任务栏及发布 EXE 的应用图标",
            "按手机端10类数据模型补齐电脑版业务模块和增删改查",
            "统一跨端实体类型并增加旧版桌面数据自动迁移，提升同步兼容性"
        ]),
        ("v3.0", "2026-09-17", [
            "品牌升级为租房管家，正式版本升级至3.0",
            "修复收租详情修改后卡片已收月数、累计水电和待收状态不能实时刷新的问题",
            "收租页和工作台下拉刷新改为真实保存并重新加载数据",
            "月度收租计划按完整租期生成，支持2年及更长租期",
            "修正工作台房源统计：管理仅统计管理类型，托管包租继续合计统计"
        ]),
        ("v2.51", "2026-09-16", [
            "首次交租月选择器改为年月选择（支持选择年份和月份）",
            "修复收租计划左侧年月换行显示问题",
            "修复收租卡片已收月份统计错误：编辑房源时旧收租记录未删除导致重复累加",
            "未收租提醒排序优化：逾期优先，逾期越久越靠上；未逾期的时间越临近越靠前",
            "包租板块卡片排序优化：临近付租优先，逾期优先，逾期越久越靠前",
            "工作台新增包租房付租提醒板块（含快捷付租二级菜单）",
            "即将到期卡片排序优化：越临近到期越靠前",
            "工作台添加下拉手动刷新，显示已刷新提示"
        ]),
        ("v2.50", "2026-09-16", [
            "水电结算规则重构：RentMonthRecord增加year字段，收租计划按年月排序",
            "新增收租表单增加首次交租月选择器，保存时根据租期自动生成收租计划（1年=12月，半年=6月，X个月=X月，月租房=12月）",
            "收租详情页月度收租计划显示为年月格式（如2026年5月），按年月顺序排列",
            "水电结算判断改用收租计划第一个月的年月，修复跨年排序错误和硬编码2025年的问题",
            "备份/恢复数据包含year字段"
        ]),
        ("v2.49", "2026-09-16", [
            "成交卡片：第一行房东换户型（只显示户型值），房号和户型加粗放大16号作为重点突出",
            "收租卡片：右侧三行数据拉开间距、字体放大加粗，第一行已收月数和第二行累计水电做成胶囊状",
            "收租详情：月度收租计划金额默认从月租金改为月租金+预存金额",
            "包租卡片：第一行（下次打租金额）和第三行（房号+户型+付款方式）位置对调，三个胶囊统一大小16号加粗，下次打租金额加粗放大",
            "未收租提醒：卡片右边租金和需结算水电中间加预存数值（有就显示），点收后收租金额默认租金+预存，房号和房东字体放大加粗",
            "恢复白色主题，舍弃v2.48浅灰色版本"
        ]),
        ("v2.48", "2026-09-16", [
            "整体UI浅灰色重构：背景色和卡片/面板色从白色改为浅灰色，降低视觉疲劳"
        ]),
        ("v2.47", "2026-09-16", [
            "本月中介费KPI第三行累计X单改成本月X单",
            "收租卡片重构：删除左侧类型区，第一行交租日+房号放大突出，第二行租金+预存+房东，第三行租期不变"
        ]),
        ("v2.46", "2026-09-16", [
            "修复汇总KPI数值胶囊宽度不一致问题，改用HStack+Spacer确保所有胶囊宽度一致"
        ]),
        ("v2.45", "2026-09-16", [
            "工作台KPI隐藏调整：即将到期/杂项收入/本月收入/杂项支出的第三行文字不隐藏",
            "汇总KPI第二行胶囊缩短一点点"
        ]),
        ("v2.44", "2026-09-16", [
            "所有板块切换后滚动位置不重置",
            "工作台KPI隐藏所有数字（含第三行说明中的数字）",
            "修复收租卡片超宽问题，累计水电永不换行",
            "汇总KPI胶囊宽度调整，第一行拉长第二三行缩短"
        ]),
        ("v2.43", "2026-09-16", [
            "工作台保留滚动位置，切换板块不重置",
            "工作台时间改为时分显示，15秒刷新一次，优化滑动性能",
            "修复收租页面卡片宽度不一致问题",
            "右滑删除和修改按钮添加圆角样式",
            "备份时间移到加减号中间，字体加粗加大",
            "工作台KPI隐藏所有数字（含第三行），星号改为2个",
            "所有隐藏状态持久化，关闭APP不重置"
        ]),
        ("v2.42", "2026-09-16", [
            "修复所有页面滑动卡顿问题，改回单视图渲染",
            "工作台KPI眼睛按钮独立成胶囊状配底色，只隐藏数值不隐藏文字",
            "备份时间移到加减号中间，字体加粗加大",
            "右滑删除和修改按钮添加圆角样式",
            "修复卡片宽度不一致问题"
        ]),
        ("v2.41", "2026-09-16", [
            "汇总KPI改为2+2+1三行布局，数值胶囊带颜色底色",
            "自动备份时间选择修复，显示当前时间",
            "板块切换保留滚动位置，切回时不回到顶部",
            "工作台滑动性能优化，改用LazyVStack",
            "新增眼睛图标隐藏数据功能：工作台6个KPI右上角各一个",
            "成交板块筛选器行加眼睛图标，三个分类单独控制隐藏金额",
            "汇总板块筛选器行加眼睛图标，隐藏KPI和卡片所有数据"
        ]),
        ("v2.40", "2026-09-16", [
            "汇总板块KPI卡片上下宽度缩窄",
            "汇总KPI数据按筛选器时间统计（全部/某年/某月）",
            "汇总下方卡片按筛选器时间展示，默认全部时间",
            "设置页面选项间距缩窄",
            "按天自动备份增加7天自动删除机制，只删自动备份不删手动备份",
            "恢复数据增加二级菜单，选择板块后再显示恢复列表",
            "备份文件命名重新设计：手动备份-总备份-2026.9.16-15.33",
            "所有卡片右滑删除增加二级确认浮框，删除按钮红色"
        ]),
        ("v2.39", "2026-09-16", [
            "副标题改为：X月还剩X天X小时，加油",
            "卡片高亮延迟缩短到0.05秒，去掉动画，修复点2次才出表单",
            "包租搜索框外层背景色修复"
        ]),
        ("v2.38", "2026-09-16", [
            "工作台头像改成正方形圆角",
            "分享图片重新设计排版，增加已收金额/待收租金等具体数据，内容占满页面",
            "副标题改为：宗介，X月还剩X天X小时，加油吧",
            "卡片高亮延迟从0.15秒优化到0.08秒",
            "包租搜索框样式与收租成交统一"
        ]),
        ("v2.37", "2026-09-16", [
            "分享功能回退到UIWindow+sheet方案，点击2次可弹出",
            "工作台时间显示改为时分秒，每秒自动刷新",
            "工作台副标题改为还剩X天X小时",
            "包租表单交租日按起租日自动获取，不再手动选择",
            "卡片点击高亮关闭详情后保持显示",
            "成交板块杂项收入和杂项支出卡片加高亮效果",
            "删除板块切换过渡动画",
            "包租板块上方添加搜索框"
        ]),
        ("v2.36", "2026-09-16", [
            "工作台顶栏时间自动刷新，30秒更新一次",
            "备份文件按修改时间降序排序",
            "恢复数据完成后弹出提示框",
            "收租卡片日期字体统一大小，不再自动缩小",
            "分享功能改用ImageRenderer，修复点击无反应问题",
            "打租计划左边标签宽度加大，显示完整",
            "包租水电结算每行支持右滑删除",
            "收租板块关闭详情后不再跳到顶部",
            "成交/收租/包租卡片点击时高亮边框反馈",
            "数据迁移失败时自动备份旧数据，不再直接删除",
            "板块切换添加淡入淡出过渡动画"
        ]),
        ("v2.35", "2026-09-16", [
            "修复数据丢失问题：PayoutRecord新字段改为可选类型，兼容SwiftData轻量迁移",
            "工作台顶栏右侧日期字体加大，与副标题一致",
            "到期提醒无数据时不显示暂无，与未收租提醒一致",
            "KPI看板杂项支出和本月收入位置对调",
            "KPI看板配色：收入红色，支出绿色",
            "分享功能修复：直接弹出系统分享面板，确保保存相册选项可用",
            "分享图片重新设计：胶囊标签+卡片式布局，月度收租4列网格",
            "包租水电结算改为动态行：默认2行，可添加，日期可选年月日",
            "包租卡片年租显示改为年总租金（付款计划合计）",
            "付款计划月份标签根据起租日期计算实际付款日期",
            "收租卡片第三行时间胶囊化加底色",
            "收租卡片租期改为读取表单登记的租期，不再自动计算",
            "收租详情页租期改起止期，新增租期行显示表单登记的租期"
        ]),
        ("v2.34", "2026-09-16", [
            "工作台副标题改为动态显示：X月还剩XX天，加油！，数字加粗深绿色",
            "副标题与主标题间距加大",
            "快捷操作上下缩窄，减少空白区域",
            "KPI看板标题全部胶囊化配底色",
            "在管房间KPI改为管理X套·托管包租X套，数字加粗深绿色",
            "本月中介费KPI累计X单数字加粗深绿色",
            "分享功能彻底修复，使用UIWindow确保正确渲染",
            "即将到期提醒改为常显，无数据时显示空状态",
            "包租打租表删除年租金，只保留月租金",
            "付款计划按月租金+付款方式+免租期计算，免租期可跨越多期",
            "包租详情页新增年总租金显示",
            "付款时间按起租月日自动计算，下次应付日期动态显示"
        ]),
        ("v2.33", "2026-09-16", [
            "工作台顶栏全新样式：左边头像可替换，中间标题可编辑，右边时间日期固定显示"
        ]),
        ("v2.32", "2026-09-16", [
            "收租卡片第三行日期固定一行显示",
            "包租卡片右边三个胶囊间距拉开，字体加大",
            "分享功能修复：改用UIHostingController+drawHierarchy",
            "成交卡片单击改为只读详情页，右上角编辑按钮可进入编辑"
        ]),
        ("v2.31", "2026-09-16", [
            "收租卡片房东与租金对调位置",
            "包租详情页添加月租金显示",
            "免租期计算修复：未付款记录自动使用最新计算金额"
        ]),
        ("v2.30", "2026-09-16", [
            "收租卡片房东只显示名字，去掉房东前缀",
            "打租计划第X季标题不换行显示",
            "新增打租表单年租金下面加月租金，双向联动",
            "打租计划金额自动根据免租期计算，合计等于年租金",
            "包租卡片房号字体放大",
            "包租卡片第三行显示下次打租金额",
            "备注移到第四行"
        ]),
        ("v2.29", "2026-09-15", [
            "收租卡片：交租日只显示X号，月租改租/XXX，预存改预/XXX",
            "收租卡片第三行租期字体调大",
            "收租卡片累计水电改累计收水电:XXX元，数字加粗深绿色",
            "收租排序优化：拖租未交的优先排在最前",
            "详情页分享功能修复",
            "包租卡片右侧改已付X次租金、已付XXXX元、已付水电费X元，全部胶囊化",
            "包租卡片去掉管理和免租期，改为房号+户型+付款方式 / X号+年租 / 备注",
            "包租卡片删除左侧图标区域",
            "包租详情页新增按月水电费结算",
            "包租详情页新增水电底数（水表+电表）",
            "包租详情页新增交租日",
            "包租详情页打租计划按付款方式动态显示（月12期/季4期/半年2期/年1期）",
            "设置页三大板块间距缩小"
        ]),
        ("v2.28", "2026-09-15", [
            "收租管理卡片全部胶囊配底色",
            "收租卡片新布局：房号+房东 / 交租日+租金+预存 / 租期",
            "收租卡片已收X个月数字加粗",
            "收租卡片动态排序：未收租优先，离交租日近排前",
            "包租管理卡片全部胶囊配底色",
            "详情页左上角新增分享功能：图片分享，自动剔除敏感信息"
        ]),
        ("v2.27", "2026-09-15", [
            "设置页版本号动态读取",
            "版本介绍箭头移入胶囊内部",
            "设置页间距大幅缩小",
            "成交卡片统一高度，备注始终显示，超出用..."
        ]),
        ("v2.23", "2026-09-15", [
            "设置页关于部分完善，新增开发者、软件说明、数据安全",
            "汇总月度列表默认降序排列，最新月份在最前",
            "汇总筛选默认显示全年数据",
            "汇总KPI新布局：左边2x2，右边净总收入跨两行",
            "净总收入统一配红色",
            "汇总下方卡片净收入胶囊化，配色对应KPI",
            "包租表单付款方式新增半年付、年付",
            "成交卡片时间恢复显示并胶囊化"
        ]),
        ("v2.22", "2026-09-15", [
            "备份数据新增分板块选择（成交/收租/包租/全部）",
            "成交卡片胶囊化：房东、租金、押金、备注全部加底色",
            "成交金额改为红色，房号永不换行",
            "杂收入/杂支出配色对调：收入红色，支出绿色",
            "汇总KPI和月度数据全部胶囊加底色",
            "成交和中介费KPI配黄色"
        ]),
        ("v2.21", "2026-09-15", [
            "回退到稳定版本",
            "Excel转备份暂用桌面端转换工具"
        ]),
        ("v2.20", "2026-09-15", [
            "清空数据对话框文字修正",
            "右滑卡片改为iOS原生swipeActions，流畅度提升",
            "杂项收入卡片优化：绿色圆形收字图标，备注为空不显示",
            "成交记录卡片三行标签式布局",
            "杂项支出卡片优化",
            "汇总顶部3数据改5数据，字体放大加黑",
            "工作台时间卡片收窄"
        ]),
        ("v2.19", "2026-09-15", [
            "备份文件夹细分为4个：成交备份/收租备份/包租备份/总备份",
            "各板块左上角导入数据改为恢复数据",
            "设置页增加分板块清空（带二次确认）",
            "设置页增加Excel转备份入口",
            "自动备份固定为总备份"
        ]),
        ("v2.18", "2026-09-15", [
            "修复收租数据导入闪退问题",
            "SwiftData关系对象先insert再关联",
            "支持收租表表名（原交租表）"
        ]),
        ("v2.17", "2026-09-15", [
            "修复日期格式问题",
            "日期统一使用yyyy-MM-dd格式"
        ]),
        ("v2.16", "2026-09-15", [
            "分批导入优化，每批2条",
            "降低主线程阻塞风险"
        ]),
        ("v2.15", "2026-09-15", [
            "数据导入改为异步后台执行",
            "避免UI卡顿"
        ]),
        ("v2.14", "2026-09-15", [
            "数据导入功能优化",
            "支持Excel模板导入"
        ]),
        ("v2.13", "2026-09-15", [
            "收租管理界面优化",
            "收租进度展示"
        ]),
        ("v2.12", "2026-09-15", [
            "成交管理界面优化",
            "新增筛选和搜索功能"
        ]),
        ("v2.11", "2026-09-15", [
            "应用名称改为中介管家",
            "APP图标优化"
        ]),
        ("v2.10", "2026-09-15", [
            "新增包租管理板块",
            "支持打租记录和月打租"
        ]),
        ("v2.9", "2026-09-15", [
            "新增汇总板块",
            "月度收支汇总统计"
        ]),
        ("v2.8", "2026-09-15", [
            "工作台KPI看板",
            "在管房间、即将到期、中介费等指标"
        ]),
        ("v2.7", "2026-09-15", [
            "数据备份和恢复功能",
            "支持分板块备份"
        ]),
        ("v2.6", "2026-09-15", [
            "新增杂项收入和支出管理",
            "支持自定义分类"
        ]),
        ("v2.5", "2026-09-15", [
            "水电结算功能",
            "按季度结算水电费"
        ]),
        ("v2.4", "2026-09-15", [
            "收租管理板块",
            "月度收租记录和提醒"
        ]),
        ("v2.3", "2026-09-15", [
            "成交管理板块",
            "支持成交记录录入和查询"
        ]),
        ("v2.2", "2026-09-15", [
            "基础UI优化",
            "深绿色主题"
        ]),
        ("v2.1", "2026-09-15", [
            "基础功能完善",
            "数据持久化优化"
        ]),
        ("v2.0", "2026-09-15", [
            "重大版本更新",
            "全新架构，SwiftData数据存储",
            "6大功能板块"
        ]),
        ("v1.0", "2026-09-01", [
            "初始版本发布",
            "基础房产中介管理功能"
        ])
    ]
    // v1.80：远程配置——版本记录合并云端更新日志（后台「远程配置」新增条目即出现在 App 设置 → 关于，无需发版）
    var displayVersions: [(version: String, date: String, changes: [String])] {
        var list = versions
        if let cloud = RemoteConfig.changelog, !cloud.isEmpty {
            let cloudItems = cloud.map { (version: $0.version, date: $0.date ?? "", changes: $0.changes) }
            let localVers = Set(list.map { $0.version })
            list = cloudItems.filter { !localVers.contains($0.version) } + list
        }
        return list
    }
    var body: some View {
        NavigationStack {
            List {
                ForEach(displayVersions, id: \.version) { ver in
                    Section(header: HStack {
                        Text(ver.version)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.themeAccent)
                        Spacer()
                        Text(ver.date)
                            .font(.system(size: 12))
                            .foregroundColor(.black)
                    }) {
                        ForEach(ver.changes, id: \.self) { change in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 6))
                                    .foregroundColor(.themeAccent)
                                    .padding(.top, 6)
                                Text(change)
                                    .font(.system(size: 14))
                                    .foregroundColor(.black)
                                    .fontWeight(.semibold)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.themeBg)
            .navigationTitle("版本更新介绍")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}


// MARK: - 账单模板设置（固定文本 / 收款码 / 预览）
struct BillTemplateSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @AppStorage("billFixedTip") private var billFixedTip = "账单由人工录入，系统生成，如金额有误请与我联系！"
    @AppStorage("billGreeting") private var billGreeting = "尊敬的租客，感谢您选择我司提供的租赁服务！"
    @AppStorage("billDuePrefix") private var billDuePrefix = "您"
    @AppStorage("billDueSuffix") private var billDueSuffix = "前需支付房租账单明细如下："
    @AppStorage("billLateFeeTip") private var billLateFeeTip = "（请务必按时交租，逾期交租将按照租房合同约定计算滞纳金：月租金5%/天×天数）"
    @AppStorage("billSign") private var billSign = "谢谢  祝 商祺"
    @AppStorage("billQRAlipayFile") private var billQRAlipayFile = ""
    @AppStorage("billQRWechatFile") private var billQRWechatFile = ""

    @State private var alipayItem: PhotosPickerItem?
    @State private var wechatItem: PhotosPickerItem?
    @State private var showAlipayPicker = false
    @State private var showWechatPicker = false
    @State private var previewImage: UIImage?
    @State private var showPreview = false
    @State private var showMsg = ""
    @State private var showAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section("固定文本（生成账单时实时生效）") {
                    TextField("顶部固定提示", text: $billFixedTip, axis: .vertical).lineLimit(1...3)
                    TextField("问候语", text: $billGreeting, axis: .vertical).lineLimit(1...3)
                    HStack(spacing: 6) {
                        TextField("引导语前段", text: $billDuePrefix)
                        Text("交租日期").font(.footnote).foregroundColor(.gray)
                        TextField("引导语后段", text: $billDueSuffix)
                    }
                    TextField("滞纳金提示", text: $billLateFeeTip, axis: .vertical).lineLimit(1...3)
                    TextField("落款", text: $billSign)
                }
                Section("收款码") {
                    qrRow("支付宝收款码", file: $billQRAlipayFile, showPicker: $showAlipayPicker)
                    qrRow("微信收款码", file: $billQRWechatFile, showPicker: $showWechatPicker)
                    Text("点击“更换”从相册选择新收款码，立即生效；点击“清除”恢复内置默认收款码。")
                        .font(.footnote)
                }
                Section("预览") {
                    Button("预览账单效果") { makePreview() }
                        .foregroundColor(.themeAccent)
                }
            }
            .navigationTitle("账单模板设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .photosPicker(isPresented: $showAlipayPicker, selection: $alipayItem, matching: .images)
            .photosPicker(isPresented: $showWechatPicker, selection: $wechatItem, matching: .images)
            .onChange(of: alipayItem) { _, newItem in
                saveQRAsync(item: newItem, prefix: "alipay_qr") { newName in
                    let old = billQRAlipayFile
                    billQRAlipayFile = newName
                    if let oldURL = qrURL(old), oldURL.lastPathComponent != newName { try? FileManager.default.removeItem(at: oldURL) }
                }
            }
            .onChange(of: wechatItem) { _, newItem in
                saveQRAsync(item: newItem, prefix: "wechat_qr") { newName in
                    let old = billQRWechatFile
                    billQRWechatFile = newName
                    if let oldURL = qrURL(old), oldURL.lastPathComponent != newName { try? FileManager.default.removeItem(at: oldURL) }
                }
            }
            .sheet(isPresented: $showPreview) {
                if let image = previewImage { ShareImagePreview(image: image, share: {}) }
            }
            .alert("提示", isPresented: $showAlert) { Button("确定", role: .cancel) {} } message: { Text(showMsg) }
        }
    }

    private func qrRow(_ title: String, file: Binding<String>, showPicker: Binding<Bool>) -> some View {
        HStack {
            Text(title).fontWeight(.semibold)
            Spacer()
            if let img = loadQR(file.wrappedValue) { Image(uiImage: img).resizable().scaledToFit().frame(width: 42, height: 42).cornerRadius(6) }
            Button("更换") { showPicker.wrappedValue = true }
                .buttonStyle(.bordered).font(.footnote)
            if !file.wrappedValue.isEmpty {
                Button("清除") {
                    if let url = qrURL(file.wrappedValue) { try? FileManager.default.removeItem(at: url) }
                    file.wrappedValue = ""
                }.buttonStyle(.bordered).tint(.red).font(.footnote)
            }
        }
        .padding(.vertical, 2)
    }

    private func qrURL(_ name: String) -> URL? {
        guard !name.isEmpty else { return nil }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }

    private func loadQR(_ name: String) -> UIImage? {
        guard let url = qrURL(name) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    // 异步加载相册图片并保存到 Documents，完成后在主线程回调文件名
    private func saveQRAsync(item: PhotosPickerItem?, prefix: String, assign: @escaping (String) -> Void) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                let name = "\(prefix)_\(Int(Date().timeIntervalSince1970)).png"
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
                if let png = img.pngData() {
                    try? png.write(to: url)
                    await MainActor.run { assign(name) }
                }
            }
        }
    }

    private func makePreview() {
        let props = (try? modelContext.fetch(FetchDescriptor<Property>())) ?? []
        guard let property = props.first(where: { !$0.isTerminated && !$0.monthlyRentRecords.isEmpty }) else {
            showMsg = "暂无可预览的收租房源，请先在收租板块添加房源并生成收租计划。"
            showAlert = true
            return
        }
        let cal = Calendar.current
        let y = cal.component(.year, from: Date())
        let m = cal.component(.month, from: Date())
        let rent = property.monthlyRentRecords.first { $0.year == y && $0.month == m } ?? property.monthlyRentRecords.first!
        let utility = property.utilitySettlementRecords.first { rec in
            guard let d = rec.dueDate else { return false }
            return cal.component(.year, from: d) == rent.year && cal.component(.month, from: d) == rent.month
        }
        let view = RentBillShareView(property: property, rent: rent, utility: utility, extras: [])
        let renderer = ImageRenderer(content: view.frame(width: 360))
        renderer.scale = 3
        if let image = renderer.uiImage {
            previewImage = image
            showPreview = true
        } else {
            showMsg = "账单预览生成失败，请重试。"
            showAlert = true
        }
    }
}

// MARK: - v1.36 管理后台口令（网页版登录用；App 内免登录直接带哈希）

struct AdminPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = CloudConfig.adminPassword
    @State private var confirm = ""
    @State private var savedFlash = false
    @State private var resultMsg: String?
    @State private var errorMsg: String?

    var body: some View {
        Form {
            Section {
                SecureField("后台口令", text: $password)
                SecureField("再次输入确认", text: $confirm)
            } header: {
                Text("口令设置")
            } footer: {
                Text("网页版管理后台用此口令登录；App 内打开后台免登录。默认口令 12345678，建议修改为不易猜的字符。v1.17 需求6：保存后会自动同步到云函数（云端后台、网页后台同用此口令）。")
            }
            Section {
                Button("保存") { save() }
            }
            if let errorMsg {
                Section {
                    Text(errorMsg).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("管理后台口令")
        .navigationBarTitleDisplayMode(.inline)
        .alert("已保存", isPresented: Binding(
            get: { savedFlash },
            set: { if !$0 { savedFlash = false } }
        )) {
            Button("好", role: .cancel) { dismiss() }
        } message: {
            Text(resultMsg ?? "后台口令已更新：\(password)")
        }
    }

    private func save() {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else {
            errorMsg = "口令至少 6 位"
            return
        }
        guard trimmed == confirm else {
            errorMsg = "两次输入不一致"
            return
        }
        // v1.17 需求6：记录旧口令哈希用于云函数鉴权，再更新本地
        let oldHash = CloudConfig.passwordHash
        CloudConfig.adminPassword = trimmed
        resultMsg = "本地口令已更新：\(trimmed)"
        savedFlash = true
        // 异步同步到云函数（改桶内 h/_admin_pwd.json）
        Task {
            let tip = await syncCloud(oldHash: oldHash, new: trimmed)
            await MainActor.run { resultMsg = tip }
        }
    }

    /// v1.17 需求6：调用云函数 setPwd 把新口令同步到云端（成功后云端后台与网页后台立即用新口令）
    private func syncCloud(oldHash: String, new: String) async -> String {
        guard let encoded = new.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(CloudConfig.functionURL)?act=setPwd&k=\(oldHash)&new=\(encoded)") else {
            return "已保存到本地，但同步云函数失败（云函数地址无效）。\n网页版后台仍用旧口令，请稍后在设置页重试。"
        }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 {
                return "已保存到本地；但云端同步被拒绝（口令校验失败）。\n请确认云函数已部署后重试。"
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["ok"] as? Bool == true {
                return "本地 + 云端后台口令均已更新：\(new)"
            }
            return "已保存到本地；云端同步未确认，请稍后重试。"
        } catch {
            return "已保存到本地；云端同步失败（网络错误：\(error.localizedDescription)）"
        }
    }
}

