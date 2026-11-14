import Foundation

struct FileCodec {
    var encoding: String.Encoding = .utf8
    var byteOrderMark = Data()

    static func decode(_ data: Data) throws -> (String, FileCodec) {
        let markers: [(Data, String.Encoding)] = [
            (Data([0xEF, 0xBB, 0xBF]), .utf8),
            (Data([0xFF, 0xFE]), .utf16LittleEndian),
            (Data([0xFE, 0xFF]), .utf16BigEndian)
        ]
        for (mark, encoding) in markers where data.starts(with: mark) {
            guard let value = String(data: data.dropFirst(mark.count), encoding: encoding) else {
                throw invalidEncoding()
            }
            return (value, FileCodec(encoding: encoding, byteOrderMark: mark))
        }
        guard let value = String(data: data, encoding: .utf8) else { throw invalidEncoding() }
        return (value, FileCodec())
    }

    func encode(_ text: String) throws -> Data {
        guard let data = text.data(using: encoding, allowLossyConversion: false) else {
            throw Self.invalidEncoding()
        }
        return byteOrderMark + data
    }

    var label: String { encoding == .utf8 ? "UTF-8" : "UTF-16" }

    private static func invalidEncoding() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError,
                userInfo: [NSLocalizedDescriptionKey: "无法以 UTF-8 或带 BOM 的 UTF-16 读取这份文件。",
                           NSLocalizedRecoverySuggestionErrorKey: "请先将文件转换为 UTF-8。原文件没有被修改。"])
    }
}
