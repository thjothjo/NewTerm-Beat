//
//  KeyboardToolbarInputView.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import Combine
import SwiftUIX

class KeyboardToolbarInputView: UIInputView {

	private var hostingView: UIHostingView<AnyView>!
	/// The bar's height, taken from what the rows actually need.
	private var contentHeight: NSLayoutConstraint!
	/// What SwiftUI reports the rows need, padding included.
	private var measuredRowsHeight: CGFloat = 50
	private let state: KeyboardToolbarViewState

	/// Told when the bar has finished changing height, so whoever lays out around the keyboard can
	/// follow. UIKit posts no keyboard frame change when an accessory sizes itself.
	var onHeightChanged: (() -> Void)?

	init(delegate: KeyboardToolbarViewDelegate?, toolbars: [Toolbar], state: KeyboardToolbarViewState) {
		self.state = state
		super.init(frame: .zero, inputViewStyle: .keyboard)

		translatesAutoresizingMaskIntoConstraints = false
		allowsSelfSizing = true

		var view = KeyboardToolbarView(delegate: delegate, toolbars: toolbars)
		// Deferred a turn: `onChange` runs inside SwiftUI's update, and re-entering UIKit layout from
		// there is asking for trouble. By the next turn the new rows are committed, which is the whole
		// point — the old code invalidated from the model change instead and measured the rows that
		// were still on screen.
		view.onHeightMeasured = { [weak self] height in
			// Deferred a turn: the preference arrives inside SwiftUI's update, and re-entering UIKit
			// layout from there is asking for trouble.
			DispatchQueue.main.async {
				self?.applyContentHeight(height)
			}
		}

		hostingView = UIHostingView(rootView: AnyView(
			view.environmentObject(state)
		))
		hostingView.translatesAutoresizingMaskIntoConstraints = false
		hostingView.shouldResizeToFitContent = true
		hostingView.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
		// The rows reserve the home indicator's strip themselves, as padding, from `state.bottomInset`.
		// Left to SwiftUI it comes from how much of the bar happens to overlap that strip, which
		// changes as the bar resizes.
		hostingView._disableSafeAreaInsets()
		addSubview(hostingView)

		NSLayoutConstraint.activate([
			hostingView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
			hostingView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
			hostingView.topAnchor.constraint(equalTo: self.topAnchor),
			hostingView.bottomAnchor.constraint(equalTo: self.bottomAnchor)
		])

		// An explicit height on the bar itself, because the hosting view's intrinsic size can't provide
		// one. SwiftUIX wraps the content in `.frame(max: layoutFittingExpandedSize)`, so it fills
		// whatever height it is offered and its intrinsic size comes back equal to the current height —
		// every time. Measured: with four rows to show, the bar latched at three rows' worth (184pt)
		// and invalidating the intrinsic size changed nothing, in either direction.
		//
		// Seeded with one row so the bar is never zero-height before SwiftUI has measured itself.
		contentHeight = heightAnchor.constraint(equalToConstant: 50)
		contentHeight.isActive = true
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	/// Re-measures the bar after rows have been added or taken away.
	///
	/// The hosting view reports the height its rows need, and the input view sizes itself to that —
	/// but neither re-asks on its own when the content changes. Closing several rows at once left the
	/// bar at its old height with the keys centred in the leftover space, and the more rows were
	/// closed the more empty bar there was above and below them.
	private func applyContentHeight(_ height: CGFloat) {
		measuredRowsHeight = height
		updateHeight()
	}

	override func didMoveToWindow() {
		super.didMoveToWindow()
		updateHeight()
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		updateHeight()
	}

	override func safeAreaInsetsDidChange() {
		super.safeAreaInsetsDidChange()
		updateHeight()
	}

	/// Forces a re-measure, for the paths that rebuild the bar rather than change its rows.
	func invalidateHeight() {
		hostingView.invalidateIntrinsicContentSize()
		invalidateIntrinsicContentSize()
		setNeedsLayout()
		layoutIfNeeded()
	}

	/// Keeps the rows' padding and the bar's height in step, both from the window's inset.
	///
	/// The window's rather than the bar's own: the bar is placed by the keyboard, and how much of it
	/// overlaps the home indicator changes as it resizes — 34pt at one height, 9pt at another. The
	/// window's inset is the one that is always the same.
	private func updateHeight() {
		let inset = window?.safeAreaInsets.bottom ?? safeAreaInsets.bottom
		if abs(state.bottomInset - inset) > 0.5 {
			state.bottomInset = inset
		}
		guard measuredRowsHeight > 0, abs(measuredRowsHeight - contentHeight.constant) > 0.5 else {
			return
		}
		contentHeight.constant = measuredRowsHeight
		invalidateIntrinsicContentSize()
		setNeedsLayout()
		layoutIfNeeded()
		onHeightChanged?()
	}

}

extension KeyboardToolbarInputView: UIInputViewAudioFeedback {
	var enableInputClicksWhenVisible: Bool {
		// Conforming to <UIInputViewAudioFeedback> allows the buttons to make the click sound
		// when tapped
		true
	}
}

/// The landscape side bar.
///
/// In landscape on iPhone the keyboard already takes most of the height, and an accessory bar above
/// it takes more of what’s left. Width is the resource landscape has to spare, so the keys move to a
/// strip pinned to the screen edge and the accessory bar goes away entirely.
///
/// It’s a `UIInputView` purely to pick up the same keyboard-matching background as the accessory
/// bar, even though it’s hosted as an ordinary subview.
class KeyboardSideBarView: UIInputView {

