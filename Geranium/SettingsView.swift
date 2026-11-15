//
//  SettingsView.swift
//  Andromeda
//
//  Developed by son3ra1n.
//

import SwiftUI
import AlertKit

struct SettingsView: View {
    @State var defaultTab = AppSettings().defaultTab
    @State var DebugStuff: Bool = false
    @State var MinimCal: String = ""
    @State var LocSimTries: String = ""
    @State var localisation: String = {
        if langaugee != "" {
            return langaugee
        }
        else if let languages = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
           let firstLanguage = languages.first {
                return "\(Locale.current.languageCode ?? "en-GB")"
        } else {
            return "en-GB"
        }
    }()
    @StateObject private var appSettings = AppSettings()
    
    // Custom language
    @State var appCodeLanguage = langaugee
    let languageMapping: [String: String] = [
                "zh-Hans": "Chinese (Simplified)",
                "zh-Hant": "Chinese (Traditional)",
                "Base": "English",
                "en-GB": "English (GB)",
                "es": "Spanish",
                "es-419": "Spanish (Latin America)",
                "fr": "French",
                "it": "Italian",
                "ja": "Japanese",
                "ko": "Korean",
                "ru": "Russian",
                "sk": "Slovak",
                "sv": "Swedish",
                "tr": "Turkish",
                "vi": "Vietnamese",
    ]
    var sortedLocalisalist: [String] {
        languageMapping.keys.sorted()
    }
    
    // Open Tab
    let defaultTabList: [Int: String] = [
                1: "Home",
                2: "Daemons",
                3: "LocSim",
                4: "Cleaner",
                5: "Superviser",
    ]
    
    
    var body: some View {
        NavigationView {
            List {
                // MARK: - ByeTime Settings
                Section(header: Label("ByeTime", systemImage: "hourglass"), footer: Text("ByeTime 可完全禁用屏幕使用时间（无论 iCloud 是否开启）。")) {
                    NavigationLink(destination: ByeTimeView(DebugStuff: $DebugStuff)) {
                        HStack {
                            Text("ByeTime 设置")
                        }
                    }
                }
                
                // MARK: - Language
                Section(header: Label("应用语言", systemImage: "magnifyingglass"), footer: Text("选择界面语言。应用会退出以应用更改。")) {
                    Picker("Language", selection: $localisation) {
                        ForEach(sortedLocalisalist, id: \.self) { abbreviation in
                            Text(languageMapping[abbreviation] ?? abbreviation)
                                .tag(abbreviation)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: localisation) { newValue in
                        if localisation.contains("en-GB") || localisation.contains("zh") || localisation.contains("es-419"){
                            let parts = localisation.components(separatedBy: "-")
                            if let appCodeLanguage = parts.last {
                                appSettings.languageCode = appCodeLanguage
                                UserDefaults.standard.set(["\(localisation)"], forKey: "AppleLanguages")
                            }
                        }
                        else {
                            appSettings.languageCode = ""
                            UserDefaults.standard.set(["\(newValue)"], forKey: "AppleLanguages")
                        }
                        UIApplication.shared.confirmAlert(title: "需要重启应用", body: "应用需要重启以应用语言更改。", onOK: {
                            exitGracefully()
                        }, noCancel: true)
                    }
                    .onAppear {
                        appSettings.languageCode = ""
                    }
                }
                
                // MARK: - Debug
                Section(header: Label("调试", systemImage: "chevron.left.forwardslash.chevron.right"), footer: Text("显示实验性调试信息。")) {
                    Toggle(isOn: $DebugStuff) {
                        Text("调试信息")
                    }
                    if DebugStuff {
                        Text("语言: \(localisation)")
                        Button("重置语言") {
                            UserDefaults.standard.set(["Base"], forKey: "AppleLanguages")
                            UIApplication.shared.confirmAlert(title: "需要重启应用", body: "应用需要重启。", onOK: {
                                exitGracefully()
                            }, noCancel: true)
                        }
                        Text("UUID: \(appSettings.usrUUID)")
                        Text("RootHelper: \(RootHelper.whatsthePath())")
                    }
                }
                
                // MARK: - Cleaner Settings
                Section(header: Label("清理", systemImage: "trash"), footer: Text("配置清理选项。")) {
                    Toggle(isOn: $appSettings.keepCheckBoxesC) {
                        Text("清理后保留勾选")
                    }
                    Toggle(isOn: $appSettings.getSizes) {
                        Text("计算清理体积")
                    }
                    .onChange(of: appSettings.getSizes) { newValue in
                        UIApplication.shared.confirmAlert(title: "需要重启应用", body: "应用需要重启。", onOK: {
                            exitGracefully()
                        }, noCancel: true)
                    }
                    Toggle(isOn: Binding<Bool>(
                        get: { !appSettings.tmpClean },
                        set: { appSettings.tmpClean = !$0 }
                    )) {
                        Text("安全清理（iOS 15 请开启）")
                    }
                    .onChange(of: appSettings.tmpClean) { newValue in
                        UIApplication.shared.confirmAlert(title: "需要重启应用", body: "应用需要重启。", onOK: {
                            exitGracefully()
                        }, noCancel: true)
                    }
                    
                    if DebugStuff {
                        HStack {
                            Text("最小体积：")
                            Spacer()
                            TextField("50.0 MB", text: $MinimCal)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: MinimCal) { newValue in
                                    MinimCal = newValue.replacingOccurrences(of: ",", with: ".")
                                }
                        }
                        .onAppear {
                            MinimCal = "\(appSettings.minimSizeC)"
                        }
                        .onChange(of: MinimCal) { newValue in
                            appSettings.minimSizeC = Double(MinimCal) ?? 50.0
                        }
                    }
                }
                
                // MARK: - 步数插件（2026-11-15 老总令：装 App 和装插件合并成一步）
                Section(header: Label("步数插件", systemImage: "figure.walk.motion"),
                        footer: Text("插件已打包在本 App 里。在这里直接给悦跑圈/咕咚注入，不用再单独装 deb 或第二个工具；随时可以一键还原。")) {
                    NavigationLink(destination: StepInjectView()) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("一键注入步数插件")
                                    .foregroundColor(.primary)
                                Text("悦跑圈 / 咕咚，装完即用")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "bolt.fill")
                                .foregroundColor(.orange)
                        }
                    }
                }

