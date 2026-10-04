import Foundation
import AppKit
import ApplicationServices
func attr(_ item: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(item, key as CFString, &value) == .success else { return nil }
    return value
}
func find(_ root: AXUIElement, names: [String]) -> AXUIElement? {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var n = 0
    while !queue.isEmpty && n < 300 {
        let (item, depth) = queue.removeFirst(); n += 1
        let title = attr(item, kAXTitleAttribute) as? String ?? ""
        if names.contains(where: { title == $0 || title.hasPrefix($0 + " ") }) { return item }
        if depth < 10, let children = attr(item, kAXChildrenAttribute) as? [AXUIElement] { queue += children.map { ($0, depth + 1) } }
    }
    return nil
}
guard AXIsProcessTrusted(), let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dt.Xcode" }) else { print("UI_BUILD_ACCESS_UNAVAILABLE"); exit(1) }
_ = app.activate(options: [.activateIgnoringOtherApps])
let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 1)
let windows = attr(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
guard let projectWindow = windows.first(where: { (attr($0, kAXTitleAttribute) as? String ?? "").contains("DeviceAcceptance") }) else { print("UI_BUILD_INDEPENDENT_WINDOW_NOT_FOUND"); exit(1) }
_ = AXUIElementPerformAction(projectWindow, kAXRaiseAction as CFString)
Thread.sleep(forTimeInterval: 0.4)
guard let barRef = attr(root, kAXMenuBarAttribute), CFGetTypeID(barRef) == AXUIElementGetTypeID() else { print("UI_BUILD_MENU_UNAVAILABLE"); exit(1) }
let bar = barRef as! AXUIElement
guard let product = find(bar, names: ["Product", "产品"]) else { print("UI_BUILD_PRODUCT_MENU_UNAVAILABLE"); exit(1) }
_ = AXUIElementPerformAction(product, kAXPressAction as CFString)
guard let buildFor = find(product, names: ["Build For", "构建用于"]) else { print("UI_BUILD_FOR_MENU_UNAVAILABLE"); exit(1) }
_ = AXUIElementPerformAction(buildFor, kAXPressAction as CFString)
guard let testing = find(buildFor, names: ["Testing", "测试"]) else { print("UI_BUILD_TESTING_MENU_UNAVAILABLE"); exit(1) }
let enabled = attr(testing, kAXEnabledAttribute) as? Bool ?? false
print("UI_BUILD_TESTING_ENABLED=\(enabled)")
guard enabled else { exit(1) }
let action = AXUIElementPerformAction(testing, kAXPressAction as CFString)
print("UI_BUILD_INDEPENDENT_TARGET_REQUESTED=\(action == .success)")
