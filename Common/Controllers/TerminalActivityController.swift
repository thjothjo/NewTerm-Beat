//
//  TerminalActivityController.swift
//  NewTerm Common
//

import Foundation
import os.log
#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// Puts a long-running command on the Dynamic Island while the app is in the background.
///
/// The point is the case the app was built for: an agent CLI left working on something. Once the app
/// is backgrounded there's nothing on screen to say whether it's still going, still thinking, or
/// finished ten minutes ago — so this says so without having to open the app.
///
/// Deliberately only while backgrounded. In the foreground the terminal itself is the answer, and an
/// island that duplicates what's already on screen is noise.
public final class TerminalActivityController {

	/// Commands worth surfacing. A `ls` finishing isn't news; an agent working for ten minutes is.
	private static let watchedCommands = ["claude", "codex", "grok", "gemini", "aider"]

	/// Quiet for this long and the command is treated as waiting rather than working.
	private static let quietThreshold: TimeInterval = 6

	/// Nothing changes on screen faster than this, and each update costs a system round trip.
	private static let minimumUpdateInterval: TimeInterval = 2

	private static let logger = Logger(subsystem: "ws.hbang.Terminal", category: "LiveActivity")

	public init() {}

	/// The command being watched, if any, and when it started.
	private var command: String?
	private var project: String?
	private var startedAt = Date()
	private var lastOutputAt = Date()
	private var lastUpdateAt = Date.distantPast
	private var isForeground = true
	private var quietTimer: Timer?
	/// Steps on every update, so the island has something to draw motion from.
	private var tick = 0

	#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
	@available(iOS 16.2, *)
	private var activity: Activity<TerminalActivityAttributes>? {
		get { _activity as? Activity<TerminalActivityAttributes> }
		set { _activity = newValue }
	}
	/// Stored untyped because a stored property can't carry an availability annotation.
	private var _activity: Any?
	#endif

	// MARK: - Input

	/// The command line the user just ran, as typed.
	public func commandDidStart(_ line: String, project: String?) {
		guard let name = Self.watchedName(in: line) else {
			// Something else started, so whatever we were watching is no longer what's running.
			commandDidFinish()
			return
		}
		command = name
		self.project = project
		detail = ""
		startedAt = Date()
		lastOutputAt = Date()
		startIfNeeded()
	}

	/// Output timing tells working from waiting apart, and the last line says what it is doing.
	///
	/// The line does reach the lock screen, which is a deliberate trade: it is the whole point of
	/// glancing at the phone, and it is why the island can be switched off in Settings. Anything a
	/// program prints back — a token, a password it echoed — would go with it.
	public func didReceiveOutput() {
		guard command != nil else {
			return
		}
		lastOutputAt = Date()
		update(state: .running)
	}

	/// Asked for the last line the terminal shows, at the moment one is about to be drawn.
	///
	/// Pulled rather than pushed: pushing it meant the terminal built the line on every chunk of
	/// output whether or not there was an island to put it on — which, in the foreground with nothing
	/// being watched, was every time. Now it is built only when an update is really going out, which
	/// the rate limit holds to one every couple of seconds.
	public var lastLineProvider: (() -> String?)?

	/// What the agent last printed, cut down to something that fits a lock screen row.
	private var detail = ""

	private func refreshDetail() {
		if let line = lastLineProvider?() {
			detail = Self.summarised(line)
		}
	}

	private static func summarised(_ line: String) -> String {
		let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.count > 60 else {
			return trimmed
		}
		return String(trimmed.prefix(60)) + "…"
	}

	/// The shell is back at a prompt, or the terminal closed.
	public func commandDidFinish() {
		guard command != nil else {
			return
		}
		update(state: .finished, force: true)
		command = nil
		quietTimer?.invalidate()
		quietTimer = nil
		end(after: 3)
	}

	/// Only backgrounded does the island have a job to do.
	public func applicationDidChangeForeground(_ foreground: Bool) {
		isForeground = foreground
		if foreground {
			endImmediately()
		} else {
			startIfNeeded()
		}
	}

	// MARK: - Activity lifecycle

	private func startIfNeeded() {
		guard !isForeground, let command = command, Preferences.shared.liveActivityEnabled else {
			return
		}
		#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
		guard #available(iOS 16.2, *),
					ActivityAuthorizationInfo().areActivitiesEnabled,
					activity == nil else {
			return
		}
		let attributes = TerminalActivityAttributes(command: command, project: project)
		tick = 0
		refreshDetail()
		let state = TerminalActivityAttributes.ContentState(state: .running,
																						detail: detail,
																												startedAt: startedAt,
																												tick: tick)
		do {
			activity = try Activity.request(attributes: attributes,
																			contentState: state,
																			pushType: nil)
			startQuietTimer()
		} catch {
			// Denied, or too many already running. Not worth surfacing — the terminal still works.
			Self.logger.notice("Couldn’t start Live Activity: \(String(describing: error))")
		}
		#endif
	}

	private func update(state: TerminalActivity.State, force: Bool = false) {
		#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
		guard #available(iOS 16.2, *), let activity = activity else {
			return
		}
		// Rate limited: output arrives a byte at a time, and an update per byte would be thousands a
		// second for a system that draws at most a few.
		guard force || Date().timeIntervalSince(lastUpdateAt) >= Self.minimumUpdateInterval else {
			return
		}
		lastUpdateAt = Date()
		tick &+= 1
		if state == .running {
			refreshDetail()
		}
		let content = TerminalActivityAttributes.ContentState(state: state,
																							detail: detail,
																													startedAt: startedAt,
																													tick: tick)
		Task {
			await activity.update(using: content)
		}
		#endif
	}

	/// Notices the command going quiet, which is what "waiting for you" looks like from out here.
	private func startQuietTimer() {
		quietTimer?.invalidate()
		quietTimer = Timer.scheduledTimer(withTimeInterval: Self.quietThreshold, repeats: true) { [weak self] _ in
			guard let self, self.command != nil else {
				return
			}
			if Date().timeIntervalSince(self.lastOutputAt) >= Self.quietThreshold {
				self.update(state: .waiting, force: true)
			}
		}
	}

	private func end(after delay: TimeInterval) {
		#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
		guard #available(iOS 16.2, *), let activity = activity else {
			return
		}
		self.activity = nil
		Task {
			// Left up briefly on purpose: "it finished" is the one state worth seeing after the fact.
			try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
			await activity.end(dismissalPolicy: .immediate)
		}
		#endif
	}

	private func endImmediately() {
		quietTimer?.invalidate()
		quietTimer = nil
		#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
		guard #available(iOS 16.2, *), let activity = activity else {
			return
		}
		self.activity = nil
		Task {
			await activity.end(dismissalPolicy: .immediate)
		}
		#endif
	}

	// MARK: - Parsing

	/// The watched command a command line runs, if it runs one.
	///
	/// Only the first word, and only after stripping the things people put in front of a command —
	/// otherwise `time codex` or `VAR=1 claude` wouldn't be recognised as the thing they run.
	static func watchedName(in line: String) -> String? {
		var words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
		while let first = words.first,
					first.contains("=") || first == "time" || first == "sudo" || first == "command" {
			words.removeFirst()
		}
		guard let first = words.first else {
			return nil
		}
		let name = (first as NSString).lastPathComponent
		return watchedCommands.contains(name) ? name : nil
	}

}
