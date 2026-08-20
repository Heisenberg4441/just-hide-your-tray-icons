import AppKit

/// Hides third-party menu bar icons using the only mechanism macOS gives an
/// ordinary app: an *expander* — a wide, empty status item parked directly to
/// the left of our arrow. Everything the expander pushes past the left edge of
/// the status area no longer fits, and macOS folds it away.
///
/// Layout we aim for (the menu bar lays items out right-to-left):
///
///     [ app menus ][ …icons with nowhere to go… ][ expander ][ ‹ ][ Control Center ][ clock ]
///
/// Two things make this harder than it sounds:
///
/// * macOS refuses to place a status item that does not fit. Instead of
///   squeezing its neighbours it drops the item off-screen entirely — so the
///   expander cannot be handed a "big enough" constant. Its length has to be
///   measured against the live menu bar, which is what `calibrate()` does.
/// * The free width changes constantly, because the front app's menus sit in
///   the same bar. A wide menu can leave no room at all.
@MainActor
final class MenuBarHider {

    // MARK: - Placement

    /// Autosave names double as the suffix of the private-but-stable
    /// `NSStatusItem Preferred Position <autosaveName>` user default.
    private enum Autosave {
        static let arrow = "JustHideArrow"
        static let expander = "JustHideExpander"
    }

    /// Preferred position is a right-to-left rank compared against every other
    /// app's stored value: the *smaller* the number the further right the item
    /// sits. Values <= 0 are ignored as "no preference" and land you in the
    /// left-most slot, which is why these are fractions rather than 0 and 1 —
    /// they also edge out the other menu bar managers, which all ask for 1.
    private enum Position {
        static let arrow = 0.5
        /// Where the separator sits by default: immediately left of the arrow,
        /// so everything gets hidden. Moving it further left (a *larger* value)
        /// leaves the icons it passes over on the visible side.
        static let separator = 1.5
        static let separatorLimit = 4096.0
    }

    /// Persisted cut point. Icons that end up to the right of the separator stay
    /// visible when the rest are tucked away.
    var separatorPosition: Double {
        get { UserDefaults.standard.object(forKey: Self.separatorKey) as? Double ?? Position.separator }
        set { UserDefaults.standard.set(newValue, forKey: Self.separatorKey) }
    }
    private static let separatorKey = "SeparatorPosition"

