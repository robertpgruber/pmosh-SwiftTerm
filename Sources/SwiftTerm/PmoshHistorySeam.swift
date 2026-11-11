//
//  PmoshHistorySeam.swift
//  SwiftTerm — pmosh fork (11/03/2026)
//
//  The history rows Claude Code's classic renderer leaves behind when its screen gets shorter.
//

import Foundation

// rob, 11/03: "when u rewind in pmosh it looks like it leaves junk". Claude Code's classic
// (main-screen) renderer keeps the whole conversation as one screen and can only rewrite the
// part in view; whatever has scrolled into history stays as it was. When the screen gets
// shorter (a rewind), the rows its new screen no longer has stay in history. Measured in 78x37
// tmux panes (pipe-pane) on Spark's 2.1.260, the iMac's 2.1.263 and 2.1.312; tmux's own history
// holds the same rows:
//  - Rewinding further back than the view is tall (and any rewind on 2.1.263 and 2.1.312): it
//    erases the view row by row (CUP home, EL 2 + CUD 1 per row, CUP home — never ED 3) and
//    paints the new screen's last rows there. History keeps the whole old conversation, the
//    rewound turns included, and the view repeats part of it.
//  - Rewinding one turn on 2.1.260: it erases the dialog and draws its frame higher up, at the
//    top of the view. The rewound turn stays in history right above the frame, where the
//    blank-tail view (iOSTerminalView) shows it as if it were still there.
// `PmoshSeamWatch` follows the rewind dialog at the moments the output rests; once the rewound
// message is back in the input it names the seam: the rewound message's own row, or, after a
// full repaint, where history starts repeating it (`pmoshRepaintSeam`). Only ever a found row to
// the end of history goes.
//
// rob, 11/11: "yeah pmosh rewind is leaving leftovers". No rewind made those: a dialog taller
// than the room under the conversation did (his /model list is 31 rows in a 34-row view). The
// turn still running is not settled text yet, Claude Code redraws it with the dialog; the dialog
// pushed its first rows — the message, and the dialog's own top rule — into history, and
// closing it erased the view the same way (CUP home, EL 2 + CUD 1 per row, CUP home) and drew
// the turn again from the top of the view. History kept the pushed copy right above it, in
// tmux's as well. Measured 11/11 in 78x34 tmux panes on Spark's 2.1.260, a stand-in answering
// for the model. `pmoshRedrawSeam` names that seam: where history repeats the view's first
// rows and then stops, or goes on with the dialog's rule, or started at a row that was the
// view's first one at a rest before the push. The watch asks it after every such erase that
// neither a rewind nor a resize explains.

extension Terminal {
    /// The run detector behind `pmoshViewportClears`; the parser calls it before every CSI.
    func pmoshTrackClear(code: UInt8, pars: [Int], collect: cstring) {
        guard collect.isEmpty else {
            pmoshClearRun = -1
            return
        }
        switch code {
        case 0x48: // CUP: a home ends a run (and starts the next one)
            if pars.allSatisfy({ $0 <= 1 }) {
                if pmoshClearRun == buffer.rows, !pmoshClearAwaitsDown, !isCurrentBufferAlternate {
                    pmoshViewportClears &+= 1
                }
                pmoshClearRun = 0
                pmoshClearAwaitsDown = false
            } else {
                pmoshClearRun = -1
            }
        case 0x4b: // EL 2 on the next row, at its first column
            if pmoshClearRun >= 0, !pmoshClearAwaitsDown, (pars.first ?? 0) == 2,
               buffer.x == 0, buffer.y == pmoshClearRun {
                pmoshClearAwaitsDown = true
            } else {
                pmoshClearRun = -1
            }
        case 0x42: // CUD 1 after it
            if pmoshClearRun >= 0, pmoshClearAwaitsDown, (pars.first ?? 1) <= 1 {
                pmoshClearRun += 1
                pmoshClearAwaitsDown = false
            } else {
                pmoshClearRun = -1
            }
        default:
            pmoshClearRun = -1
        }
    }

    // MARK: text

