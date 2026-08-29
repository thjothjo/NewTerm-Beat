//
//  AppDesign.swift
//  NewTerm (iOS)
//

import SwiftUI
import SwiftUIX

/// The handful of numbers and materials that keep the chrome reading as one piece.
///
/// Radii, strokes and the blur style were previously chosen per view — 4pt here, 6pt there, a hard
/// grey fill in the keyboard and an outlined rectangle in the tab bar — which is why the chrome
/// looked assembled rather than designed. Everything that floats over the terminal comes from here.
enum Design {

	// MARK: - Shape

	/// Keyboard keys. Big enough to read as a soft capsule at 45pt tall without going oval.
	static let keyRadius: CGFloat = isBigDevice ? 11 : 9
	/// Tabs and other small chips.
	static let chipRadius: CGFloat = 8
	/// Panels that hold rows of the above.
	static let panelRadius: CGFloat = 14

	/// Edge highlight on glass. Thin on purpose: it is meant to catch the eye at the corner, not to
	/// draw a box.
	static let stroke: CGFloat = 0.5

	// MARK: - Material

	/// Chrome that sits over the terminal. Thin rather than ultra-thin so terminal text passing
	/// underneath stays a suggestion of movement instead of something you try to read.
	static let chromeBlur: UIBlurEffect.Style = .systemThinMaterial
	/// Controls raised above that chrome — keys, selected tabs.
	static let raisedBlur: UIBlurEffect.Style = .systemMaterial

	// MARK: - Glass

	/// Frosted fill plus the hairline that gives it an edge.
	///
	/// The stroke colour is the label colour rather than a fixed white, so the edge stays visible in
	/// both appearances instead of disappearing into a light background.
	@ViewBuilder
	static func glass<S: InsettableShape>(_ shape: S,
																				style: UIBlurEffect.Style = raisedBlur,
																				strokeOpacity: Double = 0.14) -> some View {
		BlurEffectView(style: style)
			.clipShape(shape)
			.overlay(shape.strokeBorder(Color.primary.opacity(strokeOpacity), lineWidth: stroke))
	}

	static var keyShape: RoundedRectangle {
		RoundedRectangle(cornerRadius: keyRadius, style: .continuous)
	}

	static var chipShape: RoundedRectangle {
		RoundedRectangle(cornerRadius: chipRadius, style: .continuous)
	}
}

extension Color {
	/// Backports for a 14.0 deployment target: these exist as `UIColor` long before they exist as
	/// `Color`, and the app supports iOS further back than SwiftUI added them.
	static let appIndigo = Color(UIColor.systemIndigo)
	static let appTeal = Color(UIColor.systemTeal)
}
