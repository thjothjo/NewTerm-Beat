//
//  DeviceLog.swift
//  NewTerm Common
//
//  Temporary on-device instrumentation. Goes into the app's own preferences, because that is the one
//  place on the phone the app is demonstrably able to write — measured, every file path tried,
//  including its own temporary directory, was refused.
//

import Foundation

public enum DeviceLog {

	public static let defaultsKey = "debugLog"

	private static let queue = DispatchQueue(label: "ws.hbang.Terminal.devicelog")
	private static var buffer = [String]()
	private static let formatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm:ss.SSS"
		return formatter
	}()

	public static func write(_ message: @autoclosure () -> String) {
		let line = "\(formatter.string(from: Date())) \(message())"
		queue.async {
			buffer.append(line)
			if buffer.count > 300 {
				buffer.removeFirst(buffer.count - 300)
			}
			UserDefaults.standard.set(buffer, forKey: defaultsKey)
		}
	}

	public static func reset() {
		queue.async {
			buffer.removeAll()
			UserDefaults.standard.removeObject(forKey: defaultsKey)
		}
	}
}