	/// One key wide, plus the padding the key stack adds around it.
	static let width: CGFloat = 53

	private var hostingView: UIHostingView<AnyView>!

	init(delegate: KeyboardToolbarViewDelegate?, state: KeyboardToolbarViewState) {
		super.init(frame: .zero, inputViewStyle: .keyboard)

		translatesAutoresizingMaskIntoConstraints = false
		layer.cornerRadius = 12
		layer.cornerCurve = .continuous
		clipsToBounds = true

		hostingView = UIHostingView(rootView: AnyView(
			// Scrolls because the strip has to fit whatever height is left over — which with the
			// keyboard up in landscape can be very little.
			ScrollView(.vertical, showsIndicators: false) {
				KeyboardToolbarKeyStack(delegate: delegate, toolbar: .sideBar, axis: .vertical)
					.padding(.vertical, 2)
					.padding(.horizontal, 4)
			}
				.environmentObject(state)
		))
		hostingView.translatesAutoresizingMaskIntoConstraints = false
		// Deliberately NOT shouldResizeToFitContent: that grows the host to fit every key, which leaves
		// the scroll view with unbounded height so it never scrolls — the keys past the bottom of the
		// screen were simply clipped and unreachable. Pinned to the strip instead, the scroll view gets
		// a real height and takes over.
		hostingView.shouldResizeToFitContent = false
		// The strip sits inside the screen's side safe area, and SwiftUI adds that inset to its own
		// layout — so the keys were laid out 28pt wider than the 53pt strip that clips them, and every
		// one lost its right-hand side. The strip is already placed clear of the island by hand; it
		// doesn't want the inset applied a second time inside.
		hostingView._disableSafeAreaInsets()
		hostingView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
		addSubview(hostingView)

		NSLayoutConstraint.activate([
			widthAnchor.constraint(equalToConstant: Self.width),
			hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
			hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
			hostingView.topAnchor.constraint(equalTo: topAnchor),
			hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
		])
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

}

extension KeyboardSideBarView: UIInputViewAudioFeedback {
	var enableInputClicksWhenVisible: Bool { true }
}

/// The column a side bar toggle opens, laid over the terminal alongside the strip.
///
/// The rows More and Projects open in portrait sit above the keyboard, which in landscape is both the
/// wrong place — the keys that open them are at the screen edge — and the one direction there's no
/// room in. Beside the strip they cost width, which is what landscape has spare.
///
/// A view of its own rather than a second column inside the strip: the strip's width is what places
/// its keys, so growing it to make room slid every one of them sideways the moment a toggle was
/// pressed. Separate, the strip is the same 53pt in the same place whether a panel is open or not.
class KeyboardSidePanelView: UIInputView {

