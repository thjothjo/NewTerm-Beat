//
//  TerminalLiveActivity.swift
//  NewTerm Widget
//

import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.2, *)
struct TerminalLiveActivity: Widget {

	var body: some WidgetConfiguration {
		ActivityConfiguration(for: TerminalActivityAttributes.self) { context in
			// Lock screen and, on devices without an island, the banner.
			LockScreenView(context: context)
				.padding(.horizontal, 4)
		} dynamicIsland: { context in
			DynamicIsland {
				DynamicIslandExpandedRegion(.leading) {
					Label(context.attributes.command, systemImage: "terminal")
						.font(.caption.weight(.semibold))
						.foregroundColor(.primary)
				}
				DynamicIslandExpandedRegion(.trailing) {
					ElapsedText(startedAt: context.state.startedAt)
						.font(.caption.monospacedDigit())
						.foregroundColor(.secondary)
				}
				DynamicIslandExpandedRegion(.bottom) {
					VStack(alignment: .leading, spacing: 2) {
						if let project = context.attributes.project, !project.isEmpty {
							Text(project)
								.font(.caption2)
								.foregroundColor(.secondary)
						}
						Text(context.state.detail.isEmpty
								 ? context.state.state.label
								 : context.state.detail)
							.font(.caption)
							.lineLimit(2)
							.frame(maxWidth: .infinity, alignment: .leading)
					}
				}
			} compactLeading: {
				StatusDot(state: context.state.state, tick: context.state.tick)
			} compactTrailing: {
				ThinkingBot(state: context.state.state, tick: context.state.tick, size: 20)
			} minimal: {
				ThinkingBot(state: context.state.state, tick: context.state.tick, size: 18)
			}
		}
	}
}

/// Counting up rather than pushing a new state every second — a timer style is drawn by the system,
/// so the activity costs one update when something actually changes.
@available(iOS 16.2, *)
private struct ElapsedText: View {
	let startedAt: Date

	var body: some View {
		Text(startedAt, style: .timer)
	}
}

/// The glow the island gives off while the agent is working.
///
/// An app can only draw in the two regions either side of the island — the pill between them is the
/// system's, and nothing can paint on it. A red shadow cast from both regions is what reaches it:
/// the light bleeds inwards and the whole pill sits in it. It breathes on `tick` rather than on an
/// animation, because a Live Activity draws the state it is given and nothing moves in between —
/// which is the honest version of a pulse anyway, since it stops when the work does.
/// How far through a breath the given update is, from 0 (out) to 1 (in).
///
/// A Live Activity does not animate. Measured on the phone: six frames across two seconds are pixel
/// for pixel identical, and `symbolEffect` — the one thing that is meant to animate here — never
/// moved. The view is a still picture of whatever state was last pushed, so the only motion
/// available is the difference between one push and the next.
///
/// Which makes the step size the whole design. Flipping between two values reads as a blink; walking
/// a cosine around an eight-step cycle changes the dot a little each time, and at an update every
/// couple of seconds that reads as a breath.
@available(iOS 16.2, *)
private func breathPhase(tick: Int) -> Double {
	let steps = 8
	let phase = Double(((tick % steps) + steps) % steps) / Double(steps) * 2 * .pi
	return 0.5 + 0.5 * cos(phase)
}

/// The dot on the leading side. Small on purpose — the pill is as wide as what we put in it, and a
/// wide ring made a short status into a bar across the top of the screen.
@available(iOS 16.2, *)
private struct StatusDot: View {
	let state: TerminalActivity.State
	let tick: Int

	var body: some View {
		let breath = state == .running ? breathPhase(tick: tick) : 1
		Circle()
			.fill(state.islandTint)
			.frame(width: 10, height: 10)
			// Size and light move together, both by a little. The dot swells and fades as one thing
			// rather than switching between a big state and a small one.
			.scaleEffect(0.82 + 0.18 * breath)
			.opacity(0.6 + 0.4 * breath)
			.shadow(color: state == .running ? .red.opacity(0.35 + 0.5 * breath) : .clear,
							radius: 6 + 7 * breath)
	}
}

