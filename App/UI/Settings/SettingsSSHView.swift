//
//  SettingsSSHView.swift
//  NewTerm (iOS)
//

import SwiftUI
import SwiftUIX
import UniformTypeIdentifiers
import NewTermCommon

/// Managing what's in `~/.ssh` — the hosts you can connect to, and the keys you log in with.
///
/// The keyboard's SSH row can add a host and connect to one, which is the whole job while there's
/// one server and it takes a password. This is the rest of it: changing an entry, removing one, and
/// making a key so there's nothing to type at all.
struct SettingsSSHView: View {

	private struct Failure: Identifiable {
		var id: String { message }
		var message: String
	}

	@State private var hosts = [SSHHost]()
	@State private var keys = [SSHKey]()
	@State private var failure: Failure?
	@State private var isAdding = false
	/// The one being changed. Adding and editing are the same sheet — the difference is whether it
	/// starts empty.
	@State private var editing: SSHHost?
	@State private var isGeneratingKey = false
	@State private var isImportingKey = false
	@State private var isWorking = false
	@State private var keysPendingDeletion = [SSHKey]()

	var body: some View {
		PreferencesList {
			PreferencesGroup(header: Text("Hosts"),
											 footer: Text("Kept in \(SSHConfig.displayPath), the file ssh itself reads. Connecting runs ssh with the name, so anything you add here works from the command line too.")) {
				if hosts.isEmpty {
					Text("Nothing yet.")
						.foregroundColor(.secondary)
				}
				ForEach(hosts) { host in
					Button {
						editing = host
					} label: {
						HStack(spacing: 12) {
							SettingsIcon(systemName: "network", tint: .appTeal)
							VStack(alignment: .leading, spacing: 2) {
								Text(host.name)
									.foregroundColor(.primary)
								// What it resolves to, and the key if it has one — the two things that decide
								// whether connecting will work.
								Text(subtitle(for: host))
									.font(.caption)
									.foregroundColor(.secondary)
									.lineLimit(1)
							}
							Spacer()
						}
					}
				}
					.onDelete { offsets in
						perform { for host in offsets.map({ hosts[$0] }) { try SSHConfig.removeHost(host) } }
					}

				Button {
					isAdding = true
				} label: {
					// Spelled out rather than `Label("Add", systemImage: .plus)`: that picks SwiftUIX's
					// overload, whose title is a String and so never reaches the strings file. It rendered
					// as "Add" in a Chinese UI, and the generate button rendered as its own key.
					Label { Text("Add") } icon: { Image(systemName: "plus") }
				}
			}

			PreferencesGroup(header: Text("Keys"),
											 footer: Text("SSH_KEYS_FOOTER")) {
				if isWorking {
					HStack {
						ProgressView()
						Text("Working…")
							.foregroundColor(.secondary)
					}
				}
				if keys.isEmpty {
					Text("SSH_NO_KEYS")
						.foregroundColor(.secondary)
				}
				ForEach(keys) { key in
					NavigationLink(destination: SSHKeyView(key: key)) {
						HStack(spacing: 12) {
							// A key ssh will refuse as it stands is worth saying so before the connection
							// fails with a message about file modes.
							SettingsIcon(systemName: key.arePermissionsSafe ? "key.fill" : "exclamationmark.triangle.fill",
													 tint: key.arePermissionsSafe ? .orange : .red)
							VStack(alignment: .leading, spacing: 2) {
								Text(key.name)
								Text(subtitle(for: key))
									.font(.caption)
									.foregroundColor(.secondary)
									.lineLimit(1)
							}
						}
					}
				}
					.onDelete { offsets in
						keysPendingDeletion = offsets.map { keys[$0] }
					}

				Button {
					isGeneratingKey = true
				} label: {
					Label { Text("SSH_GENERATE_KEY") } icon: { Image(systemName: "plus") }
				}
					.disabled(isWorking)

				Button {
					isImportingKey = true
				} label: {
					Label("SSH_IMPORT_KEY", systemImage: "folder")
				}
					.disabled(isWorking)
			}
		}
			.navigationBarTitle(Text("SSH"))
			.onAppear(perform: reload)
			.onReceive(NotificationCenter.default.publisher(for: SSHConfig.didChangeNotification)) { _ in
				reload()
			}
			.onReceive(NotificationCenter.default.publisher(for: SSHKeys.didChangeNotification)) { _ in
				reload()
			}
			.sheet(isPresented: $isAdding) {
				SSHHostEditor(existing: nil, keys: keys) { host in
					perform { try SSHConfig.addHost(host) }
				}
			}
			.sheet(item: $editing) { host in
				SSHHostEditor(existing: host, keys: keys) { updated in
					perform { try SSHConfig.updateHost(host, to: updated) }
				}
			}
			.sheet(isPresented: $isGeneratingKey) {
				SSHKeyGenerator { name, type, comment in
					performInBackground { try SSHKeys.generate(name: name, type: type, comment: comment) }
				}
			}
			// `.item` rather than a list of file types: a private key usually has no extension at all,
			// and picking the folder they're kept in is less fiddly than selecting four files by hand.
			.fileImporter(isPresented: $isImportingKey,
										allowedContentTypes: [.item],
										allowsMultipleSelection: true) { result in
				switch result {
				case .success(let urls):
					performInBackground { try SSHKeys.importKeys(from: urls) }
				case .failure(let error):
					failure = Failure(message: error.localizedDescription)
				}
			}
			.alert(item: $failure) { failure in
				Alert(title: Text("Couldn’t save"),
							message: Text(failure.message),
							dismissButton: .cancel(Text("OK")))
			}
			.actionSheet(isPresented: Binding(get: { !keysPendingDeletion.isEmpty },
																 set: { if !$0 { keysPendingDeletion = [] } })) {
				ActionSheet(title: Text("Delete SSH key?"),
								message: Text(keysPendingDeletion.map(\.name).joined(separator: ", ")),
								buttons: [
									.destructive(Text("Delete")) {
										let keys = keysPendingDeletion
										keysPendingDeletion = []
										performInBackground {
											for key in keys { try SSHKeys.remove(key) }
										}
									},
									.cancel { keysPendingDeletion = [] }
								])
			}
	}

