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
											 label: { KeyValueView(icon: "textformat", iconTint: .appIndigo,
																						 title: Text("Font"),
																						 value: Text("\(preferences.fontName), \(Int(preferences.fontSize))")) })

				NavigationLink(destination: SettingsThemeView(),
											 label: { KeyValueView(icon: "paintpalette.fill", iconTint: .pink,
																						 title: Text("Theme"),
																						 value: Text(preferences.themeName)) })
			}

			PreferencesGroup(header: Text("Projects"),
											 footer: Text("Every folder in here is a project, at \((ProjectManager.rootURL.path as NSString).abbreviatingWithTildeInPath). Opening one in tmux is what lets its session survive the app being closed.")) {
				HStack(spacing: 12) {
					SettingsIcon(systemName: "folder.fill", tint: .orange)
					Text("Folder")
					Spacer()
					TextField(ProjectManager.defaultDirectory, text: preferences.$projectsDirectory)
						.multilineTextAlignment(.trailing)
						.autocapitalization(.none)
						.disableAutocorrection(true)
						.foregroundColor(.secondary)
				}

				Toggle(isOn: preferences.$useTmuxForProjects) {
					SettingsRow(icon: "rectangle.split.3x1.fill", tint: .appTeal) { Text("Open in tmux") }
				}

				NavigationLink(destination: SettingsICloudView(),
											 label: { SettingsRow(icon: "icloud.fill", tint: .blue) { Text("iCloud Drive") } })
			}

			PreferencesGroup(header: Text("SSH")) {
				NavigationLink(destination: SettingsSSHView(),
											 label: { SettingsRow(icon: "network", tint: .appTeal) { Text("SSH_HOSTS_AND_KEYS") } })
			}

			PreferencesGroup(header: Text("AI")) {
				NavigationLink(destination: SettingsAIShortcutsView(),
											 label: { SettingsRow(icon: "sparkles", tint: .purple) { Text("AI Shortcuts") } })
			}

			PreferencesGroup(header: Text("Privacy"),
											 footer: Text("Saved output is whatever was on screen, which can include a token or a password a program printed back. Turning this off clears what's already saved.")) {
				Toggle(isOn: preferences.$saveScrollback) {
					SettingsRow(icon: "clock.arrow.circlepath", tint: .appIndigo) { Text("Save Terminal History") }
				}

				Button {
					ScrollbackStore.shared.discardAll()
					savedBytes = 0
				} label: {
					HStack(spacing: 12) {
						SettingsIcon(systemName: "trash.fill", tint: savedBytes > 0 ? .red : .gray)
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
										icon: "arrow.up.arrow.down", iconTint: .blue,
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
										icon: "hand.point.up.left.fill", iconTint: .appTeal,
													asStepper: true)
			}

			PreferencesGroup(header: Text("Bell"),
											 footer: Text("When a terminal application needs to notify you of something, it rings the bell.")) {
				// Demonstrated from the toggle itself rather than by observing the value. An observation
				// fires when the screen appears too, which is why opening Settings used to ring the bell
				// — and turning one *off* is not an occasion to play it either.
				Toggle(isOn: Binding(
					get: { preferences.bellSound },
					set: { isOn in
						preferences.bellSound = isOn
						if isOn { HapticController.playBell() }
					})) {
					SettingsRow(icon: "speaker.wave.2.fill", tint: .orange) { Text("Make beep sound") }
				}
				if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
					Toggle(isOn: Binding(
						get: { preferences.bellVibrate },
						set: { isOn in
							preferences.bellVibrate = isOn
							if isOn { HapticController.playBell() }
						})) {
						SettingsRow(icon: "iphone.radiowaves.left.and.right", tint: .pink) { Text("Make haptic vibration") }
					}
				}
				Toggle(isOn: preferences.$bellHUD) {
					SettingsRow(icon: "bell.fill", tint: .yellow) { Text("Show heads-up display") }
				}
			}

			PreferencesGroup {
				NavigationLink(destination: SettingsAdvancedView(),
											 label: { SettingsRow(icon: "gearshape.2.fill", tint: .gray) { Text("Advanced") } })
			}

			PreferencesGroup {
				NavigationLink(destination: SettingsAboutView(),
											 label: { SettingsRow(icon: "info.circle.fill", tint: .blue) { Text("About") } })
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