/// A bot that looks around while it thinks.
///
/// Drawn rather than an emoji: an emoji is a picture of somebody else's robot at whatever size the
/// font feels like, and it can't look anywhere. This is a head with one eye, and the eye moves to a
/// new side on every update — so it glances about while the agent is producing output and settles
/// the moment it stops.
@available(iOS 16.2, *)
private struct ThinkingBot: View {
	let state: TerminalActivity.State
	let tick: Int
	let size: CGFloat

	/// A number that jumps about with the tick rather than counting along with it.
	///
	/// Stepping through four fixed directions made the eye march clockwise like a second hand. Hashing
	/// the tick gives an angle anywhere on the circle, and each step lands wherever it lands — so it
	/// turns both ways, by varying amounts, the way something actually thinking would.
	private var scrambled: UInt64 {
		var h = UInt64(bitPattern: Int64(tick)) &* 0x9E3779B97F4A7C15
		h ^= h >> 30
		h = h &* 0xBF58476D1CE4E5B9
		h ^= h >> 27
		return h
	}

	/// Every fifth step or so, the eye shuts instead of looking somewhere.
	private var isBlinking: Bool { state == .running && scrambled % 6 == 0 }

	/// Where the eye is looking, as a fraction of how far it can travel.
	private var gaze: CGSize {
		guard state == .running, !isBlinking else {
			// Straight ahead when there is nothing to think about.
			return .zero
		}
		let angle = Double(scrambled % 360) * .pi / 180
		return CGSize(width: cos(angle), height: sin(angle))
	}

	var body: some View {
		let travel = size * 0.11
		ZStack {
			// Black, with an outline that carries it. The island is black too, so a black head with no
			// edge is an invisible one — the outline is what makes the shape read at all.
			RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
				.fill(.black)
				.overlay(
					RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
						.strokeBorder(.white, lineWidth: 1.5)
				)
			// Shut, the eye is a line rather than a dot — the same shape squashed, so a blink reads as
			// the same eye closing instead of a different one appearing.
			Capsule()
				.fill(.white)
				.frame(width: size * 0.34, height: size * (isBlinking ? 0.08 : 0.34))
				.offset(x: gaze.width * travel, y: gaze.height * travel)
		}
			.frame(width: size, height: size)
			// The antenna, so the black square reads as a head rather than a hole.
			.overlay(alignment: .top) {
				Capsule()
					.fill(.white)
					.frame(width: size * 0.09, height: size * 0.2)
					.offset(y: -size * 0.16)
			}
	}
}

@available(iOS 16.2, *)
private struct LockScreenView: View {
	let context: ActivityViewContext<TerminalActivityAttributes>

	var body: some View {
		HStack(spacing: 10) {
			Image(systemName: context.state.state.symbol)
				.foregroundColor(context.state.state.tint)
			VStack(alignment: .leading, spacing: 2) {
				HStack {
					Text(context.attributes.command)
						.font(.callout.weight(.semibold))
					if let project = context.attributes.project, !project.isEmpty {
						Text(project)
							.font(.caption2)
							.foregroundColor(.secondary)
					}
					Spacer()
					Text(context.state.startedAt, style: .timer)
						.font(.caption.monospacedDigit())
						.foregroundColor(.secondary)
				}
				Text(context.state.detail.isEmpty
						 ? context.state.state.label
						 : context.state.detail)
					.font(.caption)
					.foregroundColor(.secondary)
					.lineLimit(1)
			}
		}
			.padding(.vertical, 6)
	}
}

private extension TerminalActivity.State {
	var symbol: String {
		switch self {
		case .running:  return "circle.dotted"
		case .waiting:  return "questionmark.circle"
		case .finished: return "checkmark.circle"
		}
	}

	var tint: Color {
		switch self {
		case .running:  return .blue
		case .waiting:  return .orange
		case .finished: return .green
		}
	}

	/// What the ring around the island is painted in.
	///
	/// Red while the agent is working, which is the state worth spotting from across a desk. The
	/// lock screen keeps the calmer blue — there the row is read, not glanced at.
	var islandTint: Color {
		switch self {
		case .running:  return .red
		case .waiting:  return .orange
		case .finished: return .green
		}
	}

	var label: String {
		switch self {
		case .running:  return "Working…"
		case .waiting:  return "Waiting for you"
		case .finished: return "Finished"
		}
	}
}
