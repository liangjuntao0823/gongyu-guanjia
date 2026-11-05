//
//  AjkPublic.swift
//  公寓管家 · 安居客前台找房页读取（v2.17 b138 重做）
//  功能：App 内 WKWebView 手机 UA 打开安居客找房页（默认 m.anjuke.com/fs/rent/?q=关键词），
//        优先读取页面内嵌 JSON-LD 结构化数据（标题/价格/面积/户型/朝向/楼层/小区/封面/详情链接），
//        JSON-LD 缺失时回退 DOM 卡片文本宽松解析；遇到验证码弹出可交互页面由用户手动过验证后继续。
//  已知约束：VM 云 IP 被安居客反爬网关拦截；真机手机网络可正常访问（用户实测过验证码后页面正常）。
//  安全：只读展示，不做任何写操作；仅用户主动点击读取。
//

import Foundation
import SwiftUI
import WebKit

// MARK: - 模型

/// 安居客找房页单套房源
struct AjkPublicHouse: Identifiable, Codable, Equatable {
    let infoid: String          // 房源 ID（详情链接里的数字）
    var title: String           // 标题
    var price: String           // 租金数字（元/月）
    var room: String            // 户型（1室1厅1卫）
    var size: String            // 面积（40.7㎡）
    var loc: String             // 区域 + 小区（顺德-龙江 利保米兰公馆）
    var floor: String           // 楼层（22/24层）
    var toward: String          // 朝向（朝南）
    var tag: String             // 出租方式（整租/合租）
    var coverURL: String        // 封面图
    var coverPath: String?      // 封面本地文件名
    let href: String            // 详情链接
    /// 兼容旧字段名（老视图/兜底解析用）
    var area: String { [room, size].filter { !$0.isEmpty }.joined(separator: " ") }

    var id: String { infoid }
    var priceValue: Int? { Int(price.filter { $0.isNumber }) }
}

/// 安居客找房设置（UserDefaults 持久化，可在房源排名设置页修改）
struct AjkPublicSettings: Codable, Equatable {
    /// v2.17：旧的小区 ID 链接（facet_comm_id）已失效，会返回佛山全城房源；改用 m 站关键词搜索入口
    static let defaultURL = "https://m.anjuke.com/fs/rent/?q=%E5%88%A9%E4%BF%9D%E7%B1%B3%E5%85%B0%E5%85%AC%E9%A6%86"
    var url: String = AjkPublicSettings.defaultURL
    var keyword: String = "利保米兰公馆"
    static let `default` = AjkPublicSettings()
}

/// 一次抓取的结果
struct AjkFetchResult {
    var houses: [AjkPublicHouse] = []
    var needVerify: Bool = false
    var error: String = ""
}

// MARK: - 本地存储

@MainActor
final class AjkPublicStore: ObservableObject {
    static let shared = AjkPublicStore()

    @Published var houses: [AjkPublicHouse] = []
    @Published var lastFetch: Date?
    @Published var lastError: String?
    @Published var loading = false
    /// v2.17：安居客弹验证码，等用户手动过验证
    @Published var needVerify = false
    @Published var settingsURL = AjkPublicSettings.default.url
    @Published var settingsKeyword = AjkPublicSettings.default.keyword

    private let defaults = UserDefaults.standard

    private init() {
        // v2.17：旧的精选页/小区ID链接自动迁移到关键词入口（旧参数会让页面退回全城房源）
        let legacyURLs = [
            "https://fs.zu.anjuke.com/?kw=%E5%88%A9%E4%BF%9D%E7%B1%B3%E5%85%B0%E5%85%AC%E9%A6%86&comm_exist=on&from=list_ac&facet_comm_id=102286650",
            "https://fs.zu.anjuke.com/?t=1&from=0&comm_exist=on&kw=%E5%88%A9%E4%BF%9D%E7%B1%B3%E5%85%B0%E5%85%AC%E9%A6%86"
        ]
        var savedURL = defaults.string(forKey: "ajk.public.url")
        if let s = savedURL, legacyURLs.contains(s) || s.contains("facet_comm_id") {
            savedURL = AjkPublicSettings.defaultURL
            defaults.set(savedURL, forKey: "ajk.public.url")
        }
        settingsURL = savedURL ?? AjkPublicSettings.defaultURL
        settingsKeyword = defaults.string(forKey: "ajk.public.keyword") ?? AjkPublicSettings.default.keyword
    }

