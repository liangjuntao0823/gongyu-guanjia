import SwiftUI
import SwiftData

struct HouseListView: View {
    /// 房源板块使用独立 HouseStore 容器的专属 context（由 App 注入）。
    /// 不能用主容器的 modelContext——iOS 17 早期版本多配置容器上查询会崩溃（闪退根因）。
    @Environment(\.houseModelContext) private var houseModelContext
    @State private var houses: [House] = []

    static let houseStoreChanged = Notification.Name("houseStoreChanged")

    /// v1.67：后台线程安全的媒体对账快照——SwiftData @Model 属性（mediaItems 等）只能在
    /// 主线程/模型上下文访问，跨线程读会崩溃（v1.66 刷新「点击没反应」根因）。
    /// 因此先在主线程把需要的数据提取成纯值，后台只做网络请求。
    private struct PendingMediaHouseSnapshot {
        let roomKey: String
        let displayRoomNo: String
        let files: [ShareMediaFile]
        let info: ShareHouseInfo
    }

    @State private var searchText = ""
    @State private var towerFilter: Int? = nil      // nil = 全部
    @State private var statusFilter: HouseStatus? = .available   // 首页默认显示待租房源
    @State private var layoutFilters: Set<String> = []   // v1.3：户型筛选支持多选，空 = 全部户型
    @State private var showAdd = false
    @State private var showBatchImport = false   // v1.58：批量录入（清单/zip/扫描）

    // 卡片左滑菜单（编辑 / 已租 / 删除）
    @State private var showEditHouse: House?
    @State private var singleShareHouse: House?
    @State private var deleteTarget: House?
    @State private var showDetailHouse: House?

    // v1.14 需求6：合并所有 confirmationDialog 为单一枚举弹窗（iOS 17 同一视图多个 confirmationDialog 会互相覆盖，
    // 导致删除确认弹窗不显示）；按触发源分发文案与按钮
    // v1.16 需求2：删除确认彻底改回 DealsView 同款独立 alert（swipeActions 手势会拦截 confirmationDialog 按钮点击；
    // 且 presenting 变体 + 自定义 Binding 在 iOS 17 swipeActions 环境不可靠）——拆分：
    //   - showDeleteConfirm + deleteTarget/isBatchDelete：删除确认（挂 body 链最末，最后挂载优先响应）
    //   - showShareModeAlert + activeDialog：分享方式选择（普通按钮触发，非 swipeActions）
    //   - showInfoAlert + infoMessage：分享错误 / 批量结果提示
    @State private var showDeleteConfirm = false
    @State private var isBatchDelete = false
    @State private var showShareModeAlert = false
    @State private var showInfoAlert = false
    @State private var infoMessage = ""
    // v1.40 第11点：同步先弹变化确认（预览 → 确认 → 应用）
    @State private var showSyncConfirm = false
    // v1.68：云端媒体对账确认（先干跑列桶 → 弹确认 → 确认后才上传）+ 同步任务进度/最小化
    @State private var showMediaSyncConfirm = false
    @State private var pendingMediaSnaps: [PendingMediaHouseSnapshot] = []
    @State private var syncTaskMinimized = false
    @ObservedObject private var syncCenter = SyncTaskCenter.shared
    @State private var pendingSyncRecs: [CloudHouseRecord] = []
    @State private var pendingSyncAdded: [(roomNo: String, roomKey: String, mediaNames: [String])] = []
    @State private var pendingSyncUpdated: [(roomNo: String, byUser: String)] = []
    @State private var pendingSyncDeleted: [(roomKey: String, roomNo: String)] = []   // v1.42：带房号
    @State private var pendingSyncPushed: [(roomKey: String, roomNo: String)] = []     // v1.42：带房号
    @State private var pendingSyncMediaDiff: [(roomNo: String, missing: Bool)] = []    // v1.43：媒体差异房号（含「本地缺文件需从云端补回」）
    @State private var activeDialog: HouseListDialog?

    // v1.22：首页多选分享——一次选多套，生成【一个合集分享卡片】（好友点开链接即可查看全部 N 套），
    // 不再逐套生成链接逐次弹微信，避免 App 与微信来回跳转
    @State private var isSelecting = false
    @State private var selectedHouseIDs = Set<UUID>()
    @State private var shareQueue: [URL] = []
    @State private var shareIndex = 0
    @State private var currentShareStep: ShareStep? = nil
    @State private var isGenerating = false
    @State private var generateTip = ""
    @State private var generateProgress = 0.0   // v1.13 需求13：上传百分比进度
        // v1.12：多选模式批量操作——批量已租 / 批量删除（保留原有多选分享逻辑不动）
    
    /// v1.15 需求2：单一弹窗枚举（iOS 17 同一视图多个 confirmationDialog/alert 会互相覆盖、且 swipeActions
    /// 手势会拦截 confirmationDialog 按钮点击，删除确认因此无反应）——统一改用单一 alert 呈现所有确认/提示
    /// v1.16 需求2：枚举仅保留「分享方式选择」两类（multiShare/singleShare）；删除/批量删除走独立 showDeleteConfirm
    enum HouseListDialog: Identifiable {
        case multiShare
        case singleShare
        var id: String {
            switch self {
            case .multiShare: return "multiShare"
            case .singleShare: return "singleShare"
            }
        }
    }

    /// 筛选后的房源：默认待租，并按「座号 + 楼层 + 房号」升序排列（1座在前，同座先按楼层、再按房号从小到大）
    /// v1.29（优化评估）：搜索/筛选在内存中进行。房源规模通常为个位数~几十套，
    /// 全量 @Query + 内存过滤即最优解；若未来房源破百再考虑把过滤下推到 SQLite（动态 @Query predicate）。
    private var filteredHouses: [House] {
        houses
            .filter { house in
                let matchSearch: Bool = {
                    guard !searchText.isEmpty else { return true }
                    let keyword = searchText.lowercased()
                    return house.roomNo.lowercased().contains(keyword)
                        || house.displayRoomNo.lowercased().contains(keyword)
                        || house.landlord.lowercased().contains(keyword)
                        || house.layout.lowercased().contains(keyword)
                        || house.remark.lowercased().contains(keyword)
                }()
                let matchTower = towerFilter == nil || house.tower == towerFilter
                let matchStatus = statusFilter == nil || house.status == statusFilter
                let matchLayout = layoutFilters.isEmpty || layoutFilters.contains(house.layout)
                return matchSearch && matchTower && matchStatus && matchLayout
            }
            .sorted { a, b in
                if a.tower != b.tower { return a.tower < b.tower }
                if a.floorNumber != b.floorNumber { return a.floorNumber < b.floorNumber }
                if a.roomNumber != b.roomNumber { return a.roomNumber < b.roomNumber }
                // 同座同层同号（如 1420上 / 1420下）：按原始房号字符串稳定排序
                return a.roomNo < b.roomNo
            }
    }

    private var layouts: [String] {
        Array(Set(houses.compactMap { $0.layout.isEmpty ? nil : $0.layout })).sorted()
    }

    /// v1.16 需求2：分享方式选择弹窗标题（activeDialog 仅用于分享选择）
    private var dialogTitle: String {
        switch activeDialog {
        case .multiShare: return "选择分享方式"
        case .singleShare: return "选择分享方式"
        case nil: return ""
        }
    }

