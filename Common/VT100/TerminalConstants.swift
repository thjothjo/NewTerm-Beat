//
//  TerminalConstants.swift
//  NewTerm Common
//
//  Created by Adam Demasi on 2/4/21.
//

import Foundation
import CoreGraphics

public struct ScreenSize: Hashable {
	public var cols: UInt16
	public var rows: UInt16
	public var pixelWidth: UInt16
	public var pixelHeight: UInt16

	public static let `default` = ScreenSize(cols: 80, rows: 25)

	public init(cols: UInt16, rows: UInt16, cellSize: CGSize = .zero) {
		self.cols = cols
		self.rows = rows
		self.pixelWidth = UInt16(cellSize.width)
		self.pixelHeight = UInt16(cellSize.height)
	}

	var windowSize: winsize {
		winsize(ws_row: rows,
						ws_col: cols,
						ws_xpixel: cols * pixelWidth,
						ws_ypixel: rows * pixelHeight)
	}
}

/// A range of cells the user has selected. Coordinates are scroll-invariant rows (the same ones
/// `StringSupplier` renders), so a selection stays on the text it was made on as new output pushes
/// the buffer along.
public struct TerminalSelection: Equatable {

	public struct Point: Equatable, Comparable {
		public var row: Int
		public var col: Int

		public init(row: Int, col: Int) {
			self.row = row
			self.col = col
		}

		public static func < (lhs: Self, rhs: Self) -> Bool {
			lhs.row == rhs.row ? lhs.col < rhs.col : lhs.row < rhs.row
		}
	}

	/// Where the selection started. Stays put while the user drags the other end.
	public var anchor: Point
	/// The end being dragged. May be before `anchor` when selecting backwards.
	public var head: Point

	public init(anchor: Point, head: Point) {
		self.anchor = anchor
		self.head = head
	}

	public init(row: Int, columns: Range<Int>) {
		self.init(anchor: Point(row: row, col: columns.lowerBound),
							head: Point(row: row, col: columns.upperBound))
	}

	public var start: Point { Swift.min(anchor, head) }
	public var end: Point { Swift.max(anchor, head) }
	public var isEmpty: Bool { anchor == head }

	/// Half-open range of columns covered on `row`, or nil if the row isn’t in the selection.
	/// Rows in the middle of a multi-line selection run the full width.
	public func columnRange(forRow row: Int, cols: Int) -> Range<Int>? {
		let start = start
		let end = end
		guard row >= start.row && row <= end.row else {
			return nil
		}
		let lower = row == start.row ? start.col : 0
		let upper = row == end.row ? end.col : cols
		return lower < upper ? lower..<upper : nil
	}
}

public struct EscapeSequences {

	// https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-PC-Style-Function-Keys

	public static let backspace = "\u{7f}".utf8Array
	public static let meta      = "\u{1b}".utf8Array
	public static let tab       = "\t".utf8Array
	/// Shift-Tab. Claude Code binds it to cycling permission modes.
	public static let backTab   = "\u{1b}[Z".utf8Array
	public static let `return`  = "\r".utf8Array

	public static let up        = "\u{1b}[A".utf8Array
	public static let upApp     = "\u{1b}OA".utf8Array
	public static let down      = "\u{1b}[B".utf8Array
	public static let downApp   = "\u{1b}OB".utf8Array
	public static let left      = "\u{1b}[D".utf8Array
	public static let leftApp   = "\u{1b}OD".utf8Array
	public static let leftMeta  = "b".utf8Array // (removed \e)
	public static let right     = "\u{1b}[C".utf8Array
	public static let rightApp  = "\u{1b}OC".utf8Array
	public static let rightMeta = "f".utf8Array // (removed \e)

	public static let home      = "\u{1b}[H".utf8Array
	public static let homeApp   = "\u{1b}OH".utf8Array
	public static let end       = "\u{1b}[F".utf8Array
	public static let endApp    = "\u{1b}OF".utf8Array
	public static let pageUp    = "\u{1b}[5~".utf8Array
	public static let pageDown  = "\u{1b}[6~".utf8Array
	public static let delete    = "\u{1b}[3~".utf8Array

	public static let fn        = [
		"OP", "OQ", "OR", "OS", "[15~", "[17~", "[18~", "[19~", "[20~", "[21~", "[23~", "[24~"
	].map { "\u{1b}\($0)".utf8Array }
}

public extension UTF8Char {
	var controlCharacter: UTF8Char {
		var newCharacter = self
		// Translate capital to lowercase
		if self >= 0x41 && self <= 0x5A { // >= 'A' <= 'Z'
			newCharacter += 0x61 - 0x41 // 'a' - 'A'
		}
		// Convert to the matching control character
		if self >= 0x61 && self <= 0x7A { // >= 'a' <= 'z'
			newCharacter -= 0x61 - 1 // 'a' - 1
		}
		return newCharacter
	}
}
