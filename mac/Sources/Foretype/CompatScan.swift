import Foundation

/// `--compat-scan`: every installed app with what it is built on and the accessibility setup
/// Foretype gives it, flagging Chromium-based apps that get none (they show Foretype no text
/// field until primed, as the ChatGPT/Codex app did before 0.1.10). Reads bundles only; needs
/// no permissions and no model.
enum CompatScan {
    struct Row {
        let name: String
        let bundleId: String
        let engine: String
        let rule: [String: Any]
        let prime: String?
    }

    /// What the bundle at `url` embeds: "electron" or "chromium" (AppKind's answer), else
    /// "chromium-other" when it ships a Chromium renderer helper (a browser, CEF), else
    /// "web-app" for a browser's installed web app (an app shim), else nil.
    static func engine(of url: URL, bundleId: String) -> String? {
        if let kind = AppKind.kind(of: url) { return kind }
        if hasRenderer(url) { return "chromium-other" }
        return AppKind.browser(ofWebApp: bundleId) != nil ? "web-app" : nil
    }

    /// True when the rule says anything: the core sends every field, so `disabled: false` and
    /// empty lists alone mean the app isn't listed.
    static func listed(_ rule: [String: Any]) -> Bool {
        rule.contains { _, v in
            if let b = v as? Bool { return b }
            if let a = v as? [Any] { return !a.isEmpty }
            return true
        }
    }

    /// A Chromium app ships "<Name> Helper (Renderer).app", either beside its framework
    /// (Electron) or inside it (Chrome and other browsers).
    static func hasRenderer(_ url: URL) -> Bool {
        let fm = FileManager.default
        let frameworks = url.appendingPathComponent("Contents/Frameworks")
        guard let items = try? fm.contentsOfDirectory(atPath: frameworks.path) else { return false }
        if items.contains(where: isRenderer) { return true }
        for fw in items where fw.hasSuffix(".framework") {
            let versions = frameworks.appendingPathComponent(fw).appendingPathComponent("Versions")
            for v in (try? fm.contentsOfDirectory(atPath: versions.path)) ?? [] where v != "Current" {
                let helpers = versions.appendingPathComponent(v).appendingPathComponent("Helpers")
                if ((try? fm.contentsOfDirectory(atPath: helpers.path)) ?? []).contains(where: isRenderer) { return true }
            }
        }
        return false
    }

    private static func isRenderer(_ name: String) -> Bool {
        name.hasSuffix(" Helper (Renderer).app")
    }

    /// App bundles in the usual folders, one level of subfolders deep (Utilities, vendor folders).
    static func installedApps() -> [URL] {
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: $0) }
        var out: [URL] = []
        for root in roots {
            for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                if item.pathExtension == "app" {
                    out.append(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    out += ((try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
                }
            }
        }
        return out
    }

    static func rows(rule: (String) -> [String: Any]) -> [Row] {
        installedApps().compactMap { url in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
            let r = rule(id)
            let engine = engine(of: url, bundleId: id)
            let prime = r["prime"] as? String ?? AppKind.kind(of: url)
                ?? AppKind.browser(ofWebApp: id).flatMap { rule($0)["prime"] as? String }.map { "\($0) (its browser)" }
            return Row(name: url.deletingPathExtension().lastPathComponent, bundleId: id, engine: engine ?? "native", rule: r, prime: prime)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Prints the Chromium-based apps and every app with a rule, and returns false when a
    /// Chromium-based app that isn't listed gets no priming (a listed one without `prime` was
    /// looked at and needs none). A browser's web app gets its browser primed.
    static func run() -> Bool {
        // The "shell" backend loads no model; the engine is only asked for compat rules.
        guard let engine = EngineBridge(configJSON: #"{"backend":"shell"}"#) else {
            print("compat scan: the engine didn't start")
            return false
        }
        let all = rows(rule: engine.compatRule)
        var unprimed: [Row] = []
        print("App | Bundle ID | Built on | Setup | Rule")
        for row in all where row.engine != "native" || listed(row.rule) {
            let ruleText = row.rule.filter { k, v in k != "note" && listed([k: v]) }.keys.sorted().joined(separator: ",")
            var setup = row.prime ?? "none"
            if row.engine != "native", row.prime == nil, !listed(row.rule) {
                setup += "  <-- UNPRIMED"
                unprimed.append(row)
            }
            print("\(row.name) | \(row.bundleId) | \(row.engine) | \(setup) | \(ruleText.isEmpty ? (listed(row.rule) ? "note" : "-") : ruleText)")
        }
        let chromium = all.filter { $0.engine != "native" && $0.engine != "web-app" }.count
        print("\(all.count) apps; \(chromium) Chromium-based; \(unprimed.count) unprimed")
        return unprimed.isEmpty
    }
}
