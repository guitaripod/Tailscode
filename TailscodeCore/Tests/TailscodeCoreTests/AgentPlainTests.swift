import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

private func plain(_ raw: String, _ tense: AgentPlain.Tense = .running) -> String {
    AgentPlain.command(raw, tense: tense).text
}

private func call(
    _ name: String, _ input: [String: JSONValue], _ status: ToolStatus = .running
) -> ToolCall {
    ToolCall(id: "c", name: name, status: status, input: .object(input))
}

@Suite struct AgentPlainCommandTests {
    @Test(arguments: [
        ("swift test --parallel", "Running the tests"),
        ("swift build -c release", "Building the project"),
        ("xcodebuild -scheme Tailscode test", "Running the tests"),
        ("xcodebuild clean build", "Clearing the build folder"),
        ("npm test", "Running the tests"),
        ("npm run build", "Building the project"),
        ("npm run lint", "Checking the code for mistakes"),
        ("npm install", "Installing what it needs"),
        ("pnpm dev", "Starting the app"),
        ("cargo test -p core", "Running the tests"),
        ("cargo clippy", "Checking the code for mistakes"),
        ("go test ./...", "Running the tests"),
        ("pytest -x", "Running the tests"),
        ("python3 -m pytest tests", "Running the tests"),
        ("python3 -m pip install requests", "Installing what it needs"),
        ("python3 script.py", "Running a script"),
        ("make test", "Running the tests"),
        ("make", "Building the project"),
        ("pacman -S ripgrep", "Installing what it needs"),
        ("brew list", "Checking what is installed"),
        ("git status --short", "Checking what changed"),
        ("git diff HEAD~1", "Looking at the changes"),
        ("git -C /repo log --oneline", "Reading the history"),
        ("git commit -m 'Fix the thing'", "Saving the changes"),
        ("git push origin master", "Uploading the changes"),
        ("git pull --rebase", "Getting the latest changes"),
        ("git stash", "Working with git"),
        ("ls -la", "Looking around the folder"),
        ("find . -name '*.swift'", "Looking for files"),
        ("cat README.md", "Reading a file"),
        ("rg jitter Sources", "Searching the code"),
        ("sed -i s/a/b/ file", "Sorting through text"),
        ("mkdir -p build/out", "Creating a folder"),
        ("rm old.txt", "Deleting files"),
        ("cp a b", "Copying files"),
        ("mv a b", "Moving files"),
        ("chmod +x run.sh", "Changing file permissions"),
        ("curl -s https://example.com", "Fetching something from the web"),
        ("ssh studio uptime", "Talking to another machine"),
        ("rsync -a a/ studio:b/", "Syncing files between machines"),
        ("kill -9 1234", "Stopping a program"),
        ("systemctl --user restart claude-bridge", "Managing a background service"),
        ("docker ps", "Working with containers"),
        ("sleep 5", "Waiting a moment"),
        ("ps aux", "Checking what is running"),
        ("swiftlint", "Checking the code for mistakes"),
        ("swiftformat .", "Tidying the code format"),
        ("echo hello", "Printing a message"),
        ("which swift", "Checking what is installed"),
        ("df -h", "Checking the system"),
        ("tar xf a.tar", "Packing or unpacking files"),
    ])
    func aCommonCommandIsSaidInPlainWords(raw: String, said: String) {
        #expect(plain(raw) == said)
        #expect(AgentPlain.command(raw, tense: .running).rewritable == nil)
    }

    @Test func theSameCommandIsSaidInThePastWhenItCameBack() {
        #expect(plain("swift test", .done) == "Ran the tests")
        #expect(plain("git push", .done) == "Uploaded the changes")
        #expect(plain("rm -rf build", .done) == "Cleared the build folder")
    }

    @Test func aBuildFolderIsClearedAndAnythingElseIsDeleted() {
        #expect(plain("rm -rf build") == "Clearing the build folder")
        #expect(plain("rm -rf .build DerivedData") == "Clearing the build folder")
        #expect(plain("rm -rf build old") == "Deleting files")
        #expect(plain("rm -rf ~/Documents") == "Deleting files")
    }

