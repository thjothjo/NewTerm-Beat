//
//  TerminalKeyInput.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import SwiftUI
import Combine
import NewTermCommon
import SwiftUIX

extension ToolbarKey {
	var keySequence: [UTF8Char] {
		switch self {
		case .escape:   return EscapeSequences.meta
		case .tab:      return EscapeSequences.tab
		case .up:       return EscapeSequences.up
		case .down:     return EscapeSequences.down
		case .left:     return EscapeSequences.left
		case .right:    return EscapeSequences.right
		// Backspace, not the forward-delete escape. `\e[3~` is the correct key for a terminal, but it
		// depends on the program having bound it: shells and TUIs that haven't swallow the `\e[3` and
		// insert the trailing `~`, and beep because there was nothing to delete. On a phone the key
		// labelled Delete has one job, and backspace is the byte every program understands.
		case .delete:   return EscapeSequences.backspace
		case .fnKey(let index): return EscapeSequences.fn[index - 1]
		case .shiftTab: return EscapeSequences.backTab
		case .fixedSpace, .variableSpace, .arrows,
				 .control, .more, .fnKeys, .projects, .image, .ssh, .ai:
			return []
		}
	}

	var appKeySequence: [UTF8Char]? {
		switch self {
		case .up:       return EscapeSequences.upApp
		case .down:     return EscapeSequences.downApp
		case .left:     return EscapeSequences.leftApp
		case .right:    return EscapeSequences.rightApp
		default:        return nil
		}
	}

	func keySequence(applicationCursor: Bool = false) -> [UTF8Char] {
		(applicationCursor ? appKeySequence : nil) ?? keySequence
	}
}

class TerminalKeyInput: TextInputBase {

	weak var terminalInputDelegate: TerminalInputProtocol?
	weak var textView: UIView! {
		didSet {
			textView.frame = bounds
			textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
			insertSubview(textView, at: 0)
		}
	}

	private var toolbar: KeyboardToolbarInputView!
	private var passwordInputView: TerminalPasswordInputView?

	private var previousFloatingCursorPoint: CGPoint? = nil
	private var repeatTimer: Timer?

	/// Set by the view controller so the system Copy command can reach the terminal’s selection. This
	/// view is the first responder, but the selection itself lives with the terminal.
	var copyHandler: (() -> Void)?
	var canCopy: (() -> Bool)?

	/// Set by the view controller — opening a project needs to add a tab, which is above this view’s
	/// pay grade.
	var openProjectHandler: ((Project) -> Void)?
	var newProjectHandler: (() -> Void)?
	var connectSSHHostHandler: ((SSHHost) -> Void)?
	var newSSHHostHandler: (() -> Void)?
	var aiCommandHandler: ((AICommand) -> Void)?
	var deleteProjectHandler: ((Project) -> Void)?
	var attachImageHandler: (() -> Void)?

	private var state = KeyboardToolbarViewState()
	private var pressedHardwareKeys = Set<UIKey>()
	private var pressedToolbarKeys = Set<ToolbarKey>()

	override init(frame: CGRect) {
		super.init(frame: frame)

		autocapitalizationType = .none
		autocorrectionType = .no
		spellCheckingType = .no
		smartQuotesType = .no
		smartDashesType = .no
		smartInsertDeleteType = .no

		var toolbars: [Toolbar] = [.attachments, .projects, .sshHosts, .aiCommands, .fnKeys, .secondary]
		if UIDevice.current.userInterfaceIdiom == .pad {
			let leadingView = KeyboardToolbarPadItemView(delegate: self,
																									 toolbar: .padPrimaryLeading,
																									 state: state)
			let trailingView = KeyboardToolbarPadItemView(delegate: self,
																										toolbar: .padPrimaryTrailing,
																										state: state)

			inputAssistantItem.allowsHidingShortcuts = false

			if #available(iOS 16, *) {
				inputAssistantItem.leadingBarButtonGroups += [
					.fixedGroup(items: [UIBarButtonItem(customView: leadingView)])
				]
				inputAssistantItem.trailingBarButtonGroups += [
					.fixedGroup(items: [UIBarButtonItem(customView: trailingView)])
				]
			} else {
				inputAssistantItem.leadingBarButtonGroups += [
					UIBarButtonItemGroup(barButtonItems: [UIBarButtonItem(customView: leadingView)], representativeItem: nil)
				]
				inputAssistantItem.trailingBarButtonGroups += [
					UIBarButtonItemGroup(barButtonItems: [UIBarButtonItem(customView: trailingView)], representativeItem: nil)
				]
			}
		} else {
			toolbars += [.primary]
		}

