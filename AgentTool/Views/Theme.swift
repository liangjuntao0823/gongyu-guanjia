import SwiftUI

// MARK: - 主题配色（参考房源管理软件深绿色主题）
extension Color {
    static let themeSidebar = Color(hex: "143B34")
    static let themeSidebarDark = Color(hex: "0E2B26")
    static let themeAccent = Color(hex: "0FA48B")
    static let themeAccentDark = Color(hex: "0B7A66")
    static let themeAccentWeak = Color(hex: "E2F4EF")
    /// v1.8：页面背景统一为 iOS 系统分组灰（#F2F2F7，与设置页 Form 默认背景一致），
    /// 各功能板块不再用偏绿的 #F4F6F3，观感更接近系统原生设置页
    static let themeBg = Color(hex: "F2F2F7")
    static let themePanel = Color.white
    static let themeText = Color(hex: "1C2D29")
    static let themeText2 = Color(hex: "5F716C")
    static let themeText3 = Color(hex: "97A49F")
    static let themeBorder = Color(hex: "E3EAE6")
    static let themeBlue = Color(hex: "3E7BFA")
    static let themeAmber = Color(hex: "E09A2F")
    static let themeRed = Color(hex: "DF5555")
}

// MARK: - DateFormatter 单例缓存（避免重复创建，提升性能）
final class DateFormatters {
    static let shared = DateFormatters()
    
    private var cache: [String: DateFormatter] = [:]
    private let queue = DispatchQueue(label: "com.agenttool.dateformatters")
    
    func formatter(_ format: String) -> DateFormatter {
        queue.sync {
            if let existing = cache[format] {
                return existing
            }
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "zh_CN")
            cache[format] = formatter
            return formatter
        }
    }
    
    // 常用格式快捷访问
    var dotDate: DateFormatter { formatter("yyyy.M.d") }
    var dashDate: DateFormatter { formatter("yyyy-MM-dd") }
    var chineseDate: DateFormatter { formatter("yyyy年M月d日") }
    var backupDateTime: DateFormatter { formatter("yyyy.M.d-H.mm") }
}

// 让 Color? 也能使用 .themeXxx 静态成员（foregroundColor 等接受 Color? 的 API）
extension Optional where Wrapped == Color {
    static var themeSidebar: Color? { Color.themeSidebar }
    static var themeSidebarDark: Color? { Color.themeSidebarDark }
    static var themeAccent: Color? { Color.themeAccent }
    static var themeAccentDark: Color? { Color.themeAccentDark }
    static var themeAccentWeak: Color? { Color.themeAccentWeak }
    static var themeBg: Color? { Color.themeBg }
    static var themePanel: Color? { Color.themePanel }
    static var themeText: Color? { Color.themeText }
    static var themeText2: Color? { Color.themeText2 }
    static var themeText3: Color? { Color.themeText3 }
    static var themeBorder: Color? { Color.themeBorder }
    static var themeBlue: Color? { Color.themeBlue }
    static var themeAmber: Color? { Color.themeAmber }
    static var themeRed: Color? { Color.themeRed }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

// MARK: - 详情表单行样式：右侧数据黑色加粗（替代默认灰色）
struct DetailLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabeledContent {
            configuration.content
                .fontWeight(.semibold)
                .foregroundColor(.black)
        } label: {
            configuration.label
        }
    }
}

// MARK: - 表单左右布局文本行（标签在左、输入框在右，与金额行一致）
struct TextRow: View {
    let label: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var width: CGFloat = 170

    var body: some View {
        HStack {
            Text(label).foregroundColor(.themeText)
            Spacer()
            TextField("请输入", text: $text)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .foregroundColor(.themeText)
                .frame(width: width)
        }
    }
}

// MARK: - 通用组件
struct GlowDot: View {
    var color: Color = .themeAccent
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.6), radius: 6)
    }
}

struct SectionTitle: View {
    let title: String
    var subtitle: String = ""

    var body: some View {
        HStack(spacing: 8) {
            GlowDot()
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.themeText)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.themeText3)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

struct StatusTag: View {
    let text: String
    var style: TagStyle = .renting