    /// A row's text as shown: cells never written read as spaces, the second half of a wide
    /// character adds nothing, trailing spaces are dropped.
    public func pmoshRowText(_ line: BufferLine) -> String {
        var s = ""
        var keep = 0
        var i = 0
        let n = line.count
        while i < n {
            let c = line[i]
            if c.code == 0 && i > 0 && line[i - 1].width == 2 {
                i += 1
                continue
            }
            if c.code == 0 || c.code == 32 {
                s.append(" ")
            } else {
                s.append(getCharacter(for: c))
                keep = s.count
            }
            i += 1
        }
        return keep == s.count ? s : String(s.prefix(keep))
    }

    /// Same characters cell for cell (a never-written cell and a space alike); colours and
    /// styles are not compared, since a repaint and a seed spell them differently.
    static func pmoshSameText(_ a: BufferLine, _ b: BufferLine) -> Bool {
        let n = min(a.count, b.count)
        for i in 0..<n {
            let x = a[i].code, y = b[i].code
            if x != y && !((x == 0 || x == 32) && (y == 0 || y == 32)) { return false }
        }
        for i in n..<a.count where a[i].code != 0 && a[i].code != 32 { return false }
        for i in n..<b.count where b[i].code != 0 && b[i].code != 32 { return false }
        return true
    }

    static func pmoshIsBlankText(_ line: BufferLine) -> Bool {
        for i in 0..<line.count where line[i].code != 0 && line[i].code != 32 { return false }
        return true
    }

    // MARK: the repaint's seam

    /// After a full-view erase and repaint: the first history row the repaint made stale, or nil.
    /// `frameTop` is the view row where Claude Code's frame starts (its input, with the message a
    /// rewind put back); the rows above it, less trailing blank rows and rules, are the repainted
    /// conversation. History is searched from its end for where that repeats:
    ///  - a block of history equal to the whole repainted conversation, other rows after it (the
    ///    rows the new screen dropped), or
    ///  - the end of history equal to the conversation's first rows (2 or more, not all blank):
    ///    history stops inside the repeat.
    /// Rows are compared by their text only. Main screen only.
    public func pmoshRepaintSeam(frameTop: Int) -> Int? {
        guard !isCurrentBufferAlternate else { return nil }
        let b = buffer
        let history = b.yBase
        guard history > 0, history + b.rows <= b.lines.count, frameTop > 0, frameTop <= b.rows else { return nil }
        var end = frameTop - 1
        while end >= 0, Terminal.pmoshIsFurniture(b.lines[history + end]) { end -= 1 }
        guard end >= 1 else { return nil }
        let head = b.lines[history]
        var p = history - 1
        while p >= 0 {
            if Terminal.pmoshSameText(b.lines[p], head) {
                var k = 1
                while k <= end, p + k < history, Terminal.pmoshSameText(b.lines[p + k], b.lines[history + k]) {
                    k += 1
                }
                var shown = 0
                for r in 0..<k where !Terminal.pmoshIsBlankText(b.lines[history + r]) { shown += 1 }
                if k > end, shown >= 2 { return p }
                if p + k == history, k >= 2, shown >= 1 { return p }
            }
            p -= 1
        }
        return nil
    }

    /// A blank row, or one drawn with box rules only (the rules around Claude Code's input).
    static func pmoshIsFurniture(_ line: BufferLine) -> Bool {
        for i in 0..<line.count {
            let c = line[i].code
            if c != 0 && c != 32 && c != 0x2500 && c != 0x2501 { return false }
        }
        return true
    }

    /// A row that is one box rule from edge to edge: the line Claude Code draws on top of a
    /// dialog (and around its input, where that has rules).
    static func pmoshIsRule(_ line: BufferLine) -> Bool {
        var rules = 0
        for i in 0..<line.count {
            let c = line[i].code
            if c == 0x2500 || c == 0x2501 {
                rules += 1
            } else if c != 0 && c != 32 {
                return false
            }
        }
        return rules >= max(8, line.count - 2)
    }

