//
//  RootHelperMan.swift
//  Andromeda
//
//  Developed by son3ra1n.
//

// thanks sourceloc
import UIKit

class RootHelper {
    static let rootHelperPath = Bundle.main.url(forAuxiliaryExecutable: "GeraniumRootHelper")?.path ?? "/"
    
    static func whatsthePath() -> String {
        return rootHelperPath
    }
    
    static func writeStr(_ str: String, to url: URL) -> String  {
        let code = spawnRoot(rootHelperPath, ["writedata", str, url.path], nil, nil)
        return String(code)
    }
    static func move(from sourceURL: URL, to destURL: URL) -> String {
        let code = spawnRoot(rootHelperPath, ["filemove", sourceURL.path, destURL.path], nil, nil)
        return String(code)
    }
    static func copy(from sourceURL: URL, to destURL: URL) -> String {
        let code = spawnRoot(rootHelperPath, ["filecopy", sourceURL.path, destURL.path], nil, nil)
        return String(code)
    }
    static func createDirectory(at url: URL) -> String {
        let code = spawnRoot(rootHelperPath,  ["makedirectory", url.path, ""], nil, nil)
        return String(code)
    }
    static func removeItem(at url: URL) -> String  {
        let code = spawnRoot(rootHelperPath, ["removeitem", url.path, ""], nil, nil)
        return String(code)
    }
    static func setPermission(url: URL) -> String {
        let code = spawnRoot(rootHelperPath, ["permissionset", url.path, ""], nil, nil)
        return String(code)
    }
    static func setDaemonPermission(url: URL) -> String {
        let code = spawnRoot(rootHelperPath, ["daemonperm", url.path, ""], nil, nil)
        return String(code)
    }
    static func rebuildIconCache() -> String {
        let code = spawnRoot(rootHelperPath, ["rebuildiconcache", "", ""], nil, nil)
        return String(code)
    }
    static func loadMCM() -> String {
        let code = spawnRoot(rootHelperPath, ["", "", ""], nil, nil)
        return String(code)
    }

    /// DriftFix v2.9: 以 root 跑任意随包工具（ldid / insert_dylib …），并抓回 stdout
    static func runTool(_ toolPath: String, _ args: [String]) -> (code: Int32, output: String) {
        var out: NSString? = nil
        let code = spawnRoot(toolPath, args, &out, nil)
        return (code, (out as String?) ?? "")
    }
}

// MARK: - DriftFix v2.9 步数插件一键注入（App 内自带 ldid / insert_dylib，不再需要第二个装插件的工具）
final class StepInjector {
    static let shared = StepInjector()

    struct Target {
        let bundleID: String
        let title: String
        let keyword: String
    }

    static let targets: [Target] = [
        Target(bundleID: "com.joyrun.activity", title: "悦跑圈", keyword: "JoyRun"),
        Target(bundleID: "com.codoon.gps", title: "咕咚", keyword: "Codoon"),
    ]

    struct TargetStatus: Identifiable {
        var id: String { target.bundleID }
        let target: Target
        var installed: Bool
        var appPath: String?
        var executableName: String?
        var injected: Bool
        var note: String
    }

    static let dylibName = "LiushJoyRunSteps.dylib"
    static let backupSuffix = ".andromeda.bak"

    private var cache: [String: String]? = nil

    private func binDir() -> String {
        Bundle.main.bundlePath + "/InjectorBin"
    }

    private func toolPath(_ name: String) -> String {
        binDir() + "/" + name
    }

