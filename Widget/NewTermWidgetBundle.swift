//
//  NewTermWidgetBundle.swift
//  NewTerm Widget
//

import SwiftUI
import WidgetKit

@main
struct NewTermWidgetBundle: WidgetBundle {
	var body: some Widget {
		if #available(iOS 16.2, *) {
			TerminalLiveActivity()
		}
	}
}