		toolbar = KeyboardToolbarInputView(delegate: self,
																			 toolbars: toolbars,
																			 state: state)
		// The bar tells us when it has actually finished resizing, rather than us guessing from the
		// model change — which fired before SwiftUI had laid the new rows out.
		toolbar.onHeightChanged = { [weak self] delta in
			self?.notifyAccessoryHeightChanged(by: delta)
		}

		// Switching keyboards — to emoji, to a third-party one, to dictation — changes how tall the
		// keyboard is, and the accessory keeps the height it measured for the old one until something
		// asks it again. That left it floating above the new keyboard, or overlapping it.
		NotificationCenter.default.addObserver(self,
																					selector: #selector(self.setNeedsInputViewReload),
																					name: UITextInputMode.currentInputModeDidChangeNotification,
																					object: nil)
		NotificationCenter.default.addObserver(self,
																					selector: #selector(self.keyboardDidHide(_:)),
																					name: UIResponder.keyboardDidHideNotification,
																					object: nil)
		NotificationCenter.default.addObserver(self,
																					selector: #selector(self.keyboardDidShow(_:)),
																					name: UIResponder.keyboardDidShowNotification,
																					object: nil)
	}

	required init?(coder aDecoder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	/// Shared with the landscape side bar so both show the same toggle state.
	var toolbarState: KeyboardToolbarViewState { state }

	private var hasPendingInputViewReload = false

	/// Rebuilds the accessory bar once, at the end of the turn.
	///
	/// `reloadInputViews()` tears the bar down and puts it back, which makes the keyboard re-lay-out
	/// and the terminal reflow around it — visible as a flash. Opening a panel used to cause two of
	/// them in a row: one for the key being toggled on, one for the deferred pass that closes the
	/// others. Coalescing them means the user sees the bar change size once.
	@objc private func setNeedsInputViewReload() {
		guard !hasPendingInputViewReload else {
			return
		}
		hasPendingInputViewReload = true
		DispatchQueue.main.async { [weak self] in
			guard let self else {
				return
			}
			self.hasPendingInputViewReload = false
			// Re-measured before the reload: reloading asks UIKit for the bar again, and if the bar
			// still believes it is as tall as it was with three rows open, that is the height UIKit
			// takes.
			UIView.performWithoutAnimation {
				self.toolbar.invalidateHeight()
				self.reloadInputViews()
				self.layoutIfNeeded()
			}
		}
	}

	/// Tells whoever lays out around the keyboard that its top edge moved, and by how much.
	///
	/// The change rather than the resulting frame: the bar's own frame is only correct once UIKit has
	/// placed it again, which is a turn later, and by then the new row has already been drawn over the
	/// terminal.
	private func notifyAccessoryHeightChanged(by delta: CGFloat) {
		// Only the bar that is actually on screen. Every tab has its own, they all re-measure when the
		// rows change, and the terminal was adding up a delta from each of them — captured at 60fps,
		// the output jumped twice as far as it should for a single frame before the correction pulled
		// it back.
		guard toolbar.window != nil else {
			return
		}
		// The change first, so the terminal makes room in the same pass the row is drawn in. Zero means
		// the bar has only just settled on a height rather than changed one, and there is nothing to
		// make room for — but the correction below still has to go out.
		if delta != 0 {
			NotificationCenter.default.post(name: Self.accessoryHeightDidChangeNotification,
																			object: self,
																			userInfo: [Self.accessoryHeightDeltaKey: delta])
		}
		// Then the truth, once UIKit has placed the bar. Deltas alone drift: UIKit's own keyboard
		// notification already accounts for the bar, the safe area moves underneath both, and adding up
		// changes from three sources that each think they own the number left the terminal 34pt out
		// after a single open and close. This is measured from where the bar actually is, so whatever
		// the arithmetic did, the next turn puts it right.
		DispatchQueue.main.async { [weak self] in
			self?.postAccessoryFrame()
		}
	}

	private func postAccessoryFrame() {
		guard let window = toolbar.window else {
			return
		}
		// The whole bar, and the whole bar floats: keys sit over the terminal rather than taking rows
		// from it. Only the keyboard below them is allowed to make the terminal smaller.
		let barFrame = toolbar.convert(toolbar.bounds, to: nil)
		let top = barFrame.minY
		let keyboardFrame = CGRect(x: barFrame.minX,
															 y: top,
															 width: barFrame.width,
															 height: window.bounds.maxY - top)
		NotificationCenter.default.post(name: Self.accessoryFrameDidChangeNotification,
																		object: self,
																		userInfo: [Self.accessoryFrameKey: keyboardFrame,
																							 Self.accessoryFloatingKey: barFrame.height])
	}

	static let accessoryHeightDidChangeNotification = Notification.Name("ws.hbang.Terminal.accessoryHeightDidChange")
	static let accessoryHeightDeltaKey = "delta"
	static let accessoryFrameDidChangeNotification = Notification.Name("ws.hbang.Terminal.accessoryFrameDidChange")
	static let accessoryFrameKey = "frame"
	/// How much of what UIKit reports as the keyboard is really the bar. All of it floats over the
	/// terminal rather than shrinking it, so whoever lays out around the keyboard takes it back off the
	/// overlap — UIKit's own keyboard frame counts the bar as part of the keyboard.
	static let accessoryFloatingKey = "floating"

	/// Landscape on iPhone. iPad keeps the accessory bar — it has the height to spare, and its keys
	/// live in the shortcuts bar rather than a row of our own.
	/// Takes the trait collection explicitly: UIKit updates a view controller’s traits before its
	/// subviews’, so the controller has to answer this from its own traits rather than asking this
	/// view — otherwise it reads the pre-rotation value and never installs the side bar.
	static func usesSideBar(for traitCollection: UITraitCollection) -> Bool {
		UIDevice.current.userInterfaceIdiom == .phone && traitCollection.verticalSizeClass == .compact
	}

	var usesSideBar: Bool { Self.usesSideBar(for: traitCollection) }

	override var inputAccessoryView: UIView? { usesSideBar ? nil : toolbar }

	/// A stand-in for the keyboard, so putting the keyboard away doesn't take the bar with it.
	///
	/// The accessory bar belongs to the first responder, and dismissing the keyboard resigns it — so
	/// the bar went too. Swapping the keyboard for a view with no height keeps the responder, and the
	/// bar stays docked where it was.
	private final class HiddenInputView: UIView {
		override var intrinsicContentSize: CGSize {
			CGSize(width: UIView.noIntrinsicMetric, height: 0)
		}
	}

	private let hiddenInputView = HiddenInputView()

	/// Whether the keyboard is standing down while the bar stays.
	private(set) var isKeyboardHidden = false

	/// Set by the view controller: whether this terminal is the one on screen.
	var wantsDockedBar = false

	override var inputView: UIView? { isKeyboardHidden ? hiddenInputView : nil }

	/// Whether the system keyboard is actually on screen.
	///
	/// Tracked from the notifications rather than read off first-responder state, because the two can
	/// disagree: the keyboard can go away while this view stays the first responder, and then nothing
	/// in `keyboardDidHide` fires, `isKeyboardHidden` stays false, and tapping the terminal found
	/// itself already the first responder and did nothing at all. The keyboard never came back.
	private(set) var isKeyboardOnScreen = false

	/// Set while deliberately handing the responder back and taking it again, so the hide that
	/// produces isn't mistaken for the user dismissing the keyboard.
	private var isRaisingKeyboard = false

	/// Brings the real keyboard back, from wherever it went.
	func showKeyboard() {
		DeviceLog.write("showKeyboard hidden=\(isKeyboardHidden) onScreen=\(isKeyboardOnScreen) fr=\(isFirstResponder) docked=\(wantsDockedBar)")
		if isKeyboardHidden {
			// Standing down behind the docked bar: swapping the stand-in back out is enough.
			isKeyboardHidden = false
			reloadInputViews()
			if !isFirstResponder {
				_ = becomeFirstResponder()
			}
			return
		}

		guard !isKeyboardOnScreen else {
			return
		}
		guard isFirstResponder else {
			_ = becomeFirstResponder()
			return
		}

		// Still the first responder, but with no keyboard. Reloading the input views doesn't bring one
		// back once UIKit has taken it away, so give the responder up and take it again.
		isRaisingKeyboard = true
		_ = super.resignFirstResponder()
		let became = becomeFirstResponder()
		isRaisingKeyboard = false
		DeviceLog.write("showKeyboard recovery became=\(became) fr=\(isFirstResponder)")
	}

	@objc private func keyboardDidShow(_ notification: Notification) {
		let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
		DeviceLog.write("didShow h=\(frame.height) hidden=\(isKeyboardHidden) fr=\(isFirstResponder)")
		// The stand-in has no height, so its arrival is reported the same way. That isn't a keyboard.
		if !isKeyboardHidden {
			isKeyboardOnScreen = true
		}
	}

	@objc private func keyboardDidHide(_ notification: Notification) {
		DeviceLog.write("didHide hidden=\(isKeyboardHidden) fr=\(isFirstResponder) docked=\(wantsDockedBar) raising=\(isRaisingKeyboard) presented=\(window?.rootViewController?.presentedViewController != nil)")
		// Only when this terminal is the thing on screen. Settings is presented over it and leaves the
		// view controller's own lifecycle alone, so without the second check the bar came back docked
		// on top of the Settings sheet. And only once — the stand-in has no height, so iOS reports its
		// arrival as the keyboard hiding too.
		isKeyboardOnScreen = false
		guard !isRaisingKeyboard,
					wantsDockedBar,
					!isKeyboardHidden,
					let window = window,
					window.rootViewController?.presentedViewController == nil,
					!isFirstResponder else {
			return
		}
		isKeyboardHidden = true
		_ = becomeFirstResponder()
	}

	override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
		super.traitCollectionDidChange(previousTraitCollection)

		if previousTraitCollection?.verticalSizeClass != traitCollection.verticalSizeClass {
			// What a toggle left open doesn't survive the trip: the thing it opened is a row above the
			// keyboard in portrait and a column beside the strip in landscape, and neither is where the
			// user left it. Closing them means the toggles agree with what's on screen either way.
			state.toggledKeys.subtract([.more, .fnKeys, .projects, .ssh, .ai])
			// Makes UIKit ask for inputAccessoryView again, which is how the bar appears and disappears
			// on rotation.
			setNeedsInputViewReload()
		}
	}

	// MARK: - Password manager

	func activatePasswordManager() {
		// Trigger the iOS password manager button, or cancel the operation.
		if let passwordInputView = passwordInputView {
			// We’ll become first responder automatically after removing the view.
			passwordInputView.removeFromSuperview()
		} else {
			passwordInputView = TerminalPasswordInputView()
			passwordInputView!.passwordDelegate = self
			addSubview(passwordInputView!)
			passwordInputView!.becomeFirstResponder()
		}
	}

	// MARK: - UITextInput

	override var hasText: Bool { true }

	override func insertText(_ text: String) {
		// Used by the software keyboard only. See pressesBegan(_:with:) below for hardware keyboard.
		let isCtrlDown = state.toggledKeys.contains(.control)
		let data = text.utf8.map { character -> UTF8Char in
			// Convert newline to carriage return
			if character == 0x0A {
				return EscapeSequences.return.first!
			}
			if isCtrlDown {
				return character.controlCharacter
			}
			return character
		}

		terminalInputDelegate!.receiveKeyboardInput(data: data)
		clearAttachments(ifSending: data)

		if isCtrlDown {
			state.toggledKeys.remove(.control)
		}

//		if !moreToolbar.isHidden {
//			setMoreRowVisible(false, animated: true)
//		}
	}

	override func deleteBackward() {
		terminalInputDelegate!.receiveKeyboardInput(data: EscapeSequences.backspace)
	}

	func beginFloatingCursor(at point: CGPoint) {
		previousFloatingCursorPoint = point
	}

	func updateFloatingCursor(at point: CGPoint) {
		guard let oldPoint = previousFloatingCursorPoint else {
			return
		}

		let threshold: CGFloat
		switch Preferences.shared.keyboardTrackpadSensitivity {
		case .off:    return
		case .low:    threshold = 8
		case .medium: threshold = 5
		case .high:   threshold = 2
		}

		let difference = point.x - oldPoint.x
		if abs(difference) < threshold {
			return
		}
		keyboardToolbarDidPressKey(difference < 0 ? .left : .right)
		previousFloatingCursorPoint = point
	}

	func endFloatingCursor() {
		previousFloatingCursorPoint = nil
	}

	// MARK: - UIResponder

	@discardableResult
	override func becomeFirstResponder() -> Bool {
		if let passwordInputView = passwordInputView {
			return passwordInputView.becomeFirstResponder()
		} else {
			_ = super.becomeFirstResponder()
			return true
		}
	}

	@discardableResult
	override func resignFirstResponder() -> Bool {
		super.resignFirstResponder()
	}

	override var canBecomeFirstResponder: Bool { true }

	override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
		switch action {
		case #selector(self.paste(_:)):
			// Only paste if the pasteboard contains a plaintext type
			return UIPasteboard.general.hasStrings || UIPasteboard.general.hasURLs

		case #selector(self.cut(_:)):
			// Ensure cut is never allowed
			return false

		case #selector(self.copy(_:)):
			// Only offer Copy when the terminal actually has a selection.
			return canCopy?() ?? false

		default:
			return super.canPerformAction(action, withSender: sender)
		}
	}

	override func copy(_ sender: Any?) {
		copyHandler?()
	}

	override func paste(_ sender: Any?) {
		if let string = UIPasteboard.general.string {
			terminalInputDelegate!.receiveKeyboardInput(data: string.utf8Array)
		}
	}

	// MARK: - Hardware keyboard

	@discardableResult
	private func handleKey(_ key: UIKey) -> Bool {
		// We don‘t want to handle cmd, let UIKit handle that.
		if key.modifierFlags.contains(.command) {
			return false
		}

		var keyData: [UTF8Char]
		switch key.keyCode {
		case .keyboardReturnOrEnter: keyData = EscapeSequences.return
		case .keyboardEscape:        keyData = EscapeSequences.meta
		case .keyboardDeleteOrBackspace: keyData = EscapeSequences.backspace
		case .keyboardDeleteForward: keyData = EscapeSequences.delete

		case .keyboardHome:
			keyData = terminalInputDelegate!.applicationCursor ? EscapeSequences.homeApp : EscapeSequences.home

		case .keyboardEnd:
			keyData = terminalInputDelegate!.applicationCursor ? EscapeSequences.endApp : EscapeSequences.end

		case .keyboardUpArrow:
			keyData = terminalInputDelegate!.applicationCursor ? EscapeSequences.upApp : EscapeSequences.up

		case .keyboardDownArrow:
			keyData = terminalInputDelegate!.applicationCursor ? EscapeSequences.downApp : EscapeSequences.down

		case .keyboardLeftArrow:
			if key.modifierFlags.contains(.alternate) {
				keyData = EscapeSequences.leftMeta
			} else if terminalInputDelegate!.applicationCursor {
				keyData = EscapeSequences.leftApp
			} else {
				keyData = EscapeSequences.left
			}

		case .keyboardRightArrow:
			if key.modifierFlags.contains(.alternate) {
				keyData = EscapeSequences.rightMeta
			} else if terminalInputDelegate!.applicationCursor {
				keyData = EscapeSequences.rightApp
			} else {
				keyData = EscapeSequences.right
			}

		case .keyboardPageUp:     keyData = EscapeSequences.pageUp
		case .keyboardPageDown:   keyData = EscapeSequences.pageDown

		case .keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4, .keyboardF5, .keyboardF6, .keyboardF7,
				.keyboardF8, .keyboardF9, .keyboardF10, .keyboardF11, .keyboardF12:
			keyData = EscapeSequences.fn[key.keyCode.rawValue - UIKeyboardHIDUsage.keyboardF1.rawValue]

		default: keyData = key.characters.utf8Array
		}

		// If we didn’t get anything to type, nothing else to do here.
		if keyData.isEmpty {
			return false
		}

		// Translate ctrl key sequences to the approriate escape.
		if key.modifierFlags.contains(.control) {
			keyData = keyData.map(\.controlCharacter)
		}

		// Prepend esc before each byte if meta key is down.
		if key.modifierFlags.contains(.alternate) {
			keyData = keyData.reduce([], { result, character in result + EscapeSequences.meta + [character] })
		}

		terminalInputDelegate?.receiveKeyboardInput(data: keyData)
		clearAttachments(ifSending: keyData)
		return true
	}

	/// Attachments belong to the line being typed, so they go away when it’s sent.
	private func clearAttachments(ifSending data: [UTF8Char]) {
		if !state.imageAttachments.isEmpty,
			 data.contains(EscapeSequences.return.first!) {
			state.imageAttachments = []
		}
	}

	override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		var isHandled = false
		for press in presses {
			if let key = press.key,
				 handleKey(key) {
				isHandled = true
				pressedHardwareKeys.insert(key)
			}
		}

		if !pressedHardwareKeys.isEmpty {
			beginKeyRepeat()
		}

		if !isHandled {
			super.pressesBegan(presses, with: event)
		}
	}

	private func handlePressesEnded(_ presses: Set<UIPress>) {
		for press in presses {
			if let key = press.key {
				pressedHardwareKeys.remove(key)
			}
		}
	}

	override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		handlePressesEnded(presses)
		super.pressesEnded(presses, with: event)
	}

	override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		handlePressesEnded(presses)
		super.pressesCancelled(presses, with: event)
	}

	private func beginKeyRepeat() {
		if repeatTimer != nil {
			return
		}

		if KeyboardPreferences.isKeyRepeatEnabled {
			repeatTimer = Timer.scheduledTimer(timeInterval: KeyboardPreferences.keyRepeatDelay,
																				 target: self,
																				 selector: #selector(self.handleKeyRepeat),
																				 userInfo: true,
																				 repeats: false)
		}
	}

	@objc private func handleKeyRepeat(_ timer: Timer) {
		for key in pressedHardwareKeys {
			handleKey(key)
		}

		for key in pressedToolbarKeys {
			keyboardToolbarDidPressKey(key)
		}

		if pressedHardwareKeys.isEmpty && pressedToolbarKeys.isEmpty {
			repeatTimer?.invalidate()
			repeatTimer = nil
			return
		}

		if timer.userInfo as? Bool ?? false {
			repeatTimer = Timer.scheduledTimer(timeInterval: KeyboardPreferences.keyRepeat,
																				 target: self,
																				 selector: #selector(self.handleKeyRepeat),
																				 userInfo: nil,
																				 repeats: true)
		}
	}

}

