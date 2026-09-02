#!/bin/bash
# Exercises the real session and project persistence sources against isolated identifiers/directories.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/session" "$WORK/project"

cat > "$WORK/session/main.swift" <<'SWIFT'
import Foundation

func check(_ condition: Bool, _ message: String) {
	if !condition {
		print("FAIL: \(message)")
		exit(1)
	}
}

let store = SessionStore.shared
let prefix = "regression-\(UUID().uuidString)"
let firstID = prefix + "-first"
let secondID = prefix + "-second"
let discardedID = prefix + "-discarded"
defer {
	store.discard(identifier: firstID)
	store.discard(identifier: secondID)
	store.discard(identifier: discardedID)
}

let first = SessionState(tabs: [SessionTabState(projectPath: "/first", title: "first")], selectedIndex: 0)
let second = SessionState(tabs: [SessionTabState(projectPath: "/second", title: "second")], selectedIndex: 0)
let split = SessionTabState(projectPath: "/split", title: "split", paneIDs: ["left", "right"])
check(split.paneIDs == ["left", "right"], "split pane ids were not retained")

// Snapshots written before pane ids existed still decode as one pane using the tab id.
let legacy = Data(#"{"id":"legacy","projectPath":null,"title":"old"}"#.utf8)
let decodedLegacy = try JSONDecoder().decode(SessionTabState.self, from: legacy)
check(decodedLegacy.paneIDs == ["legacy"], "legacy session did not default to one pane")
store.setNeedsSave(first, identifier: firstID)
store.setNeedsSave(second, identifier: secondID)
usleep(700_000)
check(store.load(identifier: firstID) == first, "saving the second scene cancelled the first")
check(store.load(identifier: secondID) == second, "second scene was not saved")
check(store.discard(identifier: secondID) == second, "discard did not return the removed scene")
check(store.load(identifier: secondID) == nil, "discard left the removed scene on disk")

store.setNeedsSave(first, identifier: discardedID)
store.discard(identifier: discardedID)
usleep(700_000)
check(store.load(identifier: discardedID) == nil, "a queued save resurrected a discarded scene")

print("session ok")
SWIFT

swiftc -o "$WORK/check-session" "$WORK/session/main.swift" Common/Controllers/SessionStore.swift
"$WORK/check-session"

cat > "$WORK/project/Stub.swift" <<'SWIFT'
import Foundation

final class Preferences {
	static let shared = Preferences()
	var projectsDirectory = ""
	var iCloudFolderPath = ""
	var iCloudFolderBookmark = Data()
	var useTmuxForProjects = false
}

enum SubProcess {
	static var homeDirectory = NSHomeDirectory()
}

extension String {
	static func localize(_ key: String, bundle: Bundle? = nil, tableName: String? = nil, comment: String = "") -> String {
		key
	}
}
SWIFT

cat > "$WORK/project/main.swift" <<'SWIFT'
import Foundation

func check(_ condition: Bool, _ message: String) {
	if !condition {
		print("FAIL: \(message)")
		exit(1)
	}
}

let manager = FileManager.default
let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
	.appendingPathComponent("project-check-\(UUID().uuidString)", isDirectory: true)
defer { try? manager.removeItem(at: base) }
let cloud = base.appendingPathComponent("cloud", isDirectory: true)
let sourceA = base.appendingPathComponent("a/demo", isDirectory: true)
let sourceB = base.appendingPathComponent("b/demo", isDirectory: true)
try manager.createDirectory(at: sourceA, withIntermediateDirectories: true)
try manager.createDirectory(at: sourceB, withIntermediateDirectories: true)
try manager.createDirectory(at: cloud, withIntermediateDirectories: true)
try ProjectManager.selectICloudFolder(cloud)
check(!Preferences.shared.iCloudFolderBookmark.isEmpty, "selected folder bookmark was not saved")
check(ProjectManager.iCloudUnavailableReason() == nil, "selected folder was incorrectly reported inaccessible")

let projectRoot = base.appendingPathComponent("projects", isDirectory: true)
Preferences.shared.projectsDirectory = projectRoot.path
do {
	_ = try ProjectManager.createProject(named: "../escaped")
	check(false, "project name escaped the projects root")
} catch {}
check(!manager.fileExists(atPath: base.appendingPathComponent("escaped").path),
			"invalid project created a directory outside the projects root")

let projectA = Project(name: "demo", url: sourceA, lastModified: Date())
let projectB = Project(name: "demo", url: sourceB, lastModified: Date())
let markerA = sourceA.appendingPathComponent("marker")
let markerB = sourceB.appendingPathComponent("marker")
let destinationMarker = cloud.appendingPathComponent("demo/marker")

try "old-a".write(to: markerA, atomically: true, encoding: .utf8)
try ProjectManager.exportToICloud(projectA)
check(try String(contentsOf: destinationMarker, encoding: .utf8) == "old-a", "initial export failed")

// Two callers must use independent staging paths. Both complete; the final destination may be either
// complete source, but never missing, merged or half-written.
for iteration in 0..<20 {
	let a = "a-\(iteration)"
	let b = "b-\(iteration)"
	try a.write(to: markerA, atomically: true, encoding: .utf8)
	try b.write(to: markerB, atomically: true, encoding: .utf8)

	let group = DispatchGroup()
	let lock = NSLock()
	var failures = [Error]()
	for project in [projectA, projectB] {
		group.enter()
		DispatchQueue.global().async {
			do {
				try ProjectManager.exportToICloud(project)
			} catch {
				lock.lock()
				failures.append(error)
				lock.unlock()
			}
			group.leave()
		}
	}
	group.wait()
	check(failures.isEmpty, "concurrent export failed: \(failures)")
	let value = try String(contentsOf: destinationMarker, encoding: .utf8)
	check(value == a || value == b, "concurrent export left partial data: \(value)")
}

print("project ok")
SWIFT

swiftc -o "$WORK/check-project" "$WORK/project/main.swift" "$WORK/project/Stub.swift" \
	Common/Controllers/ProjectManager.swift
"$WORK/check-project"