    /// After a full-view erase and repaint that no rewind explains: the first history row the
    /// repaint made stale, or nil. Claude Code erases the whole view only when what it last drew
    /// was taller than the view (a dialog over a turn still running, over a long list of models),
    /// and then paints its screen's last rows from the top of the view. Whatever the tall drawing
    /// pushed into history on its way up is drawn again there, so history repeats the view's
    /// first rows — 2 or more, not all blank — and after the repeat
    ///  - stops (the repeat is all that was pushed), or
    ///  - goes on with what stood under them: a rule within its next rows (the dialog's top; a
    ///    spinner row may sit above it), or
    ///  - goes on with anything, when the repeat is 3 rows or more and starts at one of
    ///    `quietTops`: a row that was the view's first one when the output rested before the
    ///    push, so the view shows again what it showed then (what follows is a command's echo
    ///    that Esc took back, rows the dialog itself pushed).
    /// The latest such row is the seam. The first two are looked for in the last two views' worth
    /// of history only: nothing taller gets drawn there. Rows are compared by their text only.
    /// Main screen only.
    public func pmoshRedrawSeam(quietTops: [Int] = []) -> Int? {
        guard !isCurrentBufferAlternate else { return nil }
        let b = buffer
        let history = b.yBase
        guard history > 0, history + b.rows <= b.lines.count else { return nil }
        let head = b.lines[history]
        let tops = Set(quietTops.filter { $0 >= 0 && $0 < history })
        let near = max(0, history - (2 * b.rows + 8))
        let lowest = min(near, tops.min() ?? near)
        var p = history - 1
        while p >= lowest {
            if (p >= near || tops.contains(p)), Terminal.pmoshSameText(b.lines[p], head) {
                var k = 1
                while k < b.rows, p + k < history, Terminal.pmoshSameText(b.lines[p + k], b.lines[history + k]) {
                    k += 1
                }
                var shown = 0
                for r in 0..<k where !Terminal.pmoshIsBlankText(b.lines[history + r]) { shown += 1 }
                if k >= 2, shown >= 1 {
                    if p >= near {
                        if p + k == history { return p }
                        for q in (p + k)..<min(history, p + k + 4) where Terminal.pmoshIsRule(b.lines[q]) { return p }
                    }
                    if k >= 3, tops.contains(p) { return p }
                }
            }
            p -= 1
        }
        return nil
    }

    /// The view's first rows as text, for telling a repaint that changed them from one that
    /// drew the same screen again.
    func pmoshViewHead(_ count: Int = 3) -> [String] {
        let b = buffer
        return (0..<min(count, b.rows)).map { r in
            let i = b.yBase + r
            return i < b.lines.count ? pmoshRowText(b.lines[i]) : ""
        }
    }

    // MARK: Claude Code's rewind dialog

    /// What the rewind dialog's confirmation step shows: the message the conversation goes back
    /// to (its first line, as the dialog prints it) and whether the highlighted choice restores
    /// the conversation ("Restore conversation", "Restore code and conversation").
    public struct PmoshRewindConfirm: Equatable {
        public var message: String
        /// nil while no choice is on screen (the dialog half drawn or half erased).
        public var restoresConversation: Bool?
        /// Screen row of the dialog's first line.
        public var top: Int

        func withMessage(_ m: String) -> PmoshRewindConfirm {
            var c = self
            c.message = m
            return c
        }
    }

    /// Every row of the buffer, history first, as text (tests, logs).
    public func pmoshAllRowText() -> [String] {
        let b = buffer
        return (0..<b.lines.count).map { pmoshRowText(b.lines[$0]) }
    }

    /// Rows of history (the rows above the view).
    public var pmoshHistoryRows: Int { buffer.yBase }

    /// Rows of the view, as text.
    func pmoshScreenText() -> [String] {
        let b = buffer
        return (0..<b.rows).map { r in
            let i = b.yBase + r
            return i < b.lines.count ? pmoshRowText(b.lines[i]) : ""
        }
    }

