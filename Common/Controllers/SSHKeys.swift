//
//  SSHKeys.swift
//  NewTerm Common
//

import Foundation
import os.log

/// A key pair in `~/.ssh`, as `ssh` would find it.
public struct SSHKey: Hashable, Identifiable {
	public var id: String { path }
	/// The file name, which is the useful half of the path when it's one of several in `~/.ssh`.
	public var name: String
	/// Absolute path to the private key.
	public var path: String
	/// The same path written the way a config file does, which is what goes in an `IdentityFile` line.
	public var configPath: String
	/// The whole of the `.pub` file, on one line. This is what a server's `authorized_keys` wants.
	public var publicKey: String
	/// `ed25519`, `rsa`, and so on — read from the public key rather than guessed from the name. Empty
	/// when there's no public half to read it from.
	public var type: String
	/// The trailing comment, usually `user@host`. Empty when the key was made without one.
	public var comment: String
	/// The private key's file mode, because `ssh` refuses to use a key anyone else can read.
	public var permissions: Int

	/// Whether `ssh` will accept the file as it stands.
	///
	/// A key copied out of Files, a backup or an archive arrives world-readable, and `ssh` refuses it
	/// with "UNPROTECTED PRIVATE KEY FILE" rather than falling back to a password — which reads as the
	/// key simply not working.
	public var arePermissionsSafe: Bool { permissions & 0o077 == 0 }

	/// Whether the public half is there. Without it there's nothing to put on a server.
	public var hasPublicKey: Bool { !publicKey.isEmpty }
}

/// The kinds of key `ssh-keygen` can make that are worth offering.
///
/// Not every algorithm it supports — DSA is refused by modern servers and RSA below 3072 bits is on
/// its way there. These three are the ones that get you in somewhere: the modern default, the one
/// old servers still insist on, and the one some appliances only speak.
public enum SSHKeyType: String, CaseIterable, Hashable, Identifiable {
	case ed25519
	case rsa
	case ecdsa

	public var id: String { rawValue }

	/// The file name `ssh` tries by default for this kind of key, so a host that names no
	/// `IdentityFile` still finds it.
	public var defaultFileName: String { "id_\(rawValue)" }

	public var label: String {
		switch self {
		case .ed25519: return "Ed25519"
		case .rsa:     return "RSA 4096"
		case .ecdsa:   return "ECDSA 521"
		}
	}

	/// Sizes are fixed rather than offered: the only RSA size worth making now is 4096, and for
	/// ECDSA the largest curve. A bit-length field is a way to make a weaker key by accident.
	var keygenArguments: [String] {
		switch self {
		case .ed25519: return ["-t", "ed25519"]
		case .rsa:     return ["-t", "rsa", "-b", "4096"]
		case .ecdsa:   return ["-t", "ecdsa", "-b", "521"]
		}
	}
}

/// The keys in `~/.ssh`, found rather than configured.
///
/// Same reasoning as the host list: `ssh` looks in this directory, so a key copied in over SFTP or
/// made with `ssh-keygen` in the terminal is a key this list offers. Nothing here is a record of
/// what the app did — it's a reading of what's on disk.
public enum SSHKeys {

	/// Posted after a key is made or deleted.
	public static let didChangeNotification = Notification.Name("ws.hbang.Terminal.sshKeysDidChange")

	private static let logger = Logger(subsystem: "ws.hbang.Terminal", category: "SSHKeys")

	private static func notifyChanged() {
		DispatchQueue.main.async {
			NotificationCenter.default.post(name: didChangeNotification, object: nil)
		}
	}

	/// Against the shell's home, for the same reason the config is: this is the directory `ssh` reads.
	public static var directoryURL: URL {
		URL(fileURLWithPath: SubProcess.homeDirectory, isDirectory: true)
			.appendingPathComponent(".ssh", isDirectory: true)
	}

	public static var displayPath: String { "~/.ssh" }

	public enum Failure: LocalizedError {
		/// OpenSSH isn't installed, or isn't anywhere we know to look.
		case toolMissing
		case alreadyExists(String)
		case failed(String)

		public var errorDescription: String? {
			switch self {
			case .toolMissing:
				return String.localize("SSH_KEYGEN_MISSING")
			case .alreadyExists(let name):
				return String.localize("SSH_KEY_EXISTS").replacingOccurrences(of: "%@", with: name)
			case .failed(let message):
				return message
			}
		}
	}

	// MARK: - Reading

	/// Everything in the directory this reads and skips outright.
	///
	/// Not an exhaustive list, and it doesn't need to be — it's a shortcut past the files that are
	/// always there, and everything else is decided by looking inside it.
	private static let notKeys: Set<String> = ["config", "known_hosts", "known_hosts.old",
																						 "authorized_keys", "authorized_keys2", "environment", "rc"]

