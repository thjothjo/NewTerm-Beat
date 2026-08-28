//
//  RootViewController.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import SwiftUI
import NewTermCommon

class RootViewController: UIViewController {

	static let settingsViewDoneNotification = Notification.Name(rawValue: "RootViewControllerSettingsViewDoneNotification")

	var initialCommand: String?

	private var terminals: [BaseTerminalSplitViewControllerChild] = []
	private var selectedTabIndex = 0

	private var tabToolbar: TabToolbarViewController?

	/// Snapshot handed over by the scene delegate, consumed once in viewDidLoad.
	private var pendingRestore: SessionState?
	/// Suppresses saving while restoring — otherwise the half-built state gets written back, and a
	/// crash mid-restore would truncate the snapshot to whatever had been rebuilt so far.
	private var isRestoring = false

	convenience init(restoring state: SessionState?) {
		self.init(nibName: nil, bundle: nil)
		pendingRestore = state
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		navigationController!.isNavigationBarHidden = true

		#if !targetEnvironment(macCatalyst)
		tabToolbar = TabToolbarViewController()
		tabToolbar!.view.autoresizingMask = [.flexibleWidth]
		tabToolbar!.delegate = self
		tabToolbar!.dataSource = self
		addChild(tabToolbar!)
		view.addSubview(tabToolbar!.view)

		// Tapping anywhere below the tab bar leaves tab edit mode — that’s the whole dismiss gesture,
		// there’s no Done button. It doesn’t consume the touch, so the terminal still gets it.
		let endEditingRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.endTabEditing))
		endEditingRecognizer.cancelsTouchesInView = false
		endEditingRecognizer.delegate = self
		view.addGestureRecognizer(endEditingRecognizer)
		#endif

		if let state = pendingRestore {
			pendingRestore = nil
			restore(state)
		} else {
			addTerminal()
		}

		addKeyCommand(UIKeyCommand(title: .localize("SETTINGS", comment: "Title of Settings page."),
															 image: UIImage(systemName: "gear"),
															 action: #selector(self.openSettings),
															 input: ",",
															 modifierFlags: .command))

		addKeyCommand(UIKeyCommand(title: .localize("NEW_TAB", comment: "VoiceOver label for the new tab button."),
															 action: #selector(self.newTab),
															 input: "t",
															 modifierFlags: .command))
		addKeyCommand(UIKeyCommand(title: .localize("CLOSE_TAB", comment: "VoiceOver label for the close tab button."),
															 action: #selector(self.removeCurrentTerminal),
															 input: "w",
															 modifierFlags: .command))

		#if !targetEnvironment(macCatalyst)
		addKeyCommand(UIKeyCommand(title: .localize("SHOW_PREVIOUS_TAB"),
															 action: #selector(self.selectPreviousTab),
															 input: "{",
															 modifierFlags: .command))
		addKeyCommand(UIKeyCommand(title: .localize("SHOW_NEXT_TAB"),
															 action: #selector(self.selectNextTab),
															 input: "}",
															 modifierFlags: .command))
		#endif

		let digits = (Array(1...9) + [0]).map { "\($0)" }
		for digit in digits {
			addKeyCommand(UIKeyCommand(action: #selector(self.selectTabFromKeyCommand),
																 input: digit,
																 modifierFlags: .command))
		}

		if UIApplication.shared.supportsMultipleScenes {
			addKeyCommand(UIKeyCommand(title: .localize("NEW_WINDOW", comment: "VoiceOver label for the new window button."),
																 action: #selector(self.addWindow),
																 input: "n",
																 modifierFlags: .command))
			addKeyCommand(UIKeyCommand(title: .localize("CLOSE_WINDOW", comment: "VoiceOver label for the close window button."),
																 action: #selector(self.closeCurrentWindow),
																 input: "w",
																 modifierFlags: [.command, .shift]))
		}

		addKeyCommand(UIKeyCommand(title: .localize("SPLIT_HORIZONTALLY"),
															 action: #selector(self.splitHorizontally),
															 input: "d",
															 modifierFlags: [.command, .shift]))
		addKeyCommand(UIKeyCommand(title: .localize("SPLIT_VERTICALLY"),
															 action: #selector(self.splitVertically),
															 input: "d",
															 modifierFlags: .command))


		NotificationCenter.default.addObserver(self, selector: #selector(self.preferencesUpdated), name: Preferences.didChangeNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(self.dismissSettings), name: Self.settingsViewDoneNotification, object: nil)
		// Jetsam gives no warning, so the snapshot has to be on disk before we lose the foreground.
		NotificationCenter.default.addObserver(self, selector: #selector(self.saveSessionImmediately), name: UIApplication.willResignActiveNotification, object: nil)

		preferencesUpdated()
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		// Onscreen without crashing, so whatever we restored is good — this write clears the
		// restore-attempt counter that load() bumped.
		saveSessionImmediately()
	}

	override func viewWillLayoutSubviews() {
		super.viewWillLayoutSubviews()

		// TODO: Cleanup
		#if !targetEnvironment(macCatalyst)
		let topBarHeight = TabToolbarView.preferredHeight(for: traitCollection.horizontalSizeClass)
		tabToolbar?.view.frame = CGRect(x: 0, y: 0, width: view.frame.size.width, height: view.safeAreaInsets.top + topBarHeight)

		for viewController in terminals {
			viewController.additionalSafeAreaInsets.top = topBarHeight
		}
		#endif
	}

	// MARK: - Session persistence

	private var sessionIdentifier: String? {
		view.window?.windowScene?.session.persistentIdentifier
	}

	private var sessionState: SessionState {
		SessionState(tabs: terminals.indices.map { index in
			SessionTabState(id: terminals[index].tabID,
											projectPath: terminals[index].projectPath,
											title: terminalName(at: index))
		},
								 selectedIndex: selectedTabIndex)
	}

	private func setNeedsSaveSession() {
		guard !isRestoring,
					let identifier = sessionIdentifier else {
			return
		}
		SessionStore.shared.setNeedsSave(sessionState, identifier: identifier)
	}

	@objc private func saveSessionImmediately() {
		guard !isRestoring,
					let identifier = sessionIdentifier else {
			return
		}
		SessionStore.shared.saveImmediately(sessionState, identifier: identifier)
	}

	private func restore(_ state: SessionState) {
		isRestoring = true

		for tab in state.tabs {
			// A project whose folder has gone — deleted, or moved to .Trash — still gets its tab back,
			// just as a plain shell. Dropping the tab would read as the restore having failed.
			if let path = tab.projectPath,
				 FileManager.default.fileExists(atPath: path) {
				initialCommand = ProjectManager.openCommand(forPath: path)
				addTerminal(projectPath: path, tabID: tab.id)
			} else {
				addTerminal(projectPath: nil, tabID: tab.id)
			}
		}

		if terminals.isEmpty {
			addTerminal()
		} else {
			selectTerminal(at: min(max(0, state.selectedIndex), terminals.count - 1))
		}

		isRestoring = false
	}

	// MARK: - Preferences

	@objc private func preferencesUpdated() {
		let preferences = Preferences.shared
		view.backgroundColor = preferences.colorMap.background
	}

	// MARK: - Tab management

	@objc func newTab() {
		#if targetEnvironment(macCatalyst)
		if let sceneDelegate = view.window?.windowScene?.delegate as? TerminalSceneDelegate {
			sceneDelegate.createWindow(asTab: true)
		}
		#else
		addTerminal()
		#endif
	}

	func addTerminal() {
		addTerminal(projectPath: nil)
	}

	func addTerminal(projectPath: String?, tabID: String? = nil) {
		let index = min(selectedTabIndex + 1, terminals.count)
		addTerminal(at: index, initialCommand: initialCommand, projectPath: projectPath, tabID: tabID)
		selectTerminal(at: index)
		initialCommand = nil
		setNeedsSaveSession()
	}

	private func addTerminal(at index: Int, axis: NSLayoutConstraint.Axis? = nil, initialCommand: String? = nil, projectPath: String? = nil, tabID: String? = nil) {
		// Splitting nests: the tab's existing content becomes one half of a new split. Left unbounded
		// that keeps going, and on a phone a third pane is a few characters wide and useful to nobody.
		if axis != nil && isTerminalSplit(at: index) {
			return
		}

		let splitViewController = TerminalSplitViewController()
		splitViewController.projectPath = projectPath
		if let tabID = tabID {
			splitViewController.tabID = tabID
		}
		splitViewController.view.autoresizingMask = [ .flexibleWidth, .flexibleHeight ]
		splitViewController.view.frame = view.bounds
		splitViewController.delegate = self

		// The pane that fills a fresh tab carries the tab's scrollback; the second pane of a split is a
		// new terminal with no history to restore.
		let scrollbackID = axis == nil ? splitViewController.tabID : nil
		let newTerminal = TerminalSessionViewController(initialDirectory: projectPath,
																									 initialCommand: initialCommand,
																									 scrollbackID: scrollbackID)

		addChild(splitViewController)
		splitViewController.willMove(toParent: self)
		if let tabToolbar = tabToolbar {
			view.insertSubview(splitViewController.view, belowSubview: tabToolbar.view)
		} else {
			view.addSubview(splitViewController.view)
		}
		splitViewController.didMove(toParent: self)

		if index == terminals.count {
			splitViewController.viewControllers = [newTerminal]
			terminals.append(splitViewController)
			tabToolbar?.didAddTab(at: index)
		} else if let axis = axis {
			// Splitting takes the terminal that’s already in this tab and makes it one half of the new
			// split, so the tab is replaced by the split that now owns it. The tab count is unchanged.
			let firstViewController = terminals[index]
			let secondViewController = newTerminal
			splitViewController.axis = axis
			splitViewController.viewControllers = [firstViewController, secondViewController]
			terminals[index] = splitViewController
			tabToolbar?.tabDidUpdate(at: index)
		} else {
			// A new tab in the middle of the strip goes *between* its neighbours. Replacing here would
			// drop whichever tab already sat at this index, along with whatever was running in it.
			splitViewController.viewControllers = [newTerminal]
			terminals.insert(splitViewController, at: index)
			tabToolbar?.didAddTab(at: index)
		}
	}

	func removeTerminal(viewController: BaseTerminalSplitViewControllerChild) {
		guard let index = terminals.firstIndex(of: viewController) else {
			NSLog("asked to remove terminal that doesn’t exist? %@", viewController)
			return
		}

		// Closing a tab is deliberate, so its saved scrollback shouldn't linger to be replayed into some
		// unrelated future tab — drop it with the tab.
		ScrollbackStore.shared.discard(id: viewController.tabID)

		viewController.removeFromParent()
		viewController.view.removeFromSuperview()

		terminals.remove(at: index)
		tabToolbar?.didRemoveTab(at: index)

		// If this was the last tab, close the window (or make a new tab if not supported). Otherwise
		// select the closest tab we have available.
		if terminals.count == 0 {
			if UIApplication.shared.supportsMultipleScenes {
				closeCurrentWindow()
			} else {
				addTerminal()
			}
		} else {
			selectTerminal(at: index >= terminals.count ? index - 1 : index)
		}

		// Immediate, not debounced: a tab the user closed must never come back because we crashed
		// inside the debounce window.
		saveSessionImmediately()
	}

	func removeTerminal(at index: Int) {
		removeTerminal(viewController: terminals[index])
	}

	@IBAction func removeCurrentTerminal() {
		removeTerminal(at: selectedTabIndex)
	}

	@IBAction func removeAllTerminals() {
		for terminalViewController in terminals {
			terminalViewController.removeFromParent()
			terminalViewController.view.removeFromSuperview()
		}

		terminals.removeAll()
		addTerminal()
	}

	func selectTerminal(at index: Int) {
		let oldSelectedTabIndex = selectedTabIndex < terminals.count ? selectedTabIndex : nil

		// If the previous index is now out of bounds, just use nil as our previous. The tab and view
		// controller were removed so we don’t need to do anything
		let previousViewController = oldSelectedTabIndex == nil ? nil : terminals[oldSelectedTabIndex!]
		let newViewController = terminals[index]

		selectedTabIndex = index
		tabToolbar?.didSelectTab(at: index)
		handleTitleChange(at: index)

		// Call the appropriate view controller lifecycle methods on the previous and new view controllers
		previousViewController?.beginAppearanceTransition(false, animated: false)
		previousViewController?.view.isHidden = true
		previousViewController?.endAppearanceTransition()

		newViewController.beginAppearanceTransition(true, animated: false)
		newViewController.view.isHidden = false
		newViewController.endAppearanceTransition()

		setNeedsSaveSession()
	}

	private func handleTitleChange(at index: Int) {
		if selectedTabIndex == index {
			view.window?.windowScene?.title = terminalName(at: index)

			if #available(iOS 15, *),
				 let size = terminals[index].screenSize {
				view.window?.windowScene?.subtitle = "\(size.cols)×\(size.rows)"
			}
		}
	}

	@objc private func selectPreviousTab() {
		if selectedTabIndex == 0 {
			selectTerminal(at: terminals.count - 1)
		} else {
			selectTerminal(at: selectedTabIndex - 1)
		}
	}

	@objc private func selectNextTab() {
		if selectedTabIndex == terminals.count - 1 {
			selectTerminal(at: 0)
		} else {
			selectTerminal(at: selectedTabIndex + 1)
		}
	}

	@objc private func selectTabFromKeyCommand(_ keyCommand: UIKeyCommand) {
		guard var digit = Int(keyCommand.input ?? ""),
					digit >= 0 && digit <= 9 else {
			return
		}

		if digit == 0 {
			digit = 10
		}
		digit -= 1

		if terminals.count > digit {
			selectTerminal(at: digit)
		}
	}

	// MARK: - Window management

	@objc func addWindow() {
		if let sceneDelegate = view.window?.windowScene?.delegate as? TerminalSceneDelegate {
			sceneDelegate.createWindow(asTab: false)
		}
	}

	@objc func closeCurrentWindow() {
		if terminals.count == 0 {
			destructScene()
			return
		}

		let title: String?
		let action: String
		if isBigDevice {
			title = String.localizedStringWithFormat(.localize("CLOSE_WINDOW_TITLE"), terminals.count)
			action = .close
		} else {
			title = nil
			action = String.localizedStringWithFormat(.localize("CLOSE_WINDOW_ACTION"), terminals.count)
		}

		let alertController = UIAlertController(title: title, message: nil, preferredStyle: isBigDevice ? .alert : .actionSheet)
		alertController.addAction(UIAlertAction(title: action, style: isBigDevice ? .default : .destructive, handler: { _ in
			self.destructScene()
		}))
		alertController.addAction(UIAlertAction(title: .cancel, style: .cancel, handler: nil))
		present(alertController, animated: true, completion: nil)
	}

	private func destructScene() {
		if UIApplication.shared.supportsMultipleScenes {
			// TODO: Probably need to directly use NSWindow APIs for this on Catalyst.
			// https://developer.apple.com/forums/thread/127382
			UIApplication.shared.requestSceneSessionDestruction(view.window!.windowScene!.session, options: nil, errorHandler: nil)
		} else {
			removeAllTerminals()
		}
	}

	// MARK: - Split views

	@objc func splitHorizontally() {
		addTerminal(at: selectedTabIndex, axis: .vertical)
	}

	@objc func splitVertically() {
		addTerminal(at: selectedTabIndex, axis: .horizontal)
	}

	/// Whether the tab at `index` is showing two terminals rather than one.
	func isTerminalSplit(at index: Int) -> Bool {
		guard terminals.indices.contains(index),
					let split = terminals[index] as? TerminalSplitViewController else {
			return false
		}
		return split.viewControllers.count > 1
	}

	/// The toolbar's split button: one tap splits, the next puts it back.
	///
	/// Which way it splits follows the shape of the screen — side by side where there's width to
	/// share, stacked where there isn't — rather than being two separate commands the way the
	/// keyboard shortcuts are. There's only ever one thing the button can do.
	@objc func toggleSplit() {
		if isTerminalSplit(at: selectedTabIndex) {
			closeSplit()
		} else if view.bounds.width > view.bounds.height {
			splitVertically()
		} else {
			splitHorizontally()
		}
	}

	/// Drops the pane the user *isn't* in, so what they were looking at is what fills the tab.
	private func closeSplit() {
		guard terminals.indices.contains(selectedTabIndex),
					let split = terminals[selectedTabIndex] as? TerminalSplitViewController,
					split.viewControllers.count > 1 else {
			return
		}
		let keeping = split.selectedViewController
		for viewController in split.viewControllers where viewController != keeping {
			split.remove(viewController: viewController)
		}
		tabToolbar?.tabDidUpdate(at: selectedTabIndex)
	}

}

