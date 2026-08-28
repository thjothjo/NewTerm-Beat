//
//  ScrollbackStore.swift
//  NewTerm Common
//

import Foundation
import os.log

/// Persists a tab's recent terminal output so it survives the app being killed.
///
/// Stores the raw pty bytes, not rendered lines: replaying the exact byte stream back through the
/// emulator on restore reconstructs colours, cursor position and scrollback for free, whereas
/// serialising rendered cells would have to reinvent all of that and still get it subtly wrong.
///
/// This is the self-contained half of session continuity — it brings back what the session *looked
/// like*. Resuming a live process is tmux's job, and orthogonal to this.
public final class ScrollbackStore {

	public static let shared = ScrollbackStore()

	/// The stream is capped so a long-running session can't grow the file without bound. The tail is
	/// what matters — the emulator's own scrollback is bounded anyway, so older bytes wouldn't survive
	/// replay. Cut on a UTF-8 boundary so replay never starts mid-codepoint.
	private static let maxBytes = 256 * 1024

	private let queue = DispatchQueue(label: "ws.hbang.Terminal.scrollback-store", qos: .utility)
	private let logger = Logger(subsystem: "ws.hbang.Terminal", category: "ScrollbackStore")

	private init() {
		#if DEBUG
		// A lead byte is kept; leading continuation bytes (0b10xxxxxx) are dropped so replay starts on a
		// codepoint boundary; an empty input stays empty.
		assert(Self.trimmedToBoundary(Data([0x41, 0xE4, 0xB8, 0xAD])) == Data([0x41, 0xE4, 0xB8, 0xAD]))
		assert(Self.trimmedToBoundary(Data([0x80, 0x80, 0x41])) == Data([0x41]))
		assert(Self.trimmedToBoundary(Data()) == Data())
		#endif
	}

	private static var directory: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		return base.appendingPathComponent("Scrollback", isDirectory: true)
	}

	private static func url(for id: String) -> URL {
		// The id is a UUID, so it's already a safe filename, but guard anyway against anything that
		// could climb out of the directory.
		let safe = id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
		return directory.appendingPathComponent("\(safe).bin")
	}

	// MARK: - Saving

	/// `data` is the whole captured tail for the tab. Writing is off the caller's thread and atomic.
	public func save(_ data: Data, id: String) {
		queue.async {
			do {
				try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
				try Self.trimmedToBoundary(data).write(to: Self.url(for: id), options: .atomic)
			} catch {
				// Losing scrollback is a cosmetic regression, never worth taking anything else down for.
				self.logger.error("Couldn’t save scrollback \(id): \(String(describing: error))")
			}
		}
	}

	// MARK: - Loading

	public func load(id: String) -> Data? {
		try? Data(contentsOf: Self.url(for: id))
	}

	public func discard(id: String) {
		queue.async {
			try? FileManager.default.removeItem(at: Self.url(for: id))
		}
	}

	/// Keep only the last `maxBytes`, then walk forward off any UTF-8 continuation bytes so the first
	/// byte we'd replay is the start of a codepoint.
	static func trimmedToBoundary(_ data: Data) -> Data {
		var slice = data.count > maxBytes ? data.suffix(maxBytes) : data
		// 0b10xxxxxx is a UTF-8 continuation byte; drop leading ones so we begin on a lead byte.
		while let first = slice.first, first & 0xC0 == 0x80 {
			slice = slice.dropFirst()
		}
		return Data(slice)
	}
}
