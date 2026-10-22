import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PhotosUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var showMessage = ""
    @State private var showAlert = false
    @State private var showClearSheet = false
    @State private var showBackupSheet = false
    @State private var showRestoreSheet = false
    @State private var showRestoreList = false
    @State private var restoreType: DataBackupManager.BackupType = .total
    @State private var autoBackupEnabled = false
    @State private var backupFrequency = "day"
    @State private var backupHour = 23
    @State private var clearType: DataBackupManager.BackupType? = nil
    @State private var showClearConfirm = false
    @State private var showVersionHistory = false
    @State private var showManualSync = false
    @State private var showMigration = false
    @State private var showBillTemplate = false
    @State private var showTrash = false   // v1.3：回收站入口从工作台移至设置页
    // v1.6：房源分享设置合并进主设置（原房源板块独立设置页取消）
    @State private var showHouseCacheConfirm = false
    @State private var houseCacheTip: String?
    @AppStorage("notificationSound_rent") private var rentSound = "system"
    @AppStorage("notificationSound_expiry") private var expirySound = "system"
    @AppStorage("notificationSound_payout") private var payoutSound = "system"
    @AppStorage("notificationSound_todo") private var todoSound = "system"
    @AppStorage("defaultElectricPrice") private var defaultElectricPrice = "0.8"
    @AppStorage("defaultWaterPrice") private var defaultWaterPrice = "5.5"
    @AppStorage("defaultUtilityPrepayment") private var defaultUtilityPrepayment = "0"

    private let backupManager = DataBackupManager.shared

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// v1.6：房源分享设置（合并自原房源板块独立设置页）
    private static let houseShareFooter = "远程配置：腾讯云 COS 存储桶、密钥与自定义域名，用于上传房源图片/视频并生成微信分享卡片链接。名片信息：分享 H5 页面和微信卡片上显示的姓名与电话。压缩开启后视频压到 720p、图片轻压缩，分享更快更省流量。房源数据（数据库、图片视频、二维码）默认存放在「公寓管家」文件夹内的「备份」子文件夹，长按拷贝/共享即为备份，重装后放回原位即可还原。"
    private var houseShareSection: some View {
        Section {
            NavigationLink {
                CosConfigView()
            } label: {
                Label("远程配置", systemImage: "server.rack")
            }
            NavigationLink {
                ShareProfileView()
            } label: {
                Label("名片信息", systemImage: "person.crop.circle")
            }
            Toggle("分享时压缩视频和图片", isOn: Binding(
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
                Text("\(MediaStore.houseCount()) 套")
                    .foregroundColor(.secondary)
            }
            Button {
                if let url = URL(string: "shareddocuments://") {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("打开「文件」App 查看数据文件夹", systemImage: "folder")
            }
        } footer: {
            Text(Self.houseShareFooter)
        }
    }

    // MARK: - 设置页 Section 分组（v1.6 拆分，避免 Form 表达式 type-check 超时）
    private var dataSection: some View {
        Section {
            Button { showBackupSheet = true } label: {
                Label("备份数据", systemImage: "square.and.arrow.down")
            }
            Button { showRestoreSheet = true } label: {
                Label("恢复数据", systemImage: "square.and.arrow.up")
            }
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
            Text("备份与恢复均为手动操作，建议重要数据每次修改后及时备份。")
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
                Toggle("", isOn: $autoBackupEnabled)
                    .labelsHidden()
            }
            .onChange(of: autoBackupEnabled) { _, _ in saveAutoSettings() }
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
            }
        } footer: {
            Text("自动备份将保存到总备份文件夹；按天自动备份超过7天会自动清理，手动备份不会被删除。")
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
            settingsForm
        }
    }

    /// v1.6：设置页主体拆为独立属性（避免 body 表达式 type-check 超时）
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
            .confirmationDialog("选择要备份的板块", isPresented: $showBackupSheet, titleVisibility: .visible) {
                Button("备份成交数据") { backupData(type: .deals) }
                Button("备份收租数据") { backupData(type: .properties) }
                Button("备份包租数据") { backupData(type: .payouts) }
                Button("备份全部数据") { backupData(type: .total) }
                Button("取消", role: .cancel) { }
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
            .confirmationDialog("选择要恢复的板块", isPresented: $showRestoreSheet, titleVisibility: .visible) {
                Button("恢复成交数据") { openRestore(.deals) }
                Button("恢复收租数据") { openRestore(.properties) }
                Button("恢复包租数据") { openRestore(.payouts) }
                Button("恢复全部数据") { openRestore(.total) }
                Button("取消", role: .cancel) { }
            }
            .sheet(isPresented: $showRestoreList) {
                RestoreBackupView(type: restoreType) { success in
                    showRestoreList = false
                }
            }
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

    // MARK: - 逻辑（保持不变）

    private func openRestore(_ type: DataBackupManager.BackupType) {
        restoreType = type
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showRestoreList = true }
    }

    // 备份数据 - 按板块备份
    private func backupData(type: DataBackupManager.BackupType) {
        do {
            let data: Data
            switch type {
            case .deals: data = try backupManager.exportDeals(modelContext: modelContext)
            case .properties: data = try backupManager.exportProperties(modelContext: modelContext)
            case .payouts: data = try backupManager.exportPayouts(modelContext: modelContext)
            case .total: data = try backupManager.exportAllData(modelContext: modelContext)
            }
            if let url = backupManager.saveBackup(data, type: type) {
                showMessage = "备份成功：\(url.lastPathComponent)"
            } else {
                showMessage = "备份保存失败，请检查存储空间或文件权限"
            }
        } catch {
            showMessage = "备份导出失败：\(error.localizedDescription)"
        }
        showAlert = true
    }

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

