import Foundation

/// TwoYi 托管最新版信息：查 wozofa-ship-it/twoyi-ipa 的 latest
/// release（公开 API，不用任何 token，绝不能把 PAT 写进包里）。
/// tag 形如 v1.2.6-940-zh-CN；资产里找第一个 .ipa。
struct CZFTwoYiUpdateInfo {
    /// 版本号，如 1.2.6
    let version: String
    /// 构建号，如 940
    let build: String
    let downloadURL: URL
    /// 资产体积（字节），供下载前空间预检；读不到为 0，调用方
    /// 回落到 CZFTwoYi.downloadSize。
    let size: Int64
}

enum CZFTwoYiUpdateCheck {
    private static let apiURL = URL(string: "https://api.github.com/repos/wozofa-ship-it/twoyi-ipa/releases/latest")!

    /// 查一次最新托管版：tag 解析不到、或没有 .ipa 资产都算失败，
    /// 调用方静默回落到 CZFTwoYi 的静态托管值，不弹错。
    static func check(completion: @escaping (Result<CZFTwoYiUpdateInfo, Error>) -> Void) {
        var request = URLRequest(url: apiURL)
        // CZFUpdateCheck 同款：15 秒超时，弱网不一直转。
        request.timeoutInterval = 15
        request.setValue("LiveContainer", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let (version, build) = parseTag(tag),
                  let assets = json["assets"] as? [[String: Any]],
                  let asset = assets.first(where: { (($0["name"] as? String) ?? "").hasSuffix(".ipa") }),
                  let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString) else {
                completion(.failure(NSError(domain: "CZFTwoYiUpdateCheck", code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: "TwoYi 托管信息里没有可用版本"])))
                return
            }
            let size = (asset["size"] as? NSNumber)?.int64Value ?? 0
            completion(.success(CZFTwoYiUpdateInfo(version: version, build: build, downloadURL: url, size: size)))
        }.resume()
    }

    /// v1.2.6-940-zh-CN → ("1.2.6", "940")；格式不对返回 nil。
    private static func parseTag(_ tag: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: "^v([0-9.]+)-([0-9]+)-zh-CN$"),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let vRange = Range(match.range(at: 1), in: tag),
              let bRange = Range(match.range(at: 2), in: tag) else { return nil }
        return (String(tag[vRange]), String(tag[bRange]))
    }
}
