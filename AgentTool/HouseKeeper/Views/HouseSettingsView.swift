import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import Security

// MARK: - v1.34 钥匙串写入修复（独立实现，避免改动 CosUploader.swift 整文件）

/// 旧 KeychainStore.save 的 bug：SecItemDelete 的查询字典里带了 kSecValueData（要写入的新值），
/// 而删除匹配按查询属性匹配——旧条目存的是旧数据，与新值不匹配 → 删不掉旧条目；
/// 随后 SecItemAdd 因同 account 条目已存在返回 errSecDuplicateItem 被当作成功 → 返回 true 但钥匙串仍是旧值
/// （表现为「保存成功退出再进又变回旧地域」，自检时读到 ap-guangzhou 旧值）。
/// 新实现：存在则 SecItemUpdate 更新、不存在则 SecItemAdd 添加，并立即回读比对，值一致才返回 true。
enum KeychainFix {
    private static let service = "com.zfgj.housekeeper"

    @discardableResult
    static func saveVerified(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        // 已存在 → 更新（保留 kSecAttrAccessible 属性不被覆盖）
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return load(key) == value   // 回读验证：值一致才算成功
        }
        if updateStatus != errSecItemNotFound {
            return false   // 权限等错误，明确失败
        }
        // 不存在 → 新增
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
        return load(key) == value   // 回读验证
    }

    /// 删除指定 key 的钥匙串条目（清空配置用）
    static func deleteKey(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func load(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// 设置页（v1.22 重构：归拢成两个入口——远程配置 / 名片信息）
/// 远程配置：腾讯云 COS 存储桶、密钥、自定义域名（用于分享房源卡片链接）
/// 名片信息：分享 H5 页面与微信卡片上显示的姓名/电话（默认：梁涛 / 13288251132）
///
/// v1.6（公寓管家）：独立设置页取消——房源分享相关设置合并进主 App「设置 → 房源分享」分组，
/// 本文件保留远程配置（CosConfigView）、名片信息（ShareProfileView）、恢复列表（ConfigRestoreListView）、
/// 钥匙串修复（KeychainFix）与配置备份（CosConfigBackup）等子页面与工具，供主设置页复用。

/// 「备份」子文件夹总大小（数据库、Media/、二维码、分享缓存等都在这里）
func houseDocumentsSizeText() -> String {
    var total: Int64 = 0
    if let enumerator = FileManager.default.enumerator(at: DataRoot.url(), includingPropertiesForKeys: [.fileSizeKey]) {
        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
                total += Int64(size)
            }
        }
    }
    return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
}

// MARK: - 远程配置（腾讯云 COS）

/// v1.19：新增「自定义域名（可选）」——腾讯云 2024 年后新建桶默认域名会被微信识别成文件，
/// 绑定自定义域名后微信才会把分享链接抓成网页卡片；域名留空则回退默认域名（仅兜底）
/// v1.20：保存改为「保存并验证连接」——写入钥匙串成功后立即用当前配置向 COS 上传一个测试文件
/// 并回读，真实连通才算保存成功；任何环节失败都会给出具体错误码（桶不存在/签名错误/域名未生效），
/// 不再静默提示「已保存」；同时密钥写入失败也会明确报出。
// MARK: - COS 配置备份 / 恢复（v1.33 剪贴板版 → v1.34 文件版）

