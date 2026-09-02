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
	/// Near-theme full-row fills read as mismatched strips rather than useful terminal state.
	/// ponytail: Keep the fixed threshold until a program exposes semantic roles for these rows.
	private static let subtleBackgroundDifference: CGFloat = 16 / 255

	open var terminal: Terminal!
	open var colorMap: ColorMap!
	open var fontMetrics: FontMetrics!
	open var cursorVisible = true

	public init() {
		#if DEBUG
		assert(Self.isSubtleVariant(UIColor(white: 244 / 255, alpha: 1), of: .white))
		assert(Self.isSubtleVariant(.white, of: UIColor(white: 244 / 255, alpha: 1)))
		assert(!Self.isSubtleVariant(UIColor(red: 0, green: 120 / 255, blue: 1, alpha: 1), of: .white))
		#endif
	}

	private static func isSubtleVariant(_ color: UIColor, of background: UIColor) -> Bool {
		var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
		var backgroundRed: CGFloat = 0, backgroundGreen: CGFloat = 0, backgroundBlue: CGFloat = 0, backgroundAlpha: CGFloat = 0
		guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha),
					background.getRed(&backgroundRed, green: &backgroundGreen, blue: &backgroundBlue, alpha: &backgroundAlpha) else {
			return false
		}
		let difference = Self.subtleBackgroundDifference
		return abs(red - backgroundRed) <= difference
			&& abs(green - backgroundGreen) <= difference
			&& abs(blue - backgroundBlue) <= difference
			&& abs(alpha - backgroundAlpha) <= difference
	}

	/// Whether a row holds nothing worth drawing.
	///
	/// The buffer always carries a full screen of rows, so a terminal showing one line of output still
	/// hands over a screen's worth of empty ones. Drawn, they make the content taller than the view,
	/// which lets it scroll, which puts the line that mattered above the top edge.
	public func isBlank(scrollInvariantRow row: Int) -> Bool {
		guard let terminal = terminal,
					let line = terminal.getScrollInvariantLine(row: row) else {
			return true
		}

		// A row with nothing on it but the cursor still has to be drawn.
		if cursorVisible && row - terminal.getTopVisibleRow() == terminal.getCursorLocation().y {
			return false
		}

		for column in 0..<terminal.cols {
			let data = line[column]
			let character = data.getCharacter()
			if character != " " && character != "\0" {
				return false
			}
			// Blank, but not invisible: a status bar drawn as coloured spaces is still something. Only
			// the background is asked about — the buffer fills empty cells with whatever attribute was
			// current, so comparing the whole attribute finds every row non-blank.
			if data.attribute.bg != .defaultColor {
				return false
			}
		}
		return true
	}

	public func attributedString(forScrollInvariantRow row: Int) -> AnyView {
		guard let terminal = terminal else {
			fatalError()
		}

		guard let line = terminal.getScrollInvariantLine(row: row) else {
			return AnyView(EmptyView())
		}

		let cursorPosition = terminal.getCursorLocation()
		let scrollbackRows = terminal.getTopVisibleRow()
		let inheritsSubtleRowBackground: Bool = {
			guard terminal.cols > 0 else {
				return false
			}
			let background = line[0].attribute.bg
			guard background != .defaultColor,
						(0..<terminal.cols).allSatisfy({ column in
							let attribute = line[column].attribute
							return attribute.bg == background && !attribute.style.contains(.inverse)
						}) else {
				return false
			}
			let renderedBackground = colorMap.color(for: background, isForeground: false)
			return Self.isSubtleVariant(renderedBackground, of: colorMap.background)
		}()

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
				views.append(text(buffer, cols: bufferCols, attribute: lastAttribute,
												 inheritsBackground: inheritsSubtleRowBackground))
				lastAttribute = data.attribute
				buffer.removeAll()
				bufferCols = 0
			}

			let character = data.getCharacter()

			// A wide character gets a run to itself, centred in the cells the buffer gave it. Its glyph
			// is only ~80% of the two cells it owns, so left-aligning a run of them leaves the slack
			// pooled at the right-hand end — which is what walked the cursor further from the text with
			// every character typed, and put the selection rectangle over the wrong cells. Per-character
			// framing pins every glyph to the grid the rest of the app measures against.
			if cellCols > 1 {
				if !buffer.isEmpty {
					views.append(text(buffer, cols: bufferCols, attribute: lastAttribute,
													 inheritsBackground: inheritsSubtleRowBackground))
					buffer.removeAll()
					bufferCols = 0
				}
				views.append(text(String(character), cols: cellCols, attribute: lastAttribute,
												 isCursor: isCursor, isWide: true,
												 inheritsBackground: inheritsSubtleRowBackground))
				j += cellCols
				continue
			}

			buffer.append(character == "\0" ? " " : character)
			bufferCols += cellCols

			if isCursor {
				views.append(text(buffer, cols: bufferCols, attribute: lastAttribute, isCursor: true,
												 inheritsBackground: inheritsSubtleRowBackground))
				buffer.removeAll()
				bufferCols = 0
			}

			j += cellCols
		}

		// Append the final run
		views.append(text(buffer, cols: bufferCols, attribute: lastAttribute,
								 inheritsBackground: inheritsSubtleRowBackground))

		return AnyView(HStack(alignment: .firstTextBaseline, spacing: 0) {
			views.reduce(AnyView(EmptyView()), { $0 + $1 })
		})
	}

	private func text(_ run: String,
								cols: Int,
								attribute: Attribute,
								isCursor: Bool = false,
								isWide: Bool = false,
								inheritsBackground: Bool = false) -> AnyView {
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
				// Narrow runs are leading-aligned so they sit flush on the grid. A wide character is
				// centred instead: its glyph is narrower than its two cells, and centring splits that
				// slack evenly rather than pooling it to one side. Because each wide character now has
				// its own frame, the slack can't accumulate across the line.
				.frame(width: width, alignment: isWide ? .center : .leading)
				.fixedSize(horizontal: false, vertical: true)
				// Background goes after the frame so it paints the whole cell run. Applied before it,
				// it would track the glyphs’ intrinsic width instead, leaving gaps between cells for
				// narrow runs and bleeding past them for wide ones.
				.background(inheritsBackground && !isCursor ? Color.clear : Color(background ?? .black))
				.clipped()
		)
	}

}