    enum TagStyle {
        case renting, vacant, repair, paid, unpaid, ok, expired, warn, managed

        var bgColor: Color {
            switch self {
            case .renting, .paid, .ok: return Color.themeAccentWeak
            case .vacant: return Color(hex: "E8EFFE")
            case .repair, .warn: return Color(hex: "FBF1DE")
            case .unpaid: return Color(hex: "FDF0F0")
            case .expired: return Color(hex: "F0F2F1")
            case .managed: return Color(hex: "F0E8FE")
            }
        }

        var textColor: Color {
            switch self {
            case .renting, .paid, .ok: return Color.themeAccentDark
            case .vacant: return Color(hex: "2F5FD0")
            case .repair, .warn: return Color(hex: "B97A1B")
            case .unpaid: return Color.themeRed
            case .expired: return Color.themeText2
            case .managed: return Color(hex: "6B3FA0")
            }
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(style.textColor)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(style.bgColor)
        .foregroundColor(style.textColor)
        .clipShape(Capsule())
    }
}

struct ThemeCard<Content: View>: View {
    let content: Content
    var padding: CGFloat = 16

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(Color.themePanel)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.themeBorder, lineWidth: 1)
            )
            .shadow(color: Color.themeSidebar.opacity(0.05), radius: 2, x: 0, y: 1)
            .shadow(color: Color.themeSidebar.opacity(0.07), radius: 14, x: 0, y: 5)
    }
}

struct PrimaryButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.themeAccent)
            .cornerRadius(10)
            .shadow(color: Color.themeAccent.opacity(0.3), radius: 6, x: 0, y: 2)
        }
    }
}

struct GhostButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
            }
            .foregroundColor(.themeText)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.themePanel)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.themeBorder, lineWidth: 1)
            )
        }
    }
}

// MARK: - 轮盘式日期选择器
struct WheelDateField: View {
    let label: String
    @Binding var date: Date
    @State private var showPicker = false

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.themeText2)
            Button {
                showPicker = true
            } label: {
                HStack {
                    Text(dateString)
                        .font(.system(size: 15))
                        .foregroundColor(.themeText)
                    Spacer()
                    Image(systemName: "calendar")
                        .foregroundColor(.themeText3)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Color.themeBg)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.themeBorder, lineWidth: 1))
            }
        }
        .sheet(isPresented: $showPicker) {
            WheelDatePickerSheet(date: $date, isPresented: $showPicker)
                .presentationDetents([.height(360)])
                .presentationDragIndicator(.visible)
        }
    }
}

struct WheelDatePickerSheet: View {
    @Binding var date: Date
    @Binding var isPresented: Bool
    @State private var tempDate: Date

    init(date: Binding<Date>, isPresented: Binding<Bool>) {
        _date = date
        _isPresented = isPresented
        _tempDate = State(initialValue: date.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            VStack {
                DatePicker("", selection: $tempDate, displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "zh_CN"))
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.themeBg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { isPresented = false }
                        .foregroundColor(.themeText2)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        date = tempDate
                        isPresented = false
                    }
                    .foregroundColor(.themeAccent)
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - 轮盘式年月选择器（用于筛选）
struct WheelYearMonthPicker: View {
    @Binding var year: Int?
    @Binding var month: Int?
    @State private var showPicker = false
    @State private var tempYear: Int = Calendar.current.component(.year, from: Date())
    @State private var tempMonth: Int = Calendar.current.component(.month, from: Date())

    private let years = Array(2024...2035)
    private let months = Array(1...12)

    private var displayText: String {
        if year == nil && month == nil { return "全部时间" }
        if let y = year, let m = month { return "\(y)年\(m)月" }
        if let y = year { return "\(y)年" }
        if let m = month { return "\(m)月" }
        return "全部时间"
    }

    var body: some View {
        Button {
            tempYear = year ?? Calendar.current.component(.year, from: Date())
            tempMonth = month ?? Calendar.current.component(.month, from: Date())
            showPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 12))
                Text(displayText)
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
            }
            .foregroundColor(.themeAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.themeAccentWeak)
            .cornerRadius(8)
        }
        .sheet(isPresented: $showPicker) {
            NavigationStack {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Picker("年份", selection: $tempYear) {
                            Text("全部年").tag(0)
                            ForEach(years, id: \.self) { y in
                                Text("\(y)年").tag(y)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)

                        Picker("月份", selection: $tempMonth) {
                            Text("全部月").tag(0)
                            ForEach(months, id: \.self) { m in
                                Text("\(m)月").tag(m)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal)

                    Spacer()
                }
                .background(Color.themeBg)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("取消") { showPicker = false }
                            .foregroundColor(.themeText2)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("确定") {
                            year = tempYear == 0 ? nil : tempYear
                            month = tempMonth == 0 ? nil : tempMonth
                            showPicker = false
                        }
                        .foregroundColor(.themeAccent)
                        .fontWeight(.semibold)
                    }
                }
            }
            .presentationDetents([.height(360)])
        }
    }
}

