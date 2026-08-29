//
//  TabToolbar.swift
//  NewTerm (iOS)
//
//  Created by Adam Demasi on 3/8/2022.
//

import SwiftUI
import SwiftUIX
import NewTermCommon

struct TerminalTab: Hashable {
	var title: String
	var screenSize: ScreenSize
	var isDirty: Bool
	var hasBell: Bool
	/// Whether this tab is showing two terminals side by side. Drives the split button, which offers
	/// to undo the split rather than make another one.
	var isSplit: Bool = false
	/// The project this terminal belongs to, or `nil` for one opened outside any project. The bar shows
	/// one project's terminals at a time.
	var projectPath: String?
}

class TabToolbarState: ObservableObject {
	@Published var delegate: TabToolbarDelegate?
	@Published var terminals = [TerminalTab]()
	@Published var selectedIndex = 0
	/// Which project's terminals the bar is showing — always the selected tab's, so the selected tab is
	/// never one of the hidden ones.
	@Published var visibleProjectPath: String?
	/// Home-screen style edit mode. Closing a tab used to be a single tap on the icon that also acted
	/// as the activity indicator, which made it far too easy to close a session by accident.
	@Published var isEditing = false
}

/// Home-screen style “jiggle” for things that can be deleted while editing.
///
/// Honours Reduce Motion — the delete badges still appear, they just don’t wobble.
struct JiggleModifier: ViewModifier {
	var isActive: Bool
	/// Alternates the direction per item so a row doesn’t wobble in lockstep.
	var index: Int

	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var wobbling = false

	private var rotation: Double {
		guard isActive, !reduceMotion else {
			return 0
		}
		let amount: Double = index.isMultiple(of: 2) ? 1.2 : -1.2
		return wobbling ? amount : -amount
	}

	func body(content: Content) -> some View {
		content
			.rotationEffect(.degrees(rotation))
			// The repeating animation has to be swapped for a finite one in the same update. Leaving
			// repeatForever attached means SwiftUI keeps running it, and the items carry on wobbling
			// after edit mode has ended.
			.animation(isActive && !reduceMotion
								 ? .easeInOut(duration: 0.13).repeatForever(autoreverses: true)
								 : .linear(duration: 0.12),
								 value: rotation)
			.onChange(of: isActive) { active in
				wobbling = active && !reduceMotion
			}
	}
}

extension View {
	func jiggle(isActive: Bool, index: Int) -> some View {
		modifier(JiggleModifier(isActive: isActive, index: index))
	}

	/// The little ⨯ badge that appears on a deletable item in edit mode.
	func deleteBadge(isVisible: Bool, label: String, action: @escaping () -> Void) -> some View {
		overlay(
			Group {
				if isVisible {
					Button(action: action) {
						ZStack {
							Circle()
								.fill(Color.black.opacity(0.85))
							Image(systemName: .xmark)
								.font(.system(size: 9, weight: .bold))
								.foregroundColor(.white)
						}
							.frame(width: 18, height: 18)
					}
						// Inside the bounds rather than overhanging them: the first tab sits flush against
						// the screen edge, and an overhanging badge gets clipped there.
						.offset(x: 1, y: 1)
						.accessibilityLabel(label)
				}
			},
			alignment: .topLeading
		)
	}
}

struct TabToolbarView: View {

	static let height: CGFloat = 32

	/// Height this toolbar needs for a given size class. The layout below switches on
	/// `horizontalSizeClass`, so whoever sizes the toolbar has to switch on the same thing — sizing it
	/// from the raw view width instead lets the two disagree, and the two-row compact layout then
	/// overflows a one-row frame (iPhone landscape, where the width is wide but the class is compact).
	/// Takes the UIKit size class because the caller is UIKit; it mirrors the SwiftUI
	/// `horizontalSizeClass == .compact` test below exactly, so the two can’t drift apart.
	static func preferredHeight(for horizontalSizeClass: UIUserInterfaceSizeClass) -> CGFloat {
		horizontalSizeClass == .compact ? height * 2 + 2 : height + 1
	}

	@EnvironmentObject private var state: TabToolbarState

