//
//  TerminalSplitViewController.swift
//  NewTerm (iOS)
//
//  Created by Adam Demasi on 10/4/21.
//

import UIKit
import NewTermCommon

protocol TerminalSplitViewControllerDelegate: AnyObject {
	func terminal(viewController: BaseTerminalSplitViewControllerChild, titleDidChange title: String, isDirty: Bool, hasBell: Bool)
	func terminal(viewController: BaseTerminalSplitViewControllerChild, screenSizeDidChange screenSize: ScreenSize)
	func terminalDidBecomeActive(viewController: BaseTerminalSplitViewControllerChild)
}

class BaseTerminalSplitViewControllerChild: UIViewController {
	weak var delegate: TerminalSplitViewControllerDelegate?

	/// Path of the project this tab belongs to, if any. Kept on the tab itself so opening a project
	/// that already has a session goes back to it instead of stacking up duplicates.
	var projectPath: String?

	/// Stable id for this tab, persisted in the session snapshot so its scrollback can be matched back
	/// to it after a restart.
	var tabID = UUID().uuidString

	var screenSize: ScreenSize?
	var isSplitViewResizing = false
	var showsTitleView = false
}

class TerminalSplitViewController: BaseTerminalSplitViewControllerChild {

	private static let splitSnapPoints: [Double] = [
		1 / 2, // 50%
		1 / 4, // 25%
		1 / 3, // 33%
		2 / 3, // 66%
		3 / 4  // 75%
	]

	var viewControllers: [BaseTerminalSplitViewControllerChild]! {
		didSet { updateViewControllers() }
	}
	var axis: NSLayoutConstraint.Axis = .horizontal {
		didSet {
			guard axis != oldValue else {
				return
			}
			stackView.axis = axis
			// The grabbers and the per-pane size constraints are both built from the axis, so turning
			// the stack alone left each pane pinned on the wrong dimension and the grabber dragging the
			// wrong way. Rebuilding is what the split already does whenever its panes change.
			if viewControllers != nil {
				updateViewControllers()
			}
		}
	}

	override var isSplitViewResizing: Bool {
		didSet { updateIsSplitViewResizing() }
	}
	override var showsTitleView: Bool {
		didSet { updateShowsTitleView() }
	}

	private let stackView = UIStackView()
	private var splitPercentages = [Double]()
	private var oldSplitPercentages = [Double]()
	private var constraints = [NSLayoutConstraint]()

	private var selectedIndex = 0

	/// The pane the user last touched, so an action aimed at "this terminal" hits the one they're in.
	var selectedViewController: BaseTerminalSplitViewControllerChild? {
		viewControllers.indices.contains(selectedIndex) ? viewControllers[selectedIndex] : viewControllers.first
	}

	/// The terminal the user is actually in, following the selection down through nested splits.
	var activeLeaf: TerminalSessionViewController? {
		switch selectedViewController {
		case let session as TerminalSessionViewController: return session
		case let split as TerminalSplitViewController: return split.activeLeaf
		default: return nil
		}
	}

	/// Re-runs every pane's side bar decision, so the strip follows focus from one pane to the other.
	func setNeedsSideBarUpdate() {
		for viewController in viewControllers ?? [] {
			switch viewController {
			case let session as TerminalSessionViewController: session.setNeedsSideBarUpdate()
			case let split as TerminalSplitViewController: split.setNeedsSideBarUpdate()
			default: break
			}
		}
	}

	private var keyboardHeight: CGFloat = 0

	override func loadView() {
		super.loadView()

		stackView.translatesAutoresizingMaskIntoConstraints = false
		stackView.axis = axis
		stackView.spacing = 0
		view.addSubview(stackView)

		NSLayoutConstraint.activate([
			view.safeAreaLayoutGuide.topAnchor.constraint(equalTo: stackView.topAnchor),
			view.safeAreaLayoutGuide.bottomAnchor.constraint(equalTo: stackView.bottomAnchor),
			view.safeAreaLayoutGuide.leadingAnchor.constraint(equalTo: stackView.leadingAnchor),
			view.safeAreaLayoutGuide.trailingAnchor.constraint(equalTo: stackView.trailingAnchor)
		])
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)

		NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardVisibilityChanged(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardVisibilityChanged(_:)), name: UIResponder.keyboardDidShowNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardVisibilityChanged(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardVisibilityChanged(_:)), name: UIResponder.keyboardDidHideNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardVisibilityChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(self.accessoryHeightChanged(_:)), name: TerminalKeyInput.accessoryHeightDidChangeNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(self.accessoryFrameChanged(_:)), name: TerminalKeyInput.accessoryFrameDidChangeNotification, object: nil)
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)

		// Removing keyboard notification observers should come first so we don’t trigger a bunch of
		// probably unnecessary screen size changes.
		NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
		NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardDidShowNotification, object: nil)
		NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
		NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardDidHideNotification, object: nil)
		NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
		NotificationCenter.default.removeObserver(self, name: TerminalKeyInput.accessoryHeightDidChangeNotification, object: nil)
		NotificationCenter.default.removeObserver(self, name: TerminalKeyInput.accessoryFrameDidChangeNotification, object: nil)
	}

	override func updateViewConstraints() {
		super.updateViewConstraints()
		updateConstraints()
	}

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		updateConstraints()
	}

	override func viewSafeAreaInsetsDidChange() {
		super.viewSafeAreaInsetsDidChange()
		updateConstraints()
		// The inset is the keyboard's overlap minus whatever the safe area already accounts for, and
		// that second number isn't necessarily settled when the keyboard first reports itself. At
		// launch it read zero, so the terminal was inset by the home indicator's strip a second time
		// and sat four lines short of the bar until a row was opened and something recomputed it.
		applyKeyboardInsets(animationDuration: 0, curve: nil)
	}

	override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
		super.traitCollectionDidChange(previousTraitCollection)
		updateConstraints()
	}

	// MARK: - Split View

	private func updateViewControllers() {
		loadViewIfNeeded()

		for view in stackView.arrangedSubviews {
			view.removeFromSuperview()
		}

		for (viewController, i) in zip(viewControllers, viewControllers.indices) {
			let containerView = UIView()
			containerView.translatesAutoresizingMaskIntoConstraints = false

			addChild(viewController)
			viewController.delegate = self
			viewController.view.frame = containerView.bounds
			viewController.view.autoresizingMask = [ .flexibleWidth, .flexibleHeight ]
			containerView.addSubview(viewController.view)
			stackView.addArrangedSubview(containerView)
			viewController.didMove(toParent: self)

			if i != viewControllers.count - 1 {
				let splitGrabberView = SplitGrabberView(axis: axis)
				splitGrabberView.translatesAutoresizingMaskIntoConstraints = false
				splitGrabberView.delegate = self
				stackView.addArrangedSubview(splitGrabberView)
			}
		}

		if splitPercentages.count != viewControllers.count {
			let split = Double(1) / Double(viewControllers.count)
			splitPercentages = Array(repeating: split, count: viewControllers.count)
		}

		let attribute: NSLayoutConstraint.Attribute
		let otherAttribute: NSLayoutConstraint.Attribute
		switch axis {
		case .horizontal:
			attribute = .width
			otherAttribute = .height
		case .vertical:
			attribute = .height
			otherAttribute = .width
		@unknown default: fatalError()
		}

		NSLayoutConstraint.deactivate(constraints)
		constraints = viewControllers.map { viewController in
			NSLayoutConstraint(item: viewController.view.superview!,
												 attribute: attribute,
												 relatedBy: .equal,
												 toItem: nil,
												 attribute: .notAnAttribute,
												 multiplier: 1,
												 constant: 0)
		}
		NSLayoutConstraint.activate(constraints)
		NSLayoutConstraint.activate(viewControllers.map { viewController in
			NSLayoutConstraint(item: viewController.view.superview!,
												 attribute: otherAttribute,
												 relatedBy: .equal,
												 toItem: stackView,
												 attribute: otherAttribute,
												 multiplier: 1,
												 constant: 0)
		})
	}

	/// Takes a pane out of the split without ending its session, so the caller can put it somewhere
	/// else. `remove` is the other case: that one is a terminal that has finished.
	@discardableResult
	func detach(viewController: BaseTerminalSplitViewControllerChild) -> BaseTerminalSplitViewControllerChild? {
		guard let index = viewControllers.firstIndex(of: viewController) else {
			return nil
		}
		viewController.willMove(toParent: nil)
		viewController.view.removeFromSuperview()
		viewController.removeFromParent()
		viewControllers.remove(at: index)
		return viewController
	}

	func remove(viewController: UIViewController) {
		guard let viewController = viewController as? BaseTerminalSplitViewControllerChild,
					let index = viewControllers.firstIndex(where: { item in viewController == item }) else {
			return
		}

		viewControllers.remove(at: index)

		if viewControllers.isEmpty {
			// All view controllers in the split have been removed, so remove ourselves.
			if let parentSplitView = parent as? TerminalSplitViewController {
				parentSplitView.remove(viewController: self)
			} else if let rootViewController = parent as? RootViewController {
				rootViewController.removeTerminal(viewController: self)
			}
		}
		updateViewControllers()
	}

	private func updateConstraints() {
		let totalSpace: CGFloat
		switch axis {
		case .horizontal: totalSpace = stackView.frame.size.width - 10
		case .vertical:   totalSpace = stackView.frame.size.height - 10
		@unknown default: fatalError()
		}

		for (i, constraint) in constraints.enumerated() {
			constraint.constant = totalSpace * CGFloat(splitPercentages[i])
		}
	}

	private func updateIsSplitViewResizing() {
		// A parent split view is resizing. Let our children know.
		for viewController in viewControllers {
			viewController.isSplitViewResizing = isSplitViewResizing
		}
	}

	private func updateShowsTitleView() {
		// A parent split view wants title views. Let our children know.
		for viewController in viewControllers {
			viewController.showsTitleView = showsTitleView
		}
	}

	// MARK: - Keyboard

	@objc func keyboardVisibilityChanged(_ notification: Notification) {
		guard let userInfo = notification.userInfo,
					let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
					let animationDuration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval,
					let curve = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt else {
			return
		}

		// We do this to avoid the scroll indicator from appearing as soon as the terminal appears.
		// We only want to see it after the keyboard has appeared.
//		if !hasAppeared {
//			hasAppeared = true
//			textView.showsVerticalScrollIndicator = true
//
//			if let error = failureError {
//				// Try to handle the error again now that the UI is ready.
//				didReceiveError(error: error)
//				failureError = nil
//			}
//		}

		// Hide toolbar popups if visible
//		keyInput.setMoreRowVisible(false, animated: true)

		// However much of the keyboard actually overlaps us, whatever the notification is called.
		//
		// It has to be the overlap and not the frame’s full height: with a hardware keyboard attached,
		// iOS reports a full-height keyboard sitting almost entirely below the screen and leaves only
		// the accessory bar visible. Taking the height as-is reserved ~300pt of dead space that nothing
		// was ever drawn into.
		//
		// And it must not be forced to zero on `keyboardWillHide`, which is what used to happen. iOS
		// reports an 84pt end frame there — the accessory bar, which stays on screen after the keys go
		// away — and discarding it let the terminal draw underneath the toolbar. Measured on an
		// iPhone 17 Pro Max simulator: accessory-only 84pt, keys up 402pt, and willHide reports 84pt,
		// not 0. When the keyboard genuinely leaves, the end frame is off screen and the overlap is
		// zero on its own.
		apply(keyboardFrame: keyboardFrame, animationDuration: animationDuration, curve: curve)
	}

	/// The accessory bar grew or shrank a row without the keyboard moving.
	///
	/// UIKit posts no keyboard frame change for that — the bar sizes itself — so without this the
	/// terminal keeps the inset it had and draws underneath the taller bar. `TerminalKeyInput` used to
	/// force the notification by reloading its input views, which UIKit animates as taking the bar
	/// away and bringing a new one back: the whole bar visibly dived off the bottom and returned.
	@objc func accessoryHeightChanged(_ notification: Notification) {
		guard let delta = notification.userInfo?[TerminalKeyInput.accessoryHeightDeltaKey] as? CGFloat else {
			return
		}
		// The change, applied to the overlap already known. Asking the bar for its frame instead means
		// waiting for UIKit to place it, which happens a turn later — and by then the new row has been
		// drawn over the terminal's last lines. Captured at 30fps: the row appeared on top of the
		// output for two frames before the text reflowed out from under it.
		keyboardHeight += delta
		applyKeyboardInsets(animationDuration: 0, curve: nil)
	}

	/// Where the bar actually ended up, which settles any drift the delta left behind.
	@objc func accessoryFrameChanged(_ notification: Notification) {
		guard let frame = notification.userInfo?[TerminalKeyInput.accessoryFrameKey] as? CGRect else {
			return
		}
		apply(keyboardFrame: frame, animationDuration: 0, curve: nil)
	}

	private func apply(keyboardFrame: CGRect, animationDuration: TimeInterval, curve: UInt?) {
		keyboardHeight = view.convert(keyboardFrame, from: nil)
			.intersection(view.bounds)
			.height
		applyKeyboardInsets(animationDuration: animationDuration, curve: curve)
	}

	private func applyKeyboardInsets(animationDuration: TimeInterval, curve: UInt?) {
		// Only the part of the keyboard the safe area doesn’t already account for. Flooring this at
		// bottomInset instead of 0 held a home-indicator’s worth of dead space under the terminal
		// whenever the keyboard was down — the view never came all the way back.
		let updateInsets = {
			// The window's, not the parent's. The parent's reads zero until it has been laid out, and at
			// launch that is exactly when the keyboard first reports itself — so the home indicator's
			// strip was subtracted from nothing, counted twice, and the terminal sat 34pt short of the
			// bar until a row was opened and it was recomputed against a settled parent.
			let bottomInset = self.view.window?.safeAreaInsets.bottom
				?? self.parent?.view.safeAreaInsets.bottom
				?? 0
			self.additionalSafeAreaInsets.bottom = max(0, self.keyboardHeight - bottomInset)
		}

		guard let curve = curve else {
			UIView.performWithoutAnimation(updateInsets)
			return
		}

		// We update the safe areas in an animation block to force it to be animated with the exact
		// parameters given to us in the notification.
		var options: UIView.AnimationOptions = .beginFromCurrentState
		options.insert(.init(rawValue: curve << 16))

		UIView.animate(withDuration: animationDuration,
									 delay: 0,
									 options: options,
									 animations: updateInsets)
	}

}

