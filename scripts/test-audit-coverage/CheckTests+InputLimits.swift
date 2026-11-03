#if AUDIT_CHECK_TESTS
import Foundation

extension FixtureTests {
    func inputLimitCases() {
        for (role, path) in [("manifest", "fixture.json"),
                             ("PBX", "Fixture.xcodeproj/project.pbxproj"), ("project", "project.yml")] {
            test("\(role) reads accept 32000000 bytes and reject the next byte before caching") {
                let fixture = try world("limit-read-\(role)")
                try fixture.sparseInput(path, bytes: 32_000_000)
                let inputs = try SafeInputs(root: fixture.root.path)
                try require(try inputs.read(path).count == 32_000_000, "exact metadata boundary rejected")
                try inputs.verifyUnchanged()
                try fixture.sparseInput(path, bytes: 32_000_001)
                let oversized = try SafeInputs(root: fixture.root.path)
                try rejects({ _ = try oversized.read(path) }, containing: "size limit")
                try require(oversized.hashes[path] == nil, "oversized metadata cached")
            }
        }
        test("early PBX membership rejects an oversized source before caching or parsing") {
            let fixture = try world("limit-membership")
            let inputs = try SafeInputs(root: fixture.root.path)
            let manifest = try AuditManifest.load(inputs.read("fixture.json"))
            let pbx = try ProjectMembership(data: inputs.read(manifest.pbxPath))
            try fixture.sparseInput("Sources/A.swift", bytes: 8_000_001)
            try rejects({ _ = try pbx.validate(manifest, inputs: inputs) }, containing: "size limit")
            try require(inputs.hashes["Sources/A.swift"] == nil, "oversized early source cached")
        }
        for (role, path, count) in [
            ("source", "Sources/A.swift", 8_000_001), ("manifest", "fixture.json", 32_000_001),
            ("PBX", "Fixture.xcodeproj/project.pbxproj", 32_000_001), ("project", "project.yml", 32_000_001)
        ] {
            test("\(role) oversized CLI inputs fail structurally in both modes without a cached body") {
                let fixture = try world("limit-cli-\(role)", annotated: true)
                try fixture.register(fixture.run().derivedRegistrations)
                try fixture.sparseInput(path, bytes: count)
                if role == "project" {
                    // Reviewed metadata is opaque: a matching digest must not waive the read bound.
                    fixture.manifest["specification"] = [
                        "path": path, "sha256": try digest(Data(contentsOf: fixture.root.appendingPathComponent(path))),
                        "review": "REVIEWED"
                    ]
                    try fixture.save()
                }
                for mode in ["enforce", "inventory"] {
                    let report = fixture.run(mode: mode)
                    try require(report.exitCode == 2 && !report.analysisComplete &&
                                report.diagnostics.contains { $0.message.contains("size limit") },
                                "oversized \(role) did not fail at the read bound")
                    try require(report.inputHashes[path] == nil, "oversized \(role) body cached")
                }
            }
        }
        sourceLimitCases()
        cachedLimitCases()
        growingReadCases()
    }

    private func sourceLimitCases() {
        test("source reads accept 8000000 bytes and reject the next byte before caching") {
            let fixture = try world("limit-read-source")
            try fixture.sparseInput("Sources/A.swift", bytes: 8_000_000)
            let inputs = try SafeInputs(root: fixture.root.path)
            try require(try inputs.read("Sources/A.swift", role: .source).count == 8_000_000,
                        "exact source boundary rejected")
            try inputs.verifyUnchanged()
            try fixture.sparseInput("Sources/A.swift", bytes: 8_000_001)
            let oversized = try SafeInputs(root: fixture.root.path)
            try rejects({ _ = try oversized.read("Sources/A.swift", role: .source) }, containing: "size limit")
            try require(oversized.hashes["Sources/A.swift"] == nil, "oversized source cached")
        }
    }

