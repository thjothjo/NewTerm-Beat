//
//  KeyboardToolbarView.swift
//  NewTerm (iOS)
//
//  Created by Chris Harper on 11/21/21.
//

import SwiftUI
import NewTermCommon
import SwiftUIX

fileprivate struct Key {
	var label: String
	var glyph: String?
	var imageName: SFSymbolName?
	var preferredStyle: KeyboardButtonStyle?
	var isToggle = false
	var halfHeight = false
	var widthRatio: CGFloat?
	var keyRepeat: Bool?
}

enum Toolbar: CaseIterable {
	case primary, padPrimaryLeading, padPrimaryTrailing
	case secondary, fnKeys
	/// Not a row of keys — rendered as a list of projects. See `ProjectPickerRow`.
	case projects
	/// Not a row of keys — the hosts in `~/.ssh/config`. See `SSHHostPickerRow`.
	case sshHosts
	/// Not a row of keys — installed agent CLIs and the prompts they know. See `AIPickerRow`.
	case aiCommands
	/// Not a row of keys — the `[Image #N]` receipts for images attached since the last return. See
	/// `AttachmentStrip`.
	case attachments
	/// Vertical strip pinned to the screen edge, used instead of the accessory bar in landscape on
	/// iPhone where vertical space is the scarce resource and width isn’t.
	case sideBar
	/// What More opens beside the strip. `.secondary` without the keys the strip already shows.
	case sideBarMore

	var keys: [ToolbarKey] {
		switch self {
		case .primary:
			return [
				.control, .escape, .tab, .more, .projects,
				.variableSpace(id: 0),
				.arrows
			]

		case .projects, .sshHosts, .aiCommands, .attachments:
			return []

		case .sideBar:
			// Arrows are listed individually rather than as the `.arrows` cluster: the cluster is three
			// keys wide, which would make the strip eat far more width than it needs to.
			//
			// Image and Delete are not here even though they used to be: they live behind More, the same
			// place they live in portrait, which is what makes room for More and Projects without the
			// strip growing taller than the screen. Shift-Tab stays out in the open — Claude Code cycles
			// its permission modes on it, so it's pressed far too often to sit behind a toggle.
			return [.control, .escape, .tab, .shiftTab, .more, .projects,
							.up, .down, .left, .right]

		case .sideBarMore:
			return [.delete, .image, .ssh, .ai, .fnKeys]

		case .padPrimaryLeading:
			return [.control, .escape, .tab, .more, .projects]

		case .padPrimaryTrailing:
			return [.arrows]

		case .secondary:
			return [
				.shiftTab,
				.variableSpace(id: 0),
				.delete, .image, .ssh, .ai,
				.variableSpace(id: 1),
				.fnKeys
			]

		case .fnKeys:
			return Array(1...12).map { .fnKey(index: $0) }
		}
	}
}

enum ToolbarKey: Hashable {
	// Special
	case fixedSpace(id: Int)
	case variableSpace(id: Int)
	case arrows
	// Primary - leading
	case control, escape, tab, more
	// Primary - trailing
	case up, down, left, right
	/// Shift-Tab. Claude Code cycles its permission modes on this, which is the one keystroke that
	/// stops it asking to confirm every action.
	case shiftTab
	// Secondary - extras
	case delete, fnKeys
	// Projects
	case projects
	// Attach an image for a CLI to read
	case image
	/// The hosts in `~/.ssh/config`, to connect to one without typing it.
	case ssh
	/// Installed agent CLIs and the prompts they know.
	case ai
	// Fn keys
	case fnKey(index: Int)

