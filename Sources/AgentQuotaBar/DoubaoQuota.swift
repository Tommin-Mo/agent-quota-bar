import AppKit
import ScreenCaptureKit
import Vision

/// Read only the labelled account row in the Doubao client’s sidebar.
enum DoubaoQuota {
    static let bundleID = "com.bot.neotix.doubao"

    static func amount(in text: String) -> Int? {
        // Vision sometimes reads the small diagonal link arrow as 入.
        let pattern = #"^\s*([0-9]{1,3}(?:[,，][0-9]{3})+|[0-9]+)\s*[↗入]?\s*$"#
        guard let match = text.range(of: pattern, options: .regularExpression) else { return nil }
        return Int(text[match].filter { $0.isASCII && $0.isNumber })
    }

    static func openPermissions() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func read() async -> String {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return "notRunning" }
        guard CGPreflightScreenCaptureAccess() else { return "permission" }
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "读取豆包侧栏额度")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let windows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID && $0.windowLayer == 0 && $0.frame.width > 250 && $0.frame.height > 150 }
            var amounts: [Int] = []
            for window in windows {
                let config = SCStreamConfiguration()
                let width = min(window.frame.width, 300)
                config.sourceRect = CGRect(x: 0, y: 0, width: width, height: window.frame.height)
                config.width = Int(width * 2)
                config.height = Int(window.frame.height * 2)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                guard let sidebar = image.cropping(to: CGRect(x: 0, y: 0, width: min(image.width, 600), height: image.height)) else { continue }
                let request = VNRecognizeTextRequest()
                request.usesCPUOnly = true
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: sidebar).perform([request])
                let rows = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    return (text, observation.boundingBox)
                }
                for (label, box) in rows where box.minX < 0.25 && label.range(of: #"^[^\p{L}\p{N}]*可用额度\s*$"#, options: .regularExpression) != nil {
                    let matches = rows.filter { _, rect in
                        rect.minX > box.maxX && abs(rect.midY - box.midY) < max(rect.height, box.height) * 0.55
                    }.compactMap { amount(in: $0.0) }
                    guard matches.count == 1 else { return "notVisible" }
                    amounts.append(matches[0])
                }
            }
            return amounts.count == 1 ? String(amounts[0]) : "notVisible"
        } catch { return "unavailable" }
    }
}
