//
//  TerminalView.swift
//  NewTerm (iOS)
//
//  Created by Adam Demasi on 5/4/2022.
//

import SwiftUI
import SwiftUIX
import SwiftTerm
import NewTermCommon

class TerminalState: ObservableObject {
	@Published var lines = [AnyView]()
	/// Bumped on every refresh from the terminal. `lines` holds `AnyView`s, which can’t be compared,
	/// so this is what SwiftUI watches to know that new output landed.
	@Published var revision = 0
	@Published var fontMetrics = FontMetrics(font: AppFont(), fontSize: 12)
	@Published var colorMap = ColorMap(theme: AppTheme())
	@Published var isSplitViewResizing = false
	@Published var selection: TerminalSelection?

	/// Geometry of the laid-out content, kept current by `TerminalView` so the view controller can
	/// turn a tap location into a terminal cell. Deliberately not `@Published`: it changes on every
	/// scroll frame and nothing needs to re-render when it does.
	var lineHeight: CGFloat = 0
	var contentOriginY: CGFloat = 0

	/// Previous content and viewport heights, for telling a relayout apart from the user scrolling.
	/// Not `@Published` for the same reason as above.
	var lastContentHeight: CGFloat = 0
	var lastViewportHeight: CGFloat = 0

}

/// Where the terminal’s content sits inside its scroll view. Both the scroll-to-bottom decision and
/// touch-to-cell hit testing are driven from this, so they can’t disagree about the layout.
fileprivate struct TerminalContentMetrics: Equatable {
	var originY: CGFloat = 0
	var contentHeight: CGFloat = 0
	var viewportHeight: CGFloat = 0

	/// Points between the bottom of the content and the bottom of the visible area. Zero means the
	/// terminal is scrolled all the way down.
	var distanceFromBottom: CGFloat { originY + contentHeight - viewportHeight }
}

struct TerminalView: View {
	static let horizontalSpacing: CGFloat = isBigDevice ? 3 : 0
	static let verticalSpacing: CGFloat = isBigDevice ? 2 : 0
	/// Diameter of the round grab area drawn at each end of a selection.
	static let handleKnobSize: CGFloat = 10

	private static let scrollCoordinateSpace = "terminal"

	@EnvironmentObject private var state: TerminalState

	/// Whether new output should scroll the terminal down. Cleared as soon as the user scrolls up,
	/// so streaming output doesn’t yank them back to the bottom mid-read, and set again when they
	/// scroll back down.
	@State private var followsOutput = true



	var body: some View {
		let view = GeometryReader { outer in
			ScrollViewReader { scrollView in
				ScrollView(.vertical, showsIndicators: true) {
					LazyVStack(alignment: .leading, spacing: 0) {
						ForEach(Array(zip(state.lines, state.lines.indices)), id: \.1) { line, i in
							line
								.drawingGroup(opaque: true)
								.id(i)
						}
					}
						.padding(.vertical, Self.verticalSpacing)
						.padding(.horizontal, Self.horizontalSpacing)
						.background(Color(state.colorMap.background))
						.overlay(selectionHighlight(viewportWidth: outer.size.width), alignment: .topLeading)
						.background(GeometryReader { content in
							// Preferences don’t make it out of the scroll view’s content here, so the geometry
							// is pushed straight into state instead of being published upwards.
							let metrics = TerminalContentMetrics(
								originY: content.frame(in: .named(Self.scrollCoordinateSpace)).minY,
								contentHeight: content.size.height,
								viewportHeight: outer.size.height)
							Color.clear
								.onAppear { applyGeometry(metrics) }
								.onChange(of: metrics, perform: applyGeometry)
						})
				}
					.coordinateSpace(name: Self.scrollCoordinateSpace)
					.background(Color(state.colorMap.background))
					// The three things that need the view pinned back to the newest output. None of them
					// can be caused by scrolling, so none of them can feed back into another scroll.
					//
					// Every refresh, not just the ones that change the line count: a terminal sitting at
					// its scrollback limit keeps producing output while the total number of lines stays
					// exactly where it was.
					.onChange(of: state.revision, perform: { _ in followOutput(scrollView) })
					// The keyboard appearing or the device rotating. Scrolling never changes the size of
					// the viewport, only the offset within it.
					.onChange(of: outer.size, perform: { _ in followOutput(scrollView) })
					// Coming back from the background, SwiftUI hands the scroll view back at the top.
					.onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
						followOutput(scrollView)
					}
			}
		}
			.opacity(state.isSplitViewResizing ? 0.6 : 1)
			.animation(.linear(duration: 0.1), value: state.isSplitViewResizing)

