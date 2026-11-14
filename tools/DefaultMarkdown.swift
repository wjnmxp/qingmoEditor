import AppKit
import UniformTypeIdentifiers

let arguments = Array(CommandLine.arguments.dropFirst())
guard let mode = arguments.first, ["--inspect", "--apply"].contains(mode), arguments.count >= 2 else {
    fputs("Usage: DefaultMarkdown --inspect|--apply REPORT.json [sample.md ...]\n", stderr)
    exit(2)
}
let reportURL = URL(fileURLWithPath: arguments[1])
let application = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/清墨.app")
guard Bundle(url: application)?.bundleIdentifier == "net.qingmo.editor" else {
    fputs("Installed Qingmo application was not found.\n", stderr)
    exit(1)
}
let samples = arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
let broadTypes: Set<String> = ["public.item", "public.content", "public.data", "public.text", "public.plain-text"]
var candidates = UTType.types(tag: "md", tagClass: .filenameExtension, conformingTo: nil)
for sample in samples {
    if let type = try? sample.resourceValues(forKeys: [.contentTypeKey]).contentType { candidates.append(type) }
}
var seen: Set<String> = []
let types = candidates.filter {
    !broadTypes.contains($0.identifier)
        && ($0.tags[.filenameExtension]?.contains(where: { $0.lowercased() == "md" }) ?? false)
        && seen.insert($0.identifier).inserted
}.sorted { $0.identifier < $1.identifier }
guard !types.isEmpty else {
    fputs("No Markdown-specific content types found; plain-text defaults were not changed.\n", stderr)
    exit(1)
}
let workspace = NSWorkspace.shared
func snapshot() -> [String: Any] {
    [
        "types": types.map { type in
            ["identifier": type.identifier,
             "defaultApplication": workspace.urlForApplication(toOpen: type)?.path as Any? ?? NSNull()] as [String: Any]
        },
        "files": samples.map { file in
            ["path": file.path,
             "defaultApplication": workspace.urlForApplication(toOpen: file)?.path as Any? ?? NSNull()] as [String: Any]
        },
        "installedCopies": workspace.urlsForApplications(withBundleIdentifier: "net.qingmo.editor").map(\.path)
    ]
}
var report: [String: Any] = [
    "time": ISO8601DateFormatter().string(from: Date()),
    "requestedApplication": application.path,
    "before": snapshot(),
    "applied": false
]
func saveReport() throws {
    try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        .write(to: reportURL, options: .atomic)
}
try saveReport()
if mode == "--apply" {
    var changed: [String] = []
    for type in types {
        var done = false
        var failure: Error?
        workspace.setDefaultApplication(at: application, toOpen: type) { error in
            failure = error
            done = true
        }
        while !done { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        if let failure {
            report["error"] = failure.localizedDescription
            report["changedTypes"] = changed
            report["after"] = snapshot()
            try saveReport()
            fputs("Default change failed: \(failure.localizedDescription)\n", stderr)
            exit(1)
        }
        changed.append(type.identifier)
    }
    report["changedTypes"] = changed
    report["applied"] = true
    report["after"] = snapshot()
    let matches = types.allSatisfy { workspace.urlForApplication(toOpen: $0)?.standardizedFileURL == application.standardizedFileURL }
        && samples.allSatisfy { workspace.urlForApplication(toOpen: $0)?.standardizedFileURL == application.standardizedFileURL }
    report["verified"] = matches
    try saveReport()
    if !matches {
        fputs("Association changed, but a file or type did not resolve to the installed app. See report.\n", stderr)
        exit(1)
    }
}
let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
print(String(data: output, encoding: .utf8)!)
print("Report: \(reportURL.path)")
