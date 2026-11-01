import SwiftUI

/// The main window: the PR list for the watched repo.
struct PRListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack {
            Text(model.repo ?? "Bitbucket PR Notifier").font(.headline).lineLimit(1)
            Spacer()
            if model.isRefreshing { ProgressView().controlSize(.small) }
            Button { Task { await model.refresh(userInitiated: true) } } label: { Image(systemName: "arrow.clockwise").iconHover() }
                .buttonStyle(.plain)
                .help("Refresh")
            Button { WindowManager.shared.showSettings() } label: { Image(systemName: "gearshape").iconHover() }
                .buttonStyle(.plain)
                .help("Settings")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var content: some View {
        if model.showsSkeleton {
            SkeletonRows()
        } else {
            loadedContent
        }
    }

    @ViewBuilder private var loadedContent: some View {
        if let placeholder = model.listPlaceholder {
            message(placeholder.text, action: placeholder.action)
        } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader("To Review")
                        if model.pullRequests.isEmpty { emptyLine(AppModel.noReviewsText) }
                        ForEach(model.pullRequests) { pr in
                            let reminder = model.reminder(for: pr)
                            PRRow(pr: pr,
                                  // The reminder shows on the row's bell button instead.
                                  details: model.details(for: pr, includeReminder: false),
                                  schedule: reminder?.kind, scheduleText: reminder?.text, command: "Remind Me…") {
                                WindowManager.shared.showReminder(for: pr)
                            }
                            .contextMenu {
                                Button(model.remindCommand(for: pr)) { WindowManager.shared.showReminder(for: pr) }
                            }
                        }

                        sectionHeader("My Pull Requests").padding(.top, 6)
                        if model.myPullRequests.isEmpty { emptyLine(AppModel.noMyPullRequestsText) }
                        ForEach(model.myPullRequests) { pr in
                            // Before the first approval the row's button nags the mergers;
                            // after it, it asks someone to merge (a nag still running shows in the details).
                            let approved = !pr.approvers.isEmpty
                            let nag = approved ? nil : model.nags[pr.id]
                            PRRow(pr: pr, details: model.myDetails(for: pr, includeNag: approved),
                                  schedule: nag?.kind, scheduleText: nag?.text, command: "Nag Mergers…",
                                  alwaysShowsBell: !approved,
                                  merge: approved ? (model.mergeAsked[pr.id], {
                                      WindowManager.shared.showAskToMerge(for: pr.id)
                                  }) : nil) {
                                WindowManager.shared.showNag(for: pr)
                            }
                            .contextMenu {
                                Button(model.nagCommand(for: pr)) { WindowManager.shared.showNag(for: pr) }
                                Button("Ask to Merge…") { WindowManager.shared.showAskToMerge(for: pr.id) }
                                    .disabled(pr.approvers.isEmpty)
                            }
                        }
                    }
                    .padding(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.subheadline.bold()).foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.top, 4).padding(.bottom, 2)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 6)
    }

    private func message(_ text: String, action: String?) -> some View {
        VStack(spacing: 8) {
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action { Button(action) { WindowManager.shared.showSettings() } }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Pulsing placeholder rows shaped like PR rows, shown while loading.
struct SkeletonRows: View {
    @ViewState private var dimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                VStack(alignment: .leading, spacing: 6) {
                    bar(width: [300, 240, 270][i], height: 13)
                    bar(width: [110, 90, 130][i], height: 10)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
            }
        }
        .padding(5)
        .opacity(dimmed ? 0.4 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dimmed = true }
        }
        .accessibilityLabel("Loading pull requests")
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2)
            .fill(Color.primary.opacity(0.12))
            .frame(width: width, height: height)
    }
}

/// A PR as a menu-style item: click opens it in the browser, hover highlights
/// it. The bell sets a reminder (or, on my PRs, a nag to the mergers); it
/// shows on hover, or always once set.
struct PRRow: View {
    let pr: PullRequest
    let details: String
    let schedule: Reminder.Kind?
    /// "Nag every 2 hr", for the bell's tooltip.
    let scheduleText: String?
    /// The bell's tooltip when nothing is set: "Remind Me…".
    let command: String
    /// Show the bell even when nothing's set and the row isn't hovered.
    var alwaysShowsBell = false
    /// On an approved PR of mine: who I asked to merge it (nil: no one yet),
    /// and what asking does. Takes the bell's place.
    var merge: (asked: String?, action: () -> Void)? = nil
    let action: () -> Void
    @ViewState private var hovering = false