	fileprivate var key: Key {
		switch self {
		// Special
		case .fixedSpace, .variableSpace, .arrows:
			return Key(label: "")

		// Primary - leading
		case .control:  return Key(label: .localize("Control"),
															 glyph: .localize("Ctrl"),
															 imageName: .control,
															 isToggle: true)
		case .escape:   return Key(label: .localize("Escape"),
															 glyph: .localize("Esc"),
															 imageName: .escape)
		case .tab:      return Key(label: .localize("Tab"),
															 imageName: .arrowRightToLine)
		case .more:     return Key(label: .localize("More"),
															 imageName: .ellipsis,
															 preferredStyle: .icons,
															 isToggle: true)
		// Primary - trailing
		case .up:       return Key(label: .localize("Up"),
															 imageName: .arrowUp,
															 preferredStyle: .icons,
															 halfHeight: true,
															 widthRatio: 1)
		case .down:     return Key(label: .localize("Down"),
															 imageName: .arrowDown,
															 preferredStyle: .icons,
															 halfHeight: true,
															 widthRatio: 1)
		case .left:     return Key(label: .localize("Left"),
															 imageName: .arrowLeft,
															 preferredStyle: .icons,
															 halfHeight: true,
															 widthRatio: 1)
		case .right:    return Key(label: .localize("Right"),
															 imageName: .arrowRight,
															 preferredStyle: .icons,
															 halfHeight: true,
															 widthRatio: 1)
		// Secondary
		case .shiftTab: return Key(label: .localize("Shift-Tab"),
															 glyph: "⇧tab",
															 imageName: .arrowRightToLine,
															 preferredStyle: .icons,
															 widthRatio: 1.6)

		// Secondary - extras
		case .delete:   return Key(label: .localize("Delete Forward"),
															 glyph: .localize("Del"),
															 imageName: .deleteRight,
															 preferredStyle: .icons,
															 widthRatio: 1)
		case .fnKeys:   return Key(label: .localize("Function Keys"),
															 glyph: .localize("Fn"),
															 isToggle: true,
															 widthRatio: 1)

		// Projects
		case .projects: return Key(label: .localize("Projects"),
															 glyph: .localize("Proj"),
															 imageName: .folder,
															 preferredStyle: .icons,
															 isToggle: true)

		case .image:    return Key(label: .localize("Attach Image"),
															 glyph: .localize("Img"),
															 imageName: .photo,
															 preferredStyle: .icons,
															 widthRatio: 1)

		case .ssh:      return Key(label: .localize("SSH Hosts"),
															 glyph: .localize("SSH"),
															 imageName: .network,
															 preferredStyle: .icons,
															 isToggle: true)

		case .ai:       return Key(label: .localize("AI Commands"),
															 glyph: .localize("AI"),
															 imageName: .sparkles,
															 preferredStyle: .icons,
															 isToggle: true)

		// Fn keys
		case .fnKey(let index):
			return Key(label: "F\(index)",
								 preferredStyle: .text,
								 widthRatio: 1)
		}
	}
}

protocol KeyboardToolbarViewDelegate: AnyObject {
	func keyboardToolbarDidPressKey(_ key: ToolbarKey)
	func keyboardToolbarDidBeginPressingKey(_ key: ToolbarKey)
	func keyboardToolbarDidEndPressingKey(_ key: ToolbarKey)
	func keyboardToolbarDidSelectProject(_ project: Project)
	func keyboardToolbarDidRequestNewProject()
	func keyboardToolbarDidRequestDeleteProject(_ project: Project)
	func keyboardToolbarDidSelectSSHHost(_ host: SSHHost)
	func keyboardToolbarDidRequestNewSSHHost()
	func keyboardToolbarDidRequestEditSSHHost(_ host: SSHHost)
	func keyboardToolbarDidRequestDeleteSSHHost(_ host: SSHHost)
	func keyboardToolbarDidSelectAICommand(_ command: AICommand)
}

/// One item in a picker row — a project, an SSH host, an agent command.
///
/// These rows are lists you choose from, not keys you press, and styling them as keys is what made
/// them read as an undifferentiated wall of buttons. A chip says what kind of thing it is with an
/// icon, what it is called, and where it came from, and marks the one in effect the way the tab bar
/// marks the open tab.
///
/// It also fixes the reason the rows were unreadable in a light theme: the old ones painted their
/// labels `.white` regardless of appearance, so once the keys became frosted glass the text was
/// white on near-white. Everything here is a semantic colour.
struct PickerChip: View {
	var icon: String
	/// What kind of thing this is, carried as colour on the glyph alone.
	///
	/// Every chip being the same neutral glass made a row of them read as one undifferentiated block.
	/// Colouring the 13pt icon — and nothing else — is enough to tell a project from a host from an
	/// agent at a glance, without turning the bar into a row of coloured buttons.
	var iconTint: Color = .secondary
	var title: String
	var subtitle: String?
	/// The one currently in effect — the project you are inside. Tinted, like the selected tab.
	var isSelected = false
	/// An action rather than an item: “New”. Accent-coloured so the eye separates the two at a glance.
	var isAction = false
	/// Vertical is the narrow column beside the landscape strip, where only the name fits.
	var axis: Axis = .horizontal

