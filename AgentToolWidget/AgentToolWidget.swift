//
//  AgentToolWidget.swift
//  AgentToolWidget
//
//  租房管家 · 桌面小组件（中号 systemMedium）+ 锁屏小组件
//

import WidgetKit
import SwiftUI

// MARK: - App Group 常量
let appGroupID = "group.com.gj.tg.shared"

// MARK: - 小组件数据模型
struct WidgetData {
    var todoCount: Int
    var uncollected: Int
    var expiring: Int
    var dealCount: Int
    var netIncome: Double
    var payoutRoom: String
    var payoutDate: String
    var payoutAmount: Double
    var monthRemain: Double

    static func load() -> WidgetData {
        let df = UserDefaults(suiteName: appGroupID)
        // 兜底一律为 0/占位符：App 从未写入时不显示示例数据，避免误导
        return WidgetData(
            todoCount:   df?.object(forKey: "todoCount")      as? Int ?? 0,
            uncollected: df?.object(forKey: "uncollectedCount") as? Int ?? 0,
            expiring:    df?.object(forKey: "expiringCount")   as? Int ?? 0,
            dealCount:   df?.object(forKey: "dealCount")      as? Int ?? 0,
            netIncome:   df?.double(forKey: "netIncome") ?? 0,
            payoutRoom:  df?.string(forKey: "payoutRoom")     ?? "—",
            payoutDate:  df?.string(forKey: "payoutDate")     ?? "--/--",
            payoutAmount: df?.double(forKey: "payoutAmount") ?? 0,
            monthRemain: df?.double(forKey: "monthRemainPercent") ?? 0
        )
    }

    static func money(_ n: Double) -> String {
        if n >= 10000 {
            let v = n / 10000
            return String(format: "%.2f", v).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
                + "万"
        }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: n)) ?? "0"
    }
}

// MARK: - 时间线 Provider
struct Provider: TimelineProvider {
    typealias Entry = SimpleEntry

    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), data: WidgetData.load())
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        completion(SimpleEntry(date: Date(), data: WidgetData.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        let entry = SimpleEntry(date: Date(), data: WidgetData.load())
        let next = Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let data: WidgetData
}

// MARK: - 配色（强调色保留，文字全部用系统语义色自动适配明暗）
enum WTheme {
    static let green   = Color(red: 0.06, green: 0.66, blue: 0.52)
    static let purple  = Color(red: 0.52, green: 0.44, blue: 0.92)
    static let cardBg  = Color.primary.opacity(0.08)
}

// MARK: - 桌面中号小组件
struct MediumWidgetView: View {
    let entry: SimpleEntry
    var d: WidgetData { entry.data }

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            HStack(spacing: 6) {
                statBlock(title: "待办",   value: "\(d.todoCount)",   unit: "条", tint: WTheme.green)
                statBlock(title: "未收租", value: "\(d.uncollected)", unit: "间", tint: .primary)
                statBlock(title: "到期",   value: "\(d.expiring)",   unit: "套", tint: WTheme.purple)
                statBlock(title: "成交",   value: "\(d.dealCount)",  unit: "单", tint: .primary)
                statBlock(title: "净收入", value: WidgetData.money(d.netIncome), unit: "", tint: WTheme.green)
            }

            HStack(spacing: 6) {
                Circle().fill(WTheme.purple).frame(width: 6, height: 6)
                Text("包租 \(d.payoutRoom) \(d.payoutDate) 应付")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Text(WidgetData.money(d.payoutAmount))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(WTheme.purple.opacity(0.18))
            .cornerRadius(9)

            VStack(spacing: 5) {
                HStack {
                    Text("本月进度").font(.system(size: 10)).foregroundColor(.secondary)
                    Spacer()
                    Text("剩 \(Int(d.monthRemain))%")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.primary)
                }
                ProgressView(value: (100 - d.monthRemain) / 100)
                    .tint(WTheme.green)
            }
        }
        .padding(14)
        .containerBackground(.ultraThinMaterial, for: .widget)
    }

    @ViewBuilder
    private func statBlock(title: String, value: String, unit: String, tint: Color) -> some View {
        VStack(spacing: 1) {
            Text(title).font(.system(size: 10)).foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value).font(.system(size: 16, weight: .bold)).foregroundColor(tint)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(WTheme.cardBg)
        .cornerRadius(10)
    }
}

// MARK: - 锁屏小组件
struct LockCircular: View {
    let entry: SimpleEntry
    var d: WidgetData { entry.data }
    var body: some View {
        VStack {
            Text("\(d.todoCount)").font(.system(size: 18, weight: .bold))
            Text("待办").font(.system(size: 9))
        }
        .widgetAccentable()
    }
}

struct LockRectangular: View {
    let entry: SimpleEntry
    var d: WidgetData { entry.data }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("待办 \(d.todoCount) · 未收 \(d.uncollected) · 到期 \(d.expiring)")
                .font(.system(size: 12, weight: .semibold))
            Text("包租 \(d.payoutRoom) \(d.payoutDate) \(WidgetData.money(d.payoutAmount))")
                .font(.system(size: 11))
                .widgetAccentable()
        }
    }
}

struct LockInline: View {
    let entry: SimpleEntry
    var d: WidgetData { entry.data }
    var body: some View {
        Label("待办 \(d.todoCount) · 未收租 \(d.uncollected)", systemImage: "house.fill")
    }
}

// MARK: - Widget 入口
struct AgentToolWidget: Widget {
    let kind = "AgentToolWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            MediumWidgetView(entry: entry)
        }
        .configurationDisplayName("租房管家")
        .description("看板速览与收租提醒")
        .supportedFamilies([.systemMedium])
    }
}

struct LockWidget: Widget {
    let kind = "AgentToolLock"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            LockCircular(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("租房管家 · 锁屏")
        .description("锁屏待办速览")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct AgentToolWidgetBundle: WidgetBundle {
    var body: some Widget {
        AgentToolWidget()
        LockWidget()
    }
}
