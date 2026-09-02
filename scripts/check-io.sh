#!/bin/bash
# Forces the real write helper through a payload larger than a socket's send buffer, where one
# write(2) cannot complete the request.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

func check(_ condition: Bool, _ message: String) {
	if !condition {
		print("FAIL: \(message)")
		exit(1)
	}
}

var descriptors = [Int32](repeating: -1, count: 2)
check(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0, "socketpair")
defer {
	close(descriptors[0])
	close(descriptors[1])
}
var sendBuffer: Int32 = 4096
setsockopt(descriptors[0], SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout.size(ofValue: sendBuffer)))

let expected = [UInt8](repeating: 0x5a, count: 2 * 1024 * 1024)
let group = DispatchGroup()
let lock = NSLock()
var received = [UInt8]()
group.enter()
DispatchQueue.global().async {
	var buffer = [UInt8](repeating: 0, count: 8192)
	while received.count < expected.count {
		let count = read(descriptors[1], &buffer, buffer.count)
		if count <= 0 { break }
		lock.lock()
		received.append(contentsOf: buffer.prefix(count))
		lock.unlock()
	}
	group.leave()
}

let error = writeAll(fileDescriptor: descriptors[0], data: expected)
shutdown(descriptors[0], SHUT_WR)
group.wait()
check(error == nil, "writeAll failed with errno \(error ?? -1)")
check(received == expected, "wrote \(received.count) of \(expected.count) bytes")
print("io ok")
SWIFT

swiftc -o "$WORK/check" "$WORK/main.swift" Common/Extensions/Darwin+Additions.swift
"$WORK/check"
