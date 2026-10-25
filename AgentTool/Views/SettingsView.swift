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
    @State private var houseCacheTip: String?
    @State private var watermarkSubtitle = ""   // v1.41：分享水印入口副标题（onAppear 刷新，返回设置页即显示最新开关状态）

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
            Text(Self.houseShareFooter)
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
            Text("备份数据 = 快速备份（账本 + 房源信息 + 媒体清单，自动上传云端）或全量备份（额外含全部照片视频）。恢复会覆盖当前数据，恢复前自动打包当前数据做安全备份，失败自动还原。旧版分板块 JSON 备份仍可在「查看备份文件」中恢复，不会丢失。")
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
            Text("自动备份 = 快速备份（账本 + 房源 + 清单），备份成功后自动上传云端；超过保留天数（默认 7 天）的自动备份会自动清理，手动备份不会被删除。若到点 App 未在前台，会等下次打开 App 时自动补做。")
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
            .onAppear { loadAutoSettings() }
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
                Text("快速备份：账本 + 房源信息 + 媒体清单（不含照片视频文件），备份后自动上传云端。\n全量备份：账本 + 房源 + 全部照片视频，备份后可在「查看备份文件」中手动上传云端。")
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
            .confirmationDialog("刷新分享缓存", isPresented: $showHouseCacheConfirm, titleVisibility: .visible) {
                Button("清空并刷新", role: .destructive) {
                    ShareCacheStore.clearAll()
                    houseCacheTip = "分享缓存已清空 ✅\n下次分享会重新上传并生成新链接（所有房源）"
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将清空全部房源的分享缓存，下次分享时重新上传并生成新链接。确定继续吗？")
            }
            .alert("刷新分享缓存", isPresented: Binding(
                get: { houseCacheTip != nil },
                set: { if !$0 { houseCacheTip = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(houseCacheTip ?? "")
            }
    }

    // MARK: - 逻辑

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
                showMessage = "快速备份成功：\(url.lastPathComponent)\n已自动上传云端（若网络失败会在下次打开 App 时自动重试）"
            } else {
                showMessage = "快速备份失败，请检查存储空间"
            }
            showAlert = true
        } else {
            if !BackupV5Manager.hasFreeSpace(needed: BackupV5Manager.collectMediaFileEntries().reduce(0) { $0 + (BackupV5Manager.fileSize(at: $1.fileURL)) }) {
                showMessage = "存储空间不足，全量备份至少需要与照片视频等量的剩余空间"
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
                        showMessage = "全量备份成功：\(url.lastPathComponent)\n可在「查看备份文件」中手动上传到云端"
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
        ("v1.50", "2026-10-25", ["选房链接彻底对齐单房分享H5：App本地生成选房静态壳上传COS，链接用自定义域名签名（与单房H5同机制），微信内正常打开不再下载", "分享出微信卡片：壳内og标题/描述/封面图全走自定义域名，微信分享渲染成卡片（房源实拍图+米兰公馆·在租房源）", "云函数rooms_json支持cd参数：选房页封面/二维码签名URL全部走自定义域名", "未配置自定义域名时App内明确提示（与单房分享H5相同要求）"]),
        ("v1.51", "2026-10-25", ["修复选房页封面不显示：封面从 CSS 背景图改为 <img> 标签加载（微信兼容更好），加载失败自动隐藏占位", "卡片点击有反应：有分享 H5 的房源点击直接打开完整详情页；没有的全屏放大封面预览", "修复微信分享卡片无信息：og:url 改用壳自身自定义域名签名链接，og:image 改用第一套房封面（此前指向不存在的 qrcode.jpg 导致微信只显示纯链接）", "设置压缩开关改名「压缩上传媒体（房源+分享）」：新增/编辑房源媒体上传云端与分享 H5 都会压缩（图片长边≤1600、视频 720p），上传更快", "云函数 rooms_json 新增 share 字段（每套房分享 H5 的自定义域名签名链接）"]),