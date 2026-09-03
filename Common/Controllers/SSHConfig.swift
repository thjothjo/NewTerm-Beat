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
	/// Empty for the default, 22.
	public var port: String
	/// The key to log in with — `IdentityFile`. Empty leaves `ssh` to try the usual keys in `~/.ssh`,
	/// which is right whenever there's only one.
	public var identityFile: String

	public init(name: String,
							hostName: String = "",
							user: String = "",
							port: String = "",
							identityFile: String = "") {
		self.name = name
		self.hostName = hostName
		self.user = user
		self.port = port
		self.identityFile = identityFile
	}

	/// `user@hostname:port`, or whichever parts the config gave.
	public var detail: String {
		var text = ""
		switch (user.isEmpty, hostName.isEmpty) {
		case (true, true):   text = ""
		case (true, false):  text = hostName
		case (false, true):  text = "\(user)@"
		case (false, false): text = "\(user)@\(hostName)"
		}
		if !port.isEmpty {
			text += ":\(port)"
		}
		return text
	}
}

/// The user's SSH config, read straight from disk.
///
/// Deliberately no store of our own, for the same reason a project is just a directory: `ssh` reads
/// this file, so anything else would be a second list to keep in step with it. A host added here
/// with an editor, or on a Mac and synced over, is a host this list offers — and connecting is
/// `ssh <name>`, exactly what the user would have typed.
///
/// Editing splices the lines of one entry rather than rewriting the file. The file is the user's: it
/// may have comments, includes, `Match` blocks and options this parser doesn't model, and none of
/// that should be lost to changing a port.
public enum SSHConfig {
	public enum Failure: LocalizedError {
		case invalidHost
		case alreadyExists(String)

		public var errorDescription: String? {
			switch self {
			case .invalidHost:
				return String.localize("SSH_HOST_INVALID")
			case .alreadyExists(let name):
				return String.localize("SSH_HOST_EXISTS").replacingOccurrences(of: "%@", with: name)
			}
		}
	}

	/// Posted after the config is written to, so a visible list re-reads it.
	public static let didChangeNotification = Notification.Name("ws.hbang.Terminal.sshConfigDidChange")

	/// Against the *shell's* home, not the app's: this is the file `ssh` itself will read when the
	/// command runs, and on roothide those two homes are different directories.
	public static var configURL: URL {
		URL(fileURLWithPath: SubProcess.homeDirectory, isDirectory: true)
			.appendingPathComponent(".ssh/config")
	}

	/// The path as the user would type it, for telling them — or an agent — where to look.
	public static var displayPath: String { "~/.ssh/config" }

	public static func hosts() -> [SSHHost] {
		guard let lines = try? readLines() else {
			return []
		}
		return entries(in: lines).map(\.host)
	}

	/// The command that connects to a host.
	///
	/// `--` ends option parsing, so a destination that begins with `-` — `Host -foo` in someone's
	/// config, or a hostile `ssh://` link — is a hostname to resolve and not an option to obey.
	public static func connectCommand(for host: SSHHost) -> String {
		"ssh -- \(shellQuoted(host.name))"
	}

	/// A command made from an external `ssh://` URL, or nil when the URL names nothing connectable.
	///
	/// Every URL field is untrusted: it arrived from a web page or a message. Quoting keeps it out of
	/// the shell, `--` keeps it out of ssh's own option parser, and a destination that still begins
	/// with `-` is refused outright rather than passed along to see what ssh makes of it —
	/// `-oProxyCommand=…` is a command ssh runs before connecting to anything.
	public static func connectCommand(user: String?, host: String, port: Int?) -> String? {
		let destination = user.map { "\($0)@\(host)" } ?? host
		guard !host.isEmpty, !destination.hasPrefix("-") else {
			return nil
		}
		let portOption = port.map { $0 == 22 ? "" : " -p \($0)" } ?? ""
		return "ssh\(portOption) -- \(shellQuoted(destination))"
	}

