import SwiftUI

/// The "Remind Me" window: pick a PR, then a one-time time or a
/// repeating interval. Also where a PR's reminder is cancelled.
struct ReminderView: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void

    private enum Mode: Hashable { case once, repeatedly }
    private enum Unit: Hashable { case minutes, hours }

    @ViewState private var prID: Int?
    @ViewState private var mode = Mode.once
    @ViewState private var date = Date().addingTimeInterval(3600)
    @ViewState private var every = 1.0
    @ViewState private var unit = Unit.hours

    /// State is filled in here, not in onAppear: changing it after the first
    /// layout would resize the window mid-layout.
    init(preselected: Int?, done: @escaping () -> Void) {
        self.done = done
        let model = AppModel.shared
        let candidates = model.pullRequests
        let pr = candidates.first { $0.id == preselected } ?? candidates.first
        _prID = ViewState(initialValue: pr?.id)
        let values = Self.values(for: pr.flatMap { model.reminder(for: $0)?.kind })
        _mode = ViewState(initialValue: values.mode)
        _date = ViewState(initialValue: values.date)
        _every = ViewState(initialValue: values.every)
        _everyText = ViewState(initialValue: Self.format(values.every))
        _unit = ViewState(initialValue: values.unit)
    }

    private var candidates: [PullRequest] {
        model.pullRequests
    }

    private var selected: PullRequest? { candidates.first { $0.id == prID } }

    /// Classic Mac dialog layout: right-aligned "Label:" beside its control,
    /// radio options all visible (unselected option's controls dimmed),
    /// default button bottom right, destructive action bottom left.
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 12) {
                GridRow {
                    Text("Pull Request:").gridColumnAlignment(.trailing)
                    Picker("Pull Request", selection: $prID) {
                        ForEach(candidates) { pr in Text(pr.title).lineLimit(1).tag(Optional(pr.id)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                }
                GridRow {
                    Text("Remind:")
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            radio("Once at", .once)
                            DatePicker("At", selection: $date, in: Date()...).labelsHidden()
                                .disabled(mode != .once)
                        }
                        HStack(spacing: 6) {
                            ForEach(Reminder.presets, id: \.title) { preset in
                                Button(preset.title) { date = preset.date() }.controlSize(.small)
                            }
                        }
                        .fixedSize() // full button titles; the sheet widens to fit
                        .padding(.leading, 20)
                        .disabled(mode != .once)

                        HStack(spacing: 6) {
                            radio("Every", .repeatedly)
                            // Digits and one decimal point; anything else is dropped as it's typed.
                            TextField("Every", text: Binding(
                                get: { everyText },
                                set: { everyText = Self.decimalOnly($0); every = Double(everyText) ?? 0 }))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                                .frame(width: 48)
                            Stepper("Every", value: Binding(get: { every }, set: { every = $0; everyText = Self.format($0) }),
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
                        .overlay(alignment: .leading) { if mode != .repeatedly { radio("Every", .repeatedly) } }

                        Text(mode == .repeatedly && tooShort
                             ? "The shortest interval is 5 seconds."
                             : "Repeats until you comment on or approve it.")
                            .frame(width: 300, alignment: .leading)
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                }
            }

            HStack {
                Button("Cancel Reminder") {
                    if let selected { model.clearReminder(for: selected.id) }
                    done()
                }
                .disabled(selected.flatMap { model.reminder(for: $0) } == nil)
                Spacer(minLength: 24)
                Button("Cancel", role: .cancel, action: done).keyboardShortcut(.cancelAction)
                Button("Set Reminder", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || (mode == .repeatedly && tooShort))
            }
        }
        .padding(20)
        .fixedSize()
        .onChange(of: prID) { _, _ in
            let values = Self.values(for: selected.flatMap { model.reminder(for: $0)?.kind })
            (mode, date, every, unit) = (values.mode, values.date, values.every, values.unit)
            everyText = Self.format(values.every)
        }
    }

    @ViewState private var everyText = ""

    private var seconds: TimeInterval { every * (unit == .hours ? 3600 : 60) }
    private var tooShort: Bool { seconds < Reminder.minNagSeconds }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }

    private static func decimalOnly(_ text: String) -> String {
        var seenPoint = false
        return String(text.filter { ch in
            if ch.isNumber { return true }
            if ch == ".", !seenPoint { seenPoint = true; return true }
            return false
        }.prefix(6))
    }

    /// A single native radio button bound to `mode`; two of these share it.
    private func radio(_ title: String, _ value: Mode) -> some View {
        Picker(title, selection: $mode) { Text(title).tag(value) }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .fixedSize()
    }

    /// Form values showing an existing reminder, or defaults when there's none.
    private static func values(for kind: Reminder.Kind?) -> (mode: Mode, date: Date, every: Double, unit: Unit) {
        switch kind {
        case .once(let at):
            return (.once, max(at, Date()), 1, .hours)
        case .nag(let interval):
            return interval >= 3600
                ? (.repeatedly, Date().addingTimeInterval(3600), interval / 3600, .hours)
                : (.repeatedly, Date().addingTimeInterval(3600), interval / 60, .minutes)
        case nil:
            return (.once, Date().addingTimeInterval(3600), 1, .hours)
        }
    }

    private func save() {
        guard let selected else { return }
        switch mode {
        case .once:
            model.setReminder(.once(date), for: selected)
        case .repeatedly:
            model.setReminder(.nag(seconds), for: selected)
        }
        done()
    }
}
