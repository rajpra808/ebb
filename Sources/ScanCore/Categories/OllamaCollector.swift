import Foundation

/// Category 4, Ollama: one item per model tag.
///
/// A model is a manifest listing content-addressed blobs, and models share
/// blobs (two tags of the same weights, for example). An item's size is the
/// blobs no other model uses, which is what `ollama rm` frees. Its last use
/// is the latest read of any of its blobs: Ollama reads them on every load.
struct OllamaCollector: Sendable {
    let category: Category
    let modelsFolder: String
    let options: ScanOptions
    let minimumAge: TimeInterval

    struct Model: Equatable {
        /// e.g. "llama3.2:3b" or "hf.co/user/model:Q4".
        let name: String
        let manifest: String
        let blobs: [String]
    }

    func collect() -> Findings {
        let root = ScanOptions.canonical(options.expand(modelsFolder))
        let models = Self.models(in: root)
        guard !models.isEmpty else { return Findings() }

        var usage: [String: Int] = [:]
        for model in models {
            for blob in Set(model.blobs) { usage[blob, default: 0] += 1 }
        }

        var findings = Findings()
        for model in models {
            var bytes: Int64 = 0
            var lastUsed = FileSystem.status(atPath: model.manifest)?.modificationDate
            var files = [model.manifest]
            for blob in Set(model.blobs) {
                guard let status = FileSystem.status(atPath: blob), status.isRegularFile else { continue }
                lastUsed = max(lastUsed ?? status.accessDate, status.accessDate, status.modificationDate)
                files.append(blob)
                if usage[blob] == 1 { bytes += status.allocatedSize }
            }
            let name = model.name
            findings.candidates.append(Candidate(
                path: model.manifest,
                categoryID: category.id,
                comesBack: category.comesBack,
                preselected: category.preselected,
                source: "Ollama",
                clearCommand: "ollama rm \(name)",
                isEstimated: false,
                minimumAge: minimumAge,
                useAccessTime: true,
                precomputed: PrecomputedSize(
                    allocatedBytes: bytes, fileCount: files.count, lastUsed: lastUsed,
                    paths: files, isVirtual: false
                ),
                describe: { lastUsed, now in
                    let age = lastUsed.map { Age.describe(from: $0, to: now) } ?? "a while"
                    return "Ollama model \(name), last loaded \(age) ago"
                }
            ))
        }
        return findings
    }

    /// Every model tag under `<root>/manifests`, with the blob files its
    /// manifest points to.
    static func models(in root: String) -> [Model] {
        let manifests = Paths.join(root, "manifests")
        let blobs = Paths.join(root, "blobs")
        var result: [Model] = []
        var stack = [(manifests, 0)]
        while let (folder, depth) = stack.popLast() {
            guard depth < 6, let entries = try? FileSystem.entries(ofDirectory: folder) else { continue }
            for entry in entries where !entry.name.hasPrefix(".") {
                let path = Paths.join(folder, entry.name)
                guard let status = FileSystem.status(atPath: path) else { continue }
                if status.isDirectory {
                    stack.append((path, depth + 1))
                } else if status.isRegularFile, status.logicalSize < 1_000_000,
                          let digests = digests(inManifest: path) {
                    result.append(Model(
                        name: modelName(manifest: path, manifestsRoot: manifests),
                        manifest: path,
                        // "sha256:abc" is stored as "sha256-abc".
                        blobs: digests.map { Paths.join(blobs, $0.replacingOccurrences(of: ":", with: "-")) }
                    ))
                }
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    static func digests(inManifest path: String) -> [String]? {
        guard let data = FileManager.default.contents(atPath: path),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let layers = (manifest["layers"] as? [[String: Any]]) ?? []
        let config = (manifest["config"] as? [String: Any]).map { [$0] } ?? []
        let digests = (layers + config).compactMap { $0["digest"] as? String }
            .filter { $0.hasPrefix("sha256:") && !$0.contains("/") }
        return digests.isEmpty ? nil : digests
    }

    /// `manifests/registry.ollama.ai/library/llama3.2/3b` → `llama3.2:3b`;
    /// other registries and namespaces keep their prefix.
    static func modelName(manifest: String, manifestsRoot: String) -> String {
        var parts = Paths.components(of: Paths.relative(manifest, to: manifestsRoot)).map(String.init)
        guard parts.count >= 2 else { return parts.joined(separator: "/") }
        let tag = parts.removeLast()
        if parts.first == "registry.ollama.ai" { parts.removeFirst() }
        if parts.first == "library" && parts.count == 2 { parts.removeFirst() }
        return parts.joined(separator: "/") + ":" + tag
    }
}
