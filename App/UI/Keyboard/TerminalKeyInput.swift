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
	private var isAccessorySuppressed = false

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
	var editSSHHostHandler: ((SSHHost) -> Void)?
	var deleteSSHHostHandler: ((SSHHost) -> Void)?
	var aiCommandHandler: ((AICommand) -> Void)?
	var deleteProjectHandler: ((Project) -> Void)?
	var attachImageHandler: (() -> Void)?

	private var state = KeyboardToolbarViewState()
	/// Keys held down, by the key on the keyboard rather than by the event object.
	///
	/// This was a `Set<UIKey>`, which compares by identity: the press that reports a key going up
	/// carries a different `UIKey` than the one that reported it going down, so the release didn't
	/// match, the key stayed in the set, and the repeat timer typed it forever. A key code is the
	/// same value both times.
	private var pressedHardwareKeys = [UIKeyboardHIDUsage: UIKey]()
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
																		name: UIResponder.keyboardWillHideNotification,
																		object: nil)
		// The docked bar needs an owner, and UIKit will not hand the responder over while the keyboard
		// is still animating out. `didHide` is the first moment it will.
		NotificationCenter.default.addObserver(self,
																		selector: #selector(self.keyboardDidFinishHiding(_:)),
																		name: UIResponder.keyboardDidHideNotification,
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
		// Only the rows a toggle opened float. The row that is always there takes its space from the
		// terminal, the same as the keyboard under it does — reporting the whole bar as floating left
		// the last lines of output, prompt included, drawn underneath the keys.
		let barFrame = toolbar.convert(toolbar.bounds, to: nil)
		let top = barFrame.minY
		let keyboardFrame = CGRect(x: barFrame.minX,
															 y: top,
															 width: barFrame.width,
															 height: window.bounds.maxY - top)
		NotificationCenter.default.post(name: Self.accessoryFrameDidChangeNotification,
																		object: self,
																		userInfo: [Self.accessoryFrameKey: keyboardFrame,
																							 Self.accessoryFloatingKey: toolbar.floatingHeight])
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

	/// Nil while suppressed, which is what actually takes the bar off screen — see
	/// `suppressAccessory()`.
	override var inputAccessoryView: UIView? {
		(isAccessorySuppressed || usesSideBar) ? nil : toolbar
	}

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

	/// Leaves tab edit mode. Set by the view controller, which is the one that can reach the tab bar.
	var endTabEditing: (() -> Void)?

	/// Whether this terminal really is the one on screen.
	///
	/// `wantsDockedBar` isn't enough on its own. Selecting a tab hides the previous one rather than
	/// removing it, so every tab gets `viewWillAppear` and every tab's bar thinks it is the one in
	/// front. Measured on the phone: when the visible terminal's keyboard hid, the tab *behind* it
	/// docked its own bar, took the first responder with it, and did so holding a zero-height input
	/// view — after which no tap could bring a keyboard back, because the responder belonged to a
	/// terminal nobody could see.
	private var isOnScreen: Bool {
		guard window != nil else {
			return false
		}
		var view: UIView? = self
		while let current = view {
			if current.isHidden {
				return false
			}
			view = current.superview
		}
		return true
	}

	override var inputView: UIView? { isKeyboardHidden ? hiddenInputView : nil }

	/// Whether the system keyboard is on screen, measured rather than remembered.
	///
	/// The bar sits on top of the keyboard, so with one up the bar's bottom edge is a keyboard's
	/// height clear of the bottom of the window; docked on its own it reaches the bottom. Reading it
	/// this way can't go stale. Tracking it from the notifications did: the bar reports itself as a
	/// keyboard when it docks, which set the flag with nothing on screen, and nothing ever cleared it
	/// — so every tap after that decided the keyboard was already there and did nothing at all.
	var isKeyboardOnScreen: Bool {
		guard let window = toolbar.window, toolbar.bounds.height > 0 else {
			return false
		}
		return toolbar.convert(toolbar.bounds, to: nil).maxY < window.bounds.maxY - 1
	}

	/// Set while deliberately handing the responder back and taking it again, so the hide that
	/// produces isn't mistaken for the user dismissing the keyboard.
	private var isRaisingKeyboard = false

	/// Brings the real keyboard back, from wherever it went.
	func showKeyboard() {
		raiseKeyboard()
		// UIKit refuses the responder while an earlier dismissal is still winding down, and a sheet
		// closing is exactly that. One more turn is enough. Every way of asking needs this, not just
		// the last one: with the bar docked the ask is a plain `becomeFirstResponder`, and when that
		// was refused nothing asked again — which is the tap that appeared to do nothing at all.
		DispatchQueue.main.async { [weak self] in
			guard let self = self, !self.isFirstResponder, self.wantsDockedBar, self.isOnScreen else {
				return
			}
			_ = self.becomeFirstResponder()
		}
	}

	private func raiseKeyboard() {
		// Cancels a docking waiting on the last hide animation: the keyboard is wanted again.
		dockGeneration &+= 1
		if isKeyboardHidden {
			// Standing down behind the docked bar: put the stand-in away, so asking for the keyboard
			// below gets the real one.
			isKeyboardHidden = false
			reloadInputViews()
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
		_ = becomeFirstResponder()
		// Lowered a turn later, not here. The resign above posts its keyboard notifications
		// asynchronously, and with the flag already down by the time the hide arrives it reads as the
		// user putting the keyboard away — so the bar docked itself again and the keyboard never came
		// up. Measured: one tap in six did nothing at all.
		DispatchQueue.main.async { [weak self] in
			self?.isRaisingKeyboard = false
		}
	}

	/// Removes the terminal's keyboard UI while another screen is in front. A sheet does not make the
	/// terminal disappear, so its normal view lifecycle cannot do this for us.
	func suppressAccessory() {
		guard !isAccessorySuppressed else {
			return
		}
		isAccessorySuppressed = true
		// The bar can be on screen while we are not the first responder at all. Putting the keyboard
		// away resigns it, and the attempt to take it straight back is refused while the keyboard is
		// still animating out — which leaves the bar up with nobody owning it. Resigning something we
		// don't hold does nothing, so the bar stayed exactly where it was, over whatever was presented
		// on top of the app. Taking the responder back first is what makes the bar ours to remove:
		// `inputAccessoryView` now answers nil, so the reload takes it away.
		//
		// `super`, deliberately: this class's own `becomeFirstResponder` clears the flag that makes
		// the accessory nil, which is the one thing this must not undo.
		if !isFirstResponder {
			_ = super.becomeFirstResponder()
		}
		if isFirstResponder {
			UIView.performWithoutAnimation {
				reloadInputViews()
			}
		}
		_ = resignFirstResponder()
	}

	/// Gives the bar back once whatever was in front of the terminal has gone.
	///
	/// Deliberately leaves `isKeyboardHidden` alone: the keyboard was down before the sheet appeared,
	/// and it should still be down afterwards — only the docked bar comes back.
	func restoreAccessory() {
		guard isAccessorySuppressed else {
			return
		}
		isAccessorySuppressed = false
		guard wantsDockedBar, isOnScreen else {
			return
		}
		// Never taken during the layout pass that noticed the sheet had gone. Changing the first
		// responder from inside layout re-enters UIKit's keyboard machinery mid-pass, and what that
		// produced was a keyboard that could not be brought back up at all.
		DispatchQueue.main.async { [weak self] in
			guard let self, !self.isAccessorySuppressed, self.wantsDockedBar, self.isOnScreen else {
				return
			}
			if self.isFirstResponder {
				self.reloadInputViews()
			} else {
				_ = self.becomeFirstResponder()
			}
		}
	}

	@objc private func keyboardDidHide(_ notification: Notification) {
		// Only when this terminal is the thing on screen. Settings is presented over it and leaves the
		// view controller's own lifecycle alone, so without the second check the bar came back docked
		// on top of the Settings sheet. And only once — the stand-in has no height, so iOS reports its
		// arrival as the keyboard hiding too.
		guard !isRaisingKeyboard,
					!isAccessorySuppressed,
					wantsDockedBar,
					isOnScreen,
					!isKeyboardHidden,
					let window = window,
					window.rootViewController?.presentedViewController == nil else {
			return
		}
		// Held until the keyboard has finished leaving. Swapping the input view when the animation
		// starts moves the bar to the bottom at once while the keyboard is still on its way down —
		// caught on a 15fps capture, the bar sat detached halfway up the screen with a band of white
		// between it and the keyboard still sliding away underneath. Waiting for `keyboardDidHide`
		// instead is too late: the bar goes with the keyboard and has to be animated back, which is
		// the half-second of no bar this used to have. Matching the keyboard's own duration lands the
		// swap at the moment it arrives at the bottom, where the bar already is.
		let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval
		dockGeneration &+= 1
		let generation = dockGeneration
		DispatchQueue.main.asyncAfter(deadline: .now() + max(0, duration ?? 0.25)) { [weak self] in
			guard let self = self,
						self.dockGeneration == generation,
						!self.isRaisingKeyboard,
						!self.isAccessorySuppressed,
						self.wantsDockedBar,
						self.isOnScreen,
						!self.isKeyboardHidden,
						!self.isKeyboardOnScreen,
						let window = self.window,
						window.rootViewController?.presentedViewController == nil else {
				return
			}
			self.isKeyboardHidden = true
			if self.isFirstResponder {
				UIView.performWithoutAnimation { self.reloadInputViews() }
			} else {
				_ = self.becomeFirstResponder()
			}
		}
	}

	/// Bumped whenever something changes what the keyboard is doing, so a docking that was scheduled
	/// for the end of an animation doesn't fire after the keyboard has been asked back.
	private var dockGeneration = 0

	/// Takes the responder back once the keyboard has actually gone.
	///
	/// The bar is the first responder's, and docking it means holding the responder with the keyboard
	/// down. UIKit refuses to hand it over while the keyboard is still animating out, and the refusal
	/// left the bar on screen owned by nobody: nothing could type into it, nothing could take it away,
	/// and asking for the keyboard back did nothing because there was no responder to give it to.
	@objc private func keyboardDidFinishHiding(_ notification: Notification) {
		guard !isRaisingKeyboard,
					!isAccessorySuppressed,
					wantsDockedBar,
					isOnScreen,
					isKeyboardHidden,
					!isFirstResponder,
					let window = window,
					window.rootViewController?.presentedViewController == nil else {
			return
		}
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
			_ = passwordInputView.resignFirstResponder()
			passwordInputView.removeFromSuperview()
			self.passwordInputView = nil
			_ = becomeFirstResponder()
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
		// The software keyboard, and whatever an input method settles on. See `pressesBegan` for the
		// keys a hardware keyboard sends straight through.
		inputMethodTookTheKey = true
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
		isAccessorySuppressed = false
		if let passwordInputView = passwordInputView {
			return passwordInputView.becomeFirstResponder()
		} else {
			_ = super.becomeFirstResponder()
			return true
		}
	}

	@discardableResult
	override func resignFirstResponder() -> Bool {
		_ = passwordInputView?.resignFirstResponder()
		return super.resignFirstResponder()
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
		guard let string = UIPasteboard.general.string,
					let terminalInputDelegate = terminalInputDelegate else {
			return
		}
		// Line endings become the terminal's Enter, the same as typing them — `insertText` does this
		// for the keyboard, and a bare `\n` is a byte many raw-mode programs simply ignore.
		var data = string.replacingOccurrences(of: "\r\n", with: "\r")
			.replacingOccurrences(of: "\n", with: "\r")
			.utf8Array
		// Wrapped when the program asked for it, so a shell or an agent takes a multi-line paste as one
		// thing rather than running every line as it lands.
		if terminalInputDelegate.bracketedPasteMode {
			data = EscapeSequences.bracketedPasteStart + data + EscapeSequences.bracketedPasteEnd
		}
		terminalInputDelegate.receiveKeyboardInput(data: data)
		clearAttachments(ifSending: data)
	}

	// MARK: - Hardware keyboard

	/// Keys that mean something to a terminal in themselves, whatever keyboard is in front.
	///
	/// Everything else is a character, and characters are left to the text input system — see
	/// `pressesBegan`.
	private static let handledKeyCodes: Set<UIKeyboardHIDUsage> = {
		var codes: Set<UIKeyboardHIDUsage> = [
			.keyboardReturnOrEnter, .keyboardEscape, .keyboardDeleteOrBackspace, .keyboardDeleteForward,
			.keyboardTab,
			.keyboardHome, .keyboardEnd, .keyboardPageUp, .keyboardPageDown,
			.keyboardUpArrow, .keyboardDownArrow, .keyboardLeftArrow, .keyboardRightArrow
		]
		for raw in UIKeyboardHIDUsage.keyboardF1.rawValue...UIKeyboardHIDUsage.keyboardF12.rawValue {
			if let code = UIKeyboardHIDUsage(rawValue: raw) {
				codes.insert(code)
			}
		}
		return codes
	}()

	/// Whether this key means something to a terminal in itself, rather than being a character.
	///
	/// Control and Option are terminal keys whatever keyboard is in front, and no input method wants
	/// them.
	private func isTerminalKey(_ key: UIKey) -> Bool {
		if key.modifierFlags.contains(.control) || key.modifierFlags.contains(.alternate) {
			return true
		}
		return Self.handledKeyCodes.contains(key.keyCode)
	}

	/// Whether an input method is part-way through composing something.
	///
	/// Only then are keys left to the text input system: it is the one holding the composition, and a
	/// key typed straight past it would land in the middle of what is being composed.
	///
	/// Deliberately not "is the keyboard a Chinese one". Offering every letter to the input method
	/// because of its language loses them: a terminal has nowhere to show a composition, so the
	/// letters went into one that was never displayed and never committed — typing `plain` produced
	/// `plan`, and on a keyboard whose Latin mode still reports itself as Chinese, nothing at all.
	/// Composing with a hardware keyboard needs the composition drawn somewhere the user can see it,
	/// which this doesn't do yet; until it does, keys are typed.
	private var usesInputMethod: Bool { markedTextRange != nil }

	/// Whether this key is one to offer to the input method rather than type.
	private func defersToInputMethod(_ key: UIKey) -> Bool {
		!key.modifierFlags.contains(.command) && usesInputMethod && !isTerminalKey(key)
	}

	/// Set when the input method does something with a key we handed it — composes with it, or
	/// commits something. Cleared before each batch of presses.
	private var inputMethodTookTheKey = false

	override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
		inputMethodTookTheKey = true
		super.setMarkedText(markedText, selectedRange: selectedRange)
	}

	/// Where a composition should appear, which is where the cursor is.
	///
	/// Zero here put the candidate window in the corner of the screen, a long way from what is being
	/// typed. The view controller knows where the terminal's cursor is; this asks it.
	var cursorRectProvider: (() -> CGRect)?

	override func caretRect(for position: UITextPosition) -> CGRect {
		cursorRectProvider?() ?? CGRect(x: 0, y: bounds.height, width: 1, height: 1)
	}

	override func firstRect(for range: UITextRange) -> CGRect {
		caretRect(for: range.start)
	}

	@discardableResult
	private func handleKey(_ key: UIKey) -> Bool {
		// We don‘t want to handle cmd, let UIKit handle that.
		if key.modifierFlags.contains(.command) {
			return false
		}
		// Characters go to the input method when there is one; see `defersToInputMethod`, and
		// `pressesBegan` for what happens when it turns out not to want them.
		if defersToInputMethod(key) {
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
		// Keys an input method might want. Which it is decides how they are sent, but not until it has
		// had its look at them.
		var offered = [UIKey]()
		for press in presses {
			guard let key = press.key else {
				continue
			}
			if defersToInputMethod(key) {
				offered.append(key)
				continue
			}
			if handleKey(key) {
				isHandled = true
				pressedHardwareKeys[key.keyCode] = key
			}
		}

		if !pressedHardwareKeys.isEmpty {
			beginKeyRepeat()
		}

		if !offered.isEmpty {
			// Offered, then checked. An input method's language is not the same thing as an input method
			// wanting the key: a Chinese keyboard switched to its Latin mode reports itself as Chinese
			// and composes nothing, so every letter went to a system that did nothing with it and never
			// reached the shell. The text input system works through this synchronously, so by the time
			// it returns we know whether the key was taken.
			inputMethodTookTheKey = false
			super.pressesBegan(presses, with: event)
			if !inputMethodTookTheKey {
				// Not added to the held keys: on a repeat these would be offered to the input method again
				// and declined again, and a key that types nothing has no business keeping the timer alive.
				for key in offered {
					typeDirectly(key)
				}
			}
			return
		}

		if !isHandled {
			super.pressesBegan(presses, with: event)
		}
	}

	/// Sends a key's characters to the shell, for a key the input method turned out not to want.
	@discardableResult
	private func typeDirectly(_ key: UIKey) -> Bool {
		let data = key.characters.utf8Array
		guard !data.isEmpty else {
			return false
		}
		terminalInputDelegate?.receiveKeyboardInput(data: data)
		clearAttachments(ifSending: data)
		return true
	}

	private func handlePressesEnded(_ presses: Set<UIPress>) {
		for press in presses {
			if let key = press.key {
				pressedHardwareKeys.removeValue(forKey: key.keyCode)
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
		for key in pressedHardwareKeys.values {
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
		// Tab edit mode's only way out is a tap somewhere that isn't a tab, and the bar isn't somewhere
		// that tap can land: it lives in the keyboard's own window, not in the view the dismiss gesture
		// is on. Pressing a key is as clear a "done with the tabs" as tapping the terminal.
		endTabEditing?()

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

	func keyboardToolbarDidRequestEditSSHHost(_ host: SSHHost) {
		editSSHHostHandler?(host)
	}

	func keyboardToolbarDidRequestDeleteSSHHost(_ host: SSHHost) {
		deleteSSHHostHandler?(host)
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
		if let password = password, !password.isEmpty {
			terminalInputDelegate?.receiveKeyboardInput(data: password.utf8Array + EscapeSequences.return)
		}
		passwordInputView?.removeFromSuperview()
		passwordInputView = nil
		_ = becomeFirstResponder()
	}

}