extension TerminalKeyInput: KeyboardToolbarViewDelegate {
	func keyboardToolbarDidPressKey(_ key: ToolbarKey) {
		guard let terminalInputDelegate = terminalInputDelegate else {
			return
		}

		terminalInputDelegate.receiveKeyboardInput(data: key.keySequence(applicationCursor: terminalInputDelegate.applicationCursor))

		if key.isToggle {
			applyToggle(key)
		}

		switch key {
		case .image:
			attachImageHandler?()
			closeSideBarPanel()

		// A toggle's own effect is handled above. Control is held for the key that comes after it, so
		// nothing else may close on it either.
		case .more, .projects, .ssh, .ai, .fnKeys, .control:
			break

		default:
			closeSideBarPanel()
		}
	}

	/// Flips a toggle and closes whatever it excludes, in one change.
	///
	/// Both halves together, because the bar's height follows this set: inserting the new panel and
	/// removing the old one a turn later meant the bar grew by a row and shrank again, so the terminal
	/// resized twice and reflowed twice for what the user sees as one tap. Switching between More and
	/// Projects showed that as a stutter.
	private func applyToggle(_ key: ToolbarKey) {
		var next = state.toggledKeys
		if next.contains(key) {
			next.remove(key)
			// And everything that was opened from inside it. SSH, AI and Fn are keys in the row More
			// opens, so closing More takes away the only way back to them — leaving their rows on screen
			// with nothing to dismiss them.
			next.subtract(panelsInside(key))
		} else {
			next.insert(key)
			next.subtract(panelsExcluded(by: key))
		}
		state.toggledKeys = next
	}