    /// 抓取关键词过滤 token——含「米兰」时用「米兰」（利保米兰公馆/米兰公馆都命中）
    var filterToken: String {
        let kw = settingsKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if kw.isEmpty { return "" }
        return kw.contains("米兰") ? "米兰" : kw
    }

    func saveSettings() {
        defaults.set(settingsURL, forKey: "ajk.public.url")
        defaults.set(settingsKeyword, forKey: "ajk.public.keyword")
    }

    /// v2.17：发起读取（不阻塞 UI；验证码需要人工时弹窗）
    func fetch() async {
        guard !loading else { return }
        loading = true
        needVerify = false
        lastError = nil
        let provider = AjkPublicWebViewProvider.shared
        provider.onNeedVerify = { [weak self] in
            self?.loading = false
            self?.needVerify = true
        }
        provider.startFetch(urlString: settingsURL) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.apply(result)
            }
        }
    }

    /// v2.17：用户在弹窗里过完验证码后继续读取
    func continueAfterVerify() async {
        needVerify = false
        loading = true
        AjkPublicWebViewProvider.shared.onNeedVerify = { [weak self] in
            self?.loading = false
            self?.needVerify = true
        }
        AjkPublicWebViewProvider.shared.resumeAfterVerify { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.apply(result)
            }
        }
    }

    private func apply(_ result: AjkFetchResult) {
        loading = false
        if result.needVerify {
            needVerify = true
            return
        }
        if !result.error.isEmpty {
            lastError = result.error
            return
        }
        houses = result.houses
        lastFetch = Date()
        lastError = nil
        downloadCovers()
    }

    // MARK: - 缩略图（与 58 同机制）

    static var coversDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AjkPublic", isDirectory: true)
            .appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func coverFileURL(for infoid: String) -> URL {
        coversDirectory.appendingPathComponent("\(infoid).jpg")
    }

    func coverLocalPath(for infoid: String) -> String? {
        let url = Self.coverFileURL(for: infoid)
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    private func downloadCovers() {
        let toDownload = houses.filter {
            !$0.coverURL.isEmpty && !FileManager.default.fileExists(atPath: Self.coverFileURL(for: $0.infoid).path)
        }
        guard !toDownload.isEmpty else { return }
        let dir = Self.coversDirectory
        Task.detached {
            for house in toDownload {
                guard let url = URL(string: house.coverURL) else { continue }
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    try data.write(to: dir.appendingPathComponent("\(house.infoid).jpg"), options: .atomic)
                    await MainActor.run { self.objectWillChange.send() }
                } catch {
                    // 单张失败静默，保持无图占位
                }
            }
        }
    }

    // MARK: - 概览

    var avgPrice: Int? {
        let p = houses.compactMap { $0.priceValue }
        guard !p.isEmpty else { return nil }
        return p.reduce(0, +) / p.count
    }

    var maxPrice: Int? { houses.compactMap { $0.priceValue }.max() }
}

// MARK: - 抓取 Provider

@MainActor
final class AjkPublicWebViewProvider: NSObject, WKNavigationDelegate {

    static let shared = AjkPublicWebViewProvider()

    /// 手机 UA：安居客对手机浏览器风控相对宽松
    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 需要人工过验证码时回调（UI 弹窗展示当前页面）
    var onNeedVerify: (() -> Void)?
    /// 供弹窗展示的当前页面（用户在这里点验证码）
    private(set) var verifyWebView: WKWebView?

    private var webView: WKWebView?
    private var completion: ((AjkFetchResult) -> Void)?
    private var captchaWaiting = false
    private var timeoutWork: DispatchWorkItem?
    private var housesJSONLD: [AjkPublicHouse] = []
    private var housesDOM: [AjkPublicHouse] = []
    private var didConsumeJSONLD = false

    // MARK: 对外

