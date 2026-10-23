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
    enum HouseListDialog: Identifiable {
        case multiShare
        case singleShare
        case delete
        case batchDelete
        case shareError(String)
        case batchTip(String)
        var id: String {
            switch self {
            case .multiShare: return "multiShare"
            case .singleShare: return "singleShare"
            case .delete: return "delete"
            case .batchDelete: return "batchDelete"
            case .shareError: return "shareError"
            case .batchTip: return "batchTip"
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

    /// v1.14 需求6：单一确认弹窗标题（按触发源分发）
    private var dialogTitle: String {
        switch activeDialog {
        case .multiShare: return "选择分享方式"
        case .singleShare: return "选择分享方式"
        case .delete: return "删除这套房源？"
        case .batchDelete: return "删除选中的 \(selectedHouseIDs.count) 套房源？"
        case .shareError: return "无法分享"
        case .batchTip: return "批量操作"
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
            // v1.15 需求2：统一用单一 alert 呈现所有确认/提示（iOS 17 多 confirmationDialog/alert 同链会互相覆盖、
            // swipeActions 手势会拦截 confirmationDialog 按钮点击——删除确认因此无反应；alert 无此问题，与成交板块一致）
            .alert(dialogTitle, isPresented: Binding(
                get: { activeDialog != nil },
                set: { if !$0 { activeDialog = nil } }
            ), presenting: activeDialog) { dialog in
                switch dialog {
                case .multiShare:
                    Button("发给客户（隐藏版）") { generateShareQueue(mode: .masked) }
                    Button("发给同事（完整版）") { generateShareQueue(mode: .full) }
                    Button("取消", role: .cancel) {}
                case .singleShare:
                    Button("发给客户（隐藏版）") { generateSingleShare(mode: .masked) }
                    Button("发给同事（完整版）") { generateSingleShare(mode: .full) }
                    Button("取消", role: .cancel) {}
                case .delete:
                    Button("移入回收站", role: .destructive) {
                        if let target = deleteTarget {
                            softDeleteHouse(target)
                        }
                    }
                    Button("取消", role: .cancel) {}
                case .batchDelete:
                    Button("移入回收站", role: .destructive) { batchSoftDelete() }
                    Button("取消", role: .cancel) {}
                case .shareError:
                    Button("好", role: .cancel) {}
                case .batchTip:
                    Button("好", role: .cancel) {}
                }
            } message: { dialog in
                switch dialog {
                case .multiShare:
                    Text("已选 \(selectedHouseIDs.count) 套，将生成一个合集分享卡片：好友点开链接即可查看全部房源，每套单独一页（含实拍图/视频）。隐藏版不显示房号/价格/房东，完整版显示全部信息。")
                case .singleShare:
                    Text("隐藏版只显示户型、位置和您的联系方式；完整版额外显示房号、价格、房东和密码。")
                case .delete:
                    Text("删除后进入「设置 → 回收站」可恢复；照片和视频保留在本地，彻底删除时才会移除。")
                case .batchDelete:
                    Text("删除后进入「设置 → 回收站」可恢复；照片和视频保留在本地，彻底删除时才会移除。")
                case .shareError(let msg):
                    Text(msg)
                case .batchTip(let msg):
                    Text(msg)
                }
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
            // v1.15：shareError / batchResultTip 已并入上方单一 alert（.shareError/.batchTip 分支），不再独立挂载
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
                                        activeDialog = .delete
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
                            activeDialog = .batchDelete
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

    /// v1.7：卡片左滑「删除」→ 软删除进回收站（标记 isDeleted，不删除照片/视频文件）
    private func softDeleteHouse(_ house: House) {
        guard let ctx = houseModelContext else { return }
        house.isDeleted = true
        house.deletedAt = Date()
        try? ctx.save()
        NotificationCenter.default.post(name: Self.houseStoreChanged, object: nil)
    }

    /// v1.11：卡片左滑状态切换按钮——待租→已租、已租→待租，按当前状态动态显示并反向切换。
    /// 默认列表筛选口径为「待租」，切换为已租后该房源从当前列表消失；已租筛选下左滑可一键改回待租。
    private func toggleHouseStatus(_ house: House) {
        guard let ctx = houseModelContext else { return }
        house.status = (house.status == .rented) ? .available : .rented
        try? ctx.save()
        NotificationCenter.default.post(name: Self.houseStoreChanged, object: nil)
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
        activeDialog = .batchTip("已将 \(changed) 套标记为已租（共选中 \(total) 套）")
    }

    /// 批量删除：选中的房源全部软删除进回收站（不删照片/视频文件）
    private func batchSoftDelete() {
        guard !selectedHouseIDs.isEmpty, let ctx = houseModelContext else { return }
        var changed = 0
        for house in houses where selectedHouseIDs.contains(house.id) {
            house.isDeleted = true
            house.deletedAt = Date()
            changed += 1
        }
        try? ctx.save()
        NotificationCenter.default.post(name: Self.houseStoreChanged, object: nil)
        let total = selectedHouseIDs.count
        exitMultiSelect()
        activeDialog = .batchTip("已将 \(changed) 套移入回收站（共选中 \(total) 套）")
    }

    /// v1.7：卡片左滑「分享」→ 单套分享卡片（脱敏 / 完整），生成链接后弹系统分享面板
    /// 注意：Task 内只传值类型，绝不直接访问 SwiftData @Model（跨线程读取模型会闪退）
    private func generateSingleShare(mode: ShareMode) {
        guard let house = singleShareHouse else { return }
        guard let config = CosConfig.load(), config.isValid else {
            activeDialog = .shareError("请先到「设置 → 房源分享 → 远程配置」填写云存储配置（腾讯云 COS）并保存验证，再分享卡片链接")
            return
        }
        guard !house.mediaItems.isEmpty else {
            activeDialog = .shareError("这套房源还没有照片或视频，先编辑添加素材再分享")
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
                    activeDialog = .shareError(error.localizedDescription)
                    singleShareHouse = nil
                }
            }
        }
    }

    private func startMultiShare() {
        guard !selectedHouseIDs.isEmpty else { return }
        guard let config = CosConfig.load(), config.isValid else {
            activeDialog = .shareError("请先到「设置 → 房源分享 → 远程配置」填写云存储配置（腾讯云 COS）并保存验证，再分享卡片链接")
            return
        }
        // 过滤出有素材的房源（无照片视频的无法生成卡片）
        let shareable = houses.filter { selectedHouseIDs.contains($0.id) && !$0.mediaItems.isEmpty }
        guard !shareable.isEmpty else {
            activeDialog = .shareError("选中的房源都没有照片或视频，先编辑添加素材再分享")
            return
        }
        activeDialog = .multiShare    }

    /// v1.22：生成【合集分享卡片】（一次选 N 套 → 一个链接 → 好友点开看全部），生成后弹一次系统分享面板
    /// 注意：值类型（ShareCollectionItem）在主线程构建完成，Task 内只传递值，绝不直接访问 SwiftData @Model（跨线程读取模型会闪退）
    private func generateShareQueue(mode: ShareMode) {
        guard let config = CosConfig.load(), config.isValid else {
            activeDialog = .shareError("请先到「设置 → 房源分享 → 远程配置」填写云存储配置（腾讯云 COS）并保存验证，再分享卡片链接")
            return
        }
        let shareable = houses.filter { selectedHouseIDs.contains($0.id) && !$0.mediaItems.isEmpty }
        guard !shareable.isEmpty else {
            activeDialog = .shareError("选中的房源都没有照片或视频，先编辑添加素材再分享")
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
                    activeDialog = .shareError(error.localizedDescription)
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
