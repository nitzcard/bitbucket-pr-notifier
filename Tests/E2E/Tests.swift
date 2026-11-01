import AppKit
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
        // Showing the error rebuilds the form, so find the field again.
        let tokenAgain = try waitFor("the token field") {
            settings.all(kAXTextFieldRole).first { $0.subrole == kAXSecureTextFieldSubrole }
        }
        try tokenAgain.type(MockBitbucket.token, pid: app.pid)
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

        /// Sets a nag every 2 hours on the first PR, through the Remind Me sheet.
        func nagEveryTwoHours() throws {
            try app.chooseFromStatusMenu("Remind Me…")
            let sheet = try waitFor("the Remind Me sheet") { main.children.first { $0.role == kAXSheetRole } }
            try app.waitForText("Pull Request:", in: sheet)
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
        }

        t.step("Remind Me… opens the reminder sheet, with nothing to cancel yet")
        try app.chooseFromStatusMenu("Remind Me…")
        let sheet = try waitFor("the Remind Me sheet") { main.children.first { $0.role == kAXSheetRole } }
        try expect(!(try app.button("Cancel Reminder", in: sheet)).isEnabled,
                   "Cancel Reminder should be dimmed when there's no reminder")
        try waitFor("the Cancel button") { sheet.all(kAXButtonRole).first { $0.label == "Cancel" } }.press()
        try waitUntil("the sheet to close") { main.children.allSatisfy { $0.role != kAXSheetRole } }

        t.step("Choose Every 2 hours and set the reminder")
        try nagEveryTwoHours()

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

        t.step("Commenting on the PR stops its nag")
        try nagEveryTwoHours()
        try app.waitForText("every 2 hr", in: main)
        guard let first = t.mock.pullRequests.firstIndex(where: { $0.id == 2 }) else { throw TestFailure("PR 2 is missing") }
        t.mock.pullRequests[first].myComments += 1
        try app.button("Refresh", in: main).press()
        try waitUntil("the nag to stop") { !main.shows("every 2 hr") }
    },

    TestCase(name: "nagMergersAndAskToMerge", setUp: { try $0.seedSlack() }) { t in
        let app = t.app
        let main = try app.mainWindow

        t.step("My pull requests list each reviewer's state")
        try app.waitForText("My Pull Requests", in: main)
        try app.waitForText("Cache build artifacts", in: main)
        try app.waitForText("Grace Hopper: Waiting · Alan Turing: Waiting", in: main)
        try expect(!main.all(kAXButtonRole).contains { $0.label.contains("Ask to Merge") },
                   "Ask to Merge… should appear only once the PR is approved")
        var items = try app.openStatusMenu()
        try expect(items.contains { $0.title == "Nag Mergers…" } && !items.contains { $0.title == "Ask to Merge…" },
                   "The menu should offer Nag Mergers… under the unapproved PR: \(items.map(\.title))")
        try app.closeStatusMenu()

        t.step("The PR's Nag Mergers… button messages the mergers who have a Slack member ID")
        try app.button("Nag Mergers…", in: main).press()
        let sheet = try waitFor("the Nag Mergers sheet") { main.children.first { $0.role == kAXSheetRole } }
        try app.waitForText("Linus Torvalds", in: sheet)
        try expect(!sheet.shows("Grace Hopper") && !sheet.shows("Alan Turing"),
                   "Only mergers with a member ID are listed, not the PR's reviewers")
        try app.button("Send", in: sheet).press()
        try waitUntil("the sheet to close") { main.children.allSatisfy { $0.role != kAXSheetRole } }
        try waitUntil("Linus to get a Slack message") {
            t.mock.slackMessages.contains { $0.userID == "ULINUS" && $0.message.contains("Cache build artifacts") }
        }
        try expect(t.mock.slackMessages.count == 1, "Only Linus has a member ID")

        t.step("Once approved, the PR's Ask to Merge… button messages the chosen merger")
        t.mock.myPullRequests[0].reviewers[0].approved = true
        try app.button("Refresh", in: main).press()
        try app.waitForText("Grace Hopper: Approved", in: main)
        try expect(!main.all(kAXButtonRole).contains { $0.label.contains("Nag Mergers") },
                   "Once approved, the row's button asks to merge instead of nagging")
        items = try app.openStatusMenu()
        try expect(items.contains { $0.title == "Ask to Merge…" } && !items.contains { $0.title == "Nag Mergers…" },
                   "The menu should offer Ask to Merge… under the approved PR: \(items.map(\.title))")
        try app.closeStatusMenu()
        try app.button("Ask to Merge…", in: main).press()
        let mergeSheet = try waitFor("the Ask to Merge sheet") { main.children.first { $0.role == kAXSheetRole } }
        try app.waitForText("Linus Torvalds", in: mergeSheet)
        try app.button("Send", in: mergeSheet).press()
        try waitUntil("Linus to be asked to merge") {
            t.mock.slackMessages.contains { $0.userID == "ULINUS" && $0.message.contains("Could you merge it?") }
        }
        try app.waitForText("Asked Linus Torvalds to merge", in: main)

        t.step("Settings → Slack fills in member IDs from an AI assistant's answer")
        try app.chooseFromStatusMenu("Settings…")
        let settings = try app.settingsWindow
        try waitFor("the Slack tab") { settings.all(kAXRadioButtonRole).first { $0.label == "Slack" } }.press()
        try app.waitForText("- Grace Hopper", in: settings)
        // The test uses the real clipboard; put back whatever was on it.
        let saved = NSPasteboard.general.string(forType: .string)
        defer { NSPasteboard.general.clearContents(); if let saved { NSPasteboard.general.setString(saved, forType: .string) } }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Here you go:\n- **Grace Hopper**: UGRACE01\n- Someone Else: UOTHER01", forType: .string)
        try app.button("Paste Member IDs", in: settings).press()
        try app.waitForText("Filled 1 member ID.", in: settings)
        try app.waitForText("Everyone above has a member ID.", in: settings)
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
