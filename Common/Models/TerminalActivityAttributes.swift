//
//  TerminalActivityAttributes.swift
//  NewTerm Common
//

import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// What a Live Activity shows about a terminal that's still working while the app is away.
///
/// Shared by the app, which starts and updates the activity, and the widget extension, which draws
/// it. Both sides must agree on this type exactly — it's encoded by one process and decoded by
/// another, so a field added on one side only silently breaks decoding on the other.
public enum TerminalActivity {

	/// What the terminal is doing, as far as we can tell from its output.
	public enum State: String, Codable, Hashable {
		/// Producing output.
		case running
		/// Quiet for a while, and the last thing seen looked like a question.
		case waiting
		/// The command finished.
		case finished
	}
}

#if canImport(ActivityKit) && os(iOS)
@available(iOS 16.2, *)
public struct TerminalActivityAttributes: ActivityAttributes {

	public struct ContentState: Codable, Hashable {
		public var state: TerminalActivity.State
		/// The last line of meaningful output, already trimmed to something that fits.
		public var detail: String
		/// When the command started, so the island can count up without us pushing an update a second.
		public var startedAt: Date

		public init(state: TerminalActivity.State, detail: String, startedAt: Date) {
			self.state = state
			self.detail = detail
			self.startedAt = startedAt
		}
	}

	/// The agent or command being run — `codex`, `claude`, and so on.
	public var command: String
	/// The project it's running in, when it's running in one.
	public var project: String?

	public init(command: String, project: String?) {
		self.command = command
		self.project = project
	}
}
#endif
