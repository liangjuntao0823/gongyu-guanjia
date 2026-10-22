import SwiftUI
import SwiftData

// MARK: - 回收站板块分类（v1.7：顶部标签按板块筛选 + 分区清空）
enum TrashFilter: String, CaseIterable, Identifiable {
    case all, house, deal, property, income, expense, payout, todo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .house: return "房源"
        case .deal: return "成交"
        case .property: return "收租"
        case .income: return "杂项收入"
        case .expense: return "杂项支出"
        case .payout: return "包租"
        case .todo: return "待办"
        }
    }
}

// MARK: - 回收站（软删除记录统一管理）
struct TrashView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    /// v1.7：房源数据在独立 HouseStore 容器，回收站查房源需用专属 context
    @Environment(\.houseModelContext) private var houseModelContext

    @Query(filter: #Predicate<DealRecord> { $0.isDeleted }, sort: \DealRecord.deletedAt, order: .reverse) private var deals: [DealRecord]
    @Query(filter: #Predicate<MiscIncome> { $0.isDeleted }, sort: \MiscIncome.deletedAt, order: .reverse) private var incomes: [MiscIncome]
    @Query(filter: #Predicate<MiscExpense> { $0.isDeleted }, sort: \MiscExpense.deletedAt, order: .reverse) private var expenses: [MiscExpense]
    @Query(filter: #Predicate<Property> { $0.isDeleted }, sort: \Property.deletedAt, order: .reverse) private var properties: [Property]
    @Query(filter: #Predicate<PayoutRecord> { $0.isDeleted }, sort: \PayoutRecord.deletedAt, order: .reverse) private var payouts: [PayoutRecord]
    @Query(filter: #Predicate<TodoItem> { $0.isDeleted }, sort: \TodoItem.deletedAt, order: .reverse) private var todos: [TodoItem]

    /// v1.7：房源软删除记录（独立容器手动拉取，不入 @Query）
    @State private var houses: [House] = []

    @State private var filter: TrashFilter = .all   // v1.7：板块分类筛选
    @State private var isSelecting = false
    @State private var selectedIDs = Set<UUID>()
    @State private var pendingDeleteItem: TrashItem?
    @State private var pendingRestoreItem: TrashItem?
    @State private var showClearAllConfirm = false
    @State private var showBatchDeleteConfirm = false
    @State private var showBatchRestoreConfirm = false

    private var totalCount: Int { deals.count + incomes.count + expenses.count + properties.count + payouts.count + todos.count + houses.count }

    /// 当前筛选口径下的记录数（决定列表与空态）
    private var filteredTotal: Int {
        switch filter {
        case .all: return totalCount
        case .house: return houses.count
        case .deal: return deals.count
        case .property: return properties.count
        case .income: return incomes.count
        case .expense: return expenses.count
        case .payout: return payouts.count
        case .todo: return todos.count
        }
    }

    @ViewBuilder private var mainContent: some View {
        if filteredTotal == 0 { emptyView } else { recordList }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "trash").font(.system(size: 44)).foregroundColor(.themeText3)
            Text(filter == .all ? "回收站是空的" : "「\(filter.title)」暂无记录")
                .font(.system(size: 15)).foregroundColor(.themeText3)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // v1.7：顶部板块分类标签（全部 / 房源 / 成交 / 收租 / 杂项收入 / 杂项支出 / 包租 / 待办）
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TrashFilter.allCases) { item in
                    Button {
                        filter = item
                        if !isSelecting { selectedIDs.removeAll() }
                    } label: {
                        Text(item.title)
                            .font(.footnote.weight(filter == item ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(filter == item ? Color.themeAccent : Color.themePanel)
                            .foregroundColor(filter == item ? .white : .primary)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.themeBorder, lineWidth: filter == item ? 0 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .background(Color.themeBg)
    }

    private var recordList: some View {
        List {
            if (filter == .all || filter == .house) && !houses.isEmpty { houseSection }
            if (filter == .all || filter == .deal) && !deals.isEmpty { dealSection }
            if (filter == .all || filter == .property) && !properties.isEmpty { propertySection }
            if (filter == .all || filter == .income) && !incomes.isEmpty { incomeSection }
            if (filter == .all || filter == .expense) && !expenses.isEmpty { expenseSection }
            if (filter == .all || filter == .payout) && !payouts.isEmpty { payoutSection }
            if (filter == .all || filter == .todo) && !todos.isEmpty { todoSection }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.themeBg)
    }

    // v1.7：房源板块（软删除房源在此还原 / 彻底删除；彻底删除才移除本地照片视频文件）
    private var houseSection: some View {
        Section("房源（\(houses.count)）") {
            ForEach(houses) { item in
                trashRow(title: "\(item.displayRoomNo) · \(item.landlord.isEmpty ? "无房东" : item.landlord)", detail: "租金 \(item.price)元/月", id: item.id, deletedAt: item.deletedAt, onRestore: { restoreHouse(item) }, onDelete: { deleteHouse(item) })
            }
        }
    }

    private var dealSection: some View {
        Section("成交（\(deals.count)）") {
            ForEach(deals) { item in
                trashRow(title: "\(item.roomNumber.isEmpty ? "无房号" : item.roomNumber) · \(item.date.formatted(date: .numeric, time: .omitted))", detail: "中介费 \(Int(item.totalFee))元", id: item.id, deletedAt: item.deletedAt, onRestore: { restore(item) }, onDelete: { delete(item) })
            }
        }
    }

    private var propertySection: some View {
        Section("收租（\(properties.count)）") {
            ForEach(properties) { item in
                trashRow(title: "\(item.roomNumber) · \(item.landlord)", detail: "租金 \(Int(item.rent))元/月", id: item.id, deletedAt: item.deletedAt, onRestore: { restore(item) }, onDelete: { delete(item) })
            }
        }
    }

    private var incomeSection: some View {
        Section("杂项收入（\(incomes.count)）") {
            ForEach(incomes) { item in
                trashRow(title: "\(item.item) · \(item.date.formatted(date: .numeric, time: .omitted))", detail: "收入 \(Int(item.amount))元", id: item.id, deletedAt: item.deletedAt, onRestore: { restore(item) }, onDelete: { delete(item) })
            }
        }
    }

    private var expenseSection: some View {
        Section("杂项支出（\(expenses.count)）") {
            ForEach(expenses) { item in
                trashRow(title: "\(item.item) · \(item.date.formatted(date: .numeric, time: .omitted))", detail: "支出 \(Int(item.amount))元", id: item.id, deletedAt: item.deletedAt, onRestore: { restore(item) }, onDelete: { delete(item) })
            }
        }
    }

    private var payoutSection: some View {
        Section("包租（\(payouts.count)）") {
            ForEach(payouts) { item in
                trashRow(title: "\(item.roomNumber) · \(item.paymentMethod)", detail: "月租 \(Int(item.monthlyRent ?? 0))元", id: item.id, deletedAt: item.deletedAt, onRestore: { restore(item) }, onDelete: { delete(item) })
            }
        }
    }

    private var todoSection: some View {
        Section("待办（\(todos.count)）") {
            ForEach(todos) { item in
                trashRow(title: "\(item.content)", detail: "新增于 \(item.createdDate.formatted(date: .numeric, time: .omitted))", id: item.id, deletedAt: item.deletedAt, onRestore: { restore(item) }, onDelete: { delete(item) })
            }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 14) {
                if totalCount > 0 {
                    Button(isSelecting ? "完成" : "选择") {
                        isSelecting.toggle()
                        if !isSelecting { selectedIDs.removeAll() }
                    }
                    Button {
                        showClearAllConfirm = true
                    } label: {
                        Text("清空").foregroundColor(.red)
                    }
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                mainContent
            }
            .navigationTitle("回收站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear(perform: reloadHouses)
            .onReceive(NotificationCenter.default.publisher(for: HouseListView.houseStoreChanged)) { _ in
                reloadHouses()
            }
            .alert("还原记录", isPresented: Binding(get: { pendingRestoreItem != nil }, set: { if !$0 { pendingRestoreItem = nil } })) {
                Button("取消", role: .cancel) { pendingRestoreItem = nil }
                Button("还原") { if let item = pendingRestoreItem { item.delete() }; pendingRestoreItem = nil }
            } message: { Text("确定将这条记录还原到原板块吗？") }
            .alert("永久删除", isPresented: Binding(get: { pendingDeleteItem != nil }, set: { if !$0 { pendingDeleteItem = nil } })) {
                Button("取消", role: .cancel) { pendingDeleteItem = nil }
                Button("永久删除", role: .destructive) { if let item = pendingDeleteItem { permanentlyDelete(item) }; pendingDeleteItem = nil }
            } message: { Text("永久删除后无法恢复，确定删除这条记录吗？") }
            // v1.7：清空支持「单个板块 / 全部板块」（二次确认）
            .confirmationDialog("清空回收站", isPresented: $showClearAllConfirm, titleVisibility: .visible) {
                Button("清空全部板块", role: .destructive) { clearFilter(.all) }
                Button("只清空房源", role: .destructive) { clearFilter(.house) }
                Button("只清空成交", role: .destructive) { clearFilter(.deal) }
                Button("只清空收租", role: .destructive) { clearFilter(.property) }
                Button("只清空杂项收入", role: .destructive) { clearFilter(.income) }
                Button("只清空杂项支出", role: .destructive) { clearFilter(.expense) }
                Button("只清空包租", role: .destructive) { clearFilter(.payout) }
                Button("只清空待办", role: .destructive) { clearFilter(.todo) }
                Button("取消", role: .cancel) { }
            } message: { Text("将永久删除所选板块回收站里的记录，且无法恢复。确定清空吗？") }
            .alert("批量永久删除", isPresented: $showBatchDeleteConfirm) {
                Button("取消", role: .cancel) { }
                Button("永久删除", role: .destructive) { batchDelete() }
            } message: { Text("将永久删除选中的 \(selectedIDs.count) 条记录，且无法恢复。确定吗？") }
            .alert("批量还原", isPresented: $showBatchRestoreConfirm) {
                Button("取消", role: .cancel) { }
                Button("还原", role: .destructive) { batchRestore() }
            } message: { Text("确定还原选中的 \(selectedIDs.count) 条记录吗？") }
            .safeAreaInset(edge: .bottom) {
                if isSelecting && !selectedIDs.isEmpty {
                    HStack(spacing: 14) {
                        Button {
                            showBatchRestoreConfirm = true
                        } label: {
                            Label("还原(\(selectedIDs.count))", systemImage: "arrow.uturn.backward")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(22)
                        }
                        Button {
                            showBatchDeleteConfirm = true
                        } label: {
                            Label("删除(\(selectedIDs.count))", systemImage: "trash")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(22)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
        }
    }

    // 通用行：单选模式点击高亮并进入详情，多选模式点击切换勾选
    private func trashRow(title: String, detail: String, id: UUID, deletedAt: Date?, onRestore: @escaping () -> Void, onDelete: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            if isSelecting {
                Image(systemName: selectedIDs.contains(id) ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selectedIDs.contains(id) ? .themeAccent : .themeText3)
                    .font(.system(size: 20))
                    .onTapGesture { toggleSelect(id) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 13)).foregroundColor(.themeText3).lineLimit(1)
            }
            Spacer()
            if let deletedAt {
                Text(trashDeletedAtText(deletedAt))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.themeText3)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting { toggleSelect(id) }
        }
        .listRowBackground(Color.themePanel)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.themeBorder, lineWidth: 1))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                if !isSelecting { onDelete() }
            } label: { Label("删除", systemImage: "trash") }
            Button {
                if !isSelecting { pendingRestoreItem = TrashItem(id: id, delete: onRestore) }
            } label: { Label("还原", systemImage: "arrow.uturn.backward") }
            .tint(.green)
        }
    }

    private func trashDeletedAtText(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy年M月d日 HH:mm"; return f.string(from: date)
    }

    private func toggleSelect(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    // MARK: - 房源（独立容器）

    /// 拉取已软删除的房源（按删除时间倒序）
    /// v1.9：同 HouseListView——isDeleted 可选属性在 iOS 17 #Predicate 翻译会崩溃，改全量拉取 + 内存过滤
    private func reloadHouses() {
        guard let ctx = houseModelContext else { return }
        let descriptor = FetchDescriptor<House>(sortBy: [SortDescriptor(\House.deletedAt, order: .reverse)])
        let all = (try? ctx.fetch(descriptor)) ?? []
        houses = all.filter { $0.isTrashed }
    }

    /// 还原房源：解除软删除标记，照片视频仍在本地
    private func restoreHouse(_ item: House) {
        guard let ctx = houseModelContext else { return }
        item.isDeleted = false
        item.deletedAt = nil
        try? ctx.save()
        reloadHouses()
        NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
    }

    /// 彻底删除房源：先移除本地全部文件（整个房号目录 + 分享缓存），再删模型记录；
    /// v1.13 需求19：同步删除桶里 h/<roomKey>/ 下的房源文件夹（未配置云端/桶里没有则静默跳过，不阻塞本地删除）
    private func deleteHousePermanently(_ item: House) {
        guard let ctx = houseModelContext else { return }
        MediaStore.deleteHouseDirectory(roomKey: item.mediaRoomKey)
        ctx.delete(item)
        try? ctx.save()
        reloadHouses()
        NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
        let roomKey = item.mediaRoomKey
        Task { await CloudBackupService.deleteHouseRemoteFolder(roomKey: roomKey, config: nil) }
    }

    private func deleteHouse(_ item: House) {
        pendingDeleteItem = TrashItem(id: item.id, delete: { deleteHousePermanently(item) })
    }

    // MARK: - 操作

    private func restore(_ item: DealRecord) { item.isDeleted = false; item.deletedAt = nil; save() }
    private func restore(_ item: MiscIncome) { item.isDeleted = false; item.deletedAt = nil; save() }
    private func restore(_ item: MiscExpense) { item.isDeleted = false; item.deletedAt = nil; save() }
    private func restore(_ item: Property) { item.isDeleted = false; item.deletedAt = nil; save() }
    private func restore(_ item: PayoutRecord) { item.isDeleted = false; item.deletedAt = nil; save() }
    private func restore(_ item: TodoItem) { item.isDeleted = false; item.deletedAt = nil; save() }

    private func delete(_ item: DealRecord) { pendingDeleteItem = TrashItem(id: item.id, delete: { modelContext.delete(item); save() }) }
    private func delete(_ item: MiscIncome) { pendingDeleteItem = TrashItem(id: item.id, delete: { modelContext.delete(item); save() }) }
    private func delete(_ item: MiscExpense) { pendingDeleteItem = TrashItem(id: item.id, delete: { modelContext.delete(item); save() }) }
    private func delete(_ item: Property) { pendingDeleteItem = TrashItem(id: item.id, delete: { modelContext.delete(item); save() }) }
    private func delete(_ item: PayoutRecord) { pendingDeleteItem = TrashItem(id: item.id, delete: { modelContext.delete(item); save() }) }
    private func delete(_ item: TodoItem) { pendingDeleteItem = TrashItem(id: item.id, delete: { modelContext.delete(item); save() }) }

    private func permanentlyDelete(_ item: TrashItem) { item.delete() }

    /// v1.7：按板块清空（全部 / 房源 / 成交 / 收租 / 杂项收入 / 杂项支出 / 包租 / 待办）
    private func clearFilter(_ type: TrashFilter) {
        switch type {
        case .house:
            clearHouses()
        case .deal:
            deals.forEach { modelContext.delete($0) }
            save()
        case .property:
            properties.forEach { modelContext.delete($0) }
            save()
        case .income:
            incomes.forEach { modelContext.delete($0) }
            save()
        case .expense:
            expenses.forEach { modelContext.delete($0) }
            save()
        case .payout:
            payouts.forEach { modelContext.delete($0) }
            save()
        case .todo:
            todos.forEach { modelContext.delete($0) }
            save()
        case .all:
            clearAll()
        }
        isSelecting = false
        selectedIDs.removeAll()
    }

    private func clearHouses() {
        guard let ctx = houseModelContext else { return }
        let roomKeys = houses.map { $0.mediaRoomKey }
        for item in houses {
            MediaStore.deleteHouseDirectory(roomKey: item.mediaRoomKey)
            ctx.delete(item)
        }
        try? ctx.save()
        reloadHouses()
        NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
        // v1.13 需求19：同步删除桶里各房源文件夹
        for roomKey in roomKeys {
            Task { await CloudBackupService.deleteHouseRemoteFolder(roomKey: roomKey, config: nil) }
        }
    }

    private func clearAll() {
        deals.forEach { modelContext.delete($0) }
        incomes.forEach { modelContext.delete($0) }
        expenses.forEach { modelContext.delete($0) }
        properties.forEach { modelContext.delete($0) }
        payouts.forEach { modelContext.delete($0) }
        todos.forEach { modelContext.delete($0) }
        save()
        clearHouses()
        isSelecting = false
        selectedIDs.removeAll()
    }

    private func batchDelete() {
        deals.filter { selectedIDs.contains($0.id) }.forEach { modelContext.delete($0) }
        incomes.filter { selectedIDs.contains($0.id) }.forEach { modelContext.delete($0) }
        expenses.filter { selectedIDs.contains($0.id) }.forEach { modelContext.delete($0) }
        properties.filter { selectedIDs.contains($0.id) }.forEach { modelContext.delete($0) }
        payouts.filter { selectedIDs.contains($0.id) }.forEach { modelContext.delete($0) }
        todos.filter { selectedIDs.contains($0.id) }.forEach { modelContext.delete($0) }
        save()
        // 房源批量永久删除：同时移除本地文件
        let houseTargets = houses.filter { selectedIDs.contains($0.id) }
        if !houseTargets.isEmpty, let ctx = houseModelContext {
            for item in houseTargets {
                MediaStore.deleteHouseDirectory(roomKey: item.mediaRoomKey)
                ctx.delete(item)
            }
            try? ctx.save()
            reloadHouses()
            NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
            // v1.13 需求19：同步删除桶里各房源文件夹
            for item in houseTargets {
                let roomKey = item.mediaRoomKey
                Task { await CloudBackupService.deleteHouseRemoteFolder(roomKey: roomKey, config: nil) }
            }
        }
        selectedIDs.removeAll()
    }

    private func batchRestore() {
        deals.filter { selectedIDs.contains($0.id) }.forEach { $0.isDeleted = false; $0.deletedAt = nil }
        incomes.filter { selectedIDs.contains($0.id) }.forEach { $0.isDeleted = false; $0.deletedAt = nil }
        expenses.filter { selectedIDs.contains($0.id) }.forEach { $0.isDeleted = false; $0.deletedAt = nil }
        properties.filter { selectedIDs.contains($0.id) }.forEach { $0.isDeleted = false; $0.deletedAt = nil }
        payouts.filter { selectedIDs.contains($0.id) }.forEach { $0.isDeleted = false; $0.deletedAt = nil }
        todos.filter { selectedIDs.contains($0.id) }.forEach { $0.isDeleted = false; $0.deletedAt = nil }
        save()
        // 房源批量还原
        let houseTargets = houses.filter { selectedIDs.contains($0.id) }
        if !houseTargets.isEmpty, let ctx = houseModelContext {
            for item in houseTargets {
                item.isDeleted = false
                item.deletedAt = nil
            }
            try? ctx.save()
            reloadHouses()
            NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
        }
        selectedIDs.removeAll()
    }

    private func save() { try? modelContext.save() }
}

// 用于统一触发"确认永久删除"的轻量包装
private struct TrashItem {
    let id: UUID
    let delete: () -> Void
}
