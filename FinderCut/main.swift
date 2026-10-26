import AppKit

// MARK: - 启动（main.swift 允许顶层代码）

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory) // 后台运行：不显示 Dock 图标、不显示窗口
app.run()

// MARK: - App 委托：静默处理 findercut://paste 请求，完成即退出

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var pendingWork = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[FinderCut] didFinishLaunching, pendingWork=%d", pendingWork)
        // 静默模式：不显示任何界面。若 8 秒内没有收到粘贴请求则自动退出
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self = self else { return }
            NSLog("[FinderCut] idle-timer fired, pendingWork=%d", self.pendingWork)
            guard self.pendingWork == 0 else { return }
            NSLog("[FinderCut] exit(0)")
            exit(0)
        }
    }

    // Finder 扩展在沙盒权限不足时，会通过 findercut://paste 唤起本程序完成移动
    func application(_ application: NSApplication, open urls: [URL]) {
        NSLog("[FinderCut] open urls=%@", urls.map(\.absoluteString).joined(separator: ", "))
        guard let url = urls.first(where: { $0.scheme?.lowercased() == "findercut" }) else { return }
        pendingWork += 1
        PasteRequestHandler.handle(url) { [weak self] in
            guard let self = self else { return }
            self.pendingWork = max(0, self.pendingWork - 1)
            // 稍等片刻让通知送达，随后退出，不常驻后台
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                NSLog("[FinderCut] paste done, exit(0)")
                exit(0)
            }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

// MARK: - findercut://paste 请求处理（扩展沙盒权限不足时的后备通道）

enum PasteRequestHandler {
    static func handle(_ url: URL, completion: @escaping () -> Void) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == "paste",
              let dest = components.queryItems?.first(where: { $0.name == "dest" })?.value,
              let joined = components.queryItems?.first(where: { $0.name == "paths" })?.value else {
            completion()
            return
        }
        let paths = joined.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            completion()
            return
        }

        MoveEngine.move(paths: paths, to: dest) { result in
            if result.movedCount > 0 {
                postNotification(title: "已移动 \(result.movedCount) 个项目", body: "")
            }
            if !result.failed.isEmpty {
                postNotification(title: "\(result.failed.count) 个项目移动失败",
                                 body: result.failed.joined(separator: "、"))
            }
            completion()
        }
    }
}
