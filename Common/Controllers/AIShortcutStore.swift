//
//  AIShortcutStore.swift
//  NewTerm Common
//

import Foundation
import os.log

/// One entry in the AI panel: a skill, a persona, or a command to run.
public struct AIShortcut: Codable, Hashable, Identifiable {

	public enum Kind: String, Codable, Hashable, CaseIterable {
		/// Starts an agent CLI.
		case agent
		/// A slash command or skill the agent already knows.
		case skill
		/// A block of instructions that sets how the agent should behave.
		case persona
	}

	public var id: String { "\(kind.rawValue)-\(name)" }

	/// What the key says.
	public var name: String
	/// Exactly what gets typed into the terminal.
	public var command: String
	public var kind: Kind
	/// Whether to press return afterwards. Off for anything you'd want to add to before sending —
	/// which is most things.
	public var send: Bool

	public init(name: String, command: String, kind: Kind, send: Bool = false) {
		self.name = name
		self.command = command
		self.kind = kind
		self.send = send
	}
}

/// The user's own skills and personas, in a file an agent can rewrite.
///
/// JSON on disk rather than a database or a preference, and deliberately so: the whole point is that
/// the agent running in the terminal can read it, understand it and edit it — `cat` the file and the
/// schema is self-describing, write it back and the panel picks the change up. A store only this app
/// could edit would mean asking the user to type personas on a phone keyboard.
public enum AIShortcutStore {

	public static let didChangeNotification = Notification.Name("ws.hbang.Terminal.aiShortcutsDidChange")

	private static let logger = Logger(subsystem: "ws.hbang.Terminal", category: "AIShortcuts")

	/// Against the shell's home, so the path the agent is told about is the path it can open.
	public static var fileURL: URL {
		URL(fileURLWithPath: SubProcess.homeDirectory, isDirectory: true)
			.appendingPathComponent(".newterm/shortcuts.json")
	}

	/// The path as the user would type it, for telling an agent where to look.
	public static var displayPath: String { "~/.newterm/shortcuts.json" }

	// MARK: - Reading

	private struct File: Codable {
		/// Documentation, carried in the file itself. An agent asked to add a persona reads this and
		/// knows the schema without being told.
		var readme: [String]?
		var shortcuts: [AIShortcut]

		enum CodingKeys: String, CodingKey {
			case readme = "_readme"
			case shortcuts
		}
	}

	public static func shortcuts() -> [AIShortcut] {
		guard let data = try? Data(contentsOf: fileURL) else {
			return []
		}
		do {
			return try JSONDecoder().decode(File.self, from: data).shortcuts
		} catch {
			// A file the user or an agent is midway through editing. Showing nothing is better than
			// throwing an error over the keyboard.
			logger.notice("Couldn’t read \(displayPath): \(String(describing: error))")
			return []
		}
	}

	// MARK: - Writing

	public static func save(_ shortcuts: [AIShortcut]) throws {
		try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
																						withIntermediateDirectories: true)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		let file = File(readme: readme, shortcuts: shortcuts)
		try encoder.encode(file).write(to: fileURL, options: .atomic)
		NotificationCenter.default.post(name: didChangeNotification, object: nil)
	}

	public static func add(_ shortcut: AIShortcut) throws {
		var all = shortcuts()
		// Same name and kind replaces rather than duplicates, so an agent re-running "add my reviewer
		// persona" doesn't leave two.
		all.removeAll { $0.name == shortcut.name && $0.kind == shortcut.kind }
		all.append(shortcut)
		try save(all)
	}

	public static func remove(_ shortcut: AIShortcut) throws {
		try save(shortcuts().filter { $0.id != shortcut.id })
	}

	/// Writes a starting file, if there isn't one.
	///
	/// Seeded rather than left empty so the first thing anyone — user or agent — sees when they open
	/// it is a worked example of every field.
	@discardableResult
	public static func createTemplateIfNeeded() -> Bool {
		guard !FileManager.default.fileExists(atPath: fileURL.path) else {
			return false
		}
		let examples = [
			AIShortcut(name: "Reviewer",
								 command: "You are a meticulous code reviewer. Point out real defects only — no style preferences. ",
								 kind: .persona),
			AIShortcut(name: "Explain",
								 command: "Explain what this code does, in plain terms, and name anything that looks wrong. ",
								 kind: .persona)
		]
		do {
			try save(examples)
			return true
		} catch {
			logger.error("Couldn’t create \(displayPath): \(String(describing: error))")
			return false
		}
	}

	/// The command that opens the file for editing in the terminal.
	public static var editCommand: String {
		"${EDITOR:-vi} \(displayPath)"
	}

	private static let readme = [
		"NewTerm AI shortcuts. Edit this file — the keyboard's AI panel reads it.",
		"Each entry: name (the key's label), command (typed into the terminal),",
		"kind (agent | skill | persona), send (true to press return afterwards).",
		"kind=agent starts a CLI, kind=skill is a slash command, kind=persona is",
		"instructions to paste into a running agent.",
		"Installed CLIs and files in ~/.claude and ~/.codex are listed automatically;",
		"this file is only for what you add yourself."
	]
}
