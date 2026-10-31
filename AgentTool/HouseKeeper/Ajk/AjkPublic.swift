//
//  AjkPublic.swift
//  公寓管家 · 安居客前台找房页读取（v2.2 b109）
//  功能：App 内 WKWebView 手机 UA 打开用户提供的安居客找房链接（如 fs.zu.anjuke.com 精选页），
//       注入 JS 收集第一页房源卡片文本 → Swift 宽松正则解析（标题/价格/位置/面积）→ 可点击跳详情
//  已知约束：VM 云 IP 实测被安居客/58 反爬网关拦截（antibot verifycode）；App 内走用户手机网络大概率放行
//       （与 58 m 站同理）。代码做可失败降级：弹验证码自动重试一次，仍失败提示稍后重试，不阻塞双 tab。
//  安全：只读展示，不做任何写操作；仅用户主动点击读取；只抓第一页
//

import Foundation
import SwiftUI
import WebKit

// MARK: - 模型

/// 安居客前台找房页单套房源（宽松文本解析）
struct AjkPublicHouse: Identifiable, Codable, Equatable {
    var id: String { href }
    let title: String   // 标题（户型/面积或小区名）
    let price: String   // 租金（元/月 数字）
    let loc: String     // 位置（区域-小区）
    let area: String    // 户型/面积
    let href: String    // 详情链接（跳转浏览器打开）
}

/// 安居客前台找房设置（UserDefaults 持久化，可在设置页修改）
struct AjkPublicSettings: Codable, Equatable {
    /// 默认：利保米兰公馆精选页（用户提供）
    var url: String = "https://fs.zu.anjuke.com/?t=1&from=0&comm_exist=on&kw=%E5%88%A9%E4%BF%9D%E7%B1%B3%E5%85%B0%E5%85%AC%E9%A6%86"
    var keyword: String = "利保米兰公馆"
    static let `default` = AjkPublicSettings()
}

// MARK: - 本地存储

@MainActor
final class AjkPublicStore: ObservableObject {
    static let shared = AjkPublicStore()

    @Published var houses: [AjkPublicHouse] = []
    @Published var lastFetch: Date?
    @Published var lastError: String?
    @Published var loading = false
    @Published var settingsURL = AjkPublicSettings.default.url
    @Published var settingsKeyword = AjkPublicSettings.default.keyword

    private let defaults = UserDefaults.standard

    private init() {
        settingsURL = defaults.string(forKey: "ajk.public.url") ?? AjkPublicSettings.default.url
        settingsKeyword = defaults.string(forKey: "ajk.public.keyword") ?? AjkPublicSettings.default.keyword
    }

    func saveSettings() {
        defaults.set(settingsURL, forKey: "ajk.public.url")
        defaults.set(settingsKeyword, forKey: "ajk.public.keyword")
    }

    func fetch() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await AjkPublicWebViewProvider.shared.fetch(urlString: settingsURL)
            if result.needCaptcha {
                lastError = "安居客弹出验证码校验。请稍后重试；若反复出现，可到手机上打开该链接确认可访问，或在设置里更换链接。"
                return
            }
            if !result.error.isEmpty {
                lastError = result.error
                return
            }
            houses = result.houses
            lastFetch = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

// MARK: - 抓取 Provider（WKWebView 手机 UA + JS 收集 + 宽松解析）

@MainActor
final class AjkPublicWebViewProvider: NSObject, WKNavigationDelegate {

    static let shared = AjkPublicWebViewProvider()

    struct FetchResult {
        var houses: [AjkPublicHouse] = []
        var needCaptcha: Bool = false
        var error: String = ""
    }

    /// 手机 UA：安居客对手机浏览器风控相对宽松（与 58 m 站同理；桌面 UA + 云 IP 实测必弹验证码）
    private static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<FetchResult, Error>?
    private var retriedCaptcha = false
    private var lastLoadedURL = ""
    private var pendingHouses: [AjkPublicHouse] = []

