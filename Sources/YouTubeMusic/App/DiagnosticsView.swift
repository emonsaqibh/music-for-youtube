import SwiftUI

/// Temporary scaffolding: proves the bridge is injected, the session is signed in,
/// and InnerTube calls succeed before any real UI is built on top.
struct DiagnosticsView: View {
    @State private var lines: [String] = []
    @State private var snapshot = PlayerSnapshot()
    @State private var pageInfo = "—"
    @State private var probe = "—"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Engine diagnostics")
                .font(.title2.weight(.semibold))
            controls
            box("Player", detail: describe(snapshot))
            box("Page", detail: pageInfo)
            box("InnerTube probe", detail: probe)
            events
            Spacer(minLength: 0)
        }
        .padding(20)
        .task { await boot() }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button("Sign in…") { SignIn.start() }
            Button("Diagnostics") { Task { pageInfo = await readDiagnostics() } }
            Button("Probe home") { Task { probe = await probeHome() } }
            Button("Reload") { WebEngine.shared.reload() }
        }
        .buttonStyle(.glass)
    }

    private var events: some View {
        GroupBox("Events") {
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 170)
        }
    }

    private func box(_ title: String, detail: String) -> some View {
        GroupBox(title) {
            Text(detail)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Actions

    private func boot() async {
        WebEngine.shared.onEvent = { event in
            switch event {
            case .snapshot(let s):
                snapshot = s
            case .injected(let url, let signedIn):
                log("injected signedIn=\(signedIn) \(url)")
            case .ready(let signedIn, let s):
                snapshot = s
                log("ready signedIn=\(signedIn)")
                Task {
                    pageInfo = await readDiagnostics()
                    probe = await probeHome()
                }
            case .remote(let action, let time):
                log("remote \(action) \(time.map { String(format: "%.1f", $0) } ?? "")")
            case .playerError(let code):
                log("player error \(code)")
            case .log(let text):
                log(text)
            }
        }
        WebEngine.shared.start()
    }

    private func log(_ s: String) {
        lines.append(s)
        if lines.count > 120 { lines.removeFirst(lines.count - 120) }
    }

    private func describe(_ s: PlayerSnapshot) -> String {
        guard s.ok else { return "player not attached" }
        return """
        \(s.title.isEmpty ? "(no track)" : s.title) — \(s.author)
        id=\(s.videoId)  state=\(s.state)  ad=\(s.ad)
        \(String(format: "%.1f", s.time)) / \(String(format: "%.1f", s.duration))s  vol=\(Int(s.volume))
        """
    }

    private func readDiagnostics() async -> String {
        let d = await WebEngine.shared.diagnostics()
        if d.isEmpty { return "bridge not injected yet" }
        return d.keys.sorted().map { "\($0): \(d[$0] ?? "")" }.joined(separator: "\n")
    }

    private func probeHome() async -> String {
        do {
            let json = try await WebEngine.shared.innertube("browse", ["browseId": "FEmusic_home"])
            let shelves = json.all("musicCarouselShelfRenderer")
            let titles: [String] = shelves.compactMap {
                $0[path: "header.musicCarouselShelfBasicHeaderRenderer.title"].text
            }
            return "shelves: \(shelves.count)\n" + titles.prefix(12).joined(separator: "\n")
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }
}
