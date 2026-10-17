import Foundation
import Testing
@testable import SessionVisCore

@Suite struct CommandClassifierTests {
    @Test func stripsLeadingCdAndEnvironment() {
        #expect(CommandClassifier.strip("cd /repo && swift test") == "swift test")
        #expect(CommandClassifier.strip("cd a && cd b && FOO=1 BAR=x make") == "make")
        #expect(CommandClassifier.strip("  cd /x; git status") == "git status")
        #expect(CommandClassifier.strip("echo hi && cd /x") == "echo hi && cd /x")       // only leading cd segments go
        #expect(CommandClassifier.strip("cd /only") == "")
    }

    @Test func classifiesByLeadingVerb() {
        let table: [(String, CommandClass)] = [
            ("git commit -m 'x'", .git(.commit)),
            ("cd /repo && git commit --amend", .git(.commit)),
            ("git -C /repo commit -m x", .git(.commit)),
            ("git -c user.name=t push origin main", .git(.push)),
            ("git push", .git(.push)),
            ("git merge feature-x", .git(.merge)),
            ("git rebase -i main", .git(.rebase)),
            ("git status", .git(.other)),
            ("git", .git(.other)),
            ("swift build", .build),
            ("swift test --filter X", .test),
            ("swift run SessionVis --dir /x", .run),
            ("xcodebuild -scheme A test", .test),
            ("xcodebuild -scheme A", .build),
            ("make", .build),
            ("make test", .test),
            ("npm test", .test),
            ("npm run build", .build),
            ("npm run lint", .run),
            ("npm start", .run),
            ("yarn build", .build),
            ("pnpm test", .test),
            ("pytest tests/", .test),
            ("cargo build --release", .build),
            ("cargo test", .test),
            ("go run ./cmd", .run),
            ("./scripts/bundle-app.sh", .run),
            ("ls -la", .other),
            ("", .other),
        ]
        for (command, expected) in table {
            #expect(CommandClassifier.classify(command) == expected, "\(command)")
        }
    }

    @Test func classifiesAcrossSegments() {
        #expect(CommandClassifier.classify("cd /x; swift build && echo ok") == .build)
        #expect(CommandClassifier.classify("cd /x\ngit commit -m x") == .git(.commit))
        #expect(CommandClassifier.classify("git add -A && git commit -m x") == .git(.commit))
        #expect(CommandClassifier.label(command: "git add -A && git commit -m x", description: nil) == "git commit")
        #expect(CommandClassifier.classify("swift build && swift test") == .build)
        #expect(CommandClassifier.classify("echo hi && git push") == .git(.push))
        #expect(CommandClassifier.classify("git --no-pager commit -m x") == .git(.commit))
        #expect(CommandClassifier.classify("cd /x; git commit -m 'a && b'") == .git(.commit))
    }

    @Test func labelPrefersDescriptionThenFirstTwoWords() {
        #expect(CommandClassifier.label(command: "swift test --filter X", description: "Run the store tests") == "Run the store tests")
        #expect(CommandClassifier.label(command: "swift test --filter X", description: "   ") == "swift test")
        #expect(CommandClassifier.label(command: "cd /repo && git commit -m x", description: nil) == "git commit")
        #expect(CommandClassifier.label(command: "ls", description: nil) == "ls")
        let long = String(repeating: "a", count: 60) + " b"
        #expect(CommandClassifier.label(command: long, description: nil).count == 40)
    }

    @Test func parsesCommitLines() {
        #expect(CommandClassifier.parseCommit("[main a1b2c3d] Add thing\n 2 files changed") == CommitInfo(hash: "a1b2c3d", branch: "main", message: "Add thing"))
        #expect(CommandClassifier.parseCommit("[feature/x (root-commit) 0123abc] First") == CommitInfo(hash: "0123abc", branch: "feature/x", message: "First"))
        #expect(CommandClassifier.parseCommit("[detached HEAD 9f8e7d6] Fix") == CommitInfo(hash: "9f8e7d6", branch: "detached HEAD", message: "Fix"))
        #expect(CommandClassifier.parseCommit("warning: x\n[main deadbeefcafe] Long hash ok") == CommitInfo(hash: "deadbeefcafe", branch: "main", message: "Long hash ok"))
        #expect(CommandClassifier.parseCommit("nothing to commit, working tree clean") == nil)
        #expect(CommandClassifier.parseCommit("") == nil)
    }

    @Test func milestonesAndLines() {
        #expect(CommandClass.git(.commit).milestone == .commit(nil))
        #expect(CommandClass.git(.push).milestone == .push)
        #expect(CommandClass.git(.other).milestone == nil && CommandClass.test.milestone == nil)
        #expect(Milestone.commit(CommitInfo(hash: "a1b2c3d4e5", branch: "main", message: "Msg")).line == "committed a1b2c3d · Msg")
        #expect(Milestone.commit(nil).line == "committed")
        #expect(Milestone.push.line == "pushed" && Milestone.merge.line == "merged" && Milestone.rebase.line == "rebased")
    }

    @Test func milestoneSegmentsListsEveryGitMilestoneInOrder() {
        #expect(CommandClassifier.milestoneSegments("git add -A && git commit -m x && git push") == ["git commit -m x", "git push"])
        #expect(CommandClassifier.milestoneSegments("swift test") == [])
        #expect(CommandClassifier.milestoneSegments("cd /x; git commit -m y") == ["git commit -m y"])
    }
}
