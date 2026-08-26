//
//  StringSupplier.swift
//  NewTerm Common
//
//  Created by Adam Demasi on 2/4/21.
//

import Foundation
import SwiftTerm
import SwiftUI

fileprivate extension View {
	static func + (lhs: Self, rhs: some View) -> AnyView {
		AnyView(ViewBuilder.buildBlock(lhs, AnyView(rhs)))
	}
}

open class StringSupplier {

	/// Glyphs that don’t fit the cell width we allocated for them are scaled down rather than
	/// allowed to overflow. Emoji are the main offender: SwiftTerm’s buffer gives them one column,
	/// but the emoji font renders them at roughly 2.3× the monospace advance, so they would spill
	/// over neighbouring cells and off-screen.
	private static let minimumGlyphScale: CGFloat = 0.4

	open var terminal: Terminal!
	open var colorMap: ColorMap!
	open var fontMetrics: FontMetrics!
	open var cursorVisible = true

	public init() {}

	public func attributedString(forScrollInvariantRow row: Int) -> AnyView {
		guard let terminal = terminal else {
			fatalError()
		}

		guard let line = terminal.getScrollInvariantLine(row: row) else {
			return AnyView(EmptyView())
		}

		let cursorPosition = terminal.getCursorLocation()
		let scrollbackRows = terminal.getTopVisibleRow()

		var lastAttribute = Attribute.empty
		var views = [AnyView]()
		var buffer = ""
		var bufferCols = 0
		var j = 0
		while j < terminal.cols {
			let data = line[j]
			// A wide character owns the cells that follow it — SwiftTerm parks an empty placeholder
			// in each one. They hold no glyph, so they’re skipped, and the run takes its width from
			// the cell widths the buffer assigned rather than re-measuring the characters. Measuring
			// again disagrees with the buffer (a placeholder counts as another column, a ZWJ emoji
			// sums its parts), and every cell of disagreement pushes the line further off-screen.
			let cellCols = max(1, Int(data.width))
			let isCursor = cursorVisible && row - scrollbackRows == cursorPosition.y
				&& cursorPosition.x >= j && cursorPosition.x < j + cellCols

			if isCursor || lastAttribute != data.attribute {
				// Finish up the last run by appending it to the attributed string, then reset for the
				// next run.
				views.append(text(buffer, cols: bufferCols, attribute: lastAttribute))
				lastAttribute = data.attribute
				buffer.removeAll()
				bufferCols = 0
			}

			let character = data.getCharacter()
			buffer.append(character == "\0" ? " " : character)
			bufferCols += cellCols

			if isCursor {
				views.append(text(buffer, cols: bufferCols, attribute: lastAttribute, isCursor: true))
				buffer.removeAll()
				bufferCols = 0
			}

			j += cellCols
		}

		// Append the final run
		views.append(text(buffer, cols: bufferCols, attribute: lastAttribute))

		return AnyView(HStack(alignment: .firstTextBaseline, spacing: 0) {
			views.reduce(AnyView(EmptyView()), { $0 + $1 })
		})
	}

	private func text(_ run: String, cols: Int, attribute: Attribute, isCursor: Bool = false) -> AnyView {
		var fgColor = attribute.fg
		var bgColor = attribute.bg

		if attribute.style.contains(.inverse) {
			swap(&bgColor, &fgColor)
			if fgColor == .defaultColor {
				fgColor = .defaultInvertedColor
			}
			if bgColor == .defaultColor {
				bgColor = .defaultInvertedColor
			}
		}

		let foreground = colorMap?.color(for: fgColor,
																		 isForeground: true,
																		 isBold: attribute.style.contains(.bold),
																		 isCursor: isCursor)
		let background = colorMap?.color(for: bgColor,
																		 isForeground: false,
																		 isCursor: isCursor)

		let font: UIFont?
		if attribute.style.contains(.bold) || attribute.style.contains(.blink) {
			font = attribute.style.contains(.italic) ? fontMetrics?.boldItalicFont : fontMetrics?.boldFont
		} else if attribute.style.contains(.dim) {
			font = attribute.style.contains(.italic) ? fontMetrics?.lightItalicFont : fontMetrics?.lightFont
		} else {
			font = attribute.style.contains(.italic) ? fontMetrics?.italicFont : fontMetrics?.regularFont
		}

		let width = CGFloat(cols) * (fontMetrics?.width ?? 0)

		return AnyView(
			Text(run)
				// Text attributes
				.foregroundColor(Color(foreground ?? .white))
				.font(Font(font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)))
				.underline(attribute.style.contains(.underline))
				.strikethrough(attribute.style.contains(.crossedOut))
				.tracking(0)
				// View attributes
				.allowsTightening(false)
				.lineLimit(1)
				.minimumScaleFactor(Self.minimumGlyphScale)
				// Leading, not the default centre. A run of full-width characters draws narrower than
				// the two cells each is allotted, and centring shares that slack out to both sides —
				// which pushed every line containing CJK a couple of columns to the right of the ASCII
				// lines above and below it.
				.frame(width: width, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)
				// Background goes after the frame so it paints the whole cell run. Applied before it,
				// it would track the glyphs’ intrinsic width instead, leaving gaps between cells for
				// narrow runs and bleeding past them for wide ones.
				.background(Color(background ?? .black))
				.clipped()
		)
	}

}