	// MARK: - Parsing

	/// A host, and the lines it occupies.
	struct Entry {
		var host: SSHHost
		/// From its `Host` line to the last line that configures it. Blank lines and comments after
		/// that are left out: a comment sitting above the next `Host` belongs to that one, and deleting
		/// this entry shouldn't take it.
		var range: Range<Int>
	}

	static func parse(_ text: String) -> [SSHHost] {
		entries(in: text.components(separatedBy: "\n")).map(\.host)
	}

	static func entries(in lines: [String]) -> [Entry] {
		var entries = [Entry]()
		// Keywords after a `Host` line belong to it until the next one, so the host being built has to
		// stay open across lines.
		var current: SSHHost?
		var start = 0
		var end = 0

		var seen = Set<String>()
		func flush() {
			// First entry wins, and later ones with the same name are dropped — that's what `ssh` itself
			// does with a repeated Host, so listing both would offer a choice that doesn't exist.
			if let host = current, !host.name.isEmpty, seen.insert(host.name).inserted {
				entries.append(Entry(host: host, range: start..<end))
			}
			current = nil
		}

		for (index, rawLine) in lines.enumerated() {
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

			if keyword == "host" {
				flush()
				// A `Host` line can name several patterns. Wildcards are defaults applied to other
				// hosts, not somewhere you can connect to, so they're skipped rather than listed as
				// hosts named `*`.
				if let name = parts.dropFirst().first(where: {
					!$0.hasPrefix("!") && !$0.contains("*") && !$0.contains("?")
				}) {
					current = SSHHost(name: name)
					start = index
					end = index + 1
				}
				continue
			}
			if keyword == "match" {
				// Match starts a conditional section that lasts until the next Host/Match. It never belongs
				// to the Host above it, even when the conditions happen to mention that host.
				flush()
				continue
			}

			guard current != nil else {
				// A `Match` block, or options before the first `Host`. Not ours to claim.
				continue
			}
			end = index + 1

			switch keyword {
			case "hostname":     current?.hostName = value
			case "user":         current?.user = value
			case "port":         current?.port = value
			case "identityfile": current?.identityFile = value
			default:             break
			}
		}
		flush()
		return entries
	}

	/// The keywords this parser puts back itself, so an edit replaces them rather than repeating them.
	private static let modelledKeywords: Set<String> = ["hostname", "user", "port", "identityfile"]

	private static func isModelled(_ line: String) -> Bool {
		let separators = CharacterSet(charactersIn: " \t=")
		let keyword = line.trimmingCharacters(in: .whitespaces)
			.components(separatedBy: separators)
			.first?
			.lowercased()
		return keyword.map(modelledKeywords.contains) ?? false
	}

	// MARK: - Editing

