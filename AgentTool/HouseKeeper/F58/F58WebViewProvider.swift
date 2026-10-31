//
//  F58WebViewProvider.swift
//  公寓管家 · 58同城找房列表抓取（v1.99 b105）
//  方案：WKWebView 桌面 UA 加载 58 列表页（reform=pcfront PC 前端，实测无验证码、卡片含经纪人字段）
//       → 注入 JS 收集第一页房源卡片（标题/缩略图/价格/经纪人/详情链接）→ Swift 解析入库
//  安全边界：仅用户主动触发抓取；只读 58 公开租房列表页；绝不做任何写操作；只抓第一页约 40 条
//

import Foundation
import WebKit

@MainActor
final class F58WebViewProvider: NSObject, WKNavigationDelegate {

    static let shared = F58WebViewProvider()

    /// 抓取结果
    struct FetchResult {
        var houses: [F58House] = []
        var needCaptcha: Bool = false
        var error: String = ""
    }

    /// 桌面 UA：58 对手机 UA 返回 m 站（无经纪人字段）；桌面 UA + reform=pcfront 返回 PC 前端（含经纪人，实测无验证码墙）
    private static let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<FetchResult, Error>?
    private var pendingHouses: [F58House] = []

    // MARK: - 公开入口：抓取第一页（当前设置 URL）

    func fetchFirstPage(urlString: String) async throws -> FetchResult {
        pendingHouses = []
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<FetchResult, Error>) in
            self.continuation = cont
            let config = WKWebViewConfiguration()
            // 持久数据存储：与安居客一致，保存 58 cookie（58 详情/验证码校验依赖会话）
            config.websiteDataStore = .default()
            let wv = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 844), configuration: config)
            wv.navigationDelegate = self
            // 桌面 UA 强制 PC 前端
            wv.customUserAgent = Self.desktopUA
            let controller = wv.configuration.userContentController
            controller.add(self, name: "f58Scrape")
            self.webView = wv
            guard let url = URL(string: urlString) else {
                self.continuation = nil
                cont.resume(returning: FetchResult(error: "列表页 URL 无效，请在设置里检查"))
                return
            }
            wv.load(URLRequest(url: url))
            // 兜底超时（页面卡死/网络异常/验证码需人工处理时恢复）
            DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
                if let c = self.continuation {
                    self.continuation = nil
                    self.webView?.stopLoading()
                    self.webView = nil
                    c.resume(throwing: F58Error.msg("页面加载超时，请检查网络后重试"))
                }
            }
        }
    }

    // MARK: - 导航回调

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 等待 PC 前端渲染后注入抓取脚本
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.runScrape(on: webView)
        }
    }

    // MARK: - 注入 JS：收集第一页房源卡片

    private func runScrape(on webView: WKWebView) {
        let js = """
        (async function(){
          function sleep(ms){ return new Promise(function(r){ setTimeout(r, ms); }); }
          function norm(s){ return (s||'').replace(/\\s+/g,' ').trim(); }
          // 等待 PC 前端渲染出房源卡片（最多 15 秒，防抓空）
          var waited = 0;
          while (waited < 15000) {
            if (document.querySelector('li.house-cell')) break;
            await sleep(500); waited += 500;
          }
          // 验证码墙检测（58 风控偶发；命中时交给用户人工处理，不硬抓）
          var bodyText = norm((document.body && (document.body.innerText || document.body.textContent)) || '');
          var titleText = norm(document.title || '');
          if (bodyText.indexOf('请输入验证码') >= 0 || titleText.indexOf('验证码') >= 0) {
            window.webkit.messageHandlers.f58Scrape.postMessage(JSON.stringify({type:'captcha', text: titleText}));
            return;
          }
          // 收集卡片：li.house-cell（PC 前端列表结构，字段实测确认）
          var cards = [];
          var lis = document.querySelectorAll('li.house-cell');
          for (var i = 0; i < lis.length; i++) {
            var li = lis[i];
            var aT = li.querySelector('.des h2 a');
            if (!aT) continue;
            var href = aT.getAttribute('href') || '';
            var mm = href.match(/zufang\\/(\\d+)x\\.shtml/);
            var infoid = mm ? mm[1] : '';
            var img = li.querySelector('.img-list img');
            var cover = '';
            if (img) {
              cover = img.getAttribute('lazy_src') || img.getAttribute('data-src') || img.getAttribute('src') || '';
              if (cover.indexOf('lazy_pic.png') >= 0) cover = '';
            }
            var dp = li.querySelector('.jjr_par_dp');
            var jjr = li.querySelector('.listjjr');
            var money = li.querySelector('.money b');
            var room = li.querySelector('.room');
            var infor = li.querySelector('.infor');
            var tip = li.querySelector('.ax-tip');
            var ad = li.querySelector('.ad-icon');
            // 姓名清洗：去掉「X日内实拍验真/实拍验真」等徽标杂质
            var name = jjr ? norm(jjr.innerText) : '';
            name = name.replace(/\\d+日内?实拍验真/g, '').replace(/实拍验真/g, '').trim();
            cards.push({
              infoid: infoid,
              title: norm(aT.innerText),
              href: href,
              cover: cover,
              price: money ? norm(money.innerText) : '',
              room: room ? norm(room.innerText) : '',
              loc: infor ? norm(infor.innerText) : '',
              agentDp: dp ? norm(dp.innerText) : '',
              agentName: name,
              tip: tip ? norm(tip.innerText) : '',
              ad: ad ? norm(ad.innerText) : ''
            });
          }
          // 只取第一页前 40 条（用户口径：每次约 40 条；PC 前端 DOM 会渲染更多卡片）
          cards = cards.slice(0, 40);
          window.webkit.messageHandlers.f58Scrape.postMessage(JSON.stringify({type:'page', cards: cards, page: 1}));
          window.webkit.messageHandlers.f58Scrape.postMessage(JSON.stringify({type:'done', total: cards.length, error:''}));
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

extension F58WebViewProvider: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "f58Scrape",
              let body = message.body as? String,
              let dict = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let type = dict["type"] as? String else { return }

        if type == "captcha" {
            guard let c = continuation else { return }
            continuation = nil
            userContentController.removeScriptMessageHandler(forName: "f58Scrape")
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
                let house = F58House(
                    infoid: (obj["infoid"] as? String) ?? "",
                    title: (obj["title"] as? String) ?? "",
                    href: (obj["href"] as? String) ?? "",
                    coverURL: (obj["cover"] as? String) ?? "",
                    coverPath: nil,
                    price: (obj["price"] as? String) ?? "",
                    room: (obj["room"] as? String) ?? "",
                    loc: (obj["loc"] as? String) ?? "",
                    agentDp: (obj["agentDp"] as? String) ?? "",
                    agentName: (obj["agentName"] as? String) ?? "",
                    tip: (obj["tip"] as? String) ?? "",
                    ad: (obj["ad"] as? String) ?? ""
                )
                if !house.infoid.isEmpty {
                    pendingHouses.append(house)
                }
            }
            return
        }

        if type == "done" {
            guard let c = continuation else { return }
            continuation = nil
            userContentController.removeScriptMessageHandler(forName: "f58Scrape")
            webView?.stopLoading()
            webView = nil
            var result = FetchResult()
            result.houses = pendingHouses
            c.resume(returning: result)
        }
    }
}

/// 抓取错误
enum F58Error: LocalizedError {
    case msg(String)
    var errorDescription: String? {
        switch self {
        case .msg(let m): return m
        }
    }
}
