//
//  TerminalPasswordInputView.swift
//  NewTerm (iOS)
//
//  Created by Adam Demasi on 11/3/21.
//

import UIKit

protocol TerminalPasswordInputViewDelegate: AnyObject {
	func passwordInputViewDidComplete(password: String?)
}

class TerminalPasswordInputView: UITextField, UITextFieldDelegate {

	weak var passwordDelegate: TerminalPasswordInputViewDelegate?

	override init(frame: CGRect) {
		super.init(frame: .zero)

		isSecureTextEntry = true
		textContentType = .password
		delegate = self
	}

	required init?(coder: NSCoder) {
		fatalError()
	}

	func textFieldShouldReturn(_ textField: UITextField) -> Bool {
		passwordDelegate?.passwordInputViewDidComplete(password: textField.text)
		textField.text = nil
		return false
	}

}
