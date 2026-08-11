import SwiftUI
import UIKit

@main
struct WeChatMonitorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func applicationDidFinishLaunching(_ application: UIApplication) {
        BGTaskCoordinator.shared.register()
    }
    func applicationDidEnterBackground(_ application: UIApplication) {
        MonitorEngine.shared.keepAliveInBackground()
        BGTaskCoordinator.shared.scheduleRefresh()
    }
    func applicationWillEnterForeground(_ application: UIApplication) {
        MonitorEngine.shared.refreshOnForeground()
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        completionHandler(.newData)
    }
}
