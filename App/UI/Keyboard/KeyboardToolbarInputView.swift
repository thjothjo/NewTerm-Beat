//
//  KeyboardToolbarInputView.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import SwiftUIX

class KeyboardToolbarInputView: UIInputView {

	private var hostingView: UIHostingView<AnyView>!

	init(delegate: KeyboardToolbarViewDelegate?, toolbars: [Toolbar], state: KeyboardToolbarViewState) {
		super.init(frame: .zero, inputViewStyle: .keyboard)

		translatesAutoresizingMaskIntoConstraints = false
		allowsSelfSizing = true

		hostingView = UIHostingView(rootView: AnyView(
			KeyboardToolbarView(delegate: delegate, toolbars: toolbars)
				.environmentObject(state)
		))
		hostingView.translatesAutoresizingMaskIntoConstraints = false
		hostingView.shouldResizeToFitContent = true
		hostingView.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
		addSubview(hostingView)

		NSLayoutConstraint.activate([
			hostingView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
			hostingView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
			hostingView.topAnchor.constraint(equalTo: self.topAnchor),
			hostingView.bottomAnchor.constraint(equalTo: self.bottomAnchor)
		])
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
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