    func fetch(urlString: String) async throws -> FetchResult {
        pendingHouses = []
        retriedCaptcha = false
        let cleaned = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<FetchResult, Error>) in
            self.continuation = cont
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            let wv = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 844), configuration: config)
            wv.navigationDelegate = self
            wv.customUserAgent = Self.mobileUA
            wv.configuration.userContentController.add(self, name: "ajkPublicScrape")
            self.webView = wv
            guard let url = URL(string: cleaned) else {
                self.continuation = nil
                cont.resume(returning: FetchResult(error: "安居客链接无效，请在设置里检查"))
                return
            }
            self.lastLoadedURL = cleaned
            wv.load(URLRequest(url: url))
            DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
                if let c = self.continuation {
                    self.continuation = nil
                    self.webView?.stopLoading()
                    self.webView = nil
                    c.resume(throwing: AjkPublicError.msg("页面加载超时，请检查网络后重试"))
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.runScrape(on: webView)
        }
    }

    // MARK: - JS：收集第一页卡片文本

    private func runScrape(on webView: WKWebView) {
        let js = """
        (async function(){
          function sleep(ms){ return new Promise(function(r){ setTimeout(r, ms); }); }
          function norm(s){ return (s||'').replace(/\\s+/g,' ').trim(); }
          // 等待列表卡片渲染（安居客 PC 精选页：.zu-itemmod / .list-item；兜底宽泛选择器；最多 15 秒）
          var waited = 0;
          while (waited < 15000) {
            if (document.querySelector('.zu-itemmod') || document.querySelector('.list-item') ||
                document.querySelector('[class*="zu-item"]') || document.querySelector('[class*="house-list"] li')) break;
            await sleep(500); waited += 500;
          }
          // 验证码/反爬网关检测
          var bodyText = norm((document.body && (document.body.innerText || document.body.textContent)) || '');
          var titleText = norm(document.title || '');
          var hrefNow = location.href || '';
          if (bodyText.indexOf('请输入验证码') >= 0 || titleText.indexOf('验证码') >= 0 ||
              hrefNow.indexOf('antibot') >= 0 || hrefNow.indexOf('verifycode') >= 0) {
            window.webkit.messageHandlers.ajkPublicScrape.postMessage(JSON.stringify({type:'captcha', text: titleText}));
            return;
          }
          var containers = document.querySelectorAll('.zu-itemmod, .list-item, li.item, [class*="zu-item"], [class*="list-item"], .house-list li');
          var cards = [];
          var seen = {};
          for (var i = 0; i < containers.length; i++) {
            var el = containers[i];
            var text = norm(el.innerText || '');
            if (text.length < 8) continue;
            var a = el.querySelector('a[href*="zufang"]') || (el.tagName === 'A' ? el : null);
            if (!a) continue;
            var href = a.href || a.getAttribute('href') || '';
            if (href.indexOf('zufang') < 0) continue;
            if (seen[href]) continue;
            seen[href] = 1;
            cards.push({text: text.slice(0, 800), href: href});
          }
          window.webkit.messageHandlers.ajkPublicScrape.postMessage(JSON.stringify({type:'page', cards: cards.slice(0, 60)}));
          window.webkit.messageHandlers.ajkPublicScrape.postMessage(JSON.stringify({type:'done', total: cards.length, error:''}));
        })();
        void 0;
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                Task { @MainActor in
                    self.finish(error: "脚本执行失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func finish(error: String) {
        guard let c = continuation else { return }
        continuation = nil
        webView?.stopLoading()
        webView = nil
        var result = FetchResult()
        result.error = error
        c.resume(returning: result)
    }
}

extension AjkPublicWebViewProvider: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "ajkPublicScrape",
              let body = message.body as? String,
              let dict = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let type = dict["type"] as? String else { return }

        if type == "captcha" {
            guard let c = continuation else { return }
            if !retriedCaptcha, let url = URL(string: lastLoadedURL) {
                retriedCaptcha = true
                userContentController.removeScriptMessageHandler(forName: "ajkPublicScrape")
                webView?.stopLoading()
                webView = nil
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .default()
                let wv2 = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 844), configuration: config)
                wv2.navigationDelegate = self
                wv2.customUserAgent = Self.mobileUA
                wv2.configuration.userContentController.add(self, name: "ajkPublicScrape")
                self.webView = wv2
                wv2.load(URLRequest(url: url))
                DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
                    if let cc = self.continuation {
                        self.continuation = nil
                        self.webView?.stopLoading()
                        self.webView = nil
                        cc.resume(throwing: AjkPublicError.msg("页面加载超时，请检查网络后重试"))
                    }
                }
                return
            }
            continuation = nil
            userContentController.removeScriptMessageHandler(forName: "ajkPublicScrape")
            webView?.stopLoading()
            webView = nil
            var result = FetchResult()
            result.needCaptcha = true
            c.resume(returning: result)
            return
        }

        if type == "page" {
            guard let arr = dict["cards"] as? [[String: Any]] else { return }
            for obj in arr {
                guard let text = obj["text"] as? String,
                      let href = obj["href"] as? String,
                      let house = AjkPublicParser.parse(text, href: href) else { continue }
                if !pendingHouses.contains(where: { $0.href == house.href }) {
                    pendingHouses.append(house)
                }
            }
            return
        }

        if type == "done" {
            guard let c = continuation else { return }
            continuation = nil
            userContentController.removeScriptMessageHandler(forName: "ajkPublicScrape")
            webView?.stopLoading()
            webView = nil
            var result = FetchResult()
            result.houses = pendingHouses
            c.resume(returning: result)
        }
    }
}

// MARK: - 宽松文本解析
// 安居客前台页 DOM 未能在 VM 实证（云 IP 被反爬拦截），按文本模式解析：
// 卡片文本形如「整租·1室1厅 40.69㎡ | 龙江-利保米兰公馆 1100元/月」，
// 用价格锚点 + 关键词/区域模式提取，页面改版时也能兜底

enum AjkPublicParser {

    static func parse(_ text: String, href: String) -> AjkPublicHouse? {
        // 价格：首个「数字 元/月」
        guard let priceMatch = firstCapture(text, pattern: #"\d+\s*元/月"#),
              let priceDigits = firstCapture(priceMatch, pattern: #"\d+"#),
              Int(priceDigits) != nil else { return nil }

        // 去掉价格段，得到其余文本
        var rest = text
        if let r = rest.range(of: #"\d+\s*元/月"#, options: .regularExpression) {
            rest = String(rest[..<r.lowerBound]) + " " + String(rest[r.upperBound...])
        }

        // 位置：含小区/区域关键词的段（利保米兰公馆、X区-X公馆 等）
        var loc = ""
        for seg in rest.components(separatedBy: "|").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            if seg.contains("米兰公馆") || seg.contains("利保") {
                loc = seg
                break
            }
        }
        if loc.isEmpty {
            if let m = firstCapture(rest, pattern: #"[\u4e00-\u9fa5]{2,}(?:区|公馆|公寓|花园|小区)[^\s，,。]{0,12}"#) {
                loc = m
            }
        }

        // 户型/面积：如「整租·1室1厅 40.69㎡」
        var area = ""
        if let m = firstCapture(rest, pattern: #"整租[^\s|]{0,20}|合租[^\s|]{0,20}"#) {
            area = m
        } else if let m = firstCapture(rest, pattern: #"\d+\s*室[^\s|]{0,12}"#) {
            area = m
        }
        if let m = firstCapture(rest, pattern: #"[\d.]+\s*㎡"#) {
            area = area.isEmpty ? m : "\(area) \(m)"
        }

        // 标题：移掉价格/位置/面积段后的主文本；取第一个 ≥4 字且含中文的段
        var title = rest
        for seg in [loc, area] where !seg.isEmpty {
            title = title.replacingOccurrences(of: seg, with: "")
        }
        title = title.components(separatedBy: " ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count >= 4 && $0.contains("元") == false }
            .prefix(2)
            .joined(separator: " ")
        if title.isEmpty {
            title = String(rest.prefix(30))
        }

        // href 归一：相对路径补安居客域名
        var fullHref = href
        if fullHref.hasPrefix("/") {
            fullHref = "https://fs.zu.anjuke.com" + fullHref
        }
        return AjkPublicHouse(title: title, price: priceDigits, loc: loc, area: area, href: fullHref)
    }

    private static func firstCapture(_ s: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 0)).trimmingCharacters(in: .whitespacesAndNewlines)
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
