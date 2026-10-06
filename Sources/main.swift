import AppKit
import WebKit

// A deliberately tiny YouTube Music shell: one window, one WKWebView, system WebKit.
// Everything heavy (Chromium, Node, plugin runtimes) is simply absent.

let homeURL = URL(string: UserDefaults.standard.string(forKey: "startURL") ?? "https://music.youtube.com/")!
let backgroundColor = NSColor(srgbRed: 3 / 255, green: 3 / 255, blue: 3 / 255, alpha: 1)

// Runs in the page before YouTube Music's own scripts.
let injectedJS = #"""
(() => {
  // Backdrop blur is re-composited on every scroll/animation frame; flat backgrounds are nearly free.
  const style = document.createElement('style');
  style.textContent = `*, *::before, *::after { -webkit-backdrop-filter: none !important; backdrop-filter: none !important; }`;
  document.documentElement.appendChild(style);

  // Keep "Are you still listening?" from pausing long sessions. Both paths are idle until needed.
  setInterval(() => { window._lact = Date.now(); }, 5 * 60 * 1000);
  document.addEventListener('pause', () => setTimeout(() => {
    const dialog = document.querySelector('ytmusic-you-there-renderer');
    if (!dialog) return;
    dialog.querySelector('button, tp-yt-paper-button, yt-button-renderer')?.click();
    document.querySelector('video')?.play();
  }, 1000), true);

  // Armed by the app once the page has grown too large: reports the next track change so the page
  // can be rebuilt on a song boundary instead of mid-song. Costs nothing until armed.
  window.__ytmLite = {
    reloadAtNextTrack() {
      if (this.armed) return;
      this.armed = true;
      const player = document.getElementById('movie_player');
      const current = player?.getVideoData?.().video_id;
      // loadedmetadata usually fires before any audio; 'playing' catches tracks that start after an ad.
      const events = ['loadedmetadata', 'playing'];
      const onTrack = () => {
        const data = player?.getVideoData?.();
        if (!data?.video_id || data.video_id === current || document.querySelector('.ad-showing')) return;
        events.forEach(e => document.removeEventListener(e, onTrack, true));
        this.armed = false;
        webkit.messageHandlers.ytmLite.postMessage({ videoId: data.video_id, playlistId: data.list || '' });
      };
      events.forEach(e => document.addEventListener(e, onTrack, true));
    }
  };
})();
"""#

// Telemetry/ad endpoints that cost wakeups and network but add nothing for a Premium listener.
// WebKit content-rule regexes don't support alternation, hence one rule per pattern.
let blockedURLPatterns = [
    #"^https?://[^/]*doubleclick\.net/"#,
    #"^https?://[^/]*googlesyndication\.com/"#,
    #"^https?://[^/]*googleadservices\.com/"#,
    #"^https?://[^/]*google-analytics\.com/"#,
    #"^https?://[^/]*googletagmanager\.com/"#,
    #"^https?://[^/]*googletagservices\.com/"#,
    #"^https?://[^/]*youtube\.com/pagead/"#,
    #"^https?://[^/]*youtube\.com/ptracking"#,
    #"^https?://[^/]*youtube\.com/api/stats/ads"#,
    #"^https?://[^/]*youtube\.com/api/stats/qoe"#,
    #"^https?://[^/]*youtube\.com/api/stats/atr"#,
]
let blocklistID = "blocklist-v1"  // bump when the patterns change so WebKit recompiles

func blocklistJSON() -> String {
    let rules = blockedURLPatterns.map { ["trigger": ["url-filter": $0], "action": ["type": "block"]] }
    return String(data: try! JSONSerialization.data(withJSONObject: rules), encoding: .utf8)!
}

// Google refuses sign-in from unknown embedded browsers, so present as the installed Safari.
func safariUserAgentSuffix() -> String {
    let version = Bundle(path: "/Applications/Safari.app")?
        .infoDictionary?["CFBundleShortVersionString"] as? String ?? "26.0"
    return "Version/\(version) Safari/605.1.15"
}

// music.youtube.com and the Google sign-in flow stay in the app; everything else goes to the browser.
func shouldOpenExternally(_ url: URL, userClick: Bool) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    guard scheme == "http" || scheme == "https" else {
        return !["about", "blob", "data", "javascript"].contains(scheme)
    }
    let host = url.host?.lowercased() ?? ""
    if host == "music.youtube.com" { return false }
    let isGoogle = host.split(separator: ".").contains("google")
        || host == "youtube.com" || host.hasSuffix(".youtube.com")
        || host.hasSuffix("gstatic.com") || host.hasSuffix("googleusercontent.com")
    if !isGoogle { return true }
    // Redirects (sign-in, consent) stay in-app; clicked links to youtube.com/help pages don't.
    let isAuth = host.hasPrefix("accounts.") || ["/signin", "/logout", "/ServiceLogin"].contains { url.path.hasPrefix($0) }
    return userClick && !isAuth
}

// integer(forKey:) accepts both `defaults write -int` values and `-key value` launch arguments.
let settings: UserDefaults = {
    let defaults = UserDefaults.standard
    defaults.register(defaults: ["hibernateMinutes": 30, "recycleAboveMB": 800])
    return defaults
}()

// With the window closed and nothing playing for this long, the web view is torn down entirely
// (its ~400 MB WebContent process exits) and rebuilt on demand. 0 disables:
//   defaults write local.ytmusic.lite hibernateMinutes -int 0
let hibernateMinutes = settings.integer(forKey: "hibernateMinutes")

// YouTube Music's page can grow over long sessions. With the window closed and the page above this
// size, it's rebuilt in a fresh process at the next track change. 0 disables:
//   defaults write local.ytmusic.lite recycleAboveMB -int 0
let recycleAboveMB = settings.integer(forKey: "recycleAboveMB")

let backgroundCheckInterval: TimeInterval = 5 * 60

// Physical footprint (what Activity Monitor shows as "Memory") of another process we own.
func footprintMB(of pid: pid_t) -> Int? {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return rc == 0 ? Int(info.ri_phys_footprint / 1_048_576) : nil
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
    WKScriptMessageHandler {
    var window: NSWindow!
    var webView: WKWebView?
    let contentController = WKUserContentController()
    var isHibernated = false
    var hibernatedURL: URL?
    var backgroundTimer: Timer?
    var idleSince: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        contentController.addUserScript(WKUserScript(source: injectedJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        contentController.add(self, name: "ytmLite")

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "YT Music"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = backgroundColor
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 360)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("Main")
        window.makeKeyAndOrderFront(nil)

        installBlocklist { [weak self] in self?.makeWebView(loading: homeURL) }
    }

    private func makeWebView(loading url: URL) {
        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.mediaTypesRequiringUserActionForPlayback = []
        config.applicationNameForUserAgent = safariUserAgentSuffix()
        config.preferences.isElementFullscreenEnabled = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = backgroundColor
        // Avoid a white flash before the (dark) page paints.
        if webView.responds(to: Selector(("setDrawsBackground:"))) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        window.contentView = webView
        webView.load(URLRequest(url: url))
        self.webView = webView
    }

    private func installBlocklist(then done: @escaping () -> Void) {
        guard let store = WKContentRuleListStore.default() else { return done() }
        store.lookUpContentRuleList(forIdentifier: blocklistID) { [weak self] cached, _ in
            if let cached {
                self?.contentController.add(cached)
                return done()
            }
            store.compileContentRuleList(forIdentifier: blocklistID, encodedContentRuleList: blocklistJSON()) { compiled, _ in
                if let compiled { self?.contentController.add(compiled) }
                done()
            }
        }
    }

    // MARK: Window lifecycle — closing hides the window so playback continues and WebKit stops rendering.

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        startBackgroundWatch()
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func showWindow() {
        stopBackgroundWatch()
        wake()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Background maintenance — while the window is closed, a 5-minute check either hibernates an
    // idle page or, if a playing page has grown past recycleAboveMB, rebuilds it at the next track change.

    private func startBackgroundWatch() {
        guard hibernateMinutes > 0 || recycleAboveMB > 0, webView != nil else { return }
        stopBackgroundWatch()
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: backgroundCheckInterval, repeats: true) { [weak self] _ in
            self?.checkBackground()
        }
        backgroundTimer?.tolerance = 60  // let the system coalesce this wakeup with others
    }

    private func stopBackgroundWatch() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        idleSince = nil
    }

    // WKWebView.requestMediaPlaybackState reports .playing for a paused, empty <video>, so ask the page.
    private func checkBackground() {
        let isPlaying = "[...document.querySelectorAll('video, audio')].some(m => !m.paused)"
        webView?.evaluateJavaScript(isPlaying) { [weak self] result, _ in
            guard let self else { return }
            if result as? Bool ?? false {
                self.idleSince = nil
                if recycleAboveMB > 0, let mb = self.pageFootprintMB(), mb > recycleAboveMB {
                    self.webView?.evaluateJavaScript("window.__ytmLite?.reloadAtNextTrack()", completionHandler: nil)
                }
            } else if hibernateMinutes <= 0 {
                return
            } else if let since = self.idleSince {
                if Date().timeIntervalSince(since) >= Double(hibernateMinutes) * 60 { self.hibernate() }
            } else {
                self.idleSince = Date()
            }
        }
    }

    // The page's WebContent process, via WebKit's long-standing (private) _webProcessIdentifier.
    private func pageFootprintMB() -> Int? {
        guard let webView, webView.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0
        else { return nil }
        return footprintMB(of: pid)
    }

    // Sent by the armed page script at a track change.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !window.isVisible, let body = message.body as? [String: Any],
              let videoID = body["videoId"] as? String else { return }
        var url = URLComponents(string: "https://music.youtube.com/watch")!
        url.queryItems = [URLQueryItem(name: "v", value: videoID)]
        if let list = body["playlistId"] as? String, !list.isEmpty {
            url.queryItems!.append(URLQueryItem(name: "list", value: list))
        }
        // A brand-new web view gets a fresh process; the old one (and its heap) goes away with it.
        makeWebView(loading: url.url!)
    }

    private func hibernate() {
        stopBackgroundWatch()
        isHibernated = true
        hibernatedURL = webView?.url
        webView = nil
        window.contentView = nil  // dropping the last reference tears down the web content process
    }

    // Rebuilds the page where it left off; a /watch URL autoplays that track again.
    private func wake() {
        guard isHibernated else { return }
        isHibernated = false
        makeWebView(loading: hibernatedURL ?? homeURL)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(item("Play/Pause", #selector(playPause(_:))))
        menu.addItem(item("Next", #selector(nextTrack(_:))))
        menu.addItem(item("Previous", #selector(previousTrack(_:))))
        return menu
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, action.targetFrame?.isMainFrame == true else {
            return decisionHandler(.allow)
        }
        if shouldOpenExternally(url, userClick: action.navigationType == .linkActivated) {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    // target=_blank / window.open: never spawn a second web view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if shouldOpenExternally(url, userClick: true) {
                NSWorkspace.shared.open(url)
            } else {
                webView.load(action.request)
            }
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView.url == nil { webView.load(URLRequest(url: homeURL)) } else { webView.reload() }
    }

    // MARK: Actions

    // Playback controls from a hibernated app first rebuild the page, which resumes the last track.
    private func runJS(_ source: String) {
        guard let webView else {
            wake()
            if !window.isVisible { startBackgroundWatch() }
            return
        }
        webView.evaluateJavaScript(source, completionHandler: nil)
    }

    @objc func playPause(_ sender: Any?) {
        runJS("""
        (() => {
          const button = document.querySelector('ytmusic-player-bar #play-pause-button');
          if (button) return void button.click();
          const video = document.querySelector('video');
          if (video) video.paused ? video.play() : video.pause();
        })()
        """)
    }
    @objc func nextTrack(_ sender: Any?) { runJS("document.querySelector('ytmusic-player-bar .next-button')?.click()") }
    @objc func previousTrack(_ sender: Any?) { runJS("document.querySelector('ytmusic-player-bar .previous-button')?.click()") }
    @objc func reload(_ sender: Any?) { webView?.reload() }
    @objc func goBack(_ sender: Any?) { webView?.goBack() }
    @objc func goForward(_ sender: Any?) { webView?.goForward() }
    @objc func goHome(_ sender: Any?) { webView?.load(URLRequest(url: homeURL)) }
    @objc func zoomIn(_ sender: Any?) { webView.map { $0.pageZoom = min($0.pageZoom + 0.1, 3) } }
    @objc func zoomOut(_ sender: Any?) { webView.map { $0.pageZoom = max($0.pageZoom - 0.1, 0.5) } }
    @objc func actualSize(_ sender: Any?) { webView?.pageZoom = 1 }

    // MARK: Menus

    // Our own actions.
    private func item(_ title: String, _ action: Selector, _ key: String = "",
                      _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = system(title, action, key, modifiers)
        item.target = self
        return item
    }

    // Responder-chain actions (copy:, hide:, …).
    private func system(_ title: String, _ action: Selector, _ key: String = "",
                        _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = menu
        return parent
    }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("YT Music", [
            system("About YT Music", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            system("Hide YT Music", #selector(NSApplication.hide(_:)), "h"),
            system("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            system("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            system("Quit YT Music", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("Edit", [
            system("Undo", Selector(("undo:")), "z"),
            system("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            system("Cut", #selector(NSText.cut(_:)), "x"),
            system("Copy", #selector(NSText.copy(_:)), "c"),
            system("Paste", #selector(NSText.paste(_:)), "v"),
            system("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(submenu("View", [
            item("Reload", #selector(reload(_:)), "r"),
            item("Back", #selector(goBack(_:)), "["),
            item("Forward", #selector(goForward(_:)), "]"),
            item("Home", #selector(goHome(_:)), "h", [.command, .shift]),
            .separator(),
            item("Zoom In", #selector(zoomIn(_:)), "="),
            item("Zoom Out", #selector(zoomOut(_:)), "-"),
            item("Actual Size", #selector(actualSize(_:)), "0"),
            .separator(),
            system("Toggle Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        main.addItem(submenu("Playback", [
            item("Play/Pause", #selector(playPause(_:)), "p"),
            item("Next", #selector(nextTrack(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option]),
            item("Previous", #selector(previousTrack(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option]),
        ]))
        let windowMenu = submenu("Window", [
            system("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            system("Zoom", #selector(NSWindow.performZoom(_:))),
            system("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        main.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu
        return main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
