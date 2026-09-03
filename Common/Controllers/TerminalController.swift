//
//  TerminalController.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import SwiftUI
import SwiftTerm
import os.log

/// One row, as drawn. A class so that a row has an identity: the same line handed over again is the
/// same object, and whoever is showing it can tell without looking inside.
public final class TerminalLine {
	public let view: AnyView

	public init(view: AnyView) {
		self.view = view
	}
}

/// One row that has changed since the last frame, and what it now looks like.
public struct TerminalLineChange {
	public let row: Int
	public let line: TerminalLine
}

public protocol TerminalControllerDelegate: AnyObject {
	/// A frame's worth of change. `droppedFromTop` rows have fallen off the start of the scrollback and
	/// go first; then there are `lineCount` rows, and `changes` are the ones that differ from last time,
	/// in ascending row order. Rows past the delegate's current count are always among them.
	func refresh(droppedFromTop: Int, lineCount: Int, changes: [TerminalLineChange])
	func activateBell()
	func titleDidChange(_ title: String?, isDirty: Bool, hasBell: Bool)
	func currentFileDidChange(_ url: URL?, inWorkingDirectory workingDirectoryURL: URL?)

	func saveFile(url: URL)
	func fileUploadRequested()

	func close()
	func didReceiveError(error: Error)
}

public class TerminalController {

	/// Frame rate the display link drops to once the terminal has gone `idleFrameThreshold` frames
	/// without changing. Output arriving via `readInputStream(_:)` restores the full rate straight
	/// away, so this only costs latency on the rare paths that change the screen without feeding it.
	private static let idleRefreshRate: TimeInterval = 10
	private static let idleFrameThreshold = 30

	public weak var delegate: TerminalControllerDelegate?

	public var colorMap: ColorMap {
		get { stringSupplier.colorMap! }
		set { stringSupplier.colorMap = newValue }
	}
	public var fontMetrics: FontMetrics {
		get { stringSupplier.fontMetrics! }
		set { stringSupplier.fontMetrics = newValue }
	}

	internal var terminal: Terminal?
	private var subProcess: SubProcess?
	private var subProcessFailureError: Error?
	private let stringSupplier = StringSupplier()
	/// Every row, as last drawn. Owned by `terminalQueue`, and never handed out whole.
	///
	/// It used to be copied to the main thread every frame. At full scrollback that is ten thousand
	/// type-erased views retained on this queue and released on the main one, per frame — and the
	/// profile of an agent streaming one line at a time was mostly that: reference counting, on rows
	/// that had not changed. Now only the rows that did change cross over, and each side keeps its
	/// own array.
	private var lines = [TerminalLine]()
	/// `StringSupplier.contentHash` of each row as last built, kept in step with `lines`.
	private var lineHashes = [Int]()
	/// How many rows the delegate holds, so the next frame knows which ones it has never seen.
	/// `terminalQueue` only.
	private var sentLineCount = 0

	/// The difference between the rows this controller counts and the rows SwiftTerm hands out.
	///
	/// SwiftTerm numbers rows two ways. Its update range and its top visible row count from the start
	/// of the buffer. `getScrollInvariantLine` counts from the first line the terminal ever scrolled,
	/// so once the scrollback is full and old lines are being dropped, its numbers run ahead of the
	/// buffer's by one per dropped line. Nothing exposes the difference, and asking by the buffer's
	/// count returns nil for every row — after ten thousand lines of output the whole screen went
	/// blank, and stayed blank.
	///
	/// So it is found by probing: rows below the offset come back nil, rows from it on do not. Kept
	/// from frame to frame and checked each time against the row at the offset and the one before it,
	/// which is two lookups when nothing has moved. `terminalQueue` only.
	private var rowOffset = 0

	private func updateRowOffset(_ terminal: Terminal) {
		let isValid = terminal.getScrollInvariantLine(row: rowOffset) != nil
			&& (rowOffset == 0 || terminal.getScrollInvariantLine(row: rowOffset - 1) == nil)
		if isValid {
			return
		}
		// The rows that exist form one run at least a screen tall, so stepping by half a screen can't
		// jump over it. From zero rather than from the old offset: a reset puts the numbering back to
		// the start, and the old offset is then past everything.
		let step = max(1, terminal.rows / 2)
		// Bounded by what the buffer can hold: a scrollback's worth of lines plus a screen, and some
		// room over. Past that there is nothing to find, and the loop was free to run for hours.
		let limit = 10_000 + terminal.rows * 4
		var probe = 0
		while terminal.getScrollInvariantLine(row: probe) == nil {
			probe += step
			guard probe <= limit else {
				// No rows anywhere in range. Leave the offset alone rather than keep looking.
				return
			}
		}
		// The first row that exists is in (probe - step, probe].
		var low = max(0, probe - step)
		var high = probe
		while low < high {
			let mid = (low + high) / 2
			if terminal.getScrollInvariantLine(row: mid) == nil {
				low = mid + 1
			} else {
				high = mid
			}
		}
		rowOffset = low
		stringSupplier.rowOffset = low
	}

	private var processLaunchDate: Date?
	private var updateTimer: CADisplayLink?
	private var refreshRate: TimeInterval = 60
	/// Rate the display link is actually running at, which may be `idleRefreshRate` rather than
	/// `refreshRate`. Main queue only.
	private var appliedRefreshRate: TimeInterval = 0
	/// Consecutive frames with no change to the terminal. `terminalQueue` only.
	private var idleFrames = 0
	private var isIdleThrottled = false
	private var isTabVisible = true
	private var isWindowVisible = true
	private var isVisible: Bool { isTabVisible && isWindowVisible }
	private var isDirty = false {
		didSet { updateTitle() }
	}
	private var hasBell = false {
		didSet { updateTitle() }
	}
	private var readBuffer = [UTF8Char]()