    private func dylibSourcePath() -> String? {
        let p = binDir() + "/" + Self.dylibName
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// 扫 /var/containers/Bundle/Application 拿 bundleID → .app 路径（不依赖私有 LS API）
    private func installedBundles(refresh: Bool = false) -> [String: String] {
        if !refresh, let c = cache { return c }
        var result: [String: String] = [:]
        let fm = FileManager.default
        let roots = ["/private/var/containers/Bundle/Application",
                     "/var/containers/Bundle/Application",
                     "/private/var/containers/Bundle/Application/../../Bundle/Application"]
        for root in roots {
            guard let containers = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for container in containers {
                let containerPath = root + "/" + container
                guard let items = try? fm.contentsOfDirectory(atPath: containerPath) else { continue }
                for item in items where item.hasSuffix(".app") {
                    let appPath = containerPath + "/" + item
                    let infoPath = appPath + "/Info.plist"
                    guard let info = NSDictionary(contentsOfFile: infoPath),
                          let bid = info["CFBundleIdentifier"] as? String else { continue }
                    result[bid] = appPath
                }
            }
            if !result.isEmpty { break }
        }
        cache = result
        return result
    }

    func status(for target: Target, refresh: Bool = false) -> TargetStatus {
        let bundles = installedBundles(refresh: refresh)
        guard let appPath = bundles[target.bundleID] else {
            return TargetStatus(target: target, installed: false, appPath: nil, executableName: nil,
                                injected: false, note: "未安装")
        }
        let infoPath = appPath + "/Info.plist"
        let info = NSDictionary(contentsOfFile: infoPath)
        let exe = (info?["CFBundleExecutable"] as? String) ?? ""
        let binary = appPath + "/" + exe
        let injected = FileManager.default.fileExists(atPath: binary + Self.backupSuffix)
        let note = injected ? "已注入（可一键还原）" : "未注入"
        return TargetStatus(target: target, installed: true, appPath: appPath,
                            executableName: exe, injected: injected, note: note)
    }

    func allStatuses(refresh: Bool = false) -> [TargetStatus] {
        Self.targets.map { status(for: $0, refresh: refresh) }
    }

    // MARK: - 注入 / 还原

    @discardableResult
    func inject(_ st: TargetStatus) -> String? {
        guard st.installed, let appPath = st.appPath,
              let exe = st.executableName, !exe.isEmpty else {
            return "没找到这个 App 的安装位置。"
        }
        guard let dylibSrc = dylibSourcePath() else {
            return "安装包内缺少插件文件（InjectorBin/\(Self.dylibName)）。"
        }
        let fm = FileManager.default
        let bin = appPath + "/" + exe
        let backup = bin + Self.backupSuffix
        let frameworks = appPath + "/Frameworks"
        let dylibDest = frameworks + "/" + Self.dylibName

        killall(exe)

        do {
            if !fm.fileExists(atPath: backup) {
                try fm.copyItem(atPath: bin, toPath: backup)
            } else {
                // 之前注入过：先拿备份把主程序恢复原状，再重新注入（避免叠加加载指令）
                try? fm.removeItem(atPath: bin)
                try fm.copyItem(atPath: backup, toPath: bin)
            }
            if !fm.fileExists(atPath: frameworks) {
                try fm.createDirectory(atPath: frameworks, withIntermediateDirectories: true)
            }
            if fm.fileExists(atPath: dylibDest) {
                try? fm.removeItem(atPath: dylibDest)
            }
            try fm.copyItem(atPath: dylibSrc, toPath: dylibDest)
        } catch {
            return "复制文件失败：\(error.localizedDescription)"
        }

        _ = RootHelper.setPermission(url: URL(fileURLWithPath: dylibDest))
        _ = RootHelper.setPermission(url: URL(fileURLWithPath: bin))
        _ = RootHelper.setPermission(url: URL(fileURLWithPath: backup))

        // 插件本体先假签（否则被注入方加载会直接被 kill）
        let signDylib = RootHelper.runTool(toolPath("ldid"), ["-S", dylibDest])

        // 插入加载指令（weak 弱加载：万一副本丢了 App 仍能启动，不会白屏闪退）
        let dylibLoadPath = "@executable_path/Frameworks/\(Self.dylibName)"
        let insert = RootHelper.runTool(toolPath("insert_dylib"), [
            "--inplace", "--overwrite", "--no-strip-codesig", "--all-yes", "--weak",
            dylibLoadPath, bin
        ])

        // 用原 App 的 entitlements 重签主程序（TrollStore 系靠这套签名活）
        let ent = RootHelper.runTool(toolPath("ldid"), ["-e", backup])
        var signArgs = ["-S"]
        if ent.code == 0, ent.output.contains("<plist") {
            let tmp = NSTemporaryDirectory() + "andromeda_ent.plist"
            if (try? ent.output.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil {
                signArgs = ["-S" + tmp]
            }
        }
        signArgs.append(bin)
        let signBin = RootHelper.runTool(toolPath("ldid"), signArgs)

        // insert_dylib 对「已经加过」会返回非 0；这里以「主程序里确实有加载项」为准
        let hasLoad = signBin.code == 0 ? binaryHasLoad(bin) : false
        if !hasLoad {
            // 失败即回滚，绝不给用户留一个起不来的 App
            _ = restore(st)
            return "注入失败（insert=\(insert.code) sign=\(signBin.code) dylib=\(signDylib.code)）。已自动还原。"
        }
        _ = RootHelper.rebuildIconCache()
        return nil
    }

    /// 主程序里是否已有我们这条加载指令（重注入时 insert_dylib 会报重复，不能当失败）
    private func binaryHasLoad(_ path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }
        return data.range(of: Data(Self.dylibName.utf8)) != nil
    }

    @discardableResult
    func restore(_ st: TargetStatus) -> String? {
        guard st.installed, let appPath = st.appPath,
              let exe = st.executableName, !exe.isEmpty else {
            return "没找到这个 App 的安装位置。"
        }
        let fm = FileManager.default
        let bin = appPath + "/" + exe
        let backup = bin + Self.backupSuffix
        let dylibDest = appPath + "/Frameworks/" + Self.dylibName

        guard fm.fileExists(atPath: backup) else { return "没有备份，可能本来就没注入过。" }

        killall(exe)
        do {
            if fm.fileExists(atPath: bin) { try? fm.removeItem(atPath: bin) }
            try fm.copyItem(atPath: backup, toPath: bin)
        } catch {
            return "还原失败：\(error.localizedDescription)"
        }
        _ = RootHelper.setPermission(url: URL(fileURLWithPath: bin))
        if fm.fileExists(atPath: dylibDest) { try? fm.removeItem(atPath: dylibDest) }
        _ = RootHelper.rebuildIconCache()
        return nil
    }
}