// MARK: - 轮盘式年月选择器（非Optional，用于首次交租年月）
struct WheelYearMonthField: View {
    let label: String
    @Binding var year: Int
    @Binding var month: Int
    @State private var showPicker = false
    @State private var tempYear: Int = 2026
    @State private var tempMonth: Int = 1

    private let years = Array(2024...2035)
    private let months = Array(1...12)

    private var displayText: String {
        "\(year)年\(month)月"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.themeText2)
            Button {
                tempYear = year
                tempMonth = month
                showPicker = true
            } label: {
                HStack {
                    Text(displayText)
                        .font(.system(size: 15))
                        .foregroundColor(.themeText)
                    Spacer()
                    Image(systemName: "calendar")
                        .foregroundColor(.themeText3)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Color.themeBg)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.themeBorder, lineWidth: 1))
            }
        }
        .sheet(isPresented: $showPicker) {
            NavigationStack {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Picker("年份", selection: $tempYear) {
                            ForEach(years, id: \.self) { y in
                                Text("\(y)年").tag(y)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)

                        Picker("月份", selection: $tempMonth) {
                            ForEach(months, id: \.self) { m in
                                Text("\(m)月").tag(m)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal)

                    Spacer()
                }
                .background(Color.themeBg)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("取消") { showPicker = false }
                            .foregroundColor(.themeText2)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("确定") {
                            year = tempYear
                            month = tempMonth
                            showPicker = false
                        }
                        .foregroundColor(.themeAccent)
                        .fontWeight(.semibold)
                    }
                }
            }
            .presentationDetents([.height(320)])
        }
    }
}

// MARK: - HTML Excel 生成（解决CSV保存后格式乱问题）
func makeExcelHTML(title: String, headers: [String], rows: [[String]]) -> String {
    var html = """
    <html xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:x="urn:schemas-microsoft-com:office:excel" xmlns="http://www.w3.org/TR/REC-html40">
    <head>
    <meta charset="UTF-8">
    <style>
    table { border-collapse: collapse; }
    td, th { border: 1px solid #999; padding: 4px 8px; font-family: Arial; font-size: 12px; mso-number-format:'\\@'; white-space: nowrap; }
    th { background-color: #143B34; color: white; font-weight: bold; }
    tr:nth-child(even) td { background-color: #F5F7F5; }
    </style>
    </head>
    <body>
    <table>
    """
    html += "<tr>" + headers.map { "<th>\($0)</th>" }.joined() + "</tr>\n"
    for row in rows {
        html += "<tr>" + row.map { "<td>\($0)</td>" }.joined() + "</tr>\n"
    }
    html += "</table></body></html>"
    return html
}

// MARK: - 全局文件选择器（直接通过UIWindow弹出，避免sheet包装问题）
private class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    let onPick: (URL) -> Void
    init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first { onPick(url) }
    }
}

private var currentPickerDelegate: DocumentPickerDelegate?

