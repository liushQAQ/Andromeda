//
//  CurrentlyDisabledDaemonView.swift
//  Andromeda
//
//  Developed by son3ra1n.
//

import SwiftUI

struct CurrentlyDisabledDaemonView: View {
    let plistPath = "/var/mobile/Documents/disabled.plist"
    @Environment(\.dismiss) var dismiss
    @State private var data: [String: Bool] = [:]
    @State private var result: String = ""
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("已禁用守护进程管理"), footer: Text("当前所有已禁用守护进程的列表。右滑可重新启用。")) {
                    ForEach(data.sorted(by: { $0.key < $1.key }).filter { $0.value == true }, id: \.key) { key, _ in
                        Text(key)
                            .swipeActions {
                                Button(role: .destructive) {
                                    removeDaemon(key: key)
                                } label: {
                                    Label("禁用", systemImage: "xmark")
                                }
                            }
                    }
                }
                Section(header: Text("搞砸了？"), footer: Text("删除已禁用列表即可重来。iOS 下次重启会从头重新生成该文件。")) {
                    Button("重置") {
                        result = RootHelper.removeItem(at: URL(fileURLWithPath: "/var/mobile/Documents/disabled.plist"))
                        result = RootHelper.copy(from: URL(fileURLWithPath: "/var/db/com.apple.xpc.launchd/disabled.plist"), to: URL(fileURLWithPath: "/var/mobile/Documents/disabled.gerackup"))
                        result = RootHelper.removeItem(at: URL(fileURLWithPath: "/var/db/com.apple.xpc.launchd/disabled.plist"))
                        result = RootHelper.removeItem(at: URL(fileURLWithPath: "/var/db/com.apple.xpc.launchd/disabled.migrated"))
                        data = [:]
                        UIApplication.shared.alert(title:"Done !", body:"Please manually reboot your device", withButton: false)
                    }
                }
            }
            .interactiveDismissDisabled()
            .navigationBarTitle("Manage")
            .navigationBarItems(trailing:
                Button("保存") {
                    saveIt()
                    close()
                }
            )
        }
        .onAppear {
            loadIt()
        }
    }
    private func loadIt() {
        if let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Bool] {
            data = dict
        }
    }
    private func saveIt() {
        (data as NSDictionary).write(toFile: plistPath, atomically: true)
        print(result)
        var result = RootHelper.removeItem(at: URL(fileURLWithPath: "/var/db/com.apple.xpc.launchd/disabled.plist"))
        result = RootHelper.move(from: URL(fileURLWithPath: "/var/mobile/Documents/disabled.plist"), to: URL(fileURLWithPath: "/var/db/com.apple.xpc.launchd/disabled.plist"))
        print(result)
    }
    
    private func removeDaemon(key: String) {
        data[key] = nil
    }
    
    func close() {
        dismiss()
    }
}

#Preview {
    CurrentlyDisabledDaemonView()
}