	private func subtitle(for host: SSHHost) -> String {
		let key = host.identityFile.isEmpty
			? ""
			: (host.identityFile as NSString).lastPathComponent
		switch (host.detail.isEmpty, key.isEmpty) {
		case (true, true):   return host.name
		case (true, false):  return key
		case (false, true):  return host.detail
		case (false, false): return "\(host.detail) · \(key)"
		}
	}

	/// What the key is, or what's wrong with it — whichever the user needs to know first.
	private func subtitle(for key: SSHKey) -> String {
		if !key.arePermissionsSafe {
			return String(format: .localize("SSH_KEY_PERMISSIONS_OPEN"), String(key.permissions, radix: 8))
		}
		guard key.hasPublicKey else {
			return .localize("SSH_KEY_NO_PUBLIC")
		}
		return key.comment.isEmpty ? key.type : "\(key.type) · \(key.comment)"
	}

	/// Runs something that writes to disk, and puts whatever went wrong in front of the user.
	///
	/// Every write here can fail the same way — the directory is read-only, the file is owned by
	/// someone else, ssh-keygen isn't installed — and failing silently would leave the list looking
	/// like the edit worked.
	private func perform(_ work: () throws -> Void) {
		do {
			try work()
		} catch {
			let message = error.localizedDescription
			// Presented a beat later, because most of these are called from a sheet's Save button while
			// that sheet is dismissing, and SwiftUI drops an alert presented into a dismissal already in
			// flight. Measured on the simulator: generating a key failed, and nothing at all was shown.
			// Only the alert waits — the work itself has already happened, so a swipe-to-delete still
			// takes the row away immediately.
			DispatchQueue.main.asyncAfter(deadline: .now() + SSHHostEditor.dismissalDuration) {
				failure = Failure(message: message)
			}
		}
		reload()
	}

	private func performInBackground(_ work: @escaping () throws -> Void) {
		isWorking = true
		DispatchQueue.global(qos: .userInitiated).async {
			let result = Result { try work() }
			DispatchQueue.main.asyncAfter(deadline: .now() + SSHHostEditor.dismissalDuration) {
				isWorking = false
				if case .failure(let error) = result {
					failure = Failure(message: error.localizedDescription)
				}
				reload()
			}
		}
	}

	private func reload() {
		hosts = SSHConfig.hosts()
		keys = SSHKeys.keys()
	}
}

/// Adding or changing a host.
///
/// The four fields that decide where a connection goes, and which key it uses. Anything else — jump
/// hosts, forwarding, keepalives — is edited in the file, which stays the source of truth and keeps
/// whatever it already says when this sheet saves.
///
/// Not private, and deliberately: the keyboard's SSH row adds hosts too, and it used to do it with
/// its own four-field alert. Two editors meant two things to keep in step, and the alert had no room
/// for a key picker — so adding a host from the keyboard, which is where hosts actually get added,
/// was the one path that couldn't set up a key login.
struct SSHHostEditor: View {

	/// How long to wait before showing a failure raised by this editor or the key generator.
	///
	/// Both call back while they are dismissing, and an alert presented into a dismissal already in
	/// flight is dropped. Measured on the simulator: a failed key generation showed nothing at all.
	static let dismissalDuration: TimeInterval = 0.45

	@Environment(\.presentationMode) private var presentationMode

	@State private var name: String
	@State private var hostName: String
	@State private var user: String
	@State private var port: String
	@State private var identityFile: String

