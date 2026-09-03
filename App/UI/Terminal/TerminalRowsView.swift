//
//  TerminalRowsView.swift
//  NewTerm (iOS)
//

import UIKit
import SwiftUI
import SwiftUIX
import Combine
import NewTermCommon

/// The terminal's rows: a scroll view, and a cell for each row that is on screen.
///
/// They were a `LazyVStack`, and once the scrollback was full that was the whole of the main thread —
/// profiled at ten thousand rows and one line of output a frame, SwiftUI re-sized every row it wasn't
/// showing, walked every row to find the one to scroll to, and diffed the lot: about 20ms a line. A
/// `UITableView` cut that to 6ms, and the rest was the table's own bookkeeping — every insert or
/// delete walks every row it knows about, whether or not it is on screen.
///
/// So the rows are placed by hand. A row's position is its index times the row height, the content
/// height is a multiplication, and when a line falls off the top of the scrollback every cell on
/// screen moves up one row: a frame change each, and one new cell at the bottom. Nothing is
/// measured, and nothing off screen exists.
///
/// Each row is still the SwiftUI view `StringSupplier` builds, hosted in its cell — that is where
/// the wide-character and emoji alignment lives, and none of it changes.
final class TerminalRowsView: UIView, UIScrollViewDelegate {

	private let state: TerminalState
	private let scrollView = ScrollView()
	/// What the cells sit in. When lines fall off the top of the scrollback the whole container moves
	/// up instead of every cell: a hosted SwiftUI view re-renders whenever its own frame changes, and
	/// fifty of those a line was most of what a line cost. Its superview moving costs it nothing.
	private let rowsContainer = UIView()
	/// How many rows have fallen off the top since the container was last put back at zero. A cell's
	/// place in the container is its row plus this, so a cell that only moved keeps its frame.
	private var droppedRows = 0
	private let selectionOverlay = SelectionOverlayView()
	private var cancellables = Set<AnyCancellable>()

	/// The cells on screen, by the row each is showing.
	private var cells = [Int: RowCell]()
	/// Cells with no row, kept so a row scrolling into view gets a host without building one.
	private var spareCells = [RowCell]()
	private static let spareCellLimit = 48

	private var rowHeight: CGFloat = 0

	/// Whether new output keeps the newest row on screen. Cleared when the user scrolls up, so
	/// streaming output doesn't yank them back mid-read, and set again when they scroll back down.
	private var followsOutput = true

	init(state: TerminalState) {
		self.state = state
		super.init(frame: .zero)

		scrollView.delegate = self
		scrollView.alwaysBounceVertical = false
		scrollView.contentInsetAdjustmentBehavior = .always
		scrollView.contentInset = UIEdgeInsets(top: TerminalView.verticalSpacing, left: 0,
																					 bottom: TerminalView.verticalSpacing, right: 0)
		scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		scrollView.frame = bounds
		scrollView.onInsetsChanged = { [weak self] in self?.followOutput() }
		addSubview(scrollView)
		rowsContainer.clipsToBounds = false
		scrollView.addSubview(rowsContainer)

		// In the scroll view rather than over it, so it scrolls with the rows. Above the cells.
		selectionOverlay.isUserInteractionEnabled = false
		selectionOverlay.isHidden = true
		selectionOverlay.layer.zPosition = 1
		scrollView.addSubview(selectionOverlay)

		state.$fontMetrics
			.sink { [weak self] in self?.apply(fontMetrics: $0) }
			.store(in: &cancellables)
		state.$colorMap
			.sink { [weak self] in self?.apply(colorMap: $0) }
			.store(in: &cancellables)
		state.$selection
			.sink { [weak self] in self?.apply(selection: $0) }
			.store(in: &cancellables)
		state.$isSplitViewResizing
			.sink { [weak self] resizing in
				UIView.animate(withDuration: 0.1) { self?.scrollView.alpha = resizing ? 0.6 : 1 }
			}
			.store(in: &cancellables)

		// Coming back from the background, UIKit can hand the scroll position back at the top.
		NotificationCenter.default.addObserver(self, selector: #selector(followOutput),
																					 name: UIApplication.didBecomeActiveNotification, object: nil)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		updateContentSize()
		placeContainer()
		// The keyboard arriving or the device rotating changes the viewport. Neither is the user
		// scrolling, so neither changes whether output is being followed — but the bottom has moved.
		followOutput()
		layoutRows()
	}

