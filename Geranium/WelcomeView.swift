//
//  WelcomeView.swift
//  Andromeda
//
//  Developed by son3ra1n.
//


import SwiftUI

struct WelcomeView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var loggingAllowed: Bool
    @Binding var updBypass: Bool
    @StateObject private var appSettings = AppSettings()
    var body: some View {
        List {
            Section(header: Text("初始设置")) {
                Text("欢迎使用 Andromeda——面向 TrollStore 的 iOS 工具箱：摇杆与路线定位模拟、守护进程管理、精细化存储清理等。由 son3ra1n 开发。")
            }
            if getDeviceCode() == "iPhone8,4" {
                Section(header: Text("你好！iPhone SE 一代用户")) {
                    Text("检测到你在 iPhone SE 2016（一代）上使用，可能出现严重 UI 问题，提前致歉。")
                }
            }
            Section(header: Text("日志收集")) {
                Text("我们会收集少量日志上传服务器，用于修 bug 和分析崩溃。日志不含个人信息，只有设备类型与崩溃日志本身，另含功能使用统计。你可以选择完全阻止上传。")
                Toggle(isOn: $loggingAllowed) {
                    Text("启用日志收集")
                }
                .onChange(of: loggingAllowed) { newValue in
                    if !loggingAllowed {
                        UIApplication.shared.alert(title: "警告", body: "关闭日志后，遇到问题时开发者更难排查。")
                    }
                }
            }
            
            Section(header: Text("更新提醒")) {
                Text("发布新版本时，应用启动会弹窗询问是否更新。你可以关闭该提醒。")
                Toggle(isOn: $updBypass) {
                    Text("关闭更新弹窗")
                }
            }
            
            Section(header: Text("清理体积统计")) {
                Text("在你的设备上计算文件体积时，可能出现权限设置不正确的问题。")
                Toggle(isOn: $appSettings.getSizes) {
                    Text("计算文件体积")
                }
            }
            if !updBypass {
                Section(header: Text("警告")) {
                    Text("要启用自动更新，需在 TrollStore 中开启「放大器 URL Scheme」。")
                    Text("1. 打开 TrollStore")
                    Text("2. 进入设置")
                    Text("3. 开启 URL Scheme")
                }
            }
        }
        .navigationTitle("欢迎！")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("知道了") {
                    close()
                }
            }
        }
        .environment(\.defaultMinListRowHeight, 50)
        .interactiveDismissDisabled()
    }

    func close() {
        dismiss()
    }
}

public struct CustomButtonStyle: ButtonStyle {
    public func makeBody(configuration: Self.Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.vertical, 12)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14.0, style: .continuous)
                            .fill(Color.accentColor))
            .opacity(configuration.isPressed ? 0.4 : 1.0)
    }
}

public struct LinkButtonStyle: ButtonStyle {
    public func makeBody(configuration: Self.Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.vertical, 12)
            .foregroundColor(.blue)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12.0, style: .continuous)
                            .fill(Color.blue.opacity(0.1)))
            .opacity(configuration.isPressed ? 0.4 : 1.0)
    }
}

public struct DangerButtonStyle: ButtonStyle {
    public func makeBody(configuration: Self.Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.bold))
            .padding(.vertical, 12)
            .foregroundColor(.red)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12.0, style: .continuous)
                            .fill(Color.red.opacity(0.1)))
            .opacity(configuration.isPressed ? 0.4 : 1.0)
    }
}