    private func cachedLimitCases() {
        test("a stricter cached reread cannot be relaxed by later metadata or default reads") {
            let fixture = try world("limit-stricter")
            try fixture.sparseInput("Sources/A.swift", bytes: 8_000_001)
            let inputs = try SafeInputs(root: fixture.root.path)
            _ = try inputs.read("Sources/A.swift")
            let original = inputs.hashes
            try rejects({ _ = try inputs.read("Sources/A.swift", role: .source) }, containing: "8000000")
            try rejects({ _ = try inputs.read("Sources/A.swift", role: .metadata) }, containing: "8000000")
            try rejects({ _ = try inputs.read("Sources/A.swift") }, containing: "8000000")
            try rejects({ try inputs.verifyUnchanged() }, containing: "8000000")
            try require(inputs.hashes == original, "failed stricter read replaced previously observed content")
        }
        for (role, limit) in [(InputRole.source, 8_000_000), (.metadata, 32_000_000)] {
            test("\(role) cached reread and verifyUnchanged reject growth without replacing cached content") {
                let fixture = try world("limit-cached-\(role)")
                let path = "Sources/A.swift"
                let inputs = try SafeInputs(root: fixture.root.path)
                _ = try inputs.read(path, role: role)
                let original = inputs.hashes
                try fixture.sparseInput(path, bytes: limit + 1)
                try rejects({ _ = try inputs.read(path) }, containing: "\(limit)")
                try rejects({ try inputs.verifyUnchanged() }, containing: "\(limit)")
                try require(inputs.hashes == original, "oversized changed body replaced cached content")
            }
        }
        test("an oversized first source read retains its bound even without a cached body") {
            let fixture = try world("limit-uncached")
            try fixture.sparseInput("Sources/A.swift", bytes: 8_000_001)
            let inputs = try SafeInputs(root: fixture.root.path)
            try rejects({ _ = try inputs.read("Sources/A.swift", role: .source) }, containing: "8000000")
            try rejects({ _ = try inputs.read("Sources/A.swift") }, containing: "8000000")
            try require(inputs.hashes.isEmpty, "failed first reads cached content")
            try inputs.verifyUnchanged()
        }
    }

    private func growingReadCases() {
        for limit in [8_000_000, 32_000_000] {
            test("consumed bounded reader detects deterministic growth beyond \(limit) bytes") {
                let fixture = try world("limit-growing-\(limit)")
                let path = "Sources/A.swift"
                try fixture.sparseInput(path, bytes: 65_536)
                let url = fixture.root.appendingPathComponent(path)
                let reader = try FileHandle(forReadingFrom: url)
                defer { try? reader.close() }
                let writer = try FileHandle(forWritingTo: url)
                defer { try? writer.close() }
                var consumed = 0
                var requests: [Int] = []
                try rejects({
                    _ = try SafeInputs.boundedRead(limit: limit, path: path) { count in
                        requests.append(count)
                        let data = try reader.read(upToCount: count) ?? Data()
                        consumed += data.count
                        if requests.count == 1 {
                            // Grow only after the real first read, not by racing a pre-stat.
                            try writer.truncate(atOffset: UInt64(limit + 1))
                        }
                        return data
                    }
                }, containing: "\(limit)")
                try require(consumed == limit + 1 && requests.allSatisfy { $0 <= 65_536 },
                            "reader did not stop at its one-byte overflow probe")
            }
        }
        test("bounded reader tolerates short reads and propagates read failures") {
            var remaining = Data([1, 2, 3])
            let data = try SafeInputs.boundedRead(limit: 3, path: "short") { _ in
                guard !remaining.isEmpty else { return Data() }
                return Data([remaining.removeFirst()])
            }
            try require(data == Data([1, 2, 3]), "short read mistaken for EOF")
            try rejects({
                _ = try SafeInputs.boundedRead(limit: 3, path: "failure") { _ in
                    throw AuditFailure("fixture read failure")
                }
            }, containing: "fixture read failure")
        }
    }
}

extension FixtureWorld {
    func sparseInput(_ path: String, bytes: Int) throws {
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent(path))
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.truncate(atOffset: UInt64(bytes))
    }
}
#endif