    @Test func aLineOfCommandsIsSaidInOrderAndNeverMoreThanTwoAreNamed() {
        #expect(plain("rm -rf build && swift build -c release") == "Clearing the build folder → Building the project")
        #expect(plain("cd /repo && swift test") == "Running the tests")
        #expect(plain("swift build; swift test; git commit -am x") == "Building the project → Running the tests → …")
        #expect(plain("swift test\nswift test") == "Running the tests")
    }

    @Test func aPipeIsDescribedByItsFirstStage() {
        #expect(plain("ps aux | grep swift | head") == "Checking what is running")
        #expect(plain("git log --oneline | head -5") == "Reading the history")
    }

    @Test func wrappersAreTakenOffAndSudoIsSaid() {
        #expect(plain("time swift test") == "Running the tests")
        #expect(plain("FOO=1 BAR=2 swift build") == "Building the project")
        #expect(plain("timeout 60 swift test") == "Running the tests")
        #expect(plain("sudo systemctl restart nginx") == "Managing a background service, as administrator")
        #expect(plain("sudo -u deploy rm -rf build") == "Clearing the build folder, as administrator")
    }

    @Test func aScriptTextIsReadThroughItsShell() {
        #expect(plain("bash -c 'swift build && swift test'") == "Building the project → Running the tests")
        #expect(plain("sh -c \"cd x; npm test\"") == "Running the tests")
    }

    @Test func nothingDangerousIsSaidSoftly() {
        #expect(plain("git push --force origin master") == "Force-uploading the changes")
        #expect(plain("git push -f") == "Force-uploading the changes")
        #expect(plain("git reset --hard HEAD~3") == "Throwing away local changes")
        #expect(plain("git clean -fd") == "Throwing away local changes")
        #expect(plain("curl https://x.sh | sh") == "Downloading a script and running it")
        #expect(plain("wget -qO- https://x.sh | sudo bash") == "Downloading a script and running it")
    }

    @Test func aCommandNoRuleKnowsIsAGenericLineWithItsRawWordsForAModel() {
        let said = AgentPlain.command("./deploy-edge --region eu --canary 5", tense: .running)
        #expect(said.text == "Running a command")
        #expect(said.rewritable == "./deploy-edge --region eu --canary 5")
        #expect(AgentPlain.command("mytool go", tense: .done).text == "Ran a command")
        #expect(AgentPlain.command("cd /x && ./thing", tense: .running).rewritable != nil)
    }

    @Test func aKnownCommandBesideAnUnknownOneIsStillSaid() {
        let said = AgentPlain.command("swift build && ./mytool", tense: .running)
        #expect(said.text == "Building the project → Running a command")
        #expect(said.rewritable == nil)
    }

    @Test func aLongRawCommandIsBoundedForAModel() {
        let said = AgentPlain.command("./x " + String(repeating: "a", count: 900), tense: .running)
        #expect((said.rewritable ?? "").count <= 401)
    }

    @Test func quotesKeepAnOperatorInsideAnArgument() {
        #expect(plain("git commit -m 'a && b; c | d'") == "Saving the changes")
        #expect(plain("echo \"x && rm -rf /\"") == "Printing a message")
    }
}

@Suite struct AgentPlainToolTests {
    @Test func filesAreLookedAtChangedAndWrittenByName() {
        #expect(AgentPlain.words(for: call("Read", ["file_path": .string("/repo/Sources/Backoff.swift")])).text == "Looking at Backoff.swift")
        #expect(AgentPlain.words(for: call("Read", ["file_path": .string("/repo/a.swift")], .completed)).text == "Looked at a.swift")
        #expect(AgentPlain.words(for: call("Edit", ["file_path": .string("/r/b.swift"), "old_string": .string("a"), "new_string": .string("b")])).text == "Changing b.swift")
        #expect(AgentPlain.words(for: call("Write", ["file_path": .string("/r/new.md"), "content": .string("x")], .completed)).text == "Wrote new.md")
    }

