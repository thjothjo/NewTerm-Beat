//
//  SettingsView.swift
//  NewTerm (iOS)
//
//  Created by Adam Demasi on 3/4/21.
//

import SwiftUI
import CoreHaptics
import NewTermCommon

fileprivate extension KeyboardArrowsStyle {
	var name: String {
		switch self {
		case .butterfly:   return "Butterfly"
		case .scissor:     return "Scissor"
		case .classic:     return "Classic"
		case .vim:         return "Vim"
		case .vimInverted: return "Vim Inverted"
		}
	}
}

fileprivate extension KeyboardTrackpadSensitivity {
	var name: String {
		switch self {
		case .off:    return "Off"
		case .low:    return "Low"
		case .medium: return "Medium"
		case .high:   return "High"
		}
	}
}

struct SettingsView: View {

	@Environment(\.presentationMode)
	var presentationMode

	@ObservedObject var preferences = Preferences.shared

	/// The bell settings as of the last change, so the first observation — which fires simply because
	/// the screen appeared — can be told apart from the user actually toggling something.
	@State private var lastBellSettings: [Bool]?

	var windowScene: UIWindowScene?

	@State private var keyboardToolbarState = KeyboardToolbarViewState()

	private func dismiss() {
		if let windowScene = windowScene {
			UIApplication.shared.requestSceneSessionDestruction(windowScene.session, options: nil, errorHandler: nil)
		} else {
			// TODO: presentationMode seems useless when UIKit is presenting
			// the view controller rather than SwiftUI? Ugh
//			presentationMode.wrappedValue.dismiss()
			NotificationCenter.default.post(name: RootViewController.settingsViewDoneNotification, object: nil)
		}
	}

	var body: some View {
		let list = List() {
			PreferencesGroup(header: Text("Terminal")) {
				NavigationLink(destination: SettingsFontView(),
											 label: { KeyValueView(title: Text("Font"),
																						 value: Text("\(preferences.fontName), \(Int(preferences.fontSize))")) })

				NavigationLink(destination: SettingsThemeView(),
											 label: { KeyValueView(title: Text("Theme"),
																						 value: Text(preferences.themeName)) })
			}

			PreferencesGroup(header: Text("Projects"),
											 footer: Text("Every folder in here is a project. Currently \(ProjectManager.rootURL.path). Opening a project in tmux is what lets its session survive the app being closed.")) {
				HStack {
					Text("Folder")
					Spacer()
					TextField(ProjectManager.defaultDirectory, text: preferences.$projectsDirectory)
						.multilineTextAlignment(.trailing)
						.autocapitalization(.none)
						.disableAutocorrection(true)
						.foregroundColor(.secondary)
				}

				Toggle("Open in tmux", isOn: preferences.$useTmuxForProjects)

				NavigationLink(destination: SettingsICloudView(),
											 label: { Text("iCloud Drive") })
			}

			PreferencesGroup(header: Text("AI")) {
				NavigationLink(destination: SettingsAIShortcutsView(),
											 label: { Text("AI Shortcuts") })
			}

			PreferencesGroup(header: Text("Keyboard"),
											 footer: Text("Touch and hold the Space bar, then drag around the keyboard to move the cursor.")) {
				PreferencesPicker(selection: preferences.$keyboardArrowsStyle,
													label: Text("Arrow Keys"),
													valueLabel: Text(preferences.keyboardArrowsStyle.name),
													asLink: true) {
					ForEach(KeyboardArrowsStyle.allCases, id: \.self) { key in
						HStack(alignment: .center) {
							Text(key.name)
							Spacer()
							KeyboardToolbarKeyStack(toolbar: .padPrimaryTrailing,
																			arrowsStyle: key)
								.environmentObject(keyboardToolbarState)
								.disabled(true)
						}
							.height(44)
					}
				}

				PreferencesPicker(selection: preferences.$keyboardTrackpadSensitivity,
													label: Text("Trackpad Sensitivity"),
													valueLabel: Text(preferences.keyboardTrackpadSensitivity.name),
													asStepper: true)
			}

			PreferencesGroup(header: Text("Bell"),
											 footer: Text("When a terminal application needs to notify you of something, it rings the bell.")) {
				Toggle("Make beep sound", isOn: preferences.$bellSound)
				if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
					Toggle("Make haptic vibration", isOn: preferences.$bellVibrate)
				}
				Toggle("Show heads-up display", isOn: preferences.$bellHUD)
			}

			PreferencesGroup {
				NavigationLink(destination: SettingsAdvancedView(),
											 label: { Text("Advanced") })
			}

			PreferencesGroup {
				NavigationLink(destination: SettingsAboutView(),
											 label: { Text("About") })
			}
		}
			.listStyle(InsetGroupedListStyle())
			// Demonstrating the bell is only meaningful when one of these is actually toggled. Comparing
			// against the value seen last is what makes that so: the observation fires once when the
			// screen appears, and every opening of Settings used to ring the bell for no reason.
			.onChange(of: [preferences.bellVibrate, preferences.bellSound]) { newValue in
				defer { lastBellSettings = newValue }
				guard let previous = lastBellSettings, previous != newValue else {
					return
				}
				HapticController.playBell()
			}

		return NavigationView {
			list
				.navigationBarTitle("SETTINGS", displayMode: .large)
				.navigationBarItems(trailing: Button(action: { self.dismiss() },
																						 label: { Text(verbatim: .done).bold() }))
		}
			.navigationViewStyle(StackNavigationViewStyle())
	}
}

struct SettingsView_Previews: PreviewProvider {
	static var previews: some View {
		SettingsView()
	}
}
