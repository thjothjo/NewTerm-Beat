//
//  SettingsICloudView.swift
//  NewTerm (iOS)
//

import SwiftUI
import SwiftUIX
import UniformTypeIdentifiers
import NewTermCommon

/// Copying projects to and from iCloud Drive, so they can be worked with from a Mac.
///
/// Copies rather than the projects living in iCloud Drive directly. The terminal's shell is a
/// separate process, and the entitlement that lets this app into `Mobile Documents` isn't inherited
/// across exec — measured on-device — so a project kept there would be listed and never openable.
struct SettingsICloudView: View {

	private struct Failure: Identifiable {
		var id: String { message }
		var message: String
	}

	/// What a copy is about to overwrite, held until the user says go ahead.
	private struct PendingCopy: Identifiable {
		enum Direction { case export, importing }
		var id: String { "\(name)-\(direction == .export ? "out" : "in")" }
		var direction: Direction
		var name: String
		/// Files iCloud hasn't downloaded, which would arrive as empty placeholders.
		var evicted: [String] = []
	}

	@ObservedObject private var preferences = Preferences.shared

	@State private var projects = ProjectManager.projects()
	@State private var isChoosingFolder = false
	@State private var iCloudNames = [String]()
	@State private var unavailable: String? = ProjectManager.iCloudUnavailableReason()
	@State private var pending: PendingCopy?
	@State private var failure: Failure?
	@State private var busyName: String?

	var body: some View {
		PreferencesList {
			// Outside the availability check on purpose. Picking a folder is the way out of not being
			// able to reach the default one, so hiding it exactly when the default is unreachable would
			// leave nothing to do about it.
			PreferencesGroup(footer: Text("Copies go into this folder. It’s created on the first copy if it isn’t there yet.")) {
				Button {
					isChoosingFolder = true
				} label: {
					HStack {
						Text("Folder")
							.foregroundColor(.primary)
						Spacer()
						Text(ProjectManager.iCloudFolderName)
							.foregroundColor(.secondary)
						Image(systemName: .chevronRight)
							.foregroundColor(.secondary)
							.imageScale(.small)
					}
				}
			}

			if let unavailable = unavailable {
				PreferencesGroup(footer: Text("Projects stay on this device. Nothing is copied anywhere until you ask for it.")) {
					Text(unavailable)
						.foregroundColor(.secondary)
				}
			} else {
				PreferencesGroup(header: Text("Copy to iCloud Drive"),
												 footer: Text("Puts a copy in iCloud Drive/\(ProjectManager.iCloudFolderName), where it shows up on your Mac. Replaces whatever is already there under the same name.")) {
					if projects.isEmpty {
						Text("No projects yet.")
							.foregroundColor(.secondary)
					}
					ForEach(projects) { project in
						row(name: project.name, symbol: .arrowUp) {
							pending = PendingCopy(direction: .export, name: project.name)
						}
					}
				}

				PreferencesGroup(header: Text("Copy from iCloud Drive"),
												 footer: Text("Replaces the project of the same name on this device. There is no merge — the copy in iCloud Drive wins outright.")) {
					if iCloudNames.isEmpty {
						Text("Nothing in iCloud Drive/\(ProjectManager.iCloudFolderName) yet.")
							.foregroundColor(.secondary)
					}
					ForEach(iCloudNames, id: \.self) { name in
						row(name: name, symbol: .arrowDown) {
							pending = PendingCopy(direction: .importing,
																		name: name,
																		evicted: ProjectManager.evictedFileNames(inICloudProjectNamed: name))
						}
					}
				}
			}
		}
			.navigationBarTitle("iCloud Drive")
			.onAppear(perform: reload)
			// The system picker rather than a list of our own: it browses iCloud Drive, On My iPhone and
			// anything else Files can see, which is more than we could enumerate ourselves.
			.fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
				if case .success(let url) = result {
					preferences.iCloudFolderPath = url.path
					reload()
				}
			}
			.alert(item: $pending) { copy in confirmation(for: copy) }
			.alert(item: $failure) { failure in
				Alert(title: Text("Couldn’t copy"),
							message: Text(failure.message),
							dismissButton: .cancel(Text("OK")))
			}
	}

	private func row(name: String, symbol: SFSymbolName, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			HStack {
				Text(name)
					.foregroundColor(.primary)
				Spacer()
				if busyName == name {
					ProgressView()
				} else {
					Image(systemName: symbol)
						.foregroundColor(.accentColor)
				}
			}
		}
			.disabled(busyName != nil)
	}

	private func confirmation(for copy: PendingCopy) -> Alert {
		let title: Text
		let message: Text
		switch copy.direction {
		case .export:
			title = Text("Copy “\(copy.name)” to iCloud Drive?")
			message = iCloudNames.contains(copy.name)
				? Text("The copy already in iCloud Drive will be replaced. Anything changed there and not copied back is lost.")
				: Text("A copy goes to iCloud Drive/\(ProjectManager.iCloudFolderName).")
		case .importing:
			title = Text("Copy “\(copy.name)” from iCloud Drive?")
			let base = projects.contains(where: { $0.name == copy.name })
				? "The project on this device will be replaced."
				: "It’s added as a new project."
			// Named rather than counted: which files come back empty is the thing that decides whether
			// to go and open them on the Mac first.
			message = copy.evicted.isEmpty
				? Text(base)
				: Text("\(base)\n\n\(copy.evicted.count) file(s) aren’t downloaded and would arrive empty, starting with \(copy.evicted.prefix(3).joined(separator: ", ")). Open the folder on your Mac to download them first.")
		}
		return Alert(title: title,
								 message: message,
								 primaryButton: .destructive(Text("Copy")) { perform(copy) },
								 secondaryButton: .cancel())
	}

	private func perform(_ copy: PendingCopy) {
		busyName = copy.name
		// Off the main thread: a project is a directory of source, and copying it is not instant.
		DispatchQueue.global(qos: .userInitiated).async {
			var thrown: Error?
			do {
				switch copy.direction {
				case .export:
					guard let project = projects.first(where: { $0.name == copy.name }) else {
						return
					}
					try ProjectManager.exportToICloud(project)
				case .importing:
					try ProjectManager.importFromICloud(named: copy.name)
				}
			} catch {
				thrown = error
			}
			DispatchQueue.main.async {
				busyName = nil
				if let thrown = thrown {
					failure = Failure(message: thrown.localizedDescription)
				}
				reload()
			}
		}
	}

	private func reload() {
		unavailable = ProjectManager.iCloudUnavailableReason()
		projects = ProjectManager.projects()
		iCloudNames = unavailable == nil ? ProjectManager.iCloudProjectNames() : []
	}
}
