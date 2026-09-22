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
        guard let value = copyAttribute(element, attribute) else { return nil }
        if CFGetTypeID(value) == CFStringGetTypeID() {
            return value as? String
        }
        if CFGetTypeID(value) == CFURLGetTypeID() {
            return CFURLGetString(value as! CFURL) as String
        }
        return nil
    }

    static func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return value as! AXUIElement
    }

    static func elementsAttribute(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        guard let values = copyAttribute(element, attribute) as? [Any] else { return [] }
        return values.compactMap { value in
            let cfValue = value as CFTypeRef
            guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { return nil }
            return cfValue as! AXUIElement
        }
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

func focusedPageURL(for appElement: AXUIElement) throws -> String {
    guard var current = AX.elementAttribute(appElement, kAXFocusedUIElementAttribute as CFString) else {
        throw CaptureError()
    }

    var visited = 0
    while visited < 32 {
        if AX.stringAttribute(current, kAXRoleAttribute as CFString) == "AXWebArea",
           let candidate = pageURL(in: AX.stringAttribute(current, kAXURLAttribute as CFString)) {
            return candidate
        }
        guard let parent = AX.elementAttribute(current, kAXParentAttribute as CFString) else {
            break
        }
        current = parent
        visited += 1
    }

    throw CaptureError()
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
    let url = try focusedPageURL(for: appElement)
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
