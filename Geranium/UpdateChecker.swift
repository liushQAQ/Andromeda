//
//  UpdateChecker.swift
//  自由轨迹 (FreeTrack)
//
//  云端版本检测：读取 GitHub Release 里的 latest.json / API，
//  比对版本号后提示下载最新 tipa，可直接交给 TrollStore 安装。
//

import Foundation
import SwiftUI
import UIKit

struct FreeTrackRelease {
    let version: String
    let build: Int
    let tipaURL: String
    let changelog: String
}

final class UpdateCenter: ObservableObject {
    static let shared = UpdateCenter()

    static let repoSlug = "liushQAQ/Andromeda"
    static let releasesPage = "https://github.com/liushQAQ/Andromeda/releases/latest"
    private static let autoCheckKey = "freetrack.lastAutoCheck"

    @Published var checking: Bool = false

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    // MARK: - 本机版本

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static var appBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    var currentVersion: String { UpdateCenter.appVersion }
    var currentBuild: Int { UpdateCenter.appBuild }
    var versionLine: String { "v\(currentVersion) (\(currentBuild))" }

    // MARK: - 检测入口

    /// 云端比对。manual=true 时无论结果都给出提示，false 时只有发现新版本才弹。
    func check(manual: Bool) {
        if checking { return }
        checking = true

        let group = DispatchGroup()
        let lock = NSLock()
        var hit: FreeTrackRelease?
        var failedSources: [String] = []

        for source in UpdateCenter.sources() {
            group.enter()
            UpdateCenter.fetch(source.url) { object in
                lock.lock()
                if hit == nil, let dict = object as? [String: Any],
                   let release = UpdateCenter.parse(dict, sourceName: source.name) {
                    hit = release
                } else if hit == nil {
                    failedSources.append(source.name)
                }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.checking = false
            lock.lock()
            let release = hit
            let failed = failedSources
            lock.unlock()

            if let release = release {
                if UpdateCenter.isNewer(release) {
                    self.presentUpdate(release)
                } else if manual {
                    self.presentUpToDate(release)
                }
            } else if manual {
                self.presentFailure(failed)
            }
        }
    }

    /// 启动后静默检查：只在新版本出现时提示，6 小时内不重复。
    func autoCheckIfNeeded() {
        if AppSettings().updBypass { return }
        let last = UserDefaults.standard.double(forKey: UpdateCenter.autoCheckKey)
        let now = Date().timeIntervalSince1970
        if last > 0 && now - last < 6 * 3600 { return }
        UserDefaults.standard.set(now, forKey: UpdateCenter.autoCheckKey)
        check(manual: false)
    }

    // MARK: - 数据源

    private struct Source {
        let name: String
        let url: String
    }

    private static func sources() -> [Source] {
        let json = "https://github.com/\(repoSlug)/releases/latest/download/latest.json"
        return [
            Source(name: "ghfast", url: "https://ghfast.top/\(json)"),
            Source(name: "gh-proxy", url: "https://gh-proxy.com/\(json)"),
            Source(name: "github", url: json),
            Source(name: "github-api", url: "https://api.github.com/repos/\(repoSlug)/releases/latest")
        ]
    }

    private static func fetch(_ urlString: String, completion: @escaping (Any?) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("FreeTrack-iOS/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, _, _ in
            guard let data = data, !data.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                completion(nil)
                return
            }
            completion(object)
        }.resume()
    }

    // MARK: - 解析

