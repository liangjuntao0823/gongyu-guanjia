import SwiftUI

// MARK: - v1.81 远程配置原生化：App 内管理后台第 4 个 tab
/// 读取：云函数 act=configGet（带口令）→ 未配置/为空时用默认模板填充
/// 保存：POST act=configSave（自动 version+1）→ 云端生效 + 写本地缓存（断网兜底）
/// 与云端网页后台（admin.html「远程配置」页）完全同源，免跳浏览器、免下载文件
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

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("配置版本").foregroundStyle(.secondary)
                    Spacer()
                    Text(config.version > 0 ? "\(config.version)" : "未加载")
                }
                if let ua = config.updatedAt, !ua.isEmpty {
                    HStack {
                        Text("更新时间").foregroundStyle(.secondary)
                        Spacer()
                        Text(ua)
                    }
                }
                Button {
                    loadConfig()
                } label: {
                    Label(loading ? "加载中…" : "从云端加载", systemImage: "arrow.down.circle")
                }
                .disabled(loading || saving)
                Button {
                    saveConfig()
                } label: {
                    Label(saving ? "保存中…" : "保存到云端", systemImage: "checkmark.circle")
                }
                .disabled(loading || saving)
                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(statusText.contains("失败") ? .red : .secondary)
                }
            } header: {
                Text("远程配置中心")
            } footer: {
                Text("保存后立即写入云端，App 下次启动 / 同步自动生效；断网时 App 使用本地缓存，不受影响。")
            }

            Section("公告横幅") {
                Toggle("显示公告", isOn: Binding(get: {
                    config.announcement?.enabled ?? false
                }, set: { v in
                    var a = config.announcement ?? RemoteConfig.Announcement(enabled: false, text: "", link: nil)
                    a.enabled = v
                    config.announcement = a
                }))
                TextField("公告文字", text: Binding(get: {
                    config.announcement?.text ?? ""
                }, set: { v in
                    var a = config.announcement ?? RemoteConfig.Announcement(enabled: false, text: "", link: nil)
                    a.text = v
                    config.announcement = a
                }))
                TextField("公告链接（可选）", text: Binding(get: {
                    config.announcement?.link ?? ""
                }, set: { v in
                    var a = config.announcement ?? RemoteConfig.Announcement(enabled: false, text: "", link: nil)
                    a.link = v.isEmpty ? nil : v
                    config.announcement = a
                }))
                .keyboardType(.URL)
                .autocapitalization(.none)
            }

            Section("最低版本") {
                TextField("如 1.79，低于此版本提示升级", text: Binding(get: {
                    config.minimumVersion ?? ""
                }, set: { config.minimumVersion = $0.isEmpty ? nil : $0 }))
                    .keyboardType(.numbersAndPunctuation)
            }

            Section("功能开关") {
                ForEach(config.features.keys.sorted(), id: \.self) { key in
                    Toggle(key, isOn: Binding(get: {
                        config.features[key] ?? false
                    }, set: { config.features[key] = $0 }))
                }
            }

            Section("参数") {
                ForEach(config.params.keys.sorted(), id: \.self) { key in
                    HStack {
                        Text(key)
                        Spacer()
                        TextField("数值", text: Binding(get: {
                            let v = config.params[key] ?? 0
                            return v == v.rounded() ? String(Int(v)) : String(v)
                        }, set: { t in
                            config.params[key] = Double(t) ?? (config.params[key] ?? 0)
                        }))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                    }
                }
            }

            Section("提示文案") {
                ForEach(config.tips.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(key).font(.footnote).foregroundStyle(.secondary)
                        TextField("提示内容", text: Binding(get: {
                            config.tips[key] ?? ""
                        }, set: { config.tips[key] = $0 }), axis: .vertical)
                            .lineLimit(1...3)
                    }
                }
            }

            Section("帮助文本") {
                ForEach(config.helpTexts.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(key).font(.footnote).foregroundStyle(.secondary)
                        TextField("帮助内容", text: Binding(get: {
                            config.helpTexts[key] ?? ""
                        }, set: { config.helpTexts[key] = $0 }), axis: .vertical)
                            .lineLimit(1...4)
                    }
                }
            }

            Section("更新日志") {
                ForEach(config.changelog ?? []) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.version)\(entry.date.map { " · \($0)" } ?? "")")
                            .font(.footnote).fontWeight(.semibold)
                        ForEach(entry.changes, id: \.self) { c in
                            Text("· \(c)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("新增一条（添加到顶部）").font(.footnote).foregroundStyle(.secondary)
                    TextField("版本号", text: $newCLVersion)
                    TextField("日期（可选）", text: $newCLDate)
                    TextField("改动内容，每行一条", text: $newCLChanges, axis: .vertical)
                        .lineLimit(1...4)
                    Button("添加到日志") { addChangelog() }
                        .disabled(newCLVersion.trimmingCharacters(in: .whitespaces).isEmpty)
                }
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
                } else {
                    // 云端未创建配置：用内置默认模板填充，保证全部可编辑
                    config = Self.defaultTemplate()
                }
                loaded = true
                statusText = "已加载（云端配置版本 \(config.version)）"
            }
        }.resume()
    }

    // MARK: 保存

    private func saveConfig() {
        saving = true
        statusText = ""
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
                // 云端确认：同步更新本地缓存（断网兜底）
                RemoteConfig.apply(body)
                statusText = "已保存 ✓ 配置版本 \(obj.version ?? body.version)，App 下次启动/同步即生效"
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
