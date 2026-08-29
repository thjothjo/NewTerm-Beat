//
//  TerminalSessionViewController.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import os.log
import CoreServices
import PhotosUI
import SwiftUIX
import NewTermCommon

class TerminalSessionViewController: BaseTerminalSplitViewControllerChild {

	override var isSplitViewResizing: Bool {
		didSet { updateIsSplitViewResizing() }
	}
	override var showsTitleView: Bool {
		didSet { updateShowsTitleView() }
	}
	override var screenSize: ScreenSize? {
		get { terminalController.screenSize }
		set { terminalController.screenSize = newValue }
	}

	private var terminalController = TerminalController()
	private var keyInput = TerminalKeyInput(frame: .zero)
	private var textView: TerminalHostingView!
	private var textViewTapGestureRecognizer: UITapGestureRecognizer!
	private var textViewLongPressGestureRecognizer: UILongPressGestureRecognizer!
	private var selectionHandlePanGestureRecognizer: UIPanGestureRecognizer!
	private var sideBarView: KeyboardSideBarView?
	private var sidePanelView: KeyboardSidePanelView?
	private var paneHeaderView: PaneHeaderView?
	private var paneTitle = ""
	private var sideBarLeadingConstraint: NSLayoutConstraint?
	private var sideBarTopConstraint: NSLayoutConstraint?
	private var sideBarBottomConstraint: NSLayoutConstraint?

	private var state = TerminalState()

	private var hudState = HUDViewState()
	private var hudView: UIHostingView<AnyView>!

	/// When the bell last sounded, so a burst of them is announced once.
	///
	/// A shell rings the bell every time a key can't do anything — backspace at an empty prompt, tab
	/// with nothing to complete. Tapping Delete a few times at a bare prompt is three or four of
	/// those, and answering each with a sound and a jolt of haptics turns a key doing nothing into the
	/// loudest thing the app does.
	private var lastBellAt = Date.distantPast
	private static let bellCoalescingInterval: TimeInterval = 0.5

	private var hasAppeared = false
	private var hasStarted = false
	private var failureError: Error?

	private var lastAutomaticScrollOffset = CGPoint.zero
	private var invertScrollToTop = false

	private var isPickingFileForUpload = false

	/// `UIEditMenuInteraction` on iOS 16+, held as AnyObject because stored properties can’t be
	/// annotated with availability.
	private var editMenuInteraction: AnyObject?

	/// What the long press selected before the finger started moving. Dragging extends from this
	/// rather than from the touch point.
	private var selectionBase: TerminalSelection?
	/// Which handle the current pan is moving, if it started on one.
	private var draggingHandle: SelectionHandle?

	/// How close a touch has to land to a handle to grab it. Sized for a fingertip, not the knob.
	private static let handleGrabRadius: CGFloat = 22

	private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
	/// Absolute (`/…`) and home-relative (`~/…`) paths. Deliberately loose — false positives are
	/// filtered out by checking the path actually exists before offering to open it.
	private static let pathDetector = try? NSRegularExpression(pattern: #"(?:~/|/)[^\s"'`<>|]+"#)

	private static let logger = Logger(subsystem: "ws.hbang.Terminal", category: "TerminalSession")

	/// Which saved scrollback this pane replays, and where its own is written back. Nil for a pane
	/// with no history to remember. Internal so a pane that moves to another tab can take its history
	/// with it rather than leaving it behind under the old tab's name.
	let scrollbackID: String?
	private var hasSeededScrollback = false

	init(initialDirectory: String? = nil, initialCommand: String? = nil, scrollbackID: String? = nil) {
		self.scrollbackID = scrollbackID
		super.init(nibName: nil, bundle: nil)

		terminalController.delegate = self
		terminalController.initialDirectory = initialDirectory
		terminalController.initialCommand = initialCommand
		// The shell is deliberately *not* started here — see startSubProcessIfNeeded().
	}

	/// Starts the shell, once we know how big the terminal is.
	///
	/// Starting in `init` would open the pty at the default 80×25 and leave the real size to arrive
	/// later as a SIGWINCH the shell may never see. Waiting for the first layout costs nothing — the
	/// view isn’t on screen yet — and the shell comes up already knowing its size.
	private func startSubProcessIfNeeded() {
		guard !hasStarted, failureError == nil,
					let screenSize = screenSize,
					// A zero size is worse than no size: the pty opens 0×0, the shell’s TIOCGWINSZ comes
					// back empty, and it falls back to terminfo’s 80×24 and stays there.
					screenSize.cols > 0, screenSize.rows > 0 else {
			return
		}
		// Replay saved output before the shell starts, so the history is already on screen when the new
		// prompt appears. Once only, and only before the first start.
		if !hasSeededScrollback {
			hasSeededScrollback = true
			if let scrollbackID = scrollbackID,
				 let saved = ScrollbackStore.shared.load(id: scrollbackID) {
				terminalController.seedScrollback(saved)
			}
		}
		do {
			try terminalController.startSubProcess()
			hasStarted = true
		} catch {
			failureError = error
			if hasAppeared {
				didReceiveError(error: error)
			}
		}
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		super.loadView()

		title = .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")

		preferencesUpdated()
		textView = TerminalHostingView(state: state)

		keyInput.canCopy = { [weak self] in self?.state.selection != nil }
		keyInput.copyHandler = { [weak self] in self?.copySelection() }
		keyInput.openProjectHandler = { [weak self] in self?.openProject($0) }
		keyInput.newProjectHandler = { [weak self] in self?.rootViewController?.createProject() }
		keyInput.deleteProjectHandler = { [weak self] in self?.rootViewController?.trashProject($0) }
		keyInput.connectSSHHostHandler = { [weak self] in self?.connectSSH(to: $0) }
		keyInput.newSSHHostHandler = { [weak self] in self?.addSSHHost() }
		keyInput.aiCommandHandler = { [weak self] in self?.insertAICommand($0) }
		keyInput.attachImageHandler = { [weak self] in self?.attachImage() }

		textViewTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.handleTextViewTap(_:)))
		textViewTapGestureRecognizer.delegate = self
		textView.addGestureRecognizer(textViewTapGestureRecognizer)

