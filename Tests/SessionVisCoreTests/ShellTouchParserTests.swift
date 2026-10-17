import Foundation
import Testing
@testable import SessionVisCore

@Suite struct ShellTouchParserTests {
    let cwd = "/repo"
    func t(_ command: String) -> [ShellTouch] { ShellTouchParser.touches(in: command, cwd: cwd) }
    func read(_ p: String, _ verb: String, scope: TouchScope = .file) -> ShellTouch { ShellTouch(path: p, kind: .read, scope: scope, verb: verb) }
    func write(_ p: String, _ verb: String, scope: TouchScope = .file) -> ShellTouch { ShellTouch(path: p, kind: .write, scope: scope, verb: verb) }

    @Test func readVerbsResolveAgainstCwd() {
        #expect(t("cat Sources/A.swift") == [read("/repo/Sources/A.swift", "cat")])
        #expect(t("head -n 20 README.md") == [read("/repo/README.md", "head")])
        #expect(t("tail -5 a.log b.log") == [read("/repo/a.log", "tail"), read("/repo/b.log", "tail")])
        #expect(t("wc -l /abs/x.txt") == [read("/abs/x.txt", "wc")])
        #expect(t("stat Package.swift") == [read("/repo/Package.swift", "stat")])
    }

    @Test func cdTracksAcrossChains() {
        #expect(t("cd /repo/Sources && sed -n 1,80p A.swift") == [read("/repo/Sources/A.swift", "sed")])
        #expect(t("cd Tests; cat X.swift && cd .. && cat Y.swift") == [read("/repo/Tests/X.swift", "cat"), read("/repo/Y.swift", "cat")])
        #expect(t("cd /elsewhere && cat a.txt") == [read("/elsewhere/a.txt", "cat")])
        #expect(t("cd && cat a.txt") == [read("/repo/a.txt", "cat")])
    }

    @Test func pipesAndOrChains() {
        #expect(t("cat a.swift b.swift | grep foo") == [read("/repo/a.swift", "cat"), read("/repo/b.swift", "cat")])
        #expect(t("ls Sources || cat fallback.txt") == [read("/repo/Sources", "ls", scope: .directory), read("/repo/fallback.txt", "cat")])
        #expect(t("cat a.txt\ncat b.txt") == [read("/repo/a.txt", "cat"), read("/repo/b.txt", "cat")])
    }

    @Test func sedAndAwkDistinguishScriptsFromFiles() {
        #expect(t("sed -n '1,10p' A.swift B.swift") == [read("/repo/A.swift", "sed"), read("/repo/B.swift", "sed")])
        #expect(t("sed -i '' 's/a/b/' README.md") == [write("/repo/README.md", "sed")])
        #expect(t("sed -i 's/a/b/' README.md") == [write("/repo/README.md", "sed")])
        #expect(t("sed --in-place 's/a/b/' README.md") == [write("/repo/README.md", "sed")])
        #expect(t("sed -e 's/a/b/' -e 's/c/d/' x.txt") == [read("/repo/x.txt", "sed")])
        #expect(t("awk '{print $1}' data.csv") == [read("/repo/data.csv", "awk")])
        #expect(t("awk -F, -f prog.awk data.csv") == [read("/repo/data.csv", "awk")])
    }

    @Test func grepFamily() {
        #expect(t("grep -rn \"needle\" Sources Tests") == [read("/repo/Sources", "grep", scope: .directory), read("/repo/Tests", "grep", scope: .directory)])
        #expect(t("grep foo A.swift") == [read("/repo/A.swift", "grep")])
        #expect(t("grep -e foo -A 3 A.swift") == [read("/repo/A.swift", "grep")])
        #expect(t("rg --type swift pattern Sources") == [read("/repo/Sources", "rg", scope: .directory)])
        #expect(t("rg pattern") == [])
        #expect(t("egrep -i x a.txt") == [read("/repo/a.txt", "egrep")])
    }

    @Test func directoryVerbs() {
        #expect(t("ls -la Sources/Tree") == [read("/repo/Sources/Tree", "ls", scope: .directory)])
        #expect(t("ls") == [read("/repo", "ls", scope: .directory)])
        #expect(t("find Tests -name '*.swift'") == [read("/repo/Tests", "find", scope: .directory)])
        #expect(t("find . -type f") == [read("/repo", "find", scope: .directory)])
        #expect(t("tree docs") == [read("/repo/docs", "tree", scope: .directory)])
    }

    @Test func writesCopiesAndMoves() {
        #expect(t("cp src.swift dst.swift") == [read("/repo/src.swift", "cp"), write("/repo/dst.swift", "cp")])
        #expect(t("cp src.swift dst/") == [read("/repo/src.swift", "cp"), write("/repo/dst", "cp", scope: .directory)])
        #expect(t("cp -r a b") == [read("/repo/a", "cp"), write("/repo/b", "cp", scope: .directory)])
        #expect(t("mv old.swift new.swift") == [write("/repo/new.swift", "mv")])
        #expect(t("tee -a log.txt") == [write("/repo/log.txt", "tee")])
        #expect(t("touch Sources/New.swift") == [write("/repo/Sources/New.swift", "touch")])
        #expect(t("diff a.txt b.txt") == [read("/repo/a.txt", "diff"), read("/repo/b.txt", "diff")])
    }