extension RootViewController: TerminalSplitViewControllerDelegate {

	func terminal(viewController: BaseTerminalSplitViewControllerChild, titleDidChange title: String, isDirty: Bool, hasBell: Bool) {
		guard let index = terminals.firstIndex(of: viewController) else {
			return
		}

		handleTitleChange(at: index)
		tabToolbar?.tabDidUpdate(at: index)
	}

	func terminal(viewController: BaseTerminalSplitViewControllerChild, screenSizeDidChange screenSize: ScreenSize) {
		guard let index = terminals.firstIndex(of: viewController) else {
			return
		}

		handleTitleChange(at: index)
		tabToolbar?.tabDidUpdate(at: index)
	}

	func terminalDidBecomeActive(viewController: BaseTerminalSplitViewControllerChild) {
		guard let index = terminals.firstIndex(of: viewController) else {
			return
		}

		handleTitleChange(at: index)
		tabToolbar?.tabDidUpdate(at: index)
	}

}

extension RootViewController: TabToolbarDataSource {

	func numberOfTerminals() -> Int {
		return terminals.count
	}

	func selectedTerminalIndex() -> Int {
		return selectedTabIndex
	}

	func terminalName(at index: Int) -> String {
		let title = terminals[index].title
		if let title = title, !title.isEmpty {
			return title
		}
		// A project tab is named after its folder. Every tab reading “Terminal” tells you nothing about
		// which AI task is running where, and the folder name is the one label that’s already
		// meaningful and already known before anything has run.
		if let projectPath = terminals[index].projectPath {
			return URL(fileURLWithPath: projectPath).lastPathComponent
		}
		return .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")
	}

}

