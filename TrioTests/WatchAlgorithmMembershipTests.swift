import Foundation
import Testing

/// The watch app compiles the shared algorithm sources by explicit project membership, while
/// `AlgorithmPackage/Package.swift` lists them by hand. This fails when a package source is missing from the watch target.
@Suite("Watch Algorithm Membership Tests") struct WatchAlgorithmMembershipTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // TrioTests
        .deletingLastPathComponent() // repo root

    @Test("Watch app compiles every AlgorithmPackage source") func testWatchCompilesPackageSources() throws {
        let packageSources = try Self.packageSources()
        let watchSources = try Self.watchAppSources()
        try #require(!packageSources.isEmpty)

        let missing = packageSources.subtracting(watchSources)
        #expect(missing.isEmpty, "Missing from the Trio Watch App target: \(missing.sorted())")
    }

    /// Expands the `sources` entries and the model and helper lists of the package's `Trio` target.
    private static func packageSources() throws -> Set<String> {
        let manifest = try String(
            contentsOf: repoRoot.appendingPathComponent("AlgorithmPackage/Package.swift"),
            encoding: .utf8
        )
        func quoted(after pattern: String) throws -> [String] {
            let list = try #require(manifest.firstMatch(of: try Regex(pattern).dotMatchesNewlines())?[1].substring)
            return try list.matches(of: Regex(#""([^"]+)""#)).compactMap { $0[1].substring.map(String.init) }
        }
        let entries = try quoted(after: #"sources: \[(.*?)\]"#)
            + quoted(after: #"let algorithmModels = \[(.*?)\]"#).map { "Models/\($0).swift" }
            + quoted(after: #"let algorithmHelpers = \[(.*?)\]"#).map { "Helpers/\($0).swift" }

        var files = Set<String>()
        for entry in entries {
            let url = repoRoot.appendingPathComponent("Trio/Sources").appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            try #require(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), "\(entry)")
            guard isDirectory.boolValue else {
                files.insert("Trio/Sources/\(entry)")
                continue
            }
            let enumerator = try #require(FileManager.default.enumerator(atPath: url.path))
            for case let relative as String in enumerator where relative.hasSuffix(".swift") {
                files.insert("Trio/Sources/\(entry)/\(relative)")
            }
        }
        return files
    }

    /// Resolves the repo-relative path of every file in the watch app's Sources phase.
    private static func watchAppSources() throws -> Set<String> {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Trio.xcodeproj/project.pbxproj"))
        let project = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let objects = try #require(project?["objects"] as? [String: [String: Any]])

        var parent: [String: String] = [:]
        for (id, object) in objects {
            for child in object["children"] as? [String] ?? [] { parent[child] = id }
        }
        func path(of id: String) -> String? {
            var components: [String] = []
            var current: String? = id
            while let id = current, let object = objects[id] {
                if let path = object["path"] as? String { components.insert(path, at: 0) }
                switch object["sourceTree"] as? String {
                case "SOURCE_ROOT": return components.joined(separator: "/")
                case "<group>": current = parent[id]
                default: return nil
                }
            }
            return components.joined(separator: "/")
        }

        let target = try #require(objects.values.first {
            $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == "Trio Watch App"
        })
        let sourcesPhase = try #require(
            (target["buildPhases"] as? [String] ?? []).compactMap { objects[$0] }
                .first { $0["isa"] as? String == "PBXSourcesBuildPhase" }
        )
        let fileRefs = (sourcesPhase["files"] as? [String] ?? []).compactMap { objects[$0]?["fileRef"] as? String }
        return Set(fileRefs.compactMap(path(of:)))
    }
}
