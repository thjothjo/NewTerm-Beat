//
//  TerminalInputProtocol.swift
//  NewTerm Common
//
//  Created by Adam Demasi on 20/6/19.
//

import Foundation

public protocol TerminalInputProtocol: AnyObject {

	func receiveKeyboardInput(data: [UTF8Char])

	var applicationCursor: Bool { get }

	/// Whether the program asked (mode 2004) for pasted text to arrive wrapped in `ESC[200~` and
	/// `ESC[201~`, so it can tell a paste from typing.
	var bracketedPasteMode: Bool { get }

}
