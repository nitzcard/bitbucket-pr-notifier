import AppKit
import Observation

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    /// Automatic checking, set in Settings. Each check costs ≥1 request against
    /// Bitbucket's 1,000/hour limit, so intervals under a minute get a warning.
    var autoRefresh = UserDefaults.standard.object(forKey: "autoRefresh") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoRefresh, forKey: "autoRefresh"); start() }
    }
    var refreshMinutes = UserDefaults.standard.object(forKey: "refreshMinutes") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(refreshMinutes, forKey: "refreshMinutes"); start() }
    }
    static let minRefreshMinutes = 0.1

    enum Status: Equatable {
        case signedOut
        case noRepo
        case ok
        case error(String)
    }

    private(set) var pullRequests: [PullRequest] = []
    /// My comment count per PR id, refetched only when the PR's `updatedOn` changes.
    private var myComments: [Int: (updatedOn: Date, count: Int)] = [:]
    private(set) var status: Status = .signedOut
    private(set) var isRefreshing = false
    /// Show placeholder rows: first load of a repo, or a refresh the user asked
    /// for. Background polls keep the current list to avoid flicker.
    private(set) var showsSkeleton = false
    /// Reminders for the current repo, by PR id (see Reminders.swift).
    var reminders: [Int: Reminder] = [:]
    /// Mirrors the macOS notification permission; Settings warns when it's off.
    var notificationsAllowed = true
    private(set) var lastUpdated: Date?

    private(set) var accountName: String? = UserDefaults.standard.string(forKey: "accountName")
    /// Last email used for API-token sign-in, to prefill the form.
    var lastEmail: String { UserDefaults.standard.string(forKey: "email") ?? "" }

    var repo: String? = UserDefaults.standard.string(forKey: "repo") {
        didSet {
            UserDefaults.standard.set(repo, forKey: "repo")
            knownIDs = nil
            pullRequests = []
            myComments = [:]
            lastUpdated = nil
            reminders = Self.loadReminders(repo: repo)
            Task { await refresh() }
        }
    }

    /// PR ids seen in the last check, persisted per repo so PRs assigned while
    /// the app wasn't running still notify on the next launch. `nil` (never
    /// checked this repo) makes the next check silent.
    private var knownIDs: Set<Int>? {
        get { repo.flatMap { UserDefaults.standard.array(forKey: "knownIDs.\($0)") as? [Int] }.map(Set.init) }
        set { if let repo { UserDefaults.standard.set(newValue.map(Array.init), forKey: "knownIDs.\(repo)") } }
    }
    private(set) var userUUID: String?
    private var pollTask: Task<Void, Never>?

    private var credentials: Credentials? = Credentials.load()
    /// Shared so concurrent callers don't spend the same rotating refresh token twice.
    private var tokenRefresh: Task<OAuthTokens, Error>?

    var isSignedIn: Bool { credentials != nil && status != .signedOut }

    init() {
        status = credentials == nil ? .signedOut : .ok
        reminders = Self.loadReminders(repo: repo)
    }

    /// Checks once now, then keeps checking if automatic refresh is on.
    /// Called again whenever the refresh settings change.
    func start() {
        pollTask?.cancel()
        pollTask = Task {
            await refresh()
            while autoRefresh, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(refreshMinutes, Self.minRefreshMinutes) * 60))
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }

    /// A client with valid credentials, refreshing the OAuth access token if needed.
    func client() async throws -> BitbucketClient {
        switch credentials {
        case nil:
            throw BitbucketError.unauthorized()
        case .apiToken(let email, let token):
            return BitbucketClient(email: email, token: token)
        case .oauth(let tokens):
            guard tokens.isExpiring else { return BitbucketClient(accessToken: tokens.accessToken) }
            guard let config = OAuthConfig.bundled else { throw BitbucketError.unauthorized() }
            let refresh = tokenRefresh ?? Task { try await config.refresh(tokens) }
            tokenRefresh = refresh
            defer { tokenRefresh = nil }
            let fresh = try await refresh.value
            credentials = .oauth(fresh)
            credentials?.save()
            return BitbucketClient(accessToken: fresh.accessToken)
        }
    }

    func signIn(email: String, token: String) async throws {
        let user = try await BitbucketClient(email: email, token: token).currentUser()
        UserDefaults.standard.set(email, forKey: "email")
        await finishSignIn(.apiToken(email: email, token: token), user: user)
    }

    func signInWithBrowser() async throws {
        guard let config = OAuthConfig.bundled else { return }
        let tokens = try await config.signIn()
        let user = try await BitbucketClient(accessToken: tokens.accessToken).currentUser()
        await finishSignIn(.oauth(tokens), user: user)
    }

    private func finishSignIn(_ credentials: Credentials, user: BitbucketUser) async {
        credentials.save()
        self.credentials = credentials
        accountName = user.display_name
        UserDefaults.standard.set(user.display_name, forKey: "accountName")
        userUUID = user.uuid
        status = .ok
        NSApp.activate(ignoringOtherApps: true) // come back from the browser
        await refresh()
    }

    func signOut() {
        Credentials.delete()
        credentials = nil
        UserDefaults.standard.removeObject(forKey: "accountName")
        accountName = nil
        userUUID = nil
        knownIDs = nil
        pullRequests = []
        status = .signedOut
        updateDockBadge()
    }

    func refresh(userInitiated: Bool = false) async {
        guard credentials != nil else { status = .signedOut; return }
        guard let repo else { status = .noRepo; return }
        guard !isRefreshing else { return }
        isRefreshing = true
        showsSkeleton = userInitiated || lastUpdated == nil
        let started = ContinuousClock.now
        defer {
            isRefreshing = false
            showsSkeleton = false
        }

        do {
            let client = try await client()
            if userUUID == nil { userUUID = try await client.currentUser().uuid }
            let prs = try await client.pullRequests(repo: repo, reviewerUUID: userUUID!)
            guard repo == self.repo else { return } // repo changed mid-request

            if let knownIDs {
                let new = prs.filter { !knownIDs.contains($0.id) }
                Notifier.notify(new)
            }
            knownIDs = Set(prs.map(\.id))
            await updateMyComments(prs, repo: repo, client: client)
            if userInitiated { try? await Task.sleep(until: started + .milliseconds(400)) }
            pullRequests = prs
            pruneReminders(prs)
            topUpFastNags()
            lastUpdated = Date()
            status = .ok
        } catch BitbucketError.unauthorized(_) {
            status = .signedOut
        } catch {
            status = .error(error.localizedDescription)
        }
        updateDockBadge()
    }

    func myCommentCount(_ pr: PullRequest) -> Int { myComments[pr.id]?.count ?? 0 }

    private func updateMyComments(_ prs: [PullRequest], repo: String, client: BitbucketClient) async {
        guard let me = userUUID else { return }
        let stale = prs.filter { myComments[$0.id]?.updatedOn != $0.updatedOn }
        let counts = await withTaskGroup(of: (PullRequest, Int?).self) { group in
            for pr in stale {
                group.addTask { (pr, try? await client.commentCount(repo: repo, prID: pr.id, by: me)) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        for (pr, count) in counts {
            if let count { myComments[pr.id] = (pr.updatedOn, count) }
        }
        let current = Set(prs.map(\.id))
        myComments = myComments.filter { current.contains($0.key) }
    }

    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = pullRequests.isEmpty ? nil : "\(pullRequests.count)"
    }
}
