import SwiftUI
import UIKit
@main
struct NativeMenuFixture: App {
    var body: some Scene { WindowGroup { NavigationStack { List {
        ProjectRowMenu(title: "验收项目甲", actions: [.init(title: "导出…", image: "square.and.arrow.up", perform: {}), .init(title: "移到回收站", image: "trash", destructive: true, perform: {})]).frame(height: 44)
        ProjectRowMenu(title: "验收项目乙", subtitle: "回收站测试行", actions: [.init(title: "恢复", image: "arrow.uturn.backward", perform: {}), .init(title: "彻底删除", image: "trash", destructive: true, perform: {})]).frame(height: 44)
    }.navigationTitle("原生菜单隔离验收") }.preferredColorScheme(CommandLine.arguments.contains("dark") ? .dark : .light) } }
}
