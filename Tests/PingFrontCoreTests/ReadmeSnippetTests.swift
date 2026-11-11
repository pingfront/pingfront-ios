import Foundation
import Testing

/// README.md's Swift blocks must match `Tests/PingFrontDocSnippetTests/ReadmeSnippets.swift`, which the
/// iOS build compiles.
///
/// A README edit without the compiled copy (or an API change that breaks it) fails.
@Suite("README snippets")
struct ReadmeSnippetTests {
    static let root = TestPaths.package

    static func normalized(_ line: Substring) -> String {
        line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("Every line of every README Swift block is in the compiled snippets")
    func snippetsMatch() throws {
        let readme = try String(contentsOf: Self.root.appending(path: "README.md"), encoding: .utf8)
        let compiled = try String(
            contentsOf: Self.root.appending(path: "Tests/PingFrontDocSnippetTests/ReadmeSnippets.swift"), encoding: .utf8)
        let known = Set(compiled.split(separator: "\n").map(Self.normalized))
        var inSwift = false
        var missing: [String] = []
        for line in readme.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                inSwift = line == "```swift"
                continue
            }
            let text = Self.normalized(line)
            guard inSwift, !text.isEmpty, text != "@main", text != "import PingFront" else { continue }
            if !known.contains(text) { missing.append(text) }
        }
        #expect(missing.isEmpty, "README lines not in ReadmeSnippets.swift:\n\(missing.joined(separator: "\n"))")
    }
}
