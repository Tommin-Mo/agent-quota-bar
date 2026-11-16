import Foundation
import Security

// 只做一件事：读取 Chromium Safe Storage 口令，交给 collector 在内存里解密 Cookie。
// 独立 helper 让 macOS 的钥匙串授权归到这个 app 内的二进制，而不是 /usr/bin/security。
let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: ChromeSafeStorage <service> <account>\n".utf8))
    exit(2)
}
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: args[1],
    kSecAttrAccount as String: args[2],
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne,
]
var item: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &item)
guard status == errSecSuccess, let data = item as? Data, !data.isEmpty else {
    exit(status == errSecItemNotFound ? 44 : 1)
}
FileHandle.standardOutput.write(data)
