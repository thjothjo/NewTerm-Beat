//
//  SettingsAcknowledgementsTextView.swift
//  NewTerm (iOS)
//
//  Created by Adam Demasi on 25/6/21.
//

import SwiftUI
import WebKit

struct SettingsAcknowledgementsTextViewRepresentable: UIViewRepresentable {

	func makeUIView(context: Context) -> UITextView {
		let textView = UITextView()
		textView.isEditable = false

		guard let url = Bundle.main.url(forResource: "acknowledgements", withExtension: "html"),
					let data = try? Data(contentsOf: url) else {
			textView.text = .localize("ACKNOWLEDGEMENTS_UNAVAILABLE")
			return textView
		}

		let preamble = """
		<!DOCTYPE html>
		<html>
		<head>
			<meta charset="utf-8">
			<style>
			html { font: -apple-system-body; -webkit-text-size-adjust: none; }
			body { font-size: 0.9em; }
			.preamble { font-size: 0.92em; text-align: center; }
			</style>
		</head>
		<body>
			<p class="preamble">
				<a href="https://newterm.app/">newterm.app</a>
				<br>
				<a href="https://github.com/hbang/NewTerm">github.com/hbang/NewTerm</a>
			</p>
			<p class="preamble"></p>
		"""
		let preambleData = Data(preamble.utf8)
		let postamble = Data("</body></html>".utf8)
		let html = preambleData + data + postamble

		let attributedString = NSMutableAttributedString()
		if let image = UIImage(named: "app-icon-basic") {
			let attachmentAttributedString = NSMutableAttributedString(attachment: NSTextAttachment(image: image))
			let paragraphStyle = NSMutableParagraphStyle()
			paragraphStyle.alignment = .center
			paragraphStyle.paragraphSpacing = 15
			attachmentAttributedString.addAttribute(.paragraphStyle,
															 value: paragraphStyle,
															 range: NSMakeRange(0, attachmentAttributedString.length))
			attributedString.append(attachmentAttributedString)
			attributedString.mutableString.append("\n")
		}

		let completion = { (htmlAttributedString: NSAttributedString) in
			DispatchQueue.main.async {
				attributedString.append(htmlAttributedString)
				attributedString.addAttribute(.foregroundColor, value: UIColor.label, range: NSMakeRange(0, attributedString.length))

				// Sigh, fix paragraph spacing due to silly WebKit bug
				attributedString.beginEditing()
				attributedString.enumerateAttribute(.paragraphStyle, in: NSMakeRange(0, attributedString.length), options: []) { value, range, _ in
					guard let value = value as? NSParagraphStyle,
							let paragraphStyle = value.mutableCopy() as? NSMutableParagraphStyle else {
						return
					}
					paragraphStyle.paragraphSpacing = max(paragraphStyle.paragraphSpacing, 6)
					attributedString.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
				}
				attributedString.endEditing()

				textView.attributedText = attributedString
			}
		}

		if #available(iOS 14, *) {
			NSMutableAttributedString.loadFromHTML(data: html, options: [:]) { htmlAttributedString, _, _ in
				if let htmlAttributedString = htmlAttributedString {
					completion(htmlAttributedString)
				} else {
					DispatchQueue.main.async {
						textView.text = .localize("ACKNOWLEDGEMENTS_UNAVAILABLE")
					}
				}
			}
		} else {
			if let htmlAttributedString = try? NSMutableAttributedString(data: html,
																				 options: [
																					.documentType: NSAttributedString.DocumentType.html
																				 ],
																				 documentAttributes: nil) {
				completion(htmlAttributedString)
			} else {
				textView.text = .localize("ACKNOWLEDGEMENTS_UNAVAILABLE")
			}
		}

		return textView
	}

	func updateUIView(_ uiView: UIViewType, context: Context) {}

}

struct SettingsAcknowledgementsTextViewRepresentable_Previews: PreviewProvider {
	static var previews: some View {
		SettingsAcknowledgementsTextViewRepresentable()
			.preferredColorScheme(.dark)
			.previewDevice("iPhone 12 Pro")
	}
}