    private var isNag: Bool { if case .nag = schedule { true } else { false } }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Button { NSWorkspace.shared.open(pr.url) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pr.title)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(details).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(pr.url.absoluteString)

            // One button per row, in a fixed-width column so its icon lines up
            // across rows whatever its caption ("merge", "every 2 hr"…).
            Group {
                if let merge {
                    rowButton(symbol: "arrow.triangle.merge", caption: merge.asked == nil ? "merge" : "asked",
                              help: merge.asked.map { "Asked \($0) to merge. Click to ask again." } ?? "Ask to Merge…",
                              label: "Ask to Merge…", action: merge.action)
                } else if hovering || schedule != nil || alwaysShowsBell {
                    // Bell for a one-time reminder, two-arrow circle for a nag; its time below.
                    // The two-arrow circle (🔄's shape) as a symbol, so it's tinted like the
                    // bell and distinct from the header's single-arrow refresh button.
                    rowButton(symbol: schedule.map { $0.symbol + (isNag ? "" : ".fill") } ?? "bell",
                              caption: schedule?.shortText,
                              help: scheduleText.map { "\($0). Click to edit." } ?? command,
                              label: scheduleText ?? command, action: action)
                }
            }
            .frame(width: Self.buttonColumnWidth)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .menuItemHover()
        .onHover { hovering = $0 }
    }

    private static let buttonColumnWidth: CGFloat = 64

    private func rowButton(symbol: String, caption: String?, help: String, label: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).frame(width: 20, height: 16)
                if let caption { Text(caption).font(.caption2).lineLimit(1) }
            }
            .iconHover()
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @ViewState private var email = ""
    @ViewState private var token = ""
    @ViewState private var signInError: String?
    @ViewState private var signingIn = false
    @ViewState private var browserSignIn: Task<Void, Never>?

    @ViewState private var repos: [String] = []
    @ViewState private var search = ""
    @ViewState private var loadingRepos = false
    @ViewState private var repoError: String?
    /// What Paste Member IDs did, shown beside it.
    @ViewState private var pasteResult: String?

    /// The screen's usable height, less the title bar and a margin.
    private static var maxHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 800) - 80 }

    private static let tokenHelp = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!
    private static let scopes = [
        "read:user:bitbucket",
        "read:workspace:bitbucket",
        "read:repository:bitbucket",
        "read:pullrequest:bitbucket",
    ]

    private enum Tab: Hashable { case general, account, slack }
    /// Signed out, Settings opens on Account, where signing in happens.
    @ViewState private var tab: Tab = AppModel.shared.isSignedIn ? .general : .account

    var body: some View {
        TabView(selection: $tab) {
            form {
                Section("Notifications") {
                    Text(model.notificationsAllowed
                         ? "Notifications are enabled."
                         : "Notifications are disabled, so you won't be alerted about new pull requests.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Notification Settings…") { NSWorkspace.shared.open(Notifier.settingsURL) }
                }
                refreshSection
            }
            .tabItem { Text("General") }
            .tag(Tab.general)

            form {
                if model.isSignedIn {
                    Section("Account") {
                        LabeledContent("Signed in as", value: model.accountName ?? "Bitbucket user")
                        Button("Sign Out") { model.signOut() }
                    }
                    repoSection
                } else {
                    if OAuthConfig.bundled != nil { browserSection }
                    tokenSections
                }
            }
            .tabItem { Text("Account") }
            .tag(Tab.account)

            form {
                slackSection
                if model.isSignedIn {
                    mergeSection
                    memberIDSection
                }
            }
            .tabItem { Text("Slack") }
            .tag(Tab.slack)
        }
        .padding(.top, 8)
        .frame(minWidth: 480, idealWidth: 480, maxWidth: .infinity)
        .task(id: model.isSignedIn) { await loadReposIfNeeded() }
        .onAppear { fillInLastSignIn() }
        .onChange(of: model.isSignedIn) { _, signedIn in
            if !signedIn { fillInLastSignIn(); tab = .account }
        }
        .onDisappear { browserSignIn?.cancel() }
    }

    /// One tab's grouped form: as tall as its content, but never taller than
    /// the screen; past that it scrolls, so its bottom can always be reached.
    private func form(@ViewBuilder _ content: () -> some View) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .frame(maxHeight: Self.maxHeight)
    }

    private var refreshSection: some View {
        @Bindable var model = model
        return Section("Refresh PR Interval") {
            Toggle("Refresh automatically", isOn: $model.autoRefresh)
            HStack(spacing: 6) {
                Text("Every:")
                TextField("Every", value: $model.refreshMinutes, format: .number.precision(.fractionLength(0...2)))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 56)
                Stepper("Every", value: $model.refreshMinutes, in: AppModel.minRefreshMinutes...60, step: 0.5)
                    .labelsHidden()
                Text(model.refreshMinutes == 1 ? "minute" : "minutes")
                Spacer()
            }
            .disabled(!model.autoRefresh)
            if model.autoRefresh, model.refreshMinutes < 1 {
                Text("Checking more than once a minute may exceed Bitbucket's limit of 1,000 requests per hour.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var browserSection: some View {
        Section {
            HStack {
                if browserSignIn == nil {
                    Button("Sign in with Bitbucket") { signInWithBrowser() }
                        .buttonStyle(.borderedProminent)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the browser…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { browserSignIn?.cancel() }
                }
            }
            if let signInError { Text(signInError).foregroundStyle(.red).font(.caption) }
        } footer: {
            Text("Opens Bitbucket in your browser. Approve access and you're signed in.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// After signing out, the same email and API token are ready to sign in again.
    private func fillInLastSignIn() {
        if email.isEmpty { email = model.lastEmail }
        if token.isEmpty { token = Credentials.signedOutToken ?? "" }
    }

    @ViewBuilder private var tokenSections: some View {
        let prefix = OAuthConfig.bundled != nil ? "Or use an API token — " : ""
        Section("\(prefix)1. Create a token in your browser") {
            Text("Click below, choose **Create API token with scopes**, pick **Bitbucket**, and tick these scopes:")
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.scopes.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Button("Open Bitbucket Token Page") { NSWorkspace.shared.open(Self.tokenHelp) }
        }

        Section {
            fieldRow("Atlassian email") {
                TextField("Atlassian email", text: $email, prompt: Text("you@company.com").foregroundStyle(.secondary))
            }
            fieldRow("API token") {
                SecureField("API token", text: $token, prompt: Text("ATATT…").foregroundStyle(.secondary))
            }
            if OAuthConfig.bundled == nil, let signInError {
                Text(signInError).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                if signingIn { ProgressView().controlSize(.small) }
                Button("Sign In") { signIn() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(email.isEmpty || token.isEmpty || signingIn)
            }
        } header: {
            Text("2. Copy the token, then come back here")
        } footer: {
            Text("Saved on this Mac, readable only by your user account.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// A label followed by a left-aligned field that fills the rest of the row.
    private func fieldRow(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 110, alignment: .leading)
            field()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .labelsHidden()
                .frame(maxWidth: .infinity)
        }
    }

    private var repoSection: some View {
        Section("Repository") {
            LabeledContent("Watching", value: model.repo ?? "None")
            TextField("Search", text: $search, prompt: Text("Search repositories"))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .labelsHidden()
            if loadingRepos {
                ProgressView().frame(maxWidth: .infinity)
            } else if let repoError {
                Text(repoError).foregroundStyle(.red).font(.caption)
                Button("Retry") { Task { await loadRepos() } }
            } else {
                let matches = filteredRepos
                if matches.isEmpty {
                    Text("No matching repositories").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(matches, id: \.self) { name in
                                    Button {
                                        model.repo = name
                                    } label: {
                                        HStack {
                                            Text(name)
                                            Spacer()
                                            if name == model.repo { Image(systemName: "checkmark") }
                                        }
                                        .padding(.vertical, 5)
                                        .padding(.horizontal, 6)
                                        .menuItemHover(selected: name == model.repo)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(height: 260)
                        .onAppear {
                            if let repo = model.repo { proxy.scrollTo(repo, anchor: .center) }
                        }
                    }
                }
            }
        }
    }

    /// Per repository: some repos let only a few people merge.
    private var mergeSection: some View {
        @Bindable var model = model
        return Section {
            Toggle("Offer to ask someone when a pull request of mine is first approved", isOn: $model.askToMerge)
            Group {
                ForEach($model.mergers) { $person in
                    HStack(spacing: 6) {
                        TextField("Name", text: $person.name, prompt: Text("Name"))
                        TextField("Member ID", text: $person.memberID, prompt: Text("U0123ABCD"))
                            .frame(width: 120)
                        Button { model.mergers.removeAll { $0.id == person.id } } label: { Image(systemName: "minus") }
                            .help("Remove Merger")
                    }
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                }
                Button("Add Merger") { model.mergers.append(SlackPerson(name: "", memberID: "")) }
            }
        } header: {
            Text("Merging in \(model.repo ?? "This Repository")")
        } footer: {
            Text("Ask to Merge… on an approved pull request of yours messages one of these people on Slack. "
                 + "A Slack member ID is on their profile: ⋯ → Copy member ID.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var slackSection: some View {
        @Bindable var model = model
        return Section {
            labeledRow("User Token:") {
                SecureField("User Token", text: $model.slackToken,
                            prompt: Text("xoxp-…").foregroundStyle(.secondary))
            }
            labeledRow("Webhook URL:") {
                TextField("Webhook URL", text: $model.slackWebhook,
                          prompt: Text("https://hooks.slack.com/triggers/…").foregroundStyle(.secondary))
            }
            labeledRow("Workspace ID:") {
                TextField("Workspace ID", text: $model.slackTeam, prompt: Text("T0123ABCD").foregroundStyle(.secondary))
            }
        } header: {
            Text("Slack")
        } footer: {
            Text("With a user token (from a Slack app with the user scopes im:write and chat:write), messages are sent as you. "
                 + "Otherwise a Slack workflow that starts from a webhook with the variables user_id and message sends them. "
                 + "With neither, the message is copied and the person's DM opens in Slack, using the workspace ID.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Copies a prompt for an AI assistant that can search Slack, then fills in
    /// the member IDs from its answer on the clipboard.
    @ViewBuilder private var memberIDSection: some View {
        let missing = model.peopleMissingMemberIDs
        Section {
            if missing.isEmpty {
                Text("Everyone above has a member ID.").foregroundStyle(.secondary)
            } else {
                Text(model.memberIDPrompt)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let pasteResult { Text(pasteResult).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Copy Prompt") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.memberIDPrompt, forType: .string)
                    pasteResult = nil
                }
                Button("Paste Member IDs") {
                    let filled = model.fillMemberIDs(from: NSPasteboard.general.string(forType: .string) ?? "")
                    pasteResult = filled == 0 ? "No matching names on the clipboard."
                        : filled == 1 ? "Filled 1 member ID." : "Filled \(filled) member IDs."
                }
            }
            .disabled(missing.isEmpty)
        } header: {
            Text("Find Member IDs with AI")
        } footer: {
            Text("Add mergers by name, then copy this prompt into an AI assistant that can search your Slack "
                 + "(such as Claude with Slack connected). Copy its answer and click Paste Member IDs.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A right-aligned "Label:" directly beside its left-aligned field.
    private func labeledRow(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 130, alignment: .trailing)
            field()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .labelsHidden()
                .frame(maxWidth: .infinity)
        }
    }

    private var filteredRepos: [String] {
        search.isEmpty ? repos : repos.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    private func signIn() {
        signingIn = true
        signInError = nil
        Task {
            do {
                try await model.signIn(email: email.trimmingCharacters(in: .whitespaces),
                                       token: token.trimmingCharacters(in: .whitespaces))
                token = ""
            } catch {
                signInError = error.localizedDescription
            }
            signingIn = false
        }
    }

    private func signInWithBrowser() {
        signInError = nil
        browserSignIn = Task {
            do {
                try await model.signInWithBrowser()
            } catch is CancellationError {
            } catch {
                signInError = error.localizedDescription
            }
            browserSignIn = nil
        }
    }

    private func loadReposIfNeeded() async {
        if model.isSignedIn, repos.isEmpty { await loadRepos() }
    }

    private func loadRepos() async {
        loadingRepos = true
        repoError = nil
        do { repos = try await model.client().repositories() } catch { repoError = error.localizedDescription }
        loadingRepos = false
    }
}

/// The macOS 27 SDK turns `@State` into a macro whose plugin ships only with
/// Xcode. Aliasing the underlying property wrapper lets Command Line Tools build.
typealias ViewState = SwiftUI.State
