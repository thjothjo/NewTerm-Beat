//
//  SSHConfig.swift
//  NewTerm Common
//

import Foundation

/// A host you can connect to, as named in `~/.ssh/config`.
public struct SSHHost: Hashable, Identifiable {
	public var id: String { name }
	/// The alias, which is also the argument to `ssh`.
	public var name: String
	/// What it resolves to, for telling two similarly-named aliases apart. Empty when the config
	/// doesn't say — `ssh` will use the alias itself.
	public var hostName: String
	public var user: String

	/// `user@hostname`, or whichever half the config gave.
	public var detail: String {
		switch (user.isEmpty, hostName.isEmpty) {
		case (true, true):   return ""
		case (true, false):  return hostName
		case (false, true):  return "\(user)@"
		case (false, false): return "\(user)@\(hostName)"
		}
	}
}

/// The user's SSH config, read straight from disk.
///
/// Deliberately no store of our own, for the same reason a project is just a directory: `ssh` reads
/// this file, so anything else would be a second list to keep in step with it. A host added here
/// with an editor, or on a Mac and synced over, is a host this list offers — and connecting is
/// `ssh <name>`, exactly what the user would have typed.
public enum SSHConfig {

	/// Posted after the config is written to, so a visible list re-reads it.
	public static let didChangeNotification = Notification.Name("ws.hbang.Terminal.sshConfigDidChange")

	/// Against the *shell's* home, not the app's: this is the file `ssh` itself will read when the
	/// command runs, and on roothide those two homes are different directories.
	public static var configURL: URL {
		URL(fileURLWithPath: SubProcess.homeDirectory, isDirectory: true)
			.appendingPathComponent(".ssh/config")
	}

	public static func hosts() -> [SSHHost] {
		guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
			// No config yet is the normal first-run state, not an error worth surfacing.
			return []
		}
		return parse(text)
	}

	/// The command that connects to a host.
	public static func connectCommand(for host: SSHHost) -> String {
		"ssh \(shellQuoted(host.name))"
	}

	// MARK: - Parsing

	static func parse(_ text: String) -> [SSHHost] {
		var hosts = [SSHHost]()
		// Keywords after a `Host` line belong to it until the next one, so the host being built has to
		// stay open across lines.
		var current: SSHHost?

		var seen = Set<String>()
		func flush() {
			// First entry wins, and later ones with the same name are dropped — that's what `ssh` itself
			// does with a repeated Host, so listing both would offer a choice that doesn't exist.
			if let host = current, !host.name.isEmpty, seen.insert(host.name).inserted {
				hosts.append(host)
			}
			current = nil
		}

		for rawLine in text.components(separatedBy: .newlines) {
			let line = rawLine.trimmingCharacters(in: .whitespaces)
			guard !line.isEmpty, !line.hasPrefix("#") else {
				continue
			}

			// `Keyword value`, or `Keyword=value` — ssh_config accepts both.
			let separators = CharacterSet(charactersIn: " \t=")
			let parts = line.components(separatedBy: separators).filter { !$0.isEmpty }
			guard let keyword = parts.first?.lowercased() else {
				continue
			}
			let value = parts.dropFirst().joined(separator: " ")

			switch keyword {
			case "host":
				flush()
				// A `Host` line can name several patterns. Wildcards are defaults applied to other
				// hosts, not somewhere you can connect to, so they're skipped rather than listed as
				// hosts named `*`.
				if let name = parts.dropFirst().first(where: { !$0.contains("*") && !$0.contains("?") }) {
					current = SSHHost(name: name, hostName: "", user: "")
				}

			case "hostname":
				current?.hostName = value

			case "user":
				current?.user = value

			default:
				break
			}
		}
		flush()
		return hosts
	}

	// MARK: - Editing

	/// Appends a host to the config, creating the file if it isn't there.
	///
	/// Append rather than rewrite: the file is the user's, it may have comments, includes and options
	/// this parser doesn't model, and none of that should be lost to adding one entry.
	public static func addHost(name: String, hostName: String, user: String, port: String) throws {
		let directory = configURL.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: directory,
																						withIntermediateDirectories: true,
																						// ssh refuses to use a config anyone else can write to.
																						attributes: [.posixPermissions: 0o700])

		var entry = "\nHost \(name)\n"
		if !hostName.isEmpty {
			entry += "  HostName \(hostName)\n"
		}
		if !user.isEmpty {
			entry += "  User \(user)\n"
		}
		if !port.isEmpty {
			entry += "  Port \(port)\n"
		}

		let existing = (try? Data(contentsOf: configURL)) ?? Data()
		try (existing + Data(entry.utf8)).write(to: configURL, options: .atomic)
		try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)

		NotificationCenter.default.post(name: didChangeNotification, object: nil)
	}

	private static func shellQuoted(_ string: String) -> String {
		"'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}
}
