import AppKit
import Foundation

struct Page: Decodable {
    let title: String
    let url: String
}

struct Link: Encodable {
    let html: String
    let text: String
}

enum PageError: Error {
    case invalid
    case write
}

func validate(_ page: Page) throws {
    let title = page.title
    let rawURL = page.url
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !title.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
          !rawURL.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
          let url = URLComponents(string: rawURL),
          url.scheme == "https",
          ["notion.so", "www.notion.so"].contains(url.host ?? ""),
          url.user == nil, url.password == nil,
          !url.path.isEmpty, url.path != "/", url.fragment == nil else {
        throw PageError.invalid
    }
}

func htmlEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

func markdownLabel(_ value: String) -> String {
    var result = ""
    for char in value {
        if char == "\\" || char == "[" || char == "]" {
            result.append("\\")
        }
        result.append(char)
    }
    return result
}

func render(_ page: Page) throws -> Link {
    try validate(page)
    let html = "<a href=\"" + htmlEscape(page.url) + "\">" + htmlEscape(page.title) + "</a>"
    // Encode Markdown destination delimiters while preserving the navigated URL.
    let destination = page.url.replacingOccurrences(of: "(", with: "%28")
        .replacingOccurrences(of: ")", with: "%29")
    return Link(html: html, text: "[" + markdownLabel(page.title) + "](" + destination + ")")
}

func main() throws {
    guard CommandLine.arguments.count == 2,
          ["--render", "--copy"].contains(CommandLine.arguments[1]) else {
        throw PageError.invalid
    }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let page = try JSONDecoder().decode(Page.self, from: input)
    let link = try render(page)
    if CommandLine.arguments[1] == "--render" {
        let output = try JSONEncoder().encode(link)
        FileHandle.standardOutput.write(output)
        return
    }

    let item = NSPasteboardItem()
    guard item.setString(link.text, forType: .string),
          let html = link.html.data(using: .utf8),
          item.setData(html, forType: NSPasteboard.PasteboardType("public.html")) else {
        throw PageError.write
    }
    // Prepare both representations before a single pasteboard write.
    guard NSPasteboard.general.writeObjects([item]) else { throw PageError.write }
}

do {
    try main()
} catch {
    fputs("ページ情報の検証またはクリップボード書込みに失敗しました。\n", stderr)
    exit(1)
}
