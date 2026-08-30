//
//  DeviceLog.swift
//  NewTerm Common
//
//  Temporary on-device instrumentation. Writes to a file because the phone has no console we can
//  read over SSH while the app is in the user's hands.
//

import Foundation

public enum DeviceLog {

	public static let path = "/var/mobile/newterm-beat.log"

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
			let url = URL(fileURLWithPath: path)
			if let handle = try? FileHandle(forWritingTo: url) {
				handle.seekToEndOfFile()
				handle.write(data)
				try? handle.close()
			} else {
				try? data.write(to: url)
			}
		}
	}
}