    private var tower1Count: Int { houses.filter { $0.tower == 1 }.count }
    private var tower2Count: Int { houses.filter { $0.tower == 2 }.count }
    private var availableCount: Int { houses.filter { $0.status == .available }.count }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    syncTaskBanner
                    statsBar
                    searchBar
                    filterBar
                    houseList
                }
            }
            .navigationTitle("房源管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // v1.59：左上角 = 手动同步 + 多选入口（多选从右上角移到刷新旁边）
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 14) {
                        // v1.19：左上角手动同步（与下拉刷新同效果——拉取云端房源）
                        Button {
                            Task { await syncCloudHouses() }
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        // v1.21：多选分享入口（v1.59 移到左上角）
                        Button {
                            isSelecting = true
                        } label: {
                            Image(systemName: "checkmark.circle")
                        }
                    }
                    .disabled(isSelecting)
                }
                // v1.7：房源设置已合并进主 App 设置页，左上角设置按钮移除（无独立设置入口）
                ToolbarItem(placement: .topBarTrailing) {
                    if isSelecting {
                        Button("取消") { exitMultiSelect() }
                    } else {
                        HStack(spacing: 14) {
                            // v1.58：批量录入入口（清单导入 / 媒体包导入 / 扫描补录）
                            Button {
                                showBatchImport = true
                            } label: {
                                Image(systemName: "square.and.arrow.down.on.square")
                            }
                            // v1.7：+ 按钮样式与其他板块一致（plus.circle.fill + 主题绿）
                            Button {
                                showAdd = true
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.themeAccent)
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                HouseEditView(house: nil)
            }
            .sheet(isPresented: $showBatchImport) {
                HouseBatchImportView()
            }
            .sheet(item: $showEditHouse) { house in
                HouseEditView(house: house)
            }
            .navigationDestination(item: $showDetailHouse) { house in
                HouseDetailView(house: house)
            }
            // v1.16 需求2：分享方式选择（普通按钮触发，非 swipeActions；用真 @State 绑定避免 iOS 17 自定义 Binding 不可靠问题）
            .alert(dialogTitle, isPresented: $showShareModeAlert) {
                switch activeDialog {
                case .multiShare:
                    Button("发给客户（隐藏版）") { generateShareQueue(mode: .masked) }
                    Button("发给同事（完整版）") { generateShareQueue(mode: .full) }
                    Button("取消", role: .cancel) {}
                case .singleShare:
                    Button("发给客户（隐藏版）") { generateSingleShare(mode: .masked) }
                    Button("发给同事（完整版）") { generateSingleShare(mode: .full) }
                    Button("取消", role: .cancel) {}
                case nil:
                    EmptyView()
                }
            } message: {
                switch activeDialog {
                case .multiShare:
                    Text("已选 \(selectedHouseIDs.count) 套，将生成一个合集分享卡片：好友点开链接即可查看全部房源，每套单独一页（含实拍图/视频）。隐藏版不显示房号/价格/房东，完整版显示全部信息。")
                case .singleShare:
                    Text("隐藏版只显示户型、位置和您的联系方式；完整版额外显示房号、价格、房东和密码。")
                case nil:
                    Text("")
                }
            }
            // v1.16 需求2：分享错误 / 批量结果提示（单行文本，独立 alert）
            // v1.71（#95）：提示改由 MainTabView 的 GlobalAlertOverlay 全局呈现——
            // 此前挂在房源页，离开房源板块后「好」按钮被禁用变灰只能重启；现在任何页面都能点。
            .onChange(of: showInfoAlert) { _, shown in
                if shown {
                    let msg = infoMessage
                    showInfoAlert = false   // 本地状态立即复位（全局已接管呈现）
                    GlobalAlertCenter.shared.show(msg)
                }
            }
            // v1.40 第11点：同步变化确认——先展示变化详情，确认后才应用
            .alert("发现云端变化", isPresented: $showSyncConfirm) {
                Button("确认同步", role: .destructive) {
                    Task { await applySyncPreview() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(syncChangeSummary())
            }
            // v1.68：云端媒体对账确认——干跑列桶后发现云端缺媒体，确认后才开始上传（不再静默后台跑）
            .alert("确认补齐云端媒体", isPresented: $showMediaSyncConfirm) {
                Button("开始补齐", role: .destructive) {
                    Task { await runMediaUpload(snaps: pendingMediaSnaps, config: CosConfig.load(), ctx: houseModelContext) }
                }
                Button("取消", role: .cancel) { pendingMediaSnaps = [] }
            } message: {
                Text(mediaSyncConfirmSummary())
            }
            .sheet(item: $currentShareStep, onDismiss: {
                // 上一张分享面板关闭后自动弹下一张；全部发完自动退出多选
                if shareIndex < shareQueue.count - 1 {
                    shareIndex += 1
                    currentShareStep = ShareStep(url: shareQueue[shareIndex])
                } else {
                    exitMultiSelect()
                }
            }) { step in
                HouseShareSheet(items: [step.url])
            }
            .overlay {
                if isGenerating {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView(value: generateProgress)
                                .progressViewStyle(.linear)
                                .tint(.white)
                            Text(generateTip)
                                .font(.footnote)
                                .foregroundColor(.white)
                            Text("\(Int(generateProgress * 100))%")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.85))
                        }
                        .padding(20)
                        .background(Color.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            // v1.16 需求2：删除确认——复刻 DealsView 已验证可用的模式：独立 alert + 真 @State Bool 绑定，
            // 挂在本链最末（最后挂载优先响应），避免 iOS 17 swipeActions 手势拦截 confirmationDialog / 自定义 Binding 失效的问题
            // v1.36 需求1：删除改为彻底删除（不再进回收站）
            // v1.71（#94）：同步任务横幅自动收起兜底 + 最小化状态复位——
            //   1) 新任务出现（id 变化）→ 复位最小化，横幅重新显示（此前最小化过一次后新任务一直不出现）；
            //   2) 任务结束（isRunning 变 false）→ 1.2s 后自动收起横幅并复位（任何调用点忘了 dismiss 都兜底）。
            .onChange(of: syncCenter.task?.id) { _, _ in
                syncTaskMinimized = false
            }
            .onChange(of: syncCenter.task?.isRunning) { _, running in
                guard running == false else { return }
                // 记录本次结束的任务 id，1.2s 后仅当仍是同一个任务时才收起——
                // 防止「完成→新任务在 1.2s 窗口内开始」时误把新任务也 dismiss
                let finishedID = syncCenter.task?.id
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    guard let finishedID, syncCenter.task?.id == finishedID else { return }
                    syncCenter.dismiss()
                    syncTaskMinimized = false
                }
            }
            .alert("删除这套房源？", isPresented: $showDeleteConfirm) {
                if isBatchDelete {
                    Button("彻底删除", role: .destructive) { batchSoftDelete() }
                } else if let target = deleteTarget {
                    Button("彻底删除", role: .destructive) { softDeleteHouse(target) }
                }
                Button("取消", role: .cancel) { deleteTarget = nil }
            } message: {
                if isBatchDelete {
                    Text("将彻底删除选中的 \(selectedHouseIDs.count) 套房源：本地照片视频、数据库记录、已在云端的 h/<房号>/ 目录一并清除，不可恢复。备份镜像 backups/media 保留。")
                } else if let target = deleteTarget {
                    // v1.19 补全：删除确认提示按该房当前存储位置动态显示（是否删云端一目了然）
                    switch target.cloudStatus {
                    case .both:
                        Text("将删除「本地 + 云端」这套房源：本地照片视频、数据库记录，以及云端 h/\(target.mediaRoomKey)/ 一并清除，不可恢复。备份镜像 backups/media 保留。")
                    case .local:
                        Text("将删除本地房源（未上传云端）：本地照片视频、数据库记录一并清除，不可恢复。备份镜像 backups/media 保留。")
                    case .cloud:
                        Text("将删除云端同步副本：该房本机无媒体，将从云端 h/\(target.mediaRoomKey)/ 清除，不可恢复。")
                    }
                }
            }
        }
        .onAppear {
            reloadHouses()
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.houseStoreChanged)) { _ in
            reloadHouses()
        }
    }

    /// 从独立 HouseStore 配置拉取房源（按创建时间倒序，与原来 @Query 一致；v1.7：排除已进回收站的软删除房源）
    /// v1.9：isDeleted 为可选属性，SwiftData #Predicate 对「可选 Bool」在 iOS 17 会触发翻译崩溃（点进房源板块闪退的根因），
    /// 改为全量拉取 + 内存过滤（房源数量级小，性能无影响）
    private func reloadHouses() {
        guard let ctx = houseModelContext else { return }
        let descriptor = FetchDescriptor<House>(sortBy: [SortDescriptor(\House.createdAt, order: .reverse)])
        let all = (try? ctx.fetch(descriptor)) ?? []
        // v1.70：强制从持久层重载每个房源对象（含 mediaItems 关系）——修复「批量恢复媒体后
        // 卡片仍显示无实拍图/不显示缩略图，必须重启才正常」：SwiftData 同一上下文里插入媒体后，
        // 已缓存对象的 to-many 关系不会自动刷新，列表重新 fetch 拿到的仍是同一实例、关系为旧缓存。
        ctx.refreshAllObjects()   // v1.70：强制从持久层重载全部对象（含 mediaItems 关系）
        houses = all.filter { !$0.isTrashed }
        // v1.71：存量无前缀媒体目录自动归一迁移（media/2059/ → media/1-2059/），幂等；修复
        // v1.69 前编辑页新图落盘无前缀目录导致的上传失败、云端断媒体、刷新缺媒体死循环。
        MediaStore.migrateUnprefixedHouseDirectories(houses: houses)
    }

    // MARK: - 统计（动态跟随当前筛选；v1.31：恢复 v1.29 显示方式 + 修复统计栏下沉）
    // 规则：
    //  - 筛选了座号 / 户型 → 显示筛选口径数量（如「1座 X套」「1座 单间上层 X套」，状态为隐含条件不拼入）
    //  - 仅筛选状态（含默认待租）→ 显示「待租 X套 + 1座 X套 + 2座 X套」：状态在前、该状态下的座号分布跟上，
    //    1座/2座不再被默认「待租」筛选顶替掉（统计栏不下沉）
    //  - 无任何筛选 → 显示「1座 X套 2座 X套 待租 X套」

    private var statsBar: some View {
        HStack(spacing: 12) {
            // v1.28：版本号徽章已移除，改到「设置」页最底部显示

            Label {
                Text("房源统计")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } icon: {
                Image(systemName: "building.2.fill")
                    .font(.footnote)
                    .foregroundColor(AppTheme.primary)
            }

            Spacer()

            if towerFilter != nil || !layoutFilters.isEmpty {
                Text(statsFilteredLabel)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
                    .lineLimit(1)
            } else if let status = statusFilter {
                Text("\(status.label) \(filteredHouses.count) 套")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
                Text("1座 \(filteredHouses.filter { $0.tower == 1 }.count) 套")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
                Text("2座 \(filteredHouses.filter { $0.tower == 2 }.count) 套")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
            } else {
                Text("1座 \(tower1Count) 套")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
                Text("2座 \(tower2Count) 套")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
                Text("待租 \(availableCount) 套")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white)
    }

    private var statsFilteredLabel: String {
        var parts: [String] = []
        if let t = towerFilter { parts.append("\(t)座") }
        if !layoutFilters.isEmpty { parts.append(layoutFilters.sorted().joined(separator: "、")) }
        parts.append("\(filteredHouses.count)套")
        return parts.joined(separator: " ")
    }

    // MARK: - 搜索

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("搜索房号 / 房东 / 户型 / 备注", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 分类检索（第一行：座号 / 状态；第二行：户型）

    private var filterBar: some View {
        VStack(spacing: 8) {
            // 第一行：座号 + 状态
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip(title: "全部座", isOn: towerFilter == nil) {
                        towerFilter = nil
                    }
                    filterChip(title: "1座", isOn: towerFilter == 1) {
                        towerFilter = 1
                    }
                    filterChip(title: "2座", isOn: towerFilter == 2) {
                        towerFilter = 2
                    }

                    Divider().frame(height: 16)

                    filterChip(title: "全部状态", isOn: statusFilter == nil) {
                        statusFilter = nil
                    }
                    filterChip(title: "待租", isOn: statusFilter == .available) {
                        statusFilter = .available
                    }
                    filterChip(title: "已租", isOn: statusFilter == .rented) {
                        statusFilter = .rented
                    }
                }
                .padding(.horizontal, 16)
            }

            // 第二行：户型筛选（独立一行，选项随已收录房源的户型类型动态增减；支持多选）
            // v1.69：「全部户型」固定在最左，不随右侧户型左右移动
            HStack(spacing: 8) {
                filterChip(title: "全部户型", isOn: layoutFilters.isEmpty) {
                    layoutFilters.removeAll()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(layouts, id: \.self) { layout in
                            filterChip(title: layout, isOn: layoutFilters.contains(layout)) {
                                if layoutFilters.contains(layout) {
                                    layoutFilters.remove(layout)
                                } else {
                                    layoutFilters.insert(layout)
                                }
                            }
                        }
                    }
                    .padding(.trailing, 16)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }

    private func filterChip(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(isOn ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isOn ? AppTheme.primary : Color.white)
                .foregroundColor(isOn ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 列表（点击卡片进入详情；多选模式点击卡片切换选中；编辑/已租/删除在详情页操作）

    private var houseList: some View {
        Group {
            if houses.isEmpty {
                EmptyStateView(
                    icon: "house",
                    title: "还没有房源",
                    subtitle: "点右上角「+」登记第一套房源"
                )
            } else if filteredHouses.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "没有匹配的房源",
                    subtitle: "换个搜索词或筛选条件试试"
                )
            } else {
                // v1.10：列表容器由 ScrollView+自定义 SwipeActionRow 改为 List+原生 swipeActions（与其他板块一致），
                // 左滑菜单「分享」替换为「已租」（直接切换房源状态为已租）
                List {
                    ForEach(filteredHouses) { house in
                        if isSelecting {
                            // 多选模式：点击整卡切换选中，左上角勾选标记
                            Button {
                                toggleHouseSelect(house)
                            } label: {
                                HouseCardView(house: house)
                                    .overlay(alignment: .topLeading) {
                                        Image(systemName: selectedHouseIDs.contains(house.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 22))
                                            .foregroundColor(selectedHouseIDs.contains(house.id) ? AppTheme.primary : Color.white)
                                            .shadow(radius: 2)
                                            .padding(8)
                                    }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        } else {
                            // 卡片左滑菜单（编辑 / 状态切换 / 删除），样式与其他板块一致；点击卡片进入详情
                            // v1.11：状态按钮按当前状态动态显示（待租→「已租」、已租→「待租」），颜色用绿色与编辑的蓝色区分
                            HouseCardView(house: house)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    showDetailHouse = house
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        deleteTarget = house
                                        isBatchDelete = false
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                    .tint(.red)
                                    Button {
                                        toggleHouseStatus(house)
                                    } label: {
                                        Label(house.status == .rented ? "待租" : "已租", systemImage: house.status == .rented ? "arrow.uturn.backward" : "checkmark.circle")
                                    }
                                    .tint(.green)
                                    Button {
                                        showEditHouse = house
                                    } label: {
                                        Label("编辑", systemImage: "pencil")
                                    }
                                    .tint(.themeBlue)
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(AppTheme.background)
                // v1.19：下拉刷新 = 从云端拉取房源（与左上角手动同步同效果）
                // v1.63：下拉刷新改本地刷新——媒体补全检测（磁盘与记录对账），不再触发云端同步；
                //        左上角刷新按钮保持云端同步不变
                .refreshable {
                    await localRefreshWithMediaCheck()
                }
            }
        }
        // v1.21：多选模式底部操作栏（v1.12：增加批量已租 / 批量删除，分享逻辑保留不动）
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Text("已选 \(selectedHouseIDs.count) 套")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(AppTheme.primary)
                        Spacer()
                        Button("全选") {
                            selectAllFiltered()
                        }
                        .font(.subheadline)
                        .disabled(selectedHouseIDs.count == filteredHouses.count)
                    }
                    HStack(spacing: 10) {
                        // v1.12：批量已租——选中的待租房源一键标为已租（已租的保持不变）
                        Button {
                            batchSetRented()
                        } label: {
                            Text("批量已租")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(selectedHouseIDs.isEmpty)
                        // v1.12：批量删除——移入回收站（二级确认，不删照片视频）
                        Button(role: .destructive) {
                            isBatchDelete = true
                            showDeleteConfirm = true
                        } label: {
                            Text("删除（\(selectedHouseIDs.count)）")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(selectedHouseIDs.isEmpty)
                        // v1.21：批量分享（合集卡片）——保留原逻辑
                        Button {
                            startMultiShare()
                        } label: {
                            Text("分享（\(selectedHouseIDs.count)）")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.primary)
                        .disabled(selectedHouseIDs.isEmpty)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
    }

    // MARK: - v1.21 多选分享

    private func toggleHouseSelect(_ house: House) {
        if selectedHouseIDs.contains(house.id) {
            selectedHouseIDs.remove(house.id)
        } else {
            selectedHouseIDs.insert(house.id)
        }
    }

    private func selectAllFiltered() {
        for house in filteredHouses {
            selectedHouseIDs.insert(house.id)
        }
    }

    private func exitMultiSelect() {
        isSelecting = false
        selectedHouseIDs.removeAll()
        shareQueue = []
        shareIndex = 0
        currentShareStep = nil
    }

    /// v1.36 需求1：卡片左滑「删除」→ 彻底删除（本地文件+数据库记录+云端桶 h/<房号>/ 一并删除，不再进回收站）
    /// 保留二次确认弹窗；backups/media 镜像保留；云端失败写操作日志（不阻塞本地删除）
    private func softDeleteHouse(_ house: House) {
        guard let ctx = houseModelContext else {
            infoMessage = "数据容器不可用，无法删除"; showInfoAlert = true
            return
        }
        let roomKey = house.mediaRoomKey
        let config = CosConfig.load()
        let wasCloud = house.cloudStatus   // v1.19 补全：记录删除前存储位置，用于成功提示
        MediaStore.deleteHouseDirectory(roomKey: roomKey)
        ctx.delete(house)
        do {
            try ctx.save()
            NotificationCenter.default.post(name: Self.houseStoreChanged, object: nil)
        } catch {
            infoMessage = "删除失败：\(error.localizedDescription)"; showInfoAlert = true
        }
        // v1.19 补全：删除成功提示——区分删了本地 / 云端 / 双端
        switch wasCloud {
        case .local:
            infoMessage = "已删除本地房源"; showInfoAlert = true
        case .both:
            infoMessage = "已删除本地房源，正在同步删除云端…"; showInfoAlert = true
        case .cloud:
            infoMessage = "已删除云端同步副本"; showInfoAlert = true
        }
        // 云端同步删除（v1.69 规范：单条日志「彻底删除（本地+云端）」）
        if let config = config, config.isValid {
            Task {
                do {
                    var objCount = 0
                    try await CloudBackupService.deleteHouseRemoteFolder(roomKey: roomKey, config: config, writeLog: false, reportCount: { objCount = $0 })
                    try await CloudHouseSync.delete(roomKey: roomKey, config: config)
                    BackupLogStore.log(category: "删除", action: "彻底删除（本地+云端）", result: "成功", detail: "\(roomKey)（云端桶文件夹\(objCount)个对象 + 云端账本已移除）", cloud: true)
                } catch {
                    BackupLogStore.log(category: "删除", action: "彻底删除（本地+云端）", result: "失败", detail: "\(roomKey) \(error.localizedDescription)", cloud: true)
                    await MainActor.run {
                        infoMessage = "云端删除失败：\(error.localizedDescription)。可在「设置 → 桶管理」手动清理 h/\(roomKey)/"; showInfoAlert = true
                    }
                }
            }
        } else {
            BackupLogStore.log(category: "删除", action: "彻底删除（本地+云端）", result: "跳过", detail: "未配置云存储 \(roomKey)", cloud: true)
        }
    }

    /// v1.11：卡片左滑状态切换按钮——待租→已租、已租→待租，按当前状态动态显示并反向切换。
    /// 默认列表筛选口径为「待租」，切换为已租后该房源从当前列表消失；已租筛选下左滑可一键改回待租。
    /// v1.19：切换时刷新最后更新时间，并把新状态同步到云端账本（共享房源）。
    private func toggleHouseStatus(_ house: House) {
        guard let ctx = houseModelContext else { return }
        house.status = (house.status == .rented) ? .available : .rented
        house.lastUpdatedAt = Date()
        try? ctx.save()
        pushHouseToCloud(house)
        NotificationCenter.default.post(name: Self.houseStoreChanged, object: nil)
    }

    // MARK: - v1.19 云端房源同步（共享房源）

    /// 把单套房源推送到云端账本（读改写，同房号覆盖）。无云存储配置则跳过（仅本地）。
    private func pushHouseToCloud(_ house: House) {
        guard let config = CosConfig.load() else { return }
        let record = CloudHouseSync.record(from: house, username: CloudUser.username)
        Task {
            do {
                try await CloudHouseSync.upload(record: record, config: config)
                await MainActor.run {
                    house.cloudStatus = .both
                    try? houseModelContext?.save()
                }
                BackupLogStore.log(category: "房源", action: "同步房源（本地→云端）", result: "成功", detail: house.displayRoomNo, cloud: true)
            } catch {
                BackupLogStore.log(category: "房源", action: "同步房源（本地→云端）", result: "失败", detail: "\(house.displayRoomNo)：\(error.localizedDescription)", cloud: true)
            }
        }
    }

    /// v1.41：云端账本与本地房源的字段级对比——任一字段（含媒体清单）不同即视为有变化。
    /// 替代旧的时间戳比较：时间戳只有秒级精度且恢复备份后 lastUpdatedAt 为空，
    /// 会导致「明明没变化每次同步都判更新」。字段级对比满足「一个标点符号变了都要同步」。
    /// v1.43：媒体清单改用归一化等价比较（去扩展名小写）——视频 .mov/.mp4 视为同一文件，
    ///        不再因两套扩展名互斥而每次同步都误判「更新」。
    private func cloudRecordDiffers(_ rec: CloudHouseRecord, from house: House) -> Bool {
        if rec.roomNo != house.roomNo { return true }
        if rec.tower != house.tower { return true }
        if rec.landlord != house.landlord { return true }
        if rec.layout != house.layout { return true }
        if rec.price != house.price { return true }
        if rec.password != house.password { return true }
        if rec.remark != house.remark { return true }
        if rec.status != house.statusRaw { return true }
        let localMedia = Set(house.mediaItems.map { Self.mediaNormKey($0.fileName) })
        if localMedia != Set(rec.mediaNames.map { Self.mediaNormKey($0) }) { return true }
        return false
    }

    /// v1.43：媒体名归一化 key——去扩展名 + 小写。
    /// 视频 .mov/.mp4 同源（上传云端统一转 mp4、本地按原样或账本名保存），按此视为同一文件；
    /// 首帧图「xxx.mp4.vthumb.jpg」归一化为「xxx.mp4.vthumb」，与视频「xxx」天然区分，不会被误配。
    private static func mediaNormKey(_ name: String) -> String {
        (name as NSString).deletingPathExtension.lowercased()
    }

    /// 从云端拉取房源账本并同步到本地（下拉刷新 / 左上角手动同步同效果）。
    /// v1.19 补全「增减逻辑」：
    ///  - 增：云端新增 → 完整下载到本地（文字 + 媒体），标双端、可编辑
    ///  - 改：云端比本地新 → 覆盖文字字段；本地媒体缺失但云端有 → 自动下载媒体
    ///  - 减：本地房源在云端账本已不存在 → 若它来自云端（双端/云端）则跟随删除；纯本地未上传的保留并补传云端
    ///  - 无任何变化 → 提示「已刷新，无变化」，不写入操作日志
    /// v1.41：
    ///  - 「更新」判定改为字段级对比（cloudRecordDiffers），不再依赖时间戳（时间戳精度/恢复备份导致误判）
    ///  - 媒体差异双向识别：云端有本地缺（要下载）与 本地有云端缺（要跟随删除）都算变化并弹确认
    /// v1.63：下拉刷新 = 本地刷新（媒体补全检测）：
    /// 磁盘有而记录没有 → 自动补建媒体记录；记录有而磁盘没有 → 提示待云端回补；
    /// 无对应房源的目录 → 提示可扫描补录。有变化列明细，无变化提示「已刷新，无变化」。
    private func localRefreshWithMediaCheck() async {
        guard let ctx = houseModelContext else { return }
        let all = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
        let active = all.filter { !$0.isTrashed }
        var addedLines: [String] = []
        var missingLines: [String] = []
        var addedCount = 0
        var addedFiles = 0
        await MainActor.run {
            var inserted: [MediaItem] = []
            for house in active {
                // v1.69：目录名强制带前缀（mediaRoomKey），不再做无前缀迁移
                let dir = MediaStore.houseDirectory(roomKey: house.mediaRoomKey)
                let disk = Set(MediaStore.mediaFileNames(in: dir))
                let recorded = Set(house.mediaItems.map { $0.fileName })
                let toAdd = disk.subtracting(recorded)
                let missing = recorded.subtracting(disk)
                if !toAdd.isEmpty {
                    for f in toAdd.sorted() {
                        let lower = f.lowercased()
                        let media = MediaItem(fileName: f, kind: (lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")) ? "video" : "image")
                        media.house = house
                        ctx.insert(media)
                        inserted.append(media)
                        addedFiles += 1
                    }
                    addedCount += 1
                    addedLines.append("\(house.displayRoomNo)：补全 \(toAdd.count) 个媒体")
                }
                if !missing.isEmpty {
                    missingLines.append("\(house.displayRoomNo)：本地缺 \(missing.count) 个文件（云端回补）")
                }
            }
            if !inserted.isEmpty { try? ctx.save() }
            // 未收录目录：media 下有目录但无对应房源
            let keys = MediaStore.scanMediaDirectoryKeys()
            let orphanKeys = keys.filter { key in
                let (roomNo, tower) = BatchImporter.parseRoom(key, explicitTower: key.hasPrefix("2-") ? 2 : 0)
                guard !roomNo.isEmpty else { return true }
                return !active.contains { $0.tower == tower && $0.roomNo == roomNo }
            }
            var lines: [String] = []
            if addedCount > 0 {
                lines.append("媒体补全 \(addedCount) 间（\(addedFiles) 个文件）：")
                lines.append(contentsOf: addedLines)
            }
            if !missingLines.isEmpty {
                lines.append("待云端回补：" + missingLines.joined(separator: "；"))
            }
            if !orphanKeys.isEmpty {
                lines.append("未收录目录 \(orphanKeys.count) 个：\(orphanKeys.prefix(5).joined(separator: "、"))（可去批量录入-扫描补录导入）")
            }
            if lines.isEmpty {
                infoMessage = "已刷新，无变化"
            } else {
                infoMessage = lines.joined(separator: "\n")
            }
            showInfoAlert = true
            NotificationCenter.default.post(name: Self.houseStoreChanged, object: nil)
        }
    }

    private func syncCloudHouses() async {
        let config = CosConfig.load()
        guard let config else {
            infoMessage = "未配置云存储，无法同步云端房源"; showInfoAlert = true
            return
        }
        guard let ctx = houseModelContext else { return }
        do {
            let recs = try await CloudHouseSync.fetchAll(config: config)
            // v1.40 第11点：先算 diff 弹确认，确认后才应用（此前直接执行后才弹结果，用户无法拦截误覆盖）
            // v1.42：新增/更新/删除/补传/媒体差异全部带具体房号（用户要求：只要对比有差别就列出房号）
            var added: [(roomNo: String, roomKey: String, mediaNames: [String])] = []
            var updated: [(roomNo: String, byUser: String)] = []
            var deleted: [(roomKey: String, roomNo: String)] = []
            var pushed: [(roomKey: String, roomNo: String)] = []
            var mediaRoomKeys: [(roomKey: String, roomNo: String)] = []
            await MainActor.run {
                pendingSyncMediaDiff = []   // v1.43：每次同步前重置媒体差异收集
                let local = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
                var localByKey: [String: House] = [:]
                for h in local where !h.isTrashed { localByKey[h.mediaRoomKey] = h }
                let cloudKeys = Set(recs.map { $0.roomKey })
                for rec in recs {
                    if let h = localByKey[rec.roomKey] {
                        if cloudRecordDiffers(rec, from: h) {
                            // v1.40 B1：多人冲突提示——云端由他人更新时展示修改者
                            // v1.69：房号一律真实引用带前缀（rec.roomKey），不做去前缀简化
                            updated.append((rec.roomKey, rec.updatedBy))
                        }
                        // v1.43：媒体差异三名单对账（账本 / 本地记录 / 磁盘真实文件），归一化等价比较：
                        //   - 账本有、本地记录或磁盘缺 → 需要下载（含用户手删 media 文件后刷新刷回）
                        //   - 本地记录或磁盘有、账本没有 → 需要跟随删除（多余/旧残留收敛）
                        //   - 视频 .mov/.mp4 视为同一文件（去扩展名比较），消除两套名字互斥导致的循环
                        let localNorm = Set(h.mediaItems.map { Self.mediaNormKey($0.fileName) })
                        let cloudNorm = Set(rec.mediaNames.map { Self.mediaNormKey($0) })
                        let diskNorm = Set(MediaStore.existingFileNames(roomKey: h.mediaRoomKey).map { Self.mediaNormKey($0) })
                        let needDownload = !cloudNorm.isSubset(of: localNorm) || !cloudNorm.isSubset(of: diskNorm)
                        let needRemove = !localNorm.isSubset(of: cloudNorm) || !diskNorm.isSubset(of: cloudNorm)
                        if needDownload || needRemove {
                            mediaRoomKeys.append((h.mediaRoomKey, h.displayRoomNo))
                            pendingSyncMediaDiff.append((h.displayRoomNo, needDownload))
                        }
                    } else {
                        // v1.69：新增列表与媒体差异的房号一律带前缀真实引用
                        added.append((rec.roomKey, rec.roomKey, rec.mediaNames))
                        if !rec.mediaNames.isEmpty {
                            mediaRoomKeys.append((rec.roomKey, rec.roomKey))
                            pendingSyncMediaDiff.append((rec.roomKey, true))
                        }
                    }
                }
                for (key, h) in localByKey where !cloudKeys.contains(key) {
                    // v1.71（方案 A）：云端账本为空（首次同步/云端被清空）时一律走「本地→云端」补传，
                    // 不判定「云端已删」——否则本地双端房会被误判为云端已删而提示删本地（v1.42 事故模式）。
                    if !recs.isEmpty && (h.cloudStatus == .both || h.cloudStatus == .cloud) {
                        deleted.append((key, h.displayRoomNo))
                    } else {
                        pushed.append((key, h.displayRoomNo))
                    }
                }
            }
            let hasChange = !added.isEmpty || !updated.isEmpty || !deleted.isEmpty || !pushed.isEmpty || !mediaRoomKeys.isEmpty
            guard hasChange else {
                // v1.65：账本无变化时做「云端媒体对账」——本地有媒体但云端 h/<房号>/ 缺对象 → 补齐媒体。
                // v1.68：改为先「干跑」列桶比对（只查不传），得出待补列表 → 弹确认框，确认后才开始上传。
                // 不再静默后台跑（用户看不到过程以为没反应）；上传过程走全局同步任务中心：
                // 房源页顶部进度条 + 可最小化收起到「设置 → 待补传媒体」随时查看进度。
                let pending = await preflightMediaSnapshots(config: config, ctx: ctx)
                if pending.isEmpty {
                    infoMessage = "已刷新，无变化"; showInfoAlert = true
                    return
                }
                pendingMediaSnaps = pending
                showMediaSyncConfirm = true
                return
            }
            pendingSyncRecs = recs
            pendingSyncAdded = added
            pendingSyncUpdated = updated
            pendingSyncDeleted = deleted
            pendingSyncPushed = pushed
            showSyncConfirm = true
        } catch {
            infoMessage = "同步失败：\(error.localizedDescription)"; showInfoAlert = true
            BackupLogStore.log(category: "同步", action: "同步房源（云端→本地）", result: "失败", detail: error.localizedDescription, cloud: true)
        }
    }

    /// v1.67：在主线程把 House 的可跨线程数据提取成值快照（后台线程安全）
    private func makePendingSnapshot(from h: House) -> PendingMediaHouseSnapshot {
        let files = h.mediaItems.map { ShareMediaFile(name: $0.fileName, kind: $0.kind) }
        let profile = CosUploader.loadShareProfile()
        let info = ShareHouseInfo(
            displayRoomNo: h.displayRoomNo, towerLabel: h.towerLabel,
            layout: h.layout, statusLabel: h.status.label, priceText: h.priceText,
            landlord: h.landlord, password: h.password, remark: h.remark,
            name: profile.name, phone: profile.phone
        )
        return PendingMediaHouseSnapshot(roomKey: h.mediaRoomKey, displayRoomNo: h.displayRoomNo, files: files, info: info)
    }

    /// v1.68：云端媒体对账「干跑」——只列桶比对，不传任何东西，返回「云端缺媒体」的房源快照列表。
    /// 供同步无变化时弹确认框前预检；列桶失败视为待补（确认后可重试，不丢数据）。
    private func preflightMediaSnapshots(config: CosConfig, ctx: ModelContext) async -> [PendingMediaHouseSnapshot] {
        var snapshots: [PendingMediaHouseSnapshot] = []
        await MainActor.run {
            let local = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
            snapshots = local.filter { !$0.isTrashed && $0.cloudStatus != .cloud && !$0.mediaItems.isEmpty }.map { makePendingSnapshot(from: $0) }
        }
        var pending: [PendingMediaHouseSnapshot] = []
        for snap in snapshots {
            do {
                let objs = try await CosUploader.listObjects(prefix: "h/\(snap.roomKey)/", config: config)
                let cloudNames = Set(objs.map { Self.mediaNormKey(($0.name as NSString).lastPathComponent) })
                let localNames = Set(snap.files.map { Self.mediaNormKey($0.name) })
                if !localNames.isSubset(of: cloudNames) { pending.append(snap) }
            } catch {
                pending.append(snap)
            }
        }
        return pending
    }

    /// v1.68：按确认后的快照列表执行媒体补传，走全局同步任务中心（进度条 / 最小化 / 待补传页可见）。
    /// 幂等覆盖+刷新分享页（与批量导入同机制）；失败保留在补传队列，下次刷新对账再补。
    private func runMediaUpload(snaps: [PendingMediaHouseSnapshot], config: CosConfig?, ctx: ModelContext?) async {
        guard !snaps.isEmpty, let config else { return }
        let total = snaps.reduce(0) { $0 + $1.files.count }
        syncCenter.begin(title: "补齐云端媒体", roomKeys: snaps.map { $0.displayRoomNo }, total: total)
        var uploaded: [String] = []
        var failed: [String] = []
        var done = 0
        for snap in snaps {
            syncCenter.advance(done: done, current: snap.displayRoomNo)
            do {
                _ = try await CosUploader.autoRegenerateMaskedShare(mediaFiles: snap.files, roomKey: snap.roomKey, info: snap.info, config: config)
                uploaded.append(snap.displayRoomNo)
            } catch {
                failed.append(snap.displayRoomNo)
            }
            done += snap.files.count
            syncCenter.advance(done: done, current: snap.displayRoomNo)
        }
        syncCenter.finish(success: failed.isEmpty)
        // v1.70：完成后进度条自动收起（不再需要手动点「完成」）——任务已结束，弹窗已告知结果；
        // 若曾最小化到「待补传媒体」页，进行中的任务卡片同样自动消失。
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            syncCenter.dismiss()
            syncTaskMinimized = false
        }
        var lines: [String] = []
        if !uploaded.isEmpty { lines.append("已补齐云端媒体 \(uploaded.count) 套：" + uploaded.joined(separator: "，")) }
        if !failed.isEmpty { lines.append("补传失败（可稍后再刷新重试）：" + failed.joined(separator: "，")) }
        infoMessage = lines.isEmpty ? "没有需要补传的媒体" : lines.joined(separator: "\n")
        showInfoAlert = true
        if !uploaded.isEmpty {
            BackupLogStore.log(category: "同步", action: "补齐云端媒体（本地→云端）", result: "成功", detail: uploaded.joined(separator: "，"), cloud: true)
        }
        if !failed.isEmpty {
            BackupLogStore.log(category: "同步", action: "补齐云端媒体（本地→云端）", result: "失败", detail: failed.joined(separator: "，"), cloud: true)
        }
    }

    /// v1.68：媒体对账确认框详情——列出每套缺几个媒体
    private func mediaSyncConfirmSummary() -> String {
        guard !pendingMediaSnaps.isEmpty else { return "" }
        var lines = ["云端缺失媒体 \(pendingMediaSnaps.count) 套，确认后开始补齐："]
        lines += pendingMediaSnaps.map { "\($0.displayRoomNo)（缺 \($0.files.count) 个媒体）" }
        return lines.joined(separator: "\n")
    }

    /// v1.68：进行中的同步/补传任务进度条（房源页顶部，可「最小化」收起到设置-待补传媒体页查看）
    @ViewBuilder
    private var syncTaskBanner: some View {
        if let t = syncCenter.task, !syncTaskMinimized {
            VStack(spacing: 8) {
                HStack {
                    Label(t.title, systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if t.isRunning {
                        Button { syncTaskMinimized = true } label: {
                            Label("最小化", systemImage: "minus.circle")
                                .font(.footnote)
                        }
                    } else {
                        Button {
                            syncCenter.dismiss()
                            syncTaskMinimized = false
                        } label: {
                            Label("完成", systemImage: "checkmark.circle")
                                .font(.footnote)
                        }
                    }
                }
                ProgressView(value: t.fraction)
                HStack {
                    if t.isRunning {
                        Text("\(t.done)/\(t.total) 个媒体 · 正在处理 \(t.current)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Text(t.success ? "全部完成" : "完成，部分失败")
                            .font(.caption2)
                            .foregroundColor(t.success ? .green : .orange)
                    }
                    Spacer()
                    Text("\(Int(t.fraction * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
        }
    }

    /// v1.40 第11点：确认弹窗里的变化详情
    /// v1.42：所有差异（新增/更新/云端已删/本地补传/媒体差异）一律列出具体房号
    private func syncChangeSummary() -> String {
        var parts: [String] = []
        if !pendingSyncAdded.isEmpty { parts.append("新增\(pendingSyncAdded.count)套：\(pendingSyncAdded.map { $0.roomNo }.prefix(8).joined(separator: "，"))") }
        if !pendingSyncUpdated.isEmpty {
            let upd = pendingSyncUpdated.prefix(8).map { "\($0.roomNo)（\($0.byUser.isEmpty ? "他人" : $0.byUser)改）" }.joined(separator: "，")
            parts.append("更新\(pendingSyncUpdated.count)套：\(upd)")
        }
        if !pendingSyncDeleted.isEmpty { parts.append("云端已删\(pendingSyncDeleted.count)套：\(pendingSyncDeleted.map { $0.roomNo }.prefix(8).joined(separator: "，"))，本地跟随删除") }
        if !pendingSyncPushed.isEmpty { parts.append("本地新增\(pendingSyncPushed.count)套将补传云端：\(pendingSyncPushed.map { $0.roomNo }.prefix(8).joined(separator: "，"))") }
        // v1.43：媒体差异独立列出房号，并标注「缺（将从云端补齐）」与「多（将跟随删除）」，不重复计入更新数
        if !pendingSyncMediaDiff.isEmpty {
            let missing = Set(pendingSyncMediaDiff.filter { $0.missing }.map { $0.roomNo })
            let extra = Set(pendingSyncMediaDiff.filter { !$0.missing }.map { $0.roomNo })
            var mediaParts: [String] = []
            if !missing.isEmpty { mediaParts.append("本地缺媒体将从云端补齐：\(Array(missing).prefix(8).joined(separator: "，"))") }
            if !extra.isEmpty { mediaParts.append("本地多余媒体将跟随删除：\(Array(extra).prefix(8).joined(separator: "，"))") }
            parts.append(contentsOf: mediaParts)
        }
        return parts.joined(separator: "\n") + "\n\n确认后才会同步；取消则本次不动任何数据。"
    }

    /// v1.40 第11点：确认后应用同步（原执行逻辑）
    /// v1.41：更新判定改字段级对比；新增媒体 reconcile——跟随云端删除本地多余媒体（账本已删、本地残留）
    private func applySyncPreview() async {
        guard let config = CosConfig.load(), let ctx = houseModelContext else { return }
        let recs = pendingSyncRecs
        do {
            var addedCount = 0, updatedCount = 0, deletedCount = 0, pushedCount = 0
            var removedMediaCount = 0
            var addedRoomNo: [String] = []
            var updatedRoomNo: [String] = []
            var deletedRoomNo: [String] = []
            var pushedRoomNo: [String] = []
            var pushedRecords: [CloudHouseRecord] = []   // v1.64：补传聚合
            var pushedMediaHouses: [PendingMediaHouseSnapshot] = []   // v1.67：补传后需上传媒体的快照（主线程提取，后台只传值）
            var mediaDiffRoomNo: [String] = []
            var mediaRoomKeys: [(roomKey: String, roomNo: String)] = []   // v1.42：带房号
            await MainActor.run {
                let local = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
                var localByKey: [String: House] = [:]
                for h in local where !h.isTrashed { localByKey[h.mediaRoomKey] = h }
                let cloudKeys = Set(recs.map { $0.roomKey })
                for rec in recs {
                    if let h = localByKey[rec.roomKey] {
                        if cloudRecordDiffers(rec, from: h) {
                            h.roomNo = rec.roomNo; h.tower = rec.tower; h.landlord = rec.landlord
                            h.layout = rec.layout; h.price = rec.price; h.password = rec.password
                            h.remark = rec.remark; h.statusRaw = rec.status
                            h.lastUpdatedAt = rec.updatedAt
                            updatedCount += 1
                            updatedRoomNo.append(rec.roomKey)   // v1.69：带前缀真实引用
                        }
                        // v1.43：媒体差异双向 reconcile（归一化等价，.mov/.mp4 视为同一文件）——
                        //  ① 账本有、本地记录或磁盘缺 → 下载（mediaRoomKeys；含用户手删文件后刷回）
                        //  ② 本地记录有、账本已无 → 跟随删除（文件 + 记录）
                        //  ③ 磁盘上有、账本已无的孤儿残留（旧首帧图/分享页等）→ 只删文件
                        let cloudNorm = Set(rec.mediaNames.map { Self.mediaNormKey($0) })
                        let localNorm = Set(h.mediaItems.map { Self.mediaNormKey($0.fileName) })
                        let diskNorm = Set(MediaStore.existingFileNames(roomKey: h.mediaRoomKey).map { Self.mediaNormKey($0) })
                        let needDownload = !cloudNorm.isSubset(of: localNorm) || !cloudNorm.isSubset(of: diskNorm)
                        let needRemove = !localNorm.isSubset(of: cloudNorm) || !diskNorm.isSubset(of: cloudNorm)
                        if needDownload {
                            mediaRoomKeys.append((h.mediaRoomKey, h.displayRoomNo))
                            mediaDiffRoomNo.append(h.displayRoomNo)
                        }
                        if needRemove {
                            for item in Array(h.mediaItems) where !cloudNorm.contains(Self.mediaNormKey(item.fileName)) {
                                MediaStore.delete(fileName: item.fileName, roomKey: h.mediaRoomKey)
                                ctx.delete(item)
                                HouseMediaUploadQueue.remove(roomKey: h.mediaRoomKey, fileName: item.fileName)
                                removedMediaCount += 1
                            }
                            for dname in MediaStore.existingFileNames(roomKey: h.mediaRoomKey) where !cloudNorm.contains(Self.mediaNormKey(dname)) {
                                MediaStore.delete(fileName: dname, roomKey: h.mediaRoomKey)
                                removedMediaCount += 1
                            }
                        }
                        h.cloudStatus = .both
                    } else {
                        let h = House(
                            roomNo: rec.roomNo, tower: rec.tower, landlord: rec.landlord,
                            layout: rec.layout, price: rec.price, password: rec.password,
                            remark: rec.remark, status: HouseStatus(rawValue: rec.status) ?? .available
                        )
                        h.lastUpdatedAt = rec.updatedAt
                        h.cloudStatus = .cloud
                        ctx.insert(h)
                        addedCount += 1
                        addedRoomNo.append(rec.roomKey)   // v1.69：带前缀真实引用
                        if !rec.mediaNames.isEmpty {
                            mediaRoomKeys.append((h.mediaRoomKey, rec.roomKey))
                            mediaDiffRoomNo.append(rec.roomKey)
                        }
                    }
                }
                for (key, h) in localByKey where !cloudKeys.contains(key) {
                    if h.cloudStatus == .both || h.cloudStatus == .cloud {
                        MediaStore.deleteHouseDirectory(roomKey: key)
                        ctx.delete(h)
                        deletedCount += 1
                        deletedRoomNo.append(h.displayRoomNo)
                    } else {
                        // v1.64：不再逐个并发 pushHouseToCloud（并发读改写同一账本文件会互相覆盖、
                        // 云端丢失房源）——先收集，同步完成后一次性聚合写回云端账本
                        pushedRecords.append(CloudHouseSync.record(from: h, username: CloudUser.username))
                        pushedCount += 1
                        pushedRoomNo.append(h.displayRoomNo)
                    }
                }
                try? ctx.save()
                reloadHouses()
            }
            // v1.64：本地补传聚合为一次全量账本写入（串行）——此前 7 个异步 Task 并发对 h/_houses.json
            // 做「读改写」，最后一次写回会覆盖其他并发任务的结果，导致云端只剩最后一条（实测只剩 2309）。
            // 聚合写 + 成功后统一把补传房源标「双端」，失败保持「仅本地」并提示，可下次重试。
            if !pushedRecords.isEmpty {
                do {
                    var all = recs
                    for rec in pushedRecords {
                        all.removeAll { $0.roomKey == rec.roomKey }
                        all.append(rec)
                    }
                    try await CloudHouseSync.uploadRecords(all, config: config)
                    await MainActor.run {
                        let local = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
                        var snapshots: [PendingMediaHouseSnapshot] = []
                        for h in local where !h.isTrashed && pushedRecords.contains(where: { $0.roomKey == h.mediaRoomKey }) {
                            h.cloudStatus = .both
                            if !h.mediaItems.isEmpty {
                                snapshots.append(makePendingSnapshot(from: h))
                            }
                        }
                        pushedMediaHouses = snapshots
                        try? ctx.save()
                        reloadHouses()
                    }
                    // v1.65：补传账本后同步上传本地媒体（幂等覆盖+刷新分享页，与批量导入同机制）。
                    // 此前同步只写账本不传媒体，恢复/导入后媒体永远上不了云，「双端」名不副实；
                    // 上传失败的媒体下次「已刷新无变化」会走云端媒体对账再补。
                    // v1.67：只用主线程提取的值快照，后台不再访问 SwiftData 模型。
                    // v1.68：上传纳入全局同步任务中心（房源页进度条 + 可最小化到待补传媒体页查看）。
                    if !pushedMediaHouses.isEmpty {
                        Task { await runMediaUpload(snaps: pushedMediaHouses, config: config, ctx: ctx) }
                    }
                    BackupLogStore.log(category: "同步", action: "补传房源（本地→云端）", result: "成功", detail: pushedRoomNo.joined(separator: "，"), cloud: true)
                } catch {
                    await MainActor.run {
                        infoMessage = "补传云端失败：\(error.localizedDescription)。本地房源保持「仅本地」，可稍后重新同步补传"; showInfoAlert = true
                    }
                    BackupLogStore.log(category: "同步", action: "补传房源（本地→云端）", result: "失败", detail: error.localizedDescription, cloud: true)
                }
            }
            var mediaSaved = 0
            if !mediaRoomKeys.isEmpty {
                for (roomKey, _) in mediaRoomKeys {
                    // v1.42：同步下载进度 → 卡片底部进度条（云端 → 本机）
                    HouseSyncProgress.shared.update(roomKey: roomKey, direction: .download, progress: 0)
                    // v1.43：只下载云端账本名单（expectedNames）内的媒体，落盘名与账本一致 →
                    // 同步完成后本地记录/磁盘 = 账本名单，下次同步零差异（根治「下载N删N」循环）
                    guard let rec = recs.first(where: { $0.roomKey == roomKey }) else {
                        HouseSyncProgress.shared.update(roomKey: roomKey, direction: .download, progress: 1)
                        continue
                    }
                    let files = (try? await CosUploader.downloadHouseMedia(roomKey: roomKey, expectedNames: rec.mediaNames, config: config, progress: { p in
                        HouseSyncProgress.shared.update(roomKey: roomKey, direction: .download, progress: p)
                    })) ?? []
                    HouseSyncProgress.shared.update(roomKey: roomKey, direction: .download, progress: 1)
                    mediaSaved += files.count
                    await MainActor.run {
                        let all = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
                        if let h = all.first(where: { $0.mediaRoomKey == roomKey && !$0.isTrashed }) {
                            // 下载返回的文件名 = 账本名 → 插入记录后本地记录与账本零差异
                            for f in files where !h.mediaItems.contains(where: { $0.fileName == f.fileName }) {
                                let item = MediaItem(fileName: f.fileName, kind: f.kind)
                                item.house = h
                                ctx.insert(item)
                            }
                            // v1.41：按账本补记录——磁盘已有但记录缺失（如恢复快速备份后，
                            // 备份只有记录引用没有媒体本体），补建 MediaItem 记录，详情页才能打开视频
                            if let rec = recs.first(where: { $0.roomKey == roomKey }) {
                                let recorded = Set(h.mediaItems.map { $0.fileName })
                                let disk = MediaStore.existingFileNames(roomKey: roomKey)
                                for name in rec.mediaNames where !recorded.contains(name) && disk.contains(name) {
                                    let lower = name.lowercased()
                                    let isVideo = lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")
                                    let item = MediaItem(fileName: name, kind: isVideo ? "video" : "image")
                                    item.house = h
                                    ctx.insert(item)
                                }
                            }
                            h.cloudStatus = .both
                            try? ctx.save()
                        }
                    }
                }
            }
            // v1.42：完成提示一律列出具体房号（用户要求：只要对比有差别就列出房号）
            // v1.43：媒体方向标注（云端→本地 / 本地→云端）
            var parts: [String] = []
            if addedCount > 0 { parts.append("新增\(addedCount)套：\(addedRoomNo.joined(separator: "，"))") }
            if updatedCount > 0 { parts.append("更新\(updatedCount)套：\(updatedRoomNo.joined(separator: "，"))") }
            if deletedCount > 0 { parts.append("云端已删\(deletedCount)套：\(deletedRoomNo.joined(separator: "，"))") }
            if pushedCount > 0 { parts.append("补传\(pushedCount)套：\(pushedRoomNo.joined(separator: "，"))") }
            if mediaSaved > 0 { parts.append("下载媒体\(mediaSaved)个（云端→本地）") }
            if removedMediaCount > 0 { parts.append("删除媒体\(removedMediaCount)个（本地多余跟随删）") }
            if !mediaDiffRoomNo.isEmpty { parts.append("媒体同步：\(Array(Set(mediaDiffRoomNo)).joined(separator: "，"))") }
            let msg = "已同步：\(parts.joined(separator: "，"))"
            infoMessage = msg; showInfoAlert = true
            BackupLogStore.log(category: "同步", action: "同步房源（云端→本地）", result: "成功", detail: msg, cloud: true)
            HouseSyncProgress.shared.clear()
        } catch {
            infoMessage = "同步失败：\(error.localizedDescription)"; showInfoAlert = true
            BackupLogStore.log(category: "同步", action: "同步房源（云端→本地）", result: "失败", detail: error.localizedDescription, cloud: true)
            HouseSyncProgress.shared.clear()
        }
    }

    // MARK: - v1.12 多选批量操作（批量已租 / 批量删除）

    /// 批量已租：选中的待租房源全部标为已租（已租的保持不变），完成后自动退出多选
    private func batchSetRented() {
        guard !selectedHouseIDs.isEmpty, let ctx = houseModelContext else { return }
        var changed = 0
        for house in houses where selectedHouseIDs.contains(house.id) && house.status == .available {
            house.status = .rented
            changed += 1
        }
        try? ctx.save()
        NotificationCenter.default.post(name: Self.houseStoreChanged, object: nil)
        let total = selectedHouseIDs.count
        exitMultiSelect()
        infoMessage = "已将 \(changed) 套标记为已租（共选中 \(total) 套）"; showInfoAlert = true
    }

    /// v1.36 需求1：批量删除 → 彻底删除（本地文件+数据库记录+云端桶一并删除，不再进回收站）
    private func batchSoftDelete() {
        guard !selectedHouseIDs.isEmpty, let ctx = houseModelContext else {
            infoMessage = "数据容器不可用，无法删除"; showInfoAlert = true
            return
        }
        var changed = 0
        var deletedKeys: [String] = []
        let config = CosConfig.load()
        for house in houses where selectedHouseIDs.contains(house.id) {
            let roomKey = house.mediaRoomKey
            MediaStore.deleteHouseDirectory(roomKey: roomKey)
            ctx.delete(house)
            deletedKeys.append(roomKey)
            changed += 1
        }
        do {
            try ctx.save()
            NotificationCenter.default.post(name: Self.houseStoreChanged, object: nil)
        } catch {
            infoMessage = "删除失败：\(error.localizedDescription)"; showInfoAlert = true
        }
        // 云端同步删除（v1.69 规范）：单 Task 内**串行**逐套执行——此前每套一个并发 Task 同时
        // 读改写云端账本 h/_houses.json，并发互相覆盖导致删除不彻底（实测 7 套删完账本仍剩 3 套）。
        // 日志每套只记一条「彻底删除（本地+云端）」，不再出现「删媒体 + 删文件夹」两条混杂记录。
        // v1.71：接入全局同步任务中心——顶部进度条实时显示「批量删除云端房源 N 套」逐套推进，
        // 云端全部删完才弹完成提示（此前本地删完就弹「同步删除中」，云端过程无感知）。
        if let config = config, config.isValid {
            Task {
                syncCenter.begin(title: "批量删除云端房源", roomKeys: deletedKeys, total: deletedKeys.count)
                var failedKeys: [String] = []
                var done = 0
                for roomKey in deletedKeys {
                    syncCenter.advance(done: done, current: roomKey)
                    do {
                        var objCount = 0
                        try await CloudBackupService.deleteHouseRemoteFolder(roomKey: roomKey, config: config, writeLog: false, reportCount: { objCount = $0 })
                        try await CloudHouseSync.delete(roomKey: roomKey, config: config)
                        BackupLogStore.log(category: "删除", action: "彻底删除（本地+云端）", result: "成功", detail: "\(roomKey)（云端桶文件夹\(objCount)个对象 + 云端账本已移除）", cloud: true)
                    } catch {
                        failedKeys.append(roomKey)
                        BackupLogStore.log(category: "删除", action: "彻底删除（本地+云端）", result: "失败", detail: "\(roomKey) \(error.localizedDescription)", cloud: true)
                    }
                    done += 1
                    syncCenter.advance(done: done, current: roomKey)
                }
                syncCenter.finish(success: failedKeys.isEmpty)
                var lines = ["云端删除完成：成功 \(deletedKeys.count - failedKeys.count) 套"]
                if !failedKeys.isEmpty {
                    lines.append("失败 \(failedKeys.count) 套：\(failedKeys.joined(separator: "，"))（可在「设置 → 桶管理」手动清理）")
                }
                await MainActor.run {
                    infoMessage = lines.joined(separator: "\n"); showInfoAlert = true
                }
                // v1.71：完成后进度条自动收起
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    syncCenter.dismiss()
                    syncTaskMinimized = false
                }
            }
        } else {
            BackupLogStore.log(category: "删除", action: "彻底删除（本地+云端）", result: "跳过", detail: "未配置云存储 共\(deletedKeys.count)套", cloud: true)
        }
        let total = selectedHouseIDs.count
        exitMultiSelect()
        // v1.19 补全：批量删除成功提示（含云端同步）
        infoMessage = "已彻底删除 \(changed) 套本地房源（共选中 \(total) 套）；云端同步删除中…"; showInfoAlert = true
    }

    /// v1.7：卡片左滑「分享」→ 单套分享卡片（脱敏 / 完整），生成链接后弹系统分享面板
    /// 注意：Task 内只传值类型，绝不直接访问 SwiftData @Model（跨线程读取模型会闪退）
    private func generateSingleShare(mode: ShareMode) {
        guard let house = singleShareHouse else { return }
        guard let config = CosConfig.load(), config.isValid else {
            infoMessage = "请先到「设置 → 房源分享 → 远程配置」填写云存储配置（腾讯云 COS）并保存验证，再分享卡片链接"; showInfoAlert = true
            return
        }
        guard !house.mediaItems.isEmpty else {
            infoMessage = "这套房源还没有照片或视频，先编辑添加素材再分享"; showInfoAlert = true
            return
        }
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
        isGenerating = true
        generateTip = "正在上传照片和视频…"
        generateProgress = 0
        Task {
            do {
                let url = try await CosUploader.shareCard(mediaFiles: files, roomKey: roomKey, info: info, mode: mode, config: config) { p in
                    Task { @MainActor in self.generateProgress = p }
                }
                await MainActor.run {
                    isGenerating = false
                    shareQueue = [url]
                    shareIndex = 0
                    currentShareStep = ShareStep(url: url)
                    singleShareHouse = nil
                }
            } catch {
                await MainActor.run {
                    isGenerating = false
                    infoMessage = error.localizedDescription; showInfoAlert = true
                    singleShareHouse = nil
                }
            }
        }
    }

    private func startMultiShare() {
        guard !selectedHouseIDs.isEmpty else { return }
        guard let config = CosConfig.load(), config.isValid else {
            infoMessage = "请先到「设置 → 房源分享 → 远程配置」填写云存储配置（腾讯云 COS）并保存验证，再分享卡片链接"; showInfoAlert = true
            return
        }
        // 过滤出有素材的房源（无照片视频的无法生成卡片）
        let shareable = houses.filter { selectedHouseIDs.contains($0.id) && !$0.mediaItems.isEmpty }
        guard !shareable.isEmpty else {
            infoMessage = "选中的房源都没有照片或视频，先编辑添加素材再分享"; showInfoAlert = true
            return
        }
        activeDialog = .multiShare; showShareModeAlert = true
    }

    /// v1.22：生成【合集分享卡片】（一次选 N 套 → 一个链接 → 好友点开看全部），生成后弹一次系统分享面板
    /// 注意：值类型（ShareCollectionItem）在主线程构建完成，Task 内只传递值，绝不直接访问 SwiftData @Model（跨线程读取模型会闪退）
    private func generateShareQueue(mode: ShareMode) {
        guard let config = CosConfig.load(), config.isValid else {
            infoMessage = "请先到「设置 → 房源分享 → 远程配置」填写云存储配置（腾讯云 COS）并保存验证，再分享卡片链接"; showInfoAlert = true
            return
        }
        let shareable = houses.filter { selectedHouseIDs.contains($0.id) && !$0.mediaItems.isEmpty }
        guard !shareable.isEmpty else {
            infoMessage = "选中的房源都没有照片或视频，先编辑添加素材再分享"; showInfoAlert = true
            return
        }
        let sortedShareable = shareable.sorted { a, b in
            if a.tower != b.tower { return a.tower < b.tower }
            if a.floorNumber != b.floorNumber { return a.floorNumber < b.floorNumber }
            if a.roomNumber != b.roomNumber { return a.roomNumber < b.roomNumber }
            return a.roomNo < b.roomNo
        }

        // 主线程先构建值类型数组（Task 闭包内不触碰 @Model）
        let rooms = sortedShareable.map { house -> ShareCollectionItem in
            ShareCollectionItem(
                roomKey: house.mediaRoomKey,
                displayRoomNo: house.displayRoomNo,
                towerLabel: house.towerLabel,
                layout: house.layout,
                statusLabel: house.status.label,
                priceText: house.priceText,
                landlord: house.landlord,
                password: house.password,
                remark: house.remark,
                mediaFiles: house.mediaItems.map { ShareMediaFile(name: $0.fileName, kind: $0.kind) }
            )
        }

        isGenerating = true
        generateTip = "正在生成合集分享卡片（共 \(sortedShareable.count) 套）…"
        generateProgress = 0

        Task {
            do {
                let url = try await CosUploader.shareCollection(rooms: rooms, mode: mode, config: config) { p in
                    Task { @MainActor in self.generateProgress = p }
                }
                await MainActor.run {
                    isGenerating = false
                    shareQueue = [url]
                    shareIndex = 0
                    currentShareStep = ShareStep(url: url)
                }
            } catch {
                await MainActor.run {
                    isGenerating = false
                    infoMessage = error.localizedDescription; showInfoAlert = true
                    exitMultiSelect()
                }
            }
        }
    }
}

// MARK: - 多选分享步骤（sheet(item:) 依次弹分享面板）

struct ShareStep: Identifiable {
    let id = UUID()
    let url: URL
}

#Preview {
    HouseListView()
        .modelContainer(for: [House.self, MediaItem.self], inMemory: true)
}