    @Test func redirections() {
        #expect(t("echo hi > out.txt") == [write("/repo/out.txt", ">")])
        #expect(t("echo hi >> out.txt") == [write("/repo/out.txt", ">")])
        #expect(t("swift build &> build.log") == [write("/repo/build.log", ">")])
        #expect(t("sort < in.txt > out.txt") == [read("/repo/in.txt", "<"), write("/repo/out.txt", ">")])
        #expect(t("swift build 2> err.log") == [])
        #expect(t("swift test 2>&1 | tail -3") == [])
        #expect(t("cat a.txt > b.txt") == [read("/repo/a.txt", "cat"), write("/repo/b.txt", ">")])
    }

    @Test func heredocBodiesAreNotParsed() {
        let cmd = "cat > out.txt <<'EOF'\ncat Sources/A.swift\nsed -i x y.swift\nEOF\ncat after.txt"
        #expect(t(cmd) == [write("/repo/out.txt", ">"), read("/repo/after.txt", "cat")])
        #expect(t("python3 - <<EOF\nopen('x.txt','w')\nEOF") == [])
        #expect(t("cat <<-END > f.txt\n\tline\n\tEND") == [write("/repo/f.txt", ">")])
    }

    @Test func quotingAndEscapes() {
        #expect(t("cat \"my file.swift\"") == [read("/repo/my file.swift", "cat")])
        #expect(t("cat 'single quoted.txt'") == [read("/repo/single quoted.txt", "cat")])
        #expect(t("cat my\\ file.swift") == [read("/repo/my file.swift", "cat")])
        #expect(t("echo \"a && b\" > out.txt") == [write("/repo/out.txt", ">")])
        #expect(t("grep 'x | y' a.txt") == [read("/repo/a.txt", "grep")])
    }

    @Test func skippedOperands() {
        #expect(t("cat *.swift") == [])
        #expect(t("cat $HOME/x.txt") == [])
        #expect(t("cat ~/x.txt") == [])
        #expect(t("cat -") == [])
        #expect(t("cat /dev/null") == [])
        #expect(t("cat a.txt 'b?.txt'") == [read("/repo/a.txt", "cat")])
    }

    @Test func prefixesAndNoTouchVerbs() {
        #expect(t("FOO=1 cat a.txt") == [read("/repo/a.txt", "cat")])
        #expect(t("sudo cat a.txt") == [read("/repo/a.txt", "cat")])
        #expect(t("/bin/cat a.txt") == [read("/repo/a.txt", "cat")])
        #expect(t("swift test --filter X") == [])
        #expect(t("git add Sources/A.swift && git commit -m x") == [])
        #expect(t("rm -rf build && mkdir out && chmod +x run.sh") == [])
        #expect(t("python3 script.py data.csv") == [])
        #expect(t("") == [])
    }

    @Test func operandCapAndOrder() {
        let names = (1...9).map { "f\($0).txt" }.joined(separator: " ")
        let out = t("cat \(names)")
        #expect(out.count == Constants.shellOperandLimit)
        #expect(out.first?.path == "/repo/f1.txt" && out.last?.path == "/repo/f8.txt")
    }

    @Test func normalisesDotSegments() {
        #expect(t("cat ./Sources/../README.md") == [read("/repo/README.md", "cat")])
        #expect(t("cd Sources/Tree && cat ../Sim/Simulation.swift") == [read("/repo/Sources/Sim/Simulation.swift", "cat")])
    }

    @Test func malformedInputYieldsNothing() {
        for cmd in ["cat 'unterminated", "cat \"unterminated", "cat trailing\\", "cat <<", "cat <<-", "cat >", "2>", "&", "|",
                    "cat <<EOF\nbody never ends", "\n\n;;", "(", ")", "((", "))", "$(", "`", "cat $(unclosed a.txt", "cat `unclosed",
                    "{", "}", "<(", "#", "cat (", "diff <(git show"] {
            #expect(t(cmd) == [], "\(cmd.debugDescription)")
        }
    }

    @Test func subshellsScopeTheirCd() {
        #expect(t("(cd Sources && cat A.swift)") == [read("/repo/Sources/A.swift", "cat")])
        #expect(t("(cd Sources && cat A.swift) && cat B.swift") == [read("/repo/Sources/A.swift", "cat"), read("/repo/B.swift", "cat")])
        #expect(t("(cat a.txt; cat b.txt)") == [read("/repo/a.txt", "cat"), read("/repo/b.txt", "cat")])
    }