/// v1.13 需求16：COS 配置备份统一存放目录 Documents/备份/CosConfig/（不再散在「备份」根目录）
enum CosConfigStore {
    static func directory() -> URL {
        let dir = DataRoot.url().appendingPathComponent("CosConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// 把钥匙串里的 COS 配置导出为 JSON（v1.34 改为生成「桶名_地域_日期.json」文件由用户选择位置保存），
/// 换机 / 重装 / 误改后可从备份文件一键恢复。配置含密钥，备份文件请妥善保管。
enum CosConfigBackup {
    /// v1.44：备份文件补全云函数地址 + 用户名——换机/重装后一键还原应包含完整连接参数与身份
    static func exportJSON() -> String? {
        guard let config = CosConfig.load() else { return nil }
        let dict: [String: String] = [
            "bucket": config.bucket,
            "region": config.region,
            "secretId": config.secretId,
            "secretKey": config.secretKey,
            "customDomain": config.customDomain,
            "functionURL": CloudConfig.functionURL,
            "username": CloudUser.username
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    /// 从备份文件内容恢复配置到钥匙串；返回 (是否成功, 提示)
    static func restore(fromJSON json: String) -> (Bool, String) {
        guard let data = json.data(using: .utf8) else {
            return (false, "所选文件内容不是有效的配置文本，请确认选择的是「备份配置到文件」生成的 .json 文件")
        }
        let parsed: Any?
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            return (false, "所选文件内容不是有效的配置文本，请确认选择的是「备份配置到文件」生成的 .json 文件")
        }
        guard let dict = parsed as? [String: Any] else {
            return (false, "所选文件内容不是有效的配置文本，请确认选择的是「备份配置到文件」生成的 .json 文件")
        }
        let trimSet = CharacterSet.whitespacesAndNewlines
        let bucket = (dict["bucket"] as? String ?? "").trimmingCharacters(in: trimSet)
        let region = (dict["region"] as? String ?? "").trimmingCharacters(in: trimSet)
        let secretId = (dict["secretId"] as? String ?? "").trimmingCharacters(in: trimSet)
        let secretKey = (dict["secretKey"] as? String ?? "").trimmingCharacters(in: trimSet)
        let customDomain = (dict["customDomain"] as? String ?? "").trimmingCharacters(in: trimSet)
        let functionURL = (dict["functionURL"] as? String ?? "").trimmingCharacters(in: trimSet)
        let uname = (dict["username"] as? String ?? "").trimmingCharacters(in: trimSet)
        if bucket.isEmpty || region.isEmpty || secretId.isEmpty || secretKey.isEmpty {
            return (false, "配置缺少必填项（存储桶 / 地域 / SecretId / SecretKey），请检查备份文件")
        }
        var allSaved = true
        let items: [(String, String)] = [
            (KeychainKey.bucket, bucket),
            (KeychainKey.region, region),
            (KeychainKey.secretId, secretId),
            (KeychainKey.secretKey, secretKey),
            (KeychainKey.customDomain, customDomain)
        ]
        for item in items {
            if !KeychainFix.saveVerified(item.1, for: item.0) {
                allSaved = false
            }
        }
        if !allSaved {
            return (false, "写入本机钥匙串失败，请重试；若仍失败请重启 App 后再试")
        }
        // v1.44：备份里的云函数地址 + 用户名一并还原（旧备份无此字段时保持原值，不覆盖）
        if !functionURL.isEmpty { CloudConfig.functionURL = functionURL }
        if !uname.isEmpty { CloudUser.username = uname }
        let msg = "配置已恢复：地域 " + region + " / 存储桶 " + bucket
            + (functionURL.isEmpty ? "" : "\n云函数地址：\(functionURL)")
            + (uname.isEmpty ? "" : "\n用户名：\(uname)")
            + "\n表单已刷新，可点「保存并验证连接」确认可用"
        return (true, msg)
    }
}

struct CosConfigView: View {
    @State private var bucket = ""
    @State private var region = ""
    @State private var secretId = ""
    @State private var secretKey = ""
    @State private var customDomain = ""
    @State private var functionURL = ""   // v1.18：云函数地址（后台网址），管理后台入口走此地址
    @State private var username = ""      // v1.19：多用户——本机用户名（共享房源时区分是谁的操作）
    @State private var savedTip: String?
    @State private var webCacheTip: String?   // v1.38：刷新网页后台缓存的提示
    @State private var isVerifying = false
    // v1.34：文件备份 / 恢复 + 清空配置（v1.35：备份直写「备份」文件夹；v1.36：恢复改为列表选择）
    @State private var showRestoreList = false
    @State private var confirmClear = false
    @State private var showBrowseConfig = false   // v1.7：查看 COS 配置备份文件（内部浏览组件，只读）
    // v1.37：多用户「导出给别人用」改 SwiftUI sheet 弹系统分享面板（此前手动 present 被 alert 覆盖弹不出）
    @State private var profileShareURL: URL? = nil
    @State private var showProfileShare = false
    @State private var showProfileImport = false   // 导入别人发来的共享配置文件

    init() {
        // v1.34：新装 App 默认配置全部为空，由用户自行填写（不再预填 ap-hongkong）
        let b = KeychainStore.load(KeychainKey.bucket) ?? ""
        let r = KeychainStore.load(KeychainKey.region) ?? ""
        let i = KeychainStore.load(KeychainKey.secretId) ?? ""
        let k = KeychainStore.load(KeychainKey.secretKey) ?? ""
        let d = KeychainStore.load(KeychainKey.customDomain) ?? ""
        _bucket = State(initialValue: b)
        _region = State(initialValue: r)
        _secretId = State(initialValue: i)
        _secretKey = State(initialValue: k)
        _customDomain = State(initialValue: d)
        _functionURL = State(initialValue: CloudConfig.functionURL)
        _username = State(initialValue: CloudUser.username)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("用途", value: "分享房源卡片链接")
                LabeledContent("有效期", value: "长期有效（不自动过期）")
            } footer: {
                Text("分享时 App 会把该房源的图片和视频上传到腾讯云 COS，生成一个链接卡片发给微信好友；好友点开卡片即可查看，链接长期有效。")
            }

            // v1.18：云函数后台——管理后台网址（可设置）、后台口令、部署教程
            Section {
                TextField("云函数地址（后台网址）", text: $functionURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                // v1.41 第7点：三个按钮合并为两个——「保存并验证」（先存地址再验证连通）+「清空地址」
                // v1.43：样式对齐 COS 配置按钮（保存=深蓝实心底白字 + 验证中转圈；清空=浅色描边）
                HStack(spacing: 12) {
                    Button {
                        saveAndVerifyFunctionURL()
                    } label: {
                        if isVerifying {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("保存并验证", systemImage: "checkmark.circle")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 31/255, green: 58/255, blue: 95/255))
                    .disabled(isVerifying)
                    Button {
                        clearFunctionURL()
                    } label: {
                        Label("清空地址", systemImage: "xmark.circle")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isVerifying || functionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                NavigationLink {
                    AdminPasswordView()
                } label: {
                    Label("后台口令", systemImage: "lock")
                }
                // v1.40 第4点：部署包下载入口改为图文教程（教程内仍可下载部署包 zip）
                NavigationLink {
                    DeployGuideView()
                } label: {
                    Label("云端部署图文教程", systemImage: "book")
                }
                // v1.38：网页后台每次改动（重新部署）后，点此刷新——清 App 网页缓存 + 换新版本戳，safari 打开的后台立即是最新版，无需重新构建 App
                Button {
                    WebCache.clear { savedTip = "网页后台缓存已刷新 ✅\n下次在「管理后台」点右上角 Safari 图标打开网页后台，就是最新版本。" }
                } label: {
                    Label("刷新网页后台缓存", systemImage: "arrow.clockwise.circle")
                }
            } header: {
                Text("云函数后台")
            } footer: {
                Text("云函数地址即管理后台网页的网址。地址可独立保存/验证/清空（验证会访问后台首页，不依赖口令）。给别的房东用：点「云端部署图文教程」按步骤部署，再把他的云函数地址填到这里。")
            }

            // v1.37：使用说明——单用户/多用户详细说明（展开块）+ 三端互通说明（已移到云端配置）
            Section("使用说明") {
                DisclosureGroup("单用户（用自己的配置）") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("· 单人用只需 3 步：① 填好 云函数地址 / 桶 / 地域 / 自定义域名 / 密钥；② 点「保存并验证连接」；③ 正常用 App。").font(.footnote)
                        Text("· 房源文字、照片视频会自动传到云端桶；分享卡片发好友能直接看；备份会上传到云端留档。").font(.footnote)
                        Text("· 网页后台（云函数地址）可看访问统计、管理桶文件、查储存用量。").font(.footnote)
                        Text("· 换机 / 重装：填同样配置 + 恢复配置备份，下拉同步就把云端房源拉回本地。").font(.footnote)
                        Text("· 本地数据始终保留，云端只是「第二份」，断开配置也不影响本地使用。").font(.footnote)
                    }
                    .padding(.vertical, 4)
                }
                DisclosureGroup("多用户（多台共用一套桶）") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("· 前提：几台手机填同一个桶和云函数地址，各自填不同用户名。").font(.footnote)
                        Text("· 共享的只有「房源」：一台录入上传，另一台下拉同步就能看到；删房也会同步删云端。").font(.footnote)
                        Text("· 不共享：名片、二维码、水印、分享记录、访问统计、云端备份——都按用户名分开，绝不会看到别人（备份各管各的）。").font(.footnote)
                        Text("· 用户名的作用：操作日志 / 分享 / 统计带上用户名，网页后台能看到是谁在操作。").font(.footnote)
                        Text("· 给别人用不用懂桶和云函数：配好你的后，把「配置」发给对方导入 + 填用户名即可；对方也可以自己整套部署（用下方部署包）用自己的桶。").font(.footnote)
                    }
                    .padding(.vertical, 4)
                }
                NavigationLink {
                    InterconnectionInfoView()
                } label: {
                    Label("三端互通说明（App ↔ 云函数 ↔ 网页后台）", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            // v1.19：多用户——每台设备一个用户名，共享房源、其他数据按用户名隔离
            Section {
                TextField("我的用户名（如：涛）", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    saveUsername()
                } label: {
                    Label("保存用户名", systemImage: "person.fill.checkmark")
                }
                .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                // v1.37：多用户下的「导出/导入配置」已去掉——与下方「腾讯云 COS 配置」备份重复，合并到一处
            } header: {
                Text("多用户（共享房源）")
            } footer: {
                Text("多台手机填同一个桶配置、各自填用户名，即可共享房源：一台录入，另一台下拉同步就能看到。操作日志/分享/统计会带上您的用户名，其他私有数据（名片/水印/统计/备份）按用户名分开。")
            }

            Section("腾讯云 COS 配置") {
                TextField("存储桶名称", text: $bucket)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("地域（如 ap-hongkong）", text: $region)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("自定义域名（必填，如 share.fangyuan88.site）", text: $customDomain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("SecretId", text: $secretId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("SecretKey", text: $secretKey)
            }

            Section {
                HStack(spacing: 12) {
                    Button {
                        saveAndVerify()
                    } label: {
                        if isVerifying {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("保存并验证连接")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 31/255, green: 58/255, blue: 95/255))
                    .disabled(bucket.isEmpty || region.isEmpty || secretId.isEmpty || secretKey.isEmpty || isVerifying)
                    // v1.35：访问储存桶——用当前填写的桶名/地域直接打开腾讯云 COS 控制台对应桶
                    Button {
                        openBucketConsole()
                    } label: {
                        Label("访问储存桶", systemImage: "safari")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             || region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } footer: {
                Text("「保存并验证连接」会用当前配置上传测试文件并回读，成功才提示「配置正确」；「访问储存桶」用当前填写的桶名和地域打开腾讯云控制台。")
            }

            // v1.34：备份 / 恢复配置（文件方式）——备份生成「桶名_地域_日期.json」文件，
            // v1.35：备份文件直接生成到「公寓管家」→「备份」文件夹，不再弹出文件选择器
            // v1.36：恢复改为 App 内列表选择（列表选择式写法，避免系统文件选择器点击无反应）
            Section(header: Text("备份 / 恢复配置"), footer: Text("点「备份配置到文件」后，备份文件（桶名_地域_日期.json，含密钥）会直接生成到 iOS「文件」App → 我的 iPhone → 公寓管家 → 「备份」文件夹，随整个「备份」文件夹一起备份即可。换机 / 重装 / 误改后，点「从备份文件恢复配置」在列表中选择备份文件（或从其他位置导入）即可一键还原。含密钥内容请勿外泄。")) {
                Button {
                    prepareBackupFile()
                } label: {
                    Label("备份配置到文件", systemImage: "square.and.arrow.up")
                }
                Button {
                    showRestoreList = true
                } label: {
                    Label("从备份文件恢复配置", systemImage: "square.and.arrow.down")
                }
                // v1.7：查看配置备份文件（内部浏览组件，只读；与恢复选文件同款窗口）
                Button {
                    showBrowseConfig = true
                } label: {
                    Label("查看备份文件", systemImage: "folder")
                }
                // v1.34：清空全部配置并断开与桶的连接
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("清空全部配置并断开连接", systemImage: "trash")
                }
                .alert("确认清空全部配置？", isPresented: $confirmClear) {
                    Button("清空", role: .destructive) { clearAllConfig() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("将删除本机保存的存储桶、地域、密钥、自定义域名全部配置，并断开与 COS 的连接。此操作不可撤销，可先用「备份配置到文件」留底。")
                }
            }

            // v1.28：开通步骤从设置主页面移入本页（仅首次配置需要）
            Section("开通步骤（简述）") {
                Text("1. 打开 cloud.tencent.com 注册并实名认证；2. 开通「对象存储 COS」；3. 创建存储桶：名称可自定义（如 fangyuan88）、地域按您实际选择的填写（如香港 ap-hongkong）、访问权限选「私有读写」；4. 在「访问管理 CAM → API 密钥管理」新建密钥，得到 SecretId 和 SecretKey；5. 在「存储桶 → 域名与传输管理 → 自定义源站域名」绑定自己的域名（需先在腾讯云购买域名），并把域名填入远程配置的「自定义域名」栏——微信只认自定义域名，才能把链接抓成网页卡片。注意：桶名和地域必须和您实际创建的存储桶一致，才能连接成功。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Text("密钥与名片只存在本机钥匙串，不会上传到任何地方。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("云端配置")
        .navigationBarTitleDisplayMode(.inline)
        // v1.45：保存用户名 / 云函数地址等配置后，返回再进本页即时显示最新值
        //（与分享水印开关、微信二维码同款修法——SwiftUI 导航复用实例时 init 只跑一次，onAppear 重读存储兜底）
        .onAppear {
            username = CloudUser.username
            functionURL = CloudConfig.functionURL
            bucket = KeychainStore.load(KeychainKey.bucket) ?? ""
            region = KeychainStore.load(KeychainKey.region) ?? ""
            secretId = KeychainStore.load(KeychainKey.secretId) ?? ""
            secretKey = KeychainStore.load(KeychainKey.secretKey) ?? ""
            customDomain = KeychainStore.load(KeychainKey.customDomain) ?? ""
        }
        .sheet(isPresented: $showRestoreList) {
            ConfigRestoreListView(
                onPick: { url in
                    handleRestoreFile(url)
                }
            )
        }
        .sheet(isPresented: $showBrowseConfig) {
            CosBackupBrowseView()
        }
        // v1.37：导出「给别人用」配置 → 系统分享面板（SwiftUI sheet，保证能弹出）
        .sheet(isPresented: $showProfileShare) {
            if let url = profileShareURL {
                HouseShareSheet(items: [url])
            }
        }
        // v1.37：导入别人发来的共享配置文件
        .fileImporter(isPresented: $showProfileImport, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    importUserProfile(url)
                }
            case .failure(let error):
                savedTip = "无法读取所选文件：\(error.localizedDescription)"
            }
        }
        .alert("配置结果", isPresented: Binding(
            get: { savedTip != nil },
            set: { if !$0 { savedTip = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(savedTip ?? "")
        }
    }

    // v1.41 第7点：云函数地址「保存并验证」——先保存地址，再访问后台首页（act=admin 无需口令）验证连通
    private func saveAndVerifyFunctionURL() {
        functionURL = functionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        CloudConfig.functionURL = functionURL
        let urlText = functionURL
        guard !urlText.isEmpty else {
            savedTip = "云函数地址已清空"
            return
        }
        guard let url = URL(string: "\(urlText)?act=admin") else {
            savedTip = "地址格式不正确（应包含 https://）"
            return
        }
        isVerifying = true
        URLSession.shared.dataTask(with: url) { data, resp, err in
            DispatchQueue.main.async {
                self.isVerifying = false
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    self.savedTip = "地址已保存并验证：后台可连接 ✅"
                } else if let http = resp as? HTTPURLResponse {
                    self.savedTip = "地址已保存；云函数返回 HTTP \(http.statusCode)，请确认函数已部署且地址完整（末尾带 .tencentscf.com）"
                } else if let err = err {
                    self.savedTip = "地址已保存；连接失败：\(err.localizedDescription)"
                } else {
                    self.savedTip = "地址已保存；连接失败，请检查网络与地址"
                }
            }
        }.resume()
    }

    // v1.40 第3点：清空云函数地址（不再回退到旧默认值）
    private func clearFunctionURL() {
        CloudConfig.clearFunctionURL()
        functionURL = ""
        savedTip = "已清空云函数地址（新装状态）"
    }

    private func saveAndVerify() {
        // 0. 统一去除首尾空格（粘贴带入空白会导致签名失败或地域识别异常）
        let trimSet = CharacterSet.whitespacesAndNewlines
        bucket = bucket.trimmingCharacters(in: trimSet)
        region = region.trimmingCharacters(in: trimSet)
        secretId = secretId.trimmingCharacters(in: trimSet)
        secretKey = secretKey.trimmingCharacters(in: trimSet)
        customDomain = customDomain.trimmingCharacters(in: trimSet)
        functionURL = functionURL.trimmingCharacters(in: trimSet)
        if !functionURL.isEmpty {
            CloudConfig.functionURL = functionURL
        }
        // v1.19：保存用户名（操作日志 / 分享 / 统计带它）
        username = username.trimmingCharacters(in: trimSet)
        CloudUser.username = username

        // 1. 写入钥匙串：任一项写失败都要明确提示（v1.20 之前写入失败被静默吞掉）
        var allSaved = true
        let items: [(String, String)] = [
            (KeychainKey.bucket, bucket),
            (KeychainKey.region, region),
            (KeychainKey.secretId, secretId),
            (KeychainKey.secretKey, secretKey),
            (KeychainKey.customDomain, customDomain)
        ]
        for (key, value) in items {
            if !KeychainFix.saveVerified(value, for: key) {
                allSaved = false
            }
        }
        if !allSaved {
            savedTip = "写入本机钥匙串失败，请重新保存一次；若仍失败请重启 App 后再试"
            return
        }

        // 1.5 回读自检（v1.33）：保存后立即从钥匙串读回比对，防止「保存成功但重启后是旧值」
        let savedBucket = KeychainStore.load(KeychainKey.bucket) ?? ""
        let savedRegion = KeychainStore.load(KeychainKey.region) ?? ""
        if savedRegion != region || savedBucket != bucket {
            savedTip = "写入自检失败：钥匙串中地域为「\(savedRegion)」、存储桶为「\(savedBucket)」，与本次填写不一致。请重启 App 后重新保存"
            return
        }

        // 2. 后台真实验证：上传测试文件 + 回读（失败会带具体错误码）
        isVerifying = true
        let config = CosConfig(bucket: bucket, region: region, secretId: secretId, secretKey: secretKey, customDomain: customDomain)
        Task {
            do {
                let hostUsed = try await CosUploader.verifyConnection(config: config)
                // v1.24：多用户隔离——云端模式若没设用户名，提醒先设置（备份/分享按用户名隔离，未设名统一落到「未设置」，避免误覆盖）
                let unameTip = CloudUser.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "\n⚠️ 还没设置用户名：云端备份/分享会归到「未设置」名下，建议在下方「多用户」填写自己的用户名，多人共用时好区分"
                    : ""
                savedTip = "配置正确：云存储连接成功 ✅\n已保存地域：\(region)\n实际使用域名：\(hostUsed)\n现在可以去详情页「分享」生成卡片链接\(unameTip)"
            } catch {
                savedTip = "验证失败：\(error.localizedDescription)"
            }
            isVerifying = false
        }
    }

    // MARK: - v1.34 备份 / 恢复配置（文件方式）

    /// 生成备份文件名：桶名_地域_日期.json（如 fangyuan88-1511251056_ap-hongkong_20261021.json）
    private var backupFileName: String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        let safeBucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "cos" : bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeRegion = region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : region.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(safeBucket)_\(safeRegion)_\(df.string(from: Date())).json"
    }

    /// 备份：生成 JSON 文件并直接写入「备份/CosConfig」子文件夹（Documents/备份/CosConfig/<桶名_地域_日期.json>），
    /// v1.35：不再弹出文件导出器（避免 iOS 上偶发空白面板）；备份文件随整个「备份」文件夹一起备份
    /// v1.13 需求16：配置备份收拢到 备份/CosConfig/ 子文件夹（根目录只留「备份」文件夹）
    private func prepareBackupFile() {
        guard let json = CosConfigBackup.exportJSON() else {
            savedTip = "当前没有完整配置可备份，请先填写存储桶 / 地域 / SecretId / SecretKey 并保存"
            return
        }
        let target = CosConfigStore.directory().appendingPathComponent(backupFileName)
        do {
            try json.data(using: .utf8)?.write(to: target, options: .atomic)
            savedTip = "配置备份成功 ✅\n文件已生成到：文件 App → 我的 iPhone → 公寓管家 → 备份 → CosConfig\n\(backupFileName)\n（随「备份」文件夹一起拷贝/共享即可留底）"
        } catch {
            savedTip = "生成备份文件失败：\(error.localizedDescription)"
        }
    }

    /// v1.18：下载云端部署包——从 App 内导出 zip 到「备份」文件夹（内含 deploy.py 脚本 + 图文说明，给房东部署云端后台用）
    /// v1.40 第4点：入口改为图文教程页内按钮；顺带修复路径（此前 DataRoot 已是「备份」，又拼了一层「备份」导致导到 备份/备份/）
    private func downloadDeployPack() {
        guard let url = Bundle.main.url(forResource: "云端部署包", withExtension: "zip") else {
            savedTip = "未找到云端部署包资源，请确认安装的是最新版 App"
            return
        }
        let dir = DataRoot.url()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("云端部署包.zip")
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: url, to: target)
            savedTip = "云端部署包已导出到本地 ✅\n位置：文件 App → 公寓管家 → 备份 → 云端部署包.zip\n内含 deploy.py 部署脚本 + 图文说明，发给房东在电脑上解压运行即可在自己腾讯云部署后台。"
        } catch {
            savedTip = "导出失败：\(error.localizedDescription)"
        }
    }

    // MARK: - v1.19 多用户：保存用户名 / 导出「给别人用」的配置

    /// v1.19 补全：单独保存用户名（此前只在「保存并验证连接」里顺带写，改后退出重进会被清空）
    private func saveUsername() {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        username = trimmed
        CloudUser.username = trimmed
        savedTip = trimmed.isEmpty
            ? "用户名不能为空，请输入后保存"
            : "用户名已保存：\(trimmed)\n共享房源的操作日志 / 分享 / 统计都会带上它"
    }

    /// 把本机已填的云配置 + 用户名打包成一个 JSON 文件，走系统分享发给别人；对方「添加用户/导入配置」即可共用房源。
    /// 文件不含敏感解释，仅含可用的连接参数。
    private func exportUserProfile() {
        let trimmedName = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile: [String: String] = [
            "app": "公寓管家共享配置",
            "bucket": bucket,
            "region": region,
            "secretId": secretId,
            "secretKey": secretKey,
            "customDomain": customDomain,
            "functionURL": functionURL,
            "username": trimmedName
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted]),
              let json = String(data: data, encoding: .utf8) else {
            savedTip = "生成配置文件失败，请重试"
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("公寓管家共享配置.json")
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            savedTip = "写入配置失败：\(error.localizedDescription)"
            return
        }
        // v1.37：改用 SwiftUI sheet 弹系统分享面板（手动 present 在 SwiftUI 里会被 alert 覆盖，面板弹不出）
        profileShareURL = url
        showProfileShare = true
    }

    /// v1.37：导入别人发来的共享配置文件（「导出给别人用」生成的 .json）——自动识别各字段并写入本机钥匙串 + 云函数地址 + 用户名
    private func importUserProfile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            savedTip = "无法识别该文件，请选择「导出给别人用」生成的共享配置文件（.json）"
            return
        }
        let trim = CharacterSet.whitespacesAndNewlines
        let bucket = (dict["bucket"] as? String ?? "").trimmingCharacters(in: trim)
        let region = (dict["region"] as? String ?? "").trimmingCharacters(in: trim)
        let secretId = (dict["secretId"] as? String ?? "").trimmingCharacters(in: trim)
        let secretKey = (dict["secretKey"] as? String ?? "").trimmingCharacters(in: trim)
        let customDomain = (dict["customDomain"] as? String ?? "").trimmingCharacters(in: trim)
        let functionURL = (dict["functionURL"] as? String ?? "").trimmingCharacters(in: trim)
        let uname = (dict["username"] as? String ?? "").trimmingCharacters(in: trim)
        if bucket.isEmpty || region.isEmpty || secretId.isEmpty || secretKey.isEmpty {
            savedTip = "该文件不是共享配置文件（缺少存储桶 / 地域 / SecretId / SecretKey）"
            return
        }
        var allSaved = true
        let items: [(String, String)] = [
            (KeychainKey.bucket, bucket),
            (KeychainKey.region, region),
            (KeychainKey.secretId, secretId),
            (KeychainKey.secretKey, secretKey),
            (KeychainKey.customDomain, customDomain)
        ]
        for (key, value) in items {
            if !KeychainFix.saveVerified(value, for: key) { allSaved = false }
        }
        if !allSaved {
            savedTip = "写入本机钥匙串失败，请重试；若仍失败请重启 App 后再试"
            return
        }
        if !functionURL.isEmpty { CloudConfig.functionURL = functionURL }
        if !uname.isEmpty { CloudUser.username = uname }
        // 刷新表单，用户直接看到刚导入的值
        self.bucket = bucket
        self.region = region
        self.secretId = secretId
        self.secretKey = secretKey
        self.customDomain = customDomain
        self.functionURL = CloudConfig.functionURL
        self.username = CloudUser.username
        savedTip = "共享配置已导入 ✅\n存储桶：\(bucket) / 地域：\(region)\n云函数地址：\(functionURL.isEmpty ? "（未填）" : functionURL)\n用户名：\(uname.isEmpty ? "（未填）" : uname)\n可点「保存并验证连接」确认可用"
    }

    /// 取当前最上层 VC（分享面板 / 弹窗用）——优先找前台活跃场景的 keyWindow
    private func topMostViewController() -> UIViewController? {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene, ws.activationState == .foregroundActive else { continue }
            let root = ws.keyWindow?.rootViewController ?? ws.windows.first?.rootViewController
            guard let root else { continue }
            var top = root
            while let presented = top.presentedViewController { top = presented }
            return top
        }
        return nil
    }

    /// v1.35：访问储存桶——用当前填写的桶名/地域打开腾讯云 COS 控制台对应桶页面（默认浏览器）
    private func openBucketConsole() {
        let b = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty, !r.isEmpty else {
            savedTip = "请先填写存储桶名称和地域，再访问储存桶"
            return
        }
        let urlString = "https://console.cloud.tencent.com/cos/bucket?bucket=\(b)&region=\(r)"
        guard let url = URL(string: urlString) else {
            savedTip = "无法打开储存桶，请检查桶名 / 地域是否填写正确"
            return
        }
        UIApplication.shared.open(url) { ok in
            if !ok {
                savedTip = "无法打开浏览器，请手动访问腾讯云控制台"
            }
        }
    }

    /// 恢复：从用户选择的备份文件读取并还原配置
    private func handleRestoreFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            savedTip = "无法读取所选文件，请确认选择的是「备份配置到文件」生成的 .json 文件"
            return
        }
        let result = CosConfigBackup.restore(fromJSON: text)
        savedTip = result.1
        if result.0 {
            // 恢复成功后刷新表单，用户可直接看到刚恢复的值
            refreshFormFromKeychain()
        }
    }

    /// 清空全部配置：删除钥匙串 COS 5 项 + 云函数地址 + 用户名，并清空表单
    /// v1.41（C2 补全）：此前只删 COS 5 项——云函数地址（UserDefaults）与用户名（UserDefaults）未清，
    /// 「清空全部配置」后 App 仍带旧地址/旧用户名连接云端，不是真正「断开全部连接」。
    private func clearAllConfig() {
        var allCleared = true
        let keys = [
            KeychainKey.bucket,
            KeychainKey.region,
            KeychainKey.secretId,
            KeychainKey.secretKey,
            KeychainKey.customDomain
        ]
        for key in keys {
            if !KeychainFix.deleteKey(key) {
                allCleared = false
            }
        }
        // v1.41：一并清云函数地址与用户名（都存 UserDefaults，重装后才可能残留，主动清空）
        CloudConfig.clearFunctionURL()
        CloudUser.username = ""
        bucket = ""
        region = ""
        secretId = ""
        secretKey = ""
        customDomain = ""
        functionURL = ""
        username = ""
        // 置空后复核：钥匙串 5 项删除成功 + 云函数地址与用户名均已清空
        let cleared = CloudConfig.functionURL.isEmpty && CloudUser.username.isEmpty
        savedTip = (allCleared && cleared) ? "已清空全部配置并断开与云端的连接 ✅" : "部分配置清除失败，请重启 App 后重试"
    }

    private func refreshFormFromKeychain() {
        bucket = KeychainStore.load(KeychainKey.bucket) ?? ""
        region = KeychainStore.load(KeychainKey.region) ?? ""
        secretId = KeychainStore.load(KeychainKey.secretId) ?? ""
        secretKey = KeychainStore.load(KeychainKey.secretKey) ?? ""
        customDomain = KeychainStore.load(KeychainKey.customDomain) ?? ""
    }
}

// MARK: - 恢复配置（v1.36：列表式选择，替代系统文件选择器避免点击无反应）


// MARK: - v1.40 第4点：云端部署图文教程（替代原「下载部署包 zip」入口；教程内仍可下载部署包）

struct DeployGuideView: View {
    @State private var tip: String?
    @State private var showTip = false

    private struct Step {
        let icon: String
        let title: String
        let body: String
    }

    private let steps: [Step] = [
        Step(icon: "person.crop.circle.badge.checkmark", title: "1. 准备腾讯云账号", body: "打开 cloud.tencent.com 注册并完成实名认证。新用户可先领取免费额度。"),
        Step(icon: "function", title: "2. 开通云函数 SCF", body: "搜索「云函数 SCF」进入控制台，开通服务（按量付费，日常个人使用基本不产生费用）。"),
        Step(icon: "square.and.arrow.down", title: "3. 下载部署包", body: "点下方「下载部署包」，把 zip 发到电脑（或 iPhone 上用文件 App 存着）。部署包内含 app.py、admin.html、deploy.py 和说明。"),
        Step(icon: "plus.circle", title: "4. 创建函数并上传", body: "云函数控制台 → 函数服务 → 创建：运行环境选 Python 3，创建方式选「从头开始」；创建后进入函数 → 函数代码 → 上传 zip 部署包（覆盖 index.py 逻辑）。"),
        Step(icon: "slider.horizontal.3", title: "5. 配置环境变量", body: "在函数「配置 → 环境变量」添加：BUCKET（存储桶名）、REGION（地域，如 ap-hongkong）、SECRET_ID、SECRET_KEY、PASSWORD（后台口令，默认 12345678）。保存后点「部署」。"),
        Step(icon: "link", title: "6. 找到云函数地址", body: "函数详情页 → 「触发管理」→ 复制访问路径（形如 https://xxxx.ap-hongkong.tencentscf.com）。把完整地址填到 App「云端配置 → 云函数地址」，点「验证地址」。"),
        Step(icon: "checkmark.seal", title: "7. 验证与使用", body: "验证提示「地址正确，后台可连接」即可。App 首页「管理后台」就能打开网页后台：看访问统计、分享记录、管理桶文件。"),
        Step(icon: "arrow.triangle.2.circlepath", title: "8. 重新部署", body: "以后升级后台：把新版部署包 zip 重新上传并部署；部署完在 App 里点「刷新网页后台缓存」，后台立即是最新版，不用重新安装 App。")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(steps, id: \.title) { step in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: step.icon)
                            .font(.system(size: 18))
                            .foregroundColor(Color(red: 31/255, green: 58/255, blue: 95/255))
                            .frame(width: 30)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text(step.body)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                // 下载部署包 zip（教程核心操作）
                Button {
                    downloadPack()
                } label: {
                    Label("下载部署包（zip，含脚本+说明）", systemImage: "square.and.arrow.down")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 31/255, green: 58/255, blue: 95/255))
                .padding(.top, 4)
                Text("部署包导出到：文件 App → 公寓管家 → 备份 → 云端部署包.zip")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(16)
        }
        .navigationTitle("云端部署图文教程")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: $showTip) {
            Button("好", role: .cancel) {}
        } message: {
            Text(tip ?? "")
        }
    }

    private func downloadPack() {
        guard let url = Bundle.main.url(forResource: "云端部署包", withExtension: "zip") else {
            tip = "未找到云端部署包资源，请确认安装的是最新版 App"; showTip = true
            return
        }
        let dir = DataRoot.url()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("云端部署包.zip")
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: url, to: target)
            tip = "云端部署包已导出到本地 ✅\n位置：文件 App → 公寓管家 → 备份 → 云端部署包.zip"
            showTip = true
        } catch {
            tip = "导出失败：\(error.localizedDescription)"; showTip = true
        }
    }
}

