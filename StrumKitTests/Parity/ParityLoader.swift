// StrumKitTests/Parity/ParityLoader.swift
import Foundation

public enum ParityLoader {
    /// Repository root, derived from this file's compile-time path.
    ///
    /// #filePath anchor:
    /// StrumKitTests/Parity/ParityLoader.swift ->
    ///   .deletingLastPathComponent() -> StrumKitTests/Parity
    ///   .deletingLastPathComponent() -> StrumKitTests
    ///   .deletingLastPathComponent() -> repository root
    public static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The Tools/parity-contract directory containing the frozen schema, manifest, and traces.
    public static var parityContractDirectory: URL {
        repositoryRoot.appendingPathComponent("Tools/parity-contract")
    }

    /// Manifest file location.
    public static var manifestURL: URL {
        parityContractDirectory.appendingPathComponent("schema/manifest.json")
    }

    /// Loads the frozen ParityManifest from disk.
    public static func loadManifest() throws -> ParityManifest {
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(ParityManifest.self, from: data)
    }

    /// Loads a golden trace given its relative path under Tools/parity-contract/ (e.g. "traces/product-fixtures/uke_e.wav.json").
    public static func loadTrace(at relativePath: String) throws -> ParityTrace {
        let traceURL = parityContractDirectory.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: traceURL)
        return try JSONDecoder().decode(ParityTrace.self, from: data)
    }

    /// Loads a golden trace given case name and category.
    public static func loadTrace(named name: String, category: String) throws -> ParityTrace {
        let filename = name.hasSuffix(".json") ? name : "\(name).json"
        let relativePath = "traces/\(category)/\(filename)"
        return try loadTrace(at: relativePath)
    }
}

extension ParityTrace {
    /// Loads a trace directly using the ParityLoader.
    public static func load(at relativePath: String) throws -> ParityTrace {
        try ParityLoader.loadTrace(at: relativePath)
    }

    /// Loads a trace by case name and category.
    public static func load(named name: String, in category: String) throws -> ParityTrace {
        try ParityLoader.loadTrace(named: name, category: category)
    }
}

extension ParityManifest {
    /// Loads the manifest directly using the ParityLoader.
    public static func load() throws -> ParityManifest {
        try ParityLoader.loadManifest()
    }
}
