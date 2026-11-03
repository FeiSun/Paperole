import AppKit
import SwiftUI

/// A persisted scan, independent of the review decisions (Mark OK, fixed, sent) on its findings.
struct CheckScanReport: Decodable, Equatable {
    var startedAt: String?
    var completedAt: String?
    var rules: [CheckRuleRun]
}

struct CheckRuleRun: Decodable, Equatable, Identifiable {
    var code: String
    var group: String
    var title: String
    var count: Int
    var status: String
    var detail: String
    var online: Bool
    var id: String { code }
    var incomplete: Bool { ["failed", "partial", "unavailable"].contains(status) }
    var conclusion: String {
        switch status {
        case "done": return count == 0 ? "No findings" : "\(count) finding\(count == 1 ? "" : "s")"
        case "off": return "Off"
        case "skipped": return "Not applicable"
        case "partial": return "Partial · \(count) found"
        case "failed": return "Failed"
        default: return "Unable to check"
        }
    }
}

struct LookupLogRow: Identifiable {
    var key: String
    var title: String
    var conclusion: String
    var detail: String
    var incomplete: Bool
    var pending: Bool
    var id: String { key }
}

/// One current-paper snapshot drives both the short status and the complete, copyable log.
@MainActor
struct CheckActivitySnapshot {
    private static let dateReader = ISO8601DateFormatter()
    var rules: [CheckRuleRun]
    var sources: [(source: RefSource, rows: [LookupLogRow], enabled: Bool, summary: String)]
    var headline: String
    var symbol: String
    var attention: Bool
    var message: String?
    var completedAt: String?
    var findings: [Check]
    var round: Int
    var verifying: Bool

    init(_ model: AppModel) {
        let checks = model.checks, refs = model.refs
        let roundNumber = model.round?.n ?? 0
        round = roundNumber
        let key = RefLookup.roundKey(model.selectedPath ?? "", roundNumber)
        let referencesHere = model.referenceRoundKey == key
        rules = checks.report?.rules ?? []
        // An online rule needs Semantic Scholar; its saved results remain usable while fetching is off.
        for i in rules.indices where rules[i].online && rules[i].status == "unavailable" && rules[i].count == 0
            && !model.lookUp.contains(.semanticScholar) {
            rules[i].status = "off"
            rules[i].detail = "Semantic Scholar lookup is off; no saved results are available for this check."
        }
        findings = checks.scanFindings
        completedAt = checks.report?.completedAt
        let entries = referencesHere ? model.refEntries.values.sorted { $0.key < $1.key } : []
        sources = RefSource.allCases.map { source in
            let enabled = model.lookUp.contains(source) && model.checksOn
            let jobs = refs.queued[source, default: []].filter { $0.paper == model.selectedPath && $0.round == roundNumber }
            let rows = entries.map { e -> LookupLogRow in
                let r = model.refResults[e.key]?[source], a = refs.attempts[key]?[source]?[e.key]
                let pending = jobs.contains { $0.entry.key == e.key }
                let status: String
                if pending { status = source == .googleScholar && refs.blocked ? "verification" : "pending" }
                else if let r { status = r.found ? "matched" : "not_found" }
                else { status = a?.status ?? (enabled ? "unavailable" : "off") }
                let conclusion: String
                switch status {
                case "matched": conclusion = "Record found"
                case "not_found": conclusion = "No matching record"
                case "pending": conclusion = refs.resting[source] != nil ? "Waiting for rate limit" : "Pending"
                case "verification": conclusion = "Verification required"
                case "skipped": conclusion = "Missing searchable title or identifier"
                case "stopped": conclusion = "Stopped before lookup"
                case "limited": conclusion = "Daily limit reached"
                case "off": conclusion = "Off"
                default: conclusion = "No usable response"
                }
                var detail: [String] = []
                if let r, r.found {
                    if let t = r.title, !t.isEmpty { detail.append(t) }
                    let meta = [r.year.map(String.init), r.venue, r.citations.map { "\($0) citations" }].compactMap { $0 }
                    if !meta.isEmpty { detail.append(meta.joined(separator: " · ")) }
                    if let p = r.published { detail.append("Published at " + p) }
                } else if let t = r?.closest?.title { detail.append("Closest: " + t) }
                if let a { detail.append("Recorded " + Self.date(a.at)) }
                return LookupLogRow(key: e.key, title: e.title ?? e.label ?? e.key, conclusion: conclusion,
                                    detail: detail.joined(separator: "\n"),
                                    incomplete: ["unavailable", "stopped", "limited", "verification"].contains(status), pending: pending)
            }
            let complete = rows.filter { !$0.pending && !$0.incomplete }.count
            let summary = !enabled ? "Off" : rows.isEmpty ? (model.referencesLoading && referencesHere ? "Loading…" : "No references")
                : rows.contains(where: \.pending) ? "\(complete) of \(rows.count) recorded"
                : rows.contains(where: \.incomplete) ? "Incomplete" : "Done · \(rows.count) records"
            return (source, rows, enabled, summary)
        }
        let hasPending = sources.contains { $0.enabled && $0.rows.contains(where: \.pending) }
        verifying = refs.blocked && sources.contains { $0.source == .googleScholar && $0.enabled && $0.rows.contains(where: \.pending) }
        message = checks.reportError ?? (referencesHere ? model.referenceLoadError : nil)
        if model.referenceStoreErrors.contains(key) { message = "Some lookup records could not be saved. The log may be incomplete." }
        attention = verifying || message != nil || rules.contains(where: \.incomplete)
            || sources.contains { $0.enabled && $0.rows.contains(where: \.incomplete) }
        if !model.checksOn {
            headline = "Checks off"; symbol = "minus"; attention = false
        } else if verifying {
            headline = "Checks · Action needed"; symbol = "exclamationmark.circle"
        } else if checks.phase == .asking || checks.refreshing || (model.referencesLoading && referencesHere) || model.referenceStores.values.contains(key) {
            headline = checks.report == nil ? "Checking…" : "Updating check log…"; symbol = "clock"
        } else if hasPending {
            headline = "Checks · Looking up references…"; symbol = "clock"
        } else if attention {
            headline = "Checks incomplete"; symbol = "exclamationmark.circle"
        } else if checks.report == nil {
            headline = "Checks · No scan record"; symbol = "minus"
        } else if rules.allSatisfy({ $0.status == "off" }) && sources.allSatisfy({ !$0.enabled }) {
            headline = "No checks selected"; symbol = "minus"
        } else {
            let count = rules.filter { $0.status != "off" }.reduce(0) { $0 + $1.count }
            headline = "Checks complete · " + (count == 0 ? "No findings" : "\(count) finding\(count == 1 ? "" : "s")")
            symbol = "checkmark"
        }
    }

