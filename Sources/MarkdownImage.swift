import AppKit

/// Images own their source boundary: Foundation omits empty alt positions and
/// drops some Unicode destinations. Rendering never rewrites the Markdown.
struct MarkdownImage {
    let range: NSRange
    let alt: String
    let destination: String
    let url: URL?

    static func parse(_ source: String, baseURL: URL?, excluding excluded: [NSRange]) -> [MarkdownImage] {
        let text = source as NSString
        var blocked = IndexSet()
        for range in excluded { blocked.insert(integersIn: range.location..<NSMaxRange(range)) }
        if let comments = try? NSRegularExpression(pattern: "<!--[\\s\\S]*?(?:-->|$)") {
            for match in comments.matches(in: source, range: NSRange(location: 0, length: text.length)) {
                blocked.insert(integersIn: match.range.location..<NSMaxRange(match.range))
            }
        }
        func escaped(_ i: Int) -> Bool {
            var j = i
            while j > 0 && text.character(at: j - 1) == 92 { j -= 1 }
            return (i - j) % 2 == 1
        }
        func space(_ i: Int) -> Bool { i < text.length && [9, 10, 13, 32].contains(text.character(at: i)) }
        func labelEnd(_ start: Int) -> Int? {
            var depth = 1
            var i = start + 1
            while i < text.length {
                let c = text.character(at: i)
                if !escaped(i) {
                    if c == 91 { depth += 1 }
                    if c == 93 { depth -= 1; if depth == 0 { return i } }
                }
                i += 1
            }
            return nil
        }
        func unescape(_ value: String) -> String {
            value.replacingOccurrences(of: #"\\([\x21-\x2F\x3A-\x40\x5B-\x60\x7B-\x7E])"#,
                                       with: "$1", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
        }
        func destination(_ start: Int) -> (String, Int)? {
            guard start < text.length else { return nil }
            var i = start
            if text.character(at: i) == 60 {
                i += 1
                let begin = i
                while i < text.length {
                    let c = text.character(at: i)
                    if [10, 13].contains(c) { return nil }
                    if c == 62 && !escaped(i) {
                        return (unescape(text.substring(with: NSRange(location: begin, length: i - begin))), i + 1)
                    }
                    i += 1
                }
                return nil
            }
            var depth = 0
            while i < text.length {
                let c = text.character(at: i)
                if !escaped(i) {
                    if space(i) { break }
                    if c == 40 { depth += 1 }
                    if c == 41 { if depth == 0 { break }; depth -= 1 }
                    if c == 60 { return nil }
                }
                i += 1
            }
            guard depth == 0, i > start else { return nil }
            return (unescape(text.substring(with: NSRange(location: start, length: i - start))), i)
        }
        func normalized(_ value: String) -> String {
            unescape(value).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        }
        var references: [String: String] = [:]
        let definitions = try! NSRegularExpression(pattern: #"(?m)^[ \t]{0,3}\[([^\]\r\n]+)\]:[ \t]*"#)
        for match in definitions.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            guard !blocked.contains(match.range.location),
                  let (value, _) = destination(NSMaxRange(match.range)) else { continue }
            let key = normalized(text.substring(with: match.range(at: 1)))
            if references[key] == nil { references[key] = value }
            let line = text.lineRange(for: match.range)
            blocked.insert(integersIn: line.location..<NSMaxRange(line))
        }
        var images: [MarkdownImage] = []
        var i = 0
        while i + 1 < text.length {
            guard text.character(at: i) == 33, text.character(at: i + 1) == 91,
                  !escaped(i), !blocked.contains(i), let close = labelEnd(i + 1) else { i += 1; continue }
            let alt = text.substring(with: NSRange(location: i + 2, length: close - i - 2))
            var end = close + 1
            var target: String?
            if end < text.length && text.character(at: end) == 40 {
                var cursor = end + 1
                while space(cursor) { cursor += 1 }
                if let (value, after) = destination(cursor) {
                    cursor = after
                    let hadSpace = space(cursor)
                    while space(cursor) { cursor += 1 }
                    if hadSpace, cursor < text.length, [34, 39, 40].contains(text.character(at: cursor)) {
                        let closing: UniChar = text.character(at: cursor) == 40 ? 41 : text.character(at: cursor)
                        cursor += 1
                        while cursor < text.length && (text.character(at: cursor) != closing || escaped(cursor)) { cursor += 1 }
                        if cursor < text.length { cursor += 1 }
                        while space(cursor) { cursor += 1 }
                    }
                    if cursor < text.length && text.character(at: cursor) == 41 {
                        target = value
                        end = cursor + 1
                    }
                }
            } else if end < text.length && text.character(at: end) == 91, let refEnd = labelEnd(end) {
                let ref = text.substring(with: NSRange(location: end + 1, length: refEnd - end - 1))
                target = references[normalized(ref.isEmpty ? alt : ref)]
                end = refEnd + 1
            } else { target = references[normalized(alt)] }
            if let target, !target.isEmpty {
                images.append(MarkdownImage(range: NSRange(location: i, length: end - i),
                                            alt: unescape(alt), destination: target,
                                            url: resolve(target, baseURL: baseURL)))
                i = end
            } else { i += 1 }
        }
        return images
    }

    static func resolve(_ value: String, baseURL: URL?) -> URL? {
        if value.hasPrefix("/") { return URL(fileURLWithPath: value.removingPercentEncoding ?? value) }
        if value.hasPrefix("~/") {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.insert(charactersIn: "%#")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: encoded, relativeTo: baseURL)?.absoluteURL,
              ["file", "http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}
