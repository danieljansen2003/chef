import Foundation

enum InstalledAppResolution {
    case found(InstalledApp)
    case ambiguous([String])
    case missing
}

/// Bounded catalog of installed application bundles. It reads bundle metadata
/// only; it never opens an app or executes a command.
enum InstalledAppCatalog {
    private static let maximumEntriesPerDirectory = 4096
    private static let maximumApps = 2048
    private static let maximumNameLength = 120

    static func all() -> [InstalledApp] { all(home: nil, roots: nil) }

    static func all(home: URL? = nil, roots overrideRoots: [URL]? = nil) -> [InstalledApp] {
        let roots = searchRoots(home: home, overrideRoots: overrideRoots)
        var seen = Set<String>()
        var found: [InstalledApp] = []
        for root in roots {
            guard found.count < maximumApps,
                  let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey]), rootValues.isDirectory == true,
                  let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }).prefix(maximumEntriesPerDirectory) {
                guard found.count < maximumApps, url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                      let app = installedApp(at: url, allowedRoots: roots) else { continue }
                let key = app.url.standardizedFileURL.path
                guard seen.insert(key).inserted else { continue }
                found.append(app)
            }
        }
        return found.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
    }

    /// Case-, diacritic-, whitespace-, and punctuation-insensitive exact-name key.
    /// Invalid, oversized, and credential-bearing targets fail closed.
    static func normalize(_ raw: String) -> String {
        guard raw.count <= maximumNameLength, !PersonalWorkspace.hasCredential(raw) else { return "" }
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.split { !$0.isLetter && !$0.isNumber }.map(String.init).joined(separator: " ")
    }

    /// Exact name wins before spoken courtesy words are considered, preserving
    /// real titles such as “The Unarchiver” or “A Friend for Me”.
    static func resolve(_ raw: String) -> InstalledAppResolution { resolve(raw, apps: all()) }
    static func resolve(name: String) -> InstalledAppResolution { resolve(name) }

    static func resolve(_ raw: String, home: URL? = nil, roots: [URL]? = nil) -> InstalledAppResolution {
        resolve(raw, apps: all(home: home, roots: roots))
    }

    private static func resolve(_ raw: String, apps: [InstalledApp]) -> InstalledAppResolution {
        guard !raw.isEmpty, raw.count <= maximumNameLength, !PersonalWorkspace.hasCredential(raw), !Safety.blocked(raw) else { return .missing }
        let spoken = stripSpokenWrappers(raw)
        let polite = stripCourtesy(spoken)
        let candidates = [raw, spoken, polite, stripNameDecorations(polite)]
        for candidate in candidates {
            let key = normalize(candidate)
            guard !key.isEmpty else { continue }
            let matches = apps.filter { normalize($0.name) == key || normalize(choiceLabel($0)) == key }
            if matches.count == 1, let app = matches.first { return .found(app) }
            if matches.count > 1 { return .ambiguous(matches.map(choiceLabel).sorted()) }
        }
        return .missing
    }

    private static func searchRoots(home: URL?, overrideRoots: [URL]?) -> [URL] {
        let bases = overrideRoots ?? [URL(fileURLWithPath: "/Applications", isDirectory: true),
                                      URL(fileURLWithPath: "/System/Applications", isDirectory: true),
                                      URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
                                      (home ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)).appendingPathComponent("Applications", isDirectory: true)]
        var result: [URL] = []
        for base in bases {
            let standardized = base.standardizedFileURL
            if !result.contains(where: { $0.path == standardized.path }) { result.append(standardized) }
            if base.lastPathComponent != "CoreServices" {
                let utilities = standardized.appendingPathComponent("Utilities", isDirectory: true)
                if !result.contains(where: { $0.path == utilities.path }) { result.append(utilities) }
            }
        }
        return result
    }

    private static func installedApp(at url: URL, allowedRoots: [URL]) -> InstalledApp? {
        let fileURL = url.standardizedFileURL
        let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let allowed = allowedRoots.contains { root in
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
            return resolved.path.hasPrefix(canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/")
        }
        guard allowed,
              let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true,
              let bundle = Bundle(url: resolved) else { return nil }
        let identifier = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !identifier.isEmpty, !PersonalWorkspace.hasCredential(identifier) else { return nil }
        let display = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleName = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = [display, bundleName, Optional(resolved.deletingPathExtension().lastPathComponent), Optional(identifier)]
            .compactMap { value -> String? in guard let value, !value.isEmpty, value.count <= maximumNameLength else { return nil }; return value }
            .first
        guard let name, !name.isEmpty else { return nil }
        return InstalledApp(url: resolved, name: name)
    }

    private static func stripSpokenWrappers(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"^(?:(?:can|could|would|will)\s+you\s+|please\s+|open\s+(?:up\s+)?|launch\s+|my\s+)+"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripCourtesy(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<3 {
            let trimmed = value.replacingOccurrences(of: #"\s+(?:for\s+me|please)$"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == value { break }
            value = trimmed
        }
        return value
    }

    private static func stripNameDecorations(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"\s+(?:app|application)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"^(?:my|the)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func choiceLabel(_ app: InstalledApp) -> String {
        let identifier = Bundle(url: app.url)?.bundleIdentifier ?? app.url.deletingPathExtension().lastPathComponent
        return "\(app.name) (\(identifier))"
    }

    static func test(at root: URL) throws {
        let first = root.appendingPathComponent("First.app/Contents", isDirectory: true)
        let second = root.appendingPathComponent("Second.app/Contents", isDirectory: true)
        let titleOne = root.appendingPathComponent("TitleOne.app/Contents", isDirectory: true)
        let titleTwo = root.appendingPathComponent("TitleTwo.app/Contents", isDirectory: true)
        let titleThree = root.appendingPathComponent("TitleThree.app/Contents", isDirectory: true)
        for (directory, title, identifier) in [(first, "Same Name", "example.one"), (second, "Same Name", "example.two"), (titleOne, "The Unarchiver", "example.unarchiver"), (titleTwo, "A Friend for Me", "example.friend"), (titleThree, "System Settings", "example.settings")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": title, "CFBundleDisplayName": title, "CFBundlePackageType": "APPL"]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: directory.appendingPathComponent("Info.plist"), options: .atomic)
        }
        let search = [root]
        if case .ambiguous(let choices) = resolve("Same Name", home: nil, roots: search), choices.count == 2 {} else { throw NSError(domain: "InstalledAppCatalogTest", code: 1) }
        if case .found(let app) = resolve("the unarchiver", home: nil, roots: search), app.name == "The Unarchiver" {} else { throw NSError(domain: "InstalledAppCatalogTest", code: 2) }
        if case .found(let app) = resolve("can you open The Unarchiver", home: nil, roots: search), app.name == "The Unarchiver" {} else { throw NSError(domain: "InstalledAppCatalogTest", code: 6) }
        if case .found(let app) = resolve("A Friend for Me", home: nil, roots: search), app.name == "A Friend for Me" {} else { throw NSError(domain: "InstalledAppCatalogTest", code: 3) }
        if case .ambiguous(let choices) = resolve("Same Name for me", home: nil, roots: search), choices.count == 2 {} else { throw NSError(domain: "InstalledAppCatalogTest", code: 4) }
        if case .missing = resolve("token=super-secret", home: nil, roots: search) {} else { throw NSError(domain: "InstalledAppCatalogTest", code: 5) }
        if case .found(let app) = resolve("System Settings for me please", home: nil, roots: search), app.name == "System Settings" {} else { throw NSError(domain: "InstalledAppCatalogTest", code: 7) }
    }
}