		// UIKit rather than a SwiftUI gesture: UILongPressGestureRecognizer reports a location on
		// .began, so a press that never moves still selects the word under the finger. SwiftUI’s
		// LongPressGesture carries no location, and only yields one once the finger has moved.
		textViewLongPressGestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(self.handleTextViewLongPress(_:)))
		textViewLongPressGestureRecognizer.minimumPressDuration = 0.35
		textView.addGestureRecognizer(textViewLongPressGestureRecognizer)

		// Only claims the touch when it lands on a selection handle (see `gestureRecognizerShouldBegin`),
		// so scrolling the terminal is unaffected everywhere else.
		selectionHandlePanGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(self.handleSelectionHandlePan(_:)))
		selectionHandlePanGestureRecognizer.delegate = self
		textView.addGestureRecognizer(selectionHandlePanGestureRecognizer)

		keyInput.frame = view.bounds
		keyInput.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		keyInput.textView = textView
		keyInput.terminalInputDelegate = terminalController
		view.addSubview(keyInput)
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		hudView = UIHostingView(rootView: AnyView(
			HUDView()
				.environmentObject(self.hudState)
		))
		hudView.translatesAutoresizingMaskIntoConstraints = false
		hudView.shouldResizeToFitContent = true
		hudView.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
		hudView.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
		view.addSubview(hudView)

		NSLayoutConstraint.activate([
			hudView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			hudView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
		])

		addKeyCommand(UIKeyCommand(title: .localize("CLEAR_TERMINAL", comment: "VoiceOver label for a button that clears the terminal."),
															 image: UIImage(systemName: "text.badge.xmark"),
															 action: #selector(self.clearTerminal),
															 input: "k",
															 modifierFlags: .command))

		#if !targetEnvironment(macCatalyst)
		addKeyCommand(UIKeyCommand(title: .localize("PASSWORD_MANAGER", comment: "VoiceOver label for the password manager button."),
															 image: UIImage(systemName: "key.fill"),
															 action: #selector(self.activatePasswordManager),
															 input: "f",
															 modifierFlags: [ .command, .alternate ]))
		#endif

		if UIApplication.shared.supportsMultipleScenes {
			NotificationCenter.default.addObserver(self, selector: #selector(self.sceneDidEnterBackground), name: UIWindowScene.didEnterBackgroundNotification, object: nil)
			NotificationCenter.default.addObserver(self, selector: #selector(self.sceneWillEnterForeground), name: UIWindowScene.willEnterForegroundNotification, object: nil)
		}

		// The scene notifications above only register on multi-scene devices (iPad/Mac). Scrollback has
		// to be saved on iPhone too, so hang it off the app-level notification, which always fires.
		NotificationCenter.default.addObserver(self, selector: #selector(self.appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)

		// Second path to the same relayout. A 180° landscape flip is the case that needs it, and it is
		// exactly the case where `viewWillTransition` is passed an unchanged size — so don't rely on
		// that alone. Both just mark the layout dirty, so firing twice costs nothing.
		UIDevice.current.beginGeneratingDeviceOrientationNotifications()
		NotificationCenter.default.addObserver(self, selector: #selector(self.setNeedsSideBarUpdate), name: UIDevice.orientationDidChangeNotification, object: nil)

		NotificationCenter.default.addObserver(self, selector: #selector(self.preferencesUpdated), name: Preferences.didChangeNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(self.accessoryFrameChanged), name: TerminalKeyInput.accessoryFrameDidChangeNotification, object: nil)

		updateSideBar()
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)

		keyInput.wantsDockedBar = true
		keyInput.becomeFirstResponder()
		terminalController.terminalWillAppear()
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)

		hasAppeared = true

		if let error = failureError {
			didReceiveError(error: error)
		}
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)

		keyInput.wantsDockedBar = false
		keyInput.resignFirstResponder()
		terminalController.terminalWillDisappear()
	}

	override func viewDidDisappear(_ animated: Bool) {
		super.viewDidDisappear(animated)

		hasAppeared = false
	}

	override func viewWillLayoutSubviews() {
		super.viewWillLayoutSubviews()
		// Belt and braces: traitCollectionDidChange is the usual trigger, but rotation doesn’t always
		// deliver it before the first layout of the new size.
		updateSideBar()
		updateScreenSize()
	}

	/// The bar has settled on a height, whether or not that moved the safe area.
	///
	/// The first measurement after launch deliberately reports no change — UIKit's keyboard
	/// notification already accounted for the bar — so nothing else asks the terminal to work out how
	/// many rows now fit. It kept the count from before the bar settled, which is fewer than fit, and
	/// the shortfall showed as a gap under the last line that only closed once a row had been opened.
	@objc private func accessoryFrameChanged() {
		updateScreenSize()
	}

	override func viewSafeAreaInsetsDidChange() {
		super.viewSafeAreaInsetsDidChange()
		updateScreenSize()
		// Deliberately not re-pinning the scroll here. Doing so asks the view to scroll to the bottom of
		// lines that were laid out for the old size, against a viewport that is already the new one —
		// captured at 60fps, the output jumped 118pt up for a single frame and dropped back. The
		// resize produces new lines a moment later and the refresh that delivers them re-pins on its
		// own, correctly.
	}

	override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
		super.traitCollectionDidChange(previousTraitCollection)
		updateSideBar()
		updateScreenSize()
	}

	override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
		super.viewWillTransition(to: size, with: coordinator)
		coordinator.animate(alongsideTransition: nil) { _ in
			self.setNeedsSideBarUpdate()
		}
	}

	/// Asks for a layout pass rather than recomputing here, so the inset is worked out once UIKit has
	/// settled the new interface orientation instead of racing it.
	///
	/// Flipping 180° between the two landscape orientations moves the Dynamic Island to the other
	/// side while changing nothing any of the usual callbacks watch: the bounds are identical, the
	/// traits are identical, and the safe-area insets are symmetric so they don't change either.
	/// Nothing asked for a relayout, so the strip kept the inset it had worked out for the side the
	/// island used to be on — and sat under it.
	// MARK: - Pane header

	/// Names the pane while the tab is split, and marks which of the two the keys go to.
	///
	/// Splitting takes the terminal next door and puts it in beside this one, which means its tab is
	/// gone from the strip along the top — so without this there is nothing left saying which terminal
	/// either half is, or which one is listening.
	private func updatePaneHeader() {
		let isSplit = (tabContainer?.viewControllers?.count ?? 1) > 1
		guard isSplit else {
			paneHeaderView?.removeFromSuperview()
			paneHeaderView = nil
			return
		}

		let header: PaneHeaderView
		if let existing = paneHeaderView {
			header = existing
		} else {
			header = PaneHeaderView()
			view.addSubview(header)
			NSLayoutConstraint.activate([
				header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
				header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
				header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
			])
			paneHeaderView = header
		}
		header.configure(title: paneTitle, isActive: isActivePane)
		view.bringSubviewToFront(header)
	}

	/// Takes the strip down, for when this pane shouldn't be showing one.
	private func discardSideBar() {
		sidePanelView?.removeFromSuperview()
		sidePanelView = nil
		sideBarView?.removeFromSuperview()
		sideBarView = nil
		sideBarLeadingConstraint = nil
		sideBarTopConstraint = nil
		sideBarBottomConstraint = nil
	}

	@objc func setNeedsSideBarUpdate() {
		view.setNeedsLayout()
		parent?.viewIfLoaded?.setNeedsLayout()
	}

	/// Shows the landscape key strip on the leading edge, and gives it its own space rather than
	/// floating it over the text — the terminal reflows to the narrower width instead of having a
	/// column hidden behind it.
	/// Width the strip claims from the terminal: the strip itself plus a little breathing room.
	private static let sideBarInset = KeyboardSideBarView.width + 8

	/// How far the strip's ends come in when it's hugging the edge, so they clear the display's
	/// rounded corners. The strip scrolls, so the length this costs is length it can scroll back.
	private static let sideBarCornerClearance = DisplayEdge.clearance(atDistance: DisplayEdge.inset)

	/// Whether the Dynamic Island is on the same edge the strip is pinned to.
	private var isDynamicIslandOnLeadingEdge: Bool {
		DisplayEdge.isIslandOnLeadingEdge(for: view.window?.windowScene?.interfaceOrientation)
	}

	/// The split container filling the whole tab, whichever pane this is.
	///
	/// Not simply `parent`: after a split the panes sit at different depths, so taking each pane's own
	/// parent hosted the two strips in different views and drew them in different places, one over the
	/// other. Every pane resolves to the same container here, so there is one place the strip can be.
	private var tabContainer: TerminalSplitViewController? {
		var candidate: UIViewController? = parent
		while let current = candidate, current.parent != nil, !(current.parent is RootViewController) {
			candidate = current.parent
		}
		return candidate as? TerminalSplitViewController
	}

	/// Whether this pane is the one the user is typing in, and so the one the strip belongs to.
	private var isActivePane: Bool {
		guard let container = tabContainer else {
			return true
		}
		return container.activeLeaf === self
	}

	private func updateSideBar() {
		// Before the frame maths below, which has to know whether a header is taking a strip off the top.
		updatePaneHeader()

		let usesSideBar = TerminalKeyInput.usesSideBar(for: traitCollection)
		// One strip per tab, belonging to the pane with focus, so its keys reach the terminal the user
		// is actually in. Each pane used to make its own, which in a split stacked two of them up.
		let shouldShow = usesSideBar && isActivePane

		// Hosted on the tab container, not on our own view.
		//
		// Our view is inset from the screen by the split container, which pins its content to the safe
		// area — in landscape that's 62pt in from each edge. Hugging the physical edge from here means
		// a negative leading constant, which puts the strip *entirely* outside our bounds: UIKit still
		// draws it, but hit testing is clipped to the superview's bounds, so it never receives a single
		// touch. That's why it looked fine and did nothing. The container's view spans the whole
		// screen, so from there the strip can sit against the edge and still be touchable.
		let host: UIView = tabContainer?.viewIfLoaded ?? parent?.viewIfLoaded ?? view

		if shouldShow && sideBarView == nil {
			let sideBar = KeyboardSideBarView(delegate: keyInput, state: keyInput.toolbarState)
			host.addSubview(sideBar)
			let leading = sideBar.leadingAnchor.constraint(equalTo: host.leadingAnchor)
			sideBarLeadingConstraint = leading
			// Top and bottom are pinned rather than centred with inequalities: those left the height up
			// to the hosting view's intrinsic size, and without that the strip has no defined height at
			// all — it renders wrong and won't scroll.
			let top = sideBar.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 4)
			let bottom = sideBar.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -4)
			sideBarTopConstraint = top
			sideBarBottomConstraint = bottom
			NSLayoutConstraint.activate([leading, top, bottom])
			sideBarView = sideBar

			// Alongside the strip, over the terminal. It hides itself when no toggle has anything open,
			// and its own width constraint sizes it to whichever column that is.
			let panel = KeyboardSidePanelView(delegate: keyInput, state: keyInput.toolbarState)
			host.addSubview(panel)
			NSLayoutConstraint.activate([
				panel.leadingAnchor.constraint(equalTo: sideBar.trailingAnchor,
																			 constant: KeyboardSidePanelView.spacing),
				panel.topAnchor.constraint(equalTo: sideBar.topAnchor),
				panel.bottomAnchor.constraint(equalTo: sideBar.bottomAnchor)
			])
			sidePanelView = panel
		} else if !shouldShow {
			discardSideBar()
		}

		// In landscape iOS reports the same inset on both sides — enough to clear the Dynamic Island —
		// so following it blindly parked the strip 59pt in even on the side with no island, a gap wider
		// than the strip itself. On that side the only thing to clear is the display's rounded corner,
		// and a corner only intrudes at the very ends of the strip: pulling its ends in by
		// `cornerClearance` lets the rest of it sit against the edge.
		let safeInset = view.window?.safeAreaInsets.left ?? 0
		// Only worth reclaiming where iOS is actually holding space back. A phone with no island and
		// square display corners reports no inset, and there the strip is already flush.
		let canHugEdge = !isDynamicIslandOnLeadingEdge && safeInset > DisplayEdge.inset

		let leadingInset = canHugEdge ? DisplayEdge.inset : safeInset
		// Only make up the shortfall. The ends are already held off the display's corners by the tab
		// bar above and the home indicator below, and adding the full clearance on top of those cost
		// the strip a button's worth of height for nothing.
		let hostInsets = host.safeAreaInsets
		let endInset = { (existing: CGFloat) -> CGFloat in
			canHugEdge ? max(4, Self.sideBarCornerClearance - existing) : 4
		}
		sideBarLeadingConstraint?.constant = leadingInset
		sideBarTopConstraint?.constant = endInset(hostInsets.top)
		sideBarBottomConstraint?.constant = -endInset(hostInsets.bottom)

		// Whatever the strip still covers of the text area, the terminal gives up.
		//
		// Measured against where this pane actually starts, not against `shouldShow`: the strip sits at
		// the tab's leading edge, so in a split it covers the leading pane and misses the trailing one
		// entirely — and which pane owns it must not change either pane's width, or the text would
		// reflow every time focus moved between them.
		let paneOriginX = view.superview?.convert(view.frame.origin, to: nil).x ?? safeInset
		let offset = TerminalKeyInput.usesSideBar(for: traitCollection)
			? max(0, leadingInset + Self.sideBarInset - paneOriginX)
			: 0
		// The header, when a split is putting one up, sits above the text rather than over it.
		let headerHeight = paneHeaderView == nil ? 0 : PaneHeaderView.height + view.safeAreaInsets.top
		let frame = CGRect(x: offset,
											 y: headerHeight,
											 width: max(0, keyInput.bounds.width - offset),
											 height: max(0, keyInput.bounds.height - headerHeight))
		if textView.frame != frame {
			textView.autoresizingMask = []
			textView.frame = frame
		}

	}

	// MARK: - Screen

	func updateScreenSize() {
		if isSplitViewResizing {
			return
		}

		// Determine the screen size based on the font size
		var layoutSize = textView.safeAreaLayoutGuide.layoutFrame.size
		layoutSize.width -= TerminalView.horizontalSpacing * 2
		layoutSize.height -= TerminalView.verticalSpacing * 2

		if layoutSize.width < 0 || layoutSize.height < 0 {
			// Not laid out yet. We’ll be called again when we are.
			return
		}

		let glyphSize = terminalController.fontMetrics.boundingBox
		if glyphSize.width == 0 || glyphSize.height == 0 {
			fatalError("Failed to get glyph size")
		}

		let newSize = ScreenSize(cols: UInt16(layoutSize.width / glyphSize.width),
														 rows: UInt16(layoutSize.height / glyphSize.height.rounded(.up)),
														 cellSize: glyphSize)
		if screenSize != newSize {
			// Resizing reflows the buffer, so text moves to different cells while a selection keeps the
			// coordinates it was made with — after a rotation it would be highlighting, and copying,
			// whatever now happens to sit there. There's nothing to re-anchor it to, so it goes.
			clearSelection()
			screenSize = newSize
			delegate?.terminal(viewController: self, screenSizeDidChange: newSize)
		}

		startSubProcessIfNeeded()
	}

	@objc func clearTerminal() {
		terminalController.clearTerminal()
	}

	private func updateIsSplitViewResizing() {
		state.isSplitViewResizing = isSplitViewResizing

		if !isSplitViewResizing {
			updateScreenSize()
		}
	}

	private func updateShowsTitleView() {
		updateScreenSize()
	}

	// MARK: - Gestures

	@objc private func handleTextViewTap(_ gestureRecognizer: UITapGestureRecognizer) {
		guard gestureRecognizer.state == .ended else {
			return
		}

		// Anywhere outside the tab bar counts as the “blank space” that ends tab edit mode.
		rootViewController?.endTabEditing()

		// A tap while something is selected just dismisses the selection, the same as any other text
		// view — it shouldn’t also follow whatever link happens to be underneath.
		if state.selection != nil {
			clearSelection()
			return
		}

		if let cell = cell(at: gestureRecognizer.location(in: textView)),
			 openItem(atRow: cell.row, column: cell.col) {
			return
		}

		if keyInput.isKeyboardHidden {
			// The bar stayed docked while the keyboard was away; tapping the terminal asks for it back.
			keyInput.showKeyboard()
		} else if !keyInput.isFirstResponder {
			keyInput.becomeFirstResponder()
			delegate?.terminalDidBecomeActive(viewController: self)
		}
	}

	// MARK: - Selection

	@objc private func handleTextViewLongPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
		guard let cell = cell(at: gestureRecognizer.location(in: textView)) else {
			return
		}

		switch gestureRecognizer.state {
		case .began:
			let selection: TerminalSelection
			if let range = terminalController.wordRange(atScrollInvariantRow: cell.row, column: cell.col) {
				selection = TerminalSelection(row: cell.row, columns: range)
			} else {
				// No word under the finger — most of a terminal screen is blank, and anchoring an empty
				// selection there meant the long press appeared to do nothing at all: nothing highlighted,
				// and no menu on release because an empty selection is skipped. Take the single cell
				// instead, which is something the user can see and drag out from.
				selection = TerminalSelection(row: cell.row, columns: cell.col..<(cell.col + 1))
			}
			selectionBase = selection
			state.selection = selection

		case .changed:
			// Extend from the edges of what `.began` selected rather than from the touch point. Moving
			// the head to the finger collapsed the word back to wherever inside it the press landed —
			// and a finger never holds perfectly still, so the word selection never survived to be used.
			guard let base = selectionBase else {
				break
			}
			if cell < base.start {
				state.selection = TerminalSelection(anchor: base.end, head: cell)
			} else {
				// The cell under the finger should be included, and `head` is exclusive.
				let head = TerminalSelection.Point(row: cell.row, col: cell.col + 1)
				state.selection = TerminalSelection(anchor: base.start, head: Swift.max(head, base.end))
			}

		case .ended, .cancelled:
			if let selection = state.selection,
				 !selection.isEmpty {
				showEditMenu(at: selectionRect(for: selection))
			}

		default:
			break
		}
	}

	// MARK: - Selection handles

	private enum SelectionHandle {
		case start, end
	}

	/// Centres of the two handles, in `textView` coordinates. The start handle sits above the first
	/// selected cell, the end handle below the last — matching where they’re drawn.
	private func handleCentres(for selection: TerminalSelection) -> (start: CGPoint, end: CGPoint) {
		let cellWidth = terminalController.fontMetrics.width
		let originY = TerminalView.verticalSpacing + state.contentOriginY
		let knob = TerminalView.handleKnobSize / 2
		return (start: CGPoint(x: TerminalView.horizontalSpacing + CGFloat(selection.start.col) * cellWidth,
													 y: originY + CGFloat(selection.start.row) * state.lineHeight - knob),
						end: CGPoint(x: TerminalView.horizontalSpacing + CGFloat(selection.end.col) * cellWidth,
												 y: originY + CGFloat(selection.end.row + 1) * state.lineHeight + knob))
	}

	@objc private func handleSelectionHandlePan(_ gestureRecognizer: UIPanGestureRecognizer) {
		switch gestureRecognizer.state {
		case .changed:
			guard let handle = draggingHandle,
						let selection = state.selection,
						let cell = cell(at: gestureRecognizer.location(in: textView)) else {
				return
			}
			switch handle {
			case .start:
				state.selection = TerminalSelection(anchor: selection.end, head: cell)
			case .end:
				state.selection = TerminalSelection(anchor: selection.start,
																						head: TerminalSelection.Point(row: cell.row, col: cell.col + 1))
			}

		case .ended, .cancelled:
			draggingHandle = nil
			if let selection = state.selection,
				 !selection.isEmpty {
				showEditMenu(at: selectionRect(for: selection))
			}

		default:
			break
		}
	}

	/// The selection’s bounding box in `textView` coordinates, for anchoring the edit menu.
	private func selectionRect(for selection: TerminalSelection) -> CGRect {
		let cellWidth = terminalController.fontMetrics.width
		let start = selection.start
		let end = selection.end
		return CGRect(x: TerminalView.horizontalSpacing + CGFloat(start.col) * cellWidth,
									y: TerminalView.verticalSpacing + CGFloat(start.row) * state.lineHeight + state.contentOriginY,
									width: CGFloat(max(1, end.col - start.col)) * cellWidth,
									height: CGFloat(end.row - start.row + 1) * state.lineHeight)
	}

	/// Turns a location in `textView` into the cell under it, using the geometry `TerminalView`
	/// measured from the laid-out content.
	private func cell(at location: CGPoint) -> TerminalSelection.Point? {
		let cellWidth = terminalController.fontMetrics.width
		guard state.lineHeight > 0,
					cellWidth > 0 else {
			return nil
		}

		let row = Int((location.y - state.contentOriginY - TerminalView.verticalSpacing) / state.lineHeight)
		let col = Int(max(0, location.x - TerminalView.horizontalSpacing) / cellWidth)
		guard row >= 0 && row < state.lines.count else {
			return nil
		}
		return TerminalSelection.Point(row: row, col: col)
	}

	private func clearSelection() {
		state.selection = nil
		selectionBase = nil
		draggingHandle = nil
	}

	private func copySelection() {
		guard let selection = state.selection else {
			return
		}

		let text = terminalController.text(in: selection)
		if !text.isEmpty {
			UIPasteboard.general.string = text
		}
		clearSelection()
	}

	private func showEditMenu(at rect: CGRect) {
		if #available(iOS 16, *) {
			let interaction: UIEditMenuInteraction
			if let existing = editMenuInteraction as? UIEditMenuInteraction {
				interaction = existing
			} else {
				interaction = UIEditMenuInteraction(delegate: self)
				textView.addInteraction(interaction)
				editMenuInteraction = interaction
			}
			interaction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil,
																																sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
		} else {
			keyInput.becomeFirstResponder()
			UIMenuController.shared.showMenu(from: textView, rect: rect)
		}
	}

	// MARK: - Links

	/// Opens whatever is under the given cell — a URL in the browser, an existing file or directory
	/// in Filza. Returns whether anything was opened.
	private func openItem(atRow row: Int, column: Int) -> Bool {
		guard let item = terminalController.contiguousText(atScrollInvariantRow: row, column: column),
					let offset = Self.utf16Offset(ofCharacterAt: item.characterOffset, in: item.text) else {
			return false
		}

		if let detector = Self.linkDetector,
			 let url = Self.firstMatch(of: detector, in: item.text, covering: offset)?.url {
			UIApplication.shared.open(url)
			return true
		}

		if let detector = Self.pathDetector,
			 let match = Self.firstMatch(of: detector, in: item.text, covering: offset) {
			let path = (item.text as NSString).substring(with: match.range)
			if let url = Self.filzaURL(forPath: path) {
				// If nothing is installed to take the filza:// URL, open() fails silently and the tap does
				// nothing. Fall back to cd-ing the terminal into the directory — useful in its own right,
				// and it guarantees the tap always does *something* the user can see.
				UIApplication.shared.open(url, options: [:]) { [weak self] opened in
					if !opened {
						self?.changeDirectory(into: path)
					}
				}
				return true
			}
		}

		return false
	}

	/// Fallback for a tapped path when nothing could open it: cd the shell into it (or its parent, if
	/// it's a file). Types it as if the user had, so it lands in their history and they see it happen.
	private func changeDirectory(into path: String) {
		// Existence is checked against the resolved path (which may live inside the jbroot), but what
		// gets typed is the path as written — the shell is already in that root and would not find the
		// resolved form.
		guard let resolved = Self.resolveExistingPath(path) else {
			return
		}
		var isDirectory: ObjCBool = false
		_ = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory)
		let asWritten = path.hasPrefix("~") ? path : (path as NSString).standardizingPath
		let target = isDirectory.boolValue ? asWritten : (asWritten as NSString).deletingLastPathComponent
		let quoted = "'" + target.replacingOccurrences(of: "'", with: "'\\''") + "'"
		terminalController.write(Array("cd \(quoted)\n".utf8))
	}

	/// `text` has one character per terminal cell, so a column is a character offset — but regexes
	/// work in UTF-16 offsets, which differ as soon as the line contains anything non-ASCII.
	private static func utf16Offset(ofCharacterAt column: Int, in text: String) -> Int? {
		guard column >= 0 && column < text.count else {
			return nil
		}
		let index = text.index(text.startIndex, offsetBy: column)
		return text.utf16.distance(from: text.startIndex, to: index)
	}

	private static func firstMatch(of regex: NSRegularExpression,
																 in text: String,
																 covering utf16Offset: Int) -> NSTextCheckingResult? {
		let range = NSRange(location: 0, length: (text as NSString).length)
		return regex.matches(in: text, range: range)
			.first { NSLocationInRange(utf16Offset, $0.range) }
	}

	/// Turns a path as the *shell* printed it into one this process can actually open.
	///
	/// On roothide the shell runs inside the jailbreak root, so what it prints as `/usr/bin` is really
	/// a directory inside the jbroot — a different one from the `/usr/bin` we see. Checking the bare
	/// path therefore fails for everything the jailbreak provides, and the tap did nothing at all.
	/// Returns nil when neither reading exists, which is also what throws out the false positives the
	/// loose path pattern picks up.
	private static func resolveExistingPath(_ path: String) -> String? {
		let expanded = path.hasPrefix("~") ? NSString(string: path).expandingTildeInPath : path
		if FileManager.default.fileExists(atPath: expanded) {
			return expanded
		}
		if let jbRoot = SubProcess.jbRoot {
			let inJail = (jbRoot as NSString).appendingPathComponent(expanded)
			if FileManager.default.fileExists(atPath: inJail) {
				return inJail
			}
		}
		return nil
	}

	/// Filza opens paths with `filza://view/<path>`.
	private static func filzaURL(forPath path: String) -> URL? {
		guard let resolved = resolveExistingPath(path) else {
			return nil
		}
		let encoded = resolved.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? resolved
		return URL(string: "filza://view\(encoded)")
	}

	// MARK: - Projects

	/// Walks up to the tab host. A session lives inside a split view controller inside
	/// `RootViewController`, which is what owns tabs.
	private var rootViewController: RootViewController? {
		var controller: UIViewController? = parent
		while let current = controller {
			if let root = current as? RootViewController {
				return root
			}
			controller = current.parent
		}
		return nil
	}

	private func openProject(_ project: Project) {
		rootViewController?.openProject(project)
	}

	// MARK: - SSH

	/// Types the connect command and runs it, in this terminal.
	///
	/// Deliberately typed rather than run out of sight: what lands in the scrollback is exactly the
	/// command the user could have typed, which is the thing they can then edit, repeat with ⌃R, or
	/// copy somewhere else.
	private func connectSSH(to host: SSHHost) {
		// \r, not \n: the pty's Enter is carriage return — a newline lands in the buffer without
		// running it. Same byte the initial-command path sends.
		terminalController.write(Array(SSHConfig.connectCommand(for: host).utf8) + EscapeSequences.return)
	}

	/// Adds a host to `~/.ssh/config`.
	///
	/// The fields are the four that decide where a connection goes. Anything else — keys, jump hosts,
	/// forwarding — is edited in the file itself, which stays the source of truth.
	private func addSSHHost() {
		let alertController = UIAlertController(title: .localize("New SSH Host"),
																						message: .localize("Added to ~/.ssh/config. Connecting runs ssh with the name."),
																						preferredStyle: .alert)
		let placeholders = [
			(String.localize("Name (e.g. server)"), UIKeyboardType.default),
			(String.localize("Host name or IP"), .URL),
			(String.localize("User (optional)"), .default),
			(String.localize("Port (optional)"), .numberPad)
		]
		for (placeholder, keyboardType) in placeholders {
			alertController.addTextField { textField in
				textField.placeholder = placeholder
				textField.keyboardType = keyboardType
				textField.autocapitalizationType = .none
				textField.autocorrectionType = .no
			}
		}

		alertController.addAction(UIAlertAction(title: .cancel, style: .cancel))
		alertController.addAction(UIAlertAction(title: .localize("Add"), style: .default) { [weak self, weak alertController] _ in
			let fields = alertController?.textFields?.map { $0.text ?? "" } ?? []
			let name = fields.first?.trimmingCharacters(in: .whitespaces) ?? ""
			guard !name.isEmpty else {
				return
			}
			do {
				try SSHConfig.addHost(name: name,
															hostName: fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : "",
															user: fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) : "",
															port: fields.count > 3 ? fields[3].trimmingCharacters(in: .whitespaces) : "")
			} catch {
				self?.presentError(title: .localize("Couldn’t Add Host"), error: error)
			}
		})
		present(alertController, animated: true)
	}

	/// Types an agent command, and leaves the return to the user.
	///
	/// Nothing is run automatically. Starting an agent, or sending it a prompt, is worth a glance
	/// before committing to — and a slash command is nearly always followed by an argument anyway.
	private func insertAICommand(_ command: AICommand) {
		// Deliberately types and nothing more. Clearing the line first — ^U, the shell's own kill-line
		// — looked right and was not: not every shell binds it, and in one that doesn't it goes to the
		// program as a control byte with results nobody wants. Two personas in a row concatenating is
		// worse than nothing; a stray control byte in someone's session is worse than that.
		terminalController.write(Array(command.command.utf8))
	}

	private func presentError(title: String, error: Error) {
		let alertController = UIAlertController(title: title,
																						message: error.localizedDescription,
																						preferredStyle: .alert)
		alertController.addAction(UIAlertAction(title: .ok, style: .cancel))
		present(alertController, animated: true)
	}

	// MARK: - Image attachments

	/// Offers the photo library, and puts the path of whatever is picked into the terminal.
	///
	/// A CLI can’t be handed a picture, only somewhere to read one from, so the image is copied into
	/// the project and its path is typed in. The `[Image #N]` chip above the keyboard is the readable
	/// name for what was attached — the line itself has to carry the real path.
	private func attachImage() {
		var configuration = PHPickerConfiguration(photoLibrary: .shared())
		configuration.filter = .images
		configuration.selectionLimit = 1

		let picker = PHPickerViewController(configuration: configuration)
		picker.delegate = self
		present(picker, animated: true)
	}

	private func insertAttachment(_ data: Data, fileExtension: String) {
		let projectPath = (parent as? TerminalSplitViewController)?.projectPath
		do {
			let (url, index) = try ImageAttachment.save(data,
																									fileExtension: fileExtension,
																									projectPath: projectPath)
			// Quoted, because the projects folder is user-named and may well contain spaces.
			let quoted = "'" + url.path.replacingOccurrences(of: "'", with: #"'\''"#) + "' "
			terminalController.write(Array(quoted.utf8))
			keyInput.toolbarState.imageAttachments.append(index)
		} catch {
			let alertController = UIAlertController(title: .localize("Couldn’t Attach Image"),
																							message: error.localizedDescription,
																							preferredStyle: .alert)
			alertController.addAction(UIAlertAction(title: .ok, style: .cancel))
			present(alertController, animated: true)
		}
	}


	// MARK: - Lifecycle

	@objc private func sceneDidEnterBackground(_ notification: Notification) {
		if notification.object as? UIWindowScene == view.window?.windowScene {
			terminalController.windowDidEnterBackground()
			// Backgrounding is the last guaranteed callback before jetsam can take us with no warning, so
			// get the scrollback on disk now.
			saveScrollback()
		}
	}

	@objc private func appDidEnterBackground(_ notification: Notification) {
		// Fires on every device when the app backgrounds — the last guaranteed point before jetsam.
		saveScrollback()
	}

	/// Persist this tab's scrollback so it can be replayed after the app is killed.
	/// Whether this terminal's output is worth bringing back.
	///
	/// A project, or a terminal an agent has been run in. A plain shell someone typed `ls` in has no
	/// conversation to resume, and replaying one only means the tab opens onto a wall of yesterday's
	/// output above the prompt.
	private var isWorthRestoring: Bool {
		(parent as? TerminalSplitViewController)?.projectPath != nil || terminalController.hasRunAgent
	}

	private func saveScrollback() {
		guard let scrollbackID = scrollbackID else {
			return
		}
		guard isWorthRestoring else {
			// Dropped rather than left alone: a tab that used to qualify and no longer does shouldn't
			// keep restoring the output from back when it did.
			ScrollbackStore.shared.discard(id: scrollbackID)
			return
		}
		ScrollbackStore.shared.save(terminalController.snapshotScrollback(), id: scrollbackID)
	}

	@objc private func sceneWillEnterForeground(_ notification: Notification) {
		if notification.object as? UIWindowScene == view.window?.windowScene {
			terminalController.windowWillEnterForeground()
		}
	}

	@objc private func preferencesUpdated() {
		state.fontMetrics = terminalController.fontMetrics
		state.colorMap = terminalController.colorMap
	}

}

