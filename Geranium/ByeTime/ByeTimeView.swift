//
//  ByeTimeView.swift
//  Andromeda
//
//  Developed by son3ra1n.
//

import SwiftUI

struct ByeTimeView: View {
    @Binding var DebugStuff: Bool
    @State var ScreenTimeAgent: Bool = true
    @State var usagetrackingd: Bool = true
    @State var homed: Bool = false
    @State var familycircled: Bool = false
    var body: some View {
        VStack {
            List {
                Section(header: Label("屏幕使用时间代理", systemImage: "hourglass"), footer: Text("屏幕使用时间代理负责管理所有屏幕使用时间偏好。仅禁用它最多只能部分关闭屏幕使用时间。")) {
                    Toggle(isOn: $ScreenTimeAgent) {
                        Text("禁用屏幕使用时间代理")
                    }
                    .disabled(!DebugStuff)
                }
                Section(header: Label("使用跟踪代理", systemImage: "magnifyingglass"), footer: Text("使用跟踪代理监控并上报 健康/家长控制（屏幕使用时间）/设备管理 设定的使用预算。禁用它可能连带关闭部分功能。")) {
                    Toggle(isOn: $usagetrackingd) {
                        Text("禁用使用跟踪代理")
                    }
                }
                Section(header: Label("Homed", systemImage: "homekit"), footer: Text("Homed 负责 HomeKit 配件（如 HomePod、智能灯泡等在「家庭」App 里管理的设备。在用这些配件请不要禁用。")) {
                    Toggle(isOn: $homed) {
                        Text("禁用 Homed")
                    }
                }
                Section(header: Label("Familycircled", systemImage: "figure.and.child.holdinghands"), footer: Text("Familycircled 负责 iCloud 家庭体系（含家庭订阅），后订阅将无法使用，但也可借此让屏幕使用时间失效。")) {
                    Toggle(isOn: $familycircled) {
                        Text("禁用 Familycircled")
                    }
                }
            }
            Button("Bye ScreenTime !", action : {
                UIApplication.shared.confirmAlert(title: "即将禁用这些守护进程。", body: "将删除屏幕使用时间偏好文件，并阻止以下守护进程随 iOS 启动。确定继续吗？", onOK: {
                    UIApplication.shared.alert(title: "正在移除屏幕使用时间...", body: "Your device will reboot, 设备将自动重启；建议第一次自动重启后再手动重启一次。", animated: false, withButton: false)
                    DisableScreenTime(screentimeagentd: ScreenTimeAgent, usagetrackingd: usagetrackingd, homed: homed, familycircled: familycircled)
                }, noCancel: false, yes: true)
            })
            .padding(10)
            .background(Color.accentColor)
            .cornerRadius(8)
            .foregroundColor(.black)
            Button("Enable ScreenTime", action : {
                UIApplication.shared.confirmAlert(title: "即将重新启用屏幕使用时间。", body: "将恢复你之前备份的屏幕使用时间数据，相关记录也会重新开启。", onOK: {
                    enableBack()
                }, noCancel: false, yes: true)
            })
            .padding(10)
            .background(Color.accentColor)
            .cornerRadius(8)
            .foregroundColor(.black)
        }
    }
}
