import AppKit

/// 把 curl / SSL / DNS 的长报错收成用户能一眼看懂的具体原因。
enum ProviderErrorText {
    static func summary(_ raw: String?) -> String {
        let text = (raw ?? "").lowercased()
        if text.contains("ssl_") || text.contains("ssl_connect") || text.contains("curl: (35)") {
            return "SSL 连接失败"
        }
        if text.contains("could not resolve host") || text.contains("curl: (6)") || text.contains("enotfound") || text.contains("eai_again") {
            return "DNS 解析失败"
        }
        if text.contains("timed out") || text.contains("timeout") || text.contains("etimedout")
            || text.contains("econnreset") || text.contains("curl: (28)") {
            return "连接超时"
        }
        if text.contains("network is unreachable") || text.contains("no route to host") {
            return "网络不可达"
        }
        if text.contains("connection refused") || text.contains("failed to connect") || text.contains("curl: (7)") {
            return "无法连接服务器"
        }
        if text.contains("401") || text.contains("unauthorized") || text.contains("登录态") {
            return "登录态失效"
        }
        if text.contains("403") || text.contains("forbidden") {
            return "无权限访问"
        }
        if text.contains("未找到") || text.contains("没有登录") || text.contains("not found") {
            return "未找到登录态"
        }
        return "连接失败"
    }

    static func hint(for summary: String) -> String {
        switch summary {
        case "SSL 连接失败": return "检查代理或网络后重试"
        case "DNS 解析失败", "网络不可达", "连接超时", "无法连接服务器": return "检查网络后重试"
        case "登录态失效": return "重新登录后重试"
        case "未找到登录态": return "先完成登录"
        case "无权限访问": return "检查账号权限"
        default: return "检查配置后重试"
        }
    }

    static func display(_ raw: String?) -> String {
        let text = summary(raw)
        return "\(text) · \(hint(for: text))"
    }
}
