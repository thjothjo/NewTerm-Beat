//
//  Darwin+Additions.swift
//  NewTerm (iOS)
//
//  Created by Adam Demasi on 19/7/2022.
//

import Foundation
import Darwin

// Macros copied from <sys/wait.h>
@inline(__always)
fileprivate func _WSTATUS(_ value: Int32) -> Int32 {
	return value & 0177
}

@inline(__always)
func WIFEXITED(_ value: Int32) -> Bool {
	return _WSTATUS(value) == 0
}

@inline(__always)
func WEXITSTATUS(_ value: Int32) -> Int32 {
	return (value >> 8) & 0xff
}

/// Writes the complete payload, handling the short writes and interruptions permitted by write(2).
/// Returns errno on failure so the caller can report it on the appropriate queue.
func writeAll(fileDescriptor: Int32, data: [UInt8]) -> errno_t? {
	data.withUnsafeBytes { rawBuffer in
		guard let baseAddress = rawBuffer.baseAddress else {
			return nil
		}
		var offset = 0
		while offset < rawBuffer.count {
			let count = Darwin.write(fileDescriptor,
											 baseAddress.advanced(by: offset),
											 rawBuffer.count - offset)
			if count > 0 {
				offset += count
				continue
			}
			if count == 0 {
				return EIO
			}

			switch errno {
			case EINTR:
				continue
			case EAGAIN:
				var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
				var pollResult: Int32
				repeat {
					pollResult = Darwin.poll(&descriptor, 1, -1)
				} while pollResult == -1 && errno == EINTR
				if pollResult > 0 {
					continue
				}
				return errno == 0 ? EIO : errno
			default:
				return errno
			}
		}
		return nil
	}
}
