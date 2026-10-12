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
            Text(model.repo ?? "PR Notify").font(.headline).lineLimit(1)
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
        switch model.status {
        case .signedOut:
            message("Sign in to Bitbucket to see your pull requests.", action: "Sign In…")
        case .noRepo:
            message("Choose a repository to watch.", action: "Choose Repository…")
        case .error(let text) where model.pullRequests.isEmpty:
            message(text, action: nil)
        default:
            if model.pullRequests.isEmpty {
                message("No pull requests to review.", action: nil)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.pullRequests) { pr in
                            PRRow(pr: pr,
                                  details: pr.details(me: model.userUUID, myComments: model.myCommentCount(pr),
                                                      reminder: model.reminder(for: pr)),
                                  canRemind: pr.isUnreviewed(by: model.userUUID),
                                  hasReminder: model.reminder(for: pr) != nil)
                                .contextMenu {
                                    Button("Remind Me…") { WindowManager.shared.showReminder(for: pr) }
                                        .disabled(!pr.isUnreviewed(by: model.userUUID))
                                }
                        }
                    }
                    .padding(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
    let canRemind: Bool
    let hasReminder: Bool
    @ViewState private var hovering = false

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

            if canRemind && (hovering || hasReminder) {
                Button { WindowManager.shared.showReminder(for: pr) } label: {
                    Image(systemName: hasReminder ? "bell.fill" : "bell").iconHover()
                }
                .buttonStyle(.plain)
                .help(hasReminder ? "Edit Reminder…" : "Remind Me…")
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
                LabeledContent("Status") {
                    Text(model.notificationsAllowed ? "On" : "Off")
                        .foregroundStyle(model.notificationsAllowed ? Color.secondary : Color.red)
                }
                if !model.notificationsAllowed {
                    Text("You won't be alerted about new pull requests until notifications are turned on.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(model.notificationsAllowed ? "Notification Settings…" : "Turn On Notifications…") {
                    NSWorkspace.shared.open(Notifier.settingsURL)
                }
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
        .scrollDisabled(true)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: model.isSignedIn) { await loadReposIfNeeded() }
        .onAppear { if email.isEmpty { email = model.lastEmail } }
        .onDisappear { browserSignIn?.cancel() }
    }

    private var refreshSection: some View {
        @Bindable var model = model
        return Section("Refresh") {
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
