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

public protocol TerminalControllerDelegate: AnyObject {
	func refresh(lines: [AnyView])
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
	private var lines = [AnyView]()

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
	private var scrollbackCapture = [UTF8Char]()

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
		#endif

		let options = TerminalOptions(termName: "xterm-256color",
																	scrollback: 10_000)
		terminal = Terminal(delegate: self, options: options)

		stringSupplier.terminal = terminal

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
		stringSupplier.colorMap = preferences.colorMap
		stringSupplier.fontMetrics = preferences.fontMetrics

		powerStateChanged()
		terminal?.refresh(startRow: 0, endRow: terminal?.rows ?? 0)
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

	private func setUpdateTimer(fps: TimeInterval) {
		appliedRefreshRate = fps
		updateTimer?.invalidate()
		updateTimer = CADisplayLink(target: self, selector: #selector(self.updateTimerFired))
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

	// MARK: - Terminal

	public func readInputStream(_ data: [UTF8Char]) {
		if let text = String(bytes: data, encoding: .utf8) {
			activityController.didReceiveOutput(text)
		}
		terminalQueue.async {
			self.readBuffer += data

			self.scrollbackCapture += data
			if self.scrollbackCapture.count > Self.scrollbackCaptureCap {
				self.scrollbackCapture.removeFirst(self.scrollbackCapture.count - Self.scrollbackCaptureCap)
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
		terminalQueue.sync { Data(scrollbackCapture) }
	}

	/// Replay previously-saved output before the live shell starts, reconstructing the last visual
	/// state, and prime the capture buffer so the next save still carries this history. Feed it through
	/// the normal input path so it renders and re-captures exactly as live output would.
	/// True while saved output is being fed back, so the emulator's replies go nowhere.
	private var isSeedingScrollback = false

	public func seedScrollback(_ data: Data) {
		guard !data.isEmpty else {
			return
		}
		isSeedingScrollback = true
		defer { isSeedingScrollback = false }
		// Bells stripped before replaying. The saved bytes are a recording of the session, and every
		// BEL the shell rang during it is in there — feeding them back rang the lot on launch, for
		// things that happened yesterday. Replaying is reconstructing what the screen looked like, not
		// making it all happen again.
		readInputStream([UTF8Char](data).filter { $0 != 0x07 })
		// A newline so the restored shell's first prompt starts cleanly below the history rather than
		// merged onto its last line.
		readInputStream([UInt8]("\r\n".utf8))
	}

	public func write(_ data: [UTF8Char]) {
		noteTypedInput(data)
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
				self.readBuffer.removeAll()
			}

			guard let terminal = self.terminal else {
				return
			}

			let scrollbackRows = terminal.getTopVisibleRow()
			var cursorLocation = terminal.getCursorLocation()
			cursorLocation.y += scrollbackRows

			let updateRange = terminal.getScrollInvariantUpdateRange() ?? (0, 0)
			if updateRange == (0, 0) && cursorLocation == self.lastCursorLocation {
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
			let neededCount = max(scrollInvariantRows, updateRange.endY + 1)
			if self.lines.count > neededCount {
				self.lines.removeSubrange(neededCount...)
			}
			// Filled from the terminal as they're added rather than left as placeholders. A row that
			// was appended blank only gets drawn if some later frame happens to name it as changed, and
			// a line that has finished changing never is — which is what left gaps in the output.
			while self.lines.count < neededCount {
				self.lines.append(self.stringSupplier.attributedString(forScrollInvariantRow: self.lines.count))
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

			for i in linesToUpdate {
				self.lines[i] = self.stringSupplier.attributedString(forScrollInvariantRow: i)
			}

			self.lastCursorLocation = cursorLocation

			// Snapshotted here, on the queue that owns `lines`. Handing `&self.lines` to the main queue
			// instead let the next frame mutate the array from this queue while the main thread was
			// still reading it — a data race on the array’s storage, with no bound on what it corrupts.
			// The copy is free in practice: the delegate keeps a reference either way, so the write
			// after this already triggered COW.
			let snapshot = self.lines
			DispatchQueue.main.async {
				self.delegate?.refresh(lines: snapshot)

				if !self.isVisible && !self.isDirty {
					self.isDirty = true
				}
			}
		}
	}

	public func clearTerminal() {
		// Same reason as `updateScreenSize()`: resetting reallocates the buffers, so it can’t run on
		// the main thread while `terminalQueue` is feeding them. Queued first, so the redraw the nudge
		// below provokes arrives after it.
		terminalQueue.async {
			self.terminal?.resetToInitialState()
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
			self.write([UTF8Char](data))
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

	public func receiveKeyboardInput(data: [UTF8Char]) {
		// Forward the data from the keyboard directly to the subprocess
		subProcess!.write(data: data)
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
