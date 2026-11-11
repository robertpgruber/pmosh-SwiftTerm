import Foundation
import Testing
@testable import SwiftTerm

// pmosh fork (11/03/2026): the pieces of PmoshHistorySeam.swift that need no recording. The
// recorded rewinds (Claude Code 2.1.260 and 2.1.312 in tmux) are replayed in pmosh's own tests.
struct PmoshHistorySeamTests {
    private let esc = "\u{1b}"

    /// Claude Code's classic renderer clears the view for a full repaint as CUP home, EL 2 + CUD 1
    /// on every row, CUP home. Only that, on the main screen, counts.
    @Test func viewportClearIsCountedOncePerErase() {
        let (t, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 4, scrollback: 100)
        t.feed(text: "a\r\nb\r\nc\r\nd")
        let erase = esc + "[H" + String(repeating: esc + "[2K" + esc + "[1B", count: 4) + esc + "[H"
        t.feed(text: erase)
        #expect(t.pmoshViewportClears == 1)
        // a row short is not a full erase
        t.feed(text: esc + "[H" + String(repeating: esc + "[2K" + esc + "[1B", count: 3) + esc + "[H")
        #expect(t.pmoshViewportClears == 1)
        // text in between breaks the run
        t.feed(text: esc + "[H" + esc + "[2K" + esc + "[1Bx" + String(repeating: esc + "[2K" + esc + "[1B", count: 3) + esc + "[H")
        #expect(t.pmoshViewportClears == 1)
        // split anywhere, it still counts
        for b in Array(erase.utf8) { t.feed(byteArray: [b]) }
        #expect(t.pmoshViewportClears == 2)
        // the alternate screen never counts
        t.feed(text: esc + "[?1049h" + erase)
        #expect(t.pmoshViewportClears == 2)
    }

    /// A cut drops history from a row to the end of history; a parked viewport keeps its rows,
    /// and the list grows again without handing a line out twice.
    @Test func cutKeepsAParkedViewportOnItsRows() {
        let (t, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 4, scrollback: 100)
        for i in 0..<20 { t.feed(text: "l\(i)\r\n") }
        let b = t.buffer
        #expect(b.yBase == 17)
        b.yDisp = 5
        #expect(t.pmoshCutHistory(from: 10) == 7)
        #expect(b.yBase == 10 && b.yDisp == 5)
        #expect(t.pmoshRowText(b.lines[9]) == "l9" && t.pmoshRowText(b.lines[10]) == "l17")
        b.yDisp = 9
        #expect(t.pmoshCutHistory(from: 8) == 2)
        #expect(b.yDisp == 8)
        for i in 0..<30 { t.feed(text: "m\(i)\r\n") }
        var ids = Set<ObjectIdentifier>()
        for i in 0..<b.lines.count { ids.insert(ObjectIdentifier(b.lines[i])) }
        #expect(ids.count == b.lines.count)
    }

    /// The repaint's seam: history repeats the repainted rows above the frame, then rows the new
    /// screen dropped follow. Made-up text, the renderer's moves.
    @Test func repaintSeamFindsTheRepeat() {
        let (t, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 6, scrollback: 100)
        let old = (1...12).map { "row \($0)" } + ["dropped a", "dropped b", "dropped c"]
        t.feed(text: old.joined(separator: "\r\n") + "\r\n")
        // erase the view, paint rows 7...10 again and a frame under them
        let erase = esc + "[H" + String(repeating: esc + "[2K" + esc + "[1B", count: 6) + esc + "[H"
        t.feed(text: erase + ["row 7", "row 8", "row 9", "row 10", "", "> input"].joined(separator: "\r\n"))
        #expect(t.pmoshViewportClears == 1)
        let p = t.pmoshRepaintSeam(frameTop: 5)
        #expect(p.map { t.pmoshRowText(t.buffer.lines[$0]) } == "row 7")
        t.pmoshCutHistory(from: p!)
        let rows = t.pmoshAllRowText().filter { !$0.isEmpty }
        #expect(rows == (1...10).map { "row \($0)" } + ["> input"])
        // nothing repeats: no seam
        let (u, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 6, scrollback: 100)
        u.feed(text: (1...12).map { "row \($0)" }.joined(separator: "\r\n") + "\r\n")
        u.feed(text: erase + ["other 1", "other 2", "other 3", "other 4", "", "> input"].joined(separator: "\r\n"))
        #expect(u.pmoshRepaintSeam(frameTop: 5) == nil)
    }