	@Environment(\.horizontalSizeClass)
	private var horizontalSizeClass

	@Environment(\.verticalSizeClass)
	private var verticalSizeClass

	var body: some View {
		if horizontalSizeClass == .compact {
			VStack(spacing: 2) {
				HStack(alignment: .center, spacing: 6) {
					leadingButtons
					// Balances the trailing buttons so the title stays centred: the leading spacer is one
					// button wide, so it needs the rest of them as empty space.
					Color.clear
						.frame(width: (Self.height + 6) * 3)
					titleLabel
					buttons
				}
					.frame(height: Self.height)
				tabs
					.frame(height: Self.height)
			}
		} else {
			HStack(alignment: .center, spacing: 6) {
				leadingButtons
				tabs
				buttons
			}
				.frame(height: Self.height)
		}
	}

	/// Ends edit mode. There’s no Done button — tapping a tab, or the empty space beside the tabs,
	/// gets out of it, the way the home screen works.
	///
	/// It has to live *inside* the scroll view’s content: a scroll view handles touches within its own
	/// bounds, so a tap gesture on a background behind it never sees them.
	private var tabsFiller: some View {
		Color.clear
			.frame(maxWidth: .infinity)
			.contentShape(Rectangle())
			.onTapGesture {
				if state.isEditing {
					state.isEditing = false
				}
			}
	}

	private var tabs: some View {
		GeometryReader { proxy in
			scrollingTabs(minimumWidth: proxy.size.width)
		}
	}

	/// One project's terminals, side by side. Indices are into the full tab list, not positions within
	/// a filtered copy — everything the bar hands back to the delegate is an index into the real list.
	private struct TabRun: Identifiable {
		var projectPath: String?
		var indices: [Int]
		var id: String { projectPath ?? "" }
	}

	/// What the bar shows: one project's terminals when you're inside a project, otherwise all of them
	/// with each project's gathered together.
	///
	/// Grouped rather than in tab order even when showing everything: a project's terminals are opened
	/// and closed over a session, so in tab order they end up interleaved with every other project's,
	/// which is the state that made a second terminal hard to find in the first place.
	private var tabRuns: [TabRun] {
		if let project = state.visibleProjectPath {
			return [TabRun(projectPath: project,
										 indices: state.terminals.indices.filter { state.terminals[$0].projectPath == project })]
		}

		var runs = [TabRun]()
		for index in state.terminals.indices {
			let path = state.terminals[index].projectPath
			if let existing = runs.firstIndex(where: { $0.projectPath == path }) {
				runs[existing].indices.append(index)
			} else {
				runs.append(TabRun(projectPath: path, indices: [index]))
			}
		}
		// Terminals belonging to no project last and unmarked — they're not a group, they're what's
		// left over.
		return runs.filter { $0.projectPath != nil } + runs.filter { $0.projectPath == nil }
	}