	private let isNew: Bool
	/// What's in `~/.ssh`, to pick from rather than type a path.
	let keys: [SSHKey]
	let onSave: (SSHHost) -> Void

	init(existing: SSHHost?, keys: [SSHKey], onSave: @escaping (SSHHost) -> Void) {
		_name = State(initialValue: existing?.name ?? "")
		_hostName = State(initialValue: existing?.hostName ?? "")
		_user = State(initialValue: existing?.user ?? "")
		_port = State(initialValue: existing?.port ?? "")
		_identityFile = State(initialValue: existing?.identityFile ?? "")
		isNew = existing == nil
		self.keys = keys
		self.onSave = onSave
	}

	/// The key already named by the config, when it isn't one of the files we found.
	///
	/// A path to a key kept somewhere else is still a working config, and a picker that quietly
	/// dropped it would break the host the first time anyone edited its port.
	private var unknownKey: String? {
		guard !identityFile.isEmpty,
					!keys.contains(where: { $0.configPath == identityFile }) else {
			return nil
		}
		return identityFile
	}

	var body: some View {
		NavigationView {
			PreferencesList {
				PreferencesGroup(footer: Text("SSH_HOST_NAME_FOOTER")) {
					field("Name", placeholder: "server", text: $name)
					field("SSH_HOST_NAME", placeholder: "example.com", text: $hostName, keyboardType: .URL)
					field("SSH_USER", placeholder: "root", text: $user)
					field("SSH_PORT", placeholder: "22", text: $port, keyboardType: .numberPad)
				}

				PreferencesGroup(header: Text("Keys"),
												 footer: Text("SSH_HOST_KEY_FOOTER")) {
					Picker(selection: $identityFile, label: Text("SSH_KEY")) {
						Text("SSH_KEY_NONE").tag("")
						if let path = unknownKey {
							Text((path as NSString).lastPathComponent).tag(path)
						}
						ForEach(keys) { key in
							Text(key.name).tag(key.configPath)
						}
					}
				}
			}
				.navigationBarTitle(isNew ? Text("Add") : Text("EDIT"), displayMode: .inline)
				// Titles are spelled out as `Text` throughout this file rather than passed as string
				// literals: SwiftUIX adds `String` overloads of Button and Label, and a literal binds to
				// those instead of SwiftUI's LocalizedStringKey ones — which renders the key itself in any
				// language but English.
				.navigationBarItems(
					leading: Button { presentationMode.wrappedValue.dismiss() } label: { Text("Cancel") },
					trailing: Button {
						onSave(SSHHost(name: trimmed(name),
													 hostName: trimmed(hostName),
													 user: trimmed(user),
													 port: trimmed(port),
													 identityFile: identityFile))
						presentationMode.wrappedValue.dismiss()
					} label: {
						Text("Save")
					}
						.disabled(trimmed(name).isEmpty)
				)
		}
	}

	private func field(_ title: LocalizedStringKey,
										 placeholder: String,
										 text: Binding<String>,
										 keyboardType: UIKeyboardType = .default) -> some View {
		HStack {
			Text(title)
			Spacer()
			TextField(placeholder, text: text)
				.keyboardType(keyboardType)
				.multilineTextAlignment(.trailing)
				.autocapitalization(.none)
				.disableAutocorrection(true)
				.foregroundColor(.secondary)
		}
	}

	private func trimmed(_ string: String) -> String {
		string.trimmingCharacters(in: .whitespaces)
	}
}

/// One key: where it's stored, what state it's in, and the public half to put on the server.
private struct SSHKeyView: View {

	private struct Failure: Identifiable {
		var id: String { message }
		var message: String
	}

	/// Re-read after every action here, so the row that said "fix this" goes away once it's fixed.
	@State private var key: SSHKey
	@State private var didCopy = false
	@State private var failure: Failure?
	@State private var isWorking = false

	init(key: SSHKey) {
		_key = State(initialValue: key)
	}

