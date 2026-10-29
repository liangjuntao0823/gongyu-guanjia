import SwiftUI

// MARK: - v1.82 远程配置原生化（中文显示 + 排版优化）
/// 读取：云函数 act=configGet（带口令）→ 未配置/为空时用默认模板填充
/// 保存：POST act=configSave（自动 version+1）→ 云端生效 + 写本地缓存（断网兜底）
/// 所有配置项显示中文名称（英文 key 以小字副标题展示，便于对照后台文档）
struct RemoteConfigAdminView: View {
    @State private var config = RemoteConfig.Payload()
    @State private var loading = false
    @State private var saving = false
    @State private var statusText = ""
    @State private var loaded = false

    // 更新日志新增条目
    @State private var newCLVersion = ""
    @State private var newCLDate = ""
    @State private var newCLChanges = ""

    /// v1.89：AI 模型清单（JSON 文本编辑）
    @State private var aiModelsJSON = ""

    var body: some View {
        Form {
            // ── 顶部：状态 + 操作 ──
            Section {
                HStack {
                    Label("配置版本", systemImage: "number")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(config.version > 0 ? "v\(config.version)" : "未加载")
                        .fontWeight(.semibold)
                }
                if let ua = config.updatedAt, !ua.isEmpty {
                    HStack {
                        Label("更新时间", systemImage: "clock")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(ua)
                    }
                }
                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(statusText.contains("失败") || statusText.contains("无效") ? .red : .green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 12) {
                    Button {
                        loadConfig()
                    } label: {
                        Label(loading ? "加载中…" : "从云端加载", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(loading || saving)
                    Button {
                        saveConfig()
                    } label: {
                        Label(saving ? "保存中…" : "保存到云端", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading || saving)
                }
            } header: {
                Label("远程配置中心", systemImage: "gearshape.2")
            } footer: {
                Text("保存后立即写入云端，App 下次启动 / 同步自动生效；断网时 App 使用本地缓存，不受影响。")
            }

            // ── 基础设置 ──
            Section {
                Toggle("显示公告横幅", isOn: Binding(get: {
                    config.announcement?.enabled ?? false
                }, set: { v in
                    var a = config.announcement ?? RemoteConfig.Announcement(enabled: false, text: "", link: nil)
                    a.enabled = v
                    config.announcement = a
                }))
                .tint(.green)
                if config.announcement?.enabled == true {
                    LabeledContent {
                        TextField("公告文字", text: Binding(get: {
                            config.announcement?.text ?? ""
                        }, set: { v in
                            var a = config.announcement ?? RemoteConfig.Announcement(enabled: false, text: "", link: nil)
                            a.text = v
                            config.announcement = a
                        }), axis: .vertical)
                        .lineLimit(1...3)
                        .multilineTextAlignment(.trailing)
                    } label: {
                        Text("公告文字").foregroundStyle(.secondary)
                    }
                    LabeledContent {
                        TextField("选填，点击可跳转", text: Binding(get: {
                            config.announcement?.link ?? ""
                        }, set: { v in
                            var a = config.announcement ?? RemoteConfig.Announcement(enabled: false, text: "", link: nil)
                            a.link = v.isEmpty ? nil : v
                            config.announcement = a
                        }))
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .multilineTextAlignment(.trailing)
                    } label: {
                        Text("公告链接").foregroundStyle(.secondary)
                    }
                }
                LabeledContent {
                    TextField("如 1.79", text: Binding(get: {
                        config.minimumVersion ?? ""
                    }, set: { config.minimumVersion = $0.isEmpty ? nil : $0 }))
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                } label: {
                    Text("最低版本").foregroundStyle(.secondary)
                }
            } header: {
                Label("基础设置", systemImage: "slider.horizontal.3")
            }

            // ── 功能开关 ──
            Section {
                ForEach(config.features.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(Self.label(key), isOn: Binding(get: {
                            config.features[key] ?? false
                        }, set: { config.features[key] = $0 }))
                        .tint(.green)
                        if Self.label(key) != key {
                            Text(key).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Label("功能开关", systemImage: "switch.2")
            }

            // ── 数值参数 ──
            Section {
                ForEach(config.params.keys.sorted(), id: \.self) { key in
                    LabeledContent {
                        TextField("", text: Binding(get: {
                            let v = config.params[key] ?? 0
                            return v == v.rounded() ? String(Int(v)) : String(v)
                        }, set: { t in
                            config.params[key] = Double(t) ?? (config.params[key] ?? 0)
                        }))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.label(key))
                            if Self.label(key) != key {
                                Text(key).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } header: {
                Label("数值参数", systemImage: "number.circle")
            }

            // ── 提示文案 ──
            Section {
                ForEach(config.tips.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(Self.label(key)).font(.subheadline).fontWeight(.medium)
                            if Self.label(key) != key {
                                Text(key).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        TextField("提示内容", text: Binding(get: {
                            config.tips[key] ?? ""
                        }, set: { config.tips[key] = $0 }), axis: .vertical)
                            .lineLimit(1...3)
                            .font(.footnote)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            } header: {
                Label("提示文案（App 内各处提示语）", systemImage: "text.bubble")
            }

            // ── 帮助说明 ──
            Section {
                ForEach(config.helpTexts.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(Self.label(key)).font(.subheadline).fontWeight(.medium)
                            if Self.label(key) != key {
                                Text(key).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        TextField("帮助内容", text: Binding(get: {
                            config.helpTexts[key] ?? ""
                        }, set: { config.helpTexts[key] = $0 }), axis: .vertical)
                            .lineLimit(1...5)
                            .font(.footnote)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            } header: {
                Label("帮助说明（设置页长文案）", systemImage: "questionmark.circle")
            }

            // ── AI 模型清单（v1.89）──
            Section {
                TextEditor(text: $aiModelsJSON)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                Text("格式：[{\"modelID\":\"doubao-…\",\"name\":\"模型名\",\"desc\":\"说明\"}]；保存时自动校验，非法 JSON 不生效")
                    .font(.caption2).foregroundStyle(.secondary)
            } header: {
                Label("AI 模型清单（设置页模型下拉扩展）", systemImage: "brain")
            } footer: {
                Text("App 内置默认 3 个模型；这里追加账号下已开通的其他模型，App 设置页会自动合并显示并附说明。")
            }

            // ── 版本更新记录 ──
            Section {
                let list = Binding<[RemoteConfig.ChangelogEntry]>(
                    get: { config.changelog ?? [] },
                    set: { config.changelog = $0 }
                )
                ForEach(list.wrappedValue) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.version)\(entry.date.map { " · \($0)" } ?? "")")
                            .font(.footnote).fontWeight(.semibold)
                        ForEach(entry.changes, id: \.self) { c in
                            Text("· \(c)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    var arr = list.wrappedValue
                    arr.remove(atOffsets: offsets)
                    config.changelog = arr
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("新增一条（添加到顶部）").font(.footnote).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("版本号", text: $newCLVersion)
                            .textFieldStyle(.roundedBorder)
                        TextField("日期（可选）", text: $newCLDate)
                            .textFieldStyle(.roundedBorder)
                    }
                    TextField("改动内容，每行一条", text: $newCLChanges, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    Button("添加到日志") { addChangelog() }
                        .buttonStyle(.borderedProminent)
                        .disabled(newCLVersion.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.vertical, 2)
            } header: {
                Label("版本更新记录（App 设置页展示）", systemImage: "list.bullet.clipboard")
            } footer: {
                Text("左滑条目可删除。新增条目会显示在 App 设置页的版本记录顶部。")
            }

            // ── 底部保存 ──
            Section {
                Button {
                    saveConfig()
                } label: {
                    Label(saving ? "保存中…" : "保存全部配置到云端", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading || saving)
            }
        }
        .navigationTitle("远程配置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !loaded { loadConfig() }
        }
    }

    // MARK: 加载

    private func loadConfig() {
        loading = true
        statusText = ""
        let u = (CloudUser.username).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(CloudConfig.functionURL)?act=configGet&k=\(CloudConfig.passwordHash)&u=\(u)") else {
            loading = false
            statusText = "云函数地址无效，请先在「设置 → 云端配置」填写"
            return
        }
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            DispatchQueue.main.async {
                loading = false
                guard let data = data,
                      let obj = try? JSONDecoder().decode(ConfigGetResponse.self, from: data),
                      obj.ok else {
                    statusText = "加载失败：无法连接云函数，请检查网络与地址"
                    return
                }
                if let fetched = obj.config {
                    config = fetched
                    if let list = fetched.aiModels, let data = try? JSONEncoder().encode(list) {
                        aiModelsJSON = String(data: data, encoding: .utf8) ?? ""
                    } else {
                        aiModelsJSON = ""
                    }
                } else {
                    config = Self.defaultTemplate()
                    aiModelsJSON = ""
                }
                loaded = true
                statusText = "已加载云端配置 v\(config.version)"
            }
        }.resume()
    }

    // MARK: 保存

    private func saveConfig() {
        saving = true
        statusText = ""
        // v1.89：解析 AI 模型清单（非法 JSON 则忽略并提示，不阻断其他配置保存）
        let trimmed = aiModelsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            config.aiModels = nil
        } else if let data = trimmed.data(using: .utf8),
                  let list = try? JSONDecoder().decode([RemoteConfig.AIModelInfo].self, from: data) {
            config.aiModels = list
        } else {
            saving = false
            statusText = "AI 模型清单 JSON 格式无效，请检查后重试"
            return
        }
        config.version = (config.version > 0 ? config.version : 0) + 1
        var body = config
        body.updatedBy = CloudUser.username
        let u = (CloudUser.username).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(CloudConfig.functionURL)?act=configSave&k=\(CloudConfig.passwordHash)&u=\(u)"),
              let payload = try? JSONEncoder().encode(body) else {
            saving = false
            statusText = "保存失败：参数无效"
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                saving = false
                guard let data = data,
                      let obj = try? JSONDecoder().decode(ConfigSaveResponse.self, from: data),
                      obj.ok else {
                    statusText = "保存失败：云函数未确认（请检查网络与口令）"
                    return
                }
                RemoteConfig.apply(body)
                statusText = "已保存 ✓ 配置版本 v\(obj.version ?? body.version)，App 下次启动/同步即生效"
            }
        }.resume()
    }

    private func addChangelog() {
        let version = newCLVersion.trimmingCharacters(in: .whitespaces)
        guard !version.isEmpty else { return }
        let date = newCLDate.trimmingCharacters(in: .whitespaces)
        let changes = newCLChanges.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var list = config.changelog ?? []
        list.insert(RemoteConfig.ChangelogEntry(version: version, date: date.isEmpty ? nil : date, changes: changes), at: 0)
        config.changelog = list
        newCLVersion = ""
        newCLDate = ""
        newCLChanges = ""
    }

    // MARK: 配置项中文名（英文 key → 中文显示）

    private static func label(_ key: String) -> String {
        LABELS[key] ?? key
    }

    private static let LABELS: [String: String] = [
        // 功能开关
        "compressUpload": "上传压缩",
        "watermark": "分享水印",
        "autoBackup": "自动备份",
        "showOfflineRestore": "离线重建入口",
        "showRoomsShare": "选房分享入口",
        // 数值参数
        "autoBackupKeepDays": "自动备份保留天数（天）",
        "roomsLinkExpiryDays": "选房链接有效期（天）",
        "videoCompressHeight": "视频压缩高度（px）",
        "imageCompressQuality": "图片压缩质量（0-1）",
        "syncRetryCount": "同步失败重试次数",
        // 提示文案
        "refreshDone": "刷新完成提示",
        "refreshNoChange": "刷新无变化提示",
        "refreshFail": "刷新失败提示",
        "syncFail": "同步失败提示",
        "noCloudConfig": "未配置云端提示",
        "containerUnavailable": "数据容器不可用提示",
        "deletingCloud": "删除云端中提示",
        "bulkDeleteDone": "批量删除完成提示",
        "cloudCopyDeleted": "云端副本已删除提示",
        "cloudDeleteFail": "云端删除失败提示",
        "bulkRentDone": "批量已租完成提示",
        "backfillFail": "补传云端失败提示",
        "quickBackupOk": "快速备份成功提示",
        "quickBackupFail": "快速备份失败提示",
        "fullBackupOk": "全量备份成功提示",
        "fullBackupFail": "全量备份失败提示",
        "fullBackupSpace": "全量备份空间不足提示",
        "fullBackupRunning": "全量备份进行中提示",
        "offlineRestoreOk": "离线重建完成提示",
        "noLocalLedger": "无本地账本提示",
        "noPreviewRooms": "无可预览房源提示",
        "billPreviewFail": "账单预览失败提示",
        // 帮助说明
        "houseShareFooter": "云端配置与名片说明",
        "backupIntro": "备份体系说明",
        "autoBackupIntro": "自动备份说明",
        "cloudSetupIntro": "云端配置说明",
        "passwordIntro": "后台口令说明",
        "multiShareIntro": "多用户共享说明",
        "clearConfigWarn": "清空配置警告",
        "tencentTutorial": "腾讯云部署教程",
        "backupConfigFile": "备份配置文件说明"
    ]

    // MARK: 默认模板（与云端后台 CFG_DEFAULT 同源，云端未配置时保证全部可编辑）

    private static func defaultTemplate() -> RemoteConfig.Payload {
        var p = RemoteConfig.Payload()
        p.version = 1
        p.announcement = RemoteConfig.Announcement(enabled: false, text: "", link: nil)
        p.minimumVersion = ""
        p.features = [
            "compressUpload": true,
            "watermark": true,
            "autoBackup": true,
            "showOfflineRestore": true,
            "showRoomsShare": true
        ]
        p.params = [
            "autoBackupKeepDays": 7,
            "roomsLinkExpiryDays": 2,
            "videoCompressHeight": 720,
            "imageCompressQuality": 0.85,
            "syncRetryCount": 1
        ]
        p.tips = [
            "refreshDone": "已刷新",
            "refreshNoChange": "已刷新，无变化",
            "refreshFail": "刷新失败，请检查网络",
            "syncFail": "同步失败：{error}",
            "noCloudConfig": "未配置云存储，无法同步云端房源",
            "containerUnavailable": "数据容器不可用，无法删除",
            "deletingCloud": "已删除本地房源，正在同步删除云端…",
            "bulkDeleteDone": "已彻底删除 {changed} 套本地房源（共选中 {total} 套）；云端同步删除中…",
            "cloudCopyDeleted": "已删除云端同步副本",
            "cloudDeleteFail": "云端删除失败：{error}。可在「设置 → 桶管理」手动清理",
            "bulkRentDone": "已将 {changed} 套标记为已租（共选中 {total} 套）",
            "backfillFail": "补传云端失败：{error}。本地房源保持「仅本地」，可稍后重新同步补传",
            "quickBackupOk": "快速备份成功：{file}\n已自动上传云端（若网络失败会在下次打开 App 时自动重试）",
            "quickBackupFail": "快速备份失败，请检查存储空间",
            "fullBackupOk": "全量备份成功：{file}\n可在「查看备份文件」中手动上传到云端",
            "fullBackupFail": "全量备份失败，请检查存储空间",
            "fullBackupSpace": "存储空间不足，全量备份至少需要与照片视频等量的剩余空间",
            "fullBackupRunning": "正在生成全量备份…",
            "offlineRestoreOk": "离线重建完成：已从本地账本恢复 {n} 套房源",
            "noLocalLedger": "未找到本地账本（media 文件夹中没有 info.json）。请先联网同步一次生成账本，或使用「恢复数据」。",
            "noPreviewRooms": "暂无可预览的收租房源，请先在收租板块添加房源并生成收租计划。",
            "billPreviewFail": "账单预览生成失败，请重试。"
        ]
        p.helpTexts = [
            "houseShareFooter": "云端配置：腾讯云 COS 存储桶、密钥、自定义域名与云函数地址（后台网址），用于上传房源图片/视频生成微信分享卡片链接，以及打开云端管理后台；可导出部署包给别的房东自建后台。名片信息：分享 H5 页面和微信卡片上显示的姓名与电话。压缩上传开启后，新增/编辑房源的图片视频上传云端与分享 H5 都会压缩（视频压到 720p、图片轻压缩），上传更快更省流量。房源数据（数据库、图片视频、二维码）默认存放在「公寓管家」文件夹内的「备份」「media」两个子文件夹，长按拷贝/共享即为备份，重装后放回原位即可还原。",
            "backupIntro": "备份数据 = 快速备份（账本 + 媒体清单，不含房源与照片视频，自动上传云端；房源统一从云端同步恢复）或全量备份（额外含全部房源与照片视频）。恢复会覆盖当前数据，恢复前自动打包当前数据做安全备份，失败自动还原。旧版分板块 JSON 备份仍可在「查看备份文件」中恢复，不会丢失。",
            "autoBackupIntro": "自动备份 = 快速备份（账本 + 房源 + 清单），备份成功后自动上传云端；超过保留天数（默认 7 天）的自动备份会自动清理，手动备份不会被删除。若到点 App 未在前台，会等下次打开 App 时自动补做。",
            "cloudSetupIntro": "• 单用户：填好云函数地址 + 桶配置 + 用户名即可，房源/备份自动上传云端，后台看统计与用量。\n• 多用户：几台手机填同一套桶配置、各自填不同用户名，房源云端共享（一台录入另一台下拉同步可见）；名片/水印/统计/备份按用户名隔离，互不读取。\n• 房源板块下拉刷新 / 左上角手动同步都是拉取云端房源到本地，效果一致。",
            "passwordIntro": "网页版管理后台用此口令登录；App 内打开后台免登录。默认口令 12345678，建议修改为不易猜的字符。保存后会自动同步到云函数（云端后台、网页后台同用此口令）。",
            "multiShareIntro": "多台手机填同一个桶配置、各自填用户名，即可共享房源：一台录入，另一台下拉同步就能看到。操作日志/分享/统计会带上您的用户名，其他私有数据（名片/水印/统计/备份）按用户名分开。",
            "clearConfigWarn": "将删除本机保存的存储桶、地域、密钥、自定义域名全部配置，并断开与 COS 的连接。此操作不可撤销，可先用「备份配置到文件」留底。",
            "tencentTutorial": "1. 打开 cloud.tencent.com 注册并实名认证；2. 开通「对象存储 COS」；3. 创建存储桶：名称可自定义、地域按实际选择、访问权限选「私有读写」；4. 在「访问管理 CAM → API 密钥管理」新建密钥，得到 SecretId 和 SecretKey；5. 在「存储桶 → 域名与传输管理 → 自定义源站域名」绑定自己的域名（微信只认自定义域名，才能把链接抓成网页卡片）。注意：桶名和地域必须和您实际创建的存储桶一致，才能连接成功。",
            "backupConfigFile": "点「备份配置到文件」后，备份文件（桶名_地域_日期.json，含密钥）会直接生成到 iOS「文件」App → 我的 iPhone → 公寓管家 → 「备份」文件夹，随整个「备份」文件夹一起备份即可。换机 / 重装 / 误改后，点「从备份文件恢复配置」在列表中选择备份文件（或从其他位置导入）即可一键还原。含密钥内容请勿外泄。"
        ]
        p.changelog = []
        return p
    }
}

// MARK: 云函数响应

private struct ConfigGetResponse: Codable {
    let ok: Bool
    let config: RemoteConfig.Payload?
    let error: String?
}

private struct ConfigSaveResponse: Codable {
    let ok: Bool
    let version: Int?
    let error: String?
}
