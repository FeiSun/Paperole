import SwiftUI

/// Edit Paper… (FEATURES E2, OV-7; the sidebar's and the pages' context menus): the paper's title and its student
/// (`edit_paper`), the student typed or picked from those listed. Papers whose student's name is the same, case and
/// spaces aside, are listed together; a paper without one is under Unassigned until it gets one.
struct EditPaperSheet: View {
    let model: AppModel
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var student = ""
    @State private var loaded = false

    private var paper: PaperRef? { model.papers.first { $0.path == path } }

    var body: some View {
        let names = model.studentGroups.filter { !$0.unassigned }.map(\.name)
        VStack(alignment: .leading, spacing: 14) {
            Text(paper?.student.isEmpty == true ? "Assign to a Student" : "Edit Paper").font(.title2.bold())
            Form {
                TextField("Title", text: $title)
                HStack(spacing: 6) {
                    TextField("Student", text: $student)
                    if !names.isEmpty {
                        Menu {
                            ForEach(names, id: \.self) { n in Button(n) { student = n } }
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("A student already listed")
                    }
                }
            }
            Text("Papers with the same student, case and spaces aside, are listed together. final.pdf and emails already written keep the old words.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let t = StudentName.shown(title), s = StudentName.shown(student)
                    model.editPaper(path, title: t != paper?.title ? t : nil, student: s != paper?.student && !s.isEmpty ? s : nil)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            guard !loaded, let p = paper else { return }
            loaded = true
            title = p.title
            student = p.student
        }
    }

    private var canSave: Bool {
        let t = StudentName.shown(title), s = StudentName.shown(student)
        guard let p = paper, !t.isEmpty else { return false }
        if s.isEmpty && !p.student.isEmpty { return false }  // a student's name cannot be emptied (edit_paper)
        return t != p.title || (s != p.student && !s.isEmpty)
    }
}

/// Rename Student… (the sidebar's student context menu): every paper of the student gets the name, which also puts
/// one student's papers written two ways under one name.
struct RenameStudentSheet: View {
    let model: AppModel
    let key: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var loaded = false

    var body: some View {
        let g = model.studentGroups.first { $0.key == key }
        let others = model.studentGroups.filter { !$0.unassigned && $0.key != key }.map(\.name)
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Student").font(.title2.bold())
            Form {
                HStack(spacing: 6) {
                    TextField("Name", text: $name)
                    if !others.isEmpty {
                        Menu {
                            ForEach(others, id: \.self) { n in Button(n) { name = n } }
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Another student listed: their papers and these are then listed together")
                    }
                }
            }
            Text(Self.whoGetsIt(g?.name, papers: g?.papers.count ?? 0) + " The name of another student listed puts both students’ papers together.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") {
                    model.renameStudent(key, to: name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(StudentName.shown(name).isEmpty || StudentName.shown(name) == g?.name)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = g?.name ?? ""
        }
    }

    /// "All 3 papers of Maya Chen get this name.", or for one "Maya Chen’s paper gets this name." (review 2026-10-24:
    /// it read "All 1 paper of Maya Chen get this name.").
    static func whoGetsIt(_ student: String?, papers: Int) -> String {
        papers == 1 ? "\(student ?? "The student")’s paper gets this name."
            : "All \(count(papers, "paper")) of \(student ?? "the student") get this name."
    }
}

/// Map Headings… (FEATURES OV-9, OVERVIEW-v2 §3.2): for each of the student's papers, each first-level heading with
/// the standard section it belongs to, filled in with the engine's suggestion (`suggested_bucket`) until the advisor
/// answers; "Its own column" keeps the heading's own name. Done keeps the answers of the papers whose answers changed
/// (in their ledgers, the app's list keeping copies), and Where the comments land is asked for again, once.
struct MapHeadingsSheet: View {
    let model: AppModel
    let key: String
    @Environment(\.dismiss) private var dismiss
    @State private var answers: [String: [String: String]] = [:]
    @State private var loaded = false

    static let standard: [(String, String)] = [("abstract", "Abstract"), ("introduction", "Introduction"), ("method", "Methods"),
                                               ("results", "Results"), ("discussion", "Discussion"), ("conclusion", "Conclusion")]

    /// A standard section's column title; nil for "" (its own column) or an unknown id.
    static func title(_ bucket: String) -> String? { standard.first { $0.0 == bucket }?.1 }

    var body: some View {
        let papers = model.studentGroups.first { $0.key == key }?.papers ?? []
        VStack(alignment: .leading, spacing: 12) {
            Text("Map Headings").font(.title2.bold())
            Text("Say which standard section each heading belongs to, so Where the comments land puts like with like. Each paper needs this once.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(papers) { p in
                        if let d = model.hubModel.data[p.path] {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(p.title).font(.system(size: 13, weight: .semibold))
                                ForEach(d.sections, id: \.key) { s in
                                    HStack(spacing: 10) {
                                        Text(s.key == "front" ? "Title and abstract" : s.name ?? s.title ?? s.key)
                                            .foregroundStyle(s.gone == true ? Ink.secondary : Ink.label)
                                            .lineLimit(1).truncationMode(.tail)
                                            .frame(width: 220, alignment: .leading)
                                            .help(s.gone == true ? "Not in the latest round" : s.title ?? "")
                                        Picker("", selection: binding(p.path, s.key)) {
                                            ForEach(Self.standard, id: \.0) { b in Text(b.1).tag(b.0) }
                                            Divider()
                                            Text("Its own column").tag("")
                                        }
                                        .labelsHidden()
                                        .frame(width: 180)
                                    }
                                    .font(.system(size: 13))
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 420)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    let changed = Self.changed(answers, papers)
                    for (path, a) in changed { model.setBuckets(path, a, reload: false) }
                    if !changed.isEmpty && model.hub != nil { model.loadHub() }  // once, after them (A4b-08)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            answers = Self.initial(papers, data: model.hubModel.data)
        }
    }

    private func binding(_ path: String, _ key: String) -> Binding<String> {
        Binding(get: { answers[path]?[key] ?? "" }, set: { answers[path, default: [:]][key] = $0 })
    }

    /// The answers that are not what the paper has (one never answered has none: Done keeps its suggestions).
    static func changed(_ answers: [String: [String: String]], _ papers: [PaperRef]) -> [String: [String: String]] {
        answers.filter { path, a in papers.first { $0.path == path }?.buckets != a }
    }

    /// Each paper's answers so far, else the engine's suggestions ("" where it has none).
    static func initial(_ papers: [PaperRef], data: [String: PaperOverview]) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for p in papers {
            guard let d = data[p.path] else { continue }
            var a: [String: String] = [:]
            for s in d.sections { a[s.key] = p.buckets?[s.key] ?? s.suggestedBucket ?? "" }
            out[p.path] = a
        }
        return out
    }
}
