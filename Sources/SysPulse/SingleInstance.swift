import AppKit
import Darwin
import Foundation

/// 保证同一时间只有一个实例、并且优先使用「应用程序」目录里的那一份。
///
/// 菜单栏 App 跑两份会变成两个图标，偏好设置和开机自启也会互相打架。
/// 两道保险：
/// 1. 按 bundle id 查在跑的实例，决定「谁让位、谁接管」；
/// 2. 文件锁（`flock`）兜底——锁在进程退出时自动释放，所以不存在残留状态。
enum SingleInstance {
    private static let installedApp = URL(fileURLWithPath: "/Applications/SysPulse.app")
    private static var lockDescriptor: Int32 = -1

    /// 在创建界面之前调用。若本进程不该继续运行，会直接退出。
    static func enforce() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.local.syspulse"
        let myPID = ProcessInfo.processInfo.processIdentifier
        let iAmInstalled = Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("/Applications/")

        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }

        if iAmInstalled {
            // 我是「应用程序」里那份：把别处的实例收掉，等它们退出后再拿锁
            others.forEach { $0.terminate() }
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline, others.contains(where: { !$0.isTerminated }) {
                usleep(50_000)
            }
        } else {
            // 我不是：优先让「应用程序」里那份来跑
            if others.contains(where: { $0.bundleURL?.path.hasPrefix("/Applications/") == true }) {
                exit(0)
            }
            if FileManager.default.fileExists(atPath: installedApp.path) {
                NSWorkspace.shared.open(installedApp)
                exit(0)
            }
            if !others.isEmpty {
                exit(0)
            }
        }

        guard acquireLock() else { exit(0) }
    }

    /// 取独占文件锁；拿不到说明已经有实例在跑
    private static func acquireLock() -> Bool {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.local.syspulse.instance.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return true }   // 锁文件用不了就不阻塞启动
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        lockDescriptor = descriptor
        return true
    }
}
