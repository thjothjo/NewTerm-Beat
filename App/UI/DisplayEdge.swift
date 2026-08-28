//
//  DisplayEdge.swift
//  NewTerm (iOS)
//

import UIKit

/// Where content can sit relative to the physical edges of the screen.
///
/// In landscape iOS reports the same side inset on both edges — enough to clear the Dynamic Island —
/// so following it puts content just as far in on the edge with no island. There the only thing to
/// clear is the display's rounded corner, which intrudes less the further along the edge you get.
enum DisplayEdge {

	/// How far in content sits on an edge with no Dynamic Island. Small enough to read as against the
	/// edge, non-zero so rounded content doesn't touch the display's own curve.
	static let inset: CGFloat = 8

	/// Largest corner radius Apple currently ships, used because there's no public API for the real
	/// one. Clearing the worst case costs a few points on smaller displays and never clips.
	private static let cornerRadius: CGFloat = 56

	/// Whether the Dynamic Island is on the leading (left, in a left-to-right layout) edge.
	///
	/// `UIInterfaceOrientation`'s landscape cases are defined as the *opposite* `UIDeviceOrientation`
	/// — `UIInterfaceOrientationLandscapeLeft == UIDeviceOrientationLandscapeRight` — so interface
	/// `.landscapeRight` is the device rotated left, which puts its top edge, and the island with it,
	/// on the left. Reading the names at face value puts the clearance on the wrong side.
	static func isIslandOnLeadingEdge(for orientation: UIInterfaceOrientation?) -> Bool {
		orientation == .landscapeRight
	}

	/// How far in from one edge content must sit to clear the rounded corner, given how far along the
	/// other edge it is.
	///
	/// The corner is an arc of radius r centred at (r, r), so at distance d along one edge the screen
	/// boundary on the other is at `r - sqrt(r² - (r - d)²)`. Symmetric, so it answers both "how far
	/// down before I can be this far in" and "how far in must I be at this height".
	static func clearance(atDistance distance: CGFloat) -> CGFloat {
		guard distance < cornerRadius else {
			return 0
		}
		let offset = cornerRadius - distance
		return cornerRadius - (cornerRadius * cornerRadius - offset * offset).squareRoot()
	}
}