func presentDocumentPicker(onPick: @escaping (URL) -> Void) {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = scene.windows.first(where: { $0.isKeyWindow }),
          let rootVC = window.rootViewController else { return }

    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
    picker.allowsMultipleSelection = false
    let delegate = DocumentPickerDelegate(onPick: onPick)
    currentPickerDelegate = delegate
    picker.delegate = delegate
    rootVC.present(picker, animated: true)
}

// MARK: - 自定义椭圆形滑动操作行
struct SwipeActionItem: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
}

struct SwipeActionRow<Content: View>: View {
    let content: Content
    let actions: [SwipeActionItem]
    var contentBackground: Color
    var onTap: (() -> Void)?
    @State private var offset: CGFloat = 0
    @State private var isOpen = false
    @State private var dragStart: CGFloat = 0

    private var actionWidth: CGFloat { CGFloat(actions.count) * 72 + CGFloat(actions.count - 1) * 8 + 32 }

    init(actions: [SwipeActionItem], contentBackground: Color = .themePanel, onTap: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.actions = actions
        self.contentBackground = contentBackground
        self.onTap = onTap
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // 操作按钮层
            HStack(spacing: 8) {
                ForEach(actions) { item in
                    Button(action: {
                        item.action()
                        withAnimation(.spring(response: 0.3)) { offset = 0; isOpen = false }
                    }) {
                        VStack(spacing: 3) {
                            Image(systemName: item.icon)
                                .font(.system(size: 16))
                            Text(item.title)
                                .font(.system(size: 11))
                        }
                        .frame(width: 64)
                        .frame(maxHeight: .infinity)
                        .background(Capsule().fill(item.color))
                        .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .trailing)

            // 内容层
            content
                .background(contentBackground)
                .offset(x: offset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if isOpen {
                                let delta = value.translation.width
                                if delta > 0 {
                                    offset = min(0, -actionWidth + delta)
                                }
                            } else {
                                if value.translation.width < 0 {
                                    offset = max(value.translation.width, -actionWidth)
                                }
                            }
                        }
                        .onEnded { value in
                            if isOpen {
                                if value.translation.width > 40 {
                                    withAnimation(.spring(response: 0.3)) { offset = 0; isOpen = false }
                                } else {
                                    withAnimation(.spring(response: 0.3)) { offset = -actionWidth; isOpen = true }
                                }
                            } else {
                                if value.translation.width < -60 {
                                    withAnimation(.spring(response: 0.3)) { offset = -actionWidth; isOpen = true }
                                } else {
                                    withAnimation(.spring(response: 0.3)) { offset = 0; isOpen = false }
                                }
                            }
                        }
                )
                .onTapGesture {
                    if isOpen {
                        withAnimation(.spring(response: 0.3)) { offset = 0; isOpen = false }
                    } else {
                        // 菜单未展开时放行点击（如跳转详情），由外部 onTap 回调接管
                        onTap?()
                    }
                }
        }
        .clipped()
    }
}

