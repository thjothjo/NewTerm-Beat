//
//  AICatalog.swift
//  NewTerm Common
//

import Foundation

/// Something the AI panel can type for you.
public struct AICommand: Hashable, Identifiable {
	public enum Kind {
		/// An agent CLI that's installed. Typing its name starts it.
		case cli
		/// A prompt, skill or custom command an agent already knows, invoked with a slash.
		case prompt
	}

	public var id: String { "\(kind)-\(name)" }
	public var name: String
	/// Exactly what gets typed into the terminal.
	public var command: String
	public var kind: Kind
	/// Where it was found, so it's clear which agent a slash command belongs to.
	public var source: String
	/// Whether picking this should clear whatever is already typed. A persona is a setting, not
	/// something you add to what's there.
	public var replacesInput: Bool = false
}

/// The agent CLIs installed on this device, and the prompts they already know.
///
/// Found rather than configured, the same way a project is a directory and an SSH host is a line in
/// a config: installing a CLI is what puts it in the list, and adding a prompt file is what adds the
/// command. Nothing here has a list of its own to fall out of step with what's on disk.
public enum AICatalog {

	/// Posted after the catalogue is rescanned.
	public static let didChangeNotification = Notification.Name("ws.hbang.Terminal.aiCatalogDidChange")

	/// Agent CLIs worth looking for, in the order they're offered.
	private static let knownCLIs = ["claude", "codex", "grok", "gemini", "aider"]

	/// Where prompts live, per agent. A directory of markdown files, each named after the command it
	/// provides, is the shape all of these settled on.
	private static let promptDirectories: [(source: String, path: String, isSkillFolder: Bool)] = [
		("Claude", ".claude/commands", false),
		("Claude", ".claude/skills", true),
		("Codex", ".codex/prompts", false)
	]

	public static func commands() -> [AICommand] {
		// The user's own first: a persona they wrote is more use than the CLI list they already know.
		userShortcuts() + installedCLIs() + prompts()
	}

	private static func userShortcuts() -> [AICommand] {
		AIShortcutStore.shortcuts().map { shortcut in
			AICommand(name: shortcut.name,
								command: shortcut.send ? shortcut.command + "\r" : shortcut.command,
								kind: shortcut.kind == .agent ? .cli : .prompt,
								source: shortcut.kind.sourceLabel,
								replacesInput: shortcut.replacesInput)
		}
	}

	// MARK: - CLIs

	/// The shell's `PATH` isn't ours to read — it belongs to a process that doesn't exist yet — so the
	/// directories a jailbreak actually installs into are checked directly.
	private static var binaryDirectories: [String] {
		let relative = ["/usr/local/bin", "/usr/bin", "/bin", "/opt/homebrew/bin"]
		var directories = [String]()
		for path in relative {
			if let root = SubProcess.jbRoot {
				directories.append(root + path)
			}
			directories.append("/var/jb" + path)
			directories.append(path)
		}
		// Where npm, pipx and uv put things, and where every one of these agents installs by default.
		directories.append((SubProcess.homeDirectory as NSString).appendingPathComponent(".local/bin"))
		return directories
	}

	private static func installedCLIs() -> [AICommand] {
		knownCLIs.compactMap { name in
			let found = binaryDirectories.contains { directory in
				FileManager.default.isExecutableFile(atPath: (directory as NSString).appendingPathComponent(name))
			}
			guard found else {
				return nil
			}
			// No newline: starting an agent is the one thing worth reading over before committing to it.
			return AICommand(name: name, command: name, kind: .cli, source: .localize("Installed"))
		}
	}

	// MARK: - Prompts

	private static func prompts() -> [AICommand] {
		let home = SubProcess.homeDirectory as NSString
		var commands = [AICommand]()
		// Keyed by source as well as name: Claude and Codex can each have a /review, and they are not
		// the same command. Deduping on name alone silently dropped the second.
		var seen = Set<String>()

		for entry in promptDirectories {
			let directory = home.appendingPathComponent(entry.path)
			let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
			for item in contents.sorted() where !item.hasPrefix(".") {
				let name: String
				if entry.isSkillFolder {
					// A skill is a directory holding a SKILL.md; the directory's name is the command.
					var isDirectory: ObjCBool = false
					let path = (directory as NSString).appendingPathComponent(item)
					guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
								isDirectory.boolValue else {
						continue
					}
					name = item
				} else {
					guard (item as NSString).pathExtension == "md" else {
						continue
					}
					name = (item as NSString).deletingPathExtension
				}

				guard seen.insert("\(entry.source)/\(name)").inserted else {
					continue
				}
				// A trailing space, because a slash command is nearly always followed by an argument.
				commands.append(AICommand(name: "/\(name)",
																	command: "/\(name) ",
																	kind: .prompt,
																	source: entry.source))
			}
		}
		return commands
	}
}

private extension AIShortcut.Kind {
	/// What the list shows underneath the name, so a persona isn't mistaken for a command.
	var sourceLabel: String {
		switch self {
		case .agent:   return .localize("Yours")
		case .skill:   return .localize("Skill")
		case .persona: return .localize("Persona")
		}
	}
}