	static let height: CGFloat = 45

	private var isTinted: Bool { isSelected || isAction }

	/// Trims a long note down to a hint.
	///
	/// The string rather than the layout: capping the width with `frame(maxWidth:)` makes the chip
	/// flexible, and a row of flexible chips gets squeezed to fit instead of scrolling — which turned
	/// project names into "b…" and "al…".
	private static func shortened(_ text: String) -> String {
		let limit = 26
		guard text.count > limit else {
			return text
		}
		return text.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
	}

	var body: some View {
		let shape = RoundedRectangle(cornerRadius: Design.keyRadius, style: .continuous)

		HStack(spacing: axis == .vertical ? 4 : 7) {
			Image(systemName: icon)
				.font(.system(size: axis == .vertical ? 10 : 13, weight: .semibold))
				.foregroundColor(isTinted ? .accentColor : iconTint)

			VStack(alignment: .leading, spacing: 0) {
				Text(title)
					.font(.system(size: axis == .vertical ? 11 : (isBigDevice ? 16 : 15), weight: .medium))
					.foregroundColor(isTinted ? Color.accentColor : .primary)
				// Dropped in the column: it is one key wide, and the name already has to be truncated
				// to fit.
				if axis == .horizontal, let subtitle = subtitle, !subtitle.isEmpty {
					Text(Self.shortened(subtitle))
						.font(.system(size: 10))
						.foregroundColor(.secondary)
				}
			}
				.lineLimit(1)
				.truncationMode(.tail)
		}
			.padding(.horizontal, axis == .vertical ? 6 : 10)
			.frame(maxWidth: axis == .vertical ? .infinity : nil, alignment: .leading)
			.frame(height: Self.height)
			.background(background(shape: shape))
			.contentShape(shape)
	}

	@ViewBuilder
	private func background<S: InsettableShape>(shape: S) -> some View {
		if isSelected {
			Design.glass(shape, strokeOpacity: 0)
				.overlay(shape.fill(Color.accentColor.opacity(0.20)))
				.overlay(shape.strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1))
		} else {
			Design.glass(shape)
		}
	}
}

/// What a row shows when it has nothing to list.
///
/// A bare line of grey text read as a rendering failure. An icon and a sentence that says what to do
/// about it reads as an answer.
struct PickerEmptyState: View {
	var icon: String
	var text: String
	var axis: Axis = .horizontal

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: icon)
				.font(.system(size: 12, weight: .medium))
			Text(text)
				.font(.system(size: 12))
				.lineLimit(axis == .vertical ? 2 : 1)
		}
			.foregroundColor(.secondary)
			.padding(.horizontal, 8)
			.frame(maxWidth: axis == .vertical ? .infinity : nil, alignment: .leading)
			.frame(height: PickerChip.height)
	}
}

/// The agent CLIs installed here, and the prompts they already know.
struct AIPickerRow: View {
	weak var delegate: KeyboardToolbarViewDelegate?

	var axis: Axis = .horizontal

	@State private var commands = [AICommand]()

	private static let rowHeight: CGFloat = 45

	@ViewBuilder
	private func stack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
		switch axis {
		case .horizontal: HStack(alignment: .center, spacing: 5) { content() }
		case .vertical:   VStack(alignment: .leading, spacing: 5) { content() }
		}
	}

	var body: some View {
		ScrollView(axis == .horizontal ? .horizontal : .vertical, showsIndicators: false) {
			stack {
				if commands.isEmpty {
					PickerEmptyState(icon: "sparkles",
													 text: String.localize("No agent CLIs installed"),
													 axis: axis)
				} else {
					ForEach(commands) { command in
						Button {
							UIDevice.current.playInputClick()
							delegate?.keyboardToolbarDidSelectAICommand(command)
						} label: {
							// A CLI starts something; a prompt is something you hand to what's already
							// running. Different icons because they behave differently.
							// The note when there is one: "Persona" says what kind of thing it is, which you
							// can already see from the icon, while the note says what it does.
							PickerChip(icon: command.kind == .cli ? "terminal" : "sparkles",
												 iconTint: command.kind == .cli ? .green : .purple,
												 title: command.name,
												 subtitle: command.note ?? command.source,
												 axis: axis)
						}
							.buttonStyle(.plain)
					}
				}
			}
				.padding(.horizontal, 4)
		}
			.frame(height: axis == .horizontal ? Self.rowHeight : nil)
			.onAppear { commands = AICatalog.commands() }
			.onReceive(NotificationCenter.default.publisher(for: AICatalog.didChangeNotification)) { _ in
				commands = AICatalog.commands()
			}
			// An agent that just rewrote the shortcuts file should see its own change without the app
			// being restarted — that's the whole point of the file being editable.
			.onReceive(NotificationCenter.default.publisher(for: AIShortcutStore.didChangeNotification)) { _ in
				commands = AICatalog.commands()
			}
	}
}

