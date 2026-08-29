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
				StatusDot(state: context.state.state)
			} compactTrailing: {
				ElapsedText(startedAt: context.state.startedAt)
					.font(.caption2.monospacedDigit())
					.foregroundColor(.secondary)
			} minimal: {
				StatusDot(state: context.state.state)
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

@available(iOS 16.2, *)
private struct StatusDot: View {
	let state: TerminalActivity.State

	var body: some View {
		Image(systemName: state.symbol)
			.foregroundColor(state.tint)
			.font(.caption)
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

	var label: String {
		switch self {
		case .running:  return "Working…"
		case .waiting:  return "Waiting for you"
		case .finished: return "Finished"
		}
	}
}