	/// Gap between the strip and the panel.
	static let spacing: CGFloat = 4

	private var hostingView: UIHostingView<AnyView>!
	private var widthConstraint: NSLayoutConstraint!
	private var toggleObserver: AnyCancellable?

	init(delegate: KeyboardToolbarViewDelegate?, state: KeyboardToolbarViewState) {
		super.init(frame: .zero, inputViewStyle: .keyboard)

		translatesAutoresizingMaskIntoConstraints = false
		layer.cornerRadius = 12
		layer.cornerCurve = .continuous
		clipsToBounds = true
		isHidden = true

		hostingView = UIHostingView(rootView: AnyView(
			KeyboardSidePanelContent(delegate: delegate)
				.environmentObject(state)
		))
		hostingView.translatesAutoresizingMaskIntoConstraints = false
		hostingView.shouldResizeToFitContent = false
		// Same reason as the strip: the panel is placed by hand, and SwiftUI adding the screen's side
		// safe area again inside it lays the content out wider than the view that clips it.
		hostingView._disableSafeAreaInsets()
		hostingView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
		addSubview(hostingView)

		widthConstraint = widthAnchor.constraint(equalToConstant: KeyboardSideBarView.width)
		NSLayoutConstraint.activate([
			widthConstraint,
			hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
			hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
			hostingView.topAnchor.constraint(equalTo: topAnchor),
			hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
		])

		toggleObserver = state.$toggledKeys
			.map { Self.width(forToggles: $0) }
			.removeDuplicates()
			.sink { [weak self] width in self?.apply(width: width) }
	}

	/// One key column wide, whatever is in it — the panel is a second strip beside the first, not a
	/// sheet. `nil` when nothing is open, so the panel isn't a stray translucent box over the terminal.
	private static func width(forToggles toggles: Set<ToolbarKey>) -> CGFloat? {
		// Fn keys win over More, because More is what opens them and so both are on at once.
		guard !toggles.isDisjoint(with: [.projects, .ssh, .ai, .fnKeys, .more]) else {
			return nil
		}
		return KeyboardSideBarView.width
	}

	private func apply(width: CGFloat?) {
		guard let width else {
			isHidden = true
			return
		}
		widthConstraint.constant = width
		isHidden = false
		// Deliberately not `layoutIfNeeded`. This runs from `@Published`'s `willSet`, so the property
		// hasn't actually changed yet — forcing a layout here made SwiftUI render against the old value
		// and consider itself up to date, and it never drew the new one. The panel then sat at the new
		// column's width still showing the old column's contents.
		superview?.setNeedsLayout()
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

}

extension KeyboardSidePanelView: UIInputViewAudioFeedback {
	var enableInputClicksWhenVisible: Bool { true }
}

private struct KeyboardSidePanelContent: View {
	weak var delegate: KeyboardToolbarViewDelegate?

	@EnvironmentObject private var state: KeyboardToolbarViewState

	@ViewBuilder
	var body: some View {
		if state.toggledKeys.contains(.projects) {
			ProjectPickerRow(delegate: delegate, axis: .vertical)
		} else if state.toggledKeys.contains(.ssh) {
			SSHHostPickerRow(delegate: delegate, axis: .vertical)
		} else if state.toggledKeys.contains(.ai) {
			AIPickerRow(delegate: delegate, axis: .vertical)
		} else if state.toggledKeys.contains(.fnKeys) {
			column { KeyboardToolbarKeyStack(delegate: delegate, toolbar: .fnKeys, axis: .vertical) }
		} else if state.toggledKeys.contains(.more) {
			column { KeyboardToolbarKeyStack(delegate: delegate, toolbar: .sideBarMore, axis: .vertical) }
		}
	}

	private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
		ScrollView(.vertical, showsIndicators: false) {
			content()
				.padding(.vertical, 2)
				.padding(.horizontal, 4)
				// Against the strip. Centred, the keys floated in the middle of the panel and the space
				// beside them read as a gap between two separate things.
				.frame(maxWidth: .infinity, alignment: .leading)
		}
	}
}
