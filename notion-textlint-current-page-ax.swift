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
        if CFGetTypeID(value) == CFStringGetTypeID() { return value as? String }
        if CFGetTypeID(value) == CFURLGetTypeID() { return CFURLGetString(value as! CFURL) as String }
        return nil
    }

    static func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        guard let value = copyAttribute(element, attribute),
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return CFBooleanGetValue(value as! CFBoolean)
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

func subtreeFocused(_ element: AXUIElement, depth: Int, visited: inout Int) -> Bool {
    guard depth <= 80, visited < 12_000 else { return false }
    visited += 1
    if AX.boolAttribute(element, kAXFocusedAttribute as CFString) { return true }
    for child in AX.elementsAttribute(element, kAXChildrenAttribute as CFString) {
        if subtreeFocused(child, depth: depth + 1, visited: &visited) { return true }
    }
    return false
}

func focusedPageURL(for appElement: AXUIElement) throws -> String {
    var regions: [(url: String, focused: Bool)] = []
    var visited = 0

    func walk(_ element: AXUIElement, depth: Int) {
        guard depth <= 80, visited < 12_000 else { return }
        visited += 1
        let role = AX.stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        let roleDescription =
            (AX.stringAttribute(element, "AXRoleDescription" as CFString) ?? "").lowercased()
        if role == "AXWebArea" || roleDescription == "html content" {
            if let candidate = pageURL(in: AX.stringAttribute(element, kAXURLAttribute as CFString)) {
                var focusVisited = 0
                regions.append((candidate, subtreeFocused(element, depth: 0, visited: &focusVisited)))
                return
            }
        }
        for child in AX.elementsAttribute(element, kAXChildrenAttribute as CFString) {
            walk(child, depth: depth + 1)
        }
    }

    walk(appElement, depth: 0)
    let focusedRegions = regions.filter { $0.focused }
    guard focusedRegions.count == 1, let result = focusedRegions.first else { throw CaptureError() }
    return result.url
}

func supportedBrowser(_ name: String) -> Bool {
    ["Zen", "Arc", "Google Chrome", "Microsoft Edge", "Safari", "Firefox", "Brave Browser"].contains(name)
}

func capture(app: NSRunningApplication) throws -> (String, String, String) {
    guard AXIsProcessTrusted() else { throw CaptureError() }
    guard let applicationName = app.localizedName,
          applicationName == "Notion" || supportedBrowser(applicationName) else { throw CaptureError() }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    let url = try focusedPageURL(for: appElement)
    let kind = applicationName == "Notion" ? "notion_desktop" : "browser"
    return (applicationName, kind, url)
}

func fail() -> Never { exit(1) }

guard let frontmost = NSWorkspace.shared.frontmostApplication else { fail() }
do {
    let first = try capture(app: frontmost)
    let second = try capture(app: frontmost)
    guard first.0 == second.0, first.1 == second.1, first.2 == second.2 else { fail() }
    let record: [String: Any] = [
        "context": ["kind": first.1, "application": first.0],
        "url": first.2,
    ]
    let data = try JSONSerialization.data(withJSONObject: ["records": [record]], options: [])
    guard let output = String(data: data, encoding: .utf8) else { fail() }
    print(output, terminator: "")
} catch { fail() }