    static func date(_ text: String) -> String {
        guard let date = dateReader.date(from: text) else { return text }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var text: String {
        var lines = ["Auto checks · Round \(round)", headline]
        if let completedAt { lines.append("Latest scan: " + Self.date(completedAt)) }
        if let message { lines.append(message) }
        for group in ChecksModel.groups {
            lines.append("\n" + group.title)
            for rule in rules where rule.group == group.id {
                lines.append("\(rule.title): \(rule.conclusion)\n  \(rule.detail)")
                if rule.status != "off" {
                    for finding in findings where finding.code == rule.code {
                        lines.append("  " + finding.copied)
                    }
                }
            }
        }
        for source in sources {
            lines.append("\n\(source.source.name): \(source.summary)")
            for row in source.rows {
                lines.append("\(row.title): \(row.conclusion)")
                if !row.detail.isEmpty { lines.append("  " + row.detail) }
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Always reachable beside Build Details, including while the reader is on Comments or in Focus.
struct CheckActivityButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var checks: ChecksModel
    @ObservedObject var refs: RefLookup
    @State private var showing = false

    var body: some View {
        let snapshot = CheckActivitySnapshot(model)
        Button { showing.toggle() } label: {
            ViewThatFits(in: .horizontal) {
                label(snapshot.headline, snapshot)
                label("Checks", snapshot)
            }
        }
        .buttonStyle(.plain)
        .help("Show the check log · " + snapshot.headline)
        .accessibilityLabel("Auto check log. " + snapshot.headline)
        .popover(isPresented: $showing, arrowEdge: .top) {
            CheckActivityPanel(model: model, checks: checks, refs: refs) { showing = false }
        }
        .onChange(of: model.selectedPath) { _, _ in showing = false }
        .onChange(of: model.round?.n) { _, _ in showing = false }
    }

    private func label(_ text: String, _ snapshot: CheckActivitySnapshot) -> some View {
        HStack(spacing: 5) {
            Image(systemName: snapshot.symbol)
                .foregroundStyle(snapshot.symbol == "exclamationmark.circle" ? Color(nsColor: Palette.toCheck) : Ink.secondary)
            Text(text).lineLimit(1)
            Image(systemName: "chevron.up").font(.system(size: 8))
        }.fixedSize()
    }
}

struct CheckActivityPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var checks: ChecksModel
    @ObservedObject var refs: RefLookup
    var close: () -> Void = {}
    @State var expanded: Set<String> = []
    @State private var contentHeight: CGFloat = 220

    var body: some View {
        let snapshot = CheckActivitySnapshot(model)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Auto checks").font(.headline)
                Spacer()
                Text("Round \(snapshot.round)").foregroundStyle(Ink.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.headline)
                if let time = snapshot.completedAt {
                    Text("Latest scan · " + CheckActivitySnapshot.date(time)).foregroundStyle(Ink.secondary)
                }
                if let message = snapshot.message { Text(message).foregroundStyle(Ink.secondary) }
                if snapshot.verifying {
                    Button("Verify Google Scholar…") { refs.verify() }.buttonStyle(LinkStyle())
                }
            }.font(.system(size: 12))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ChecksModel.groups, id: \.id) { group in
                        let rows = snapshot.rules.filter { $0.group == group.id }
                        if !rows.isEmpty {
                            DisclosureGroup(isExpanded: binding(group.id)) {
                                VStack(alignment: .leading, spacing: 14) {
                                    ForEach(rows) { rule in
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(alignment: .firstTextBaseline) {
                                                Text(rule.title).fixedSize(horizontal: false, vertical: true)
                                                Spacer(minLength: 8)
                                                Text(rule.conclusion).foregroundStyle(Ink.secondary)
                                                    .fixedSize()
                                            }
                                            Text(rule.detail).foregroundStyle(Ink.secondary).font(.system(size: 11))
                                                .fixedSize(horizontal: false, vertical: true)
                                            if rule.status != "off" {
                                                ForEach(snapshot.findings.filter { $0.code == rule.code }, id: \.key) { finding in
                                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                                        Text(finding.text + (finding.trail.map { " · " + $0 } ?? ""))
                                                            .fixedSize(horizontal: false, vertical: true)
                                                        if let index = checks.list.firstIndex(where: { $0.key == finding.key }) {
                                                            Button {
                                                                close()
                                                                model.tab = .checks
                                                                model.checkClicked(index)
                                                            } label: {
                                                                Image(systemName: "arrow.up.forward")
                                                            }.buttonStyle(LinkStyle())
                                                                .help("Show finding")
                                                                .accessibilityLabel("Show finding")
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }.padding(.top, 8).padding(.leading, 4)
                            } label: {
                                HStack {
                                    Text(group.title).fontWeight(.medium)
                                    Spacer()
                                    Text(summary(rows)).foregroundStyle(Ink.secondary)
                                }
                                .textSelection(.disabled)
                                .contentShape(Rectangle())
                                .onTapGesture { binding(group.id).wrappedValue.toggle() }
                            }
                        }
                    }
                    if !snapshot.rules.isEmpty { Divider() }
                    ForEach(snapshot.sources, id: \.source.rawValue) { source in
                        DisclosureGroup(isExpanded: binding(source.source.rawValue)) {
                            VStack(alignment: .leading, spacing: 12) {
                                if source.rows.isEmpty {
                                    Text(source.enabled ? "No lookup records yet." : "Online lookup is off.").foregroundStyle(Ink.secondary)
                                }
                                ForEach(source.rows) { row in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(row.title).fixedSize(horizontal: false, vertical: true)
                                        Text(row.conclusion).foregroundStyle(Ink.secondary)
                                        if !row.detail.isEmpty {
                                            Text(row.detail).font(.system(size: 11)).foregroundStyle(Ink.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).padding(.leading, 4)
                        } label: {
                            HStack {
                                Text(source.source.name).fontWeight(.medium)
                                Spacer()
                                Text(source.summary).foregroundStyle(Ink.secondary)
                            }
                            .textSelection(.disabled)
                            .contentShape(Rectangle())
                            .onTapGesture { binding(source.source.rawValue).wrappedValue.toggle() }
                        }
                    }
                }
                .padding(.trailing, 8)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: CheckLogHeight.self, value: geometry.size.height)
                })
            }
            .frame(height: min(contentHeight, 420))
            .onPreferenceChange(CheckLogHeight.self) { contentHeight = $0 }
            Divider()
            HStack {
                Button("View findings") { close(); model.tab = .checks }.buttonStyle(LinkStyle())
                    .disabled(!model.checksOn || checks.phase != .ready)
                Spacer()
                Button("Copy log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snapshot.text, forType: .string)
                }.buttonStyle(LinkStyle())
                SettingsLink { Text("Settings…") }.buttonStyle(LinkStyle())
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Ink.label)
        .textSelection(.enabled)
        .padding(16)
        .frame(width: 480)
        .background(Color(nsColor: Palette.panel))
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(key) }, set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
    }

    private func summary(_ rows: [CheckRuleRun]) -> String {
        let enabled = rows.filter { $0.status != "off" }
        if enabled.isEmpty { return "Off" }
        if enabled.contains(where: \.incomplete) { return "Incomplete" }
        let n = enabled.reduce(0) { $0 + $1.count }
        return "\(enabled.count) checks · \(n) found"
    }
}

private enum CheckLogHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