// MARK: - 版本更新介绍
struct VersionHistoryView: View {
    let versions: [(version: String, date: String, changes: [String])] = [
        ("v1.6", "2026-10-22", ["设置统一：房源板块独立设置页取消，全部合并进主 App「设置 → 房源分享」分组（远程配置/名片信息/分享压缩/刷新缓存/房源数据）", "房源板块左上角设置按钮：一键跳转主「设置」页，全 App 只保留一个设置入口", "UI 按房源管家设置页原生 iOS 风格统一（Form 分组 + 小字说明）", "配色恢复为原租房管家深绿主题"]),
        ("v1.4", "2026-10-22", ["回收站入口调整：移至设置页右上角（图标+文字按钮），不再占用数据管理列表", "工作台「新增房源」：不再跳转房源板块，改为直接弹出登记表单（与新增收租/新增成交一致），保存后房源列表自动刷新"]),
        ("v1.3", "2026-10-22", ["房源板块：户型筛选支持多选（可同时筛选多种户型）", "房源设置：刷新分享缓存增加二次确认，防止误触", "房源设置：移除底部版本号", "分享压缩开关默认开启（此前默认关闭，视频按原文件上传）", "工作台：回收站入口移至设置页，空位新增「新增房源」入口"]),
        ("v1.2", "2026-10-22", ["修复：房源板块闪退（根治）——租房管家与房源管家数据改为两个独立存储容器，房源页面使用专属数据上下文，规避 iOS 17 早期版本多存储配置崩溃问题", "房源数据仍独立存放 Documents/备份/（housekeeper.store），拷贝还原方式不变"]),
        ("v1.1", "2026-10-22", ["修复：与旧租房管家彻底隔离——App Group 改为全新 group.com.gj.tg.shared，桌面小组件/同步数据不再与旧应用互通", "优化：房源板块移至第二个 Tab（工作台之后），通知提醒跳转同步更新"]),
        ("v1.0", "2026-10-21", ["公寓管家正式版：租房管家（经营工具）与房源管家（获客分享）合体", "完整保留租房管家全部功能：工作台/成交/收租/包租/汇总/设置/回收站/待办/备忘录/账单模板/自动备份", "新增房源管家板块：房源库/实拍图视频/微信卡片分享/H5脱敏页/腾讯云COS远程配置", "房源数据独立存储（备份文件夹），可直接拷贝还原", "全新应用ID（com.gj.tg），与旧应用完全隔离，可并行安装"]),
        ("v5.29", "2026-10-21", ["备份数据与恢复数据分开两行显示", "设置页每一行补上系统小图标（与备份/恢复/清空同风格）", "修复备份频率与自定义铃声标题重复显示的问题", "移除设置页底部版本号", "自动备份说明补充：按天自动备份超过7天自动清理，手动备份保留"]),
        ("v5.28", "2026-10-21", ["设置页面改为 iOS 原生清爽风格（Form 分组 + 小字说明），整体更简洁、字体图标回归系统默认大小", "应用名称更新为租房管家"]),
        ("v5.27", "2026-10-21", ["设置页面微信风格：浅灰背景、白色圆角分组卡片、镂空线条图标、行间浅灰分隔线", "备份/数据同步/自动备份/水电单价/自定义铃声各板块增加小字使用说明", "构建流程增加 Release 发布通道，IPA 可通过 GitHub Release 下载", "应用名称更新为租房管家"]),
        ("v5.26", "2026-10-21", ["设置页面改为微信风格：浅灰背景、白色圆角分组卡片、镂空线条图标、行间浅灰分隔线，上下间距、字体大小、色调、背景色按微信设置页统一", "备份/数据同步/自动备份/水电单价/自定义铃声各板块增加小字使用说明", "构建流程增加 Release 发布通道，IPA 可通过 GitHub Release 下载"]),
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
        ("v5.0", "2026-09-19", ["水电计划去重和账单分享", "收款码账单图片", "桌面小组件打包"]),
        ("v5.1", "2026-09-19", ["水电计划左右UI及可编辑结算文本", "计划去重排序和新增收租修复", "工作台结余金额修复", "收租账单附加费用和紧凑排版", "所有图片分享增加预览"]),
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

    var body: some View {
        NavigationStack {
            List {
                ForEach(versions, id: \.version) { ver in
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