    static func pmoshTrimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
    }

    /// The rewind dialog's confirmation step, if it is on screen.
    public func pmoshRewindConfirm() -> PmoshRewindConfirm? {
        guard !isCurrentBufferAlternate else { return nil }
        let text = pmoshScreenText()
        guard let ask = text.firstIndex(where: { $0.contains("Confirm you want to restore") }) else { return nil }
        var top = ask
        for r in stride(from: ask - 1, through: max(0, ask - 3), by: -1) where Terminal.pmoshTrimmed(text[r]) == "Rewind" {
            top = r
            if r > 0, Terminal.pmoshTrimmed(text[r - 1]).allSatisfy({ $0 == "─" }), !Terminal.pmoshTrimmed(text[r - 1]).isEmpty {
                top = r - 1
            }
        }
        // The message sits on the "│ " lines under the question, wrapped to the dialog's width;
        // the last of them is its age ("(2m ago)", "(in 39s)").
        var parts: [String] = []
        var r = ask + 1
        while r < text.count, !Terminal.pmoshTrimmed(text[r]).hasPrefix("│"), r < ask + 4 { r += 1 }
        while r < text.count {
            let t = Terminal.pmoshTrimmed(text[r])
            guard t.hasPrefix("│") else { break }
            parts.append(Terminal.pmoshTrimmed(String(t.dropFirst())))
            r += 1
        }
        if let age = parts.last, parts.count > 1, age.hasPrefix("("), age.hasSuffix(")") { parts.removeLast() }
        let m = parts.joined(separator: " ")
        guard !m.isEmpty else { return nil }
        var restores: Bool?
        for r in ask..<text.count {
            let t = Terminal.pmoshTrimmed(text[r])
            if t.hasPrefix("❯") {
                restores = t.contains("Restore conversation") || t.contains("Restore code and conversation")
                break
            }
        }
        return PmoshRewindConfirm(message: m, restoresConversation: restores, top: top)
    }

    /// True while the rewind dialog's first step (the list of messages) is on screen.
    public func pmoshRewindSelectorShown() -> Bool {
        guard !isCurrentBufferAlternate else { return false }
        return pmoshScreenText().contains { $0.contains("Restore the code and/or conversation") }
    }

    /// A row's text with the user-message marks Claude Code may draw in front of it
    /// (a prompt glyph, a bar) taken off.
    static func pmoshMessageText(_ s: String) -> String {
        var t = Substring(pmoshTrimmed(s))
        while let f = t.first, "❯>›│▌┃".contains(f) {
            t = t.dropFirst().drop(while: { $0.isWhitespace })   // 2.1.312: "❯" + NO-BREAK SPACE
        }
        return String(t)
    }

    /// Whether a row reads as the start of `message` (the dialog's text, possibly cut short with
    /// an ellipsis): the whole message, or — 16 characters or more — the first part of a message
    /// longer than a row, or a row that goes on past where the dialog cut it.
    static func pmoshRowStartsMessage(_ row: String, _ message: String) -> Bool {
        let r = pmoshMessageText(row)
        var m = pmoshTrimmed(message)
        let cut = m.hasSuffix("…")
        if cut { m = pmoshTrimmed(String(m.dropLast())) }
        guard !m.isEmpty, !r.isEmpty else { return false }
        if r == m { return true }
        guard r.count >= 16, m.count >= 16 else { return false }
        return m.hasPrefix(r) || (cut && r.hasPrefix(m))
    }

    /// The last buffer row before `limit` where `message` starts as a user message: its text
    /// starts the message and the row above it is blank. nil when there is none.
    public func pmoshLatestMessageRow(_ message: String, before limit: Int) -> Int? {
        let b = buffer
        var i = min(limit, b.lines.count) - 1
        while i >= 1 {
            if Terminal.pmoshIsBlankText(b.lines[i - 1]) == true,
               !Terminal.pmoshIsBlankText(b.lines[i]),
               Terminal.pmoshRowStartsMessage(pmoshRowText(b.lines[i]), message) {
                return i
            }
            i -= 1
        }
        return nil
    }

    /// The view row where `message` is back in Claude Code's input after a rewind: the lowest row
    /// that starts it (the input sits under the conversation), or nil.
    public func pmoshDraftRow(_ message: String) -> Int? {
        let text = pmoshScreenText()
        for r in stride(from: text.count - 1, through: 0, by: -1) where !text[r].isEmpty {
            if Terminal.pmoshRowStartsMessage(text[r], message) { return r }
        }
        return nil
    }

    // MARK: cutting

    /// A row that says something: not blank, not rules only.
    func pmoshRowSaysSomething(_ line: BufferLine) -> Bool {
        !Terminal.pmoshIsFurniture(line)
    }

    /// Where a cut sits in the conversation, by content, so a copy of the same history elsewhere
    /// (tmux's own, painted back by a later seed) can be cut the same way: the text of the rows
    /// that say something just before it and of the first ones in it, and how many rows come
    /// before the first of those inside it (blank rows, rules).
    ///
    /// `head` and `tail` say which rows exactly (11/11): `pmoshTextHash` of the cut's first rows
    /// and, for a cut longer than that, of its last ones, blank rows and rules included. What a
    /// dialog pushed into history is drawn again right under it, so the same message stands in
    /// the copy and in the turn that follows; only the rows as a whole tell the two apart.
    public struct PmoshCutAnchors: Equatable {
        public var before: [String]
        public var first: [String]
        public var lead: Int
        public var head: [UInt32]
        public var tail: [UInt32]

        public init(before: [String], first: [String], lead: Int, head: [UInt32] = [], tail: [UInt32] = []) {
            self.before = before
            self.first = first
            self.lead = lead
            self.head = head
            self.tail = tail
        }
    }

    /// Rows hashed at each end of a cut for `PmoshCutAnchors.head` and `.tail`.
    public static let pmoshCutHashedRows = 12

    /// A row's text as one number (FNV-1a over its UTF-8), the same for a row of the buffer
    /// (`pmoshRowText`) and for the line tmux captured of it, escapes and trailing spaces off.
    public static func pmoshTextHash(_ text: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for byte in text.utf8 {
            h ^= UInt32(byte)
            h = h &* 16777619
        }
        return h
    }

    /// The anchors of a cut from buffer row `row`, `count` rows each way.
    public func pmoshCutAnchors(at row: Int, count: Int = 3) -> PmoshCutAnchors {
        let b = buffer
        let cut = max(0, b.yBase - row)
        let hashed = min(cut, Terminal.pmoshCutHashedRows)
        let head = (0..<hashed).map { Terminal.pmoshTextHash(pmoshRowText(b.lines[row + $0])) }
        let tail = cut > hashed ? (0..<hashed).map { Terminal.pmoshTextHash(pmoshRowText(b.lines[b.yBase - hashed + $0])) } : []
        var before: [String] = []
        var i = row - 1
        while i >= 0, before.count < count {
            if pmoshRowSaysSomething(b.lines[i]) { before.insert(pmoshRowText(b.lines[i]), at: 0) }
            i -= 1
        }
        var first: [String] = []
        var lead = -1
        i = row
        while i < b.yBase, first.count < count {
            if pmoshRowSaysSomething(b.lines[i]) {
                if lead < 0 { lead = i - row }
                first.append(pmoshRowText(b.lines[i]))
            }
            i += 1
        }
        return PmoshCutAnchors(before: before, first: first, lead: max(0, lead), head: head, tail: tail)
    }

    /// Drops history from buffer row `from` to the end of history (the row above the view), so
    /// the view's first row follows row `from - 1`. A parked viewport keeps its rows: one inside
    /// the dropped rows lands on the seam. Returns how many rows went.
    @discardableResult
    public func pmoshCutHistory(from start: Int) -> Int {
        guard !isCurrentBufferAlternate else { return 0 }
        let b = buffer
        let n = b.yBase - start
        guard start >= 0, n > 0 else { return 0 }
        b.lines.pmoshRemove(start: start, count: n)
        b.yBase -= n
        if b.yDisp >= start + n {
            b.yDisp -= n
        } else if b.yDisp > start {
            b.yDisp = start
        }
        b.recalculateLinesWithImagesCount()
        refresh(startRow: 0, endRow: rows - 1)
        return n
    }
}

