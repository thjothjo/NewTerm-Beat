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
	private var sideBarView: KeyboardSideBarView?
	private var sideBarLeadingConstraint: NSLayoutConstraint?

	private var state = TerminalState()

	private var hudState = HUDViewState()
	private var hudView: UIHostingView<AnyView>!

	private var hasAppeared = false
	private var hasStarted = false
	private var failureError: Error?

	private var lastAutomaticScrollOffset = CGPoint.zero
	private var invertScrollToTop = false

	private var isPickingFileForUpload = false

	/// `UIEditMenuInteraction` on iOS 16+, held as AnyObject because stored properties can’t be
	/// annotated with availability.
	private var editMenuInteraction: AnyObject?

	private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
	/// Absolute (`/…`) and home-relative (`~/…`) paths. Deliberately loose — false positives are
	/// filtered out by checking the path actually exists before offering to open it.
	private static let pathDetector = try? NSRegularExpression(pattern: #"(?:~/|/)[^\s"'`<>|]+"#)

	private static let logger = Logger(subsystem: "ws.hbang.Terminal", category: "TerminalSession")

	/// Stable id used to persist and restore this tab's scrollback across app restarts. Nil for tabs
	/// that shouldn't be remembered.
	private let scrollbackID: String?
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

		NotificationCenter.default.addObserver(self, selector: #selector(self.preferencesUpdated), name: Preferences.didChangeNotification, object: nil)

		updateSideBar()
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)

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

	override func viewSafeAreaInsetsDidChange() {
		super.viewSafeAreaInsetsDidChange()
		updateScreenSize()
	}

	override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
		super.traitCollectionDidChange(previousTraitCollection)
		updateSideBar()
		updateScreenSize()
	}

	/// Shows the landscape key strip on the leading edge, and gives it its own space rather than
	/// floating it over the text — the terminal reflows to the narrower width instead of having a
	/// column hidden behind it.
	/// Width the strip claims from the terminal: the strip itself plus a little breathing room.
	private static let sideBarInset = KeyboardSideBarView.width + 8

	private func updateSideBar() {
		let shouldShow = TerminalKeyInput.usesSideBar(for: traitCollection)

		// Hosted on the tab container, not on our own view.
		//
		// Our view is inset from the screen by the split container, which pins its content to the safe
		// area — in landscape that's 62pt in from each edge. Hugging the physical edge from here means
		// a negative leading constant, which puts the strip *entirely* outside our bounds: UIKit still
		// draws it, but hit testing is clipped to the superview's bounds, so it never receives a single
		// touch. That's why it looked fine and did nothing. The container's view spans the whole
		// screen, so from there the strip can sit against the edge and still be touchable.
		let host: UIView = parent?.viewIfLoaded ?? view

		if shouldShow && sideBarView == nil {
			let sideBar = KeyboardSideBarView(delegate: keyInput, state: keyInput.toolbarState)
			host.addSubview(sideBar)
			let leading = sideBar.leadingAnchor.constraint(equalTo: host.leadingAnchor)
			sideBarLeadingConstraint = leading
			// Top and bottom are pinned rather than centred with inequalities: those left the height up
			// to the hosting view's intrinsic size, and without that the strip has no defined height at
			// all — it renders wrong and won't scroll.
			NSLayoutConstraint.activate([
				leading,
				sideBar.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 4),
				sideBar.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -4)
			])
			sideBarView = sideBar
		} else if !shouldShow,
							let sideBar = sideBarView {
			sideBar.removeFromSuperview()
			sideBarView = nil
			sideBarLeadingConstraint = nil
		}

		// Inside the safe area, whichever side the Dynamic Island happens to be on. Insetting only on
		// the island side and hugging the physical edge on the other left the strip sitting entirely
		// outside the safe area there — measured at x=0..53 against a 62pt inset — where the display's
		// curve clips the keys. iOS reporting the same inset on both sides in landscape isn't the
		// unhelpful quirk the old comment took it for: it is the margin that clears the island on one
		// side and the corner radius on the other.
		let leadingInset = view.window?.safeAreaInsets.left ?? 0
		sideBarLeadingConstraint?.constant = leadingInset

		// Whatever the strip still covers of the text area, the terminal gives up. Our view already
		// starts inside the screen by the safe-area inset, so when the strip is flush with the edge
		// there's usually no overlap left at all.
		let overhang = view.window?.safeAreaInsets.left ?? 0
		let offset = shouldShow ? max(0, leadingInset + Self.sideBarInset - overhang) : 0
		let frame = CGRect(x: offset,
											 y: 0,
											 width: max(0, keyInput.bounds.width - offset),
											 height: keyInput.bounds.height)
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

		if !keyInput.isFirstResponder {
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
			if let range = terminalController.wordRange(atScrollInvariantRow: cell.row, column: cell.col) {
				state.selection = TerminalSelection(row: cell.row, columns: range)
			} else {
				state.selection = TerminalSelection(anchor: cell, head: cell)
			}

		case .changed:
			if let selection = state.selection {
				state.selection = TerminalSelection(anchor: selection.anchor, head: cell)
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
			 let match = Self.firstMatch(of: detector, in: item.text, covering: offset),
			 let url = Self.filzaURL(forPath: (item.text as NSString).substring(with: match.range)) {
			UIApplication.shared.open(url)
			return true
		}

		return false
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

	/// Filza opens paths with `filza://view/<path>`. Only paths that exist are offered, which also
	/// throws out the false positives the loose path pattern picks up.
	private static func filzaURL(forPath path: String) -> URL? {
		let resolved = path.hasPrefix("~") ? NSString(string: path).expandingTildeInPath : path
		guard FileManager.default.fileExists(atPath: resolved) else {
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
	private func saveScrollback() {
		guard let scrollbackID = scrollbackID else {
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
		if Preferences.shared.bellHUD {
			hudState.isVisible = true
		}

		HapticController.playBell()
	}

	func titleDidChange(_ title: String?, isDirty: Bool, hasBell: Bool) {
		let newTitle = title ?? .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")
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