	/// Appends a host to the config, creating the file if it isn't there.
	public static func addHost(_ host: SSHHost) throws {
		try validate(host)
		var lines = try readLines()
		guard !entries(in: lines).contains(where: { $0.host.name == host.name }) else {
			throw Failure.alreadyExists(host.name)
		}
		// Trailing blank lines are the only thing normalised, so entries stay one blank line apart
		// however many times this runs.
		while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
			lines.removeLast()
		}
		if !lines.isEmpty {
			lines.append("")
		}
		lines.append("Host \(host.name)")
		lines += renderedOptions(for: host)
		// A file that ends with a newline, as every tool that appends to this one expects.
		lines.append("")
		try write(lines)
	}

	/// Replaces one entry in place, leaving everything else in the file exactly as it was.
	public static func updateHost(_ old: SSHHost, to new: SSHHost) throws {
		try validate(new)
		var lines = try readLines()
		if old.name != new.name,
			 entries(in: lines).contains(where: { $0.host.name == new.name }) {
			throw Failure.alreadyExists(new.name)
		}
		guard let entry = entries(in: lines).first(where: { $0.host.name == old.name }) else {
			// Gone from under us — an editor or an agent rewrote the file while this sheet was open.
			// Adding it is closer to what was asked than silently doing nothing.
			try addHost(new)
			return
		}

		var block = [renamed(lines[entry.range.lowerBound], from: old.name, to: new.name)]
		block += renderedOptions(for: new)
		// Anything in the block this parser doesn't model — ProxyJump, ForwardAgent, a comment between
		// options — is kept. Understanding four keywords is not a reason to drop the rest of someone's
		// config.
		block += lines[entry.range].dropFirst().filter { !isModelled($0) }

		lines.replaceSubrange(entry.range, with: block)
		try write(lines)
	}

	public static func removeHost(_ host: SSHHost) throws {
		var lines = try readLines()
		guard let entry = entries(in: lines).first(where: { $0.host.name == host.name }) else {
			return
		}
		lines.removeSubrange(entry.range)
		try write(lines)
	}

	/// Renames one pattern on a `Host` line, leaving any others alone.
	///
	/// `Host web web.old` names the same machine twice; renaming `web` shouldn't lose `web.old`.
	private static func renamed(_ line: String, from old: String, to new: String) -> String {
		guard old != new else {
			return line
		}
		let separators = CharacterSet(charactersIn: " \t=")
		var parts = line.trimmingCharacters(in: .whitespaces)
			.components(separatedBy: separators)
			.filter { !$0.isEmpty }
		guard let index = parts.firstIndex(of: old) else {
			return "Host \(new)"
		}
		parts[index] = new
		return parts.joined(separator: " ")
	}

	private static func renderedOptions(for host: SSHHost) -> [String] {
		var lines = [String]()
		if !host.hostName.isEmpty {
			lines.append("  HostName \(host.hostName)")
		}
		if !host.user.isEmpty {
			lines.append("  User \(host.user)")
		}
		if !host.port.isEmpty {
			lines.append("  Port \(host.port)")
		}
		if !host.identityFile.isEmpty {
			lines.append("  IdentityFile \(host.identityFile)")
		}
		return lines
	}

	/// Values written by this editor are single ssh_config tokens. Rejecting invalid syntax here keeps
	/// every caller safe, including pasted text that a single-line field still hands us verbatim.
	private static func validate(_ host: SSHHost) throws {
		let invalidName = CharacterSet.whitespacesAndNewlines
			.union(CharacterSet(charactersIn: "*?!#="))
		let invalidToken = CharacterSet.whitespacesAndNewlines
		guard !host.name.isEmpty,
				 host.name.rangeOfCharacter(from: invalidName) == nil,
				 host.hostName.rangeOfCharacter(from: invalidToken) == nil,
				 host.user.rangeOfCharacter(from: invalidToken) == nil,
				 !host.identityFile.contains(where: { $0.isNewline }),
				 host.port.isEmpty || (Int(host.port).map { (1...65_535).contains($0) } == true) else {
			throw Failure.invalidHost
		}
	}

	// MARK: - Disk

	private static func readLines() throws -> [String] {
		do {
			let data = try Data(contentsOf: configURL)
			guard let text = String(data: data, encoding: .utf8) else {
				throw CocoaError(.fileReadInapplicableStringEncoding)
			}
			return text.components(separatedBy: "\n")
		} catch let error as CocoaError where error.code == .fileReadNoSuchFile {
			// No config yet is the normal first-run state. Other read failures must reach editing callers
			// so an unreadable existing file is never mistaken for an empty one and overwritten.
			return []
		}
	}

	private static func write(_ lines: [String]) throws {
		try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(),
																						withIntermediateDirectories: true,
																						// ssh refuses to use a config anyone else can write to.
																						attributes: [.posixPermissions: 0o700])
		try Data(lines.joined(separator: "\n").utf8).write(to: configURL, options: .atomic)
		try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
		NotificationCenter.default.post(name: didChangeNotification, object: nil)
	}

	private static func shellQuoted(_ string: String) -> String {
		"'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}
}