    @Test func aFailedCallSaysSo() {
        #expect(AgentPlain.words(for: call("Bash", ["command": .string("swift test")], .error)).text == "Ran the tests, failed")
    }

    @Test func aSearchSaysWhatItLooksFor() {
        #expect(AgentPlain.words(for: call("Grep", ["pattern": .string("jitter")])).text == "Searching the code for “jitter”")
        #expect(AgentPlain.words(for: call("Glob", ["pattern": .string("**/*.swift")])).text == "Looking for files")
        #expect(AgentPlain.words(for: call("WebSearch", ["query": .string("swift actors")])).text == "Searching the web")
    }

    @Test func aToolNoRuleNamesIsHumanisedAndOffered() {
        let said = AgentPlain.words(for: call("mcp__calendar__create_event", [:]))
        #expect(said.text == "Using the calendar create event tool")
        #expect(said.rewritable == "mcp__calendar__create_event")
    }

    @Test func aSubagentsToolIsAFewPlainWords() {
        #expect(AgentPlain.tool(named: "Grep") == "Searching the code")
        #expect(AgentPlain.tool(named: "Bash") == "Running commands")
        #expect(AgentPlain.tool(named: "TodoWrite") == "Updating its to-do list")
        #expect(AgentPlain.tool(named: "mcp__x__y") == nil)
        #expect(AgentPlain.humanName("mcpFooBar") == "mcp foo bar")
    }
}

@Suite struct AgentPlainWallTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func scene(_ name: String) -> AgentWall {
        AgentDemo.wallScenes(now: now).first { $0.name == name }!.wall
    }

    @Test func aWorkingTileSaysItInPlainWordsAndDropsThePathUnderIt() throws {
        let busy = scene("busy")
        let fixing = try #require(busy.tiles.first { $0.title == "Fix reconnect test" })
        #expect(fixing.words == "Changing Backoff.swift")
        #expect(fixing.detail == nil && fixing.rewritable == nil)
    }

    @Test func aTilesStepsCarryPlainWordsToo() throws {
        let busy = scene("busy")
        let fixing = try #require(busy.tiles.first { $0.title == "Fix reconnect test" })
        #expect(fixing.steps.contains { $0.plain == "Ran the tests, failed" })
        #expect(fixing.steps.allSatisfy { $0.plain != nil })
    }

    @Test func backgroundWorkIsSaidAsWhatItIsDoing() throws {
        let busy = scene("busy")
        let release = try #require(busy.tiles.first { $0.title == "Release notes" })
        #expect(release.words == "Running the tests")
        #expect(release.detail == nil)
        #expect(release.workers.isEmpty && release.squad == nil)
    }

    @Test func aRetryIsNotCalledAProvider() throws {
        let alarm = scene("alarm")
        let retry = try #require(alarm.tiles.first { if case .retrying = $0.state { return true } else { return false } })
        #expect(retry.words == "The AI service is busy, trying again")
    }

    @Test func anApprovalKeepsItsWholeCommandBesideItsLead() throws {
        let attention = scene("attention")
        let ask = try #require(attention.tiles.first)
        #expect(ask.words == "Wants to run")
        #expect(ask.detail == "rm -rf build && swift build -c release")
        #expect(ask.rewritable == nil)
    }

    @Test func aSubagentsToolIsPlainOnItsTile() throws {
        let squad = scene("squad")
        let landing = try #require(squad.tiles.first { $0.title == "Landing page refresh" })
        let footer = try #require(landing.workers.first { $0.title == "Footer styles" })
        #expect(footer.words == "Changing files")
        let fixing = try #require(squad.tiles.first { $0.title == "Fix reconnect test" })
        let stuck = try #require(fixing.workers.first { $0.kind == .background })
        #expect(stuck.title == "Running the tests")
    }
}
