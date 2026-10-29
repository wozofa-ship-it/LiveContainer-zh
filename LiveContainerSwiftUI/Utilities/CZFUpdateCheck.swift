import Foundation

/// fork nightly 更新信息：只认 fork 自己的 nightly release，
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
    private static let apiURL = URL(string: "https://api.github.com/repos/wozofa-ship-it/LiveContainer-zh/releases/tags/nightly")!
    private static let fallbackIPAURL = URL(string: "https://github.com/wozofa-ship-it/LiveContainer-zh/releases/download/nightly/LiveContainer.ipa")!

    /// 本机短提交号：包里 LCVersionInfo 是 "Release (main/25c5124)"
    /// 这种格式，构建时的 Run Script 写进去的；解析不到就返回 nil。
    static func currentCommit() -> String? {
        guard let info = Bundle.main.infoDictionary?["LCVersionInfo"] as? String,
              let slash = info.lastIndex(of: "/") else { return nil }
        let tail = info[info.index(after: slash)...]
        let commit = tail.prefix(while: { $0.isLetter || $0.isNumber })
        return commit.isEmpty ? nil : String(commit)
    }

    /// 查一次 fork nightly：正文第一行就是 "**Commit:** [完整 SHA](...)”，
    /// 资产里找独立版 LiveContainer.ipa（不是 +SideStore 那个二合一版）。
    static func check(completion: @escaping (Result<CZFUpdateInfo, Error>) -> Void) {
        var request = URLRequest(url: apiURL)
        request.setValue("LiveContainer", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = json["body"] as? String,
                  let fullSHA = nightlyCommitSHA(from: body) else {
                completion(.failure(NSError(domain: "CZFUpdateCheck", code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: "nightly 信息里没有提交号"])))
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

    private static func nightlyCommitSHA(from body: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "Commit:\\*\\* \\[([0-9a-f]{40})\\]"),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body) else { return nil }
        return String(body[range])
    }
}