extension RootViewController {

	/// One terminal per project: if the project already has a tab, go back to it rather than piling
	/// up duplicate sessions on the same directory.
	/// Leaves tab edit mode. Called when a tap lands somewhere that isn’t a tab.
	@objc func endTabEditing() {
		tabToolbar?.endEditing()
	}

	func openProject(_ project: Project) {
		if let index = terminals.firstIndex(where: { $0.projectPath == project.url.path }) {
			selectTerminal(at: index)
			return
		}

		initialCommand = ProjectManager.openCommand(for: project)
		addTerminal(projectPath: project.url.path)
	}

	func trashProject(_ project: Project) {
		let alertController = UIAlertController(title: String(format: .localize("Move “%@” to Trash?"), project.name),
																						message: .localize("The folder and everything in it moves to .Trash inside your projects folder. You can put it back with a file manager."),
																						preferredStyle: .alert)
		alertController.addAction(UIAlertAction(title: .cancel, style: .cancel, handler: nil))
		alertController.addAction(UIAlertAction(title: .localize("Move to Trash"), style: .destructive) { [weak self] _ in
			do {
				try ProjectManager.trashProject(project)
			} catch {
				self?.presentProjectError(title: .localize("Couldn’t Move Project"),
																	message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
			}
		})
		present(alertController, animated: true)
	}

	private func presentProjectError(title: String, message: String) {
		let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
		alertController.addAction(UIAlertAction(title: .ok, style: .cancel, handler: nil))
		present(alertController, animated: true)
	}

}

extension RootViewController: TabToolbarDelegate {