/// Watches a terminal at quiet moments (no output for a few tens of milliseconds) for Claude
/// Code's rewind, and says where its history went stale, for the view to drop with
/// `pmoshCutHistory`. For a rewind it only ever cuts after the dialog's confirmation step was on
/// screen with a conversation restore picked, and the message it showed is back in the input.
/// Any other full-view erase (11/11: the repaint that follows a dialog taller than the view)
/// cuts only where history repeats the top of the view the way a pushed copy does
/// (`pmoshRedrawSeam`). A repaint that follows a resize is never looked at, nor one that drew
/// the same screen again (Ctrl-L).
public final class PmoshSeamWatch {
    public init() {}

    /// The rewind dialog's confirmation step, last seen: its message, the newest row above the
    /// dialog that starts that message (absolute: buffer row + `totalLinesTrimmed`), and
    /// `pmoshViewportClears` at the time.
    private var confirm: (dialog: Terminal.PmoshRewindConfirm, absRow: Int?, clears: Int)?
    /// When the dialog left the screen (its restore may still be arriving).
    private var goneAt: Date?
    /// After a cut at the rewound message with no full repaint seen yet: the message, the
    /// erase count then, and how long a repaint that follows still counts. Claude Code 2.1.312
    /// draws the restored input first and repaints the view after it; a link that stalls in
    /// between shows the cut before the repaint.
    private var followUp: (message: String, clears: Int, until: Date)?
    /// `pmoshViewportClears` at the last look, and until when a full-view erase seen since then
    /// may still be painting its rows (a link that delivers the repaint in pieces).
    private var seenClears: Int?
    private var redrawUntil: Date?
    /// Where the view's first row stood at the output's rests, each place once, oldest first
    /// (absolute: buffer row + `totalLinesTrimmed`). The last one is where it stands now.
    private var quietTops: [Int] = []
    static let quietTopsKept = 64
    /// The grid at the last look, and when it last changed: the repaint that follows a resize
    /// is the resize's own.
    private var seenSize: (cols: Int, rows: Int)?
    private var resizedAt: Date?
    /// The view's first rows at the last look, and as they were at the look before the erase
    /// now waited on.
    private var seenHead: [String] = []
    private var headBeforeErase: [String] = []
    /// How long after the dialog left the screen the restore is waited for.
    static let grace: TimeInterval = 3