/// The hosts in `~/.ssh/config`, to connect to one without typing its name.
struct SSHHostPickerRow: View {
	weak var delegate: KeyboardToolbarViewDelegate?

	/// Vertical when it’s the column beside the landscape strip, horizontal as the accessory row.
	var axis: Axis = .horizontal

	@State private var hosts = [SSHHost]()
	/// Long-press to enter, same as the projects row and the tab bar. A stray tap connects; it must
	/// never be able to rewrite the config.
	@State private var isEditing = false

	/// Matches `KeyboardKeyButtonStyle`’s key height, the same as the projects row.
	private static let rowHeight: CGFloat = 45

	@ViewBuilder
	private func stack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
		switch axis {
		case .horizontal: HStack(alignment: .center, spacing: 5) { content() }
		case .vertical:   VStack(alignment: .leading, spacing: 5) { content() }
		}
	}

	var body: some View {
		ScrollView(axis == .horizontal ? .horizontal : .vertical, showsIndicators: false) {
			stack {
				Button {
					UIDevice.current.playInputClick()
					delegate?.keyboardToolbarDidRequestNewSSHHost()
				} label: {
					PickerChip(icon: "plus",
										 title: axis == .horizontal ? String.localize("New") : "",
										 isAction: true,
										 axis: axis)
				}
					.buttonStyle(.plain)
					.accessibilityLabel(String.localize("New SSH Host"))

				if hosts.isEmpty {
					PickerEmptyState(icon: "network.slash",
													 text: String.localize("No hosts in ~/.ssh/config"),
													 axis: axis)
				} else {
					ForEach(Array(zip(hosts, hosts.indices)), id: \.0) { host, index in
						// Deliberately not a Button, for the same reason the projects row isn’t one: a Button
						// swallows the press and no long-press gesture on it ever fires.
						// The alias is what gets typed, so it leads; what it resolves to is only there to
						// tell two similar aliases apart, and is dropped entirely in the narrow column.
						PickerChip(icon: "network",
											 iconTint: .appTeal,
											 title: host.name,
											 subtitle: host.detail,
											 axis: axis)
							.frame(minWidth: axis == .vertical ? 0 : Self.rowHeight)
							.onTapGesture {
								UIDevice.current.playInputClick()
								if isEditing {
									// In edit mode a tap changes the entry rather than connecting — the badge
									// beside it is for removing, and there’s nothing else a tap could mean here.
									isEditing = false
									delegate?.keyboardToolbarDidRequestEditSSHHost(host)
								} else {
									delegate?.keyboardToolbarDidSelectSSHHost(host)
								}
							}
							.onLongPressGesture { isEditing = true }
							.jiggle(isActive: isEditing, index: index)
							.deleteBadge(isVisible: isEditing,
													 label: String(format: .localize("Delete %@"), host.name),
													 action: { delegate?.keyboardToolbarDidRequestDeleteSSHHost(host) })
					}
				}
			}
				.padding(.horizontal, 4)
		}
			.frame(height: axis == .horizontal ? Self.rowHeight : nil)
			.background(
				// Tapping the empty part of the row leaves edit mode — there’s no Done button.
				Color.clear
					.contentShape(Rectangle())
					.onTapGesture { isEditing = false }
			)
			.onAppear {
				hosts = SSHConfig.hosts()
				isEditing = false
			}
			.onReceive(NotificationCenter.default.publisher(for: SSHConfig.didChangeNotification)) { _ in
				hosts = SSHConfig.hosts()
			}
	}
}

/// The `[Image #N]` receipts for images attached to the line being typed.
///
/// The terminal line itself has to contain the real path — that’s the only thing a CLI can open —
/// so this is what shows the friendlier name for what was attached.
struct AttachmentStrip: View {
	let indexes: [Int]