    private static func positionKey(_ autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    // MARK: - Calibration tuning

    /// How much the expander grows per calibration step. Small enough to land
    /// close to the true maximum, large enough to converge in a few steps.
    private let step: CGFloat = 60
    /// How far past the clamp point to push the expander in order to swallow
    /// macOS's own `«` overflow chevron along with the icons.
    ///
    /// Measured on macOS 27: at the clamp point the system still draws its
    /// chevron; from roughly +40 it disappears, and somewhere past +250 macOS
    /// gives up on the expander altogether and every icon springs back. The
    /// middle of that band is the safe place to sit.
    private let chevronOvershoot: CGFloat = 120
    /// The arrow is deliberately a fixed width rather than
    /// `NSStatusItem.variableLength`. A variable-length item makes macOS treat
    /// the whole run as elastic: instead of folding the neighbouring icons away
    /// it quietly clips the expander, and a handful of icons nearest the arrow
    /// stay on show no matter how long the expander gets. Measured on macOS 27:
    /// same expander, same positions, variable-length arrow leaves four icons
    /// visible, fixed-width arrow hides every one of them.
    private let arrowWidth: CGFloat = 30
    /// Width of the separator while the icons are on show. AppKit floors a
    /// status item at roughly 16pt anyway, so this is as thin as it gets.
    private let separatorWidth: CGFloat = 8
    /// Time given to the menu bar to lay itself out after a length change.
    private let settleDelay = Duration.milliseconds(50)
    /// Status item windows report a bogus origin for a moment after launch, so
    /// the first calibration waits for real geometry rather than measuring zeros.
    private let geometryPollInterval = Duration.milliseconds(150)
    private let geometryPollLimit = 40

    // MARK: - State

    private(set) var isHidden = false
    private var arrowItem: NSStatusItem!
    private var expanderItem: NSStatusItem!
    private var calibration: Task<Void, Never>?
    /// Last length known to place the expander correctly; the next calibration
    /// starts from here so an app switch usually costs one or two steps.
    private var lastGoodLength: CGFloat = 60
    /// Set while the menu bar has no room for us at all, so the background poll
    /// stops re-measuring a situation it cannot fix.
    private var stoodDownAt: Date?
    /// Length at which growth last ran out of room, *before* the overshoot that
    /// swallows the system chevron. Re-measuring starts here rather than from
    /// scratch — and the overshoot is always applied to this, never to a length
    /// that already includes one, which would make it creep up on every pass.
    private var wallLength: CGFloat = 0
    /// Where the expander's left edge ended up last time we measured. If it has
    /// drifted right, the bar has room we are no longer using — icons will have
    /// crept back into view.
    private var lastCalibratedX: CGFloat = .greatestFiniteMagnitude

    /// Called after every state change so the UI (icon, menu) can follow.
    var onStateChange: (() -> Void)?

    // MARK: - Setup

    init() {
        let bar = NSStatusBar.system

        // Created first so it starts out right of the expander even before the
        // preferred positions are honoured.
        arrowItem = Self.makeItem(in: bar, autosaveName: Autosave.arrow,
                                  position: Position.arrow, length: arrowWidth)

        // Deliberately born narrow: macOS drops a status item created wider than
        // the free space, but happily clips one that grows into it.
        expanderItem = Self.makeItem(in: bar, autosaveName: Autosave.expander,
                                     position: separatorPosition, length: separatorWidth)
        showSeparatorGlyph()
    }

    /// Order is load-bearing: the preferred position is read at the moment
    /// `autosaveName` is assigned, so it has to be on disk before that line.
    private static func makeItem(in bar: NSStatusBar, autosaveName: String,
                                 position: Double, length: CGFloat) -> NSStatusItem {
        let defaults = UserDefaults.standard
        let key = positionKey(autosaveName)
        // Seed only when absent, so a position the user chose by ⌘-dragging
        // survives a relaunch. "Reset Icon Position" is the way back.
        let resolved = defaults.object(forKey: key) as? Double ?? position
        defaults.set(resolved, forKey: key)

        let item = bar.statusItem(withLength: length)
        item.autosaveName = autosaveName
        // ⌘-dragging an item off the bar is persisted, which would leave the app
        // running with no way to reach it.
        item.behavior = []
        item.isVisible = true
        defaults.set(resolved, forKey: key)   // isVisible can clear the key
        return item
    }

    var arrowButton: NSStatusBarButton? { arrowItem.button }
    var arrowStatusItem: NSStatusItem { arrowItem }

    // MARK: - Public API

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        stoodDownAt = nil
        setExpander(inBar: true)
        hideSeparatorGlyph()
        onStateChange?()
        calibrate()
    }

    func show() {
        guard isHidden else { return }
        isHidden = false
        calibration?.cancel()
        // The expander stays in the bar as a thin separator: it is the marker
        // the user ⌘-drags icons past to decide what stays visible.
        setExpander(inBar: true)
        showSeparatorGlyph()
        onStateChange?()
    }

    func toggle() { isHidden ? show() : hide() }

    private func showSeparatorGlyph() {
        expanderItem.length = separatorWidth
        expanderItem.button?.title = "|"
        expanderItem.button?.alphaValue = 0.35
    }

    private func hideSeparatorGlyph() {
        expanderItem.button?.title = ""
    }

    /// Puts both items back where they belong after a ⌘-drag has moved them —
    /// the arrow has to stay right of the expander or hiding swallows it too.
    func resetPosition() async {
        let wasHidden = isHidden
        show()
        separatorPosition = Position.separator
        for (item, autosaveName, position) in [(arrowItem!, Autosave.arrow, Position.arrow),
                                               (expanderItem!, Autosave.expander, Position.separator)] {
            // The position is only re-read when the item (re)enters the bar, and
            // leaving the bar wipes the stored value — so write it in between.
            item.isVisible = false
            try? await Task.sleep(for: settleDelay)
            UserDefaults.standard.set(position, forKey: Self.positionKey(autosaveName))
            item.isVisible = true
            try? await Task.sleep(for: settleDelay)
        }
        lastGoodLength = step
        lastCalibratedX = .greatestFiniteMagnitude
        wallLength = 0
        Log.debug("positions reset")
        if wasHidden { hide() }
    }

    // MARK: - Choosing what stays visible

    /// How much the gap between separator and arrow has to change before we
    /// count it as "moved past one icon".
    private let gapThreshold: CGFloat = 12

