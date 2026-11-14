//
//  DaemonWelcomeView.swift
//  Andromeda
//
//  Developed by son3ra1n.
//

import SwiftUI

struct DaemonWelcomeView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        List {
            
            Section(header: Text("用途")) {
                Text("通过向 iOS 内部添加规则，阻止守护进程在开机时启动。应用会列出所有运行中的守护进程，左滑可移除。")
            }
            
            Section(header: Text("警告")) {
                Text("禁用系统守护进程有风险，可能导致设备无限重启。请谨慎操作，设备出问题与开发者无关。")
                    .foregroundStyle(.red)
            }
            Section(header: Text("请注意")) {
                Text("想恢复某项选择，请进入管理器（应用图标旁的列表图标），在那里可重新启用已禁用的守护进程。")
                    .foregroundStyle(.green)
            }
            Section(header: Text("更多信息")) {
                Button("守护进程作用说明列表") {
                    UIApplication.shared.open(URL(string: "https://www.reddit.com/r/jailbreak/comments/10v7j59/tutorial_list_of_ios_daemons_and_what_they_do/")!)
                }
                Button("可禁用的守护进程列表") {
                    UIApplication.shared.open(URL(string: "https://www.reddit.com/r/jailbreak/comments/10v7j59/comment/j8s1lgj/")!)
                }
            }
        }
        .navigationTitle("须知")
        .navigationBarItems(trailing: Button("明白了") {
            close()
        })
        .environment(\.defaultMinListRowHeight, 50)
        .interactiveDismissDisabled()
    }

    func close() {
        dismiss()
    }
}

#Preview {
    DaemonWelcomeView()
}