	/// Rolling tail of raw output, kept so it can be persisted and replayed after the app is killed.
	/// `terminalQueue` only, same as `readBuffer`. Capped by dropping from the front — the tail is what
	/// survives replay anyway.
	private static let scrollbackCaptureCap = 256 * 1024
	private var scrollbackCapture = ByteTailBuffer(capacity: scrollbackCaptureCap)
	private var activityOutputUpdatePending = false

	internal var terminalQueue = DispatchQueue(label: "ws.hbang.Terminal.terminal-queue")

	public var screenSize: ScreenSize? {
		didSet { updateScreenSize() }
	}
	public var scrollbackLines: Int { terminal?.getTopVisibleRow() ?? 0 }

	private var lastCursorLocation: (x: Int, y: Int) = (-1, -1)
	private var lastBellDate: Date?

	internal var title: String?
	internal var userAndHostname: String?
	internal var user: String?
	internal var hostname: String?
	internal var isLocalhost: Bool { hostname == nil || hostname == ProcessInfo.processInfo.hostName }
	internal var currentWorkingDirectory: URL?
	internal var currentFile: URL?

	internal var iTermIntegrationVersion: String?
	internal var shell: String?

	internal var logger = Logger(subsystem: "ws.hbang.Terminal", category: "TerminalController")

