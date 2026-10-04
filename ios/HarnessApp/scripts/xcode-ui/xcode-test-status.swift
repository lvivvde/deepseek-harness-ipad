import Foundation
import AppKit
import ApplicationServices
func attr(_ item: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(item, key as CFString, &value) == .success else { return nil }
    return value
}
guard AXIsProcessTrusted(), let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dt.Xcode" }) else { print("GUI_STATUS_UNAVAILABLE"); exit(0) }
let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 1)
let windows = attr(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
var queue: [(AXUIElement, Int)] = windows.map { ($0, 0) }
var strings: [String] = []
var n = 0
let end = Date().addingTimeInterval(10)
while !queue.isEmpty && n < 1800 && Date() < end {
    let (item, depth) = queue.removeFirst(); n += 1
    strings += [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].compactMap { attr(item, $0) as? String }
    if depth < 18, let children = attr(item, kAXChildrenAttribute) as? [AXUIElement] { queue += children.map { ($0, depth + 1) } }
}
let markers: [(String, [String])] = [
 ("testSucceeded", ["Test Succeeded", "测试成功"]),
 ("testFailed", ["Test Failed", "测试失败"]),
 ("automationTimeout", ["Timed out while enabling automation mode"]),
 ("buildSucceeded", ["Build Succeeded", "构建成功"]),
 ("buildFailed", ["Build Failed", "构建失败"]),
 ("noAccounts", ["No Accounts"]),
 ("noRunnerProfile", ["No profiles for 'org.lvivvde.harness.acceptance.xctrunner'"]),
 ("signInRequired", ["Sign In", "Reauthenticate", "登录"]),
 ("personalTeam", ["Personal Team", "个人团队"]),
 ("accountPane", ["Apple Accounts"]),
 ("maximumApps", ["Maximum number", "maximum number"])
]
for (key, needles) in markers { print("GUI_BUILD_MARKER \(key)=\(strings.contains { s in needles.contains { s.contains($0) } })") }
print("GUI_BUILD_ELEMENTS_CHECKED=\(n)")
