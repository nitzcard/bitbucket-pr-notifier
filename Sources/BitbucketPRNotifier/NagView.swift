import SwiftUI

/// The "Nag Mergers" sheet: pick one of my PRs and the repo's mergers, then send
/// them a Slack message now, once at a time, or now and every interval.
struct NagView: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void

    private enum Mode: Hashable { case now, once, repeatedly }
    private enum Unit: Hashable { case minutes, hours }

    @ViewState private var prID: Int?
    @ViewState private var chosen: Set<String> = []
    @ViewState private var mode = Mode.now
    @ViewState private var date = Date().addingTimeInterval(3600)
    @ViewState private var every = 4.0
    @ViewState private var everyText = ""
    @ViewState private var unit = Unit.hours

    /// State is filled in here, not in onAppear: changing it after the first
    /// layout would resize the window mid-layout.
    init(preselected: Int?, done: @escaping () -> Void) {
        self.done = done
        let model = AppModel.shared
        let pr = model.myPullRequests.first { $0.id == preselected } ?? model.myPullRequests.first
        _prID = ViewState(initialValue: pr?.id)
        let values = Self.values(for: pr, model: model)
        _chosen = ViewState(initialValue: values.chosen)
        _mode = ViewState(initialValue: values.mode)
        _date = ViewState(initialValue: values.date)
        _every = ViewState(initialValue: values.every)
        _everyText = ViewState(initialValue: NumberText.format(values.every))
        _unit = ViewState(initialValue: values.unit)
    }

    private var selected: PullRequest? { model.myPullRequests.first { $0.id == prID } }
    /// Chosen mergers' member IDs, leaving out any since removed in Settings.
    private var recipients: Set<String> { chosen.intersection(model.readyMergers.map(\.memberID)) }

    private var seconds: TimeInterval { every * (unit == .hours ? 3600 : 60) }
    private var tooShort: Bool { seconds < ReviewerNag.minSeconds }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 12) {
                GridRow {
                    Text("Pull Request:").gridColumnAlignment(.trailing)
                    Picker("Pull Request", selection: $prID) {
                        ForEach(model.myPullRequests) { pr in Text(pr.title).lineLimit(1).tag(Optional(pr.id)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                }
                GridRow {
                    Text("Mergers:")
                    mergerList
                }
                GridRow {
                    Text("Send:")
                    sendOptions
                }
            }

            HStack {
                Button("Cancel Nag") {
                    if let selected { model.clearNag(for: selected.id) }
                    done()
                }
                .disabled(selected.flatMap { model.nags[$0.id] } == nil)
                Spacer(minLength: 24)
                Button("Cancel", role: .cancel, action: done).keyboardShortcut(.cancelAction)
                Button(mode == .now ? "Send" : "Schedule", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || recipients.isEmpty || (mode == .repeatedly && tooShort))
            }
        }
        .padding(20)
        .fixedSize()
        .onChange(of: prID) { _, _ in
            let values = Self.values(for: selected, model: model)
            (chosen, mode, date, every, unit) = (values.chosen, values.mode, values.date, values.every, values.unit)
            everyText = NumberText.format(values.every)
        }
    }

    @ViewBuilder private var mergerList: some View {
        if model.readyMergers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No one is set to merge in this repository.").foregroundStyle(.secondary)
                Button("Add Mergers in Settings…") {
                    done()
                    WindowManager.shared.showSettings()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.readyMergers) { person in
                    Toggle(person.name, isOn: Binding(
                        get: { chosen.contains(person.memberID) },
                        set: { on in if on { chosen.insert(person.memberID) } else { chosen.remove(person.memberID) } }))
                }
            }
        }
    }

    private var sendOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            radio("Now", .now)
            HStack(spacing: 6) {
                radio("Once at", .once)
                DatePicker("At", selection: $date, in: Date()...).labelsHidden()
                    .disabled(mode != .once)
            }
            HStack(spacing: 6) {
                radio("Now and every", .repeatedly)
                TextField("Every", text: Binding(
                    get: { everyText },
                    set: { everyText = NumberText.decimalOnly($0); every = Double(everyText) ?? 0 }))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 48)
                Stepper("Every", value: Binding(get: { every }, set: { every = $0; everyText = NumberText.format($0) }),
                        in: 0...999, step: 1).labelsHidden()
                Picker("Unit", selection: $unit) {
                    Text("Minutes").tag(Unit.minutes)
                    Text("Hours").tag(Unit.hours)
                }
                .labelsHidden()
                .fixedSize()
            }
            .disabled(mode != .repeatedly)
            // Keep the radio itself clickable while its controls are dimmed.
            .overlay(alignment: .leading) { if mode != .repeatedly { radio("Now and every", .repeatedly) } }

            Text(mode == .repeatedly && tooShort
                 ? "The shortest interval is 15 minutes."
                 : "Stops once the pull request is merged or declined.")
                .frame(width: 300, alignment: .leading)
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 20)
        }
    }

    private func radio(_ title: String, _ value: Mode) -> some View {
        Picker(title, selection: $mode) { Text(title).tag(value) }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .fixedSize()
    }

    /// Form values showing a PR's existing nag, or defaults: every merger,
    /// sent now.
    private static func values(for pr: PullRequest?, model: AppModel)
        -> (chosen: Set<String>, mode: Mode, date: Date, every: Double, unit: Unit) {
        let later = Date().addingTimeInterval(3600)
        guard let pr, let nag = model.nags[pr.id] else {
            return (Set(model.readyMergers.map(\.memberID)), .now, later, 4, .hours)
        }
        switch nag.kind {
        case .once(let at):
            return (nag.recipients, .once, max(at, Date()), 4, .hours)
        case .nag(let interval):
            return interval >= 3600
                ? (nag.recipients, .repeatedly, later, interval / 3600, .hours)
                : (nag.recipients, .repeatedly, later, interval / 60, .minutes)
        }
    }

    private func save() {
        guard let selected else { return }
        let recipients = recipients
        switch mode {
        case .now: Task { await model.nagNow(selected, recipients: recipients) }
        case .once: model.setNag(.once(date), recipients: recipients, for: selected)
        case .repeatedly: model.setNag(.nag(seconds), recipients: recipients, for: selected)
        }
        done()
    }
}