	/// Every private key in `~/.ssh`, whether or not this app put it there.
	///
	/// Found by reading the folder and looking inside each file, not by name and not from a list of
	/// our own: `ssh` doesn't care what a key is called, so a key copied in over SFTP, restored from a
	/// backup or made with `ssh-keygen` in the terminal is a key that shows up here.
	public static func keys() -> [SSHKey] {
		let manager = FileManager.default
		let directory = directoryURL.path
		let contents = (try? manager.contentsOfDirectory(atPath: directory)) ?? []

		return contents.sorted().compactMap { item in
			guard !item.hasPrefix("."),
						!notKeys.contains(item),
						// The public half is listed with the key it belongs to, not as a key of its own.
						(item as NSString).pathExtension != "pub" else {
				return nil
			}
			let path = (directory as NSString).appendingPathComponent(item)
			var isDirectory: ObjCBool = false
			guard manager.fileExists(atPath: path, isDirectory: &isDirectory),
						!isDirectory.boolValue,
						isPrivateKey(atPath: path) else {
				return nil
			}

			// The public half when there is one. It's the part that names the type and carries the
			// comment — an imported key often arrives without it, which is worth showing rather than
			// hiding the key.
			let publicKey = (try? String(contentsOfFile: path + ".pub", encoding: .utf8))?
				.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
			let fields = publicKey.components(separatedBy: " ")
			// `ssh-ed25519 AAAA… yang@phone`: type, key, then whatever comment was given, which can
			// itself contain spaces.
			let type = (fields.first ?? "").replacingOccurrences(of: "ssh-", with: "")
			let comment = fields.count > 2 ? fields.dropFirst(2).joined(separator: " ") : ""
			let permissions = ((try? manager.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?
				.intValue ?? 0

			return SSHKey(name: item,
										path: path,
										configPath: "\(displayPath)/\(item)",
										publicKey: publicKey,
										type: type,
										comment: comment,
										permissions: permissions)
		}
	}

	/// Whether a file is a private key, by looking at it rather than at its name.
	private static func isPrivateKey(atPath path: String) -> Bool {
		guard let handle = FileHandle(forReadingAtPath: path) else {
			return false
		}
		defer { try? handle.close() }
		// The first line of every format ssh accepts: `-----BEGIN OPENSSH PRIVATE KEY-----`, or RSA,
		// EC, or plain PKCS#8. 64 bytes reaches the end of the longest of them.
		guard let data = try? handle.read(upToCount: 64) else {
			return false
		}
		let marker = String(decoding: data, as: UTF8.self)
			.split(whereSeparator: \.isNewline)
			.first
			.map(String.init) ?? ""
		return [
			"-----BEGIN OPENSSH PRIVATE KEY-----",
			"-----BEGIN RSA PRIVATE KEY-----",
			"-----BEGIN DSA PRIVATE KEY-----",
			"-----BEGIN EC PRIVATE KEY-----",
			"-----BEGIN PRIVATE KEY-----",
			"-----BEGIN ENCRYPTED PRIVATE KEY-----"
		].contains(marker)
	}

	// MARK: - Writing

	/// Makes a new key pair by running `ssh-keygen`.
	///
	/// Shelled out rather than generated in-process, and deliberately: the file format is OpenSSH's,
	/// the tool that defines it is already installed on any device that can run `ssh` at all, and a
	/// hand-rolled encoder that's subtly wrong produces a key that fails at the far end, weeks later.
	///
	/// The comment is what identifies the key in a server's `authorized_keys`, which is the list you
	/// read months later trying to work out which of six lines is the phone you still own.
	@discardableResult
	public static func generate(name: String,
															type: SSHKeyType = .ed25519,
															comment: String = "") throws -> SSHKey {
		let manager = FileManager.default
		// A file name, not a path: anything with a slash in it would write somewhere other than the
		// directory this list reads, and the key would appear to have vanished.
		guard !name.isEmpty,
				!name.contains("/"),
				!name.hasPrefix("."),
				!name.contains(where: \.isWhitespace) else {
			throw Failure.failed(String.localize("SSH_KEY_NAME_INVALID"))
		}
		let path = (directoryURL.path as NSString).appendingPathComponent(name)
		guard !manager.fileExists(atPath: path), !manager.fileExists(atPath: path + ".pub") else {
			// ssh-keygen would stop and ask whether to overwrite, on a stdin nobody can type into.
			throw Failure.alreadyExists(name)
		}
		guard let tool = binaryPath("ssh-keygen") else {
			throw Failure.toolMissing
		}
		try manager.createDirectory(at: directoryURL,
																withIntermediateDirectories: true,
																// ssh ignores keys in a directory others can write to.
																attributes: [.posixPermissions: 0o700])

		// Empty passphrase: there's nowhere to type one at connect time. A key on a device that's
		// already unlocked to use the app is as protected as the app is.
		let safeComment = comment.components(separatedBy: .newlines).joined(separator: " ")
		let output: String
		do {
			output = try run(tool, ["ssh-keygen"]
											+ type.keygenArguments
											+ ["-f", path,
												 "-N", "",
												 "-C", safeComment.isEmpty ? "newterm@\(ProcessInfo.processInfo.hostName)" : safeComment])
		} catch {
			try? manager.removeItem(atPath: path)
			try? manager.removeItem(atPath: path + ".pub")
			throw error
		}
		guard manager.fileExists(atPath: path + ".pub") else {
			try? manager.removeItem(atPath: path)
			throw Failure.failed(output.isEmpty ? String.localize("SSH_KEYGEN_FAILED") : output)
		}
		try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
		try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path + ".pub")

		notifyChanged()
		guard let key = keys().first(where: { $0.name == name }) else {
			throw Failure.failed(String.localize("SSH_KEYGEN_FAILED"))
		}
		return key
	}

	/// Copies keys into `~/.ssh` from wherever the user picked them.
	///
	/// Folders are read rather than refused: keys are usually kept together, and picking the folder
	/// they're in is less fiddly on a phone than selecting four files by hand. Anything in there that
	/// isn't a private key — `known_hosts`, a README, the public halves — is passed over silently,
	/// because skipping a file that was never a key isn't a failure worth an alert.
	@discardableResult
	public static func importKeys(from urls: [URL]) throws -> Int {
		try FileManager.default.createDirectory(at: directoryURL,
																						withIntermediateDirectories: true,
																						attributes: [.posixPermissions: 0o700])
		var imported = 0
		var firstError: Error?

		for url in urls {
			// Files hands over a security-scoped URL; without this the copy fails with a permissions
			// error that has nothing to do with the file's own permissions.
			let accessed = url.startAccessingSecurityScopedResource()
			defer {
				if accessed {
					url.stopAccessingSecurityScopedResource()
				}
			}

			for candidate in expand(url) {
				do {
					if try importKey(from: candidate) {
						imported += 1
					}
				} catch {
					// Kept rather than thrown: one name already taken shouldn't stop the other three
					// arriving. Reported below, once the rest are in.
					if firstError == nil {
						firstError = error
					}
				}
			}
		}

		if imported > 0 {
			notifyChanged()
		}
		if let error = firstError {
			throw error
		}
		guard imported > 0 else {
			throw Failure.failed(String.localize("SSH_IMPORT_NONE"))
		}
		return imported
	}

	/// The files to consider for one thing the user picked — itself, or its contents if it's a folder.
	private static func expand(_ url: URL) -> [URL] {
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
			return []
		}
		guard isDirectory.boolValue else {
			return [url]
		}
		// Only the top level: `~/.ssh` is flat, and a recursive walk of a picked folder is a good way to
		// copy in something nobody meant to.
		let contents = (try? FileManager.default.contentsOfDirectory(at: url,
																																 includingPropertiesForKeys: nil,
																																 options: [.skipsHiddenFiles])) ?? []
		return contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
	}