extension TerminalSessionViewController: TerminalControllerDelegate {

	func refresh(lines: [AnyView]) {
		state.lines = lines
		state.revision &+= 1
	}

	func activateBell() {
		let now = Date()
		guard now.timeIntervalSince(lastBellAt) >= Self.bellCoalescingInterval else {
			return
		}
		lastBellAt = now

		if Preferences.shared.bellHUD {
			hudState.isVisible = true
		}

		HapticController.playBell()
	}

	func titleDidChange(_ title: String?, isDirty: Bool, hasBell: Bool) {
		let newTitle = title ?? .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")
		paneTitle = newTitle
		updatePaneHeader()
		delegate?.terminal(viewController: self,
											 titleDidChange: newTitle,
											 isDirty: isDirty,
											 hasBell: hasBell)
	}

	func currentFileDidChange(_ url: URL?, inWorkingDirectory workingDirectoryURL: URL?) {
		#if targetEnvironment(macCatalyst)
		if let windowScene = view.window?.windowScene {
			windowScene.titlebar?.representedURL = url
		}
		#endif
	}

	func saveFile(url: URL) {
		let viewController = UIDocumentPickerViewController(forExporting: [url], asCopy: false)
		viewController.delegate = self
		present(viewController, animated: true, completion: nil)
	}

