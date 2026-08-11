import Foundation
import UserNotifications
import BackgroundTasks

/// iOS 后台任务协调：尽量在被系统清理后重新唤醒（系统调度，非保证）
final class BGTaskCoordinator {
    static let shared = BGTaskCoordinator()
    private static let refreshId = "com.aihub.wechatmonitor.refresh"

    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshId, using: nil) { task in
            self.handle(task: task)
        }
    }

    func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // 忽略：系统会自行调度
        }
    }

    private func handle(task: BGTask) {
        scheduleRefresh()
        DispatchQueue.main.async {
            MonitorEngine.shared.refreshOnForeground()
        }
        task.setTaskCompleted(success: true)
    }
}