    /// Room currently available between the separator and the arrow — i.e. how
    /// much of the bar is on the always-visible side of the cut.
    private var separatorGap: CGFloat {
        guard let separator = expanderFrame, let arrow = arrowFrame else { return 0 }
        return arrow.minX - separator.minX
    }

    /// Moves the separator one icon further left (keeping one more icon on show)
    /// or one back to the right.
    ///
    /// macOS offers no way to ask what else is in the menu bar, and on macOS 27
    /// other apps' items are not even separate windows any more — so the only
    /// way to find the next slot is to try preferred positions and watch how
    /// much room opens up next to our arrow. The gap only ever grows with the
    /// position value, which makes it a binary search rather than a scan.
    func moveSeparator(keepingMore: Bool) async {
        let wasHidden = isHidden
        show()
        guard await applySeparatorPosition(separatorPosition) else { return }
        let startGap = separatorGap

        func movedPastAnIcon() -> Bool {
            keepingMore ? separatorGap > startGap + gapThreshold
                        : separatorGap < startGap - gapThreshold
        }

        var low = keepingMore ? separatorPosition : Position.separator
        var high = keepingMore ? Position.separatorLimit : separatorPosition

        // Is there anything left to move past at all?
        guard await applySeparatorPosition(keepingMore ? high : low) else { return }
        guard movedPastAnIcon() else {
            Log.debug("separator already as far \(keepingMore ? "left" : "right") as it goes")
            _ = await applySeparatorPosition(separatorPosition)
            finishSeparatorMove(restoringHidden: wasHidden)
            return
        }

        for _ in 0..<9 {
            let middle = (low + high) / 2
            guard await applySeparatorPosition(middle) else { return }
            if keepingMore {
                if movedPastAnIcon() { high = middle } else { low = middle }
            } else {
                if movedPastAnIcon() { low = middle } else { high = middle }
            }
        }

        let settled = keepingMore ? high : low
        guard await applySeparatorPosition(settled) else { return }
        separatorPosition = settled
        wallLength = 0            // the whole geometry just moved
        Log.debug("separator -> \(settled); gap \(Int(startGap)) -> \(Int(separatorGap))")
        finishSeparatorMove(restoringHidden: wasHidden)
    }

    private func finishSeparatorMove(restoringHidden: Bool) {
        showSeparatorGlyph()
        if restoringHidden { hide() }
    }

    /// Re-enters the bar at a new preferred position. The value is only read as
    /// the item joins the bar, and leaving the bar deletes it, so the write has
    /// to happen in between.
    private func applySeparatorPosition(_ position: Double) async -> Bool {
        expanderItem.isVisible = false
        do { try await Task.sleep(for: settleDelay) } catch { return false }
        UserDefaults.standard.set(position, forKey: Self.positionKey(Autosave.expander))
        expanderItem.isVisible = true
        showSeparatorGlyph()
        do { try await Task.sleep(for: .milliseconds(120)) } catch { return false }
        return !Task.isCancelled
    }

    /// Re-measures if something moved under us — a different app took over the
    /// menu bar (its menus are a different width), a display was attached, or a
    /// new status item appeared. Cheap when nothing actually changed.
    ///
    /// `force` separates "something definitely changed" (an app switch) from the
    /// background poll, which must not keep re-running a measurement that has
    /// already concluded there is no room.
    func revalidate(force: Bool) {
        // The cheap read comes first, and it mutates nothing. Re-measuring costs
        // several length changes, and while they run the icons flash back into
        // view — so an app switch that changed nothing must cost nothing.
        guard isHidden, needsRecalibration else { return }
        if !force, let stoodDownAt,
           Date().timeIntervalSince(stoodDownAt) < Self.standDownRetryInterval { return }
        calibrate()
    }

    /// Re-measures unconditionally. For things the user just asked for, where
    /// "nothing looks different, so do nothing" would read as the command being
    /// ignored.
    func recalibrateNow() {
        guard isHidden else { return }
        stoodDownAt = nil
        calibrate()
    }

    private static let standDownRetryInterval: TimeInterval = 30

    /// Whether the background poll should re-measure. Being *placed* correctly
    /// is not the same as still *working*: a squeeze can leave the expander at
    /// its emergency width, correctly positioned and hiding nothing at all, and
    /// nothing else would ever notice once the squeeze passes.
    var needsRecalibration: Bool {
        guard isHidden else { return false }
        if stoodDownAt != nil { return true }             // retry is rate-limited below
        guard isPlacedCorrectly else { return true }
        if expanderItem.length < lastGoodLength - 1 { return true }
        if let x = expanderFrame?.origin.x, abs(x - lastCalibratedX) > step / 2 { return true }
        return false
    }

