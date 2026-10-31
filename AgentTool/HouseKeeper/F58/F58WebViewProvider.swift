//
//  F58WebViewProvider.swift
//  公寓管家 · 58同城找房列表抓取（v2.1 b108）
//  方案：WKWebView 手机 UA 加载 m 站手机版列表（iPhone UA + m 站 URL，58 对手机浏览器风控宽松，
//       实测不弹验证码、key 关键词生效；自动剥离 reform=pcfront——它会转 PC 站并丢弃 key 参数）
//       → 注入 JS 收集第一页房源卡片（标题/缩略图/价格/位置/详情链接）→ Swift 解析入库
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

    /// 手机 UA：58 对手机浏览器风控宽松（实测 iPhone UA 加载 m 站手机版不弹验证码、关键词 key 生效）；
    /// 注意：桌面 UA + reform=pcfront 会被 58 反爬网关拦截（iOS WebKit 平台指纹与 UA 不符 → 弹验证码），
    /// 且 reform=pcfront 转 PC 站时会丢弃 key 参数导致抓到全城房源，故统一走手机站手机版
    private static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<FetchResult, Error>?
    private var pendingHouses: [F58House] = []
    /// 验证码命中后的自动重试（58 风控偶发，重试一次常可放行；仍失败才提示用户人工处理）
    private var retriedCaptcha = false
    /// 本次实际加载的 URL（自动重试时复用）
    private var lastLoadedURL = ""

    // MARK: - 公开入口：抓取第一页（当前设置 URL）

    func fetchFirstPage(urlString: String) async throws -> FetchResult {
        pendingHouses = []
        retriedCaptcha = false
        // URL 归一：剥离 reform=pcfront（它会转 PC 站并丢弃 key 参数 → 抓到全城房源且触发反爬网关）
        var cleaned = urlString
            .replacingOccurrences(of: "&reform=pcfront", with: "")
            .replacingOccurrences(of: "?reform=pcfront", with: "")
            .replacingOccurrences(of: "&reform=pcfront&", with: "&")
        // PC 站列表 URL 归一为手机站（58 对 PC 站 URL 反爬严格，手机 UA 访问 PC 站会被 58 重定向回 m 站）
        cleaned = cleaned
            .replacingOccurrences(of: "https://sd.58.com/zufang/", with: "https://m.58.com/sd/zufang/")
            .replacingOccurrences(of: "http://sd.58.com/zufang/", with: "https://m.58.com/sd/zufang/")
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<FetchResult, Error>) in
            self.continuation = cont
            let config = WKWebViewConfiguration()
            // 持久数据存储：与安居客一致，保存 58 cookie（58 详情/验证码校验依赖会话）
            config.websiteDataStore = .default()
            let wv = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 844), configuration: config)
            wv.navigationDelegate = self
            // 手机 UA：58 对真实手机浏览器风控宽松（实测 iPhone UA 不弹验证码、key 生效）
            wv.customUserAgent = Self.mobileUA
            let controller = wv.configuration.userContentController
            controller.add(self, name: "f58Scrape")
            self.webView = wv
            guard let url = URL(string: cleaned) else {
                self.continuation = nil
                cont.resume(returning: FetchResult(error: "列表页 URL 无效，请在设置里检查"))
                return
            }
            self.lastLoadedURL = cleaned
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
        // 等待列表渲染后注入抓取脚本
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
          // 等待列表渲染出卡片（手机站 li[class*=realverify] / li.list-item，PC 前端 li.house-cell；最多 15 秒）
          var waited = 0;
          while (waited < 15000) {
            if (document.querySelector('li.house-cell') || document.querySelector('li[class*=realverify]') || document.querySelector('li.list-item')) break;
            await sleep(500); waited += 500;
          }
          // 验证码/反爬网关检测（58 风控偶发；命中时交给上层重试或人工处理，不硬抓）
          var bodyText = norm((document.body && (document.body.innerText || document.body.textContent)) || '');
          var titleText = norm(document.title || '');
          var hrefNow = location.href || '';
          if (bodyText.indexOf('请输入验证码') >= 0 || titleText.indexOf('验证码') >= 0 ||
              hrefNow.indexOf('antibot') >= 0 || hrefNow.indexOf('verifycode') >= 0 ||
              (document.getElementById && document.getElementById('@@xxzlGatewayUrl'))) {
            window.webkit.messageHandlers.f58Scrape.postMessage(JSON.stringify({type:'captcha', text: titleText}));
            return;
          }
          var cards = [];
          var lis = document.querySelectorAll('li.house-cell');
          var mobile = lis.length === 0;
          if (mobile) {
            lis = document.querySelectorAll('li[class*=realverify]');
            if (lis.length === 0) lis = document.querySelectorAll('li.list-item');
          }
          for (var i = 0; i < lis.length; i++) {
            var li = lis[i];
            var a = li.querySelector('.des h2 a') || li.querySelector('a.list-item') || li.querySelector('a');
            if (!a) continue;
            var href = a.getAttribute('href') || '';
            var mm = href.match(/zufang\\/(\\d+)x\\.shtml/);
            var infoid = mm ? mm[1] : (li.getAttribute('infoid') || '');
            if (!infoid) continue;
            var img = li.querySelector('.img-list img');
            var cover = '';
            if (img) {
              cover = img.getAttribute('lazy_src') || img.getAttribute('data-src') || img.getAttribute('src') || '';
              if (cover.indexOf('lazy_pic.png') >= 0) cover = '';
            }
            if (!cover) {
              var imgBox = li.querySelector('.list-item-img');
              if (imgBox) cover = imgBox.getAttribute('bg-src') || '';
            }
            var dp = li.querySelector('.jjr_par_dp');
            var jjr = li.querySelector('.listjjr');
            var money = li.querySelector('.money b') || li.querySelector('.list-item-info-price');
            var addrEl = li.querySelector('.room') || li.querySelector('.list-item-info-addr-text');
            var infor = li.querySelector('.infor');
            var tip = li.querySelector('.ax-tip') || li.querySelector('.list-item-img-tag');
            var ad = li.querySelector('.ad-icon');
            // 标题：PC 前端 .des h2 a；手机站 a.list-item 文本首段（去掉「安选/广告」标签）
            var title = '';
            var price = money ? norm(money.innerText).replace(/[^\\d]/g, '') : '';
            var room = '', loc = '';
            if (mobile) {
              var aText = norm(a.innerText || '');
              var lines = aText.split(' ');
              title = (lines.length > 1 ? lines[1] : lines[0]) || '';
              var addrText = addrEl ? norm(addrEl.innerText) : '';
              var sp = addrText.indexOf(' ');
              room = sp > 0 ? addrText.slice(0, sp) : addrText;
              loc = sp > 0 ? addrText.slice(sp + 1).trim() : '';
              if (!ad && aText.indexOf('广告') >= 0) ad = aText.indexOf('广告') >= 0 ? { innerText: '广告' } : null;
            } else {
              title = norm(a.innerText);
              room = addrEl ? norm(addrEl.innerText) : '';
              loc = infor ? norm(infor.innerText) : '';
            }
            // 姓名清洗：去掉「X日内实拍验真/实拍验真」等徽标杂质
            var name = jjr ? norm(jjr.innerText) : '';
            name = name.replace(/\\d+日内?实拍验真/g, '').replace(/实拍验真/g, '').trim();
            cards.push({
              infoid: infoid,
              title: title,
              href: href,
              cover: cover,
              price: price,
              room: room,
              loc: loc,
              agentDp: dp ? norm(dp.innerText) : '',
              agentName: name,
              tip: tip ? norm(tip.innerText) : '',
              ad: ad ? norm(ad.innerText) : ''
            });
          }
          // 只取第一页前 40 条（用户口径：每次约 40 条）
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
            // 58 风控偶发：自动重试一次（重建 WebView 重新加载，同一 continuation），仍失败才提示用户
            if !retriedCaptcha, let url = URL(string: lastLoadedURL) {
                retriedCaptcha = true
                userContentController.removeScriptMessageHandler(forName: "f58Scrape")
                webView?.stopLoading()
                webView = nil
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .default()
                let wv2 = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 844), configuration: config)
                wv2.navigationDelegate = self
                wv2.customUserAgent = Self.mobileUA
                wv2.configuration.userContentController.add(self, name: "f58Scrape")
                self.webView = wv2
                wv2.load(URLRequest(url: url))
                DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
                    if let cc = self.continuation {
                        self.continuation = nil
                        self.webView?.stopLoading()
                        self.webView = nil
                        cc.resume(throwing: F58Error.msg("页面加载超时，请检查网络后重试"))
                    }
                }
                return
            }
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