	// MARK: - Rows

	/// Told what changed, after `state.lines` has been brought up to date.
	///
	/// Rows that survive keep their cells, re-keyed by where they are now; the cells showing a row
	/// that changed are reconfigured in place; and then the screen is laid out, which fills in
	/// whatever rows are showing with no cell — after a line of output, exactly one.
	func apply(removedAtTop: Int, removedAtEnd: Int, appended: Int, changedRows: [Int]) {
		let count = state.lines.count
		if removedAtTop > 0 || removedAtEnd > 0 {
			var moved = [Int: RowCell]()
			moved.reserveCapacity(cells.count)
			for (row, cell) in cells {
				let newRow = row - removedAtTop
				if newRow >= 0 && newRow < count {
					moved[newRow] = cell
				} else {
					retire(cell)
				}
			}
			cells = moved
			droppedRows += removedAtTop
			placeContainer()
		}
		if removedAtTop > 0 || removedAtEnd > 0 || appended > 0 {
			let offsetBefore = scrollView.contentOffset.y
			updateContentSize()
			if removedAtTop > 0 && !followsOutput {
				// Reading the scrollback while lines fall off the top of it: the text under the finger
				// stays where it is, which means the offset comes down by what was removed.
				let floor = -scrollView.adjustedContentInset.top
				scrollView.contentOffset.y = max(floor, offsetBefore - CGFloat(removedAtTop) * rowHeight)
			}
		}
		for row in changedRows {
			if let cell = cells[row] {
				show(row, in: cell)
			}
		}
		followOutput()
		layoutRows()
	}

	/// Moves the container so that row r's cell, at (r + dropped) × height inside it, lands at
	/// r × height in the content. Put back to zero now and then: Core Animation keeps positions as
	/// single-precision floats, and a container a few million points up would start rounding.
	private func placeContainer() {
		if CGFloat(droppedRows) * rowHeight > 1_000_000 {
			droppedRows = 0
		}
		let origin = CGPoint(x: 0, y: -CGFloat(droppedRows) * rowHeight)
		let frame = CGRect(origin: origin, size: CGSize(width: scrollView.bounds.width, height: 0))
		if rowsContainer.frame != frame {
			rowsContainer.frame = frame
		}
	}

	private func updateContentSize() {
		let size = CGSize(width: scrollView.bounds.width, height: CGFloat(state.lines.count) * rowHeight)
		if scrollView.contentSize != size {
			scrollView.contentSize = size
		}
	}

	/// The rows that should have a cell, given where the scroll view is.
	private var visibleRows: Range<Int> {
		guard rowHeight > 0, state.lines.count > 0 else {
			return 0..<0
		}
		let top = scrollView.contentOffset.y
		let bottom = top + scrollView.bounds.height
		let first = max(0, Int(floor(top / rowHeight)))
		let last = min(state.lines.count, Int(ceil(bottom / rowHeight)))
		return first..<max(first, last)
	}

	/// Puts a cell under every row on screen, and takes them away from rows that have left it.
	private func layoutRows() {
		let rows = visibleRows
		for (row, cell) in cells where !rows.contains(row) {
			cells.removeValue(forKey: row)
			retire(cell)
		}
		let width = scrollView.bounds.width
		for row in rows {
			let cell: RowCell
			if let existing = cells[row] {
				cell = existing
			} else {
				cell = spareCells.popLast() ?? RowCell()
				cell.isHidden = false
				cells[row] = cell
				show(row, in: cell)
				if cell.superview == nil {
					rowsContainer.addSubview(cell)
				}
			}
			let frame = CGRect(x: 0, y: CGFloat(row + droppedRows) * rowHeight, width: width, height: rowHeight)
			if cell.frame != frame {
				cell.frame = frame
			}
		}
	}