    /// Rows read as the start of a message: the prompt marks Claude Code draws taken off,
    /// 2.1.312's "❯" + no-break space included, and a message longer than a row.
    @Test func messageRows() {
        #expect(Terminal.pmoshRowStartsMessage("❯\u{a0}fix the bug", "fix the bug"))
        #expect(Terminal.pmoshRowStartsMessage("> fix the bug", "fix the bug"))
        #expect(Terminal.pmoshRowStartsMessage("fix the bug", "fix the bug"))
        #expect(!Terminal.pmoshRowStartsMessage("fix the bugs", "fix the bug"))
        #expect(Terminal.pmoshRowStartsMessage("please look at section nine again", "please look at section nine again and tell me"))
        #expect(!Terminal.pmoshRowStartsMessage("please", "please look at section nine again and tell me"))
        #expect(Terminal.pmoshRowStartsMessage("please look at section nine again and tell", "please look at section…"))
    }

    // MARK: a repaint no rewind asked for (11/11/2026)

    /// CUP home, EL 2 + CUD 1 on every row, CUP home: the erase Claude Code's full repaint starts with.
    private func erase(_ rows: Int) -> String {
        esc + "[H" + String(repeating: esc + "[2K" + esc + "[1B", count: rows) + esc + "[H"
    }

    private func rule(_ cols: Int) -> String { String(repeating: "─", count: cols) }

    /// A dialog's top line is a rule from edge to edge; a short one, or one with text, is not.
    @Test func ruleRows() {
        let (t, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 6, scrollback: 100)
        t.feed(text: [rule(20), rule(19), rule(6), "── title ──", ""].joined(separator: "\r\n"))
        let b = t.buffer
        #expect(Terminal.pmoshIsRule(b.lines[0]))
        #expect(Terminal.pmoshIsRule(b.lines[1]))
        #expect(!Terminal.pmoshIsRule(b.lines[2]))
        #expect(!Terminal.pmoshIsRule(b.lines[3]))
        #expect(!Terminal.pmoshIsRule(b.lines[4]))
    }

    /// A dialog taller than the view pushed the running turn's rows into history; the repaint
    /// after it draws them again from the top of the view. History stops inside the repeat.
    @Test func redrawSeamWhereHistoryStopsInTheRepeat() {
        let (t, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 6, scrollback: 100)
        // an earlier turn, then the running one; the dialog scrolls four more rows away
        t.feed(text: ["old 1", "old 2", "", "the prompt", "", "", "d1", "d2", "d3", "d4", "d5", "d6"].joined(separator: "\r\n"))
        #expect(t.buffer.yBase == 6)
        t.feed(text: erase(6) + ["", "the prompt", "", "", "", ""].joined(separator: "\r\n"))
        #expect(t.pmoshViewportClears == 1)
        let p = t.pmoshRedrawSeam()
        #expect(p == 2)
        t.pmoshCutHistory(from: p!)
        #expect(t.pmoshAllRowText().filter { !$0.isEmpty } == ["old 1", "old 2", "the prompt"])
    }

    /// The same with the dialog's own top in history: under the repeat come a spinner's row,
    /// a blank one and the rule. Two repeated rows with other text after them are no seam, a
    /// rest there or not.
    @Test func redrawSeamWithTheDialogsRuleInHistory() {
        let (t, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 6, scrollback: 100)
        t.feed(text: ["old 1", "", "the prompt", "*", "", rule(20), "d1", "d2", "d3", "d4", "d5", "d6"].joined(separator: "\r\n"))
        #expect(t.buffer.yBase == 6)
        t.feed(text: erase(6) + ["", "the prompt", "+", "", "", ""].joined(separator: "\r\n"))
        #expect(t.pmoshRedrawSeam() == 1)

        let (u, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 6, scrollback: 100)
        u.feed(text: ["old 1", "", "the prompt", "an answer", "more of it", "and more", "d1", "d2", "d3", "d4", "d5", "d6"].joined(separator: "\r\n"))
        u.feed(text: erase(6) + ["", "the prompt", "+", "", "", ""].joined(separator: "\r\n"))
        #expect(u.pmoshRedrawSeam() == nil)
        #expect(u.pmoshRedrawSeam(quietTops: [1]) == nil)
    }

