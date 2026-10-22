import SwiftUI
import SwiftData
import UserNotifications

// Tab 路由，用于工作台快捷操作跳转
final class TabRouter: ObservableObject {
    @Published var selectedTab: Int = 0
}

@main
struct AgentToolApp: App {
    private let mainContainer: ModelContainer
    private let houseContainer: ModelContainer
    private let storageWarning: String?
    @StateObject private var tabRouter = TabRouter()

    init() {
        // 强制应用内系统控件使用中文
        UserDefaults.standard.set(["zh-Hans", "zh_CN"], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
        LocalNotificationManager.shared.configure()

        // 房源板块数据存独立 store（Documents/备份/housekeeper.store + Media 文件夹），
        // 与主 App 经营数据（默认 default.store）完全隔离：复制「备份」文件夹即可整体还原房源数据
        BackupGuide.ensureExists()

        // v1.8：先把此前「容器初始化失败时自动隔离」的主库文件找回原位（仅当当前默认 store 不存在时执行）。
        // 防误移：目标位置已存在同名文件则不覆盖。数据找回后再正常打开，避免用户主经营数据留在隔离区。
        Self.recoverQuarantinedStores()

        // 关键：两个数据体系必须用【两个独立 ModelContainer】，不能合成一个多配置容器——
        // iOS 17 早期版本在主 context 上查询非默认配置的模型会直接崩溃（房源板块闪退根因）。
        // 每个容器单配置、单 store，是最稳定的 SwiftData 用法（与两个原 App 各自的行为一致）。
        // 注意：两个容器必须一次性创建（元组赋值），避免第一个成功第二个抛错导致重复初始化崩溃。
        do {
            (mainContainer, houseContainer) = try Self.makePersistentContainers()
            storageWarning = nil
        } catch {
            print("ModelContainer init failed: \(error)")
            // 备份旧的store文件而不是直接删除，防止数据丢失
            let fileManager = FileManager.default
            if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let backupFolder = appSupport.appendingPathComponent("backup_\(Int(Date().timeIntervalSince1970))")
                try? fileManager.createDirectory(at: backupFolder, withIntermediateDirectories: true)
                if let files = try? fileManager.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: nil) {
                    for file in files {
                        let name = file.lastPathComponent
                        if name.hasSuffix(".store") || name.hasSuffix(".store-wal") ||
                           name.hasSuffix(".store-shm") || name.contains("AgentTool") {
                            try? fileManager.moveItem(at: file, to: backupFolder.appendingPathComponent(name))
                            print("Backed up: \(name)")
                        }
                    }
                }
            }
            // 再试一次，不行就用内存模式
            do {
                (mainContainer, houseContainer) = try Self.makePersistentContainers()
                storageWarning = nil
            } catch {
                let persistentError = error
                print("Second init also failed: \(persistentError)")
                // 持久库不可用时进入明确标识的临时模式，避免误以为数据已保存。
                do {
                    (mainContainer, houseContainer) = try Self.makeMemoryContainers()
                    storageWarning = "本地数据库无法打开，当前为临时模式；本次新增或修改的数据不会永久保存。请先导出可用数据并重启 APP。错误：\(persistentError.localizedDescription)"
                } catch {
                    fatalError("数据库和临时存储均无法初始化：\(error.localizedDescription)")
                }
            }
        }
    }

    /// v1.8：找回被隔离的主库文件（此前容器初始化失败时自动移入 backup_<时间戳> 的 store 文件）。
    /// 仅在当前默认 store 不存在时执行；目标位置已有同名文件则不覆盖。
    private static func recoverQuarantinedStores() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let defaultStore = appSupport.appendingPathComponent("default.store")
        if fm.fileExists(atPath: defaultStore.path) { return }
        let dirs = (try? fm.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let backups = dirs.filter {
            guard $0.lastPathComponent.hasPrefix("backup_") else { return false }
            return (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard let newest = backups.max(by: {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }) else { return }
        if let files = try? fm.contentsOfDirectory(at: newest, includingPropertiesForKeys: nil) {
            for file in files where !file.lastPathComponent.hasPrefix(".") {
                let dest = appSupport.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.moveItem(at: file, to: dest)
                    print("Recovered quarantined store: \(file.lastPathComponent)")
                }
            }
        }
    }

    /// 创建两个持久化 ModelContainer（主 App 经营数据 → 默认 store；房源数据 → Documents/备份/housekeeper.store）
    private static func makePersistentContainers() throws -> (ModelContainer, ModelContainer) {
        let mainSchema = Schema([
            Property.self, RentMonthRecord.self, UtilityQuarterRecord.self, UtilitySettlementRecord.self, TodoItem.self,
            DealRecord.self, MiscIncome.self, MiscExpense.self,
            PayoutRecord.self, PayoutMonthRecord.self, PayoutUtilityRecord.self, ProfitCalculation.self, UtilitySettlementHistory.self
        ])
        let houseSchema = Schema([House.self, MediaItem.self])
        let main = try ModelContainer(for: mainSchema)
        let house = try ModelContainer(for: houseSchema, configurations: [
            ModelConfiguration("HouseStore", schema: houseSchema, url: DataRoot.url().appendingPathComponent("housekeeper.store"))
        ])
        return (main, house)
    }

    /// 内存模式兜底（两个容器均为 in-memory，重启即清空）
    private static func makeMemoryContainers() throws -> (ModelContainer, ModelContainer) {
        let mainSchema = Schema([
            Property.self, RentMonthRecord.self, UtilityQuarterRecord.self, UtilitySettlementRecord.self, TodoItem.self,
            DealRecord.self, MiscIncome.self, MiscExpense.self,
            PayoutRecord.self, PayoutMonthRecord.self, PayoutUtilityRecord.self, ProfitCalculation.self, UtilitySettlementHistory.self
        ])
        let houseSchema = Schema([House.self, MediaItem.self])
        let main = try ModelContainer(for: mainSchema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let house = try ModelContainer(for: houseSchema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return (main, house)
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .tint(.themeAccent)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .environment(\.calendar, Calendar(identifier: .gregorian))
                .environmentObject(tabRouter)
                .environment(\.houseModelContext, houseContainer.mainContext)
                .alert("存储异常", isPresented: Binding(
                    get: { storageWarning != nil },
                    set: { _ in }
                )) {
                    Button("我知道了") { }
                } message: {
                    Text(storageWarning ?? "")
                }
        }
        .modelContainer(mainContainer)
    }
}

// 房源板块专用 ModelContext（独立 HouseStore 容器）。
// 主 App 页面继续用主容器的 @Environment(\.modelContext)；房源页面用 houseModelContext。
private struct HouseModelContextKey: EnvironmentKey {
    static let defaultValue: ModelContext? = nil
}

extension EnvironmentValues {
    var houseModelContext: ModelContext? {
        get { self[HouseModelContextKey.self] }
        set { self[HouseModelContextKey.self] = newValue }
    }
}

// 自定义6个Tab的底部导航
struct MainTabView: View {
    @EnvironmentObject private var tabRouter: TabRouter
    @Environment(\.modelContext) private var modelContext
    // v1.12：自动备份快速备份需要房源容器（保存快照中的房源 JSON）
    @Environment(\.houseModelContext) private var houseModelContext

    private let tabs = [
        (title: "工作台", icon: "house.fill"),
        (title: "房源", icon: "building.2.fill"),
        (title: "成交", icon: "doc.text.fill"),
        (title: "收租", icon: "creditcard.fill"),
        (title: "包租", icon: "arrow.up.circle.fill"),
        (title: "汇总", icon: "chart.pie.fill"),
        (title: "设置", icon: "gearshape.fill")
    ]

    @State private var visitedTabs: Set<Int> = [0]
    @State private var automaticBackupMessage: String?
    @State private var isCheckingAutomaticBackup = false
    private let automaticBackupTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect() // 记录已访问的tab，默认工作台已访问

    init() {
        // v1.7：去掉系统导航栏底部阴影分隔线（所有板块顶部与滚动后都不再出现系统横线）；
        // 设置页需要的「滚动后才显示」分隔线由 SettingsView 用滚动检测 overlay 动态绘制
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = UIColor(Color.themeBg)
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor(Color.themeText)]
        navAppearance.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
    }

    var body: some View {
        VStack(spacing: 0) {
            // 混合方案：已访问的板块保持渲染（用opacity隐藏，保留滚动位置），未访问的不渲染
            ZStack {
                Color.themeBg.ignoresSafeArea()
                if visitedTabs.contains(0) {
                    DashboardView(isActive: tabRouter.selectedTab == 0)
                        .opacity(tabRouter.selectedTab == 0 ? 1 : 0)
                        .disabled(tabRouter.selectedTab != 0)
                }
                if visitedTabs.contains(1) {
                    HouseListView()
                        .opacity(tabRouter.selectedTab == 1 ? 1 : 0)
                        .disabled(tabRouter.selectedTab != 1)
                }
                if visitedTabs.contains(2) {
                    DealsView()
                        .opacity(tabRouter.selectedTab == 2 ? 1 : 0)
                        .disabled(tabRouter.selectedTab != 2)
                }
                if visitedTabs.contains(3) {
                    RentCollectionView()
                        .opacity(tabRouter.selectedTab == 3 ? 1 : 0)
                        .disabled(tabRouter.selectedTab != 3)
                }
                if visitedTabs.contains(4) {
                    PayoutView()
                        .opacity(tabRouter.selectedTab == 4 ? 1 : 0)
                        .disabled(tabRouter.selectedTab != 4)
                }
                if visitedTabs.contains(5) {
                    ProfitView()
                        .opacity(tabRouter.selectedTab == 5 ? 1 : 0)
                        .disabled(tabRouter.selectedTab != 5)
                }
                if visitedTabs.contains(6) {
                    SettingsView()
                        .opacity(tabRouter.selectedTab == 6 ? 1 : 0)
                        .disabled(tabRouter.selectedTab != 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: tabRouter.selectedTab) { _, newTab in
                visitedTabs.insert(newTab)
                WidgetDataSync.sync(modelContext: modelContext)
            }

            // 底部导航
            VStack(spacing: 0) {
                Divider().background(Color.themeBorder)
                HStack(spacing: 0) {
                    ForEach(0..<tabs.count, id: \.self) { index in
                        Button {
                            tabRouter.selectedTab = index
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: tabs[index].icon)
                                    .font(.system(size: 18))
                                Text(tabs[index].title)
                                    .font(.system(size: 10))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 6)
                            .padding(.bottom, 6)
                            .foregroundColor(tabRouter.selectedTab == index ? .themeAccent : .themeText3)
                        }
                    }
                }
                .background(Color.themePanel)
            }
        }
        .onAppear {
            UNUserNotificationCenter.current().setBadgeCount(0)
            // v1.12：启动时安装崩溃日志、同步日志桥、清理恢复残留、重试未上传的云端备份
            CrashLogCollector.install()
            BackupSyncLogBridge.install()
            BackupV5Manager.cleanupPreRestoreResidue()
            checkAutoBackup()
            Task { await CloudBackupService.retryPendingUploads() }
            Task { await CloudBackupService.enforceCloudRetention() }
            LocalNotificationManager.shared.deliverMissedNotifications()
            LocalNotificationManager.shared.rebuildAll(modelContext: modelContext)
            WidgetDataSync.sync(modelContext: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            UNUserNotificationCenter.current().setBadgeCount(0)
            LocalNotificationManager.shared.configure()
            LocalNotificationManager.shared.deliverMissedNotifications()
            LocalNotificationManager.shared.rebuildAll(modelContext: modelContext)
            checkAutoBackup()
            // v1.12：回前台重试未上传的云端备份
            Task { await CloudBackupService.retryPendingUploads() }
            WidgetDataSync.sync(modelContext: modelContext)
        }
        .onReceive(automaticBackupTimer) { _ in
            checkAutoBackup()
            LocalNotificationManager.shared.rebuildAll(modelContext: modelContext)
            WidgetDataSync.sync(modelContext: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .autoBackupSettingsChanged)) { _ in
            checkAutoBackup()
        }
        .onReceive(NotificationCenter.default.publisher(for: LocalNotificationManager.navigationNotification)) { note in
            if let tab = note.userInfo?["tab"] as? Int { tabRouter.selectedTab = tab; visitedTabs.insert(tab) }
        }
        .overlay {
            Color.clear.frame(width: 1, height: 1)
                .alert("自动备份成功", isPresented: Binding(
                    get: { automaticBackupMessage != nil },
                    set: { if !$0 { automaticBackupMessage = nil } }
                )) {
                    Button("知道了", role: .cancel) { automaticBackupMessage = nil }
                } message: {
                    Text(automaticBackupMessage ?? "")
                }
        }
    }

    // 自动补偿备份：启动和回前台时检查最近一个计划时间槽（v1.12 改造：自动备份 = 快速备份 + 自动上传云端）。
    // D2 方案保留：到点 App 不在前台不备份，下次打开时按 latestDueSlot 自动补做；过点不丢。
    private func checkAutoBackup() {
        guard !isCheckingAutomaticBackup else { return }
        guard let data = UserDefaults.standard.data(forKey: "autoBackupSettings"),
              var settings = try? JSONDecoder().decode(AutoBackupSettings.self, from: data), settings.enabled else { return }
        isCheckingAutomaticBackup = true
        defer { isCheckingAutomaticBackup = false }
        let calendar = Calendar.current
        let now = Date()
        guard let dueSlot = latestDueSlot(settings: settings, now: now, calendar: calendar) else { return }
        let slotKey = ISO8601DateFormatter().string(from: dueSlot)
        let defaults = UserDefaults.standard
        // v1.12：检查 Backups 目录中是否已有该槽位的自动快速备份（快速_*_自动.zip 且修改时间 ≥ 到期槽）
        let existingAutoBackup = BackupV5Manager.listLocalBackups().contains { url in
            guard url.lastPathComponent.hasPrefix("快速_") && url.lastPathComponent.contains("_自动") else { return false }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return modified >= dueSlot
        }
        if existingAutoBackup {
            defaults.set(slotKey, forKey: "autoBackupCompletedSlot")
            if settings.lastBackupDate == nil || settings.lastBackupDate! < dueSlot {
                settings.lastBackupDate = now
                if let updated = try? JSONEncoder().encode(settings) { defaults.set(updated, forKey: "autoBackupSettings") }
            }
            return
        }
        // 执行自动快速备份（需房源容器）
        guard let houseCtx = houseModelContext else { return }
        if let url = BackupV5Manager.createFastBackup(mainContext: modelContext, houseContext: houseCtx, isAuto: true, date: now) {
            settings.lastBackupDate = now
            if let updated = try? JSONEncoder().encode(settings) { defaults.set(updated, forKey: "autoBackupSettings") }
            defaults.set(slotKey, forKey: "autoBackupCompletedSlot")
            defaults.synchronize()
            BackupLogStore.log(category: "备份", action: "自动快速备份", result: "成功", detail: url.lastPathComponent, checksum: BackupV5Manager.sha1OfFile(at: url) ?? "")
            // 自动上传云端（后台；失败入队下次重试）
            Task {
                await CloudBackupService.autoUploadFastBackup(zipURL: url, config: nil)
                await MainActor.run {
                    automaticBackupMessage = "自动备份成功：\(url.lastPathComponent)\n" + CloudBackupService.uploadState(of: url.lastPathComponent)
                }
            }
            // 按保留天数清理旧自动备份（v1.12：只清理自动快速备份，手动备份不参与）
            cleanupAutoFastBackups(days: retentionDays())
        } else {
            DispatchQueue.main.async {
                automaticBackupMessage = "自动备份失败：请检查存储空间后重试"
            }
            BackupLogStore.log(category: "备份", action: "自动快速备份", result: "失败", detail: "存储空间或导出失败")
        }
    }

    /// v1.12：自动备份保留天数（默认 7 天，设置页可调）
    private func retentionDays() -> Int {
        let days = UserDefaults.standard.integer(forKey: "autoBackupRetentionDays")
        return days > 0 ? days : 7
    }

    /// v1.12：清理 Backups 目录中超过保留天数的自动快速备份（手动备份不参与）
    private func cleanupAutoFastBackups(days: Int) {
        let fileManager = FileManager.default
        let folder = BackupV5Manager.backupsDirectory
        guard let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let calendar = Calendar.current
        let cutoffDate = calendar.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        for file in files {
            let filename = file.lastPathComponent
            if filename.hasPrefix("快速_") && filename.contains("_自动") && filename.hasSuffix(".zip") {
                if let attributes = try? fileManager.attributesOfItem(atPath: file.path),
                   let creationDate = attributes[.creationDate] as? Date,
                   creationDate < cutoffDate {
                    try? fileManager.removeItem(at: file)
                    print("已删除旧自动备份: \(filename)")
                }
            }
        }
    }

    private func latestDueSlot(settings: AutoBackupSettings, now: Date, calendar: Calendar) -> Date? {
        let hour = min(max(settings.hour, 0), 23)
        let minute = min(max(settings.minute, 0), 59)
        let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        switch settings.frequency {
        case "week":
            let weekday = calendar.component(.weekday, from: settings.lastBackupDate ?? now)
            var c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            c.weekday = weekday; c.hour = hour; c.minute = minute; c.second = 0
            guard let candidate = calendar.date(from: c) else { return nil }
            return candidate <= now ? candidate : calendar.date(byAdding: .weekOfYear, value: -1, to: candidate)
        case "month":
            let preferredDay = calendar.component(.day, from: settings.lastBackupDate ?? now)
            let maxDay = calendar.range(of: .day, in: .month, for: now)?.count ?? 28
            var c = calendar.dateComponents([.year, .month], from: now)
            c.day = min(preferredDay, maxDay); c.hour = hour; c.minute = minute; c.second = 0
            guard let candidate = calendar.date(from: c) else { return nil }
            return candidate <= now ? candidate : calendar.date(byAdding: .month, value: -1, to: candidate)
        default:
            return today <= now ? today : calendar.date(byAdding: .day, value: -1, to: today)
        }
    }
}


extension Notification.Name {
    static let autoBackupSettingsChanged = Notification.Name("autoBackupSettingsChanged")
}