	private func show(_ row: Int, in cell: RowCell) {
		let line = state.lines[row]
		// The same line again is the same view; there is nothing to re-host.
		guard cell.line !== line else {
			return
		}
		cell.line = line
		cell.hostingView.rootView = AnyView(
			line.view
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
				.padding(.horizontal, TerminalView.horizontalSpacing)
		)
	}

	/// Keeps a cell for later, or lets it go if there are enough already. Left in the hierarchy
	/// either way until it is reused or released: taking a hosted view out of the window and putting
	/// it back is a full SwiftUI render, and hiding it is not.
	private func retire(_ cell: RowCell) {
		if spareCells.count < Self.spareCellLimit {
			cell.isHidden = true
			spareCells.append(cell)
		} else {
			cell.removeFromSuperview()
		}
	}

	/// A cell that hosts one row's SwiftUI view, and keeps the host across reuse — a row change is a
	/// new root view, not a new hosting stack.
	private final class RowCell: UIView {
		let hostingView = UIHostingView<AnyView>(rootView: AnyView(EmptyView()))
		var line: TerminalLine?

		init() {
			super.init(frame: .zero)
			backgroundColor = .clear
			hostingView.backgroundColor = .clear
			hostingView._disableSafeAreaInsets()
			hostingView.frame = bounds
			hostingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
			addSubview(hostingView)
		}

		required init?(coder: NSCoder) {
			fatalError("init(coder:) has not been implemented")
		}
	}

	// MARK: - Appearance

	/// Rows are as tall as SwiftUI makes a line of this font, measured rather than taken from the
	/// font: SwiftUI rounds a row to whole points, and which way it rounds doesn't reliably follow the
	/// font's own metrics (12pt matches `ceil`, 10pt and 18pt don't). Every row is hosted the same
	/// way, so one measurement is every row's height.
	private func apply(fontMetrics: FontMetrics) {
		let probe = UIHostingController(rootView:
			Text(verbatim: "A")
				.font(Font(fontMetrics.regularFont))
				.tracking(0)
				.lineLimit(1)
				.fixedSize(horizontal: false, vertical: true)
		)
		let height = probe.sizeThatFits(in: CGSize(width: 1000, height: 1000)).height
		guard height > 0 else {
			return
		}
		state.lineHeight = height
		selectionOverlay.lineHeight = height
		selectionOverlay.cellWidth = fontMetrics.width
		if rowHeight != height {
			rowHeight = height
			setNeedsLayout()
		}
		apply(selection: state.selection)
	}

	private func apply(colorMap: ColorMap) {
		backgroundColor = colorMap.background
		scrollView.backgroundColor = colorMap.background
		selectionOverlay.isDark = colorMap.isDark
		selectionOverlay.setNeedsDisplay()
	}

	// MARK: - Following output

	/// Pins the view to the newest output, if the user hasn't scrolled up to read something.
	@objc private func followOutput() {
		guard followsOutput else {
			return
		}
		let bottom = bottomOffset
		if abs(scrollView.contentOffset.y - bottom) > 0.5 {
			scrollView.contentOffset.y = bottom
		}
	}

	/// The offset that shows the last row at the bottom — or the top, while it all fits.
	private var bottomOffset: CGFloat {
		let insets = scrollView.adjustedContentInset
		let contentHeight = CGFloat(state.lines.count) * rowHeight
		let top = -insets.top
		return max(top, contentHeight + insets.bottom - scrollView.bounds.height)
	}

