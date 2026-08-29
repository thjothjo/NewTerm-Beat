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

fileprivate extension View {
	/// `defaultScrollAnchor(.bottom)` where it exists, and nothing where it doesn't.
	@ViewBuilder
	func bottomAnchoredScroll() -> some View {
		if #available(iOS 17, *) {
			defaultScrollAnchor(.bottom)
		} else {
			self
		}
	}
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
					// Outside the lazy stack, so it is laid out even when line 0 has scrolled away.
					.background(lineHeightProbe, alignment: .topLeading)
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
					// Anchored at the bottom, so a change in the viewport's height doesn't cost the offset.
					// Without it SwiftUI rebuilds the scroll view for the new size and hands it back at the
					// top: opening a keyboard row threw the output upwards for a frame, and the row itself
					// was drawn over the last lines until the terminal caught up.
					.bottomAnchoredScroll()
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

	/// One row, laid out exactly as a real line is but never shown, purely to measure the height
	/// SwiftUI gives a row.
	///
	/// It can't be taken from the font: SwiftUI rounds a row to whole points, and which way it rounds
	/// doesn't reliably follow the font's own metrics (12pt matches `ceil`, 10pt and 18pt don't). And
	/// it can't be divided out of the content, for the reason in `applyGeometry`. Measuring one row
	/// directly is the only reading that is neither stale nor guessed.
	private var lineHeightProbe: some View {
		Text(verbatim: "A")
			.font(Font(state.fontMetrics.regularFont))
			.tracking(0)
			.lineLimit(1)
			.fixedSize(horizontal: false, vertical: true)
			.background(GeometryReader { probe in
				Color.clear
					.onAppear { state.lineHeight = probe.size.height }
					.onChange(of: probe.size.height) { state.lineHeight = $0 }
			})
			.hidden()
	}

	// MARK: - Geometry

	/// Observes the laid-out content. This must never scroll: `scrollTo` remeasures the `LazyVStack`,
	/// which changes `contentHeight`, which lands straight back here — a loop that spins the main
	/// thread until the app is dead. Scrolling is driven from events that scrolling itself can’t
	/// cause, further down.
	private func applyGeometry(_ metrics: TerminalContentMetrics) {
		state.contentOriginY = metrics.originY

		// Line height comes from `lineHeightProbe`, not from dividing the total height by the line
		// count: those two are produced by different layout passes, so output arriving between them
		// divided a stale height by a fresh count and made every row look ~9% shorter than it is.

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

	/// The preview’s terminal, kept alive across redraws.
	///
	/// These were stored properties on the view struct, which SwiftUI rebuilds every time anything it
	/// observes changes. Picking a theme therefore threw away the configured terminal and made a fresh
	/// one whose colours were only ever set in `onAppear` — which doesn’t run again — so the preview
	/// went black the moment you changed a theme. Held here, it is made once and only repainted.
	private class Model: ObservableObject {
		private class Delegate: NSObject, TerminalDelegate {
			func send(source: Terminal, data: ArraySlice<UInt8>) {}
		}

		let state = TerminalState()
		let stringSupplier = StringSupplier()
		let terminal: Terminal
		private let delegate = Delegate()

		init() {
			terminal = Terminal(delegate: delegate,
													options: TerminalOptions(cols: 80,
																									 rows: 25,
																									 termName: "xterm-256color",
																									 scrollback: 100))
			stringSupplier.terminal = terminal

			if let colorTest = try? Data(contentsOf: Bundle.main.url(forResource: "colortest", withExtension: "txt")!) {
				terminal.feed(byteArray: [UTF8Char](colorTest))
			}
		}

		/// The supplier draws the text; the state draws everything behind it. Setting only the former
		/// left a light theme’s black text sitting on the previous theme’s dark background.
		func apply(colorMap: ColorMap, fontMetrics: FontMetrics) {
			stringSupplier.colorMap = colorMap
			stringSupplier.fontMetrics = fontMetrics
			state.colorMap = colorMap
			state.fontMetrics = fontMetrics
			redraw()
		}

		func redraw() {
			state.lines = Array(0...(terminal.rows + terminal.getTopVisibleRow()))
				.map { stringSupplier.attributedString(forScrollInvariantRow: $0) }
		}
	}

	@StateObject private var model = Model()

	/// Observed rather than held, so the preview follows the live preference instead of whatever value
	/// it happened to be created with.
	@ObservedObject private var preferences = Preferences.shared

	private let timer = Timer.publish(every: 1, on: .main, in: .common)
		.autoconnect()

	/// Takes the values for source compatibility with its callers; the preview follows the live
	/// preferences regardless of what it was handed.
	init(fontMetrics: FontMetrics = FontMetrics(font: AppFont(), fontSize: 12),
			 colorMap: ColorMap = ColorMap(theme: AppTheme())) {}

	var body: some View {
		TerminalView()
			.environmentObject(model.state)
			.onAppear { apply() }
			// The notification rather than the published properties. `Preferences` stores these as
			// `@AppStorage`, which SwiftUI only observes inside a View — in a class it is plain storage,
			// so a picker writing through its binding updated the value without ever invalidating this
			// view, and the preview kept drawing the theme you had before.
			.onReceive(NotificationCenter.default.publisher(for: Preferences.didChangeNotification)) { _ in
				apply()
			}
			.onChangeOfFrame(perform: { size in
				// Determine the screen size based on the font size
				// TODO: Calculate the exact number of lines we need from the buffer
				let glyphSize = model.stringSupplier.fontMetrics?.boundingBox ?? .zero
				model.terminal.resize(cols: Int(size.width / glyphSize.width),
															rows: 32)
			})
			.onReceive(timer) { _ in model.redraw() }
	}

	private func apply() {
		model.apply(colorMap: preferences.colorMap, fontMetrics: preferences.fontMetrics)
	}
}

struct TerminalView_Previews: PreviewProvider {
	static var previews: some View {
		TerminalSampleView()
			.preferredColorScheme(.dark)
	}
}