    /// What the dialog drew and took back (a cancelled command's echo) follows the repeat: only
    /// a row that was the view's first one at a rest says the repeat starts the stale rows.
    @Test func redrawSeamAtAQuietTop() {
        let (t, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 6, scrollback: 100)
        t.feed(text: ["old 1", "old 2", "row a", "row b", "row c", "row d", "", "/model", "d1", "d2", "d3", "d4", "d5", "d6"].joined(separator: "\r\n"))
        #expect(t.buffer.yBase == 8)
        t.feed(text: erase(6) + ["row a", "row b", "row c", "row d", "", ""].joined(separator: "\r\n"))
        #expect(t.pmoshRedrawSeam() == nil)
        #expect(t.pmoshRedrawSeam(quietTops: [0, 5]) == nil)
        #expect(t.pmoshRedrawSeam(quietTops: [0, 2]) == 2)
        #expect(t.pmoshRedrawSeam(quietTops: [2, 0, 2, 7, 99, -1]) == 2)
    }

    /// A rest further back than two views still counts; a bare repeat that far back does not.
    @Test func redrawSeamFarBack() {
        let (t, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 4, scrollback: 100)
        t.feed(text: (["", "the prompt", "an answer", "more"] + (1...30).map { "pushed \($0)" }).joined(separator: "\r\n"))
        #expect(t.buffer.yBase == 30)
        t.feed(text: erase(4) + ["", "the prompt", "an answer", "more"].joined(separator: "\r\n"))
        #expect(t.pmoshRedrawSeam() == nil)
        #expect(t.pmoshRedrawSeam(quietTops: [0]) == 0)
    }

    /// No seam: nothing repeats, or only blank rows do.
    @Test func redrawSeamNeedsARepeat() {
        let (t, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 4, scrollback: 100)
        t.feed(text: (1...10).map { "row \($0)" }.joined(separator: "\r\n"))
        t.feed(text: erase(4) + ["other 1", "other 2", "", ""].joined(separator: "\r\n"))
        #expect(t.pmoshRedrawSeam(quietTops: Array(0..<6)) == nil)

        let (u, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 4, scrollback: 100)
        u.feed(text: ["row 1", "", "", "x", "y", "z", "w"].joined(separator: "\r\n"))
        u.feed(text: erase(4) + ["", "", "new", ""].joined(separator: "\r\n"))
        #expect(u.pmoshRedrawSeam(quietTops: [0, 1, 2]) == nil)
    }

    /// A watch driven by hand: `look` is one rest of the output.
    private final class Watched {
        let t: Terminal
        let watch = PmoshSeamWatch()
        var clock = Date(timeIntervalSince1970: 1_000_000)

        init(cols: Int = 20, rows: Int = 6) {
            t = TerminalTestHarness.makeTerminal(cols: cols, rows: rows, scrollback: 100).0
        }

        func look(after seconds: TimeInterval = 0.5) -> (from: Int, reason: PmoshSeamWatch.Reason)? {
            clock = clock.addingTimeInterval(seconds)
            return watch.settle(t, now: clock)
        }
    }

    /// The running turn, at rest; then the dialog drawn from the row under the prompt, four rows
    /// pushed.
    private func turnUnderADialog(_ w: Watched) {
        w.t.feed(text: ["old 1", "old 2", "", "the prompt", "", ""].joined(separator: "\r\n"))
        #expect(w.look() == nil)
        w.t.feed(text: esc + "[1A\r" + ["d1", "d2", "d3", "d4", "d5", "d6"].joined(separator: "\r\n"))
        #expect(w.t.buffer.yBase == 4)
        #expect(w.look() == nil)
    }

    /// The watch asks for that seam only after a full-view erase it has seen come by, and once.
    @Test func watchCutsARedrawOnlyAfterAnErase() {
        let w = Watched()
        turnUnderADialog(w)
        // text that happens to repeat, without an erase: nothing
        w.t.feed(text: esc + "[H" + ["", "the prompt", "", "", "", ""].joined(separator: esc + "[K\r\n") + esc + "[K")
        #expect(w.t.pmoshRedrawSeam(quietTops: [2]) == 2)
        #expect(w.look() == nil)
        // the dialog again, then the erase and the repaint
        w.t.feed(text: esc + "[H" + ["d1", "d2", "d3", "d4", "d5", "d6"].joined(separator: esc + "[K\r\n"))
        #expect(w.look() == nil)
        w.t.feed(text: erase(6) + ["", "the prompt", "", "", "", ""].joined(separator: "\r\n"))
        let cut = w.look()
        #expect(cut?.from == 2)
        #expect(cut?.reason == .redraw)
        w.t.pmoshCutHistory(from: 2)
        w.watch.reset(w.t)
        #expect(w.look() == nil)
        #expect(w.t.pmoshAllRowText().filter { !$0.isEmpty } == ["old 1", "old 2", "the prompt"])
    }