    func startFetch(urlString: String, completion: @escaping (AjkFetchResult) -> Void) {
        self.completion = completion
        housesJSONLD = []
        housesDOM = []
        didConsumeJSONLD = false
        captchaWaiting = false
        let cleaned = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleaned) else {
            finish(AjkFetchResult(error: "安居客链接无效，请在设置里检查"))
            return
        }
        reload(url)
    }

    /// 用户过完验证码后继续
    func resumeAfterVerify(completion: @escaping (AjkFetchResult) -> Void) {
        self.completion = completion
        guard let wv = webView else {
            finish(AjkFetchResult(error: "页面已关闭，请重新点「读取」"))
            return
        }
        captchaWaiting = false
        scheduleTimeout(30)
        runScrape(on: wv)
    }

    // MARK: 内部

    private func reload(_ url: URL) {
        if let old = webView {
            old.stopLoading()
            old.configuration.userContentController.removeScriptMessageHandler(forName: "ajkPublicScrape")
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent = Self.mobileUA
        wv.configuration.userContentController.add(self, name: "ajkPublicScrape")
        webView = wv
        verifyWebView = wv
        wv.load(URLRequest(url: url))
        scheduleTimeout(35)
    }

    private func scheduleTimeout(_ seconds: Double) {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.captchaWaiting else { return }
            self.finish(AjkFetchResult(error: "页面加载超时，请检查网络后重试"))
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func finish(_ result: AjkFetchResult) {
        timeoutWork?.cancel()
        timeoutWork = nil
        if let wv = webView {
            wv.stopLoading()
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "ajkPublicScrape")
        }
        webView = nil
        verifyWebView = nil
        let c = completion
        completion = nil
        c?(result)
    }

    // MARK: 导航回调

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !captchaWaiting else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.captchaWaiting else { return }
            self.runScrape(on: webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !captchaWaiting else { return }
        finish(AjkFetchResult(error: "页面加载失败：\(error.localizedDescription)"))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !captchaWaiting else { return }
        finish(AjkFetchResult(error: "页面加载失败：\(error.localizedDescription)"))
    }

    // MARK: - JS：优先读 JSON-LD，兜底扫描卡片文本

    private func runScrape(on webView: WKWebView) {
        let js = """
        (async function(){
          function sleep(ms){ return new Promise(function(r){ setTimeout(r, ms); }); }
          function norm(s){ return (s||'').replace(/\\s+/g,' ').trim(); }
          // 验证码/反爬网关检测
          var bodyText = norm((document.body && (document.body.innerText || document.body.textContent)) || '');
          var titleText = norm(document.title || '');
          var hrefNow = location.href || '';
          if (bodyText.indexOf('请输入验证码') >= 0 || bodyText.indexOf('访问过于频繁') >= 0 ||
              bodyText.indexOf('安全验证') >= 0 || bodyText.indexOf('人机验证') >= 0 ||
              titleText.indexOf('请输入验证码') >= 0 || titleText.indexOf('验证码') >= 0 ||
              hrefNow.indexOf('antibot') >= 0 || hrefNow.indexOf('verifycode') >= 0 ||
              (document.getElementById && document.getElementById('@@xxzlGatewayUrl'))) {
            window.webkit.messageHandlers.ajkPublicScrape.postMessage(JSON.stringify({type:'captcha', text: titleText}));
            return;
          }
          // 等页面把列表/结构化数据渲染出来（最多 8 秒）
          var waited = 0;
          while (waited < 8000) {
            if (document.querySelector('script[type="application/ld+json"]') ||
                document.querySelector('[class*="rent"]') ||
                document.querySelector('[class*="house"]')) break;
            await sleep(400); waited += 400;
          }
          // 1) JSON-LD 结构化清单
          var blocks = [];
          var sc = document.querySelectorAll('script[type="application/ld+json"]');
          for (var i = 0; i < sc.length; i++) {
            var raw = '';
            try { raw = sc[i].textContent || ''; } catch(e) { raw = ''; }
            if (raw && raw.indexOf('itemListElement') >= 0) blocks.push(raw);
          }
          if (blocks.length > 0) {
            window.webkit.messageHandlers.ajkPublicScrape.postMessage(JSON.stringify({type:'jsonld', blocks: blocks}));
          }
          // 2) DOM 卡片兜底（JSON-LD 没有时才有用）
          var cards = [];
          var seen = {};
          function pushCard(text, href){
            text = norm(text || '');
            if (text.length < 8 || !href) return;
            if (seen[href]) return;
            seen[href] = 1;
            cards.push({text: text.slice(0, 800), href: href});
          }
          var containers = document.querySelectorAll('[class*="rent-item"], [class*="house-item"], [class*="list-item"], [class*="zu-item"], li[class*="item"], a[class*="item"]');
          for (var k = 0; k < containers.length; k++) {
            var el = containers[k];
            var text = norm(el.innerText || '');
            if (text.indexOf('元/月') < 0) continue;
            var a = el.querySelector('a[href*="rent/"]') || el.querySelector('a[href*="zufang"]') || (el.tagName === 'A' ? el : null);
            if (!a) continue;
            var href = a.href || a.getAttribute('href') || '';
            pushCard(text, href);
            if (cards.length >= 60) break;
          }
          if (cards.length === 0) {
            var allA = document.querySelectorAll('a');
            for (var j = 0; j < allA.length; j++) {
              var aa = allA[j];
              var h2 = aa.href || aa.getAttribute('href') || '';
              var t2 = norm(aa.innerText || '');
              if (t2.indexOf('元/月') < 0) continue;
              if (h2.indexOf('rent/') < 0 && h2.indexOf('zufang') < 0 && h2.indexOf('anjuke') < 0) continue;
              var box = aa;
              for (var up = 0; up < 3 && box.parentElement; up++) {
                box = box.parentElement;
                if (norm(box.innerText || '').length > 30) break;
              }
              pushCard(norm(box.innerText || ''), h2);
              if (cards.length >= 60) break;
            }
          }
          window.webkit.messageHandlers.ajkPublicScrape.postMessage(JSON.stringify({type:'page', cards: cards.slice(0, 60)}));
          window.webkit.messageHandlers.ajkPublicScrape.postMessage(JSON.stringify({type:'done'}));
        })();
        void 0;
        """
        webView.evaluateJavaScript(js) { [weak self] _, error in
            guard let self else { return }
            if let error = error {
                Task { @MainActor in
                    self.finish(AjkFetchResult(error: "脚本执行失败：\(error.localizedDescription)"))
                }
            }
        }
    }
}

