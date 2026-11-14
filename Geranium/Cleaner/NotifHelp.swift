//
//  NotifHelp.swift
//  Andromeda
//
//  Developed by son3ra1n.
//

import SwiftUI

struct NotifHelp: View {
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("问题"), footer: Text("可能丢失部分不重要数据，如 Wi-Fi 密码与偏好设置。")) {
                    Text("清理后通知不见了？别慌，解决办法如下！")
                }
                Section(header: Text("操作步骤")) {
                    Text("先打开「设置」（本应用可帮你打开）。然后进入 **通用**，下滑进入 **传输或还原 iPhone**。")
                    Button("打开设置") {
                        if let url = URL(string:UIApplication.openSettingsURLString) {
                           if UIApplication.shared.canOpenURL(url) {
                              UIApplication.shared.open(url, options: [:], completionHandler: nil)
                           }
                        }
                    }
                }
                Section() {
                    Text("接着点 **还原**（注意：不要选「抹掉所有内容和设置」）")
                }
                Section() {
                    Text("点 **还原所有设置**，按屏幕提示完成即可！")
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("更多帮助")
                        .font(.title2)
                        .bold()
                        .padding(.top, 10)
                }
            }

        }
        .environment(\.defaultMinListRowHeight, 50)
    }
}

#Preview {
    NotifHelp()
}