/// The "Ask to Merge" sheet: pick an approved PR of mine and one of the
/// repo's mergers, and message them on Slack.
struct AskToMergeView: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void

    @ViewState private var prID: Int?
    @ViewState private var mergerID: UUID?

    init(preselected: Int?, done: @escaping () -> Void) {
        self.done = done
        let model = AppModel.shared
        let candidates = model.approvedPullRequests
        _prID = ViewState(initialValue: (candidates.first { $0.id == preselected } ?? candidates.first)?.id)
        _mergerID = ViewState(initialValue: model.readyMergers.first?.id)
    }

    private var selected: PullRequest? { model.approvedPullRequests.first { $0.id == prID } }
    private var merger: SlackPerson? { model.readyMergers.first { $0.id == mergerID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 12) {
                GridRow {
                    Text("Pull Request:").gridColumnAlignment(.trailing)
                    Picker("Pull Request", selection: $prID) {
                        ForEach(model.approvedPullRequests) { pr in Text(pr.title).lineLimit(1).tag(Optional(pr.id)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                }
                GridRow {
                    Text("Ask:")
                    if model.readyMergers.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No one is set to merge in this repository.").foregroundStyle(.secondary)
                            Button("Add Mergers in Settings…") {
                                done()
                                WindowManager.shared.showSettings()
                            }
                        }
                    } else {
                        Picker("Ask", selection: $mergerID) {
                            ForEach(model.readyMergers) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                GridRow {
                    Text("Message:")
                    Text(selected.flatMap { pr in merger.map { Slack.mergeText(pr, to: $0) } } ?? "")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(width: 320, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer(minLength: 24)
                Button("Cancel", role: .cancel, action: done).keyboardShortcut(.cancelAction)
                Button("Send") {
                    if let selected, let merger { Task { await model.askToMerge(selected, merger: merger) } }
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || merger == nil)
            }
        }
        .padding(20)
        .fixedSize()
    }
}
