import AppKit
import Foundation

struct Payload: Decodable {
    let title: String
    let url: String
    let plain: String
    let html: String
}

enum CopyError: Error {
    case invalidPayload
    case encodingFailed
    case pasteboardWriteFailed
}

func main() throws {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let payload = try JSONDecoder().decode(Payload.self, from: input)
    guard !payload.title.isEmpty,
          !payload.url.isEmpty,
          !payload.plain.isEmpty,
          !payload.html.isEmpty else {
        throw CopyError.invalidPayload
    }
    guard let htmlData = payload.html.data(using: .utf8) else {
        throw CopyError.encodingFailed
    }

    let item = NSPasteboardItem()
    guard item.setString(payload.plain, forType: .string),
          item.setData(htmlData, forType: NSPasteboard.PasteboardType("public.html")) else {
        throw CopyError.encodingFailed
    }

    guard NSPasteboard.general.writeObjects([item]) else {
        throw CopyError.pasteboardWriteFailed
    }
}

do {
    try main()
} catch {
    fputs("クリップボードへの書込みに失敗しました。\n", stderr)
    exit(1)
}
