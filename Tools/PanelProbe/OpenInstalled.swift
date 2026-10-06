import AppKit
import CoreGraphics

// 只打开正式应用已有的菜单栏面板；不修改偏好，不请求系统权限。
let installed = URL(fileURLWithPath: "/Applications/SysPulse.app")
guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.syspulse")
    .first(where: { $0.bundleURL?.standardizedFileURL == installed.standardizedFileURL }) else {
    fatalError("Installed SysPulse is not running")
}
guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    fatalError("Window list unavailable")
}
let owned = windows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == application.processIdentifier }
func bounds(_ info: [String: Any]) -> CGRect? {
    guard let dictionary = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: dictionary)
}
if owned.contains(where: { info in
    guard let rect = bounds(info) else { return false }
    return rect.height > 300 && rect.width >= 360 && rect.width < 500
}) {
    print("PASS: installed panel is already visible")
    exit(0)
}
// NSStatusBar 的托管窗口可能归 WindowServer，先尝试应用自身的公开 AX 菜单栏项。
if AXIsProcessTrusted() {
    let element = AXUIElementCreateApplication(application.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 1)
    for name in [kAXExtrasMenuBarAttribute, kAXMenuBarAttribute] {
        var rawBar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &rawBar) == .success,
              let rawBar, CFGetTypeID(rawBar) == AXUIElementGetTypeID() else { continue }
        let bar = unsafeBitCast(rawBar, to: AXUIElement.self)
        var rawChildren: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &rawChildren) == .success,
              let children = rawChildren as? [AXUIElement] else { continue }
        for child in children {
            if AXUIElementPerformAction(child, kAXPressAction as CFString) == .success {
                print("Opened installed SysPulse panel through its AX status item")
                exit(0)
            }
        }
    }
}
guard CGPreflightPostEventAccess() else {
    FileHandle.standardError.write(Data("Global mouse posting is not permitted; no permission prompt requested.\n".utf8))
    exit(2)
}
guard let item = owned.first(where: { info in
    guard let rect = bounds(info) else { return false }
    return rect.height > 0 && rect.height <= 40 && rect.width > 20
}), let rect = bounds(item) else {
    FileHandle.standardError.write(Data("Installed status item window not found.\n".utf8))
    exit(3)
}
let point = CGPoint(x: rect.midX, y: rect.midY)
let source = CGEventSource(stateID: .hidSystemState)
for type in [CGEventType.leftMouseDown, .leftMouseUp] {
    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
        fatalError("Could not create mouse event")
    }
    event.post(tap: .cghidEventTap)
}
print("Opened installed SysPulse panel at \(point)")
