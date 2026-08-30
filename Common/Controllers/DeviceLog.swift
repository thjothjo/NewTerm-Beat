//
//  DeviceLog.swift
//  NewTerm Common
//
//  Temporary on-device instrumentation. Writes to a file because the phone has no console we can
//  read over SSH while the app is in the user's hands.
//

import Foundation

public enum DeviceLog {

	/// Tried in order. The first one that accepts a write is kept.
	public static let paths = ["/var/mobile/newterm-beat.log",
														 "/var/tmp/newterm-beat.log",
														 NSTemporaryDirectory() + "newterm-beat.log"]

	private static var resolvedPath: String?

	private static let queue = DispatchQueue(label: "ws.hbang.Terminal.devicelog")
	private static let formatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm:ss.SSS"
		return formatter
	}()

	public static func write(_ message: @autoclosure () -> String) {
		let line = "\(formatter.string(from: Date())) \(message())\n"
		queue.async {
			guard let data = line.data(using: .utf8) else {
				return
			}
			for path in resolvedPath.map({ [$0] }) ?? paths {
				let url = URL(fileURLWithPath: path)
				if let handle = try? FileHandle(forWritingTo: url) {
					handle.seekToEndOfFile()
					handle.write(data)
					try? handle.close()
					resolvedPath = path
					return
				}
				if (try? data.write(to: url)) != nil {
					resolvedPath = path
					return
				}
			}
		}
	}
}