// MARK: - 恢复数据视图
struct RestoreBackupView: View {
    let type: DataBackupManager.BackupType
    var onComplete: ((Bool) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var backupFiles: [URL] = []
    @State private var isRestoring = false
    @State private var restoreMessage = ""
    @State private var showRestoreAlert = false
    @State private var restoreSuccess = false
    @State private var pendingRestoreURL: URL?
    @State private var showRestoreConfirm = false

    private let backupManager = DataBackupManager.shared

    var body: some View {
        NavigationView {
            ZStack {
                Color.themeBg.ignoresSafeArea()
                VStack {
                    if isRestoring {
                        ProgressView(restoreMessage)
                            .padding()
                    } else if backupFiles.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "folder.badge.questionmark")
                                .font(.system(size: 48))
                                .foregroundColor(.themeText3)
                            Text("暂无备份文件")
                                .foregroundColor(.themeText2)
                            Text("请先在设置中导出备份")
                                .font(.system(size: 13))
                                .foregroundColor(.themeText3)
                        }
                        .padding(.top, 80)
                    } else {
                        List {
                            ForEach(backupFiles, id: \.self) { url in
                                Button {
                                    pendingRestoreURL = url
                                    showRestoreConfirm = true
                                } label: {
                                    HStack {
                                        Image(systemName: "doc.text")
                                            .foregroundColor(.themeAccent)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(url.deletingPathExtension().lastPathComponent)
                                                .foregroundColor(.themeText)
                                                .lineLimit(1)
                                            Text(fileDate(url))
                                                .font(.system(size: 12))
                                                .foregroundColor(.themeText3)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.themeText3)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        deleteBackup(url)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle("恢复\(type.rawValue)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(.themeAccent)
                }
            }
            .onAppear { loadBackups() }
            .alert("确认恢复", isPresented: $showRestoreConfirm) {
                Button("取消", role: .cancel) { pendingRestoreURL = nil }
                Button("确认恢复", role: .destructive) {
                    if let url = pendingRestoreURL {
                        restoreFromFile(url)
                    }
                    pendingRestoreURL = nil
                }
            } message: {
                Text("将用所选备份覆盖当前\(type.rawValue)数据，此操作不可撤销。建议先备份当前数据再恢复。")
            }
            .alert(restoreSuccess ? "恢复成功" : "恢复失败", isPresented: $showRestoreAlert) {
                Button("确定") {
                    if restoreSuccess {
                        dismiss()
                        onComplete?(true)
                    }
                }
            } message: {
                Text(restoreMessage)
            }
        }
    }

    private func loadBackups() {
        backupFiles = backupManager.listBackups(in: type)
    }

    private func fileDate(_ url: URL) -> String {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let date = attrs[.modificationDate] as? Date {
            let df = DateFormatter()
            df.locale = Locale(identifier: "zh_CN")
            df.dateFormat = "yyyy-MM-dd HH:mm"
            return df.string(from: date)
        }
        return ""
    }

    private func restoreFromFile(_ url: URL) {
        do {
            let size = try backupManager.backupFileSize(at: url, type: type)
            guard size <= 10 * 1024 * 1024 else {
                throw NSError(domain: "Backup", code: 1, userInfo: [NSLocalizedDescriptionKey: "备份文件过大（超过10MB）"])
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            isRestoring = true
            restoreMessage = "正在恢复数据..."

            let scope: DataBackupManager.ImportScope
            switch type {
            case .deals: scope = .deals
            case .properties: scope = .properties
            case .payouts: scope = .payouts
            case .total: scope = .all
            }

            // 导入管理器会在独立 SwiftData 上下文中后台恢复，完成回调在主线程更新界面。
            backupManager.importAllData(from: data, modelContext: modelContext, scope: scope) { success, message in
                isRestoring = false
                restoreSuccess = success
                restoreMessage = message
                showRestoreAlert = true
            }
        } catch {
            isRestoring = false
            restoreSuccess = false
            restoreMessage = "读取备份失败：\(error.localizedDescription)"
            showRestoreAlert = true
        }
    }

    private func deleteBackup(_ url: URL) {
        if backupManager.deleteBackup(url, type: type) {
            loadBackups()
        } else {
            restoreSuccess = false
            restoreMessage = "删除备份失败，请检查文件权限后重试"
            showRestoreAlert = true
        }
    }
}


struct WheelDateTimeField: View {
    let label: String
    @Binding var date: Date
    @State private var showPicker = false
    private var text: String { let f = DateFormatter(); f.dateFormat = "yyyy年M月d日 HH:mm"; return f.string(from: date) }
    var body: some View {
        Button { showPicker = true } label: {
            HStack { Text(label).foregroundColor(.themeText); Spacer(); Text(text).foregroundColor(.themeText2); Image(systemName: "calendar.badge.clock").foregroundColor(.themeText3) }
        }
        .sheet(isPresented: $showPicker) {
            NavigationStack {
                DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute]).datePickerStyle(.wheel).labelsHidden().environment(\.locale, Locale(identifier: "zh_CN"))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showPicker = false } } }
            }.presentationDetents([.height(380)]).presentationDragIndicator(.visible)
        }
    }
}
