//
//  OrphanReaper.swift
//  NewTerm Common
//

import Foundation
import os.log

/// Cleans up processes left behind by a previous run of the app.
///
/// iOS kills a backgrounded app without warning, and none of our teardown runs when it does. Every
/// shell we started, and everything those shells were running, is re-parented to launchd and stays
/// there — holding its memory and its pid until the device reboots. A long-running CLI is the worst
/// case: leave a few of them behind across a day of app kills and the phone is out of both.
///
/// So every shell is tagged with the launch that started it, the tag is inherited by everything it
/// starts, and anything still carrying an older tag is ours to clean up.
public enum OrphanReaper {

	/// Environment variable naming the app launch that started a process.
	private static let environmentKey = "NEWTERM_LAUNCH"

	/// Unique to this run of the app. Anything tagged with a different one is left over.
	public static let launchID = UUID().uuidString

	/// Added to every shell's environment.
	public static var environmentEntry: String { "\(environmentKey)=\(launchID)" }

	private static let logger = Logger(subsystem: "ws.hbang.Terminal", category: "OrphanReaper")

	/// Kills everything tagged by an earlier launch, and reports how many.
	///
	/// Deliberately not `stop()`'s polite hang-up: these have no terminal left to hang up, and their
	/// shell — the thing that would have reaped them — is long gone.
	@discardableResult
	public static func reapOrphans() -> Int {
		let processes = allProcesses()
		guard !processes.isEmpty else {
			// Process listing is unavailable on some jailbreaks. Nothing to be done, and guessing at
			// pids to kill would be far worse than leaking.
			logger.notice("Couldn’t list processes; skipping orphan cleanup")
			return 0
		}

		let exempt = tmuxDescendants(in: processes)
		var killed = 0
		for process in processes where !exempt.contains(process.pid) {
			guard process.pid != getpid() else {
				continue
			}
			guard tagState(pid: process.pid) == .otherLaunch else {
				continue
			}
			if kill(process.pid, SIGKILL) == 0 {
				killed += 1
			}
		}

		if killed > 0 {
			logger.notice("Cleaned up \(killed) process(es) left by an earlier launch")
		}
		return killed
	}

	// MARK: - Process table

	private struct ProcessInfo {
		var pid: pid_t
		var parentPID: pid_t
		var name: String
	}

	private static func allProcesses() -> [ProcessInfo] {
		var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
		var size = 0
		guard sysctl(&name, 4, nil, &size, nil, 0) == 0, size > 0 else {
			return []
		}

		// Between sizing and reading, processes come and go; ask for a little more than we were told
		// so a burst of new ones doesn't fail the whole call.
		size += MemoryLayout<kinfo_proc>.stride * 32
		var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
		guard sysctl(&name, 4, &buffer, &size, nil, 0) == 0 else {
			return []
		}

		return buffer.prefix(size / MemoryLayout<kinfo_proc>.stride).map { process in
			let comm = process.kp_proc.p_comm
			let name = withUnsafeBytes(of: comm) { bytes in
				String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
			}
			return ProcessInfo(pid: process.kp_proc.p_pid,
												 parentPID: process.kp_eproc.e_ppid,
												 name: name)
		}
	}

	/// tmux and everything under it.
	///
	/// A tmux session outliving the app is the whole point of opening a project in one — it's how a
	/// build or an agent keeps running while the app is away. Reaping those would take the feature
	/// away, so they're the one thing left alone.
	private static func tmuxDescendants(in processes: [ProcessInfo]) -> Set<pid_t> {
		var childrenByParent = [pid_t: [pid_t]]()
		for process in processes {
			childrenByParent[process.parentPID, default: []].append(process.pid)
		}

		var exempt = Set<pid_t>()
		var queue = processes.filter { $0.name.hasPrefix("tmux") }.map(\.pid)
		while let pid = queue.popLast() {
			guard exempt.insert(pid).inserted else {
				// Already seen. Also stops a parent/child cycle — which shouldn't happen, but this loop
				// is not the place to find out the hard way.
				continue
			}
			queue.append(contentsOf: childrenByParent[pid] ?? [])
		}
		return exempt
	}

	/// Whether a process carries a tag from one of our earlier launches.
	///
	/// The raw argument block is searched rather than parsed: it holds the environment, and all that
	/// matters is whether our key is in there with an id that isn't this launch's.
	private enum TagState { case unreadable, untagged, thisLaunch, otherLaunch }

	private static func tagState(pid: pid_t) -> TagState {
		var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
		var size = 0
		guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > 0 else {
			// Not ours to read — a process owned by someone else, or one that just exited.
			return .unreadable
		}

		var buffer = [CChar](repeating: 0, count: size)
		guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0 else {
			return .unreadable
		}

		let data = Data(bytes: buffer, count: size)
		guard let key = "\(environmentKey)=".data(using: .utf8),
					let range = data.range(of: key) else {
			return .untagged
		}

		let value = data[range.upperBound...].prefix(launchID.utf8.count)
		return value == Data(launchID.utf8) ? .thisLaunch : .otherLaunch
	}
}
