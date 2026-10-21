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

    // v1.22：首页多选分享——一次选多套，生成【一个合集分享卡片】（好友点开链接即可查看全部 N 套），
    // 不再逐套生成链接逐次弹微信，避免 App 与微信来回跳转
    @State private var isSelecting = false
    @State private var selectedHouseIDs = Set<UUID>()
    @State private var showShareModePicker = false
    @State private var shareQueue: [URL] = []
    @State private var shareIndex = 0
    @State private var currentShareStep: ShareStep? = nil
    @State private var isGenerating = false
    @State private var generateTip = ""
    @State private var shareError: String?

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
            .navigationTitle("房源管家")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        HouseSettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
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
                            Button {
                                showAdd = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.body.weight(.semibold))
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                HouseEditView(house: nil)
            }
            // v1.22：多选分享——选「脱敏 / 完整」后生成一个合集卡片链接
            .confirmationDialog("选择分享方式", isPresented: $showShareModePicker, titleVisibility: .visible) {
                Button("发给客户（隐藏版）") { generateShareQueue(mode: .masked) }
                Button("发给同事（完整版）") { generateShareQueue(mode: .full) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("已选 \(selectedHouseIDs.count) 套，将生成一个合集分享卡片：好友点开链接即可查看全部房源，每套单独一页（含实拍图/视频）。隐藏版不显示房号/价格/房东，完整版显示全部信息。")
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
                            ProgressView()
                                .tint(.white)
                            Text(generateTip)
                                .font(.footnote)
                                .foregroundColor(.white)
                        }
                        .padding(20)
                        .background(Color.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .alert("无法分享", isPresented: Binding(
                get: { shareError != nil },
                set: { if !$0 { shareError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(shareError ?? "")
            }
        }
        .onAppear {
            reloadHouses()
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.houseStoreChanged)) { _ in
            reloadHouses()
        }
    }

    /// 从独立 HouseStore 配置拉取房源（按创建时间倒序，与原来 @Query 一致）
    private func reloadHouses() {
        guard let ctx = houseModelContext else { return }
        var descriptor = FetchDescriptor<House>(sortBy: [SortDescriptor(\House.createdAt, order: .reverse)])
        houses = (try? ctx.fetch(descriptor)) ?? []
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
                ScrollView {
                    LazyVStack(spacing: 10) {
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
                            } else {
                                NavigationLink {
                                    HouseDetailView(house: house)
                                } label: {
                                    HouseCardView(house: house)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, isSelecting ? 76 : 20)
                }
            }
        }
        // v1.21：多选模式底部操作栏
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
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
                    Button {
                        startMultiShare()
                    } label: {
                        Text("分享（\(selectedHouseIDs.count)）")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.primary)
                    .disabled(selectedHouseIDs.isEmpty)
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

    private func startMultiShare() {
        guard !selectedHouseIDs.isEmpty else { return }
        guard let config = CosConfig.load(), config.isValid else {
            shareError = "请先点击左上角「设置」，填写云存储配置（腾讯云 COS）并保存验证，再分享卡片链接"
            return
        }
        // 过滤出有素材的房源（无照片视频的无法生成卡片）
        let shareable = houses.filter { selectedHouseIDs.contains($0.id) && !$0.mediaItems.isEmpty }
        guard !shareable.isEmpty else {
            shareError = "选中的房源都没有照片或视频，先编辑添加素材再分享"
            return
        }
        showShareModePicker = true
    }

    /// v1.22：生成【合集分享卡片】（一次选 N 套 → 一个链接 → 好友点开看全部），生成后弹一次系统分享面板
    /// 注意：值类型（ShareCollectionItem）在主线程构建完成，Task 内只传递值，绝不直接访问 SwiftData @Model（跨线程读取模型会闪退）
    private func generateShareQueue(mode: ShareMode) {
        guard let config = CosConfig.load(), config.isValid else {
            shareError = "请先点击左上角「设置」，填写云存储配置（腾讯云 COS）并保存验证，再分享卡片链接"
            return
        }
        let shareable = houses.filter { selectedHouseIDs.contains($0.id) && !$0.mediaItems.isEmpty }
        guard !shareable.isEmpty else {
            shareError = "选中的房源都没有照片或视频，先编辑添加素材再分享"
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

        Task {
            do {
                let url = try await CosUploader.shareCollection(rooms: rooms, mode: mode, config: config)
                await MainActor.run {
                    isGenerating = false
                    shareQueue = [url]
                    shareIndex = 0
                    currentShareStep = ShareStep(url: url)
                }
            } catch {
                await MainActor.run {
                    isGenerating = false
                    shareError = error.localizedDescription
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