                // MARK: - LocSim Settings
                Section(header: Label("定位模拟", systemImage: "location.fill.viewfinder"), footer: Text("配置定位模拟参数。")) {
                    Toggle(isOn: $appSettings.locSimMultipleAttempts) {
                        Text("多次尝试停止定位模拟")
                    }
                    if appSettings.locSimMultipleAttempts {
                        HStack {
                            Text("尝试次数：")
                            Spacer()
                            TextField("3", text: $LocSimTries)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        .onAppear {
                            LocSimTries = "\(appSettings.locSimAttemptNB)"
                        }
                        .onChange(of: LocSimTries) { newValue in
                            appSettings.locSimAttemptNB = Int(LocSimTries) ?? 1
                        }
                    }
                }
                
                // MARK: - Startup
                Section(header: Label("启动", systemImage: "play"), footer: Text("自定义启动行为。")) {
                    Picker("Default Tab", selection: $defaultTab) {
                        ForEach(Array(defaultTabList.keys).sorted(), id: \.self) { key in
                            Text(defaultTabList[key] ?? "")
                                .tag(key)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: defaultTab) { newValue in
                        appSettings.defaultTab = defaultTab
                        UIApplication.shared.confirmAlert(title: "需要重启应用", body: "应用需要重启。", onOK: {
                            exitGracefully()
                        }, noCancel: true)
                    }
                    Toggle(isOn: $appSettings.tsBypass) {
                        Text("跳过 TrollStore 弹窗")
                    }
                    .onChange(of: appSettings.tsBypass) { newValue in
                        AlertKitAPI.present(title: "已保存", icon: .done, style: .iOS17AppleMusic, haptic: .success)
                    }
                }
                
                // MARK: - About
                Section(header: Label("关于", systemImage: "info.circle")) {
                    HStack {
                        Text("应用")
                        Spacer()
                        Text("自由轨迹 v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("开发者")
                        Spacer()
                        Text("liushQAQ")
                            .foregroundColor(.indigo)
                    }
                    Button(action: {
                        UpdateCenter.shared.check(manual: true)
                    }) {
                        HStack {
                            Text("检查更新")
                            Spacer()
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(.indigo)
                        }
                    }
                    Button(action: {
                        if let url = URL(string: "https://github.com/liushQAQ/Andromeda") {
                            UIApplication.shared.open(url)
                        }
                    }) {
                        HStack {
                            Text("源代码")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.indigo)
                        }
                    }
                }
                
                // MARK: - Acknowledgments
                Section(header: Label("致谢", systemImage: "heart.fill"), footer: Text("自由轨迹 基于 c22dev 的 Geranium 项目与 son3ra1n 的 Andromeda 构建，遵循 GPL-3.0 协议。")) {
                    Button(action: {
                        UIApplication.shared.open(URL(string: "https://github.com/c22dev/Geranium")!)
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Geranium（c22dev）")
                                    .foregroundColor(.primary)
                                Text("原项目与核心架构")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                        }
                    }
                    Button(action: {
                        UIApplication.shared.open(URL(string: "https://github.com/son3ra1n/Andromeda")!)
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Andromeda（son3ra1n）")
                                    .foregroundColor(.primary)
                                Text("原项目与路线模拟能力")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                        }
                    }
                    Button(action: {
                        UIApplication.shared.open(URL(string: "https://github.com/BomberFish/Geranium")!)
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("BomberFish")
                                    .foregroundColor(.primary)
                                Text("守护进程列表贡献")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("设置")
        }
    }
}

// MARK: - DriftFix v2.9 步数插件一键注入（App 自带插件与签名工具，不再需要第二个 App）
struct StepInjectView: View {
    @State private var statuses: [StepInjector.TargetStatus] = []
    @State private var busyID: String? = nil
    @State private var log: String = ""

    var body: some View {
        List {
            Section(header: Text("支持的 App"),
                    footer: Text("注入只改目标 App 的安装包，不动系统。App Store 更新会覆盖注入，更新后回来再点一次即可；不想要了随时「还原」。")) {
                ForEach(statuses) { st in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: st.installed ? "app.badge.checkmark" : "app.dashed")
                                .foregroundColor(st.installed ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(st.target.title)
                                    .font(.headline)
                                Text(st.installed ? st.note : "未安装")
                                    .font(.caption)
                                    .foregroundColor(st.injected ? .orange : .secondary)
                            }
                            Spacer()
                            if busyID == st.id {
                                ProgressView()
                            }
                        }

                        if st.installed {
                            HStack(spacing: 10) {
                                Button(action: { apply(st, inject: true) }) {
                                    Text(st.injected ? "重新注入" : "一键注入")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.indigo))
                                        .foregroundColor(.white)
                                }
                                .buttonStyle(.plain)
                                .disabled(busyID != nil)

                                Button(action: { apply(st, inject: false) }) {
                                    Text("还原")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(UIColor.secondarySystemBackground)))
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                                .disabled(busyID != nil || !st.injected)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section(header: Text("说明"),
                    footer: Text("插件 3.7：悦跑圈 / 咕咚都在 App 内生效，步数上涨速度可在插件面板里调。注入后请从桌面图标正常打开目标 App。")) {
                Button(action: { refresh() }) {
                    HStack {
                        Text("刷新列表")
                        Spacer()
                        Image(systemName: "arrow.clockwise").foregroundColor(.indigo)
                    }
                }
                if !log.isEmpty {
                    Text(log)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("注意")) {
                Text("1. 注入会把目标 App 的主程序改签名，只能由 TrollStore 安装的 App 这样做；普通未越狱设备不支持。")
                    .font(.caption)
                Text("2. 注入期间会先关掉目标 App，注入完再从桌面打开。")
                    .font(.caption)
                Text("3. 失败会自动回滚，不会把 App 弄成打不开。")
                    .font(.caption)
            }
        }
        .navigationTitle("步数插件")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
    }

    private func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = StepInjector.shared.allStatuses(refresh: true)
            DispatchQueue.main.async { statuses = list }
        }
    }

    private func apply(_ st: StepInjector.TargetStatus, inject: Bool) {
        busyID = st.id
        log = ""
        DispatchQueue.global(qos: .userInitiated).async {
            var err: String? = nil
            if inject {
                err = StepInjector.shared.inject(st)
            } else {
                err = StepInjector.shared.restore(st)
            }
            let list = StepInjector.shared.allStatuses(refresh: true)
            DispatchQueue.main.async {
                busyID = nil
                statuses = list
                if let e = err {
                    log = e
                    AlertKitAPI.present(title: inject ? "注入失败" : "还原失败", icon: .error, style: .iOS17AppleMusic, haptic: .error)
                } else {
                    log = inject ? "已注入 \(st.target.title)，去桌面打开它试试。" : "已还原 \(st.target.title)。"
                    AlertKitAPI.present(title: inject ? "注入成功" : "已还原", icon: .done, style: .iOS17AppleMusic, haptic: .success)
                }
            }
        }
    }
}
