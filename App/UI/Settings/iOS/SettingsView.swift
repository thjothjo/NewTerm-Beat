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

	/// How much terminal output is on disk right now, so the button can say what it's about to clear.
	@State private var savedBytes = 0

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

			PreferencesGroup(header: Text("Privacy"),
											 footer: Text("Saved output is whatever was on screen, which can include a token or a password a program printed back. Turning this off clears what's already saved.")) {
				Toggle("Save Terminal History", isOn: preferences.$saveScrollback)

				Button {
					ScrollbackStore.shared.discardAll()
					savedBytes = 0
				} label: {
					HStack {
						Text("Clear Saved History")
							.foregroundColor(savedBytes > 0 ? .red : .secondary)
						Spacer()
						Text(ByteCountFormatter.string(fromByteCount: Int64(savedBytes), countStyle: .file))
							.foregroundColor(.secondary)
					}
				}
					.disabled(savedBytes == 0)
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
				// Demonstrated from the toggle itself rather than by observing the value. An observation
				// fires when the screen appears too, which is why opening Settings used to ring the bell
				// — and turning one *off* is not an occasion to play it either.
				Toggle("Make beep sound", isOn: Binding(
					get: { preferences.bellSound },
					set: { isOn in
						preferences.bellSound = isOn
						if isOn { HapticController.playBell() }
					}))
				if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
					Toggle("Make haptic vibration", isOn: Binding(
						get: { preferences.bellVibrate },
						set: { isOn in
							preferences.bellVibrate = isOn
							if isOn { HapticController.playBell() }
						}))
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
			.onAppear { savedBytes = ScrollbackStore.shared.totalBytes() }
			.onChange(of: preferences.saveScrollback) { isOn in
				// Off means gone, not merely "no more from now on".
				if !isOn {
					ScrollbackStore.shared.discardAll()
				}
				savedBytes = ScrollbackStore.shared.totalBytes()
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
