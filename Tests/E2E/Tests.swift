import ApplicationServices

/// The app's main flows, end to end.
let allTests: [TestCase] = [
    TestCase(name: "firstLaunchSignInAndChooseRepository", signedIn: false) { t in
        let app = t.app
        t.step("A first launch shows Not Signed In and opens Settings")
        try app.waitForText("Not Signed In", in: try app.mainWindow)
        let settings = try app.settingsWindow
        let email = try waitFor("the email field") { settings.first(kAXTextFieldRole, matching: "you@company.com") }
        let token = try waitFor("the token field") {
            settings.all(kAXTextFieldRole).first { $0.subrole == kAXSecureTextFieldSubrole }
        }
        let signIn = try app.button("Sign In", in: settings)
        try expect(!signIn.isEnabled, "Sign In should be dimmed until both fields are filled")

        t.step("Signing in with a wrong token shows Bitbucket's error")
        try email.type(MockBitbucket.email, pid: app.pid)
        try token.type("wrong-token", pid: app.pid)
        try waitUntil("Sign In to be enabled") { signIn.isEnabled }
        try signIn.press()
        try app.waitForText("HTTP 401", in: settings)

        t.step("Signing in with the right token shows the account")
        try token.type(MockBitbucket.token, pid: app.pid)
        try app.button("Sign In", in: settings).press()
        try app.waitForText(MockBitbucket.displayName, in: settings)
        try app.waitForText("No Repository Chosen", in: try app.mainWindow)

        t.step("Choosing a repository lists its pull requests")
        try app.button("acme/web", in: settings).press()
        let main = try app.mainWindow
        try app.waitForText("Add dark mode to the dashboard", in: main)
        try app.waitForText("Fix login redirect loop", in: main)
        try app.waitForText("Grace Hopper · 2 comments · Approved", in: main)
        try app.waitForText("acme/web", in: main)
        try waitUntil("the menu bar to show 2 PRs") { try app.statusItem.title.contains("2") }
    },

    TestCase(name: "menuBarMenuListsPullRequests") { t in
        let app = t.app
        try app.waitForText("Fix login redirect loop", in: try app.mainWindow)
        try waitUntil("the menu bar to show 2 PRs") { try app.statusItem.title.contains("2") }

        t.step("The menu lists each PR with its details, and the list commands")
        let items = try app.openStatusMenu()
        let titles = items.map(\.title)
        try expect(titles.contains { $0.contains("Add dark mode to the dashboard") && $0.contains("2 comments · Approved") },
                   "Menu lacks the reviewed PR with its details: \(titles)")
        try expect(titles.contains { $0.contains("Fix login redirect loop") && $0.contains("Alan Turing") },
                   "Menu lacks the unreviewed PR: \(titles)")
        try expect(titles.contains("acme/web"), "Menu lacks the repository header: \(titles)")
        for command in ["Open Unreviewed Pull Requests", "Remind Me…", "Open PR List", "Settings…", "Check for Updates…", "Quit"] {
            guard let item = items.first(where: { $0.title == command }) else {
                throw TestFailure("Menu lacks \"\(command)\": \(titles)")
            }
            try expect(item.isEnabled, "\"\(command)\" is dimmed")
        }
        try app.closeStatusMenu()

        t.step("Open PR List brings the window back after it's closed")
        let main = try app.mainWindow
        try (main.attribute(kAXCloseButtonAttribute) as! AXUIElement?).map(Element.init)?.press()
        try waitUntil("the main window to close") { app.window(AppUnderTest.mainTitle) == nil }
        try app.chooseFromStatusMenu("Open PR List")
        try app.waitForText("Fix login redirect loop", in: try app.mainWindow)
    },

    TestCase(name: "newPullRequestAppearsOnRefresh") { t in
        let app = t.app
        let main = try app.mainWindow
        try app.waitForText("Fix login redirect loop", in: main)

        t.step("A PR assigned on Bitbucket appears after Refresh")
        t.mock.pullRequests.insert(.init(id: 3, title: "Speed up the build cache", author: "Margaret Hamilton"), at: 0)
        try app.button("Refresh", in: main).press()
        try app.waitForText("Speed up the build cache", in: main)
        try app.waitForText("Margaret Hamilton", in: main)
        try waitUntil("the menu bar to show 3 PRs") { try app.statusItem.title.contains("3") }

        t.step("A merged PR disappears after Refresh")
        t.mock.pullRequests.removeAll { $0.id == 1 }
        try app.button("Refresh", in: main).press()
        try waitUntil("the merged PR to go") { !main.shows("Fix login redirect loop") }
        try waitUntil("the menu bar to show 2 PRs") { try app.statusItem.title.contains("2") }
    },

    TestCase(name: "setAndCancelReminder") { t in
        let app = t.app
        let main = try app.mainWindow
        try app.waitForText("Fix login redirect loop", in: main)

        t.step("Remind Me… opens the reminder sheet")
        try app.chooseFromStatusMenu("Remind Me…")
        let sheet = try waitFor("the Remind Me sheet") { main.children.first { $0.role == kAXSheetRole } }
        try app.waitForText("Pull Request:", in: sheet)
        let cancelReminder = try app.button("Cancel Reminder", in: sheet)
        try expect(!cancelReminder.isEnabled, "Cancel Reminder should be dimmed when there's no reminder")

        t.step("Choose Every 2 hours and set the reminder")
        // The dimmed row has its own copy of the radio button; whichever is live takes the press.
        let radios = try waitFor("the Every radio button") {
            let found = sheet.all(kAXRadioButtonRole).filter { $0.label.contains("Every") && $0.isEnabled }
            return found.isEmpty ? nil : found
        }
        for radio in radios { try radio.press() }
        let stepper = try waitFor("the interval stepper to be enabled") {
            sheet.all(kAXIncrementorRole).first { $0.isEnabled }
        }
        try stepper.perform(kAXIncrementAction)
        try waitUntil("the interval to read 2") { sheet.all(kAXTextFieldRole).contains { $0.value == "2" } }
        try app.button("Set Reminder", in: sheet).press()
        try waitUntil("the sheet to close") { main.children.allSatisfy { $0.role != kAXSheetRole } }

        t.step("The PR shows its reminder in the window and the menu")
        try app.waitForText("every 2 hr", in: main)
        let items = try app.openStatusMenu()
        try expect(items.contains { $0.title.contains("Nag every 2 hr") },
                   "Menu doesn't show the reminder: \(items.map(\.title))")
        try app.closeStatusMenu()

        t.step("Cancel Reminder removes it")
        try app.button("every 2 hr", in: main).press()
        let editSheet = try waitFor("the Remind Me sheet") { main.children.first { $0.role == kAXSheetRole } }
        let cancel = try app.button("Cancel Reminder", in: editSheet)
        try expect(cancel.isEnabled, "Cancel Reminder should be enabled for a PR with a reminder")
        try cancel.press()
        try waitUntil("the reminder to go") { !main.shows("every 2 hr") }
    },

    TestCase(name: "signOutAndExpiredToken") { t in
        let app = t.app
        let main = try app.mainWindow
        try app.waitForText("Fix login redirect loop", in: main)

        t.step("An expired token signs the app out on the next refresh")
        t.mock.rejectsTokens = true
        try app.button("Refresh", in: main).press()
        try app.waitForText("Not Signed In", in: main)
        try app.button("Sign In…", in: main).press()
        let settings = try app.settingsWindow
        try app.waitForText(MockBitbucket.email, in: settings)

        t.step("Signing in again restores the list")
        t.mock.rejectsTokens = false
        let token = try waitFor("the token field") {
            settings.all(kAXTextFieldRole).first { $0.subrole == kAXSecureTextFieldSubrole }
        }
        try token.type(MockBitbucket.token, pid: app.pid)
        try app.button("Sign In", in: settings).press()
        try app.waitForText("Fix login redirect loop", in: main)

        t.step("Sign Out empties the list")
        try app.button("Sign Out", in: settings).press()
        try app.waitForText("Not Signed In", in: main)
        try waitUntil("the menu bar count to clear") { try !app.statusItem.title.contains("2") }
    },

    TestCase(name: "checkForUpdates") { t in
        let app = t.app
        try app.waitForText("Fix login redirect loop", in: try app.mainWindow)

        t.step("Check for Updates… reports the newer release")
        try app.chooseFromStatusMenu("Check for Updates…")
        let alert = try waitFor("the update alert") {
            app.ax.windows.first { $0.shows("Version \(MockBitbucket.latestVersion) is available.") }
        }
        try app.waitForText("You have version", in: alert)
        try app.button("Later", in: alert).press()
        try waitUntil("the alert to close") { !app.ax.windows.contains { $0.shows("is available.") } }

        t.step("The menu offers Download Update")
        let items = try app.openStatusMenu()
        try expect(items.contains { $0.title == "Download Update" }, "No Download Update item: \(items.map(\.title))")
        try app.closeStatusMenu()
    },
]
