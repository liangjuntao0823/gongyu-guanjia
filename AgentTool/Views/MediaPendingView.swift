import SwiftUI

/// v1.66：后补任务集中页——显示所有待补传媒体（上传失败入队 / 云端媒体对账补传失败保留的）。
/// 一键全部重试；本地文件已删的条目可左滑清除队列，避免永久悬挂。
struct MediaPendingView: View {
    @State private var items: [HouseMediaUploadQueue.Item] = []
    @State private var isRetrying = false
    @State private var showResult = false
    @State private var resultText = ""
    // v1.68：进行中的同步/补传任务（房源页最小化后在这里随时查看进度）
    @ObservedObject private var syncCenter = SyncTaskCenter.shared

    var body: some View {
        List {
            if let t = syncCenter.task {
                Section("进行中的同步任务") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(t.title, systemImage: "arrow.triangle.2.circlepath")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if t.isRunning {
                                Text("进行中").font(.caption).foregroundColor(.blue)
                            } else {
                                Text(t.success ? "已完成" : "部分失败")
                                    .font(.caption)
                                    .foregroundColor(t.success ? .green : .orange)
                            }
                        }
                        ProgressView(value: t.fraction)
                        HStack {
                            if t.isRunning {
                                Text("\(t.done)/\(t.total) 个媒体 · 正在处理 \(t.current)")
                                    .font(.caption2).foregroundColor(.secondary)
                            } else {
                                Text("共 \(t.total) 个媒体").font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("\(Int(t.fraction * 100))%")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Text("参与套房：\(t.roomKeys.joined(separator: "、"))")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            if items.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 40))
                                .foregroundColor(.green)
                            Text("没有待补传任务")
                                .font(.headline)
                            Text("上传失败的媒体会自动入队，在这里集中查看和重试")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 30)
                }
            } else {
                Section {
                    HStack {
                        Text("待补传 \(items.count) 个媒体 · \(roomsCount) 套房")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Spacer()
                        if isRetrying { ProgressView() }
                    }
                }
                Section {
                    ForEach(items, id: \.self) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.kind == "video" ? "video" : "photo")
                                .foregroundColor(item.kind == "video" ? .purple : .blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.roomKey)
                                    .font(.subheadline.weight(.semibold))
                                Text(item.fileName)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("待补传")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    .onDelete(perform: deleteItems)
                } footer: {
                    Text("左滑可清除单条（本地文件已删除时不会自动清除，请手动清理）。")
                }
            }
        }
        .navigationTitle("待补传媒体")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !items.isEmpty {
                    Button {
                        retryAll()
                    } label: {
                        if isRetrying {
                            ProgressView()
                        } else {
                            Label("全部重试", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isRetrying)
                }
            }
        }
        .alert("补传结果", isPresented: $showResult) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resultText)
        }
        .onAppear {
            reload()
        }
    }

    private var roomsCount: Int {
        Set(items.map { $0.roomKey }).count
    }

    private func reload() {
        items = HouseMediaUploadQueue.pendingItems()
    }

    private func deleteItems(at offsets: IndexSet) {
        for idx in offsets {
            let item = items[idx]
            HouseMediaUploadQueue.remove(roomKey: item.roomKey, fileName: item.fileName)
        }
        reload()
    }

    private func retryAll() {
        isRetrying = true
        Task {
            await HouseMediaUploadQueue.retryAll()
            await MainActor.run {
                reload()
                isRetrying = false
                resultText = items.isEmpty ? "全部补传完成" : "完成部分补传，剩余 \(items.count) 个保留待重试"
                showResult = true
            }
        }
    }
}