    /// A repaint that arrives in pieces: the erase alone at one rest, the rows at the next.
    @Test func watchWaitsForAPiecewiseRepaint() {
        let w = Watched()
        turnUnderADialog(w)
        w.t.feed(text: erase(6))
        #expect(w.look() == nil)
        w.t.feed(text: ["", "the prompt", "", "", "", ""].joined(separator: "\r\n"))
        #expect(w.look()?.from == 2)
    }

    /// The repaint that follows a resize is the resize's own: never looked at.
    @Test func watchLeavesAResizeAlone() {
        let w = Watched()
        turnUnderADialog(w)
        w.t.resize(cols: 20, rows: 5)
        w.t.feed(text: erase(5) + ["", "the prompt", "", "", ""].joined(separator: "\r\n"))
        #expect(w.look() == nil)
        #expect(w.look() == nil)
    }

    /// The same screen drawn again (Ctrl-L) pushed nothing: rows that repeat by themselves, a
    /// rest two rows back, an erase and the same rows. Nothing goes.
    @Test func watchLeavesTheSameScreenAlone() {
        let w = Watched(rows: 4)
        w.t.feed(text: ["a", "b", "ok", "ok", "ok", "ok"].joined(separator: "\r\n"))
        #expect(w.t.buffer.yBase == 2)
        #expect(w.look() == nil)
        w.t.feed(text: "\r\n" + ["ok", "ok"].joined(separator: "\r\n"))
        #expect(w.t.buffer.yBase == 4)
        #expect(w.look() == nil)
        #expect(w.t.pmoshRedrawSeam(quietTops: [2]) == 2)
        w.t.feed(text: erase(4) + ["ok", "ok", "ok", "ok"].joined(separator: "\r\n"))
        #expect(w.t.pmoshViewportClears == 1)
        #expect(w.look() == nil)
        #expect(w.look() == nil)
    }

    /// A rest is remembered once however often the output rests there (a spinner), and the
    /// row before the push stays known through many rests and pushes.
    @Test func watchKeepsTheRowBeforeThePush() {
        let w = Watched()
        w.t.feed(text: ["old 1", "old 2", "", "the prompt", "", ""].joined(separator: "\r\n"))
        for _ in 0..<100 { #expect(w.look(after: 0.1) == nil) }
        // the dialog, then twenty more rows pushed under it one at a time, a rest after each
        w.t.feed(text: esc + "[1A\r" + ["d1", "d2", "d3", "d4", "d5", "d6"].joined(separator: "\r\n"))
        #expect(w.look() == nil)
        for i in 0..<20 {
            w.t.feed(text: "\r\nmore \(i)")
            #expect(w.look(after: 0.1) == nil)
        }
        // the view comes back as it stood at that first rest
        w.t.feed(text: erase(6) + ["old 1", "old 2", "", "the prompt", "", ""].joined(separator: "\r\n"))
        #expect(w.look()?.from == 0)
    }

    /// A cut's rows by number: the first ones and, past twelve rows, the last ones.
    @Test func cutAnchorsHashTheRows() {
        #expect(Terminal.pmoshTextHash("") == 2166136261)
        #expect(Terminal.pmoshTextHash("a") == 0xE40C292C)
        let (t, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 4, scrollback: 100)
        t.feed(text: (1...30).map { $0 % 5 == 0 ? "" : "row \($0)" }.joined(separator: "\r\n"))
        let b = t.buffer
        #expect(b.yBase == 26)
        let short = t.pmoshCutAnchors(at: 20)
        #expect(short.head == (20..<26).map { Terminal.pmoshTextHash(t.pmoshRowText(b.lines[$0])) })
        #expect(short.tail.isEmpty)
        let long = t.pmoshCutAnchors(at: 2)
        #expect(long.head == (2..<14).map { Terminal.pmoshTextHash(t.pmoshRowText(b.lines[$0])) })
        #expect(long.tail == (14..<26).map { Terminal.pmoshTextHash(t.pmoshRowText(b.lines[$0])) })
        #expect(long.before == ["row 1", "row 2"] && long.first == ["row 3", "row 4", "row 6"])
    }
}
