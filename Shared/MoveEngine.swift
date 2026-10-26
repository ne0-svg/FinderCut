import Foundation
import Darwin
import UserNotifications

// MARK: - 移动结果

struct MoveResult {
    var movedCount = 0
    var failed: [String] = []
    var missing: [String] = []
    var permissionDenied = false
}

// MARK: - 移动引擎（主程序与 Finder 扩展共用）

enum MoveEngine {

    /// 在后台队列执行移动，完成后回调主线程
    static func move(paths: [String], to destination: String,
                     completion: @escaping (MoveResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = perform(paths: paths, destination: destination)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    static func perform(paths: [String], destination: String) -> MoveResult {
        var result = MoveResult()
        let fileManager = FileManager.default
        let destinationURL = URL(fileURLWithPath: destination)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            result.failed.append(destination)
            return result
        }

        for path in paths {
            let sourceURL = URL(fileURLWithPath: path)
            guard fileManager.fileExists(atPath: path) else {
                result.missing.append(sourceURL.lastPathComponent)
                continue
            }
            // 已经在目标文件夹里：跳过
            if sourceURL.deletingLastPathComponent().path == destinationURL.path {
                result.movedCount += 1
                continue
            }
            let targetURL = uniqueChild(in: destinationURL, preferredName: sourceURL.lastPathComponent)
            do {
                try fileManager.moveItem(at: sourceURL, to: targetURL)
                result.movedCount += 1
            } catch {
                let moveError = error as NSError
                if isPermissionError(moveError) {
                    result.permissionDenied = true
                    result.failed.append(sourceURL.lastPathComponent)
                    continue
                }
                do {
                    // 跨磁盘/卷：复制后删除
                    try fileManager.copyItem(at: sourceURL, to: targetURL)
                    try fileManager.removeItem(at: sourceURL)
                    result.movedCount += 1
                } catch {
                    let copyError = error as NSError
                    if isPermissionError(copyError) { result.permissionDenied = true }
                    result.failed.append(sourceURL.lastPathComponent)
                }
            }
        }
        return result
    }

    private static func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain {
            let permissionCodes: Set<Int> = [
                NSFileReadNoPermissionError,
                NSFileWriteNoPermissionError,
            ]
            if permissionCodes.contains(error.code) { return true }
        } else if error.domain == NSPOSIXErrorDomain {
            if error.code == EPERM || error.code == EACCES { return true }
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionError(underlying)
        }
        return false
    }

    private static func uniqueChild(in directory: URL, preferredName: String) -> URL {
        let fileManager = FileManager.default
        let base = directory.appendingPathComponent(preferredName)
        if !fileManager.fileExists(atPath: base.path) { return base }

        let name = preferredName as NSString
        let stem = name.deletingPathExtension
        let ext = name.pathExtension
        var index = 2
        repeat {
            let candidate = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let url = directory.appendingPathComponent(candidate)
            if !fileManager.fileExists(atPath: url.path) { return url }
            index += 1
        } while index < 1000
        return base
    }
}

// MARK: - 通知（主程序与扩展共用）

func postNotification(title: String, body: String) {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
        func fire() {
            let content = UNMutableNotificationContent()
            content.title = title
            if !body.isEmpty { content.body = body }
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            fire()
        case .notDetermined:
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { fire() }
            }
        default:
            break
        }
    }
}
