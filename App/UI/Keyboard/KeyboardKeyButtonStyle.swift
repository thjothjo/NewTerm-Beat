//
//  KeyboardButtonStyle.swift
//  NewTerm (iOS)
//
//  Created by Chris Harper on 11/21/21.
//

import SwiftUI
import SwiftUIX

struct KeyboardKeyButtonStyle: ButtonStyle {
	var selected = false
	var shadow = false
	var halfHeight = false
	var widthRatio: CGFloat?

	func makeBody(configuration: Configuration) -> some View {
		var height: CGFloat = 45
		let width = widthRatio == nil ? nil : height * widthRatio! * (isBigDevice ? 1.3 : 1)
		var fontSize: CGFloat = isBigDevice ? 18 : 15
		var cornerRadius = Design.keyRadius
		if halfHeight {
			height = (height / 2) - 1
			fontSize *= 0.9
			cornerRadius *= 0.7
		}
		let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

		return HStack(alignment: .center, spacing: 0) {
			configuration.label
				// Medium rather than regular: these are labels on a control, and at 15pt over a blurred
				// background regular weight reads as washed out.
				.font(.system(size: fontSize, weight: .medium).monospacedDigit())
				.padding(.horizontal, halfHeight ? 2 : 8)
				.padding(.vertical, halfHeight ? 0 : 6)
				.foregroundColor(selected ? Color(.systemBackground) : .primary)
		}
			.frame(minWidth: height, maxWidth: width)
			.frame(height: height)
			.background(background(shape: shape, isPressed: configuration.isPressed))
			.animation(nil)
	}

	/// An outline, with nothing behind it.
	///
	/// The keys used to be frosted. Against a light terminal that fill is a pale grey, and with 5pt
	/// between keys the row read as one continuous band across the bottom of the screen rather than as
	/// separate buttons. Without it each key is just its outline over whatever the terminal is showing.
	@ViewBuilder
	private func background<S: InsettableShape>(shape: S, isPressed: Bool) -> some View {
		if selected {
			shape
				.fill(Color.accentColor)
				.overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: Design.stroke))
		} else {
			shape
				// Pressed lightens on a dark keyboard and darkens on a light one, because it is the label
				// colour that inverts between them.
				.fill(Color.primary.opacity(isPressed ? 0.18 : 0))
				.overlay(shape.strokeBorder(Color.primary.opacity(0.22), lineWidth: Design.stroke))
				.shadow(color: shadow ? .black.opacity(0.25) : .clear,
								radius: shadow ? 1.5 : 0,
								x: 0,
								y: shadow ? 1 : 0)
		}
	}

	init(selected: Bool = false, hasShadow shadow: Bool = false, halfHeight: Bool = false, widthRatio: CGFloat? = nil) {
		self.selected = selected
		self.shadow = shadow
		self.halfHeight = halfHeight
		self.widthRatio = widthRatio
	}
}

extension ButtonStyle where Self == KeyboardKeyButtonStyle {
	/// A button style that mimicks the keys of the software keyboard.
	static func keyboardKey(selected: Bool = false, hasShadow shadow: Bool = false, halfHeight: Bool = false, widthRatio: CGFloat? = nil) -> KeyboardKeyButtonStyle {
		KeyboardKeyButtonStyle(selected: selected, hasShadow: shadow, halfHeight: halfHeight, widthRatio: widthRatio)
	}
}

struct KeyboardKeyButtonStyleContainer: View {
	var body: some View {
		HStack(alignment: .center, spacing: 5) {
			Button {

			} label: {
				Text("Ctrl")
			}
			.buttonStyle(.keyboardKey())

			Button {

			} label: {
				Image(systemName: .arrowDown)
			}
			.buttonStyle(.keyboardKey(widthRatio: 1))
		}
		.padding()
	}
}

struct KeyboardKeyButtonStyleContainer_Previews: PreviewProvider {
	static var previews: some View {
		ForEach(ColorScheme.allCases, id: \.self) { scheme in
			KeyboardKeyButtonStyleContainer()
				.preferredColorScheme(scheme)
				.previewLayout(.sizeThatFits)
		}
	}
}