	func fileUploadRequested() {
		isPickingFileForUpload = true

		let viewController = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .directory])
		viewController.delegate = self
		present(viewController, animated: true, completion: nil)
	}

	@objc func activatePasswordManager() {
		keyInput.activatePasswordManager()
	}

	@objc func close() {
		if let splitViewController = parent as? TerminalSplitViewController {
			splitViewController.remove(viewController: self)
		}
	}

	func didReceiveError(error: Error) {
		if !hasAppeared {
			failureError = error
			return
		}
		failureError = nil

		let alertController = UIAlertController(title: .localize("TERMINAL_LAUNCH_FAILED_TITLE", comment: "Alert title displayed when a terminal could not be launched."),
																						message: .localize("TERMINAL_LAUNCH_FAILED_BODY", comment: "Alert body displayed when a terminal could not be launched."),
																						preferredStyle: .alert)
		alertController.addAction(UIAlertAction(title: .ok, style: .cancel, handler: nil))
		present(alertController, animated: true, completion: nil)
	}

}

extension TerminalSessionViewController: UIGestureRecognizerDelegate {

	func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
		// This allows the tap-to-activate-keyboard gesture to work without conflicting with UIKit’s
		// internal text view/scroll view gestures… as much as we can avoid conflicting, at least.
		return gestureRecognizer == textViewTapGestureRecognizer
			&& (!(otherGestureRecognizer is UITapGestureRecognizer) || keyInput.isFirstResponder)
	}

	func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
		guard gestureRecognizer == selectionHandlePanGestureRecognizer else {
			return true
		}
		// Claim the touch only when it starts on a handle; every other pan stays with the scroll view.
		guard let selection = state.selection,
					!selection.isEmpty,
					state.lineHeight > 0 else {
			return false
		}
		let location = gestureRecognizer.location(in: textView)
		let centres = handleCentres(for: selection)
		if hypot(location.x - centres.start.x, location.y - centres.start.y) <= Self.handleGrabRadius {
			draggingHandle = .start
			return true
		}
		if hypot(location.x - centres.end.x, location.y - centres.end.y) <= Self.handleGrabRadius {
			draggingHandle = .end
			return true
		}
		return false
	}
}