	func scrollViewDidScroll(_ scrollView: UIScrollView) {
		// Where the rows start, in this view's coordinates, for turning a touch into a cell.
		state.contentOriginY = -scrollView.contentOffset.y - TerminalView.verticalSpacing

		// Only the user's own scrolling decides whether output is followed. The view moving because
		// output arrived, or because the keyboard did, says nothing about what the user wants.
		if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
			// Within a couple of rows of the bottom counts as at the bottom, so rounding and partially
			// visible rows don't stop the terminal following output.
			let distance = bottomOffset - scrollView.contentOffset.y
			followsOutput = distance <= rowHeight * 2
		}
		layoutRows()
	}

	// MARK: - Selection

	private func apply(selection: TerminalSelection?) {
		guard let selection = selection, !selection.isEmpty, rowHeight > 0 else {
			selectionOverlay.isHidden = true
			return
		}
		let knob = SelectionOverlayView.handleKnobSize
		selectionOverlay.selection = selection
		selectionOverlay.cols = Int((scrollView.bounds.width - TerminalView.horizontalSpacing * 2)
																/ max(1, selectionOverlay.cellWidth))
		// Row r starts at r × rowHeight in the content. The handles reach a knob above and below the
		// selected rows.
		selectionOverlay.frame = CGRect(x: 0,
																		y: CGFloat(selection.start.row) * rowHeight - knob,
																		width: scrollView.bounds.width,
																		height: CGFloat(selection.end.row - selection.start.row + 1) * rowHeight + knob * 2)
		selectionOverlay.isHidden = false
		selectionOverlay.setNeedsDisplay()
	}

	// MARK: -

	/// A scroll view that says when its insets moved — the keyboard, mostly — so the bottom can be
	/// kept pinned through it.
	private final class ScrollView: UIScrollView {
		var onInsetsChanged: (() -> Void)?

		override func adjustedContentInsetDidChange() {
			super.adjustedContentInsetDidChange()
			onInsetsChanged?()
		}
	}

}

/// The selected cells, and a handle at each end.
///
/// Neutral rather than tinted. In a terminal the text colour carries meaning — red for an error,
/// green for success — and a coloured wash shifts every one of them at once. An overlay picked to
/// contrast with the background marks the cells without repainting what is in them.
private final class SelectionOverlayView: UIView {

	/// Diameter of the round grab area drawn at each end of a selection.
	static let handleKnobSize: CGFloat = 10

	var selection: TerminalSelection?
	var lineHeight: CGFloat = 0
	var cellWidth: CGFloat = 0
	var cols = 0
	var isDark = false

	override init(frame: CGRect) {
		super.init(frame: frame)
		backgroundColor = .clear
		isOpaque = false
		contentMode = .redraw
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func draw(_ rect: CGRect) {
		guard let selection = selection, lineHeight > 0, cellWidth > 0,
					let context = UIGraphicsGetCurrentContext() else {
			return
		}
		let knob = Self.handleKnobSize
		let left = TerminalView.horizontalSpacing
		// Rounded ends only when the selection is a single row: two full-width rows meeting would
		// otherwise show a scalloped notch where their rounded corners abut.
		let radius: CGFloat = selection.start.row == selection.end.row ? 3 : 0
		let fill = isDark ? UIColor.white.withAlphaComponent(0.22) : UIColor.black.withAlphaComponent(0.15)

		context.setFillColor(fill.cgColor)
		for row in selection.start.row...selection.end.row {
			guard let range = selection.columnRange(forRow: row, cols: cols) else {
				continue
			}
			let cellRect = CGRect(x: left + CGFloat(range.lowerBound) * cellWidth,
														y: knob + CGFloat(row - selection.start.row) * lineHeight,
														width: CGFloat(range.count) * cellWidth,
														height: lineHeight)
			context.addPath(UIBezierPath(roundedRect: cellRect, cornerRadius: radius).cgPath)
			context.fillPath()
		}

		// Grab handles at each end. Without them the highlight is a rectangle the user can't do
		// anything with once the finger lifts, which reads as a marquee dragged over an image rather
		// than selected text.
		let startX = left + CGFloat(selection.start.col) * cellWidth
		let startY = knob
		let endX = left + CGFloat(selection.end.col) * cellWidth
		let endY = knob + CGFloat(selection.end.row - selection.start.row) * lineHeight
		context.setFillColor(tintColor.cgColor)
		context.fill(CGRect(x: startX - 1, y: startY, width: 2, height: lineHeight))
		context.fillEllipse(in: CGRect(x: startX - knob / 2, y: startY - knob, width: knob, height: knob))
		context.fill(CGRect(x: endX - 1, y: endY, width: 2, height: lineHeight))
		context.fillEllipse(in: CGRect(x: endX - knob / 2, y: endY + lineHeight, width: knob, height: knob))
	}

}
