//
//  PaneHeaderView.swift
//  NewTerm (iOS)
//

import UIKit

/// A one-line label naming a terminal, shown across the top of each half of a split.
///
/// A split takes the terminal from the tab next door, so that tab is no longer in the strip along the
/// top and neither half is named by anything. This says which terminal each half is, and which of the
/// two is the one the keyboard is talking to.
class PaneHeaderView: UIView {

	static let height: CGFloat = 20

	private let label = UILabel()

	init() {
		super.init(frame: .zero)

		translatesAutoresizingMaskIntoConstraints = false

		label.translatesAutoresizingMaskIntoConstraints = false
		label.font = .systemFont(ofSize: 11, weight: .medium)
		label.textAlignment = .center
		label.lineBreakMode = .byTruncatingTail
		addSubview(label)

		NSLayoutConstraint.activate([
			heightAnchor.constraint(equalToConstant: Self.height),
			label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
			label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
			label.centerYAnchor.constraint(equalTo: centerYAnchor)
		])
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func configure(title: String, isActive: Bool) {
		label.text = title.isEmpty
			? .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")
			: title
		// The active half is stated rather than merely not-dimmed: with only two of them, "the brighter
		// one" is a comparison the user has to make, and a tint is something they can just see.
		label.textColor = isActive ? .white : .secondaryLabel
		backgroundColor = isActive
			? UIColor.systemBlue.withAlphaComponent(0.55)
			: UIColor.label.withAlphaComponent(0.08)
	}
}
