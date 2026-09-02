//
//  SessionStore.swift
//  NewTerm Common
//

import Foundation
import CryptoKit
import os.log

public struct SessionTabState: Codable, Equatable {
	/// Stable across restarts, so a tab's saved scrollback can be matched back to it even after tabs
	/// have been added or closed and the plain index would point somewhere else.
	public var id: String
	public var projectPath: String?
	public var title: String?
	/// One scrollback id per pane. Older snapshots have one pane whose id is the tab id.
	public var paneIDs: [String]

	public init(id: String = UUID().uuidString,
						projectPath: String?,
						title: String?,
						paneIDs: [String]? = nil) {
		self.id = id
		self.projectPath = projectPath
		self.title = title
		self.paneIDs = paneIDs?.isEmpty == false ? paneIDs! : [id]
	}

	// Snapshots written before tabs had ids still decode: a missing id becomes a fresh one, which just
	// means that tab starts without restored scrollback the first time.
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
		self.projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
		self.title = try container.decodeIfPresent(String.self, forKey: .title)
		let decodedPaneIDs = try container.decodeIfPresent([String].self, forKey: .paneIDs) ?? []
		self.paneIDs = decodedPaneIDs.isEmpty ? [self.id] : decodedPaneIDs
	}
}

public struct SessionState: Codable, Equatable {
	public var tabs: [SessionTabState]
	public var selectedIndex: Int

	public init(tabs: [SessionTabState], selectedIndex: Int) {
		self.tabs = tabs
		self.selectedIndex = selectedIndex
	}
}

/// Crash-safe snapshot of a window’s tabs.
///
/// Deliberately not built on `stateRestorationActivity(for:)`: the system only asks for that when it
/// is shutting us down politely, which is the one case the user didn’t ask about. A crash, or being
/// jetsammed in the background, never gets that call — so the snapshot has to already be on disk.
public final class SessionStore {

	public static let shared = SessionStore()

	private static let schemaVersion = 1
	/// Snapshots that keep taking the app down get thrown away rather than crash-looping forever.
	private static let maxRestoreAttempts = 3
	/// Long enough to coalesce a burst of tab changes, short enough that the window where a crash
	/// loses the most recent change stays small.
	private static let debounceInterval: TimeInterval = 0.4

	private struct Envelope: Codable {
		var schemaVersion: Int
		var restoreAttempts: Int
		var checksum: String
		var state: SessionState
	}

	private struct PendingSave {
		var token: UUID
		var work: DispatchWorkItem
	}

	private let queue = DispatchQueue(label: "ws.hbang.Terminal.session-store", qos: .utility)
	/// Debouncing is per scene. A single slot makes activity in one window cancel another window's
	/// snapshot, even though those windows write different files.
	private var pendingWork = [String: PendingSave]()
	private let logger = Logger(subsystem: "ws.hbang.Terminal", category: "SessionStore")

	private init() {}

	// MARK: - Locations

	private static var directory: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		return base.appendingPathComponent("Sessions", isDirectory: true)
	}

	/// One file per scene, so multiple windows can’t clobber each other.
	private static func url(for identifier: String) -> URL {
		directory.appendingPathComponent("\(identifier).json")
	}

	private static var encoder: JSONEncoder {
		let encoder = JSONEncoder()
		// Deterministic output: the checksum is verified by re-encoding, which only works if the same
		// value always produces the same bytes.
		encoder.outputFormatting = .sortedKeys
		return encoder
	}

	private static func checksum(of data: Data) -> String {
		SHA256.hash(data: data)
			.map { String(format: "%02x", $0) }
			.joined()
	}

	// MARK: - Saving

	/// Coalesced save, for the frequent low-stakes changes — a tab added, a different tab selected.
	public func setNeedsSave(_ state: SessionState, identifier: String) {
		queue.async {
			self.pendingWork[identifier]?.work.cancel()
			let token = UUID()
			let work = DispatchWorkItem { [weak self] in
				guard let self = self,
						self.pendingWork[identifier]?.token == token else {
					return
				}
				self.pendingWork[identifier] = nil
				self.write(state, identifier: identifier)
			}
			self.pendingWork[identifier] = PendingSave(token: token, work: work)
			self.queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
		}
	}

	/// Immediate save, for the things that must not be lost: closing a tab (it must not come back from
	/// the dead) and going to the background (jetsam gives no warning).
	public func saveImmediately(_ state: SessionState, identifier: String) {
		queue.sync {
			self.pendingWork[identifier]?.work.cancel()
			self.pendingWork[identifier] = nil
			self.write(state, identifier: identifier)
		}
	}

	private func write(_ state: SessionState, identifier: String) {
		do {
			let encoder = Self.encoder
			let envelope = Envelope(schemaVersion: Self.schemaVersion,
															restoreAttempts: 0,
															checksum: Self.checksum(of: try encoder.encode(state)),
															state: state)
			let data = try encoder.encode(envelope)

			try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)

			let url = Self.url(for: identifier)
			// `.atomic` writes to a temp file and renames, so a crash mid-write can’t leave a torn file.
			// The backup covers the other case: a file that’s intact but somehow unusable.
			let backupURL = url.appendingPathExtension("bak")
			if FileManager.default.fileExists(atPath: url.path) {
				try? FileManager.default.removeItem(at: backupURL)
				try? FileManager.default.copyItem(at: url, to: backupURL)
			}

			try data.write(to: url, options: .atomic)
		} catch {
			// Failing to save must never be worse than not saving.
			logger.error("Couldn’t save session \(identifier): \(String(describing: error))")
		}
	}

	// MARK: - Loading

	public func load(identifier: String) -> SessionState? {
		let url = Self.url(for: identifier)

		guard var envelope = Self.read(url) ?? Self.read(url.appendingPathExtension("bak")) else {
			return nil
		}
		guard envelope.schemaVersion == Self.schemaVersion else {
			// Written by a newer build. Guessing at unknown fields is worse than starting fresh.
			return nil
		}

		if envelope.restoreAttempts >= Self.maxRestoreAttempts {
			logger.error("Discarding session \(identifier) after \(envelope.restoreAttempts) attempts")
			discard(identifier: identifier)
			return nil
		}

		// Count the attempt *before* handing the state over, and get it on disk now — if restoring is
		// itself what crashes, the raised count is the only thing that stops the loop.
		envelope.restoreAttempts += 1
		if let data = try? Self.encoder.encode(envelope) {
			try? data.write(to: url, options: .atomic)
		}

		return envelope.state
	}

	private static func read(_ url: URL) -> Envelope? {
		guard let data = try? Data(contentsOf: url),
					let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
					let stateData = try? encoder.encode(envelope.state),
					checksum(of: stateData) == envelope.checksum else {
			return nil
		}
		return envelope
	}

	/// Called when the user actually closes a window, as opposed to the system reclaiming it.
	@discardableResult
	public func discard(identifier: String) -> SessionState? {
		queue.sync {
			self.pendingWork[identifier]?.work.cancel()
			self.pendingWork[identifier] = nil
			let url = Self.url(for: identifier)
			let envelope = Self.read(url) ?? Self.read(url.appendingPathExtension("bak"))
			try? FileManager.default.removeItem(at: url)
			try? FileManager.default.removeItem(at: url.appendingPathExtension("bak"))
			return envelope?.schemaVersion == Self.schemaVersion ? envelope?.state : nil
		}
	}

}
