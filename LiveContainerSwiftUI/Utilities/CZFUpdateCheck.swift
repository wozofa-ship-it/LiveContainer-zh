import Foundation

/// fork update 更新信息：只认 fork 自己的 update release，
/// 不认源里的 apps_nightly.json（它下载地址指向上游 nightly，
/// 装了会丢掉 fork 的功能和 🅥 改动），也不认 source.json 里
/// 上游 3.8.0 那条。查 GitHub 公开 API，不用任何 token，
/// 绝不能把 PAT 写进包里。
struct CZFUpdateInfo {
    /// 短提交号，如 25c5124
    let commit: String
    let publishedAt: Date?
    let downloadURL: URL
}

enum CZFUpdateCheck {
    private static let apiURL = URL(string: "https://api.github.com/repos/wozofa-ship-it/LiveContainer-zh/releases/tags/update")!
    private static let fallbackIPAURL = URL(string: "https://github.com/wozofa-ship-it/LiveContainer-zh/releases/download/update/LiveContainer.ipa")!

    /// 本机短提交号：包里 LCVersionInfo 是 "Release (main/25c5124)"
    /// 这种格式，构建时的 Run Script 写进去的；解析不到就返回 nil。
    static func currentCommit() -> String? {
        guard let info = Bundle.main.infoDictionary?["LCVersionInfo"] as? String,
              let slash = info.lastIndex(of: "/") else { return nil }
        let tail = info[info.index(after: slash)...]
        let commit = tail.prefix(while: { $0.isLetter || $0.isNumber })
        return commit.isEmpty ? nil : String(commit)
    }

    /// 本机构建日期（UTC）：3.8.637（B3）起 Run Script 把构建日期
    /// 写进 LCVersionInfo 末尾，格式 "Release (main/25c5124)
    /// 2026-11-26T01:40:00Z"。老包没有这一段，解析不到返回 nil，
    /// 调用方回落到只比提交号的旧行为。SHA 本身无序、无法判断新旧，
    /// 只有这个日期能判本地是不是比 update 发布源新。
    static func currentBuildDate() -> Date? {
        guard let info = Bundle.main.infoDictionary?["LCVersionInfo"] as? String,
              let last = info.split(separator: " ").last else { return nil }
        return ISO8601DateFormatter().date(from: String(last))
    }

    /// 查一次 fork update：正文第一行就是 "**Commit:** [完整 SHA](...)"，
    /// 资产里找独立版 LiveContainer.ipa（不是 +SideStore 那个二合一版）。
    static func check(completion: @escaping (Result<CZFUpdateInfo, Error>) -> Void) {
        var request = URLRequest(url: apiURL)
        // 3.8.645（B1）：更新检查请求无超时，弱网下“检查中…”可卡
        // URLSession 默认 60 秒；15 秒超时走现有失败分支
        //（“检查失败，点一下重试”），期间设置行不再一直转。
        request.timeoutInterval = 15
        request.setValue("LiveContainer", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = json["body"] as? String,
                  let fullSHA = updateCommitSHA(from: body) else {
                completion(.failure(NSError(domain: "CZFUpdateCheck", code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: "update 信息里没有提交号"])))
                return
            }
            var publishedAt: Date?
            if let publishedString = json["published_at"] as? String {
                publishedAt = ISO8601DateFormatter().date(from: publishedString)
            }
            var downloadURL = fallbackIPAURL
            if let assets = json["assets"] as? [[String: Any]],
               let asset = assets.first(where: { ($0["name"] as? String) == "LiveContainer.ipa" }),
               let urlString = asset["browser_download_url"] as? String,
               let url = URL(string: urlString) {
                downloadURL = url
            }
            completion(.success(CZFUpdateInfo(commit: String(fullSHA.prefix(7)),
                                               publishedAt: publishedAt,
                                               downloadURL: downloadURL)))
        }.resume()
    }

    private static func updateCommitSHA(from body: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "Commit:\\*\\* \\[([0-9a-f]{40})\\]"),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body) else { return nil }
        return String(body[range])
    }
}