extension AjkPublicWebViewProvider: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "ajkPublicScrape",
              let body = message.body as? String,
              let dict = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let type = dict["type"] as? String else { return }

        // 验证码：交给 UI 弹窗，用户在这里手动过验证；不自动重试、不判失败
        if type == "captcha" {
            guard completion != nil else { return }
            captchaWaiting = true
            timeoutWork?.cancel()
            verifyWebView = webView
            onNeedVerify?()
            return
        }

        if type == "jsonld" {
            guard let blocks = dict["blocks"] as? [String] else { return }
            var parsed: [AjkPublicHouse] = []
            for b in blocks { parsed.append(contentsOf: AjkPublicParser.parseJSONLD(b)) }
            if !parsed.isEmpty {
                housesJSONLD = parsed
                didConsumeJSONLD = true
            }
            return
        }

        if type == "page" {
            guard let arr = dict["cards"] as? [[String: Any]] else { return }
            let token = AjkPublicStore.shared.filterToken
            for obj in arr {
                guard let text = obj["text"] as? String,
                      let href = obj["href"] as? String else { continue }
                if !token.isEmpty && !text.contains(token) { continue }
                guard let house = AjkPublicParser.parse(text, href: href) else { continue }
                if !housesDOM.contains(where: { $0.href == house.href }) {
                    housesDOM.append(house)
                }
            }
            return
        }

        if type == "done" {
            // JSON-LD 优先；没有结构化数据时用 DOM 兜底
            var result = AjkFetchResult()
            if didConsumeJSONLD && !housesJSONLD.isEmpty {
                result.houses = housesJSONLD
            } else {
                result.houses = housesDOM
            }
            // 本地按关键词再过滤一遍（JSON-LD 来自搜索页，正常已只有目标小区）
            let token = AjkPublicStore.shared.filterToken
            if !token.isEmpty {
                let filtered = result.houses.filter { ($0.loc + $0.title).contains(token) }
                if !filtered.isEmpty { result.houses = filtered }
            }
            if result.houses.isEmpty {
                result.error = "未解析到「\(AjkPublicStore.shared.settingsKeyword)」房源（页面可能是全城列表、结构变化或被风控拦截）。可在设置里更换链接后重试"
            }
            finish(result)
        }
    }
}

// MARK: - 解析

enum AjkPublicParser {