    /// True while the expander sits where it is supposed to: on the menu bar
    /// (not banished off-screen) and entirely to the left of the arrow.
    ///
    /// The arrow's own visibility is part of the test on purpose. When the front
    /// app's menus are wide enough, macOS starts folding status items away from
    /// the left — and a big expander makes it run out of room early enough that
    /// our arrow goes with them, leaving no way back to the icons. Keeping the
    /// arrow reachable outranks hiding one more icon.
    var isPlacedCorrectly: Bool {
        guard let expander = expanderFrame, let arrow = arrowFrame else { return false }
        // Only the starting edges matter. The expander's *window* routinely
        // reaches under the arrow — and under any icons the user chose to keep
        // on show — and macOS simply clips it; insisting the two never overlap
        // would stop growth long before the icons are actually pushed out.
        return expander.minX < arrow.minX
    }

    /// Both items are actually drawn in the menu bar. This is the only check
    /// that still means anything once the expander is overshooting: at that
    /// point the reported frames stop moving, so they can no longer tell us
    /// whether the icons are hidden.
    private var bothItemsVisible: Bool { arrowFrame != nil && expanderFrame != nil }

    /// Frames of items macOS has decided not to show live off-screen (negative
    /// `y`), so nil here means "not visible in the menu bar".
    private var expanderFrame: NSRect? { onScreenFrame(of: expanderItem) }
    private var arrowFrame: NSRect? { onScreenFrame(of: arrowItem) }

    private func onScreenFrame(of item: NSStatusItem) -> NSRect? {
        guard let frame = item.button?.window?.frame, frame.origin.y > 0 else { return nil }
        return frame
    }

    /// Adding and removing the expander is how we toggle, so the stored position
    /// has to be carried across — leaving the bar deletes it, and it would come
    /// back at the far left.
    private func setExpander(inBar: Bool) {
        let key = Self.positionKey(Autosave.expander)
        let cached = UserDefaults.standard.object(forKey: key) as? Double
        expanderItem.isVisible = inBar
        if let cached { UserDefaults.standard.set(cached, forKey: key) }
    }

    // MARK: - Calibration

    /// Finds the longest expander macOS will still lay out. Runs off the run
    /// loop because a status item's frame only updates once the menu bar has had
    /// a chance to re-lay itself out after `length` changes.
    /// Debug-only override so a length can be pinned while measuring by eye.
    private var forcedLength: CGFloat? {
        guard let raw = ProcessInfo.processInfo.environment["JUSTHIDE_FORCE_LEN"],
              let value = Double(raw) else { return nil }
        return CGFloat(value)
    }