	public init() {
		#if DEBUG
		let joinCheck = Self.join([
			TextRow(text: "12345678", usedColumns: 8),
			TextRow(text: "next", usedColumns: 4),
			TextRow(text: "prompt", usedColumns: 6)
		], columns: 8)
		assert(joinCheck.text == "12345678next\nprompt" && joinCheck.starts == [0, 8, 13])

		// Dragging a selection handle: the fixed end stays put and the cell under the finger is always
		// inside, on whichever side of the fixed end the finger has gone.
		typealias Point = TerminalSelection.Point
		let fixedEnd = Point(row: 2, col: 5)
		let before = TerminalSelection.dragging(anchor: fixedEnd, to: Point(row: 2, col: 2))
		assert(before.start == Point(row: 2, col: 2) && before.end == fixedEnd)
		let after = TerminalSelection.dragging(anchor: fixedEnd, to: Point(row: 3, col: 1))
		assert(after.start == fixedEnd && after.end == Point(row: 3, col: 2))
		assert(!TerminalSelection.dragging(anchor: fixedEnd, to: fixedEnd).isEmpty)
		#endif

		let options = TerminalOptions(termName: "xterm-256color",
																	scrollback: 10_000)
		terminal = Terminal(delegate: self, options: options)

		stringSupplier.terminal = terminal

		// Synchronous onto the terminal queue from the main thread. Safe in that direction only: nothing
		// on the terminal queue ever waits on the main thread, so this can't deadlock, and the island
		// asks at most once every couple of seconds.
		activityController.lastLineProvider = { [weak self] in
			guard let self = self else {
				return nil
			}
			return self.terminalQueue.sync { self.lastPrintedLine() }
		}

		NotificationCenter.default.addObserver(self, selector: #selector(self.preferencesUpdated), name: Preferences.didChangeNotification, object: nil)
		preferencesUpdated()

		startUpdateTimer(fps: refreshRate)

		NotificationCenter.default.addObserver(self, selector: #selector(self.appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(self.appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)

		UIDevice.current.isBatteryMonitoringEnabled = true
		NotificationCenter.default.addObserver(self, selector: #selector(self.powerStateChanged), name: UIDevice.batteryStateDidChangeNotification, object: nil)

		if #available(macOS 12, *) {
			NotificationCenter.default.addObserver(self, selector: #selector(self.powerStateChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
		}
	}

	@objc private func preferencesUpdated() {
		let preferences = Preferences.shared
		let colorMap = preferences.colorMap
		stringSupplier.colorMap = colorMap
		stringSupplier.fontMetrics = preferences.fontMetrics

		// Programs ask the terminal what its text and background colours are, and pick a light or a
		// dark palette of their own from the answer. SwiftTerm answers from its own properties, which
		// nothing had ever set — so every theme reported grey on black, and on a light theme Codex drew
		// its composer for a dark terminal: a black band with dim text on a white screen.
		terminal?.foregroundColor = colorMap.terminalForeground
		terminal?.backgroundColor = colorMap.terminalBackground

		powerStateChanged()
		terminalQueue.async {
			// Rows are only rebuilt when their content hash moves. The look changed, not the content.
			self.stringSupplier.hashSalt &+= 1
			self.terminal?.refresh(startRow: 0, endRow: self.terminal?.rows ?? 0)
		}
	}

	@objc private func powerStateChanged() {
		let preferences = Preferences.shared
		if #available(macOS 12, *),
			 ProcessInfo.processInfo.isLowPowerModeEnabled && preferences.reduceRefreshRateInLPM {
			refreshRate = 15
		} else {
			let currentRate = UIDevice.current.batteryState == .unplugged ? preferences.refreshRateOnBattery : preferences.refreshRateOnAC
			refreshRate = TimeInterval(min(currentRate, UIScreen.main.maximumFramesPerSecond))
		}
		if isVisible {
			startUpdateTimer(fps: refreshRate)
		}
	}

	public func windowDidEnterBackground() {
		activityController.applicationDidChangeForeground(false)
		// Throttle the update timer to save battery. On iPhone, we shouldn’t be visible at all in this
		// case, so throttle right down to once per second so we can maintain the dirty bit.
		startUpdateTimer(fps: UIApplication.shared.supportsMultipleScenes ? 10 : 1)
		isWindowVisible = false
	}

	public func windowWillEnterForeground() {
		activityController.applicationDidChangeForeground(true)
		// Go back to full speed.
		isWindowVisible = true
		if isVisible {
			startUpdateTimer(fps: refreshRate)
		}
	}

	@objc private func appWillResignActive() {
		stopUpdatingTimer()
		isWindowVisible = false
	}

	@objc private func appDidBecomeActive() {
		startUpdateTimer(fps: refreshRate)
		isWindowVisible = true
	}

	public func terminalWillAppear() {
		// Start updating again.
		startUpdateTimer(fps: refreshRate)
		isTabVisible = true
	}

	public func terminalWillDisappear() {
		// Not visible, so throttle right down to once per second so we can maintain the dirty bit.
		startUpdateTimer(fps: 1)
		isTabVisible = false
	}

	/// Sets the base refresh rate. Lifecycle and power changes go through here, and always win over
	/// the idle heuristic — otherwise a stale throttle would survive backgrounding and leave the
	/// terminal stuck at the wrong rate.
	private func startUpdateTimer(fps: TimeInterval) {
		terminalQueue.async {
			self.idleFrames = 0
			self.isIdleThrottled = false
		}
		setUpdateTimer(fps: fps)
	}

	/// Stands between the display link and the controller, so the link doesn't keep it alive.
	///
	/// `CADisplayLink` retains its target, and this controller's `deinit` is what invalidates the
	/// link — which it can never do while the link is holding it. With the target retained, closing a
	/// tab released the view controller and nothing else: the shell went on running, and the link went
	/// on firing at full rate for a terminal nobody could see, until the app happened to go inactive.
	private final class DisplayLinkTarget: NSObject {
		weak var controller: TerminalController?

		@objc func fire() {
			controller?.updateTimerFired()
		}
	}

	private lazy var displayLinkTarget: DisplayLinkTarget = {
		let target = DisplayLinkTarget()
		target.controller = self
		return target
	}()

	private func setUpdateTimer(fps: TimeInterval) {
		appliedRefreshRate = fps
		updateTimer?.invalidate()
		updateTimer = CADisplayLink(target: displayLinkTarget, selector: #selector(DisplayLinkTarget.fire))
		updateTimer?.preferredFramesPerSecond = Int(fps)
		updateTimer?.add(to: .main, forMode: .default)
	}

	/// Switches between the full refresh rate and the idle rate. Called from `terminalQueue` only on
	/// transitions, so an idle terminal isn’t hopping to the main queue every frame.
	private func applyAdaptiveRate(idle: Bool) {
		DispatchQueue.main.async {
			// If we’re backgrounded or the tab is hidden, whatever throttle those paths applied wins.
			guard self.isVisible else {
				return
			}
			let fps = idle ? Self.idleRefreshRate : self.refreshRate
			if fps != self.appliedRefreshRate {
				self.setUpdateTimer(fps: fps)
			}
		}
	}

	private func stopUpdatingTimer() {
		updateTimer?.invalidate()
		updateTimer = nil
	}

	// MARK: - Sub Process

	/// Directory the shell starts in. Set before `startSubProcess()`.
	public var initialDirectory: String?

	/// Command run once the shell is up. Set before `startSubProcess()`.
	///
	/// It’s written on the shell’s first output rather than immediately, because writing to the pty
	/// before the shell has taken over the tty gets the bytes echoed by the tty itself, and then
	/// echoed *again* when zsh starts and redisplays its line buffer — the same command appears
	/// twice.
	public var initialCommand: String?
	private var hasFlushedInitialCommand = false

	/// Puts a long-running agent on the Dynamic Island once the app is backgrounded.
	public let activityController = TerminalActivityController()

	/// Whether an agent CLI has been run in this terminal.
	///
	/// What decides if the session is worth keeping across a restart. A shell someone ran `ls` in has
	/// nothing to come back to; an agent conversation is the whole reason the app remembers anything.
	public private(set) var hasRunAgent = false

	/// What the user has typed since the last return, so the command can be recognised when they run
	/// it. Reading it back off the screen would mean parsing the prompt, which every shell draws
	/// differently.
	private var pendingCommandLine = ""

	/// The project this terminal was opened in, for the activity to name. The directory's own name,
	/// because that is what the project is called.
	private var activityProjectName: String? {
		guard let directory = initialDirectory, !directory.isEmpty else {
			return nil
		}
		return (directory as NSString).lastPathComponent
	}


	public func startSubProcess() throws {
		subProcess = SubProcess()
		subProcess!.delegate = self
		// Hand the pty its real size before the shell exists, rather than opening at the 80×25 default
		// and resizing after. A resize only reaches the shell as SIGWINCH, and at startup that races
		// the child claiming its controlling terminal — lose the race and the shell keeps believing
		// it has 80 columns forever, which is what left zsh’s `%` end-of-line marker on every prompt
		// and mangled every line long enough to wrap.
		if let screenSize = screenSize {
			subProcess!.screenSize = screenSize
		}
		processLaunchDate = Date()
		do {
			try subProcess!.start(initialDirectory: initialDirectory)
		} catch {
			subProcessFailureError = error
			throw error
		}
	}

	public func stopSubProcess() throws {
		try subProcess!.stop()
		stopUpdatingTimer()
	}

	/// Whether the shell is at its prompt, as opposed to running something that has the terminal.
	public var isShellInForeground: Bool {
		subProcess?.isShellInForeground ?? false
	}

	/// The last line the terminal has anything on, for the island to report.
	///
	/// Read from the buffer rather than from the bytes that just arrived: output turns up in chunks
	/// that cut across lines, and half a line is not something worth putting on a lock screen. Called
	/// on `terminalQueue`, which is the only queue allowed to touch the buffer.
	private func lastPrintedLine() -> String? {
		guard let terminal = terminal else {
			return nil
		}
		let bottom = terminal.getTopVisibleRow() + terminal.rows - 1
		for row in stride(from: bottom, through: max(0, bottom - 40), by: -1) {
			guard let line = stringSupplier.line(atRow: row) else {
				continue
			}
			var text = ""
			for column in 0..<terminal.cols {
				let character = line[column].getCharacter()
				text.append(character == "\0" ? " " : character)
			}
			let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
			if !trimmed.isEmpty {
				return trimmed
			}
		}
		return nil
	}

	// MARK: - Terminal

	/// Past this much unfed output the buffer is fed at once rather than at the next frame.
	///
	/// The frame is what normally feeds it, and a hidden tab draws one frame a second. A program that
	/// prints as fast as the pty allows could put tens of megabytes into the buffer between two of
	/// those, all of it held in memory and all of it parsed in one go when the frame came. Feeding
	/// early bounds both.
	private static let readBufferFeedThreshold = 1024 * 1024

	public func readInputStream(_ data: [UTF8Char]) {
		terminalQueue.async {
			self.readBuffer += data
			if self.readBuffer.count >= Self.readBufferFeedThreshold {
				self.terminal?.feed(byteArray: self.readBuffer)
				self.readBuffer.removeAll(keepingCapacity: true)
			}

			self.scrollbackCapture.append(data)
			// A busy command can produce hundreds of chunks before the main queue gets a turn. Activity
			// tracking only needs the most recent time, so keep at most one main-thread update pending.
			if !self.activityOutputUpdatePending {
				self.activityOutputUpdatePending = true
				DispatchQueue.main.async {
					self.activityController.didReceiveOutput()
					self.terminalQueue.async {
						self.activityOutputUpdatePending = false
					}
				}
			}

			// Come back up to speed now rather than waiting up to a frame at the idle rate, so the
			// first character after a pause isn’t delayed.
			if self.isIdleThrottled {
				self.isIdleThrottled = false
				self.idleFrames = 0
				self.applyAdaptiveRate(idle: false)
			}
		}
	}

	private func readInputStream(_ data: Data) {
		readInputStream([UTF8Char](data))
	}

	/// The captured output tail, for persisting. Synchronous so the caller (going to the background)
	/// gets a consistent snapshot before it hands off.
	public func snapshotScrollback() -> Data {
		terminalQueue.sync { scrollbackCapture.data }
	}

	/// Replay previously-saved output before the live shell starts, reconstructing the last visual
	/// state, and prime the capture buffer so the next save still carries this history.
	/// True while saved output is being fed back, so the emulator's replies go nowhere.
	private var isSeedingScrollback = false

	public func seedScrollback(_ data: Data) {
		guard !data.isEmpty else {
			return
		}
		// Bells stripped before replaying. The saved bytes are a recording of the session, and every
		// BEL the shell rang during it is in there — feeding them back rang the lot on launch, for
		// things that happened yesterday. Replaying is reconstructing what the screen looked like, not
		// making it all happen again.
		let replay = [UTF8Char](data).filter { $0 != 0x07 } + [UInt8]("\r\n".utf8)
		terminalQueue.sync {
			self.isSeedingScrollback = true
			defer { self.isSeedingScrollback = false }
			// Feed synchronously while the guard is active. Enqueuing into readBuffer and clearing the
			// guard first lets the emulator's cursor/colour replies escape into the new shell.
			self.terminal?.feed(byteArray: replay)
			self.scrollbackCapture = ByteTailBuffer(capacity: Self.scrollbackCaptureCap)
			self.scrollbackCapture.append(replay)
		}
	}

	public func write(_ data: [UTF8Char]) {
		if Thread.isMainThread {
			noteTypedInput(data)
		} else {
			DispatchQueue.main.async {
				self.noteTypedInput(data)
			}
		}
		writeRaw(data)
	}

	/// Device replies and transfer payloads go to the pty without pretending the user typed them.
	internal func writeRaw(_ data: [UTF8Char]) {
		subProcess?.write(data: data)
	}

	/// Builds up the command line as it's typed, and hands it over on return.
	///
	/// Only what we send to the pty, which is exactly what the user typed — output echoed back has
	/// already been through the shell's line editing and can't be told apart from a program's own
	/// output.
	private func noteTypedInput(_ data: [UTF8Char]) {
		for byte in data {
			switch byte {
			case 0x0D, 0x0A:
				let line = pendingCommandLine.trimmingCharacters(in: .whitespaces)
				pendingCommandLine = ""
				if !line.isEmpty {
					if TerminalActivityController.watchedName(in: line) != nil {
						hasRunAgent = true
					}
					activityController.commandDidStart(line, project: activityProjectName)
				}
			case 0x7F, 0x08:
				if !pendingCommandLine.isEmpty {
					pendingCommandLine.removeLast()
				}
			case 0x03, 0x04:
				// ^C and ^D end whatever is running, and abandon the line being typed.
				pendingCommandLine = ""
				activityController.commandDidFinish()
			case 0x20...0x7E:
				pendingCommandLine.append(Character(UnicodeScalar(byte)))
			default:
				break
			}
		}
	}

	public func write(_ data: Data) {
		write([UTF8Char](data))
	}

	@objc private func updateTimerFired() {
		terminalQueue.async {
			if !self.readBuffer.isEmpty {
				self.terminal?.feed(byteArray: self.readBuffer)
				// Keeping the capacity: the next frame's output is about the same size as this one's, and
				// giving the storage back only to ask for it again is a free allocation per frame.
				self.readBuffer.removeAll(keepingCapacity: true)
			}

			guard let terminal = self.terminal else {
				return
			}
			// Positive: that many lines fell off the top of a full scrollback since last frame, and every
			// buffer row now holds what the row after it held. Negative: the terminal was reset.
			let previousOffset = self.rowOffset
			self.updateRowOffset(terminal)
			let droppedRows = self.rowOffset - previousOffset

			let scrollbackRows = terminal.getTopVisibleRow()
			var cursorLocation = terminal.getCursorLocation()
			cursorLocation.y += scrollbackRows

			let updateRange = terminal.getScrollInvariantUpdateRange() ?? (0, 0)
			if updateRange == (0, 0) && cursorLocation == self.lastCursorLocation && droppedRows == 0 {
				// Nothing changed, nothing to do. Once we’ve been idle long enough, throttle the display
				// link — an idle terminal has no reason to wake the CPU 60 times a second.
				self.idleFrames += 1
				if self.idleFrames >= Self.idleFrameThreshold && !self.isIdleThrottled {
					self.isIdleThrottled = true
					self.applyAdaptiveRate(idle: true)
				}
				return
			}

			self.idleFrames = 0
			if self.isIdleThrottled {
				self.isIdleThrottled = false
				self.applyAdaptiveRate(idle: false)
			}

			terminal.clearUpdateRange()

			let scrollInvariantRows = scrollbackRows + terminal.rows

			// Keep exactly as many lines as exist, no more and no fewer.
			//
			// Trimming used to start one line early, at `scrollInvariantRows - 1`, and growing used to
			// overshoot by one, so every frame threw away a line that was still on screen and appended a
			// blank in its place. The blank only got drawn again if the terminal happened to report that
			// row as changed, so a line that had finished changing — the one you just filled up, the
			// moment the next one wrapped underneath it — stayed blank.
			// Big enough for everything either source knows about, and never smaller.
			//
			// Sizing strictly to `scrollInvariantRows` looks right and is not: it's derived from
			// `getTopVisibleRow()`, which reports the viewport rather than the whole buffer, and a
			// redraw that momentarily reports zero would trim the scrollback out of the array for good
			// — later frames only rewrite rows that changed, so nothing ever puts it back. Growing to
			// fit the update range as well costs a few rows that may turn out to be empty; getting the
			// trim wrong costs the user their screen.
			// Rows are kept lined up with the buffer. When lines fall off the top, the same number come off
			// the front here — the rows that survive keep their content, only their index moves — and the
			// delegate is told to do the same. A reset starts over.
			var droppedFromTop = 0
			if droppedRows < 0 {
				self.lines.removeAll(keepingCapacity: true)
				self.lineHashes.removeAll(keepingCapacity: true)
				self.sentLineCount = 0
			} else if droppedRows > 0 {
				droppedFromTop = min(droppedRows, self.lines.count)
				self.lines.removeFirst(droppedFromTop)
				self.lineHashes.removeFirst(droppedFromTop)
				self.sentLineCount = max(0, self.sentLineCount - droppedFromTop)
			}

			let neededCount = max(scrollInvariantRows, updateRange.endY + 1)
			if self.lines.count > neededCount {
				self.lines.removeSubrange(neededCount...)
				self.lineHashes.removeSubrange(neededCount...)
			}
			// Filled from the terminal as they're added rather than left as placeholders. A row that
			// was appended blank only gets drawn if some later frame happens to name it as changed, and
			// a line that has finished changing never is — which is what left gaps in the output.
			var changedRows = Set<Int>()
			while self.lines.count < neededCount {
				let row = self.lines.count
				changedRows.insert(row)
				self.lineHashes.append(self.stringSupplier.contentHash(scrollInvariantRow: row))
				self.lines.append(TerminalLine(view: self.stringSupplier.attributedString(forScrollInvariantRow: row)))
			}

			// Update lines that changed, clamped to the rows that still exist. Built by intersection
			// rather than by clamping the ends into a range literal: once the range names only rows that
			// are gone, the clamped start passes the clamped end, and `a...b` with a > b traps.
			let existingRows = 0..<neededCount
			var linesToUpdate = updateRange == (0, 0)
				? Set<Int>()
				: Set((updateRange.startY...max(updateRange.startY, updateRange.endY)).filter(existingRows.contains))
			if cursorLocation != self.lastCursorLocation {
				if existingRows.contains(cursorLocation.y) {
					linesToUpdate.insert(cursorLocation.y)
				}
				if existingRows.contains(self.lastCursorLocation.y) {
					linesToUpdate.insert(self.lastCursorLocation.y)
				}
			}
			if droppedRows > 0 {
				// The update range was recorded in buffer rows as they were at the time, and every line
				// dropped since then has moved that content up a row. Widening it downwards by the drop
				// covers wherever it ended up; redrawing the screen covers the rows the scroll itself moved
				// into view.
				if updateRange != (0, 0) {
					let widenedStart = max(0, updateRange.startY - droppedRows)
					linesToUpdate.formUnion((widenedStart..<updateRange.startY).filter(existingRows.contains))
				}
				linesToUpdate.formUnion((scrollbackRows..<min(neededCount, scrollbackRows + terminal.rows)))
			}

			for i in linesToUpdate {
				// Only if it would come out different. The terminal's own idea of what changed is coarse —
				// after a scroll it is the whole screen — and a row rebuilt to look the same still costs a
				// cell on the main thread.
				let hash = self.stringSupplier.contentHash(scrollInvariantRow: i)
				guard hash != self.lineHashes[i] else {
					continue
				}
				self.lineHashes[i] = hash
				changedRows.insert(i)
				self.lines[i] = TerminalLine(view: self.stringSupplier.attributedString(forScrollInvariantRow: i))
			}

			self.lastCursorLocation = cursorLocation

			// Trailing blank rows aren't handed over. The array is sized to the whole buffer — a full
			// screen, plus whatever the update range asked for — so a terminal showing one line still
			// produced a screen's worth of empty rows below it. That made the content taller than the
			// view, which let it scroll, which is how the one line that mattered ended up above the top
			// edge without the user having typed anything.
			var visibleCount = self.lines.count
			while visibleCount > 0, self.stringSupplier.isBlank(scrollInvariantRow: visibleCount - 1) {
				visibleCount -= 1
			}

			// What crosses to the main thread: the rows that changed and are still visible, plus every
			// row the delegate has never had. The second set is what makes this safe — a row can only
			// go from beyond the visible count to inside it when a later row fills in, and by then it is
			// past what was last sent, so it goes over whether or not it changed this frame.
			if visibleCount > self.sentLineCount {
				changedRows.formUnion(self.sentLineCount..<visibleCount)
			}
			let changes = changedRows.filter { $0 < visibleCount }.sorted().map {
				TerminalLineChange(row: $0, line: self.lines[$0])
			}
			self.sentLineCount = visibleCount
			DispatchQueue.main.async {
				self.delegate?.refresh(droppedFromTop: droppedFromTop, lineCount: visibleCount, changes: changes)

				if !self.isVisible && !self.isDirty {
					self.isDirty = true
				}
			}
		}
	}

	/// Sends every row again on the next frame.
	///
	/// For a delegate that finds itself holding fewer rows than a change is addressed to: the only way
	/// that happens is the two sides having lost step, and the fix is a fresh start rather than a
	/// guess at which rows are missing.
	public func resendAllLines() {
		terminalQueue.async {
			self.sentLineCount = 0
			// Marks the screen changed, so a frame goes out even if nothing else is happening.
			self.terminal?.refresh(startRow: 0, endRow: self.terminal?.rows ?? 0)
		}
	}

	public func clearTerminal() {
		// Same reason as `updateScreenSize()`: resetting reallocates the buffers, so it can’t run on
		// the main thread while `terminalQueue` is feeding them. Queued first, so the redraw the nudge
		// below provokes arrives after it.
		terminalQueue.async {
			self.terminal?.resetToInitialState()
			// The saved tail goes with it. Clearing is often done to get something off the screen, and
			// a capture that still held it would put it straight back at the next launch.
			self.scrollbackCapture = ByteTailBuffer(capacity: Self.scrollbackCaptureCap)
		}

		// To trigger a redraw, update the screen size, then update it back — on the main thread, which
		// is where `subProcess` lives. Widening rather than narrowing: `cols` is unsigned, so
		// subtracting from a zero-width screen would trap.
		guard let screenSize = screenSize else {
			return
		}
		var newScreenSize = screenSize
		newScreenSize.cols += 1
		subProcess?.screenSize = newScreenSize

		DispatchQueue.main.async {
			self.subProcess?.screenSize = screenSize
		}
	}

	private func updateScreenSize() {
		guard let screenSize = screenSize else {
			return
		}

		// `subProcess` and `subProcessFailureError` are created and written on the main thread, so they
		// are read here rather than inside the block below — reaching for them from `terminalQueue`
		// races with `startSubProcess()`.
		subProcess?.screenSize = screenSize
		let failureError = subProcessFailureError

		// The terminal itself goes to `terminalQueue`, because resizing reallocates its buffers and
		// this is called straight from the main thread — layout, rotation and the keyboard all land
		// here. Reallocating underneath the `feed` running on `terminalQueue` corrupts the buffer it
		// is writing into.
		terminalQueue.async {
			guard let terminal = self.terminal,
						screenSize.cols != terminal.cols || screenSize.rows != terminal.rows else {
				return
			}

			terminal.resize(cols: Int(screenSize.cols),
											rows: Int(screenSize.rows))

			if let error = failureError {
				let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
				self.readInputStream(ColorBars.render(screenSize: screenSize, message: message))
			}
		}
	}

	private func updateTitle() {
		var newTitle: String? = nil
		if let title = title,
			 !title.isEmpty {
			newTitle = title
		}
		if let hostname = hostname {
			let user = self.user == NSUserName() ? nil : self.user
			let cleanedHostname = hostname.replacingOccurrences(of: #"\.local$"#, with: "", options: .regularExpression, range: hostname.startIndex..<hostname.endIndex)
			let hostString: String
			if isLocalhost {
				hostString = user ?? ""
			} else {
				hostString = "\(user ?? "")\(user == nil ? "" : "@")\(cleanedHostname)"
			}
			if !hostString.isEmpty {
				newTitle = "[\(hostString)] \(newTitle ?? "")"
			}
		}
		self.delegate?.titleDidChange(newTitle,
																	isDirty: isDirty,
																	hasBell: hasBell)
	}

	// MARK: - Reading the buffer

	private struct TextRow {
		var text: String
		var usedColumns: Int
	}

	/// One entry per terminal cell, so an index into the result is a column. The continuation cell
	/// of a wide character (CJK, emoji) comes back as nil rather than a stray space.
	private func cells(atScrollInvariantRow row: Int) -> [Character?] {
		guard let terminal = terminal,
					let line = terminal.getScrollInvariantLine(row: row) else {
			return []
		}
		return (0..<min(line.count, terminal.cols)).map { i -> Character? in
			let data = line[i]
			if data.width == 0 {
				return nil
			}
			let character = data.getCharacter()
			return character == "\0" ? " " : character
		}
	}

	private func textRow(atScrollInvariantRow row: Int) -> TextRow? {
		let cells = cells(atScrollInvariantRow: row)
		guard !cells.isEmpty else {
			return nil
		}
		let usedColumns = cells.lastIndex(where: { $0 == nil || $0 != " " }).map { $0 + 1 } ?? 0
		var text = String(cells.compactMap { $0 })
		while text.last == " " {
			text.removeLast()
		}
		return TextRow(text: text, usedColumns: usedColumns)
	}

	private static func join(_ rows: [TextRow], columns: Int) -> (text: String, starts: [Int]) {
		var text = ""
		var starts = [Int]()
		for (index, row) in rows.enumerated() {
			if index > 0 && rows[index - 1].usedColumns < columns {
				text.append("\n")
			}
			starts.append(text.count)
			text.append(row.text)
		}
		return (text, starts)
	}

	/// Text around a cell with terminal soft-wrapped rows joined, plus the tapped character offset.
	/// SwiftTerm keeps its exact `isWrapped` flag internal, so a full row is the best public signal.
	public func contiguousText(atScrollInvariantRow row: Int,
													column: Int) -> (text: String, characterOffset: Int)? {
		guard let terminal = terminal,
					let tappedRow = textRow(atScrollInvariantRow: row),
					column >= 0,
					column < terminal.cols else {
			return nil
		}

		var firstRow = row
		// ponytail: 64 rows bounds detector work; raise it only for links over several thousand chars.
		for _ in 0..<64 {
			guard let previous = textRow(atScrollInvariantRow: firstRow - 1),
						previous.usedColumns == terminal.cols else {
				break
			}
			firstRow -= 1
		}

		var lastRow = row
		for _ in 0..<64 {
			guard let current = textRow(atScrollInvariantRow: lastRow),
						current.usedColumns == terminal.cols,
						textRow(atScrollInvariantRow: lastRow + 1) != nil else {
				break
			}
			lastRow += 1
		}

		let rows = (firstRow...lastRow).compactMap(textRow(atScrollInvariantRow:))
		let joined = Self.join(rows, columns: terminal.cols)
		let tappedIndex = row - firstRow
		guard tappedIndex >= 0,
				tappedIndex < joined.starts.count else {
			return nil
		}

		let tappedCells = cells(atScrollInvariantRow: row)
		var tappedColumn = min(column, tappedCells.count - 1)
		while tappedColumn > 0 && tappedCells[tappedColumn] == nil {
			tappedColumn -= 1
		}
		let localOffset = String(tappedCells[..<tappedColumn].compactMap { $0 }).count
		let offset = joined.starts[tappedIndex] + localOffset
		guard offset < joined.text.count,
				!tappedRow.text.isEmpty else {
			return nil
		}
		return (joined.text, offset)
	}

	/// The selected text, ready for the pasteboard. Trailing blanks are trimmed per line, and a wide
	/// character contributes one character rather than one per cell it occupies.
	public func text(in selection: TerminalSelection) -> String {
		guard let terminal = terminal else {
			return ""
		}
		let start = selection.start
		let end = selection.end
		guard start.row <= end.row else {
			return ""
		}
		let rows = (start.row...end.row).compactMap { row -> TextRow? in
			guard let range = selection.columnRange(forRow: row, cols: terminal.cols) else {
				return nil
			}
			let cells = cells(atScrollInvariantRow: row)
			let usedColumns = cells.lastIndex(where: { $0 == nil || $0 != " " }).map { $0 + 1 } ?? 0
			let lower = min(range.lowerBound, cells.count)
			let upper = min(range.upperBound, cells.count)
			var line = lower < upper ? String(cells[lower..<upper].compactMap { $0 }) : ""
			while line.last == " " {
				line.removeLast()
			}
			return TextRow(text: line, usedColumns: usedColumns)
		}
		return Self.join(rows, columns: terminal.cols).text
	}

	/// Columns of the “word” around `column`, so press-and-hold grabs something useful in one go.
	/// Words break on whitespace only, so paths and URLs come out whole rather than split on dots
	/// and slashes.
	public func wordRange(atScrollInvariantRow row: Int, column: Int) -> Range<Int>? {
		let cells = cells(atScrollInvariantRow: row)
		guard column >= 0,
					column < cells.count,
					// nil is a wide character’s continuation cell, which is part of a word, not a break.
					!(cells[column]?.isWhitespace ?? false) else {
			return nil
		}
		var lower = column
		while lower > 0 && !(cells[lower - 1]?.isWhitespace ?? false) {
			lower -= 1
		}
		var upper = column
		while upper < cells.count && !(cells[upper]?.isWhitespace ?? false) {
			upper += 1
		}
		return lower < upper ? lower..<upper : nil
	}

	// MARK: - Object lifecycle

	deinit {
		updateTimer?.invalidate()
		// Whatever the island was showing for this terminal is over: the tab it belonged to is gone.
		activityController.commandDidFinish()
	}

}

extension TerminalController: TerminalDelegate {

	public func isProcessTrusted(source: Terminal) -> Bool { isLocalhost }

	public func send(source: Terminal, data: ArraySlice<UInt8>) {
		// Swallowed while replaying saved output. These are the emulator's answers to things the
		// program asked — where the cursor is, what colour the foreground is — and a recording is full
		// of those questions. Answering them puts the reply into the shell's input, which is how a
		// restored tab came back with `;1R10;rgb:8a3d/…` typed at its prompt. Nothing is waiting for
		// an answer; the program that asked finished yesterday.
		guard !isSeedingScrollback else {
			return
		}
		terminalQueue.async {
			self.writeRaw([UTF8Char](data))
		}
	}

	public func bell(source: Terminal) {
		DispatchQueue.main.async {
			// Throttle bell so it only rings a maximum of once a second.
			if self.lastBellDate == nil || self.lastBellDate! < Date(timeIntervalSinceNow: -1) {
				self.lastBellDate = Date()
				self.delegate?.activateBell()
			}

			if !self.isVisible && !self.hasBell {
				self.hasBell = true
			}
		}
	}

	public func showCursor(source: Terminal) {
		stringSupplier.cursorVisible = true
	}

	public func hideCursor(source: Terminal) {
		stringSupplier.cursorVisible = false
	}

	public func setTerminalTitle(source: Terminal, title: String) {
		self.title = title
		DispatchQueue.main.async {
			self.updateTitle()
		}
	}

	public func hostCurrentDirectoryUpdated(source: Terminal) {
		hostCurrentDocumentUpdated(source: source)
	}

	public func hostCurrentDocumentUpdated(source: Terminal) {
		let workingDirectory = source.hostCurrentDirectory
		let filePath = source.hostCurrentDocument ?? workingDirectory
		currentWorkingDirectory = nil
		currentFile = nil

		if let workingDirectory = workingDirectory,
			 let url = URL(string: workingDirectory),
			 url.isFileURL {
			hostname = url.host
			if isLocalhost {
				currentWorkingDirectory = url
			}
		}

		if let filePath = filePath,
			 let url = URL(string: filePath),
			 url.isFileURL {
			hostname = url.host
			if isLocalhost {
				currentFile = url
			}
		}

		DispatchQueue.main.async {
			self.delegate?.currentFileDidChange(self.currentFile ?? self.currentWorkingDirectory,
																					inWorkingDirectory: self.currentWorkingDirectory)
		}
	}

}

extension TerminalController: TerminalInputProtocol {

	public var applicationCursor: Bool { terminal?.applicationCursor ?? false }

	public var bracketedPasteMode: Bool { terminal?.bracketedPasteMode ?? false }

	public func receiveKeyboardInput(data: [UTF8Char]) {
		write(data)
	}

}

extension TerminalController: SubProcessDelegate {

	func subProcessDidConnect() {
		// Yay
	}

	func subProcess(didReceiveData data: [UTF8Char]) {
		// Simply forward the input stream down the VT100 processor. When it notices changes to the
		// screen, it should invoke our refresh delegate below.
		readInputStream(data)

		if !hasFlushedInitialCommand {
			hasFlushedInitialCommand = true
			subProcess?.notifyWindowSizeChanged()
			if let command = initialCommand {
				write(Array(command.utf8) + EscapeSequences.return)
			}
			initialCommand = nil
		}
	}

	func subProcess(didDisconnectWithError error: Error?) {
		if let error = error {
			delegate?.didReceiveError(error: error)
		} else {
			// This can be the user just typing an EOF (^D) to end the terminal session. However, it
			// can also happen because the process crashed for some reason. If it seems like the shell
			// exited gracefully, just close the tab.
			if (processLaunchDate ?? Date()) < Date(timeIntervalSinceNow: -3) {
				delegate?.close()
			}
		}

		// Write the termination message to the terminal.
		let processCompleted = String.localize("PROCESS_COMPLETED_TITLE", comment: "Title displayed when the terminal’s process has ended.")
		let cols = Int(subProcess?.screenSize.cols ?? 0)
		let messageLength = processCompleted.count + 2
		let divider = String(repeating: "═", count: max((cols - messageLength) / 2, 0))
		let message = "\r\n\u{1b}[0;31m\(divider) \u{1b}[1;31m\(processCompleted)\u{1b}[0;31m \(divider)\u{1b}[m\r\n"
		readInputStream(message.data(using: .utf8)!)

		updateTimer?.invalidate()
		updateTimer = nil
		updateTimerFired()
	}

	func subProcess(didReceiveError error: Error) {
		delegate?.didReceiveError(error: error)
	}

}