	var body: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 5) {
				ForEach(indexes, id: \.self) { index in
					Text(verbatim: "[Image #\(index)]")
						.font(.system(size: 13).monospacedDigit())
						.foregroundColor(.white)
						.padding(.horizontal, 8)
						.padding(.vertical, 4)
						.background(Color(.keyBackgroundNormal).cornerRadius(4))
				}
			}
		}
			.frame(height: 26)
	}
}

class KeyboardToolbarViewState: ObservableObject {
	@Published var toggledKeys = Set<ToolbarKey>()
	/// The strip of screen the home indicator sits in, handed down from UIKit.
	///
	/// SwiftUI's own safe-area handling is switched off for this view. The bar is placed by the
	/// keyboard, and how much of it overlaps the indicator changes as it resizes — measured, the same
	/// bar reported a 34pt inset at one height and 9pt at another, so the rows were laid out against
	/// one number while the bar was sized from the other and ended up 25pt too low.
	@Published var bottomInset: CGFloat = 0


	/// Numbers of the images attached since the last return, newest last. Cleared on return, because
	/// that’s when the line they were attached to gets sent.
	@Published var imageAttachments = [Int]()
}

struct KeyboardToolbarKeyStack: View {
	weak var delegate: KeyboardToolbarViewDelegate?

	let toolbar: Toolbar
	var arrowsStyle: KeyboardArrowsStyle?
	/// Vertical for the landscape side bar, horizontal everywhere else.
	var axis: Axis = .horizontal

	@EnvironmentObject var state: KeyboardToolbarViewState

	@ObservedObject private var preferences = Preferences.shared

	@ViewBuilder
	var body: some View {
		switch axis {
		case .horizontal:
			HStack(alignment: .center, spacing: 5) { keys }
		case .vertical:
			// Tighter than the horizontal bar because the strip is height-limited and the keys are not.
			// The ten of them want 411pt at the horizontal spacing; landscape leaves 376pt between the
			// tab bar and the home indicator, so the last key — the right arrow — never made it on
			// screen and there was nothing to say it was there.
			VStack(alignment: .center, spacing: 2) { keys }
		}
	}

	@ViewBuilder
	private var keys: some View {
		ForEach(toolbar.keys, id: \.self) { key in
			switch key {
			case .fixedSpace:    EmptyView()
			case .variableSpace: Spacer(minLength: 0)
			case .arrows:        arrowsView
			default:
				// Arrows go half height in the vertical strip; at full height the seven keys don’t fit the
				// space left over in landscape and the last one ends up scrolled out of sight.
				button(for: key, halfHeight: axis == .vertical && key.key.halfHeight)
			}
		}
	}

	@ViewBuilder
	func button(for key: ToolbarKey, halfHeight: Bool = false) -> some View {
		let button = Button {
			UIDevice.current.playInputClick()

			if key.key.isToggle {
				if state.toggledKeys.contains(key) {
					state.toggledKeys.remove(key)
				} else {
					state.toggledKeys.insert(key)
				}
			}

			delegate?.keyboardToolbarDidPressKey(key)
		} label: {
			switch key {
			case .up, .down, .left, .right:
				Image(systemName: key.key.imageName!)
					.frame(width: 14, height: 14, alignment: .center)
					.accessibilityLabel(key.key.label)

			default:
				VStack(alignment: .trailing, spacing: 2) {
					HStack(spacing: 0) {
						if let imageName = key.key.imageName,
							 key.key.preferredStyle != .text {
							Image(systemName: imageName)
								.imageScale(.small)
								.opacity(0.5)
								.frame(width: 14, height: 14, alignment: .center)
								.padding(.trailing, 1)
								.accessibilityLabel(key.key.label)
						}
					}
					.frame(height: 14)

					Text((key.key.glyph ?? key.key.label).localizedLowercase)
						// Refuses to shrink, so a row that needs more width than it has genuinely doesn’t
						// fit — which is what lets ViewThatFits switch it to a scrolling row instead of
						// silently truncating `home` to `ho…`.
						.fixedSize()
				}
			}
		}
			.buttonStyle(.keyboardKey(selected: state.toggledKeys.contains(key),
																hasShadow: true,
																halfHeight: halfHeight,
																widthRatio: key.key.widthRatio))

		if KeyboardPreferences.isKeyRepeatEnabled {
			button
				.onLongPressGesture(minimumDuration: KeyboardPreferences.keyRepeatDelay,
														perform: {},
														onPressingChanged: { pressing in
					if pressing {
						delegate?.keyboardToolbarDidBeginPressingKey(key)
					} else {
						delegate?.keyboardToolbarDidEndPressingKey(key)
					}
				})
		} else {
			button
		}
	}