extension TerminalSessionViewController: PHPickerViewControllerDelegate {

	func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
		picker.dismiss(animated: true)

		guard let provider = results.first?.itemProvider else {
			return
		}

		// Decode and re-encode rather than asking the provider for PNG directly: a photo out of the
		// library is HEIC or JPEG, and the provider refuses to convert it (“Cannot load representation
		// of type public.png”). PNG because it’s the format every CLI that reads images accepts.
		guard provider.canLoadObject(ofClass: UIImage.self) else {
			return
		}

		provider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
			DispatchQueue.main.async {
				guard let self = self else {
					return
				}
				guard let image = object as? UIImage,
							let attachment = Self.attachmentData(for: image) else {
					Self.logger.warning("Couldn’t load image: \(String(describing: error))")
					return
				}
				self.insertAttachment(attachment.data, fileExtension: attachment.fileExtension)
			}
		}
	}

	/// Long edge to fit an attachment into.
	///
	/// Vision models scale down past roughly this anyway, so a full-resolution phone photo would only
	/// drop a 20 MB file into the user’s project folder and make the upload slower.
	private static let maxAttachmentEdge: CGFloat = 1568

	private static func attachmentData(for image: UIImage) -> (data: Data, fileExtension: String)? {
		let longEdge = max(image.size.width, image.size.height)
		guard longEdge > maxAttachmentEdge else {
			// Small enough to keep as-is, so keep it lossless — a screenshot of code or a diagram is
			// exactly the kind of image where JPEG artifacts cost the model detail.
			return image.pngData().map { ($0, "png") }
		}

		let scale = maxAttachmentEdge / longEdge
		let size = CGSize(width: (image.size.width * scale).rounded(),
											height: (image.size.height * scale).rounded())
		// Renderers default to the screen’s scale, which on a 3x phone would render 3× the size we
		// just worked out and undo the whole point of resizing.
		let format = UIGraphicsImageRendererFormat.default()
		format.scale = 1
		let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
			image.draw(in: CGRect(origin: .zero, size: size))
		}
		// JPEG once we’re resampling anyway: a photo re-encoded to PNG at this size is ~10 MB, which is
		// a lot to leave in someone’s project folder and to push up to a model.
		return resized.jpegData(compressionQuality: 0.9).map { ($0, "jpg") }
	}

}

extension TerminalSessionViewController: UIDocumentPickerDelegate {

	func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
		guard isPickingFileForUpload,
					let url = urls.first else {
			return
		}
		terminalController.uploadFile(url: url)
		isPickingFileForUpload = false
	}

	func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
		if isPickingFileForUpload {
			isPickingFileForUpload = false
			terminalController.cancelUploadRequest()
		} else {
			// The system will clean up the temp directory for us eventually anyway, but still delete the
			// downloads temp directory now so the file doesn’t linger around till then.
			terminalController.deleteDownloadCache()
		}
	}

}


@available(iOS 16, *)
extension TerminalSessionViewController: UIEditMenuInteractionDelegate {

	func editMenuInteraction(_ interaction: UIEditMenuInteraction,
													 menuFor configuration: UIEditMenuConfiguration,
													 suggestedActions: [UIMenuElement]) -> UIMenu? {
		UIMenu(children: [
			UIAction(title: .localize("Copy"),
							 image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
				self?.copySelection()
			}
		])
	}

}
