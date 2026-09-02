//
//  AppFont.swift
//  NewTerm Common
//
//  Created by Adam Demasi on 5/4/21.
//

import Foundation

public struct AppTheme: Codable {

	public static let predefined: [String: AppTheme] = {
		guard let url = Bundle.main.url(forResource: "Themes", withExtension: "plist"),
					let data = try? Data(contentsOf: url),
					let themes = try? PropertyListDecoder().decode([String: AppTheme].self, from: data) else {
			return ["Basic (Dark)": AppTheme()]
		}
		return themes
	}()

	public let background: String
	public let text: String
	public let boldText: String
	public let cursor: String

	public let colorTable: [String]?

	public let isDark: Bool

	public init() {
		// Fallback values
		background = "#000000"
		text = "#f2f2f2"
		boldText = "#ffffff"
		cursor = "#f2f2f2"
		colorTable = nil
		isDark = true
	}

}