		if #available(iOS 15, *) {
			return view
				.accessibilityTextContentType(.console)
		} else {
			return view
		}
	}

	// MARK: - Geometry

	/// Observes the laid-out content. This must never scroll: `scrollTo` remeasures the `LazyVStack`,
	/// which changes `contentHeight`, which lands straight back here — a loop that spins the main
	/// thread until the app is dead. Scrolling is driven from events that scrolling itself can’t
	/// cause, further down.
	private func applyGeometry(_ metrics: TerminalContentMetrics) {
		state.contentOriginY = metrics.originY

		let lineCount = state.lines.count
		if lineCount > 0 {
			// Measured from the laid-out content rather than taken from the font, so hit testing tracks
			// what’s actually drawn even if SwiftUI rounds line heights differently to FontMetrics.
			state.lineHeight = (metrics.contentHeight - Self.verticalSpacing * 2) / CGFloat(lineCount)
		}

		// The user scrolling moves the offset and nothing else. Anything that changes the size of the
		// content or of the viewport — new output, the keyboard, a rotation, coming back from the
		// background — is a rebuild, and SwiftUI drops the offset back to the top when it rebuilds.
		// Reading that as the user having scrolled up is what stranded the terminal at the top with
		// follow mode switched off, needing a manual scroll to the bottom to recover.
		let didRelayout = metrics.contentHeight != state.lastContentHeight
			|| metrics.viewportHeight != state.lastViewportHeight
		state.lastContentHeight = metrics.contentHeight
		state.lastViewportHeight = metrics.viewportHeight
		if didRelayout {
			return
		}

		// Treat “within a couple of rows of the bottom” as being at the bottom, so rounding and
		// partially visible rows don’t stop the terminal following output.
		let isAtBottom = metrics.distanceFromBottom <= state.fontMetrics.height * 2
		if isAtBottom != followsOutput {
			followsOutput = isAtBottom
		}
	}

	/// Pins the view to the newest output, if the user hasn’t scrolled up to read something.
	private func followOutput(_ scrollView: ScrollViewProxy) {
		guard followsOutput,
					let last = state.lines.indices.last else {
			return
		}
		scrollView.scrollTo(last, anchor: .bottom)
	}



	@ViewBuilder
	private func selectionHighlight(viewportWidth: CGFloat) -> some View {
		let cellWidth = state.fontMetrics.width
		if let selection = state.selection,
			 !selection.isEmpty,
			 state.lineHeight > 0,
			 cellWidth > 0 {
			let cols = Int((viewportWidth - Self.horizontalSpacing * 2) / cellWidth)
			let knob = Self.handleKnobSize
			let startX = Self.horizontalSpacing + CGFloat(selection.start.col) * cellWidth
			let startY = Self.verticalSpacing + CGFloat(selection.start.row) * state.lineHeight
			let endX = Self.horizontalSpacing + CGFloat(selection.end.col) * cellWidth
			let endY = Self.verticalSpacing + CGFloat(selection.end.row) * state.lineHeight

			// Neutral rather than tinted. In a terminal the text colour carries meaning — red for an
			// error, green for success — and a coloured wash shifts every one of them at once. An
			// overlay picked to contrast with the background marks the cells without repainting what
			// is in them.
			let fill = state.colorMap.isDark ? Color.white.opacity(0.22) : Color.black.opacity(0.15)
			// Rounded ends only when the selection is a single row: two full-width rows meeting would
			// otherwise show a scalloped notch where their rounded corners abut.
			let radius: CGFloat = selection.start.row == selection.end.row ? 3 : 0

			ZStack(alignment: .topLeading) {
				ForEach(selection.start.row...selection.end.row, id: \.self) { row in
					if let range = selection.columnRange(forRow: row, cols: cols) {
						RoundedRectangle(cornerRadius: radius)
							.fill(fill)
							.frame(width: CGFloat(range.count) * cellWidth,
										 height: state.lineHeight)
							.offset(x: Self.horizontalSpacing + CGFloat(range.lowerBound) * cellWidth,
											y: Self.verticalSpacing + CGFloat(row) * state.lineHeight)
					}
				}

				// Grab handles at each end. Without them the highlight is a rectangle the user can't do
				// anything with once the finger lifts, which reads as a marquee dragged over an image
				// rather than selected text.
				Rectangle()
					.fill(Color.accentColor)
					.frame(width: 2, height: state.lineHeight)
					.offset(x: startX - 1, y: startY)
				Circle()
					.fill(Color.accentColor)
					.frame(width: knob, height: knob)
					.offset(x: startX - knob / 2, y: startY - knob)

				Rectangle()
					.fill(Color.accentColor)
					.frame(width: 2, height: state.lineHeight)
					.offset(x: endX - 1, y: endY)
				Circle()
					.fill(Color.accentColor)
					.frame(width: knob, height: knob)
					.offset(x: endX - knob / 2, y: endY + state.lineHeight)
			}
				.allowsHitTesting(false)
		}
	}
}

