import Foundation
import Testing

/// The watch app compiles the shared algorithm sources through the project's membership exceptions, while
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

    /// The pure code the watch loop runs besides the algorithm: every file in `APS/WatchLoan` and these.
    static let watchLoopSources = [
        "Trio/Sources/Services/BolusCalculator/BolusCalculator.swift",
        "Trio/Sources/Services/BolusSafety/BolusSafetyEvaluator.swift",
        "Trio/Sources/Services/Alerts/GlucoseAlarmEvaluation.swift",
        "Trio/Sources/Services/Alerts/ForecastedGlucoseEvaluator.swift",
        "Trio/Sources/Models/GlucoseAlerts/GlucoseAlert.swift",
        "Trio/Sources/Models/GlucoseAlerts/GlucoseAlertType.swift",
        "Trio/Sources/Models/GlucoseAlerts/GlucoseAlertConfiguration.swift",
        "Trio/Sources/Models/GlucoseAlerts/DayNightOptions.swift",
        "Trio/Sources/Models/GlucoseAlerts/AlarmSoundCatalog.swift",
        "Trio/Sources/Models/GlucoseAlerts/DeviceAlertSeverity.swift"
    ]

    @Test("Watch app compiles the loop's shared sources, Foundation and LoopKit only") func testWatchCompilesLoopSources() throws {
        let loanDirectory = Self.repoRoot.appendingPathComponent("Trio/Sources/APS/WatchLoan")
        let loanFiles = try FileManager.default.contentsOfDirectory(atPath: loanDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .map { "Trio/Sources/APS/WatchLoan/\($0)" }
        try #require(loanFiles.count >= 4)
        let expected = Set(loanFiles + Self.watchLoopSources)

        let missing = expected.subtracting(try Self.watchAppSources())
        #expect(missing.isEmpty, "Missing from the Trio Watch App target: \(missing.sorted())")

        let allowedImports: Set<String> = ["Foundation", "LoopKit"]
        for file in expected.sorted() {
            let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(file), encoding: .utf8)
            let imports = source.matches(of: try Regex(#"(?m)^import (\w+)"#)).compactMap { $0[1].substring.map(String.init) }
            #expect(Set(imports).isSubset(of: allowedImports), "\(file) imports \(imports)")
        }
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

    /// Resolves the repo-relative path of every Swift file the watch app compiles: its Sources phase, its own
    /// synchronized folders, and the files other synchronized folders add to it by exception.
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

        let (targetID, target) = try #require(objects.first {
            $0.value["isa"] as? String == "PBXNativeTarget" && $0.value["name"] as? String == "Trio Watch App"
        })
        func exceptions(of group: [String: Any]) -> Set<String> {
            let sets = (group["exceptions"] as? [String] ?? []).compactMap { objects[$0] }
                .filter { $0["target"] as? String == targetID }
            return Set(sets.flatMap { $0["membershipExceptions"] as? [String] ?? [] })
        }

        let sourcesPhase = try #require(
            (target["buildPhases"] as? [String] ?? []).compactMap { objects[$0] }
                .first { $0["isa"] as? String == "PBXSourcesBuildPhase" }
        )
        let fileRefs = (sourcesPhase["files"] as? [String] ?? []).compactMap { objects[$0]?["fileRef"] as? String }
        var sources = Set(fileRefs.compactMap(path(of:)))

        let ownGroups = Set(target["fileSystemSynchronizedGroups"] as? [String] ?? [])
        for (id, group) in objects where group["isa"] as? String == "PBXFileSystemSynchronizedRootGroup" {
            guard let folder = path(of: id) else { continue }
            let listed = exceptions(of: group)
            guard ownGroups.contains(id) else {
                sources.formUnion(listed.filter { $0.hasSuffix(".swift") }.map { "\(folder)/\($0)" })
                continue
            }
            let enumerator = try #require(FileManager.default.enumerator(atPath: repoRoot.appendingPathComponent(folder).path))
            for case let relative as String in enumerator where relative.hasSuffix(".swift") && !listed.contains(relative) {
                sources.insert("\(folder)/\(relative)")
            }
        }
        return sources
    }
}