    private static func stripTag(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    private static func parse(_ dict: [String: Any], sourceName: String) -> FreeTrackRelease? {
        var version = ""
        var build = 0
        var tipaURL = ""
        var changelog = ""

        if let v = dict["version"] as? String {
            version = stripTag(v)
        } else if let tag = dict["tag_name"] as? String {
            version = stripTag(tag)
        }

        if let b = dict["build"] as? Int {
            build = b
        } else if let b = dict["build"] as? String, let n = Int(b) {
            build = n
        }

        if let u = dict["tipa_url"] as? String, !u.isEmpty {
            tipaURL = u
        } else if let u = dict["download_url"] as? String, !u.isEmpty {
            tipaURL = u
        } else if let assets = dict["assets"] as? [[String: Any]] {
            let tipas = assets.filter { (($0["name"] as? String) ?? "").lowercased().hasSuffix(".tipa") }
            if let first = tipas.first, let u = first["browser_download_url"] as? String {
                tipaURL = u
            }
        }

        if let s = dict["changelog"] as? String {
            changelog = s
        } else if let arr = dict["changelog"] as? [String] {
            changelog = arr.joined(separator: "\n")
        } else if let s = dict["body"] as? String {
            changelog = s
        }

        guard !version.isEmpty else { return nil }
        if tipaURL.isEmpty {
            tipaURL = "https://github.com/\(repoSlug)/releases/download/v\(version)/Geranium-\(version).tipa"
        }
        return FreeTrackRelease(version: version, build: build, tipaURL: tipaURL, changelog: changelog)
    }

    // MARK: - 版本比较

    private static func numbers(_ text: String) -> [Int] {
        var out: [Int] = []
        var current = ""
        for ch in text {
            if ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                out.append(Int(current) ?? 0)
                current = ""
            }
        }
        if !current.isEmpty { out.append(Int(current) ?? 0) }
        return out
    }

    static func isNewer(_ release: FreeTrackRelease) -> Bool {
        let remote = numbers(release.version)
        let local = numbers(appVersion)
        for i in 0..<max(remote.count, local.count) {
            let a = i < remote.count ? remote[i] : 0
            let b = i < local.count ? local[i] : 0
            if a != b { return a > b }
        }
        if release.build > 0 && appBuild > 0 && release.build != appBuild {
            return release.build > appBuild
        }
        return false
    }

    // MARK: - 提示与安装

    private func presentUpdate(_ release: FreeTrackRelease) {
        var message = "当前版本：\(versionLine)\n最新版本：v\(release.version)"
        if release.build > 0 { message += " (\(release.build))" }
        let notes = release.changelog.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            let clipped = notes.count > 600 ? String(notes.prefix(600)) + "\n…" : notes
            message += "\n\n更新内容：\n\(clipped)"
        }

        let alert = UIAlertController(title: "发现新版本 v\(release.version)", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "立即更新", style: .default) { _ in
            UpdateCenter.install(release)
        })
        alert.addAction(UIAlertAction(title: "稍后", style: .cancel))
        UIApplication.shared.present(alert: alert)
    }

    private func presentUpToDate(_ release: FreeTrackRelease) {
        let alert = UIAlertController(
            title: "已是最新版本",
            message: "当前 \(versionLine)\n云端最新：v\(release.version)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        UIApplication.shared.present(alert: alert)
    }

    private func presentFailure(_ failed: [String]) {
        let alert = UIAlertController(
            title: "检查更新失败",
            message: "没连上云端版本信息，请确认网络后重试。\n失败线路：\(failed.joined(separator: "、"))",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "打开发布页", style: .default) { _ in
            if let url = URL(string: UpdateCenter.releasesPage) {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: "关闭", style: .cancel))
        UIApplication.shared.present(alert: alert)
    }

    /// 优先交给 TrollStore 直接安装；未开启 URL Scheme 时退回浏览器下载页。
    static func install(_ release: FreeTrackRelease) {
        if let encoded = release.tipaURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let troll = URL(string: "apple-magnifier://install?url=\(encoded)"),
           UIApplication.shared.canOpenURL(troll) {
            UIApplication.shared.open(troll)
            return
        }
        if let url = URL(string: release.tipaURL) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - 首页 / 设置页共用的更新卡片

struct UpdateCard: View {
    @ObservedObject private var center = UpdateCenter.shared

    var body: some View {
        Button(action: { UpdateCenter.shared.check(manual: true) }) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.indigo)

                VStack(alignment: .leading, spacing: 3) {
                    Text(center.checking ? "正在检查更新…" : "检查更新")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Text("当前 \(center.versionLine) · 云端比对最新 tipa")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if center.checking {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .glassCard()
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(center.checking)
    }
}