class TerminalHostingView: UIHostingView<AnyView> {
	init(state: TerminalState) {
		let view = TerminalView()
			.environmentObject(state)
		super.init(rootView: AnyView(view))
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	required init(rootView: AnyView) {
		fatalError("init(rootView:) has not been implemented")
	}
}

struct TerminalSampleView: View {
	private class TerminalSampleViewDelegate: NSObject, TerminalDelegate {
		func send(source: Terminal, data: ArraySlice<UInt8>) {}
	}

	@State var fontMetrics: FontMetrics
	@State var colorMap: ColorMap

	private var terminal: Terminal!
	private let stringSupplier = StringSupplier()
	private let delegate = TerminalSampleViewDelegate()
	private let state = TerminalState()

	private let timer = Timer.publish(every: 1, on: .main, in: .common)
		.autoconnect()

	init(fontMetrics: FontMetrics = FontMetrics(font: AppFont(), fontSize: 12),
			 colorMap: ColorMap = ColorMap(theme: AppTheme())) {
		self.fontMetrics = fontMetrics
		self.colorMap = colorMap

		let options = TerminalOptions(cols: 80,
																	rows: 25,
																	termName: "xterm-256color",
																	scrollback: 100)
		terminal = Terminal(delegate: delegate, options: options)
		stringSupplier.terminal = terminal

		if let colorTest = try? Data(contentsOf: Bundle.main.url(forResource: "colortest", withExtension: "txt")!) {
			terminal?.feed(byteArray: [UTF8Char](colorTest))
		}
	}

	var body: some View {
		TerminalView()
			.environmentObject(state)
			.onAppear {
				stringSupplier.colorMap = colorMap
				stringSupplier.fontMetrics = fontMetrics
			}
			.onChange(of: colorMap, perform: { stringSupplier.colorMap = $0 })
			.onChange(of: fontMetrics, perform: { stringSupplier.fontMetrics = $0 })
			.onChangeOfFrame(perform: { size in
				// Determine the screen size based on the font size
				// TODO: Calculate the exact number of lines we need from the buffer
				let glyphSize = stringSupplier.fontMetrics?.boundingBox ?? .zero
				terminal.resize(cols: Int(size.width / glyphSize.width),
												rows: 32)
			})
			.onReceive(timer) { _ in
				state.lines = Array(0...(terminal.rows + terminal.getTopVisibleRow()))
					.map { stringSupplier.attributedString(forScrollInvariantRow: $0) }
			}
	}
}

struct TerminalView_Previews: PreviewProvider {
	static var previews: some View {
		TerminalSampleView()
			.preferredColorScheme(.dark)
	}
}