	private func scrollingTabs(minimumWidth: CGFloat) -> some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 0) {
				ForEach(tabRuns) { run in
					HStack(spacing: 0) {
						ForEach(run.indices, id: \.self) { index in
							tabItem(at: index)
						}
					}
						// Ties a project's terminals together as one run. Only when the bar is showing
						// everything — filtered to one project there's nothing to tell it apart from.
						.overlay(runUnderline(for: run), alignment: .bottom)
				}

				tabsFiller
			}
				// The first tab sat flush against the screen edge with its left border cut off by it.
				.padding(.leading, 8)
				// Fills the bar when the tabs don’t, so the filler has somewhere to be; scrolls when
				// there are more tabs than fit.
				.frame(minWidth: minimumWidth, alignment: .leading)
		}
	}

	@ViewBuilder
	private func runUnderline(for run: TabRun) -> some View {
		if run.projectPath != nil && state.visibleProjectPath == nil {
			Capsule()
				.fill(Color.accentColor)
				.frame(height: 2)
				.padding(.horizontal, 4)
		}
	}

	private func tabItem(at index: Int) -> some View {
		TabToolbarItemView(terminal: state.terminals[index],
											 index: index,
											 isSelected: state.selectedIndex == index,
											 isEditing: state.isEditing,
											 height: Self.height,
											 selectTerminal: {
												 // In edit mode a tap leaves edit mode rather than switching tabs, the
												 // same as tapping an app icon on a jiggling home screen.
												 if state.isEditing {
													 state.isEditing = false
												 } else {
													 state.delegate?.selectTerminal(at: index)
												 }
											 },
											 removeTerminal: {
												 // Deliberately stays in edit mode. Closing several tabs in a row is the
												 // normal case, and having to long-press again for each one after the
												 // first is worse than the wobbling continuing until it’s dismissed.
												 state.delegate?.removeTerminal(at: index)
											 },
											 beginEditing: { state.isEditing = true })
	}

	private var titleLabel: some View {
		HStack {
			Spacer()
			Text(state.terminals[state.selectedIndex].title)
				.font(.system(size: 17, weight: .semibold))
			Spacer()
		}
	}

	/// Empty, but reserved: it balances the trailing buttons so the title stays centred. There’s no
	/// Done button — edit mode ends by tapping anywhere that isn’t a tab, the way the home screen
	/// works.
	private var leadingButtons: some View {
		Color.clear
			.frame(width: Self.height + 6)
			.padding(.leading, 3)
	}

	/// Whether the selected tab is already split. Out of range while tabs are being rebuilt.
	private var isSelectedTabSplit: Bool {
		state.terminals.indices.contains(state.selectedIndex) && state.terminals[state.selectedIndex].isSplit
	}

	/// Splitting was reachable only from a hardware keyboard, so on a phone it may as well not have
	/// existed. The icon shows what the tap will do: which way the split will land, or that the
	/// second terminal is about to go away.
	private var splitButtonImage: String {
		if isSelectedTabSplit {
			return "rectangle"
		}
		// Compact height is landscape on a phone, where there's width to spare and the split goes
		// side by side; otherwise it stacks.
		return verticalSizeClass == .compact ? "rectangle.split.2x1" : "rectangle.split.1x2"
	}

	/// Four buttons all painted accent at the same weight gave the bar no hierarchy — splitting a pane
	/// shouted as loudly as opening a new tab. New Tab is the one thing done constantly and the only
	/// one that is destructive to nothing, so it keeps the accent; the rest step back to secondary and
	/// come forward on their own when you look for them.
	private var buttons: some View {
		HStack(spacing: 0) {
			barButton(systemName: splitButtonImage,
								label: isSelectedTabSplit ? "Close Split" : "Split Terminal",
								action: { state.delegate?.toggleSplit() })

			barButton(systemName: "key.fill",
								label: "Password Manager",
								action: { state.delegate?.openPasswordManager() })

			barButton(systemName: "gear",
								label: "Settings",
								action: { state.delegate?.openSettings() })

			barButton(systemName: "plus",
								label: "New Tab",
								isPrimary: true,
								action: { state.delegate?.addTerminal() })
				.padding(.trailing, 3)
		}
			.font(.system(size: 17 * 0.9, weight: .medium))
			.imageScale(.large)
	}

	private func barButton(systemName: String,
												 label: String,
												 isPrimary: Bool = false,
												 action: @escaping () -> Void) -> some View {
		Button(action: action, label: {
			Image(systemName: systemName)
				.font(.system(size: 17 * 0.9, weight: isPrimary ? .semibold : .regular))
				.foregroundColor(isPrimary ? .accentColor : .secondaryLabel)
		})
			.squareFrame(sideLength: Self.height)
			.padding(.horizontal, 3)
			.accessibilityLabel(label)
	}

}

struct TabToolbarItemView: View {
	/// Enough to tell `bunnyhub` from `newterm` without any one tab taking over the bar.
	private static let maximumTitleLength = 14

	private static func shortened(_ title: String) -> String {
		guard title.count > maximumTitleLength else {
			return title
		}
		return title.prefix(maximumTitleLength).trimmingCharacters(in: .whitespaces) + "…"
	}

	private static let cornerRadius = Design.chipRadius

	var terminal: TerminalTab
	var index: Int
	var isSelected: Bool
	var isEditing: Bool
	var height: CGFloat
	var selectTerminal: () -> Void
	var removeTerminal: () -> Void
	var beginEditing: () -> Void

