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
    public struct PmoshCutAnchors: Equatable {
        public var before: [String]
        public var first: [String]
        public var lead: Int

        public init(before: [String], first: [String], lead: Int) {
            self.before = before
            self.first = first
            self.lead = lead
        }
    }

    /// The anchors of a cut from buffer row `row`, `count` rows each way.
    public func pmoshCutAnchors(at row: Int, count: Int = 3) -> PmoshCutAnchors {
        let b = buffer
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
        return PmoshCutAnchors(before: before, first: first, lead: max(0, lead))
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
/// `pmoshCutHistory`. It only ever cuts after the rewind dialog's confirmation step was on screen
/// with a conversation restore picked, and the message it showed is back in the input: a repaint
/// that follows a resize or a change above the view never cuts anything.
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
    /// How long after the dialog left the screen the restore is waited for.
    static let grace: TimeInterval = 3

    /// Which seam a cut was found at, for the log: the full repaint's (rewinding further back
    /// than the view is tall), or the rewound message's own row.
    public enum Reason: String {
        case repaint, rewind
    }

    /// Call with the output quiet. Returns the buffer row to drop history from, or nil.
    public func settle(_ t: Terminal, now: Date = Date()) -> (from: Int, reason: Reason)? {
        guard !t.isCurrentBufferAlternate else {
            confirm = nil
            return nil
        }
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
            if expired { confirm = nil }
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
    }

    /// Forget a repaint still waited for after a rewind cut too (the view switched buffers).
    public func forget(_ t: Terminal) {
        reset(t)
        followUp = nil
    }
}
