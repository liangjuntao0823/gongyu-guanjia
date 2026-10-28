//
//  MeterManageView.swift
//  公寓管家 · 电表管理
//  一键导入云端绑定 + 手动增删 + 备注房号 + 查询链接查看
//

import SwiftUI

struct MeterManageView: View {
    @EnvironmentObject private var store: MeterStore
    @Environment(\.dismiss) private var dismiss

    @State private var importing = false
    @State private var importText = ""
    @State private var errorText: String?
    @State private var showAdd = false
    @State private var editingUID: MeterEditTarget?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前微信身份")
                        .font(.system(size: 12))
                        .foregroundColor(.themeText3)
                    Text(store.settings.openId.isEmpty ? "未配置查询链接（请在设置中粘贴微信查询链接）" : maskedOpenId)
                        .font(.system(size: 13))
                        .foregroundColor(store.settings.openId.isEmpty ? .red : .themeText)
                }
                .padding(.vertical, 2)
            }

            Section {
                Button {
                    Task { await doImport() }
                } label: {
                    HStack(spacing: 8) {
                        if importing {
                            ProgressView()
                        }
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.themeAccentDark)
                        Text(importing ? "正在拉取绑定…" : "一键导入云端绑定")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.themeText)
                        Spacer()
                        Text("按当前微信身份拉取")
                            .font(.system(size: 11))
                            .foregroundColor(.themeText3)
                    }
                }
                .disabled(importing)
            } header: {
                Text("快速导入")
            } footer: {
                Text("一键拉取当前微信账号下绑定的全部电表用户号并加入清单（已存在的自动跳过）。")
            }

            Section {
                ForEach(store.meters.sorted(by: { $0.uid < $1.uid })) { meter in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meter.uid)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                            if !meter.room.isEmpty {
                                Text(meter.room)
                                    .font(.system(size: 12))
                                    .foregroundColor(.themeText3)
                            }
                        }
                        Spacer()
                        Button("备注") { editingUID = MeterEditTarget(uid: meter.uid) }
                            .font(.system(size: 12))
                            .foregroundColor(.themeAccentDark)
                    }
                }
                .onDelete { indexSet in
                    let sorted = store.meters.sorted(by: { $0.uid < $1.uid })
                    for idx in indexSet where idx < sorted.count {
                        store.remove(uid: sorted[idx].uid)
                    }
                }
            } header: {
                Text("已管理电表（\(store.meters.count)）")
            } footer: {
                Text("左滑可删除；「备注」为该户号绑定房号，列表第一行会显示。")
            }

            Section {
                Button {
                    showAdd = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.themeAccentDark)
                        Text("手动添加电表")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.themeText)
                    }
                }
            }

            if !importText.isEmpty {
                Section {
                    Text(importText)
                        .font(.system(size: 12))
                        .foregroundColor(.themeText3)
                }
            }
        }
        .navigationTitle("电表管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .sheet(isPresented: $showAdd) { MeterAddSheet() }
        .sheet(item: $editingUID) { t in
            MeterRoomNoteSheet(uid: t.uid)
        }
        .alert("提示", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    private var maskedOpenId: String {
        let id = store.settings.openId
        guard id.count > 8 else { return id }
        return String(id.prefix(4)) + "****" + String(id.suffix(4))
    }

    private func currentProvider() -> MeterQuerying {
        switch store.settings.provider {
        case .webView: return MeterWebViewProvider.shared
        default: return MeterQueryService.shared
        }
    }

    private func doImport() async {
        importing = true
        defer { importing = false }
        do {
            let bindings = try await currentProvider().fetchBindings(store: store)
            let before = store.meters.count
            store.importBindings(bindings)
            let added = store.meters.count - before
            importText = "本次新增 \(added) 台，当前共管理 \(store.meters.count) 台电表"
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// 备注房号弹窗
struct MeterRoomNoteSheet: View {
    @EnvironmentObject private var store: MeterStore
    @Environment(\.dismiss) private var dismiss
    let uid: String
    @State private var room = ""

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.themeBorder).frame(width: 40, height: 4).padding(.top, 10)
            Text("备注房号")
                .font(.system(size: 16, weight: .bold))
                .padding(.top, 12)
            VStack(alignment: .leading, spacing: 6) {
                Text("电表 \(uid)")
                    .font(.system(size: 13))
                    .foregroundColor(.themeText3)
                TextField("如 1座2334上（留空=不显示）", text: $room)
                    .padding(12)
                    .background(Color.themeBorder.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .font(.system(size: 16))
            }
            .padding(.top, 14)
            HStack(spacing: 8) {
                Button("取消") { dismiss() }
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.themeBorder.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Button("保存") {
                    store.updateRoom(uid: uid, room: room)
                    dismiss()
                }
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.themeAccentDark)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.top, 16)
            Spacer()
        }
        .padding(.horizontal, 16)
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
        .onAppear {
            room = store.meters.first { $0.uid == uid }?.room ?? ""
        }
    }
}

/// 备注弹窗的 sheet item 包装（String 自身不满足 Identifiable）
struct MeterEditTarget: Identifiable {
    let id = UUID()
    let uid: String
}
