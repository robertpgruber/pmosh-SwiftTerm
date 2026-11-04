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
}
