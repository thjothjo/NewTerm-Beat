//
//  ColorMap.swift
//  NewTerm Common
//
//  Created by Adam Demasi on 2/4/21.
//

import UIKit
import SwiftTerm
import os.log

public enum AnsiColorCode: Int, CaseIterable {
	case black, red, green, yellow, blue, purple, cyan, white
	case brightBlack, brightRed, brightGreen, brightYellow
	case brightBlue, brightPurple, brightCyan, brightWhite
}

public struct ColorMap: Hashable {

	public let background: UIColor
	public let foreground: UIColor
	public let foregroundBold: UIColor
	public let foregroundCursor: UIColor
	public let backgroundCursor: UIColor

	public let ansiColors: [AnsiColorCode: UIColor]

	public let isDark: Bool

	public var userInterfaceStyle: UIUserInterfaceStyle { isDark ? .dark : .light }

	/// The theme's text and background colours in the form the terminal reports them, for programs
	/// that ask what they are (OSC 10 and 11) before choosing their own palette.
	public var terminalForeground: SwiftTerm.Color { Self.terminalColor(foreground, fallback: isDark) }
	public var terminalBackground: SwiftTerm.Color { Self.terminalColor(background, fallback: !isDark) }

	/// Falls back to plain white or black, whichever the theme is closer to, so a colour that can't be
	/// read still answers with the right side of light versus dark.
	private static func terminalColor(_ color: UIColor, fallback white: Bool) -> SwiftTerm.Color {
		var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
		guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
			let value: UInt16 = white ? .max : 0
			return SwiftTerm.Color(red: value, green: value, blue: value)
		}
		func component(_ value: CGFloat) -> UInt16 {
			UInt16(min(max(value, 0), 1) * CGFloat(UInt16.max))
		}
		return SwiftTerm.Color(red: component(red), green: component(green), blue: component(blue))
	}

	private var colorCache = [Attribute.Color: UIColor]()

	public init(theme: AppTheme) {
		isDark = theme.isDark
		// The same reasoning as for the ANSI table below: a fallback that is a system colour has to be
		// read as the theme's appearance, not the device's.
		let themeTraits = UITraitCollection(userInterfaceStyle: theme.isDark ? .dark : .light)
		background = (UIColor(propertyListValue: theme.background) ?? .systemGroupedBackground)
			.resolvedColor(with: themeTraits)
		foreground = (UIColor(propertyListValue: theme.text) ?? .systemGray6)
			.resolvedColor(with: themeTraits)
		foregroundBold = (UIColor(propertyListValue: theme.boldText) ?? .label)
			.resolvedColor(with: themeTraits)
		foregroundCursor = (UIColor(propertyListValue: theme.cursor) ?? .systemGreen)
			.resolvedColor(with: themeTraits)
		backgroundCursor = foregroundCursor

		// TODO: For some reason .systemCyan doesn’t exist on macOS 12? Revisit this soon.
		var cyan: UIColor!
		if #available(iOS 15, *) {
			cyan = .systemCyan
		}
		if cyan == nil {
			cyan = UIColor(dynamicProvider: { _ in
				var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
				UIColor.systemBlue.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
				return UIColor(hue: h, saturation: s * 0.7, brightness: b * 1.3, alpha: a)
			})
		}

		var ansiColors: [AnsiColorCode: UIColor] = [
			.black:  .black,
			.red:    .systemRed,
			.green:  .systemGreen,
			.yellow: .systemYellow,
			.blue:   .systemBlue,
			.purple: .systemPurple,
			.cyan:   cyan,
			.white:  foreground,
			.brightBlack:  .darkGray,
			.brightRed:    .systemRed,
			.brightGreen:  .systemGreen,
			.brightYellow: .systemYellow,
			.brightBlue:   .systemBlue,
			.brightPurple: .systemPurple,
			.brightCyan:   cyan,
			.brightWhite:  foregroundBold
		]

		if let colorTable = theme.colorTable,
			 colorTable.count == 16 {
			for (i, value) in colorTable.enumerated() {
				if let color = UIColor(propertyListValue: value) {
					ansiColors[.allCases[i]] = color
				}
			}
		}

		// Pinned to the theme's own light or dark, not the device's.
		//
		// A theme without a colour table of its own falls back to system colours, and those resolve
		// against whatever appearance is current — so a light theme on a device in dark mode drew its
		// text with the dark-mode `.label`, which is white, on the theme's white background. The text
		// was there and invisible. The theme says which end of the ramp it wants; nothing else does.
		let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
		self.ansiColors = ansiColors.mapValues { $0.resolvedColor(with: traits) }
	}

	public mutating func color(for termColor: Attribute.Color, isForeground: Bool, isBold: Bool = false, isCursor: Bool = false) -> UIColor {
		if isCursor {
			if isForeground {
				switch termColor {
				case .defaultColor, .defaultInvertedColor: return background
				default: break
				}
			} else {
				return backgroundCursor
			}
		}

		switch termColor {
		case .defaultColor:
			return isForeground ? foreground : background

		case .defaultInvertedColor:
			return isForeground ? background : foreground

		case .ansi256(let ansi):
			// Bold promotes only the original 8 ANSI colours to their bright variants. It must not shift
			// arbitrary 256-colour palette entries into a different cube/grey value.
			let index = Int(ansi) + (isBold && ansi < 8 ? 8 : 0)
			if index < 16 {
				// ANSI color (0-15)
				return ansiColors[.allCases[index]]!
			}

			if let cachedColor = colorCache[termColor] {
				return cachedColor
			}

			let color: UIColor
			if index < 232 {
				// 256-color table (16-231)
				let tableIndex = index - 16
				let r = tableIndex / 36 == 0 ? 0 : ((tableIndex / 36) * 40 + 55)
				let g = tableIndex % 36 / 6 == 0 ? 0 : ((tableIndex % 36 / 6) * 40 + 55)
				let b = tableIndex % 6 == 0 ? 0 : (tableIndex % 6 * 40 + 55)
				color = UIColor(red: CGFloat(r) / 255,
												green: CGFloat(g) / 255,
												blue: CGFloat(b) / 255,
												alpha: 1)
			} else if index < 256 {
				// Greys (232-255)
				color = UIColor(white: ((CGFloat(index) - 232) * 10 + 8) / 255,
												alpha: 1)
			} else {
				Logger().warning("Unexpected color index: \(index)")
				color = foreground
			}
			colorCache[termColor] = color
			return color

		case .trueColor(let r, let g, let b):
			if let cachedColor = colorCache[termColor] {
				return cachedColor
			}

			let color = UIColor(red: CGFloat(r) / 255,
													green: CGFloat(g) / 255,
													blue: CGFloat(b) / 255,
													alpha: 1)
			colorCache[termColor] = color
			return color
		}
	}

}