	@ViewBuilder
	var arrowsView: some View {
		switch arrowsStyle ?? preferences.keyboardArrowsStyle {
		case .butterfly:
			HStack(spacing: isBigDevice ? 5 : 2) {
				button(for: .left)
				VStack(spacing: 2) {
					button(for: .up, halfHeight: true)
					button(for: .down, halfHeight: true)
				}
				button(for: .right)
			}

		case .scissor:
			HStack(spacing: isBigDevice ? 5 : 2) {
				VStack(alignment: .trailing, spacing: 2) {
					Spacer()
					button(for: .left, halfHeight: true)
				}
				VStack(alignment: .trailing, spacing: 2) {
					button(for: .up, halfHeight: true)
					button(for: .down, halfHeight: true)
				}
				VStack(alignment: .trailing, spacing: 2) {
					Spacer()
					button(for: .right, halfHeight: true)
				}
			}

		case .classic:
			HStack(spacing: 5) {
				button(for: .up)
				button(for: .down)
				button(for: .left)
				button(for: .right)
			}

		case .vim:
			HStack(spacing: 5) {
				button(for: .left)
				button(for: .down)
				button(for: .up)
				button(for: .right)
			}

		case .vimInverted:
			HStack(spacing: 5) {
				button(for: .left)
				button(for: .up)
				button(for: .down)
				button(for: .right)
			}
		}
	}
}

/// The projects row, shown above the key rows when the Projects key is toggled on.
///
/// Projects are directories under the projects root, so this is a plain listing — there’s nothing to
/// keep in sync, and a project created in the shell or in Filza appears here too.
struct ProjectPickerRow: View {
	weak var delegate: KeyboardToolbarViewDelegate?

	/// Vertical when it’s the column beside the landscape strip, horizontal as the accessory row.
	var axis: Axis = .horizontal

	@State private var projects = [Project]()
	/// The project whose terminals the tab bar is showing on their own. Marked in the list so it's
	/// clear which one you're inside, and that tapping it again is what gets you back out.
	@State private var activePath = ProjectManager.activeProjectPath
	/// Long-press to enter, same as the tab bar. Projects are folders of source, so a stray tap must
	/// never be able to remove one.
	@State private var isEditing = false

	/// Matches `KeyboardKeyButtonStyle`’s key height. A horizontal scroll view has no intrinsic
	/// height, so without this the row collapses to nothing and the toggle looks broken.
	private static let rowHeight: CGFloat = 45

	@ViewBuilder
	private func stack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
		switch axis {
		case .horizontal: HStack(alignment: .center, spacing: 5) { content() }
		// Leading, not centre: the column sits against the key strip, and centring left a strip-wide
		// gap between the two that read as an empty column rather than as one panel.
		case .vertical:   VStack(alignment: .leading, spacing: 5) { content() }
		}
	}

	var body: some View {
		ScrollView(axis == .horizontal ? .horizontal : .vertical, showsIndicators: false) {
			stack {
				Button {
					UIDevice.current.playInputClick()
					delegate?.keyboardToolbarDidRequestNewProject()
				} label: {
					// No room for the word beside the plus in a one-key-wide column, and the plus on its
					// own says the same thing.
					PickerChip(icon: "plus",
										 title: axis == .horizontal ? String.localize("New") : "",
										 isAction: true,
										 axis: axis)
				}
					.buttonStyle(.plain)
					.accessibilityLabel(String.localize("New Project"))

				if projects.isEmpty {
					PickerEmptyState(icon: "folder.badge.plus",
													 text: String.localize("No projects yet — tap New"),
													 axis: axis)
				} else {
					ForEach(Array(zip(projects, projects.indices)), id: \.0) { project, index in
						// Deliberately not a Button: a Button swallows the press, and neither
						// onLongPressGesture nor simultaneousGesture(LongPressGesture()) fires on one. The
						// tab bar uses the same plain-view-plus-gestures shape for the same reason, so the
						// key styling is reproduced here by hand.
						// A filled folder for the one you're inside, an outline for the rest — the icon says
						// which is which before the tint does.
						PickerChip(icon: project.url.path == activePath ? "folder.fill" : "folder",
											 iconTint: .orange,
											 title: project.name,
											 isSelected: project.url.path == activePath,
											 axis: axis)
							.frame(minWidth: axis == .vertical ? 0 : Self.rowHeight)
							.onTapGesture {
								UIDevice.current.playInputClick()
								if isEditing {
									isEditing = false
								} else {
									delegate?.keyboardToolbarDidSelectProject(project)
								}
							}
							.onLongPressGesture { isEditing = true }
							.jiggle(isActive: isEditing, index: index)
							.deleteBadge(isVisible: isEditing,
													 label: String(format: .localize("Delete %@"), project.name),
													 action: {
														 // Stays in edit mode, same as the tab bar: deleting one shouldn’t mean
														 // long-pressing again to delete the next.
														 delegate?.keyboardToolbarDidRequestDeleteProject(project)
													 })
					}
				}
			}
				.padding(.horizontal, 4)
		}
			// A scroll view has no intrinsic size along the axis it scrolls, so the one that isn’t the
			// scrolling axis has to be stated or the row collapses to nothing and the toggle looks broken.
			.frame(height: axis == .horizontal ? Self.rowHeight : nil)
			.background(
				// Tapping the empty part of the row leaves edit mode — there’s no Done button.
				Color.clear
					.contentShape(Rectangle())
					.onTapGesture { isEditing = false }
			)
			.onAppear {
				projects = ProjectManager.projects()
				activePath = ProjectManager.activeProjectPath
				isEditing = false
			}
			.onReceive(NotificationCenter.default.publisher(for: ProjectManager.didChangeNotification)) { _ in
				projects = ProjectManager.projects()
			}
			.onReceive(NotificationCenter.default.publisher(for: ProjectManager.activeProjectDidChangeNotification)) { _ in
				activePath = ProjectManager.activeProjectPath
			}
	}
}

