import Cocoa
import FinderSync

final class FinderSync: FIFinderSync {

    private static let bufferKey = "FinderCutBufferPaths"

    private var pasteboardTimer: Timer?
    private var cutChangeCount: Int = 0

    private var bufferPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.bufferKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.bufferKey) }
    }

    override init() {
        super.init()
        let controller = FIFinderSyncController.default()
        controller.directoryURLs = [URL(fileURLWithPath: "/")]
        if let scissors = NSImage(systemSymbolName: "scissors", accessibilityDescription: "已剪切") {
            controller.setBadgeImage(scissors, label: "已剪切", forBadgeIdentifier: "cut")
        } else {
            // SF Symbol 加载失败的兜底图，保证 "cut" 角标一定有图可显示
            controller.setBadgeImage(Self.fallbackBadgeImage(), label: "已剪切", forBadgeIdentifier: "cut")
        }
        NSLog("[FinderCut] ext init, buffered=%d", bufferPaths.count)
        // 扩展进程被系统回收重启后：恢复未粘贴剪切项的角标 + 继续监听剪贴板
        restoreBadgesIfNeeded()
        if !bufferPaths.isEmpty { startPasteboardWatch() }
    }

    /// 扩展重启后，主动为仍在剪切板中的文件重设角标
    /// （Finder 只在窗口刷新时回调 requestBadgeIdentifier，不主动恢复角标会一直缺失）
    private func restoreBadgesIfNeeded() {
        let existing = bufferPaths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        NSLog("[FinderCut] restore badges: %d", existing.count)
        let controller = FIFinderSyncController.default()
        for path in existing {
            controller.setBadgeIdentifier("cut", for: URL(fileURLWithPath: path))
        }
    }

    /// 兜底角标图：白色圆点（仅在 SF Symbol 不可用时使用）
    private static func fallbackBadgeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 128, height: 128))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 28, y: 28, width: 72, height: 72)).fill()
        NSColor.systemBlue.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 24, y: 24, width: 80, height: 80))
        ring.lineWidth = 8
        ring.stroke()
        image.unlockFocus()
        return image
    }

    // MARK: - 右键菜单

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "剪切助手")
        let controller = FIFinderSyncController.default()
        let buffer = bufferPaths.filter { FileManager.default.fileExists(atPath: $0) }

        switch menuKind {
        case .contextualMenuForItems:
            // 右键点在文件上：仅当有选中项时显示「剪切」（与原生「拷贝」逻辑一致）
            let selection = controller.selectedItemURLs() ?? []
            if !selection.isEmpty {
                addItem("剪切", action: #selector(cutAction(_:)), to: menu)
            }
        case .contextualMenuForContainer:
            // 空白处右键：不显示「剪切」；仅当剪切板非空时显示粘贴/清空
            break
        default:
            return menu
        }

        if !buffer.isEmpty {
            let suffix = buffer.count > 1 ? "（\(buffer.count) 个项目）" : ""
            addItem("粘贴到当前文件夹\(suffix)", action: #selector(pasteAction(_:)), to: menu)
            addItem("清空剪切板", action: #selector(clearAction(_:)), to: menu)
        }
        return menu
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: - 动作

    @objc private func cutAction(_ sender: Any?) {
        let controller = FIFinderSyncController.default()
        guard let items = controller.selectedItemURLs(), !items.isEmpty else { return }
        let paths = items.map(\.path)
        guard !paths.isEmpty else { return }

        NSLog("[FinderCut] cut %d item(s)", paths.count)
        bufferPaths = paths
        for path in paths {
            controller.setBadgeIdentifier("cut", for: URL(fileURLWithPath: path))
        }
        // 清空系统剪贴板：让 Finder 原生「粘贴项目」置灰，避免误粘到剪切无关的旧内容
        NSPasteboard.general.clearContents()
        startPasteboardWatch()
        let suffix = paths.count > 1 ? "（\(paths.count) 个项目）" : ""
        postNotification(title: "已剪切\(suffix)",
                         body: "到目标文件夹空白处点右键，选择「粘贴到当前文件夹」。")
    }

    @objc private func pasteAction(_ sender: Any?) {
        let controller = FIFinderSyncController.default()
        guard let destination = controller.targetedURL() else {
            postNotification(title: "粘贴失败", body: "无法获取当前 Finder 窗口的文件夹。")
            return
        }
        let paths = bufferPaths
        guard !paths.isEmpty else { return }

        MoveEngine.move(paths: paths, to: destination.path) { [weak self] result in
            guard let self = self else { return }
            if result.permissionDenied {
                // 扩展沙盒权限不足：交给主程序完成（主程序会触发一次系统授权）
                self.clearBuffer()
                self.delegateToHostApp(paths: paths, destination: destination)
                return
            }
            self.clearBuffer()
            self.reportResult(result)
        }
    }

    @objc private func clearAction(_ sender: Any?) {
        clearBuffer()
    }

    private func clearBuffer() {
        let controller = FIFinderSyncController.default()
        NSLog("[FinderCut] clear buffer: %d item(s)", bufferPaths.count)
        for path in bufferPaths {
            controller.setBadgeIdentifier("", for: URL(fileURLWithPath: path))
        }
        bufferPaths = []
        stopPasteboardWatch()
    }

    // MARK: - 剪贴板监听：剪切后若复制了新内容，自动取消剪切（与 Windows 行为一致）

    private func startPasteboardWatch() {
        stopPasteboardWatch()
        cutChangeCount = NSPasteboard.general.changeCount
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount != self.cutChangeCount else { return }
            // 只有剪贴板出现实际内容才视为「复制了新东西」，此时取消剪切（与 Windows 一致）；
            // 剪贴板历史/接力等工具在清空后回写造成的「空变化」只更新基线，不取消剪切
            if let items = pasteboard.pasteboardItems, !items.isEmpty {
                NSLog("[FinderCut] pasteboard got new content -> cancel cut")
                self.clearBuffer()
            } else {
                NSLog("[FinderCut] pasteboard changed but empty -> keep cut")
                self.cutChangeCount = pasteboard.changeCount
            }
        }
    }

    private func stopPasteboardWatch() {
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
    }

    private func reportResult(_ result: MoveResult) {
        if !result.failed.isEmpty {
            postNotification(title: "粘贴完成：\(result.movedCount) 个成功，\(result.failed.count) 个失败",
                             body: "失败：\(result.failed.joined(separator: "、"))")
        } else if result.movedCount > 0 {
            postNotification(title: "已粘贴 \(result.movedCount) 个项目", body: "")
        }
    }

    private func delegateToHostApp(paths: [String], destination: URL) {
        var components = URLComponents()
        components.scheme = "findercut"
        components.host = "paste"
        components.queryItems = [
            URLQueryItem(name: "paths", value: paths.joined(separator: "\n")),
            URLQueryItem(name: "dest", value: destination.path),
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Finder Sync 回调

    override func requestBadgeIdentifier(for url: URL) {
        // macOS 26+ 改为在回调中主动回设角标
        let badge = bufferPaths.contains(url.path) ? "cut" : ""
        if badge == "cut" {
            NSLog("[FinderCut] badge request hit: %@", (url.path as NSString).lastPathComponent)
        }
        FIFinderSyncController.default().setBadgeIdentifier(badge, for: url)
    }

    override func beginObservingDirectory(at url: URL) {}
    override func endObservingDirectory(at url: URL) {}
}