	/// The landscape panel is a column laid over the terminal, so unlike the accessory row in portrait
	/// it costs the user something to leave open. Pressing one of its keys is as clear a "done with it"
	/// as there is, so it goes away by itself rather than needing a second tap on the key that opened it.
	private func closeSideBarPanel() {
		if usesSideBar {
			state.toggledKeys.subtract([.more, .fnKeys, .projects, .ssh, .ai])
		}
	}

	/// Leaves only `key`'s content open. One at a time in both orientations: the landscape panel has
	/// room for one column, and in portrait the rows stack — Projects, SSH and AI all open at once
	/// was three rows of pickers between the terminal and the keys.
	///
	/// Deferred a turn deliberately. A toggle key has already changed `toggledKeys` inside the button's
	/// own action by the time this runs, and SwiftUI has an update in flight against that value —
	/// changing it a second time in the same turn was simply lost. The width, which watches the
	/// publisher rather than the view, did follow, so the panel ended up narrowed to the new column
	/// while still showing the old one's contents.
	/// Everything reachable only from inside the row this key opens, however deep it goes.
	///
	/// Closing a row closes what it holds, and what those hold in turn. Today only More holds anything;
	/// written as a closure over the toolbar's own key lists so a second level would follow on its own
	/// rather than needing this to be remembered.
	private func panelsInside(_ key: ToolbarKey) -> Set<ToolbarKey> {
		var found = Set<ToolbarKey>()
		var queue = [key]
		while let next = queue.popLast() {
			for child in Self.rowOpened(by: next)?.keys.filter({ $0.isToggle }) ?? []
			where found.insert(child).inserted {
				queue.append(child)
			}
		}
		return found
	}