/// Carries the rows' real height out to the UIKit bar that has to be that tall.
struct KeyboardBarHeightKey: PreferenceKey {
	static var defaultValue: CGFloat = 0
	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
		value = max(value, nextValue())
	}
}

struct KeyboardToolbarView: View {
	/// Key height from `KeyboardKeyButtonStyle`, plus the row’s top padding.
	private static let keyRowHeight: CGFloat = 45 + 5

	weak var delegate: KeyboardToolbarViewDelegate?

	let toolbars: [Toolbar]

	/// Reports how tall the rows actually are.
	///
	/// The bar cannot work this out from the hosting view: SwiftUIX wraps the content in
	/// `.frame(max: layoutFittingExpandedSize)`, so it fills whatever height it is offered and its
	/// intrinsic size always comes back equal to the current height. Measured, the bar latched at three
	/// rows' worth with four to show and never moved again, in either direction. `fixedSize` below
	/// keeps this stack at its own height regardless, which is what makes it measurable at all.
	var onHeightMeasured: ((CGFloat) -> Void)?

	@EnvironmentObject var state: KeyboardToolbarViewState

	@ObservedObject private var preferences = Preferences.shared

	private func isToolbarVisible(_ toolbar: Toolbar) -> Bool {
		switch toolbar {
		case .primary, .padPrimaryLeading, .padPrimaryTrailing:
			return true
		case .secondary:
			return state.toggledKeys.contains(.more)
		case .fnKeys:
			return state.toggledKeys.contains(.fnKeys)
		case .projects:
			return state.toggledKeys.contains(.projects)
		case .sshHosts:
			return state.toggledKeys.contains(.ssh)
		case .aiCommands:
			return state.toggledKeys.contains(.ai)
		case .attachments:
			return !state.imageAttachments.isEmpty
		case .sideBar, .sideBarMore:
			// Hosted separately by the view controller, never inside the accessory view.
			return false
		}
	}

	private func keyStack(for toolbar: Toolbar) -> some View {
		KeyboardToolbarKeyStack(delegate: delegate, toolbar: toolbar)
			.padding(.horizontal, 4)
			.padding(.top, 5)
	}