	/// Copies one file in, if it's a private key. Returns whether it was.
	private static func importKey(from url: URL) throws -> Bool {
		let manager = FileManager.default
		let name = url.lastPathComponent
		guard url.pathExtension != "pub", isPrivateKey(atPath: url.path) else {
			return false
		}
		guard !name.contains("/"),
				!name.hasPrefix("."),
				!name.contains(where: \.isWhitespace) else {
			throw Failure.failed(String.localize("SSH_KEY_NAME_INVALID"))
		}
		let path = (directoryURL.path as NSString).appendingPathComponent(name)
		guard !manager.fileExists(atPath: path), !manager.fileExists(atPath: path + ".pub") else {
			throw Failure.alreadyExists(name)
		}

		try manager.copyItem(atPath: url.path, toPath: path)
		try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

		// Its public half, if it was sitting beside it. Otherwise work it out from the key — the two
		// have to match, and a key with no public half is a key you can't put on a server.
		let sibling = url.appendingPathExtension("pub")
		if manager.fileExists(atPath: sibling.path),
			 let tool = binaryPath("ssh-keygen"),
			 let derived = try? run(tool, ["ssh-keygen", "-y", "-f", path]) {
			do {
				let supplied = try String(contentsOf: sibling, encoding: .utf8)
				if publicKeyMaterial(supplied) != publicKeyMaterial(derived) {
					throw Failure.failed(String.localize("SSH_PUBLIC_KEY_FAILED"))
				}
				try manager.copyItem(atPath: sibling.path, toPath: path + ".pub")
				try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path + ".pub")
			} catch {
				try? manager.removeItem(atPath: path)
				try? manager.removeItem(atPath: path + ".pub")
				throw error
			}
		} else {
			// Best effort: a key with a passphrase can't be read without it, and that's not a reason to
			// refuse the import.
			try? writePublicKey(forKeyAt: path)
		}
		return true
	}

	private static func publicKeyMaterial(_ publicKey: String) -> ArraySlice<Substring> {
		publicKey.split(whereSeparator: \.isWhitespace).prefix(2)
	}

	/// Works a key's public half out of the private one, and writes it beside it.
	///
	/// For a key that arrived on its own. `ssh` itself doesn't need the `.pub` file, but you do: it's
	/// the line that goes in the server's `authorized_keys`.
	public static func recoverPublicKey(for key: SSHKey) throws {
		try writePublicKey(forKeyAt: key.path)
		notifyChanged()
	}

	private static func writePublicKey(forKeyAt path: String) throws {
		guard let tool = binaryPath("ssh-keygen") else {
			throw Failure.toolMissing
		}
		let output = try run(tool, ["ssh-keygen", "-y", "-f", path])
		guard output.contains(" ") else {
			throw Failure.failed(output.isEmpty ? String.localize("SSH_PUBLIC_KEY_FAILED") : output)
		}
		try Data((output + "\n").utf8).write(to: URL(fileURLWithPath: path + ".pub"), options: .atomic)
		try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path + ".pub")
	}

	/// Takes a key's permissions back to 0600, which is the only thing `ssh` will use it at.
	public static func fixPermissions(for key: SSHKey) throws {
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
		try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
		notifyChanged()
	}

	/// Deletes both halves of a pair.
	public static func remove(_ key: SSHKey) throws {
		try FileManager.default.removeItem(atPath: key.path)
		try? FileManager.default.removeItem(atPath: key.path + ".pub")
		notifyChanged()
	}

	// MARK: - Running ssh-keygen

	private static func binaryPath(_ name: String) -> String? {
		AICatalog.binaryDirectories
			.map { ($0 as NSString).appendingPathComponent(name) }
			.first { FileManager.default.isExecutableFile(atPath: $0) }
	}

	/// Runs a command to completion, returning whatever it said for itself.
	///
	/// Both output streams go to a file rather than a pipe: the output is a line or two and only read
	/// when something went wrong, and a pipe nobody drains is a deadlock waiting for a verbose day.
	private static func run(_ path: String, _ arguments: [String]) throws -> String {
		let logPath = NSTemporaryDirectory() + "ssh-keygen-\(UUID().uuidString)"
		defer { try? FileManager.default.removeItem(atPath: logPath) }

		var actions: posix_spawn_file_actions_t!
		posix_spawn_file_actions_init(&actions)
		defer { posix_spawn_file_actions_destroy(&actions) }
		// Nothing to read from, so a prompt we didn't anticipate ends the process instead of hanging it.
		posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
		posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, logPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
		posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)

		let environment = ["HOME=\(SubProcess.homeDirectory)",
											 "PATH=\(AICatalog.binaryDirectories.joined(separator: ":"))"]
		var argv = arguments.map { strdup($0) } + [nil]
		var envp = environment.map { strdup($0) } + [nil]
		defer {
			for pointer in argv + envp {
				free(pointer)
			}
		}

		var pid = pid_t()
		let result = ie_posix_spawn(&pid, path, &actions, nil, &argv, &envp)
		guard result == 0 else {
			logger.error("Couldn’t start \(path): \(result)")
			throw Failure.failed(String(cString: strerror(result)))
		}

		var status = Int32()
		var waited: pid_t
		repeat {
			waited = waitpid(pid, &status, 0)
		} while waited == -1 && errno == EINTR
		guard waited == pid else {
			let waitError = errno
			throw Failure.failed(String(cString: strerror(waitError)))
		}

		let output = (try? String(contentsOfFile: logPath, encoding: .utf8))?
			.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		// Exited normally with a non-zero code, or died on a signal: either way it didn't do the job.
		let exited = status & 0x7f == 0
		guard exited, (status >> 8) & 0xff == 0 else {
			logger.error("\(path) failed: \(output, privacy: .public)")
			throw Failure.failed(output.isEmpty ? String.localize("SSH_KEYGEN_FAILED") : output)
		}
		return output
	}
}
