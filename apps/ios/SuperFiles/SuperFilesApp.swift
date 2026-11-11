import SwiftUI
import UIKit

/// 后台 URLSession 事件通道：系统在后台下载完成后冷启动 App 并回调这里，
/// 转交给 BackgroundDownloadManager（必须先存起 completionHandler，事件齐后再调）。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundDownloadManager.sessionIdentifier else {
            completionHandler()
            return
        }
        BackgroundDownloadManager.shared.storeCompletionHandler(completionHandler)
    }
}

@main
struct SuperFilesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
