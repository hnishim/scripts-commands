import AppKit
import ApplicationServices
import Darwin
import Foundation

struct CaptureError: Error {}

enum AX {
    static func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        copyAttribute(element, attribute) as? String
    }

    static func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func elementsAttribute(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        guard let values = copyAttribute(element, attribute) as? [Any] else { return [] }
        return values.map { unsafeBitCast($0, to: AXUIElement.self) }
    }
}

let pageURLPattern = try! NSRegularExpression(
    pattern: #"https://(?:app\.notion\.com|notion\.so|www\.notion\.so)/[^\s\"<>]+"#
)

func pageURL(in value: String?) -> String? {
    guard let value else { return nil }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return pageURLPattern.firstMatch(in: value, range: range).map {
        String(value[Range($0.range, in: value)!])
    }
}

func unique(_ values: [String]) -> [String] {
    var result: [String] = []
    var seen = Set<String>()
    for value in values where seen.insert(value).inserted {
        result.append(value)
    }
    return result
}

func accessibilityURL(in window: AXUIElement) throws -> String {
    var stack: [(AXUIElement, Int)] = [(window, 0)]
    var visited = 0
    var urls: [String] = []

    while let (element, depth) = stack.popLast(), visited < 800 {
        visited += 1
        // AXURL belongs to the active web-area element. Do not descend into
        // that element after finding it, or page links would become competing
        // candidates for the currently displayed page.
        if let candidate = pageURL(in: AX.stringAttribute(element, "AXURL" as CFString)) {
            urls.append(candidate)
            continue
        }

        guard depth < 16 else { continue }
        for child in AX.elementsAttribute(element, kAXChildrenAttribute as CFString).reversed() {
            stack.append((child, depth + 1))
        }
    }

    let candidates = unique(urls)
    guard candidates.count == 1, let result = candidates.first else { throw CaptureError() }
    return result
}

func focusedWindow(for appElement: AXUIElement) throws -> AXUIElement {
    if let focused = AX.elementAttribute(appElement, kAXFocusedWindowAttribute as CFString) {
        return focused
    }
    let windows = AX.elementsAttribute(appElement, kAXWindowsAttribute as CFString)
    guard windows.count == 1, let only = windows.first else { throw CaptureError() }
    return only
}

func supportedBrowser(_ name: String) -> Bool {
    ["Zen", "Arc", "Google Chrome", "Microsoft Edge", "Safari", "Firefox", "Brave Browser"].contains(name)
}

func capture(app: NSRunningApplication) throws -> (String, String, String) {
    guard AXIsProcessTrusted() else { throw CaptureError() }
    guard let applicationName = app.localizedName,
          applicationName == "Notion" || supportedBrowser(applicationName) else {
        throw CaptureError()
    }

    let pid = app.processIdentifier
    let appElement = AXUIElementCreateApplication(pid)
    let window = try focusedWindow(for: appElement)
    let url = try accessibilityURL(in: window)
    let kind = applicationName == "Notion" ? "notion_desktop" : "browser"
    return (applicationName, kind, url)
}

func fail() -> Never {
    exit(1)
}

guard let frontmost = NSWorkspace.shared.frontmostApplication else { fail() }
do {
    let first = try capture(app: frontmost)
    let second = try capture(app: frontmost)
    guard first.0 == second.0, first.1 == second.1, first.2 == second.2 else { fail() }

    let record: [String: Any] = [
        "context": [
            "kind": first.1,
            "application": first.0,
            "window_id": "pid-\(frontmost.processIdentifier)",
            "tab_id": "accessibility-active-tab",
        ],
        "url": first.2,
    ]
    let payload: [String: Any] = ["records": [record]]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    guard let output = String(data: data, encoding: .utf8) else { fail() }
    print(output, terminator: "")
} catch {
    fail()
}