	var body: some View {
		PreferencesList {
			PreferencesGroup(footer: Text("SSH_KEY_STORAGE_FOOTER")) {
				if !key.type.isEmpty {
					KeyValueView(title: Text("SSH_KEY_TYPE"), value: Text(key.type))
				}
				KeyValueView(title: Text("SSH_KEY_FILE"), value: Text(key.configPath))
				if !key.comment.isEmpty {
					KeyValueView(title: Text("NOTE"), value: Text(key.comment))
				}
				KeyValueView(title: Text("SSH_KEY_PERMISSIONS"),
										 value: Text(verbatim: String(key.permissions, radix: 8))
											.foregroundColor(key.arePermissionsSafe ? .secondary : .red))

				if !key.arePermissionsSafe {
					// ssh refuses a key others can read, and says so in a message about file modes that
					// reads as the key being broken. One tap is the whole fix.
					Button {
						perform { try SSHKeys.fixPermissions(for: key) }
					} label: {
						Label("SSH_KEY_FIX_PERMISSIONS", systemImage: "lock.fill")
					}
				}
			}

			PreferencesGroup(header: Text("SSH_PUBLIC_KEY"),
											 footer: Text("SSH_PUBLIC_KEY_FOOTER")) {
				if key.hasPublicKey {
					Text(key.publicKey)
						.font(.system(size: 12, design: .monospaced))
						.foregroundColor(.secondary)

					Button {
						UIPasteboard.general.string = key.publicKey
						didCopy = true
					} label: {
						// Two branches rather than a ternary inside Label: a conditional between two string
						// literals types as String, which is the overload that doesn't localize.
						if didCopy {
							Label("SSH_COPIED", systemImage: "checkmark")
						} else {
							Label("Copy", systemImage: "doc.on.doc")
						}
					}
				} else {
					// A key that arrived on its own. ssh doesn't need the .pub file, but you do — it's the
					// line the server wants, and it can be worked back out of the private half.
					Text("SSH_KEY_NO_PUBLIC")
						.foregroundColor(.secondary)

					Button {
						isWorking = true
						DispatchQueue.global(qos: .userInitiated).async {
							let result = Result { try SSHKeys.recoverPublicKey(for: key) }
							DispatchQueue.main.async {
								isWorking = false
								if case .failure(let error) = result {
									failure = Failure(message: error.localizedDescription)
								}
								if let updated = SSHKeys.keys().first(where: { $0.path == key.path }) {
									key = updated
								}
							}
						}
					} label: {
						if isWorking {
							ProgressView()
						} else {
							Label("SSH_KEY_RECOVER_PUBLIC", systemImage: "wand.and.stars")
						}
					}
						.disabled(isWorking)
				}
			}
		}
			.navigationBarTitle(Text(key.name), displayMode: .inline)
			.alert(item: $failure) { failure in
				Alert(title: Text("Couldn’t save"),
							message: Text(failure.message),
							dismissButton: .cancel(Text("OK")))
			}
	}

	private func perform(_ work: () throws -> Void) {
		do {
			try work()
		} catch {
			failure = Failure(message: error.localizedDescription)
		}
		if let updated = SSHKeys.keys().first(where: { $0.path == key.path }) {
			key = updated
		}
	}
}

/// Making a key, for the common case of not having one yet.
private struct SSHKeyGenerator: View {

	@Environment(\.presentationMode) private var presentationMode

	@State private var type = SSHKeyType.ed25519
	/// The name `ssh` looks for by default, so a host with no `IdentityFile` finds it anyway.
	@State private var name = SSHKeyType.ed25519.defaultFileName
	@State private var comment = ""

	let onGenerate: (String, SSHKeyType, String) -> Void

	var body: some View {
		NavigationView {
			PreferencesList {
				PreferencesGroup(footer: Text("SSH_GENERATE_FOOTER")) {
					Picker(selection: $type, label: Text("SSH_KEY_TYPE")) {
						ForEach(SSHKeyType.allCases) { type in
							Text(verbatim: type.label).tag(type)
						}
					}

					HStack {
						Text("SSH_KEY_FILE")
						Spacer()
						TextField(type.defaultFileName, text: $name)
							.multilineTextAlignment(.trailing)
							.autocapitalization(.none)
							.disableAutocorrection(true)
							.foregroundColor(.secondary)
					}
				}

				PreferencesGroup(footer: Text("SSH_KEY_COMMENT_FOOTER")) {
					HStack {
						Text("NOTE")
						Spacer()
						TextField("newterm@\(UIDevice.current.name)", text: $comment)
							.multilineTextAlignment(.trailing)
							.autocapitalization(.none)
							.disableAutocorrection(true)
							.foregroundColor(.secondary)
					}
				}
			}
				// The name follows the type, because `id_rsa` is what ssh looks for when it wants an RSA
				// key and `id_ed25519` is not. Only while the name is still a default one — a name the
				// user typed is theirs, and changing the type doesn't get to overwrite it.
				.onChange(of: type) { newType in
					if SSHKeyType.allCases.contains(where: { $0.defaultFileName == name }) {
						name = newType.defaultFileName
					}
				}
				.navigationBarTitle(Text("SSH_GENERATE_KEY"), displayMode: .inline)
				.navigationBarItems(
					leading: Button { presentationMode.wrappedValue.dismiss() } label: { Text("Cancel") },
					trailing: Button {
						onGenerate(name.trimmingCharacters(in: .whitespaces),
											 type,
											 comment.trimmingCharacters(in: .whitespaces))
						presentationMode.wrappedValue.dismiss()
					} label: {
						Text("SSH_GENERATE")
					}
						.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
				)
		}
	}
}