    /// Which seam a cut was found at, for the log: the full repaint's (rewinding further back
    /// than the view is tall), the rewound message's own row, or where a repaint no rewind
    /// asked for drew the top of the view again (a dialog taller than the view closed).
    public enum Reason: String {
        case repaint, rewind, redraw
    }

    /// Call with the output quiet. Returns the buffer row to drop history from, or nil.
    public func settle(_ t: Terminal, now: Date = Date()) -> (from: Int, reason: Reason)? {
        guard !t.isCurrentBufferAlternate else {
            confirm = nil
            seenClears = nil
            redrawUntil = nil
            quietTops = []
            seenHead = []
            return nil
        }
        defer { seenHead = t.pmoshViewHead() }
        if let size = seenSize, size.cols != t.cols || size.rows != t.rows {
            resizedAt = now
            redrawUntil = nil
        }
        seenSize = (t.cols, t.rows)
        // History that got shorter (a cut, a clear, a taller grid) took the rows after its new
        // end with it.
        let top = t.buffer.yBase + t.buffer.totalLinesTrimmed
        quietTops.removeAll { $0 >= top }
        quietTops.append(top)
        if quietTops.count > PmoshSeamWatch.quietTopsKept { quietTops.removeFirst() }
        if let seen = seenClears, seen != t.pmoshViewportClears {
            if let r = resizedAt, now.timeIntervalSince(r) <= PmoshSeamWatch.grace {
                redrawUntil = nil
            } else {
                redrawUntil = now.addingTimeInterval(PmoshSeamWatch.grace)
                headBeforeErase = seenHead
            }
        }
        seenClears = t.pmoshViewportClears
        var rewinding = false
        if let cut = settleRewind(t, now: now, rewinding: &rewinding) {
            redrawUntil = nil
            return cut
        }
        // A rewind on its way owns the erase that comes with it.
        guard !rewinding, let until = redrawUntil else { return nil }
        guard now <= until else {
            redrawUntil = nil
            return nil
        }
        // The same screen drawn again pushed nothing and repeats nothing.
        guard t.pmoshViewHead() != headBeforeErase else { return nil }
        let trimmed = t.buffer.totalLinesTrimmed
        guard let p = t.pmoshRedrawSeam(quietTops: quietTops.dropLast().map { $0 - trimmed }) else { return nil }
        redrawUntil = nil
        return (p, .redraw)
    }