	/// A row lays out to fill the width when it can, and scrolls when it can’t.
	///
	/// Without this a row wider than the screen doesn’t overflow — the keys just compress until their
	/// labels truncate (`home` became `ho…` once the row reached seven keys) and the keys at each end
	/// get clipped by the screen edge.
	private func scrollableIfNeeded<Content: View>(_ content: Content) -> some View {
		// The width is read inline from the proxy rather than measured into @State: the state version
		// is what left the bar laid out at the previous orientation’s width when the measurement
		// didn’t fire on rotation.
		//
		// ViewThatFits can’t do this job — the rows contain a flexible spacer, so they report as
		// fitting any width no matter how many keys are in them.
		GeometryReader { proxy in
			ScrollView(.horizontal, showsIndicators: false) {
				content
					// Fills the bar when the keys fit, so the spacer still pushes the arrows to the
					// trailing edge, and overflows into a scroll when they don’t.
					.frame(minWidth: proxy.size.width, alignment: .leading)
			}
		}
			// A horizontal scroll view has no intrinsic height, and neither does GeometryReader.
			.frame(height: Self.keyRowHeight)
	}

	@ViewBuilder
	var body: some View {
		// Rows fill whatever width the hosting view has — its leading and trailing edges are pinned to
		// the safe area by KeyboardToolbarInputView. This used to measure the width into @State and
		// apply it with .frame(width:), which left the rows laid out at the *previous* orientation’s
		// width whenever the measurement didn’t fire on rotation: the bar came back from landscape
		// still 874pt wide, centred, and clipped off both edges of a 402pt screen.
		VStack(spacing: 0) {
			ForEach(toolbars, id: \.self) { toolbar in
				if isToolbarVisible(toolbar) {
					switch toolbar {
					case .projects:
						ProjectPickerRow(delegate: delegate)
							.padding(.horizontal, 4)
							.padding(.top, 5)
							.frame(maxWidth: .infinity)

					case .sshHosts:
						SSHHostPickerRow(delegate: delegate)
							.padding(.horizontal, 4)
							.padding(.top, 5)
							.frame(maxWidth: .infinity)

					case .aiCommands:
						AIPickerRow(delegate: delegate)
							.padding(.horizontal, 4)
							.padding(.top, 5)
							.frame(maxWidth: .infinity)

					case .attachments:
						AttachmentStrip(indexes: state.imageAttachments)
							.padding(.horizontal, 8)
							.padding(.top, 5)
							.frame(maxWidth: .infinity, alignment: .leading)

					case .fnKeys:
						CocoaScrollView(.horizontal, showsIndicators: false) {
							keyStack(for: toolbar)
						}
							.frame(maxWidth: .infinity)

					case .primary, .padPrimaryLeading, .padPrimaryTrailing, .secondary,
							 .sideBar, .sideBarMore:
						scrollableIfNeeded(keyStack(for: toolbar))
							.frame(maxWidth: .infinity)
					}
				}
			}
		}
			// Included in what gets measured below, so the height the bar is given already accounts for
			// it and there is no second number to keep in step.
			.padding(.bottom, state.bottomInset)
			// Its own height, not the one it is offered. Without this the stack is stretched to fill the
			// bar and there is nothing left to measure.
			.fixedSize(horizontal: false, vertical: true)
			.background(GeometryReader { proxy in
				Color.clear.preference(key: KeyboardBarHeightKey.self, value: proxy.size.height)
			})
			// Held against the bottom edge — the one that doesn't move, because the keyboard is below
			// it — so that while UIKit still has the bar at its old height the key rows stay put instead
			// of drifting to the middle.
			.frame(maxHeight: .infinity, alignment: .bottom)
			.onPreferenceChange(KeyboardBarHeightKey.self) { height in
				onHeightMeasured?(height)
			}
	}
}

struct KeyboardToolbarView_Previews: PreviewProvider {
	@State private static var state = KeyboardToolbarViewState()

	static var previews: some View {
		ForEach(ColorScheme.allCases, id: \.self) { scheme in
			VStack {
				Spacer()
				KeyboardToolbarView(toolbars: [.fnKeys, .secondary, .primary])
					.environmentObject(state)
					.padding(.bottom, 4)
					.background(BlurEffectView(style: .systemChromeMaterial))
					.preferredColorScheme(scheme)
					.previewLayout(.sizeThatFits)
			}
				.previewDisplayName("\(scheme)")
				.previewLayout(.fixed(width: 414, height: 100))
		}

		VStack() {
			Spacer()
			HStack {
				KeyboardToolbarKeyStack(toolbar: .padPrimaryLeading)
					.environmentObject(state)
				Spacer()
				KeyboardToolbarKeyStack(toolbar: .padPrimaryTrailing)
					.environmentObject(state)
			}
				.previewLayout(.sizeThatFits)
		}
			.previewDisplayName("iPad Toolbar")
			.previewLayout(.fixed(width: 600, height: 100))
	}
}
