import Foundation

/// Category 11: Docker data no container uses, as Docker itself reports it.
///
/// Two items at most: dangling images (untagged, used by no container) and
/// build cache not in use. Both only count entries older than a day, and the
/// suggested commands use the same `until=24h` filter so clearing removes
/// exactly what was counted.
struct DockerCollector: Sendable {
    let category: Category
    let now: Date
    let recentlyChangedSince: Date

    static let danglingImagesPath = "docker:dangling-images"
    static let buildCachePath = "docker:build-cache"

    func collect() async -> Findings {
        guard let docker = Subprocess.locate("docker", fallbacks: [
            "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ]) else { return Findings() }

        var findings = Findings()
        let arguments = ["system", "df", "-v", "--format", "{{json .}}"]
        guard let output = await Subprocess.run(docker, arguments: arguments, timeout: 20), output.status == 0,
              let usage = Self.parse(output.stdout, recentlyChangedSince: recentlyChangedSince)
        else {
            findings.warnings.append("Docker isn't running, so its images and build cache weren't checked")
            return findings
        }

        #if os(macOS)
        let note = ". Docker Desktop hands the space back to macOS gradually"
        #else
        let note = ""
        #endif
        if usage.danglingImages.count > 0 {
            let count = usage.danglingImages.count
            findings.candidates.append(candidate(
                Self.danglingImagesPath, usage.danglingImages, source: "dangling images",
                command: "docker image prune --force --filter until=24h",
                reason: "\(count) untagged image\(count == 1 ? "" : "s") no container uses" + note
            ))
        }
        if usage.buildCache.count > 0 {
            findings.candidates.append(candidate(
                Self.buildCachePath, usage.buildCache, source: "build cache",
                command: "docker builder prune --all --force --filter until=24h",
                reason: "Build cache no build is using" + note
            ))
        }
        return findings
    }

    private func candidate(_ path: String, _ total: Usage.Total, source: String, command: String,
                           reason: String) -> Candidate {
        Candidate(
            path: path, categoryID: category.id, comesBack: category.comesBack,
            preselected: category.preselected, source: source, clearCommand: command,
            // Docker's sizes are its own accounting inside the VM disk.
            isEstimated: true,
            precomputed: PrecomputedSize(
                allocatedBytes: total.bytes, fileCount: total.count, lastUsed: total.lastUsed,
                paths: [], isVirtual: true
            ),
            describe: { _, _ in reason }
        )
    }

    struct Usage: Equatable {
        struct Total: Equatable {
            var bytes: Int64 = 0
            var count = 0
            var lastUsed: Date?
        }

        var danglingImages = Total()
        var buildCache = Total()
    }

    /// Reads `docker system df -v --format '{{json .}}'`. Entries used or
    /// created within the last day, and entries without a readable date,
    /// are left out.
    static func parse(_ data: Data, recentlyChangedSince: Date) -> Usage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var usage = Usage()

        for image in object["Images"] as? [[String: Any]] ?? [] {
            let untagged = (image["Repository"] as? String) == "<none>" && (image["Tag"] as? String) == "<none>"
            guard untagged, (image["Containers"] as? String) == "0",
                  let created = date(image["CreatedAt"]), created < recentlyChangedSince,
                  let size = bytes(image["UniqueSize"] ?? image["Size"])
            else { continue }
            usage.danglingImages.add(size, lastUsed: created)
        }

        for entry in object["BuildCache"] as? [[String: Any]] ?? [] {
            let inUse = (entry["InUse"] as? Bool) ?? ((entry["InUse"] as? String) == "true")
            guard !inUse,
                  let used = date(entry["LastUsedAt"]) ?? date(entry["CreatedAt"]), used < recentlyChangedSince,
                  let size = bytes(entry["Size"])
            else { continue }
            usage.buildCache.add(size, lastUsed: used)
        }
        return usage
    }

    /// Docker prints decimal sizes like `4.115GB`, `198.9MB`, `12kB`, `0B`.
    static func bytes(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        guard let text = value as? String else { return nil }
        return ByteCount.parse(text)
    }

    /// Docker prints dates like `2026-10-17 06:15:35 +0530 IST`.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, text.count >= 25 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: String(text.prefix(25)))
    }
}

private extension DockerCollector.Usage.Total {
    mutating func add(_ size: Int64, lastUsed date: Date) {
        bytes += size
        count += 1
        lastUsed = max(lastUsed ?? date, date)
    }
}
