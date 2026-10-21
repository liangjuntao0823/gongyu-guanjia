import SwiftUI
import SwiftData

struct TodoFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let item: TodoItem?
    let readOnly: Bool
    @State private var date: Date
    @State private var content: String
    @State private var reminderEnabled: Bool
    @State private var reminderDate: Date
    @State private var restoreConfirm = false

    init(item: TodoItem? = nil, readOnly: Bool = false) {
        self.item = item; self.readOnly = readOnly
        _date = State(initialValue: item?.createdDate ?? Date())
        _content = State(initialValue: item?.content ?? "")
        _reminderEnabled = State(initialValue: item?.reminderDate != nil)
        _reminderDate = State(initialValue: item?.reminderDate ?? Date().addingTimeInterval(3600))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("待办信息") {
                    if readOnly {
                        LabeledContent("新增时间", value: date.formatted(date: .numeric, time: .omitted))
                    } else {
                        WheelDateField(label: "新增时间", date: $date)
                    }
                    TextField("待办内容", text: $content, axis: .vertical)
                        .lineLimit(3...6).disabled(readOnly)
                    if !readOnly {
                        Toggle("设置提醒", isOn: $reminderEnabled).tint(.themeAccent)
                        if reminderEnabled { WheelDateTimeField(label: "提醒时间", date: $reminderDate) }
                    } else if let reminder = item?.reminderDate {
                        LabeledContent("提醒时间", value: reminder.formatted(date: .numeric, time: .shortened))
                    }
                    if readOnly, let completed = item?.completedDate {
                        LabeledContent("办理日期", value: completed.formatted(date: .numeric, time: .omitted))
                    }
                }
            }
            .navigationTitle(readOnly ? "待办预览" : (item == nil ? "新增待办" : "编辑待办"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if readOnly {
                        Button("恢复未办理") { restoreConfirm = true }
                    } else {
                        Button("保存", action: save).disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .alert("恢复未办理？", isPresented: $restoreConfirm) {
                Button("取消", role: .cancel) { }
                Button("确认恢复") {
                    item?.isCompleted = false; item?.completedDate = nil
                    try? modelContext.save()
        LocalNotificationManager.shared.rebuildAll(modelContext: modelContext)
        dismiss()
                }
            } message: { Text("该事项将回到未办列表。") }
        }
    }

    private func save() {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let item { item.content = text; item.createdDate = date; item.reminderDate = reminderEnabled ? reminderDate : nil }
        else {
            let items = (try? modelContext.fetch(FetchDescriptor<TodoItem>(predicate: #Predicate { !$0.isDeleted }))) ?? []
            modelContext.insert(TodoItem(content: text, createdDate: date, sortOrder: (items.map(\.sortOrder).min() ?? 0) - 1, reminderDate: reminderEnabled ? reminderDate : nil))
        }
        try? modelContext.save()
        LocalNotificationManager.shared.rebuildAll(modelContext: modelContext)
        dismiss()
    }
}

struct AllTodosView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<TodoItem> { !$0.isDeleted }, sort: [SortDescriptor(\TodoItem.createdDate, order: .reverse), SortDescriptor(\TodoItem.sortOrder)]) private var todos: [TodoItem]
    @State private var selectedStatus = 0
    @State private var searchText = ""
    @State private var editingItem: TodoItem?
    @State private var previewItem: TodoItem?
    @State private var completingItem: TodoItem?
    @State private var deletingItem: TodoItem?

    private var visibleItems: [TodoItem] {
        let filtered = todos.filter { $0.isCompleted == (selectedStatus == 1) && (searchText.isEmpty || $0.content.localizedCaseInsensitiveContains(searchText)) }
        if selectedStatus == 1 {
            // 已办结：默认按完成日期降序（无完成日期则按新增日期）
            return filtered.sorted { ($0.completedDate ?? $0.createdDate) > ($1.completedDate ?? $1.createdDate) }
        }
        // 未办：按手动拖动排序
        return filtered.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.themeText3)
                TextField("搜索待办内容", text: $searchText)
                if !searchText.isEmpty { Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") } }
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(Color.themePanel).cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.themeBorder)).padding(.horizontal)
            .padding(.top, 8)
            Picker("状态", selection: $selectedStatus) { Text("未办").tag(0); Text("已办").tag(1) }
                .pickerStyle(.segmented).padding(.horizontal)
            List {
                ForEach(visibleItems) { item in
                    TodoRow(item: item, showComplete: !item.isCompleted) { completingItem = item }
                        .contentShape(Rectangle())
                        .onTapGesture { item.isCompleted ? (previewItem = item) : (editingItem = item) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { deletingItem = item } label: { Label("删除", systemImage: "trash") }
                            if !item.isCompleted { Button { editingItem = item } label: { Label("编辑", systemImage: "pencil") }.tint(.blue) }
                        }
                }
                .onMove { source, destination in if selectedStatus == 0 && searchText.isEmpty { movePending(from: source, to: destination) } }
            }.listStyle(.plain)
        }
        .navigationTitle("全部待办").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
        .sheet(item: $editingItem) { TodoFormView(item: $0) }
        .sheet(item: $previewItem) { TodoFormView(item: $0, readOnly: true) }
        .alert("确认已办？", isPresented: Binding(get: { completingItem != nil }, set: { if !$0 { completingItem = nil } })) {
            Button("取消", role: .cancel) { completingItem = nil }
            Button("确认") { completingItem?.isCompleted = true; completingItem?.completedDate = Date(); try? modelContext.save(); LocalNotificationManager.shared.rebuildAll(modelContext: modelContext); completingItem = nil }
        }
        .alert("确认删除？", isPresented: Binding(get: { deletingItem != nil }, set: { if !$0 { deletingItem = nil } })) {
            Button("取消", role: .cancel) { deletingItem = nil }
            Button("确定删除", role: .destructive) { if let item = deletingItem { item.isDeleted = true; item.deletedAt = Date(); try? modelContext.save(); LocalNotificationManager.shared.rebuildAll(modelContext: modelContext) }; deletingItem = nil }
        } message: { Text("删除后可在回收站找回。") }
    }

    private func movePending(from source: IndexSet, to destination: Int) {
        var ordered = visibleItems; ordered.move(fromOffsets: source, toOffset: destination)
        for (index, item) in ordered.enumerated() { item.sortOrder = index }; try? modelContext.save()
    }
}

struct TodoRow: View {
    let item: TodoItem; let showComplete: Bool; let onComplete: () -> Void
    private func text(_ date: Date?) -> String { guard let date else { return "" }; let f = DateFormatter(); f.dateFormat = "yyyy.M.d"; return f.string(from: date) }
    var body: some View {
        HStack(spacing: 12) {
            if item.reminderDate != nil && !item.isCompleted {
                GlowDot(color: .themeAmber, size: 9)
                    .frame(width: 12)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.content).font(.system(size: 15, weight: .semibold)).foregroundColor(.themeText)
                Text(text(item.createdDate)).font(.system(size: 14, weight: .medium)).foregroundColor(.themeText3)
            }
            Spacer()
            if showComplete {
                Button("已办", action: onComplete).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7).background(Color.themeAccent).clipShape(Capsule()).buttonStyle(.plain)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("已办结").font(.system(size: 16, weight: .bold)).foregroundColor(.themeAccentDark)
                    Text(text(item.completedDate)).font(.system(size: 15, weight: .semibold)).foregroundColor(.themeText3)
                }
            }
        }.padding(.vertical, 4)
    }
}