    @Test func processSubstitutionsAreSeparateCommands() {
        #expect(t("diff <(git show HEAD:a) b") == [read("/repo/b", "diff")])
        #expect(t("comm -12 <(sort a.txt) <(sort b.txt)") == [])
        #expect(t("diff <(cat a.txt) b.txt") == [read("/repo/a.txt", "cat"), read("/repo/b.txt", "diff")])
    }

    @Test func commandSubstitutionsAreOpaque() {
        #expect(t("grep -l foo $(git ls-files)") == [])
        #expect(t("echo \"$(git ls-files)\" > list.txt") == [write("/repo/list.txt", ">")])
        #expect(t("cat `git ls-files`") == [])
        #expect(t("echo \"x `cat a.txt` y\"") == [])
        #expect(t("echo $((1 + 2)) > n.txt") == [write("/repo/n.txt", ">")])
    }

    @Test func commentsAreSkipped() {
        #expect(t("# comment > out.txt") == [])
        #expect(t("# write result > out.txt\nswift build") == [])
        #expect(t("# don't do this\nsed -n '1,5p' a.swift\necho 'x > y'") == [read("/repo/a.swift", "sed")])
        #expect(t("cat a#b.txt") == [read("/repo/a#b.txt", "cat")])
    }

    @Test func arithmeticYieldsNothing() {
        #expect(t("(( n > 3 ))") == [])
        #expect(t("(( n > 3 )) && cat a.txt") == [read("/repo/a.txt", "cat")])
    }

    @Test func commitHeredocInSubstitutionIsOpaque() {
        #expect(t("git commit -m \"$(cat <<'EOF'\nmsg with -> and 'quotes'\nEOF\n)\"") == [])
        #expect(t("git commit -m \"$(cat <<'EOF'\nMap \"a -> b\" in parser, don't\nEOF\n)\" && cat a.txt") == [read("/repo/a.txt", "cat")])
    }

    @Test func bracesAreSkippedOrSeparate() {
        #expect(t("cat {A,B}.swift") == [])
        #expect(t("wc -l Tests/UI/{A,B,C}.swift") == [])
        #expect(t("{ cat a.txt; cat b.txt; } > out.txt") == [read("/repo/a.txt", "cat"), read("/repo/b.txt", "cat")])
    }

    @Test func operandsWithLeftoverMetacharactersAreRejected() {
        #expect(ShellTouchParser.resolve("a)", in: "/repo") == nil)
        #expect(ShellTouchParser.resolve("(git", in: "/repo") == nil)
        #expect(ShellTouchParser.resolve("{a", in: "/repo") == nil)
        #expect(ShellTouchParser.resolve("b}", in: "/repo") == nil)
        #expect(ShellTouchParser.resolve("a\nb", in: "/repo") == nil)
        #expect(ShellTouchParser.resolve("a\tb", in: "/repo") == nil)
        #expect(ShellTouchParser.resolve("ok.txt", in: "/repo") == "/repo/ok.txt")
    }

    @Test func cdSkipsFlags() {
        #expect(t("cd -P /x && cat a.txt") == [read("/x/a.txt", "cat")])
        #expect(t("cd -L Sources && cat a.txt") == [read("/repo/Sources/a.txt", "cat")])
        #expect(t("cd -- Sources && cat a.txt") == [read("/repo/Sources/a.txt", "cat")])
        #expect(t("cd - && cat a.txt") == [])
    }

    @Test func numericFlagArgumentsAreNotOperands() {
        #expect(t("truncate -s 0 f.txt") == [write("/repo/f.txt", "truncate")])
        #expect(t("tree -L 2 docs") == [read("/repo/docs", "tree", scope: .directory)])
        #expect(t("du -d 1 Sources") == [read("/repo/Sources", "du", scope: .directory)])
    }

    @Test func unresolvableCdMakesRelativeOperandsUnknown() {
        #expect(t("cd ~/other && cat a.txt") == [])
        #expect(t("cd $DIR && cat a.txt && cat /abs/b.txt") == [read("/abs/b.txt", "cat")])
        #expect(t("cd ~/x && cd /repo && cat a.txt") == [read("/repo/a.txt", "cat")])
        #expect(t("cd ~/x && cd && cat a.txt") == [read("/repo/a.txt", "cat")])
    }

    @Test func redirectAndSeparatorForms() {
        #expect(t("cat x.txt 1>out.txt") == [read("/repo/x.txt", "cat"), write("/repo/out.txt", ">")])
        #expect(t("cat x.txt 1>>out.txt") == [read("/repo/x.txt", "cat"), write("/repo/out.txt", ">")])
        #expect(t("echo x >&2") == [])
        #expect(t("cat a.txt & cat b.txt") == [read("/repo/a.txt", "cat"), read("/repo/b.txt", "cat")])
        #expect(t("swift run &") == [])
        #expect(t("grep foo <<< \"bar\"") == [])
        #expect(t("echo a2>b.txt") == [write("/repo/b.txt", ">")])
    }
}
