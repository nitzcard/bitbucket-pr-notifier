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
                        ForEach(model.pullRequests) { pr in
                            PRRow(pr: pr,
                                  // The reminder shows on the row's bell button instead.
                                  details: model.details(for: pr, includeReminder: false),
                                  reminder: model.reminder(for: pr))
                                .contextMenu {
                                    Button(model.remindCommand(for: pr)) { WindowManager.shared.showReminder(for: pr) }
                                }
                        }
                    }
                    .padding(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
        }
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
/// it. The bell sets a reminder for this PR; it shows on hover, or always once set.
struct PRRow: View {
    let pr: PullRequest
    let details: String
    let reminder: Reminder?
    @ViewState private var hovering = false

    private var isNag: Bool { if case .nag = reminder?.kind { true } else { false } }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Button { NSWorkspace.shared.open(pr.url) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pr.title)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(details).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(pr.url.absoluteString)

            if hovering || reminder != nil {
                // Bell for a one-time reminder, two-arrow circle for a nag; its time below.
                Button { WindowManager.shared.showReminder(for: pr) } label: {
                    VStack(spacing: 2) {
                        // The two-arrow circle (🔄's shape) as a symbol, so it's tinted like the
                        // bell and distinct from the header's single-arrow refresh button.
                        Image(systemName: reminder.map { $0.symbol + (isNag ? "" : ".fill") } ?? "bell")
                        if let reminder { Text(reminder.shortText).font(.caption2) }
                    }
                    .iconHover()
                }
                .buttonStyle(.plain)
                .help(reminder.map { "\($0.text). Click to edit." } ?? "Remind Me…")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .menuItemHover()
        .onHover { hovering = $0 }
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

    /// The screen's usable height, less the title bar and a margin.
    private static var maxHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 800) - 80 }

    private static let tokenHelp = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!
    private static let scopes = [
        "read:user:bitbucket",
        "read:workspace:bitbucket",
        "read:repository:bitbucket",
        "read:pullrequest:bitbucket",
    ]

    var body: some View {
        Form {
            Section("Notifications") {
                Text(model.notificationsAllowed
                     ? "Notifications are enabled."
                     : "Notifications are disabled, so you won't be alerted about new pull requests.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Notification Settings…") { NSWorkspace.shared.open(Notifier.settingsURL) }
            }
            if model.isSignedIn {
                refreshSection
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
        .formStyle(.grouped)
        // As tall as its content, but never taller than the screen: past that
        // the form scrolls, so its bottom (and padding) can always be reached.
        .frame(minWidth: 480, idealWidth: 480, maxWidth: .infinity, maxHeight: Self.maxHeight)
        .task(id: model.isSignedIn) { await loadReposIfNeeded() }
        .onAppear { fillInLastSignIn() }
        .onChange(of: model.isSignedIn) { _, signedIn in if !signedIn { fillInLastSignIn() } }
        .onDisappear { browserSignIn?.cancel() }
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
