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

	/// Posted when the tab bar starts or stops showing a single project's terminals.
	public static let activeProjectDidChangeNotification = Notification.Name("ws.hbang.Terminal.activeProjectDidChange")

	/// The project whose terminals the tab bar is showing on their own, or `nil` when it's showing all
	/// of them grouped. The projects list marks this one, so it's clear which one you're inside.
	///
	/// Here rather than passed down because the list that needs it is inside a keyboard view, several
	/// layers below the controller that decides it, and per-terminal state objects would each need
	/// their own copy kept in step.
	public private(set) static var activeProjectPath: String?

	public static func setActiveProject(path: String?) {
		guard activeProjectPath != path else {
			return
		}
		activeProjectPath = path
		NotificationCenter.default.post(name: activeProjectDidChangeNotification, object: nil)
	}

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

	// MARK: - iCloud Drive

	/// Our folder in iCloud Drive, where copies of projects go so they can be seen from a Mac.
	///
	/// A literal path, not `~`-expanded: `~` for everything else here means the jailbreak's home,
	/// and iCloud Drive only exists under the real one. Nothing in `rootURL`'s expansion applies.
	public static let iCloudRootURL = URL(fileURLWithPath: "/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/NewTerm",
																				isDirectory: true)

	/// Why iCloud Drive can't be used, or nil when it can.
	///
	/// Reading the folder rather than asking about the account: the entitlement that gets us in is
	/// checked by the kernel, so the only answer that means anything is whether the open succeeded.
	public static func iCloudUnavailableReason() -> String? {
		let container = iCloudRootURL.deletingLastPathComponent()
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: container.path, isDirectory: &isDirectory),
					isDirectory.boolValue else {
			return .localize("iCloud Drive isn’t set up on this device.")
		}
		guard (try? FileManager.default.contentsOfDirectory(atPath: container.path)) != nil else {
			return .localize("This build can’t reach iCloud Drive.")
		}
		return nil
	}

	/// Names of the project folders already copied to iCloud Drive.
	public static func iCloudProjectNames() -> [String] {
		((try? FileManager.default.contentsOfDirectory(atPath: iCloudRootURL.path)) ?? [])
			.filter { !$0.hasPrefix(".") }
			.sorted()
	}

	/// Copies a project into iCloud Drive, replacing whatever was there under the same name.
	///
	/// A copy, not a move or a link: the terminal's shell can't reach iCloud Drive — it's a separate
	/// process and the exemption that lets *us* in isn't inherited across exec — so the working copy
	/// has to stay where a shell can open it.
	public static func exportToICloud(_ project: Project) throws {
		try FileManager.default.createDirectory(at: iCloudRootURL, withIntermediateDirectories: true)
		let destination = iCloudRootURL.appendingPathComponent(project.name, isDirectory: true)
		try replaceItem(at: destination, withCopyOf: project.url)
	}

	/// Copies a project back out of iCloud Drive, replacing the local copy of the same name.
	public static func importFromICloud(named name: String) throws {
		let source = iCloudRootURL.appendingPathComponent(name, isDirectory: true)
		try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		try replaceItem(at: rootURL.appendingPathComponent(name, isDirectory: true), withCopyOf: source)
		NotificationCenter.default.post(name: didChangeNotification, object: nil)
	}

	/// Files iCloud has evicted to save space, which are on disk as stubs rather than contents.
	///
	/// Copying one gives a `.icloud` placeholder, not the file — so an import that hit any of these
	/// would look like it worked and quietly produce a project full of empty markers.
	public static func evictedFileNames(inICloudProjectNamed name: String) -> [String] {
		let root = iCloudRootURL.appendingPathComponent(name, isDirectory: true)
		guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
			return []
		}
		return enumerator
			.compactMap { $0 as? String }
			.filter { ($0 as NSString).pathExtension == "icloud" }
			.map { path -> String in
				// `.foo.txt.icloud` is a placeholder for `foo.txt`.
				let file = (path as NSString).lastPathComponent
				let stripped = (file as NSString).deletingPathExtension
				return ((path as NSString).deletingLastPathComponent as NSString)
					.appendingPathComponent(stripped.hasPrefix(".") ? String(stripped.dropFirst()) : stripped)
			}
	}

	/// Copies `source` over `destination` without leaving a half-written folder behind if it fails.
	private static func replaceItem(at destination: URL, withCopyOf source: URL) throws {
		let staging = destination.deletingLastPathComponent()
			.appendingPathComponent(".\(destination.lastPathComponent).incoming", isDirectory: true)
		try? FileManager.default.removeItem(at: staging)
		try FileManager.default.copyItem(at: source, to: staging)

		do {
			// Swapped in only once the copy is complete, so an interrupted copy can't be mistaken for
			// the real thing.
			if FileManager.default.fileExists(atPath: destination.path) {
				try FileManager.default.removeItem(at: destination)
			}
			try FileManager.default.moveItem(at: staging, to: destination)
		} catch {
			try? FileManager.default.removeItem(at: staging)
			throw error
		}
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
