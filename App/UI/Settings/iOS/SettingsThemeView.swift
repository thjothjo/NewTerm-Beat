//
//  SettingsThemeView.swift
//  NewTerm (iOS)
//
//  Created by Adam Demasi on 3/4/21.
//

import SwiftUI

struct SettingsThemeView: View {

	private let predefinedThemes = AppTheme.predefined
	private let sortedThemes = AppTheme.predefined
		.sorted(by: { a, b in a.key < b.key })
	private let lightThemes = AppTheme.predefined
		.filter { !$0.value.isDark }
		.sorted(by: { a, b in a.key < b.key })
	private let darkThemes = AppTheme.predefined
		.filter { $0.value.isDark }
		.sorted(by: { a, b in a.key < b.key })

	@ObservedObject var preferences = Preferences.shared

	var body: some View {
		VStack(spacing: 0) {
			TerminalSampleView(fontMetrics: preferences.fontMetrics,
												 colorMap: preferences.colorMap)

			PreferencesList {
				PreferencesGroup(footer: Text("Switches between a light and a dark theme when iOS does.")) {
					Toggle("Match System Appearance", isOn: preferences.$followsSystemAppearance)
				}

				if preferences.followsSystemAppearance {
					PreferencesGroup(header: Text("Light Theme")) {
						PreferencesPicker(selection: preferences.$lightThemeName, label: EmptyView()) {
							ForEach(lightThemes, id: \.key) { item in Text(item.key) }
						}
					}
					PreferencesGroup(header: Text("Dark Theme")) {
						PreferencesPicker(selection: preferences.$darkThemeName, label: EmptyView()) {
							ForEach(darkThemes, id: \.key) { item in Text(item.key) }
						}
					}
				} else {
					PreferencesGroup(header: Text("Built in Themes")) {
						PreferencesPicker(selection: preferences.$themeName, label: EmptyView()) {
							ForEach(sortedThemes, id: \.key) { item in Text(item.key) }
						}
					}
				}
			}
		}
			.navigationBarTitle("Theme")
	}

}

struct SettingsThemeView_Previews: PreviewProvider {
	static var previews: some View {
		NavigationView {
			SettingsThemeView()
		}
	}
}
