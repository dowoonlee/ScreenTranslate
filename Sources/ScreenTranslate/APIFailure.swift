import Foundation
import OSLog

/// Response text is shown only after removing request secrets and source content.
/// Persistent logs contain HTTP status only, never response bodies or request data.
struct APIFailure {
    static let logger = Logger(subsystem: "dev.screentranslate.app", category: "translation")

    static func message(data: Data, status: Int, provider: Provider, secrets: [String]) -> String {
        var result = "\(provider.rawValue) API 오류 (HTTP \(status))"
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        let type = error?["type"] as? String ?? ""
        if type.range(of: #"^[a-z_]{1,64}$"#, options: .regularExpression) != nil { result += " · \(type)" }
        if let raw = error?["message"] as? String, !raw.isEmpty {
            var safe = raw
            for secret in secrets.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
                safe = safe.replacingOccurrences(of: secret, with: "[비공개]")
            }
            for pattern in [#"sk-[A-Za-z0-9_-]+"#, #"(?i)Bearer\s+\S+"#, #"[A-Za-z0-9+/=_-]{80,}"#, #"data:image/[^\s]+"#] {
                safe = safe.replacingOccurrences(of: pattern, with: "[비공개]", options: .regularExpression)
            }
            safe = safe.components(separatedBy: .controlCharacters).joined(separator: " ")
            result += "\n" + String(safe.prefix(1200))
            let lower = raw.lowercased()
            if lower.contains("anthropic-workspace-id") {
                result += "\n앱 설정 → Claude → 워크스페이스 ID를 입력하고 저장한 뒤 다시 시도해 주세요."
            }
            if lower.contains("credit") || lower.contains("billing") || lower.contains("spend limit") {
                result += "\nAPI 콘솔에서 잔액·결제·지출 한도를 확인해 주세요."
            }
        } else {
            result += "\n서버가 상세 JSON 오류를 제공하지 않았습니다."
        }
        return result
    }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
