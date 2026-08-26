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
}

class TabToolbarState: ObservableObject {
	@Published var delegate: TabToolbarDelegate?
	@Published var terminals = [TerminalTab]()
	@Published var selectedIndex = 0
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

	var body: some View {
		if horizontalSizeClass == .compact {
			VStack(spacing: 2) {
				HStack(alignment: .center, spacing: 6) {
					leadingButtons
					// Balances the three trailing buttons so the title stays centred: one real button on
					// the leading side plus two buttons’ worth of empty space.
					Color.clear
						.frame(width: (Self.height + 6) * 2)
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

	private func scrollingTabs(minimumWidth: CGFloat) -> some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 0) {
				ForEach(Array(zip(state.terminals, state.terminals.indices)), id: \.1) { terminal, index in
					TabToolbarItemView(terminal: terminal,
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

				tabsFiller
			}
				// Fills the bar when the tabs don’t, so the filler has somewhere to be; scrolls when
				// there are more tabs than fit.
				.frame(minWidth: minimumWidth, alignment: .leading)
		}
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

	private var buttons: some View {
		HStack(spacing: 0) {
			Button(action: { state.delegate?.openPasswordManager() },
						 label: { Image(systemName: "key.fill") })
				.squareFrame(sideLength: Self.height)
				.padding(.horizontal, 3)
				.accessibilityLabel("Password Manager")

			Button(action: { state.delegate?.openSettings() },
						 label: { Image(systemName: .gear) })
				.squareFrame(sideLength: Self.height)
				.padding(.horizontal, 3)
				.accessibilityLabel("Settings")

			Button(action: { state.delegate?.addTerminal() },
						 label: { Image(systemName: .plus) })
				.squareFrame(sideLength: Self.height)
				.padding(.horizontal, 3)
				.padding(.trailing, 3)
				.accessibilityLabel("New Tab")
		}
			.foregroundColor(.accentColor)
			.font(.system(size: 17 * 0.9, weight: .medium))
			.imageScale(.large)
	}

}

struct TabToolbarItemView: View {
	/// Roughly a dozen characters at this font size — enough to tell `bunnyhub` from `newterm`
	/// without any one tab taking over the bar.
	private static let maximumTitleWidth: CGFloat = 88

	private static let cornerRadius: CGFloat = 6

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

			Text(terminal.title)
				.font(.system(size: 12, weight: .semibold))
				.foregroundColor(.label)
				.lineLimit(1)
				.truncationMode(.tail)
				// Capped so a long title — a project folder, or whatever the shell sets — can’t push the
				// other tabs off the bar. Wide enough to tell two projects apart, which is the point.
				.frame(maxWidth: Self.maximumTitleWidth, alignment: .leading)
				.accessibilityHidden(true)
		}
			.height(height - 6)
			.padding(.horizontal, 10)
			// Every tab is an outlined chip, not just the selected one. With only the selected tab
			// filled, two unselected tabs sitting side by side were a single run of text with no way to
			// see where one ended and the next began.
			.background(
				RoundedRectangle(cornerRadius: Self.cornerRadius)
					.fill(isSelected ? Color(.tabSelected) : .clear)
			)
			.overlay(
				RoundedRectangle(cornerRadius: Self.cornerRadius)
					.strokeBorder(Color.label.opacity(isSelected ? 0.25 : 0.15), lineWidth: 1)
			)
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