    /// The rewind's part of `settle`. `rewinding` comes back true while its dialog's
    /// confirmation step is on screen or its restore is still waited for.
    private func settleRewind(_ t: Terminal, now: Date, rewinding: inout Bool) -> (from: Int, reason: Reason)? {
        let b = t.buffer
        if let f = followUp {
            if now > f.until {
                followUp = nil
            } else if t.pmoshViewportClears != f.clears, let draft = t.pmoshDraftRow(f.message) {
                followUp = nil
                if let p = t.pmoshRepaintSeam(frameTop: draft) { return (p, .repaint) }
            }
        }
        if var shown = t.pmoshRewindConfirm() {
            // A dialog caught half drawn or half erased says less than the whole one did: keep
            // what the whole one said.
            rewinding = true
            if let c = confirm {
                if shown.restoresConversation == nil { shown.restoresConversation = c.dialog.restoresConversation }
                if c.dialog.message.hasPrefix(shown.message) {
                    confirm = (shown.withMessage(c.dialog.message), c.absRow, c.clears)
                    goneAt = nil
                    return nil
                }
            }
            let row = t.pmoshLatestMessageRow(shown.message, before: b.yBase + shown.top)
            confirm = (shown, row.map { $0 + b.totalLinesTrimmed }, t.pmoshViewportClears)
            goneAt = nil
            return nil
        }
        if t.pmoshRewindSelectorShown() {
            confirm = nil
            return nil
        }
        guard let c = confirm, c.dialog.restoresConversation == true else {
            confirm = nil
            return nil
        }
        let since = goneAt ?? now
        goneAt = since
        let expired = now.timeIntervalSince(since) > PmoshSeamWatch.grace
        guard let draft = t.pmoshDraftRow(c.dialog.message) else {
            if expired { confirm = nil } else { rewinding = true }
            return nil
        }
        // The restore is done: the message is back in the input.
        var cut: (from: Int, reason: Reason)?
        if let abs = c.absRow {
            let row = abs - b.totalLinesTrimmed
            if row >= 1, row < b.yBase,
               Terminal.pmoshRowStartsMessage(t.pmoshRowText(b.lines[row]), c.dialog.message) {
                cut = (row, .rewind)
            }
        }
        if t.pmoshViewportClears != c.clears {
            // It erased the view and painted its new screen's tail: the seam is where history
            // starts repeating that. A stalled link can leave the paint unfinished; wait for it.
            if let p = t.pmoshRepaintSeam(frameTop: draft) {
                if cut.map({ p < $0.from }) ?? true { cut = (p, .repaint) }
            } else if !expired {
                rewinding = true
                return nil
            }
        } else if cut != nil {
            followUp = (c.dialog.message, t.pmoshViewportClears, now.addingTimeInterval(PmoshSeamWatch.grace))
        }
        confirm = nil
        goneAt = nil
        return cut
    }

    /// Forget everything: after a cut, or when the view switches buffers.
    public func reset(_ t: Terminal) {
        confirm = nil
        goneAt = nil
        redrawUntil = nil
    }

    /// Forget a repaint still waited for after a rewind cut too (the view switched buffers).
    public func forget(_ t: Terminal) {
        reset(t)
        followUp = nil
        seenClears = nil
        quietTops = []
        seenHead = []
        seenSize = nil
        resizedAt = nil
    }
}