	/// The row a toggle opens, for the toggles that open one.
	private static func rowOpened(by key: ToolbarKey) -> Toolbar? {
		switch key {
		case .more:    return .secondary
		case .fnKeys:  return .fnKeys
		default:       return nil
		}
	}

	/// The panels a given one can't share the bar with.
	///
	/// Only the other content keys, so an armed Control survives opening a panel.
	///
	/// More is among them unless the key just pressed is one of the ones More itself is holding — SSH,
	/// AI and Fn live in the row it opens, and closing it would pull the key out from under the finger
	/// that pressed it. Projects is in the row below and has no such problem, which is why leaving More
	/// alone in portrait made the exclusion one-way.
	private func panelsExcluded(by key: ToolbarKey) -> Set<ToolbarKey> {
		guard key != .control else {
			return []
		}
		var others = Set<ToolbarKey>([.fnKeys, .projects, .ssh, .ai])
		if usesSideBar || !Toolbar.secondary.keys.contains(key) {
			others.insert(.more)
		}
		others.remove(key)
		return others
	}

	func keyboardToolbarDidBeginPressingKey(_ key: ToolbarKey) {
		switch key {
		case .up, .down, .left, .right,
				 .delete:
			pressedToolbarKeys.insert(key)
			beginKeyRepeat()

		default: break
		}
	}

