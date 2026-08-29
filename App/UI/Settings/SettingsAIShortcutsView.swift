//
//  SettingsAIShortcutsView.swift
//  NewTerm (iOS)
//

import SwiftUI
import SwiftUIX
import NewTermCommon

/// Managing the skills and personas the AI panel offers.
///
/// Deliberately thin. The file is the interface — an agent in the terminal can add a persona far
/// faster than anyone can type one on a phone, and it's the same file either way. This is here to
/// see what's in it, take something out, and be told where it lives.
struct SettingsAIShortcutsView: View {

	private struct Failure: Identifiable {
		var id: String { message }
		var message: String
	}

	@State private var shortcuts = [AIShortcut]()
	@State private var discovered = [AICommand]()
	@State private var failure: Failure?
	@State private var isAdding = false
	/// The one being changed. Adding and editing are the same sheet — the difference is whether it
	/// starts empty.
	@State private var editing: AIShortcut?

	var body: some View {
		PreferencesList {
			PreferencesGroup(header: Text("Yours"),
											 footer: Text("Kept in \(AIShortcutStore.displayPath). Ask an agent to edit that file and the panel follows — the schema is written at the top of it.")) {
				if shortcuts.isEmpty {
					Text("Nothing yet.")
						.foregroundColor(.secondary)
				}
				ForEach(shortcuts) { shortcut in
					Button {
						editing = shortcut
					} label: {
						VStack(alignment: .leading, spacing: 2) {
							HStack {
								Text(shortcut.name)
									.foregroundColor(.primary)
								Spacer()
								Text(shortcut.kind.rawValue)
									.font(.caption)
									.foregroundColor(.secondary)
							}
							// The note if it has one, because that says what the shortcut does; the text it
							// types is the implementation, and it's long.
							Text(shortcut.note?.isEmpty == false ? shortcut.note! : shortcut.command)
								.font(.caption)
								.foregroundColor(.secondary)
								.lineLimit(2)
								.frame(maxWidth: .infinity, alignment: .leading)
						}
					}
				}
					.onDelete { offsets in
						// Written back whole, so the file stays a file rather than becoming a log of edits.
						var kept = shortcuts
						kept.remove(atOffsets: offsets)
						write(kept)
					}

				Button {
					isAdding = true
				} label: {
					Label("Add", systemImage: .plus)
				}
			}

			PreferencesGroup(header: Text("Found Automatically"),
											 footer: Text("Installed agent CLIs, and the slash commands in ~/.claude and ~/.codex. These aren't editable here — installing or removing them is what changes the list.")) {
				if discovered.isEmpty {
					Text("Nothing found.")
						.foregroundColor(.secondary)
				}
				ForEach(discovered) { command in
					HStack {
						Text(command.name)
						Spacer()
						Text(command.source)
							.font(.caption)
							.foregroundColor(.secondary)
					}
				}
			}
		}
			.navigationBarTitle("AI Shortcuts")
			.onAppear(perform: reload)
			.onReceive(NotificationCenter.default.publisher(for: AIShortcutStore.didChangeNotification)) { _ in
				reload()
			}
			.sheet(isPresented: $isAdding) {
				AIShortcutEditor(existing: nil) { shortcut in
					do {
						try AIShortcutStore.add(shortcut)
					} catch {
						failure = Failure(message: error.localizedDescription)
					}
					reload()
				}
			}
			.sheet(item: $editing) { shortcut in
				AIShortcutEditor(existing: shortcut) { updated in
					do {
						try AIShortcutStore.update(shortcut, to: updated)
					} catch {
						failure = Failure(message: error.localizedDescription)
					}
					reload()
				}
			}
			.alert(item: $failure) { failure in
				Alert(title: Text("Couldn’t save"),
							message: Text(failure.message),
							dismissButton: .cancel(Text("OK")))
			}
	}

	private func write(_ kept: [AIShortcut]) {
		do {
			try AIShortcutStore.save(kept)
		} catch {
			failure = Failure(message: error.localizedDescription)
		}
		reload()
	}

	private func reload() {
		AIShortcutStore.createTemplateIfNeeded()
		shortcuts = AIShortcutStore.shortcuts()
		// The panel's list minus the ones that came from the file, so the two groups don't repeat.
		let mine = Set(shortcuts.map(\.name))
		discovered = AICatalog.commands().filter { !mine.contains($0.name) }
	}
}

/// Adding or changing one by hand, for when there's no agent around to ask.
private struct AIShortcutEditor: View {

	@Environment(\.presentationMode) private var presentationMode

	@State private var name: String
	@State private var command: String
	@State private var note: String
	@State private var kind: AIShortcut.Kind
	@State private var send: Bool

	private let isNew: Bool
	let onSave: (AIShortcut) -> Void

	init(existing: AIShortcut?, onSave: @escaping (AIShortcut) -> Void) {
		_name = State(initialValue: existing?.name ?? "")
		_command = State(initialValue: existing?.command ?? "")
		_note = State(initialValue: existing?.note ?? "")
		_kind = State(initialValue: existing?.kind ?? .persona)
		_send = State(initialValue: existing?.send ?? false)
		isNew = existing == nil
		self.onSave = onSave
	}

	var body: some View {
		NavigationView {
			PreferencesList {
				PreferencesGroup {
					HStack {
						Text("Name")
						Spacer()
						TextField("Reviewer", text: $name)
							.multilineTextAlignment(.trailing)
							.foregroundColor(.secondary)
					}
					Picker("Kind", selection: $kind) {
						ForEach(AIShortcut.Kind.allCases, id: \.self) { kind in
							Text(kind.rawValue).tag(kind)
						}
					}
					Toggle("Send Immediately", isOn: $send)
				}

				PreferencesGroup(footer: Text("AI_SHORTCUT_NOTE_FOOTER")) {
					HStack {
						Text("NOTE")
						Spacer()
						TextField("", text: $note)
							.multilineTextAlignment(.trailing)
							.foregroundColor(.secondary)
					}
				}

				PreferencesGroup(header: Text("Text"),
												 footer: Text("Typed into the terminal exactly as written. For a persona, this is the instructions; for a skill, the slash command.")) {
					TextEditor(text: $command)
						.frame(minHeight: 120)
						.autocapitalization(.none)
						.disableAutocorrection(true)
				}
			}
				.navigationBarTitle(isNew ? Text("Add") : Text("EDIT"), displayMode: .inline)
				.navigationBarItems(
					leading: Button("Cancel") { presentationMode.wrappedValue.dismiss() },
					trailing: Button("Save") {
						onSave(AIShortcut(name: name.trimmingCharacters(in: .whitespaces),
															command: command,
															kind: kind,
															send: send,
															note: note.trimmingCharacters(in: .whitespaces).isEmpty
																? nil
																: note.trimmingCharacters(in: .whitespaces)))
						presentationMode.wrappedValue.dismiss()
					}
						.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || command.isEmpty)
				)
		}
	}
}
