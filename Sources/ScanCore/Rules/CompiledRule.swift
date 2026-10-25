import Foundation

/// A rule that passed validation, with its regex compiled and its folders
/// resolved.
struct CompiledRule: @unchecked Sendable {
    // NSRegularExpression is immutable and documented as thread-safe, but
    // isn't marked Sendable in every Foundation.

    enum Match: Equatable {
        case match
        case noMatch
        /// The regex ran past its deadline. Treated as "don't know".
        case timedOut
    }

    let rule: Rule
    let roots: [String]
    private let regex: NSRegularExpression

    /// Compiles each rule, keeping the valid ones and describing the rest.
    static func compile(_ rules: [Rule], options: ScanOptions) -> (rules: [CompiledRule], warnings: [String]) {
        var compiled: [CompiledRule] = []
        var warnings: [String] = []
        for rule in rules {
            do {
                try rule.validate()
                let regex = try NSRegularExpression(pattern: rule.pattern)
                let roots = rule.roots.map { ScanOptions.canonical(options.expand($0)) }
                compiled.append(CompiledRule(rule: rule, roots: roots, regex: regex))
            } catch {
                warnings.append("Skipped rule '\(rule.name)' (\(rule.id)): \(error)")
            }
        }
        return (compiled, warnings)
    }

    /// True if `path` is inside one of the rule's folders (or the rule has
    /// none, which means everywhere).
    func applies(to path: String) -> Bool {
        roots.isEmpty || roots.contains { Paths.isSameOrDescendant(path, of: $0) }
    }

    /// Could this rule match something at or inside `path`? Used to skip
    /// never-touch checks inside items the rule can't reach.
    func overlaps(_ path: String) -> Bool {
        roots.isEmpty || roots.contains {
            Paths.isSameOrDescendant(path, of: $0) || Paths.isSameOrDescendant($0, of: path)
        }
    }

    /// Tests one file. `name` and `path` must describe the same file.
    func matches(name: String, path: String, deadline: Date) -> Match {
        evaluate(rule.matchOn == .fileName ? name : path, deadline: deadline)
    }

    /// For never-touch rules: does the rule cover `path`? In file-name mode
    /// any folder on the way down counts, so protecting a folder name
    /// protects everything inside it.
    func protects(_ path: String, deadline: Date) -> Match {
        guard applies(to: path) else { return .noMatch }
        if rule.matchOn == .fullPath { return evaluate(path, deadline: deadline) }

        // Only the part of the path inside the rule's folder counts; a rule
        // for "^build$" in ~/code shouldn't fire because ~ is /Users/build.
        let names: [String]
        if let base = roots.first(where: { Paths.isSameOrDescendant(path, of: $0) }) {
            names = path == base
                ? [Paths.lastComponent(of: path)]
                : Paths.components(of: Paths.relative(path, to: base)).map(String.init)
        } else {
            names = Paths.components(of: path).map(String.init)
        }
        for name in names {
            let result = evaluate(name, deadline: deadline)
            if result != .noMatch { return result }
        }
        return .noMatch
    }

    /// Runs the regex with a deadline. `.reportProgress` makes Foundation
    /// call back periodically during a long match, which is the only way to
    /// stop a catastrophic pattern part-way through.
    private func evaluate(_ string: String, deadline: Date) -> Match {
        var result = Match.noMatch
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        regex.enumerateMatches(in: string, options: [.reportProgress], range: range) { match, _, stop in
            if match != nil {
                result = .match
                stop.pointee = true
            } else if Date() > deadline {
                result = .timedOut
                stop.pointee = true
            }
        }
        return result
    }
}