extension TerminalSplitViewController: TerminalSplitViewControllerDelegate {

	func terminal(viewController: BaseTerminalSplitViewControllerChild, titleDidChange title: String, isDirty: Bool, hasBell: Bool) {
		guard let index = viewControllers.firstIndex(of: viewController),
					selectedIndex == index else {
			return
		}

		#if targetEnvironment(macCatalyst)
		let newTitle: String
		switch true {
		case hasBell: newTitle = "🔔 \(title)"
		case isDirty: newTitle = "• \(title)"
		default:      newTitle = title
		}
		self.title = newTitle
		#else
		self.title = title
		#endif

		if let parent = parent as? TerminalSplitViewControllerDelegate {
			parent.terminal(viewController: self, titleDidChange: title, isDirty: isDirty, hasBell: hasBell)
		} else if let parent = parent as? BaseTerminalSplitViewControllerChild {
			parent.delegate?.terminal(viewController: self, titleDidChange: title, isDirty: isDirty, hasBell: hasBell)
		}
	}

	func terminal(viewController: BaseTerminalSplitViewControllerChild, screenSizeDidChange screenSize: ScreenSize) {
		guard let index = viewControllers.firstIndex(of: viewController),
					selectedIndex == index else {
			return
		}

		self.screenSize = screenSize

		if let parent = parent as? TerminalSplitViewControllerDelegate {
			parent.terminal(viewController: self, screenSizeDidChange: screenSize)
		} else if let parent = parent as? BaseTerminalSplitViewControllerChild {
			parent.delegate?.terminal(viewController: self, screenSizeDidChange: screenSize)
		}
	}

