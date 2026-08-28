//
//  TabToolbarViewController.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import SwiftUIX

protocol TabToolbarDataSource: AnyObject {
	func numberOfTerminals() -> Int
	func selectedTerminalIndex() -> Int
	func terminalName(at index: Int) -> String
	func isTerminalSplit(at index: Int) -> Bool
}

protocol TabToolbarDelegate: AnyObject {
	func addTerminal()
	func selectTerminal(at index: Int)
	func removeTerminal(at index: Int)
	func toggleSplit()

	func openSettings()
	func openPasswordManager()
}

class TabToolbarViewController: UIViewController {

	weak var dataSource: TabToolbarDataSource?
	weak var delegate: TabToolbarDelegate? {
		didSet {
			state.delegate = delegate
		}
	}

	private let state = TabToolbarState()

	private var backdropView: UIToolbar!
	private var hostingView: UIHostingView<AnyView>!
	private var leadingConstraint: NSLayoutConstraint!
	private var trailingConstraint: NSLayoutConstraint!

	override func viewDidLoad() {
		super.viewDidLoad()

		view.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)

		backdropView = UIToolbar()
		backdropView.frame = view.bounds
		backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		backdropView.delegate = self
		view.addSubview(backdropView)

		hostingView = UIHostingView(rootView: AnyView(TabToolbarView()
			.environmentObject(state)))
		hostingView.translatesAutoresizingMaskIntoConstraints = false
		hostingView.shouldResizeToFitContent = true
		hostingView.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
		view.addSubview(hostingView)

		// Pinned to the view's own edges rather than its safe area, so the side insets can be set per
		// edge — the safe area can't tell the Dynamic Island's side from the empty one.
		leadingConstraint = hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
		trailingConstraint = view.trailingAnchor.constraint(equalTo: hostingView.trailingAnchor)

		NSLayoutConstraint.activate([
			hostingView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
			hostingView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
			leadingConstraint,
			trailingConstraint
		])

		// See `setNeedsInsetUpdate` — a 180° flip notifies nothing else.
		UIDevice.current.beginGeneratingDeviceOrientationNotifications()
		NotificationCenter.default.addObserver(self, selector: #selector(self.setNeedsInsetUpdate), name: UIDevice.orientationDidChangeNotification, object: nil)
	}

	override func viewWillLayoutSubviews() {
		super.viewWillLayoutSubviews()
		updateHorizontalInsets()
	}

	override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
		super.viewWillTransition(to: size, with: coordinator)
		coordinator.animate(alongsideTransition: nil) { _ in
			self.setNeedsInsetUpdate()
		}
	}

	/// Asks for a layout pass rather than recomputing here, so the insets are worked out once UIKit
	/// has settled the new interface orientation instead of racing it.
	///
	/// A 180° landscape flip moves the Dynamic Island to the other side without changing the bounds,
	/// the traits, or the safe-area insets — those are symmetric — so no callback fires on its own and
	/// the bar would keep the insets it worked out for the side the island used to be on.
	@objc private func setNeedsInsetUpdate() {
		view.setNeedsLayout()
	}

	/// Brings the bar in only as far as each edge actually needs.
	///
	/// In landscape both side insets come back the same, sized for the Dynamic Island, which left the
	/// tabs a long way in from the edge that has no island — further in than the keyboard strip below
	/// them. The edge with the island keeps the full inset; the other one only has to clear the
	/// display's rounded corner, and the bar's leading spacer is already wider than that corner
	/// reaches, so nothing visible sits in it.
	private func updateHorizontalInsets() {
		let safeInsets = view.safeAreaInsets
		let islandLeading = DisplayEdge.isIslandOnLeadingEdge(for: view.window?.windowScene?.interfaceOrientation)
		// `min` so an edge that iOS isn't holding space back on — portrait, or a display with square
		// corners — stays where it is rather than being pushed in.
		leadingConstraint.constant = islandLeading ? safeInsets.left : min(safeInsets.left, DisplayEdge.inset)
		trailingConstraint.constant = islandLeading ? min(safeInsets.right, DisplayEdge.inset) : safeInsets.right
	}

	@objc private func addTerminal() {
		delegate?.addTerminal()
	}

	@objc private func openSettings() {
		delegate?.openSettings()
	}

	@objc private func openPasswordManager() {
		delegate?.openPasswordManager()
	}

	@objc private func removeTerminalButtonTapped(_ button: UIButton) {
		delegate?.removeTerminal(at: button.tag)
	}

	func didSelectTab(at index: Int) {
		state.selectedIndex = dataSource!.selectedTerminalIndex()
	}

	/// Leaves tab edit mode, for taps that land outside the tab bar entirely — on the terminal.
	func endEditing() {
		state.isEditing = false
	}

	func didAddTab(at index: Int) {
		let terminal = TerminalTab(title: "",
															 screenSize: .default,
															 isDirty: false,
															 hasBell: false)
		if index == state.terminals.count {
			state.terminals.append(terminal)
		} else {
			state.terminals.insert(terminal, at: index)
		}
	}

	func didRemoveTab(at index: Int) {
		state.terminals.remove(at: index)
	}

	func tabDidUpdate(at index: Int) {
		state.terminals[index].title = dataSource?.terminalName(at: index) ?? .localize("Terminal")
		state.terminals[index].isSplit = dataSource?.isTerminalSplit(at: index) ?? false
	}

	private func selectTerminal(at index: Int) {
		state.selectedIndex = index
		delegate?.selectTerminal(at: index)
	}

}

extension TabToolbarViewController: UIToolbarDelegate {

	func position(for bar: UIBarPositioning) -> UIBarPosition {
		// Helps UIToolbar figure out where to place the shadow line
		return .top
	}

}
