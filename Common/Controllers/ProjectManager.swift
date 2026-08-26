//
//  ProjectManager.swift
//  NewTerm Common
//

import Foundation

/// A directory under the projects root.
///
/// There is deliberately no metadata store: a project *is* a subdirectory. Creating one with `mkdir`
/// in the shell, or in Filza, works exactly as well as creating one from the toolbar, and the list
/// can never drift out of sync with what’s actually on disk.
public struct Project: Hashable, Identifiable {
	public var id: String { url.path }
	public var name: String
	public var url: URL
	public var lastModified: Date

	public init(name: String, url: URL, lastModified: Date) {
		self.name = name
		self.url = url
		self.lastModified = lastModified
	}
}

public enum ProjectManager {

	public static let defaultDirectory = "~/Documents"

	/// Posted after a project is created or trashed, so any visible list re-reads the directory
	/// rather than showing a stale snapshot.
	public static let didChangeNotification = Notification.Name("ws.hbang.Terminal.projectsDidChange")

	/// Where projects live: one subdirectory per project, each holding that project’s source.
	///
	/// Written as `~/Documents` rather than a literal path so it also works in the Simulator. On a
	/// jailbroken device `HOME` is `/var/mobile`, so this resolves to `/var/mobile/Documents` —
	/// outside the app container, which is what makes projects survive reinstalling the app.
	public static var rootURL: URL {
		let path = Preferences.shared.projectsDirectory
		let raw = path.isEmpty ? defaultDirectory : path
		// Expanded against the shell's home rather than the app's. They're the same on a rootless
		// jailbreak, but on roothide the app's home is the real /var/mobile while everything the user
		// works with — including the folders they'd expect to see listed here — lives in the
		// jailbreak's own home.
		let expanded = raw.hasPrefix("~")
			? SubProcess.homeDirectory + String(raw.dropFirst())
			: raw
		return URL(fileURLWithPath: expanded, isDirectory: true)
	}

	public static func projects() -> [Project] {
		let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
		guard let contents = try? FileManager.default.contentsOfDirectory(at: rootURL,
																																			includingPropertiesForKeys: keys,
																																			options: [.skipsHiddenFiles]) else {
			// The root not existing yet is the normal first-run state, not an error worth surfacing.
			return []
		}

		return contents
			.compactMap { url -> Project? in
				let values = try? url.resourceValues(forKeys: Set(keys))
				guard values?.isDirectory == true else {
					return nil
				}
				return Project(name: url.lastPathComponent,
											 url: url,
											 lastModified: values?.contentModificationDate ?? .distantPast)
			}
			.sorted { $0.lastModified > $1.lastModified }
	}

	@discardableResult
	public static func createProject(named name: String) throws -> Project {
		let url = rootURL.appendingPathComponent(name, isDirectory: true)
		// Intermediate directories covers the root itself not existing yet.
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		NotificationCenter.default.post(name: didChangeNotification, object: nil)
		return Project(name: name, url: url, lastModified: Date())
	}

	/// Removing a project means removing a directory of source code, and iOS has no undo for that.
	/// So it moves into a hidden `.Trash` inside the projects root instead of being deleted: the scan
	/// skips hidden entries so it leaves the list, but it’s still on disk to restore from Filza.
	@discardableResult
	public static func trashProject(_ project: Project) throws -> URL {
		let trashURL = rootURL.appendingPathComponent(".Trash", isDirectory: true)
		try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)

		var destination = trashURL.appendingPathComponent(project.name, isDirectory: true)
		if FileManager.default.fileExists(atPath: destination.path) {
			// Something of that name is already in there — keep both rather than clobbering the older one.
			let stamp = Int(Date().timeIntervalSince1970)
			destination = trashURL.appendingPathComponent("\(project.name)-\(stamp)", isDirectory: true)
		}

		try FileManager.default.moveItem(at: project.url, to: destination)
		NotificationCenter.default.post(name: didChangeNotification, object: nil)
		return destination
	}

	/// The command that opens a project.
	///
	/// With tmux the session is named after the project and reused, which is the only way a session
	/// outlives the app: iOS won’t keep our child processes running, but a tmux server that is
	/// already running is a separate process tree that survives us being killed. Without tmux
	/// installed this still lands in the right directory, just without the session.
	///
	/// No `cd` and no `-c`: the shell is spawned in the project directory already, and tmux inherits
	/// it. Typing a path in would only add a wrapped line of noise to scroll past on every restore.
	public static func openCommand(for project: Project) -> String? {
		guard Preferences.shared.useTmuxForProjects else {
			return nil
		}

		let session = shellQuoted(sessionName(for: project))
		// -A attaches if the session exists and creates it otherwise.
		return "command -v tmux >/dev/null 2>&1 && tmux new-session -A -s \(session)"
	}

	/// Same command, for a project we only have a path for — which is all a restored tab remembers.
	public static func openCommand(forPath path: String) -> String? {
		let url = URL(fileURLWithPath: path, isDirectory: true)
		return openCommand(for: Project(name: url.lastPathComponent, url: url, lastModified: Date()))
	}

	public static func sessionName(for project: Project) -> String {
		// tmux treats dots and colons as session/window/pane separators.
		"nt-" + project.name.replacingOccurrences(of: #"[.:]"#,
																						 with: "-",
																						 options: .regularExpression)
	}

	private static func shellQuoted(_ string: String) -> String {
		"'" + string.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
	}

}

/// Images handed to a CLI running in the terminal.
///
/// A command-line tool can’t be given a picture, only a path to one — so an attachment is a file
/// written next to the project, and what goes into the terminal is its path.
public enum ImageAttachment {

	/// Hidden, so it stays out of the project listing and out of the way of the source next to it.
	private static let directoryName = ".nt/img"

	public static func directory(for projectPath: String?) -> URL {
		let base = projectPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ProjectManager.rootURL
		return base.appendingPathComponent(directoryName, isDirectory: true)
	}

	/// Writes `data` and returns where it went, plus the number to show the user.
	///
	/// The number continues from what’s already on disk rather than from a counter in memory, so it
	/// still lines up with the filenames after the app has been closed and reopened.
	public static func save(_ data: Data, fileExtension: String, projectPath: String?) throws -> (url: URL, index: Int) {
		let directory = directory(for: projectPath)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

		let used = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
			.compactMap { Int(($0 as NSString).deletingPathExtension) } ?? []
		let index = (used.max() ?? 0) + 1

		let url = directory.appendingPathComponent("\(index).\(fileExtension)")
		try data.write(to: url, options: .atomic)
		return (url, index)
	}

}