	func createProject() {
		let alertController = UIAlertController(title: .localize("New Project"),
																						message: String(format: .localize("Creates a folder in %@."),
																														ProjectManager.rootURL.path),
																						preferredStyle: .alert)
		alertController.addTextField { textField in
			textField.placeholder = .localize("Name")
			textField.autocapitalizationType = .none
			textField.autocorrectionType = .no
			textField.clearButtonMode = .whileEditing
		}
		alertController.addAction(UIAlertAction(title: .cancel, style: .cancel, handler: nil))
		alertController.addAction(UIAlertAction(title: .localize("Create"), style: .default) { [weak self] _ in
			let name = alertController.textFields?.first?.text?
				.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

			// The name becomes a path component, so anything that could climb out of the projects root
			// or hide the result is rejected rather than quietly rewritten into something else.
			guard !name.isEmpty,
						!name.hasPrefix("."),
						!name.contains("/") else {
				self?.presentProjectError(title: .localize("Couldn’t Create Project"),
																	message: .localize("Project names can’t be empty, start with a dot, or contain a slash."))
				return
			}

			do {
				let project = try ProjectManager.createProject(named: name)
				self?.openProject(project)
			} catch {
				self?.presentProjectError(title: .localize("Couldn’t Create Project"),
																	message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
			}
		})
		present(alertController, animated: true)
	}


	@objc func openSettings() {
		if UIApplication.shared.supportsMultipleScenes {
			UIApplication.shared.activateScene(userActivity: .settingsScene,
																				 requestedByScene: view.window?.windowScene,
																				 withProminentPresentation: true)
		} else {
			if presentedViewController == nil {
				let viewController = UIHostingController(rootView: SettingsView())
				viewController.modalPresentationStyle = .formSheet
				navigationController?.present(viewController, animated: true, completion: nil)
			}
		}
	}

	@objc private func dismissSettings() {
		presentedViewController?.dismiss(animated: true, completion: nil)
	}

	func openPasswordManager() {
		UIApplication.shared.sendAction(#selector(TerminalSessionViewController.activatePasswordManager), to: nil, from: self, for: nil)
	}

}

extension RootViewController: UIGestureRecognizerDelegate {

	func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
		// Only the dismiss-edit-mode tap goes through here, and only below the tab bar: a tap on the
		// bar itself is either a tab or a delete badge, and both have their own meaning in edit mode.
		guard let tabToolbar = tabToolbar else {
			return true
		}
		return gestureRecognizer.location(in: view).y > tabToolbar.view.frame.maxY
	}

	func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
												 shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
		true
	}

}