/// 列出「备份」文件夹内的 .json 备份文件，点击直接恢复（与主 App 恢复备份同款列表写法）；
/// 列表底部提供「从其他位置选择」用系统文件选择器兜底（保留自由选择路径的能力）。
/// v1.44：文件选择器改为本列表视图内自挂（此前跨视图延迟弹 sheet 在 iOS 上偶发被吞，按钮无效）
struct ConfigRestoreListView: View {
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Group {
                if files.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("「备份」文件夹里还没有备份文件")
                            .font(.headline)
                        Text("请先点「备份配置到文件」生成备份，或把备份 .json 文件放进 iOS「文件」App → 我的 iPhone → 公寓管家 → 备份 文件夹")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button {
                            showImporter = true
                        } label: {
                            Label("从其他位置选择…", systemImage: "folder")
                                .font(.subheadline)
                        }
                        .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(files, id: \.self) { url in
                            Button {
                                onPick(url)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.text")
                                        .foregroundColor(.blue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(url.lastPathComponent)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Text(fileSize(of: url))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        Section {
                            Button {
                                showImporter = true
                            } label: {
                                Label("从其他位置选择…", systemImage: "folder")
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("选择备份文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear(perform: loadFiles)
            // v1.44：文件选择器直接挂在本视图上（不再经父视图延迟弹），保证点按钮立即弹出系统文件选择器
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        onPick(url)
                        dismiss()
                    }
                case .failure:
                    break
                }
            }
        }
    }

    /// 列出「备份/CosConfig」文件夹内的 .json 文件（v1.13 需求16：配置备份收拢到子文件夹），
    /// 兼容旧位置「备份」根目录残留文件（启动迁移未执行完的场景），按文件名（含日期）倒序，最新的在最上面
    private func loadFiles() {
        let fm = FileManager.default
        var collected: [URL] = []
        for dir in [CosConfigStore.directory(), DataRoot.url()] {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            collected += items.filter { $0.pathExtension.lowercased() == "json" }
        }
        // 去重（同路径只保留一次）
        var seen = Set<String>()
        files = collected
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func fileSize(of url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// MARK: - v1.7 查看 COS 配置备份文件（内部浏览组件，v1.11 支持左滑删除 + 二级确认）

/// 列出「备份」文件夹根目录的 .json 配置备份文件（桶名_地域_日期.json），v1.11 起支持左滑删除（带二级确认）。
struct CosBackupBrowseView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files: [ConfigBackupFileEntry] = []
    @State private var deleteTarget: ConfigBackupFileEntry? = nil
    @State private var showDeleteConfirm = false
    @State private var deleteResultTip: String? = nil

    var body: some View {
        NavigationStack {
            Group {
                if files.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("还没有配置备份文件")
                            .font(.headline)
                        Text("点「备份配置到文件」生成后，备份文件会出现在这里（桶名_地域_日期.json）")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section("配置备份文件") {
                            ForEach(files) { file in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(file.name)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(file.sizeText)
                                            .font(.footnote)
                                            .foregroundColor(.secondary)
                                    }
                                    Text(file.dateText)
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        deleteTarget = file
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("查看备份文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .confirmationDialog(
                "删除配置备份文件？",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { file in
                Button("删除", role: .destructive) { performDelete(file) }
                Button("取消", role: .cancel) {}
            } message: { file in
                Text("「\(file.name)」将被永久删除，删除后无法恢复。")
            }
            .alert("删除配置备份文件", isPresented: Binding(
                get: { deleteResultTip != nil },
                set: { if !$0 { deleteResultTip = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(deleteResultTip ?? "")
            }
            .onAppear(perform: loadFiles)
        }
    }

    /// v1.13 需求16：配置备份文件收拢在 备份/CosConfig/；兼容扫描旧位置（备份/ 根目录残留 json）
    private func loadFiles() {
        var entries: [ConfigBackupFileEntry] = []
        for dir in [CosConfigStore.directory(), DataRoot.url()] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names where name.hasSuffix(".json") {
                let url = dir.appendingPathComponent(name)
                // 同一文件已收录（如迁移未完成导致的重复），跳过
                if entries.contains(where: { $0.url.path == url.path }) { continue }
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let date = attrs?[.modificationDate] as? Date ?? .distantPast
                entries.append(ConfigBackupFileEntry(
                    name: name,
                    sizeText: ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                    dateText: Self.dateFormatter.string(from: date),
                    url: url
                ))
            }
        }
        entries.sort { $0.dateText > $1.dateText }
        files = entries
    }

    private func performDelete(_ file: ConfigBackupFileEntry) {
        do {
            try FileManager.default.removeItem(at: file.url)
            deleteResultTip = "已删除「\(file.name)」"
            loadFiles()
        } catch {
            deleteResultTip = "删除失败，请检查文件权限后重试"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()
}

struct ConfigBackupFileEntry: Identifiable {
    let id = UUID()
    let name: String
    let sizeText: String
    let dateText: String
    let url: URL
}

// MARK: - 名片信息

/// v1.21：分享名片信息（姓名/电话）——显示在分享 H5 页面的名片区、微信卡片的描述和
/// 「拨打电话/复制电话」按钮上。v1.22：修改后再次分享自动按新名片重新生成链接
/// （分享缓存里存了名片，名片一变缓存自动失效，无需手动清缓存）。
/// v1.26：①新增实时名片预览；②说明应用范围覆盖所有出现姓名/电话的位置
/// （H5 名片区、微信卡片描述、页面底栏电话、拨打电话/复制电话）。
/// v1.27：新增「微信二维码」入口——从相册选择二维码图片保存（Documents/qrcode.png），
/// 分享时自动上传 COS 并显示在所有 H5 名片板块左侧，访客长按可直接被微信识别。
struct ShareProfileView: View {
    @State private var shareName = ""
    @State private var sharePhone = ""
    @State private var savedTip: String?
    @State private var qrImage: UIImage?
    @State private var qrPickerItem: PhotosPickerItem?

    init() {
        let n = KeychainStore.load(KeychainKey.shareName) ?? "梁涛"
        let p = KeychainStore.load(KeychainKey.sharePhone) ?? "13288251132"
        _shareName = State(initialValue: n)
        _sharePhone = State(initialValue: p)
        if let data = QrcodeStore.loadData() {
            _qrImage = State(initialValue: UIImage(data: data))
        }
    }

    /// 预览用的姓名/电话：输入为空时显示默认值（与分享时行为一致）
    private var previewName: String {
        let n = shareName.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "梁涛" : n
    }
    private var previewPhone: String {
        let p = sharePhone.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? "13288251132" : p
    }

    /// v1.42：把本地二维码立即同步到云端桶 users/<用户名>/qrcode.jpg（已发出的 H5 链接动态引用桶 URL，
    /// 保存/清除后无需重新分享即生效）。未配置云存储或上传失败时静默跳过（下次分享时仍会照常上传）。
    private func syncQRToCloud(clear: Bool) {
        guard let config = CosConfig.load() else { return }
        Task {
            do {
                if clear {
                    if let url = try? CosUploader.presignedURL(for: CloudUser.qrPath, method: "DELETE", expires: 600, headers: [], config: config) {
                        var req = URLRequest(url: url)
                        req.httpMethod = "DELETE"
                        _ = try? await URLSession.shared.data(for: req)
                    }
                } else if let data = QrcodeStore.loadData(),
                          let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) {
                    try await CosUploader.upload(data: jpeg, to: CloudUser.qrPath, contentType: "image/jpeg", config: config)
                }
            } catch {
                // 静默：网络/配置问题不阻塞本地保存，分享时会再次上传
            }
        }
    }

    var body: some View {
        Form {
            // v1.26：实时名片预览——输入即变，所见即所得
            Section(header: Text("名片预览")) {
                VStack(spacing: 10) {
                    Text("米兰租赁管家 · 专业省心租好房")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        Text(previewName)
                            .font(.headline)
                        Text(previewPhone)
                            .font(.headline)
                            .foregroundColor(.orange)
                    }
                    Text("微信同号 · 24小时可约看房")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    HStack(spacing: 10) {
                        Text("拨打电话")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 26)
                            .padding(.vertical, 9)
                            .background(Color(red: 31/255, green: 58/255, blue: 95/255))
                            .clipShape(Capsule())
                        Text("复制电话")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 26)
                            .padding(.vertical, 9)
                            .background(Color(.systemGray6))
                            .clipShape(Capsule())
                    }
                    // v1.27：二维码预览（有则显示缩略图，无则提示）
                    if let qrImage {
                        Image(uiImage: qrImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 104, height: 104)
                            .background(Color.white)
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.systemGray4), lineWidth: 1))
                            .padding(.top, 6)
                    } else {
                        Text("未设置微信二维码")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.top, 6)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(Color(.systemBackground))
                .cornerRadius(14)
                .padding(.top, 4)
            }

            Section(header: Text("名片信息"), footer: Text("姓名和电话会应用到所有出现它们的地方：分享 H5 页面的名片区（含合集列表与详情页）、微信卡片的描述、页面底栏的联系电话、以及「拨打电话/复制电话」按钮。修改并保存后，下次分享会自动按新名片重新生成链接；之前已发出的链接保持原样。")) {
                TextField("姓名（默认：梁涛）", text: $shareName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("电话（默认：13288251132）", text: $sharePhone)
                    .keyboardType(.phonePad)
                Button {
                    saveShareProfile()
                } label: {
                    Text("保存名片信息")
                        .frame(maxWidth: .infinity)
                }
                .disabled(shareName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // v1.27：微信二维码——相册选择保存；分享时自动上传，显示在所有 H5 名片板块左侧
            Section(header: Text("微信二维码"), footer: Text("二维码会显示在所有分享 H5 页面的名片板块左侧（拨打电话/复制电话上方），访客长按二维码即可弹出微信「识别图中二维码」菜单。更换后无需重新分享——已发出的链接也会自动显示新二维码。")) {
                PhotosPicker(selection: $qrPickerItem, matching: .images) {
                    Label(qrImage == nil ? "选择二维码图片" : "更换二维码图片", systemImage: "qrcode")
                }
                .onChange(of: qrPickerItem) { _, newItem in
                    guard let newItem else { return }
                    Task {
                        if let data = try? await newItem.loadTransferable(type: Data.self),
                           let image = UIImage(data: data),
                           let jpeg = image.jpegData(compressionQuality: 0.9) {
                            let ok = QrcodeStore.save(jpeg)
                            qrImage = UIImage(data: jpeg)
                            // v1.42：保存后立即同步云端桶 users/<用户名>/qrcode.jpg——
                            //        已发出的 H5 链接动态引用桶 URL，无需重新分享即显示新二维码（此前只写本地，要等下次分享才上传）
                            syncQRToCloud(clear: false)
                            savedTip = ok ? "微信二维码已更新 ✅\n已发出的分享链接也会立即显示新二维码" : "保存二维码失败，请重试"
                        } else {
                            savedTip = "无法读取所选图片，请换一张清晰的二维码图片"
                        }
                        qrPickerItem = nil
                    }
                }
                if qrImage != nil {
                    Button("清除二维码", role: .destructive) {
                        QrcodeStore.clear()
                        qrImage = nil
                        // v1.42：清除后立即删除云端桶二维码，已发出链接不再显示（此前只清本地）
                        syncQRToCloud(clear: true)
                        savedTip = "二维码已清除，已发出的分享链接不再显示二维码"
                    }
                }
            }
        }
        .navigationTitle("名片信息")
        .navigationBarTitleDisplayMode(.inline)
        // v1.42：返回本页时重新读本地二维码（与分享水印开关同款修法——init 缓存可能陈旧，onAppear 刷新即显示最新）
        .onAppear {
            if let data = QrcodeStore.loadData() {
                qrImage = UIImage(data: data)
            } else {
                qrImage = nil
            }
        }
        .alert("保存结果", isPresented: Binding(
            get: { savedTip != nil },
            set: { if !$0 { savedTip = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(savedTip ?? "")
        }
    }

    /// v1.47：把名片姓名/电话同步到云端 users/<用户名>/profile.json——公开选房 H5（?act=rooms）
    /// 每次打开/刷新实时读取它，改名片后租客刷新页面即显示最新（二维码图已由 syncQRToCloud 上传 qrcode.jpg）。
    private func syncProfileToCloud(name: String, phone: String) {
        guard let config = CosConfig.load() else { return }
        Task {
            do {
                let obj: [String: Any] = ["name": name, "phone": phone, "updated": ISO8601DateFormatter().string(from: Date())]
                if let data = try? JSONSerialization.data(withJSONObject: obj, options: []) {
                    try await CosUploader.upload(data: data, to: CloudUser.userRootPrefix + "profile.json", contentType: "application/json", config: config)
                }
            } catch {
                // 静默：网络/配置问题不阻塞本地保存，下次分享时仍会照常上传
            }
        }
    }

    /// 保存分享名片信息（姓名/电话）到钥匙串
    private func saveShareProfile() {
        let name = shareName.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = sharePhone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            savedTip = "姓名不能为空"
            return
        }
        var ok = KeychainFix.saveVerified(name, for: KeychainKey.shareName)
        ok = KeychainFix.saveVerified(phone, for: KeychainKey.sharePhone) && ok
        // v1.47：保存后同步云端名片（公开选房页实时生效）
        syncProfileToCloud(name: name, phone: phone)
        savedTip = ok ? "名片信息已保存 ✅\n姓名：\(name)\n电话：\(phone.isEmpty ? "（未填，分享时用默认号）" : phone)\n公开选房链接刷新后同步更新" : "写入本机钥匙串失败，请重新保存一次"
    }
}

// MARK: - v1.47 公开选房链接（发给租客的实时选房 H5）

/// 选房链接页：生成「公开选房 H5」链接（云函数 ?act=rooms&u=<用户名>），
/// 复制/分享给租客即可实时查看所有待租房源；改房源、改名片、换二维码后租客刷新即最新。
struct RoomsShareView: View {
    @State private var copiedTip: String?
    @State private var showShareSheet = false

    /// 公开选房链接：云函数地址 + act=rooms + 当前用户名（页面服务端实时渲染）
    private var link: String {
        let base = CloudConfig.functionURL
        guard !base.isEmpty else { return "" }
        let u = (CloudUser.username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        return base + "?act=rooms&u=" + u
    }

    var body: some View {
        Form {
            Section(header: Text("公开选房链接"), footer: Text("把链接发给租客，对方打开即可看到所有待租房源（只显示户型，房东/密码/备注等内部信息已隐藏）。页面每次打开或刷新都实时读取云端最新房源：您新增/下架房源、改租金、改名片、换二维码后，租客刷新一下就是最新内容，无需重新生成链接。")) {
                if link.isEmpty {
                    Text("尚未配置云函数地址\n请先到「设置 → 房源分享 → 云端配置」填写云函数地址并保存验证")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    Text(link)
                        .font(.caption)
                        .textSelection(.enabled)
                        .foregroundColor(.secondary)
                    Button {
                        UIPasteboard.general.string = link
                        copiedTip = "链接已复制 ✅\n直接发给租客即可"
                    } label: {
                        Label("复制链接", systemImage: "doc.on.doc")
                    }
                    Button {
                        showShareSheet = true
                    } label: {
                        Label("分享给租客", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle("公开选房链接")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareSheet) {
            HouseShareSheet(items: [link])
        }
        .alert("已复制", isPresented: Binding(
            get: { copiedTip != nil },
            set: { if !$0 { copiedTip = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(copiedTip ?? "")
        }
    }
}
