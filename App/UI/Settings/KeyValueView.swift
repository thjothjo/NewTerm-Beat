//
//  KeyValueView.swift
//  NewTerm (iOS)
//
//  Created by Adam Demasi on 3/4/21.
//

import SwiftUI

/// The tinted tile in front of a settings row.
///
/// A grouped list of nothing but text rows is uniform to the point of being unscannable — every line
/// looks the same, so finding one means reading all of them. A glyph on a colour lets you go
/// straight to the row you want, and the colour is doing the same job it does in the picker rows:
/// saying what kind of thing this is, not decorating.
struct SettingsIcon: View {
	var systemName: String
	var tint: Color

	var body: some View {
		RoundedRectangle(cornerRadius: 7, style: .continuous)
			.fill(tint)
			.frame(width: 29, height: 29)
			.overlay(
				Image(systemName: systemName)
					.font(.system(size: 15, weight: .semibold))
					.foregroundColor(.white)
			)
			// Never squeezed by a long title beside it.
			.fixedSize()
	}
}

/// A settings row that is a label and a control, with the tile in front of it.
struct SettingsRow<Content: View>: View {
	var icon: String
	var tint: Color
	@ViewBuilder var content: () -> Content

	var body: some View {
		HStack(spacing: 12) {
			SettingsIcon(systemName: icon, tint: tint)
			content()
		}
	}
}

struct KeyValueView<Title: View, Value: View>: View {

	/// SF Symbol for the tile in front of the row, or nil for a row that doesn't want one.
	var icon: String?
	var iconTint: Color = .gray
	var title: Title
	var value: Value

	init(icon: String? = nil, iconTint: Color = .gray, title: Title, value: Value) {
		self.icon = icon
		self.iconTint = iconTint
		self.title = title
		self.value = value
	}

	init(icon: String? = nil, iconTint: Color = .gray, title: Title, @ViewBuilder value: () -> (Value)) {
		self.icon = icon
		self.iconTint = iconTint
		self.title = title
		self.value = value()
	}

	var body: some View {
		HStack(spacing: 12) {
			// Nothing at all rather than an empty 29pt box: a row without a tile should sit where a
			// plain row sits, not indented as though its icon failed to load.
			if let icon = icon {
				SettingsIcon(systemName: icon, tint: iconTint)
			}
			title
			Spacer()
			value
				.lineLimit(1)
				.foregroundColor(.secondary)
		}
	}

}

struct KeyValueView_Previews: PreviewProvider {
	static var previews: some View {
		List {
			NavigationLink(destination: List() {},
										 label: { KeyValueView(title: Text("Font"),
																					 value: Text("SF Mono")) })
		}
		.listStyle(GroupedListStyle())
	}
}

