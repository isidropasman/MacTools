import Foundation

/// Format recovered from Conductor's own deep-link parser (brotli-compressed
/// inside the binary):
///
///     if (url.hostname === "workspace") {
///       const id = url.searchParams.get("id")
///       return id ? {type: "open-workspace", workspaceId: id,
///                    sessionId: url.searchParams.get("session")} : undefined
///     }
///     ...
///     return {type: "create-workspace", path, prompt}   // <- catch-all
///
/// The hostname must be exactly "workspace" and the ids are QUERY PARAMS.
/// Anything else falls through to that catch-all and *creates a workspace*,
/// which is what earlier path-style guesses were doing.
/// Overridable from ~/.llmpet/config.json. Placeholders: {workspace}, {session}.
struct Config {
    static let shared = Config()
    static let path = NSHomeDirectory() + "/.llmpet/config.json"

    private let conductorTemplate: String

    init() {
        let defaults = "conductor://workspace?id={workspace}&session={session}"
        guard let data = FileManager.default.contents(atPath: Self.path),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let template = raw["conductorLink"] as? String, !template.isEmpty
        else {
            conductorTemplate = defaults
            return
        }
        conductorTemplate = template
    }

    func conductorLink(repo: String, workspace: String, session: String) -> String? {
        let link = conductorTemplate
            .replacingOccurrences(of: "{repo}", with: repo)
            .replacingOccurrences(of: "{workspace}", with: workspace)
            .replacingOccurrences(of: "{session}", with: session)

        // Hard guard: Conductor treats every unrecognised conductor:// URL as
        // "create a workspace". Refusing to fire anything that isn't the exact
        // open-workspace shape is the difference between a dead click and one
        // that silently creates workspaces in the wrong repo.
        guard let url = URLComponents(string: link),
              url.scheme == "conductor",
              url.host == "workspace",
              url.queryItems?.first(where: { $0.name == "id" })?.value?.isEmpty == false
        else { return nil }
        return link
    }
}