	func terminalDidBecomeActive(viewController: BaseTerminalSplitViewControllerChild) {
		guard let index = viewControllers.firstIndex(of: viewController) else {
			return
		}

		selectedIndex = index
		// The side bar belongs to whichever pane has focus, so moving focus moves the strip.
		setNeedsSideBarUpdate()

		if let parent = parent as? TerminalSplitViewControllerDelegate {
			parent.terminalDidBecomeActive(viewController: self)
		} else if let parent = parent as? BaseTerminalSplitViewControllerChild {
			parent.delegate?.terminalDidBecomeActive(viewController: self)
		}
	}

}

extension TerminalSplitViewController: SplitGrabberViewDelegate {

	func splitGrabberViewDidBeginDragging(_ splitGrabberView: SplitGrabberView) {
		oldSplitPercentages = splitPercentages

		for viewController in viewControllers {
			viewController.isSplitViewResizing = true
		}
	}

	func splitGrabberView(_ splitGrabberView: SplitGrabberView, splitDidChange delta: CGFloat) {
		let totalSpace: CGFloat
		switch axis {
		case .horizontal: totalSpace = stackView.frame.size.width
		case .vertical:   totalSpace = stackView.frame.size.height
		@unknown default: fatalError()
		}

		let percentage = Double(delta / totalSpace)
		let firstSplit = max(0.15, min(0.85, oldSplitPercentages[0] + percentage))
		let secondSplit = 1 - firstSplit

		var didSnap = false
		for point in Self.splitSnapPoints {
			if firstSplit > point - 0.02 && firstSplit < point + 0.02 {
				splitPercentages[0] = point
				splitPercentages[1] = 1 - point
				didSnap = true
				break
			}
		}

		if !didSnap {
			splitPercentages[0] = firstSplit
			splitPercentages[1] = secondSplit
		}

		UIView.animate(withDuration: 0.2) {
			self.updateConstraints()
		}
	}

	func splitGrabberViewDidCommit(_ splitGrabberView: SplitGrabberView) {
		oldSplitPercentages.removeAll()

		for viewController in viewControllers {
			viewController.isSplitViewResizing = false
		}
	}

	func splitGrabberViewDidCancel(_ splitGrabberView: SplitGrabberView) {
		splitPercentages = oldSplitPercentages
		updateConstraints()

		for viewController in viewControllers {
			viewController.isSplitViewResizing = false
		}
	}

}