	func keyboardToolbarDidEndPressingKey(_ key: ToolbarKey) {
		pressedToolbarKeys.remove(key)
	}

	func keyboardToolbarDidSelectProject(_ project: Project) {
		if usesSideBar {
			state.toggledKeys.remove(.projects)
		}
		openProjectHandler?(project)
	}

	func keyboardToolbarDidRequestNewProject() {
		newProjectHandler?()
	}

	func keyboardToolbarDidRequestDeleteProject(_ project: Project) {
		deleteProjectHandler?(project)
	}

	func keyboardToolbarDidSelectSSHHost(_ host: SSHHost) {
		if usesSideBar {
			state.toggledKeys.remove(.ssh)
		}
		connectSSHHostHandler?(host)
	}

	func keyboardToolbarDidRequestNewSSHHost() {
		newSSHHostHandler?()
	}

	func keyboardToolbarDidSelectAICommand(_ command: AICommand) {
		if usesSideBar {
			state.toggledKeys.remove(.ai)
		}
		aiCommandHandler?(command)
	}
}

extension TerminalKeyInput: TerminalPasswordInputViewDelegate {

	func passwordInputViewDidComplete(password: String?) {
		if let password = password {
			// User could have typed on the keyboard while it was in password mode, rather than using the
			// password autofill. Send a return if it seems like a password was actually received,
			// otherwise just pretend it was typed like normal.
			if password.count > 2 {
				terminalInputDelegate!.receiveKeyboardInput(data: password.utf8Array + EscapeSequences.return)
			} else {
				insertText(password)
			}
		}
		passwordInputView?.removeFromSuperview()
		passwordInputView = nil
		_ = becomeFirstResponder()
	}

}