    /// 读取 JSON-LD（安居客 m 站列表页自带 ItemList 结构化清单，字段最全、页面改版也不容易崩）
    static func parseJSONLD(_ raw: String) -> [AjkPublicHouse] {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["itemListElement"] as? [[String: Any]] else { return [] }
        var out: [AjkPublicHouse] = []
        for it in items {
            let name = (it["name"] as? String) ?? ""
            let href = (it["url"] as? String) ?? ""
            var cover = (it["image"] as? String) ?? ""
            if cover.isEmpty, let imgs = it["image"] as? [Any] {
                cover = (imgs.first as? String) ?? ""
            }
            var price = ""
            if let offers = it["offers"] as? [String: Any] {
                if let p = offers["price"] as? String { price = p.filter { $0.isNumber } }
                else if let p = offers["price"] as? Int { price = String(p) }
                else if let p = offers["price"] as? Double { price = String(Int(p)) }
            }
            guard !price.isEmpty, !href.isEmpty else { continue }
            var props: [String: String] = [:]
            if let arr = it["additionalProperty"] as? [[String: Any]] {
                for p in arr {
                    guard let k = p["name"] as? String else { continue }
                    if let v = p["value"] as? String { props[k] = v }
                    else if let v = p["value"] as? Int { props[k] = String(v) }
                    else if let v = p["value"] as? Double { props[k] = String(v) }
                }
            }
            let comm = props["小区"] ?? ""
            let region = props["区域"] ?? props["商圈"] ?? ""
            let loc = [region, comm].filter { !$0.isEmpty }.joined(separator: " ")
            let infoid = firstCapture(href, pattern: #"/rent/(\d+)"#)
                ?? firstCapture(href, pattern: #"(\d{8,})"#)
                ?? href
            out.append(AjkPublicHouse(
                infoid: infoid,
                title: name,
                price: price,
                room: props["户型"] ?? "",
                size: (props["面积"] ?? "").replacingOccurrences(of: "平米", with: "㎡"),
                loc: loc,
                floor: props["楼层"] ?? "",
                toward: props["朝向"] ?? "",
                tag: props["出租方式"] ?? props["租赁方式"] ?? "",
                coverURL: cover,
                coverPath: nil,
                href: href
            ))
        }
        return out
    }

    /// DOM 卡片文本兜底解析（JSON-LD 缺失时用）
    static func parse(_ text: String, href: String) -> AjkPublicHouse? {
        guard let priceMatch = firstCapture(text, pattern: #"\d+\s*元/月"#),
              let priceDigits = firstCapture(priceMatch, pattern: #"\d+"#),
              Int(priceDigits) != nil else { return nil }

        var rest = text
        if let r = rest.range(of: #"\d+\s*元/月"#, options: .regularExpression) {
            rest = String(rest[..<r.lowerBound]) + " " + String(rest[r.upperBound...])
        }

        var loc = ""
        for seg in rest.components(separatedBy: "|").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            if seg.contains("米兰") || seg.contains("公馆") || seg.contains("区") {
                loc = seg
                break
            }
        }
        if loc.isEmpty, let m = firstCapture(rest, pattern: #"[\u4e00-\u9fa5]{2,}(?:区|公馆|公寓|花园|小区)[^\s，,。]{0,12}"#) {
            loc = m
        }

        var room = ""
        if let m = firstCapture(rest, pattern: #"\d+\s*室\d*\s*厅?\d*\s*卫?"#) { room = m.replacingOccurrences(of: " ", with: "") }
        var size = ""
        if let m = firstCapture(rest, pattern: #"[\d.]+\s*(?:㎡|平米)"#) { size = m.replacingOccurrences(of: "平米", with: "㎡").replacingOccurrences(of: " ", with: "") }

        var title = rest
        for seg in [loc, room, size] where !seg.isEmpty {
            title = title.replacingOccurrences(of: seg, with: "")
        }
        title = title.components(separatedBy: " ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count >= 4 && !$0.contains("元") }
            .prefix(2)
            .joined(separator: " ")
        if title.isEmpty { title = String(rest.prefix(30)) }

        var fullHref = href
        if fullHref.hasPrefix("/") { fullHref = "https://m.anjuke.com" + fullHref }
        let infoid = firstCapture(fullHref, pattern: #"/rent/(\d+)"#)
            ?? firstCapture(fullHref, pattern: #"(\d{8,})"#)
            ?? fullHref
        return AjkPublicHouse(
            infoid: infoid, title: title, price: priceDigits,
            room: room, size: size, loc: loc,
            floor: "", toward: "", tag: "",
            coverURL: "", coverPath: nil, href: fullHref
        )
    }

    static func firstCapture(_ s: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1 <= m.numberOfRanges - 1 ? 1 : 0)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 安居客读取错误
enum AjkPublicError: LocalizedError {
    case msg(String)
    var errorDescription: String? {
        switch self {
        case .msg(let m): return m
        }
    }
}
