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
    /// Open PRs I opened in the watched repo, with each reviewer's state.
    private(set) var myPullRequests: [PullRequest] = []
    /// My comment count per PR id, refetched only when the PR's `updatedOn` changes.
    private var myComments: [Int: (updatedOn: Date, count: Int)] = [:]
    private(set) var status: Status = .signedOut
    private(set) var isRefreshing = false
    /// Show placeholder rows: first load of a repo, or a refresh the user asked
    /// for. Background polls keep the current list to avoid flicker.
    private(set) var showsSkeleton = false
    /// Reminders for the current repo, by PR id (see Reminders.swift).
    var reminders: [Int: Reminder] = [:]
    /// Slack nags to the mergers about my PRs, by PR id (see ReviewerNags.swift).
    var nags: [Int: ReviewerNag] = [:] {
        didSet { saveRepoSetting(try? JSONEncoder().encode(nags), "nags") }
    }
    /// Who I asked to merge each of my PRs, by PR id.
    var mergeAsked: [Int: String] = [:] {
        didSet { saveRepoSetting(Dictionary(uniqueKeysWithValues: mergeAsked.map { (String($0.key), $0.value) }), "mergeAsked") }
    }

    /// This repo's setting: offer to ask a merger when one of my PRs gets its first approval.
    var askToMerge = false { didSet { saveRepoSetting(askToMerge, "askToMerge") } }
    /// Who can merge in this repo (some repos let only a few people merge).
    var mergers: [SlackPerson] = [] { didSet { saveRepoSetting(try? JSONEncoder().encode(mergers), "mergers") } }

    /// Slack Workflow Builder webhook that sends DMs (see Slack.swift). Empty:
    /// messages are copied and the DM opened in Slack instead.
    var slackWebhook = UserDefaults.standard.string(forKey: "slackWebhook") ?? "" {
        didSet { UserDefaults.standard.set(slackWebhook, forKey: "slackWebhook") }
    }
    /// Slack user token (xoxp-…) that sends DMs as me; kept in the Keychain. Wins over the webhook.
    var slackToken = Keychain.load(account: "slackUserToken").flatMap { String(data: $0, encoding: .utf8) } ?? "" {
        didSet {
            if slackToken.isEmpty { Keychain.delete(account: "slackUserToken") }
            else { Keychain.save(Data(slackToken.utf8), account: "slackUserToken") }
        }
    }
    /// The Slack workspace ID (T…), for opening DMs without a webhook.
    var slackTeam = UserDefaults.standard.string(forKey: "slackTeam") ?? "" {
        didSet { UserDefaults.standard.set(slackTeam, forKey: "slackTeam") }
    }
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
            myPullRequests = []
            myComments = [:]
            lastUpdated = nil
            reminders = Self.loadReminders(repo: repo)
            rescheduleReminders()
            loadRepoSettings()
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
    /// My PRs that were approved at least once, persisted per repo like
    /// `knownIDs`, so each first approval is announced once.
    var approvedIDs: Set<Int>? {
        get { repo.flatMap { UserDefaults.standard.array(forKey: "approvedIDs.\($0)") as? [Int] }.map(Set.init) }
        set { if let repo { UserDefaults.standard.set(newValue.map(Array.init), forKey: "approvedIDs.\(repo)") } }
    }
    private(set) var userUUID: String?
    private var pollTask: Task<Void, Never>?
    var nagTask: Task<Void, Never>?

    private var credentials: Credentials? = Credentials.load()
    /// Shared so concurrent callers don't spend the same rotating refresh token twice.
    private var tokenRefresh: Task<OAuthTokens, Error>?

    var isSignedIn: Bool { credentials != nil && status != .signedOut }

    init() {
        status = credentials == nil ? .signedOut : .ok
        reminders = Self.loadReminders(repo: repo)
        rescheduleReminders()
        loadRepoSettings()
    }

    private func loadRepoSettings() {
        let defaults = UserDefaults.standard
        nags = Self.loadNags(repo: repo)
        mergers = Self.loadMergers(repo: repo)
        askToMerge = repo.map { defaults.bool(forKey: "askToMerge.\($0)") } ?? false
        let asked = repo.flatMap { defaults.dictionary(forKey: "mergeAsked.\($0)") as? [String: String] } ?? [:]
        mergeAsked = Dictionary(uniqueKeysWithValues: asked.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    private func saveRepoSetting(_ value: Any?, _ key: String) {
        if let repo { UserDefaults.standard.set(value, forKey: "\(key).\(repo)") }
    }

    /// Checks once now, then keeps checking if automatic refresh is on.
    /// Called again whenever the refresh settings change.
    func start() {
        startNagging()
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
        rescheduleReminders()
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
        myPullRequests = []
        status = .signedOut
        rescheduleReminders()
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
            let mine = try await client.pullRequests(repo: repo, authorUUID: userUUID!)
            guard repo == self.repo else { return } // repo changed mid-request

            if let knownIDs {
                let new = prs.filter { !knownIDs.contains($0.id) }
                Notifier.notify(new)
            }
            knownIDs = Set(prs.map(\.id))
            await updateMyComments(prs, repo: repo, client: client)
            if userInitiated { try? await Task.sleep(until: started + .milliseconds(400)) }
            pullRequests = prs
            announceApprovals(mine)
            await announceMerges(mine, repo: repo, client: client)
            myPullRequests = mine
            pruneNags(mine)
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

    /// Notifies about my PRs that left the open list because they were merged
    /// (not declined). The first check of a repo only notes which are open; a
    /// PR whose state couldn't be fetched is tried again next check.
    private func announceMerges(_ mine: [PullRequest], repo: String, client: BitbucketClient) async {
        let key = "myOpenIDs.\(repo)"
        let open = Set(mine.map(\.id))
        let known = (UserDefaults.standard.array(forKey: key) as? [Int]).map(Set.init) ?? open
        var unresolved = Set<Int>()
        for id in known.subtracting(open).sorted() {
            do {
                let closed = try await client.pullRequestState(repo: repo, prID: id)
                if closed.state == "MERGED" { Notifier.announceMerge(title: closed.title, url: closed.url) }
            } catch BitbucketError.http(404, _) {
                // Deleted: nothing to announce.
            } catch {
                unresolved.insert(id)
            }
        }
        UserDefaults.standard.set(Array(open.union(unresolved)), forKey: key)
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
