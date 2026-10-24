import SwiftUI
import SwiftData

struct HouseListView: View {
    /// 房源板块使用独立 HouseStore 容器的专属 context（由 App 注入）。
    /// 不能用主容器的 modelContext——iOS 17 早期版本多配置容器上查询会崩溃（闪退根因）。
    @Environment(\.houseModelContext) private var houseModelContext
    @State private var houses: [House] = []

    static let houseStoreChanged = Notification.Name("houseStoreChanged")

    @State private var searchText = ""
    @State private var towerFilter: Int? = nil      // nil = 全部
    @State private var statusFilter: HouseStatus? = .available   // 首页默认显示待租房源
    @State private var layoutFilters: Set<String> = []   // v1.3：户型筛选支持多选，空 = 全部户型
    @State private var showAdd = false

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
    @State private var pendingSyncRecs: [CloudHouseRecord] = []
    @State private var pendingSyncAdded: [(roomNo: String, roomKey: String, mediaNames: [String])] = []
    @State private var pendingSyncUpdated: [(roomNo: String, byUser: String)] = []
    @State private var pendingSyncDeleted: [String] = []
    @State private var pendingSyncPushed: [String] = []
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
                    statsBar
                    searchBar
                    filterBar
                    houseList
                }
            }
            .navigationTitle("房源管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // v1.19：左上角手动同步（与下拉刷新同效果——拉取云端房源）
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await syncCloudHouses() }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isSelecting)
                }
                // v1.7：房源设置已合并进主 App 设置页，左上角设置按钮移除（无独立设置入口）
                ToolbarItem(placement: .topBarTrailing) {
                    if isSelecting {
                        Button("取消") { exitMultiSelect() }
                    } else {
                        HStack(spacing: 14) {
                            // v1.21：多选分享入口
                            Button {
                                isSelecting = true
                            } label: {
                                Image(systemName: "checkmark.circle")
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
            .alert("提示", isPresented: $showInfoAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(infoMessage)
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
        houses = all.filter { !$0.isTrashed }
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip(title: "全部户型", isOn: layoutFilters.isEmpty) {
                        layoutFilters.removeAll()
                    }
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
                .padding(.horizontal, 16)
            }
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
                .refreshable {
                    await syncCloudHouses()
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
        // 云端同步删除（失败写日志 + 二次提示）
        if let config = config, config.isValid {
            Task {
                do {
                    try await CloudBackupService.deleteHouseRemoteFolder(roomKey: roomKey, config: config)
                    // v1.19：同时从云端房源账本移除该房
                    try? await CloudHouseSync.delete(roomKey: roomKey, config: config)
                    BackupLogStore.log(category: "删除房源", action: "云端删除", result: "成功", detail: roomKey, cloud: true)
                } catch {
                    BackupLogStore.log(category: "删除房源", action: "云端删除", result: "失败", detail: "\(roomKey) \(error.localizedDescription)", cloud: true)
                    await MainActor.run {
                        infoMessage = "云端删除失败：\(error.localizedDescription)。可在「管理后台 → 桶管理」手动清理 h/\(roomKey)/"; showInfoAlert = true
                    }
                }
            }
        } else {
            BackupLogStore.log(category: "删除房源", action: "云端删除", result: "跳过", detail: "未配置云存储 \(roomKey)", cloud: true)
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
                BackupLogStore.log(category: "房源", action: "同步云端", result: "成功", detail: house.displayRoomNo, cloud: true)
            } catch {
                BackupLogStore.log(category: "房源", action: "同步云端", result: "失败", detail: "\(house.displayRoomNo)：\(error.localizedDescription)", cloud: true)
            }
        }
    }

    /// v1.41：云端账本与本地房源的字段级对比——任一字段（含媒体清单）不同即视为有变化。
    /// 替代旧的时间戳比较：时间戳只有秒级精度且恢复备份后 lastUpdatedAt 为空，
    /// 会导致「明明没变化每次同步都判更新」。字段级对比满足「一个标点符号变了都要同步」。
    private func cloudRecordDiffers(_ rec: CloudHouseRecord, from house: House) -> Bool {
        if rec.roomNo != house.roomNo { return true }
        if rec.tower != house.tower { return true }
        if rec.landlord != house.landlord { return true }
        if rec.layout != house.layout { return true }
        if rec.price != house.price { return true }
        if rec.password != house.password { return true }
        if rec.remark != house.remark { return true }
        if rec.status != house.statusRaw { return true }
        let localMedia = Set(house.mediaItems.map { $0.fileName })
        if localMedia != Set(rec.mediaNames) { return true }
        return false
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
            var added: [(roomNo: String, roomKey: String, mediaNames: [String])] = []
            var updated: [(roomNo: String, byUser: String)] = []
            var deleted: [String] = []
            var pushed: [String] = []
            var mediaRoomKeys: [String] = []
            await MainActor.run {
                let local = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
                var localByKey: [String: House] = [:]
                for h in local where !h.isTrashed { localByKey[h.mediaRoomKey] = h }
                let cloudKeys = Set(recs.map { $0.roomKey })
                for rec in recs {
                    if let h = localByKey[rec.roomKey] {
                        if cloudRecordDiffers(rec, from: h) {
                            // v1.40 B1：多人冲突提示——云端由他人更新时展示修改者
                            updated.append((rec.roomNo, rec.updatedBy))
                        }
                        // v1.41：媒体差异双向识别（下载缺失 或 本地多余跟随删）
                        let localNames = Set(h.mediaItems.map { $0.fileName })
                        let cloudNames = Set(rec.mediaNames)
                        if localNames != cloudNames {
                            mediaRoomKeys.append(h.mediaRoomKey)
                        }
                    } else {
                        added.append((rec.roomNo, rec.roomKey, rec.mediaNames))
                        if !rec.mediaNames.isEmpty { mediaRoomKeys.append(rec.roomKey) }
                    }
                }
                for (key, h) in localByKey where !cloudKeys.contains(key) {
                    if h.cloudStatus == .both || h.cloudStatus == .cloud {
                        deleted.append(key)
                    } else {
                        pushed.append(key)
                    }
                }
            }
            let hasChange = !added.isEmpty || !updated.isEmpty || !deleted.isEmpty || !pushed.isEmpty || !mediaRoomKeys.isEmpty
            guard hasChange else {
                infoMessage = "已刷新，无变化"; showInfoAlert = true
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
            BackupLogStore.log(category: "同步", action: "同步云端房源", result: "失败", detail: error.localizedDescription, cloud: true)
        }
    }

    /// v1.40 第11点：确认弹窗里的变化详情
    private func syncChangeSummary() -> String {
        var parts: [String] = []
        if !pendingSyncAdded.isEmpty { parts.append("新增\(pendingSyncAdded.count)套：\(pendingSyncAdded.map { $0.roomNo }.prefix(8).joined(separator: "，"))") }
        if !pendingSyncUpdated.isEmpty {
            let upd = pendingSyncUpdated.prefix(8).map { "\($0.roomNo)（\($0.byUser.isEmpty ? "他人" : $0.byUser)改）" }.joined(separator: "，")
            parts.append("更新\(pendingSyncUpdated.count)套：\(upd)")
        }
        if !pendingSyncDeleted.isEmpty { parts.append("云端已删\(pendingSyncDeleted.count)套，本地跟随删除") }
        if !pendingSyncPushed.isEmpty { parts.append("本地新增\(pendingSyncPushed.count)套将补传云端") }
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
            var mediaRoomKeys: [String] = []
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
                        }
                        // v1.41：媒体差异双向 reconcile——
                        //  ① 云端有本地缺 → 下载（mediaRoomKeys）
                        //  ② 本地记录有、云端账本已无 → 跟随删除（文件 + 记录；即别的设备删了照片，这里跟着删）
                        let localNames = Set(h.mediaItems.map { $0.fileName })
                        let cloudNames = Set(rec.mediaNames)
                        if localNames != cloudNames {
                            if !cloudNames.isSubset(of: localNames) {
                                mediaRoomKeys.append(h.mediaRoomKey)
                            }
                            for extra in localNames.subtracting(cloudNames) {
                                MediaStore.delete(fileName: extra, roomKey: h.mediaRoomKey)
                                if let item = h.mediaItems.first(where: { $0.fileName == extra }) {
                                    ctx.delete(item)
                                }
                                HouseMediaUploadQueue.remove(roomKey: h.mediaRoomKey, fileName: extra)
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
                        addedRoomNo.append(rec.roomNo)
                        if !rec.mediaNames.isEmpty { mediaRoomKeys.append(h.mediaRoomKey) }
                    }
                }
                for (key, h) in localByKey where !cloudKeys.contains(key) {
                    if h.cloudStatus == .both || h.cloudStatus == .cloud {
                        MediaStore.deleteHouseDirectory(roomKey: key)
                        ctx.delete(h)
                        deletedCount += 1
                    } else {
                        pushHouseToCloud(h)
                        pushedCount += 1
                    }
                }
                try? ctx.save()
                reloadHouses()
            }
            var mediaSaved = 0
            if !mediaRoomKeys.isEmpty {
                for roomKey in mediaRoomKeys {
                    let files = (try? await CosUploader.downloadHouseMedia(roomKey: roomKey, config: config)) ?? []
                    mediaSaved += files.count
                    await MainActor.run {
                        let all = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
                        if let h = all.first(where: { $0.mediaRoomKey == roomKey && !$0.isTrashed }) {
                            for f in files {
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
            var parts: [String] = []
            if addedCount > 0 { parts.append("新增\(addedCount)套") }
            if updatedCount > 0 { parts.append("更新\(updatedCount)套") }
            if deletedCount > 0 { parts.append("删除\(deletedCount)套") }
            if pushedCount > 0 { parts.append("补传\(pushedCount)套") }
            if mediaSaved > 0 { parts.append("下载媒体\(mediaSaved)个") }
            if removedMediaCount > 0 { parts.append("删除媒体\(removedMediaCount)个") }
            var msg = "已同步：\(parts.joined(separator: "，"))"
            if addedCount > 0 {
                msg += "\n新增房号：\(addedRoomNo.joined(separator: "，"))"
            }
            infoMessage = msg; showInfoAlert = true
            BackupLogStore.log(category: "同步", action: "同步云端房源", result: "成功", detail: msg, cloud: true)
        } catch {
            infoMessage = "同步失败：\(error.localizedDescription)"; showInfoAlert = true
            BackupLogStore.log(category: "同步", action: "同步云端房源", result: "失败", detail: error.localizedDescription, cloud: true)
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
        // 云端同步删除（失败写日志）
        if let config = config, config.isValid {
            for roomKey in deletedKeys {
                Task {
                    do {
                        try await CloudBackupService.deleteHouseRemoteFolder(roomKey: roomKey, config: config)
                        // v1.19：同时从云端房源账本移除该房
                        try? await CloudHouseSync.delete(roomKey: roomKey, config: config)
                        BackupLogStore.log(category: "删除房源", action: "云端删除", result: "成功", detail: roomKey, cloud: true)
                    } catch {
                        BackupLogStore.log(category: "删除房源", action: "云端删除", result: "失败", detail: "\(roomKey) \(error.localizedDescription)", cloud: true)
                    }
                }
            }
        } else {
            BackupLogStore.log(category: "删除房源", action: "云端删除", result: "跳过", detail: "未配置云存储 共\(deletedKeys.count)套", cloud: true)
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