    private func calibrate() {
        calibration?.cancel()
        if let forced = forcedLength {
            calibration = Task { @MainActor [weak self] in
                guard let self, await waitForGeometry() else { return }
                var current: CGFloat = step
                while current < forced {
                    current = min(current + step, forced)
                    expanderItem.length = current
                    guard await settle() else { return }
                }
                Log.debug("forced len=\(Int(forced)) x=\(Int(expanderFrame?.origin.x ?? -1))")
            }
            return
        }
        calibration = Task { @MainActor [weak self] in
            guard let self else { return }
            // A previous stand-down may have taken it out of the bar.
            setExpander(inBar: true)
            guard await waitForGeometry() else {
                // Still no room, or we were cancelled. If the former, go back to
                // standing down so the retry stays rate-limited.
                if isHidden { setExpander(inBar: false); stoodDownAt = Date() }
                return
            }

            // One length serves every display, so bound it by the narrowest.
            // The ceiling is deliberately well under half the bar: measured on
            // macOS 27, somewhere around 50% of the screen width macOS stops
            // laying the expander out at all and every icon springs back.
            let narrowestScreen = NSScreen.screens.map(\.frame.width).min() ?? 1440
            let maxLength = narrowestScreen * 0.45

            // Phase 1 — shrink until the menu bar accepts the layout again.
            // Recovering from "too wide" is the urgent half: until it fits,
            // either nothing is hidden or the arrow itself is missing.
            // Resume from the last known wall. Only the very first pass has to
            // sweep up from nothing; after that the wall is a step or two away,
            // and starting from the bottom would flash every icon back into
            // view for half a second on every app switch.
            var length = wallLength > 0 ? min(wallLength, maxLength) : step
            expanderItem.length = length
            guard await settle() else { return }

            while !isPlacedCorrectly && length > step {
                length = max(step, length - step)
                Log.debug("shrink -> \(Int(length))")
                expanderItem.length = length
                guard await settle() else { return }
            }

            guard isPlacedCorrectly else {
                // Not enough room for even the smallest expander — a very wide
                // menu on a narrow screen. Stand down rather than leave the
                // arrow stranded off-screen.
                // Leave the bar entirely rather than park an empty sliver: at
                // this width it hides nothing and is just a visible gap.
                Log.debug("no room; standing down")
                wallLength = 0
                setExpander(inBar: false)
                stoodDownAt = Date()
                return
            }

            // Phase 2 — grow while it still fits *and* still buys screen space.
            // Growth ends one of three ways: the expander stops moving left
            // (clamped), it would run under the arrow, or macOS drops it. The
            // first two mean we have found the wall and the icons are hidden;
            // only the third is a failure.
            var lastX = expanderFrame?.origin.x ?? .greatestFiniteMagnitude
            var hitTheWall = false
            while length + step <= maxLength {
                let candidate = length + step
                expanderItem.length = candidate
                guard await settle() else { return }

                if let x = expanderFrame?.origin.x, isPlacedCorrectly {
                    length = candidate
                    if x >= lastX - 1 {            // clamped — as far left as it goes
                        Log.debug("clamped at x=\(Int(x)); settled at \(Int(length))")
                        hitTheWall = true
                        break
                    }
                    lastX = x
                    continue
                }

                expanderItem.length = length       // back off to the last good one
                guard await settle() else { return }
                // Overlapping the arrow is the wall; losing an item is failure.
                hitTheWall = bothItemsVisible
                Log.debug("grow \(Int(candidate)) rejected at \(Int(length)); wall=\(hitTheWall)")
                break
            }

            wallLength = length
            if hitTheWall {
                length = await overshootPastClamp(from: length, limit: maxLength)
            }

            lastGoodLength = length
            lastCalibratedX = expanderFrame?.origin.x ?? .greatestFiniteMagnitude
            stoodDownAt = nil
            Log.debug("calibrated: len=\(Int(length)) x=\(Int(lastCalibratedX))")
        }
    }

    /// At the clamp point the icons are hidden but macOS still shows its own `«`
    /// overflow chevron next to our arrow. Pushing a little further swallows the
    /// chevron too. Too far and macOS discards the expander entirely, so this
    /// backs off the moment either of our items stops being drawn.
    private func overshootPastClamp(from length: CGFloat, limit: CGFloat) async -> CGFloat {
        guard hidesSystemChevron else { return length }
        let target = min(length + chevronOvershoot, limit)
        guard target > length else { return length }

        expanderItem.length = target
        guard await settle() else { return length }

        guard bothItemsVisible else {
            Log.debug("overshoot \(Int(target)) lost an item; back to \(Int(length))")
            expanderItem.length = length
            _ = await settle()
            return length
        }
        Log.debug("overshot to \(Int(target)) to swallow the system chevron")
        return target
    }

    /// Whether to push past the clamp point far enough to hide macOS's own `«`.
    var hidesSystemChevron: Bool {
        get { UserDefaults.standard.object(forKey: Self.chevronKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.chevronKey) }
    }
    private static let chevronKey = "HideSystemOverflowChevron"

    /// Status item windows sit at the origin for a beat after they are created.
    /// Measuring during that window reads every item as "off-screen" and the
    /// calibration concludes, wrongly, that there is no room.
    private func waitForGeometry() async -> Bool {
        for _ in 0..<geometryPollLimit {
            if arrowFrame != nil && expanderFrame != nil { return true }
            do { try await Task.sleep(for: geometryPollInterval) } catch { return false }
            if Task.isCancelled || !isHidden { return false }
        }
        Log.debug("menu bar geometry never settled")
        return false
    }

    /// Waits for the menu bar to settle. Returns false if the calibration was
    /// cancelled or the icons were revealed meanwhile.
    private func settle() async -> Bool {
        do { try await Task.sleep(for: settleDelay) } catch { return false }
        return !Task.isCancelled && isHidden
    }
}
