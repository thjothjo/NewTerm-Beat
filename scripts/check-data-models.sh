#!/bin/bash
# Regression checks for disk-backed user data and the bounded terminal-output tail.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/shortcuts" "$WORK/tail"

cat > "$WORK/shortcuts/Stub.swift" <<'SWIFT'
import Foundation

enum SubProcess {
	static var homeDirectory = NSHomeDirectory()
}

extension String {
	static func localize(_ key: String, bundle: Bundle? = nil, tableName: String? = nil, comment: String = "") -> String {
		key
	}
}
SWIFT

cat > "$WORK/shortcuts/main.swift" <<'SWIFT'
import Foundation

func check(_ condition: Bool, _ message: String) {
	if !condition {
		print("FAIL: \(message)")
		exit(1)
	}
}

let manager = FileManager.default
let home = NSTemporaryDirectory() + "shortcut-check-\(UUID().uuidString)"
SubProcess.homeDirectory = home
defer { try? manager.removeItem(atPath: home) }
try manager.createDirectory(at: AIShortcutStore.fileURL.deletingLastPathComponent(),
													withIntermediateDirectories: true)

let invalid = Data("{ still-being-edited".utf8)
try invalid.write(to: AIShortcutStore.fileURL)
do {
	try AIShortcutStore.add(AIShortcut(name: "Safe", command: "safe", kind: .skill))
	check(false, "overwrote malformed shortcuts JSON")
} catch {}
check(try Data(contentsOf: AIShortcutStore.fileURL) == invalid, "changed malformed shortcuts JSON")

try manager.removeItem(at: AIShortcutStore.fileURL)
try AIShortcutStore.add(AIShortcut(name: "Safe", command: "safe", kind: .skill))
check(AIShortcutStore.shortcuts().map(\.name) == ["Safe"], "could not create a new shortcuts file")
print("shortcuts ok")
SWIFT

swiftc -o "$WORK/check-shortcuts" "$WORK/shortcuts/main.swift" "$WORK/shortcuts/Stub.swift" \
	Common/Controllers/AIShortcutStore.swift
"$WORK/check-shortcuts"

cat > "$WORK/tail/Stub.swift" <<'SWIFT'
import Foundation

final class Preferences {
	static let shared = Preferences()
	var saveScrollback = true
}
SWIFT

cat > "$WORK/tail/main.swift" <<'SWIFT'
import Foundation

func check(_ condition: Bool, _ message: String) {
	if !condition {
		print("FAIL: \(message)")
		exit(1)
	}
}

var tail = ByteTailBuffer(capacity: 16)
for value in UInt8(0)..<40 {
	tail.append([value])
}
check(tail.data == Data(24..<40), "wrong bounded tail: \(Array(tail.data))")
tail.append(Array(repeating: 0xaa, count: 32))
check(tail.data == Data(repeating: 0xaa, count: 16), "large append did not replace the tail")
print("tail ok")
SWIFT

swiftc -o "$WORK/check-tail" "$WORK/tail/main.swift" "$WORK/tail/Stub.swift" \
	Common/Controllers/ScrollbackStore.swift
"$WORK/check-tail"