	var body: some View {
		let accessibilityLabel: String
		switch true {
		case terminal.hasBell: accessibilityLabel = "\(terminal.title), \(String.localize("has bell"))"
		case terminal.isDirty: accessibilityLabel = "\(terminal.title), \(String.localize("has activity"))"
		default:               accessibilityLabel = terminal.title
		}

		return HStack(spacing: 4) {
			// Indicator only — closing is press-and-hold then the badge. It used to be a button here,
			// which meant the bell and activity dots doubled as a one-tap “destroy this session”.
			indicator

			// Trimmed as a string, not with `frame(maxWidth:)`. A capped frame makes the label flexible,
			// and the row stretches itself to fill the bar — so with only a few tabs open SwiftUI shared
			// the slack out by *squeezing* every label instead, and each one read "Ter…" until enough
			// tabs were open to fill the width.
			Text(Self.shortened(terminal.title))
				.font(.system(size: 12, weight: isSelected ? .semibold : .medium))
				// The selected tab is the one you are looking at; the rest are a list you are choosing
				// from. Weight and colour say which is which, so the chip doesn’t have to shout.
				.foregroundColor(isSelected ? .label : .secondaryLabel)
				.lineLimit(1)
				.fixedSize()
				.accessibilityHidden(true)
		}
			.height(height - 6)
			.padding(.horizontal, 10)
			// Every tab is an outlined chip, not just the selected one. With only the selected tab
			// marked, two unselected tabs sitting side by side were a single run of text with no way to
			// see where one ended and the next began.
			.background(chipBackground)
			.padding(.vertical, 3)
			.padding(.trailing, 4)
			.accessibilityLabel(accessibilityLabel)
			.accessibilityAddTraits(.isButton)
			.accessibilityAddTraits(isSelected ? .isSelected : [])
			.onTapGesture(perform: selectTerminal)
			.onLongPressGesture(perform: beginEditing)
			.jiggle(isActive: isEditing, index: index)
			.deleteBadge(isVisible: isEditing,
									 label: .localize("Close Tab"),
									 action: removeTerminal)
	}

	/// Frosted and tinted when selected, outlined when not.
	///
	/// Material alone doesn’t mark it: the bar is already blurred, so blurring a small piece of it
	/// again comes out the same shade and every tab looked identical. The tint is what carries the
	/// selection; the material is what keeps it from becoming a flat block in a translucent bar.
	@ViewBuilder
	private var chipBackground: some View {
		let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
		if isSelected {
			Design.glass(shape, strokeOpacity: 0)
				.overlay(shape.fill(Color.accentColor.opacity(0.22)))
				.overlay(shape.strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1))
		} else {
			shape.strokeBorder(Color.label.opacity(0.13), lineWidth: Design.stroke)
		}
	}

	@ViewBuilder
	private var indicator: some View {
		switch true {
		case terminal.hasBell:
			Image(systemName: .bellFill)
				.font(.system(size: 12 * 1.05))
				.foregroundColor(.label)

		case terminal.isDirty:
			Image(systemName: .circleFill)
				.font(.system(size: 12 * 0.9))
				.foregroundColor(.label.opacity(0.5))

		default:
			EmptyView()
		}
	}
}

struct TabToolbarView_Previews: PreviewProvider {
	static var previews: some View {
		let state = TabToolbarState()
		state.selectedIndex = 0
		state.terminals = [
			TerminalTab(title: "nano",
									screenSize: ScreenSize(cols: 80, rows: 25),
								  isDirty: false,
								  hasBell: false),
			TerminalTab(title: "mobile@iphone: ~",
									screenSize: ScreenSize(cols: 80, rows: 25),
									isDirty: true,
									hasBell: true),
			TerminalTab(title: "ssh",
									screenSize: ScreenSize(cols: 80, rows: 25),
									isDirty: true,
									hasBell: false),
		]

		return VStack {
			TabToolbarView()
				.environmentObject(state)
				.background(BlurEffectView(style: .systemChromeMaterial))
			Spacer()
		}
	}
}
