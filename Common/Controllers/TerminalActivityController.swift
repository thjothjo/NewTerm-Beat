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
		startedAt = Date()
		lastOutputAt = Date()
		startIfNeeded()
	}

	/// Output timing tells working from waiting apart. The text itself may contain secrets and never
	/// belongs on the lock screen.
	public func didReceiveOutput() {
		guard command != nil else {
			return
		}
		lastOutputAt = Date()
		update(state: .running)
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
		guard !isForeground, let command = command else {
			return
		}
		#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
		guard #available(iOS 16.2, *),
					ActivityAuthorizationInfo().areActivitiesEnabled,
					activity == nil else {
			return
		}
		let attributes = TerminalActivityAttributes(command: command, project: project)
		let state = TerminalActivityAttributes.ContentState(state: .running,
																						detail: "",
																												startedAt: startedAt)
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
		let content = TerminalActivityAttributes.ContentState(state: state,
																							detail: "",
																													startedAt: startedAt)
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
