//
//  SubProcess.swift
//  NewTerm
//
//  Created by Adam Demasi on 9/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import Foundation
import os.log

enum SubProcessIllegalStateError: Error, LocalizedError {
	case alreadyStarted, notStarted
	case openPtyFailed(errno: errno_t)
	case loginTtyFailed(errno: errno_t)
	case forkFailed(errno: errno_t)
	case deallocatedWhileRunning

	private func errorString(errno: errno_t) -> String {
		if let string = strerror(errno) {
			return String(cString: string)
		}
		return String(format: .localize("Unknown (%i)"), errno)
	}

	var errorDescription: String? {
		switch self {
		case .alreadyStarted, .notStarted, .deallocatedWhileRunning:
			return .localize("Internal state error")

		case .openPtyFailed(let errno):
			return String(format: .localize("Couldn’t initialize a terminal. %@"), errorString(errno: errno))

		case .loginTtyFailed(let errno):
			return String(format: .localize("Couldn’t prepare terminal for logging in. %@"), errorString(errno: errno))

		case .forkFailed(let errno):
			return String(format: .localize("Couldn’t start a terminal process. %@"), errorString(errno: errno))
		}
	}
}

enum SubProcessIOError: Error {
	case readFailed(errno: errno_t?)
	case writeFailed(errno: errno_t?)
}

protocol SubProcessDelegate: AnyObject {
	func subProcessDidConnect()
	func subProcess(didReceiveData data: [UTF8Char])
	func subProcess(didDisconnectWithError error: Error?)
	func subProcess(didReceiveError error: Error)
}

public class SubProcess {

	static let loginHelper: String = Bundle.main.path(forAuxiliaryExecutable: "NewTermLoginHelper")!

	static let loginIsShell: Bool = {
		#if targetEnvironment(simulator)
		true
		#else
		// TODO: Temporary workaround for XinaA15
		(try? URL(fileURLWithPath: "/var/Liy/xina").checkResourceIsReachable()) == true
		#endif
	}()

	/// Root of the jailbreak filesystem, when it isn’t at a fixed path.
	///
	/// Rootless jailbreaks put everything under `/var/jb`, so the fixed paths below are enough. roothide
	/// instead installs into a randomised directory and only makes `/var/jb` work for processes it has
	/// injected into — ours isn’t one, so `/var/jb` resolves to the real `/`, where none of the tools we
	/// need exist, and the terminal dies with ENOENT before the shell ever runs.
	///
	/// The app bundle is inside that directory, so its own path is the one dependable way to find it.
	/// On a rootless jailbreak this comes out as `/var/jb`, and on a rootful one as empty — which is
	/// exactly right in both cases.
	/// The jailbreak root the shell runs inside, when there is one. Public because paths printed by the
	/// shell have to be resolved against it before this process can open them.
	public static let jbRoot: String? = {
		let path = Bundle.main.bundlePath
		guard let range = path.range(of: "/Applications/", options: .backwards) else {
			return nil
		}
		var root = String(path[..<range.lowerBound])
		// The bundle path comes back with the /private prefix while everything else on the system uses
		// /var, so strip it or none of the comparisons below line up.
		if root.hasPrefix("/private/var") {
			root = String(root.dropFirst("/private".count))
		}
		return root.isEmpty ? nil : root
	}()

	/// First path that exists, preferring the jailbreak root we found over the well-known ones.
	private static func resolve(_ path: String, fallback: String) -> String {
		let candidates = [jbRoot.map { $0 + path }, "/var/jb" + path, path].compactMap { $0 }
		return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? fallback
	}

	static let login: String = {
		#if targetEnvironment(simulator)
		return "/bin/zsh"
		#elseif targetEnvironment(macCatalyst)
		return "/usr/bin/login"
		#else
		// TODO: Temporary workaround for XinaA15
		if loginIsShell {
			return resolve("/bin/zsh", fallback: "/bin/zsh")
		}
		return resolve("/usr/bin/login", fallback: "/usr/bin/login")
		#endif
	}()

	/// argv[0] the helper insists on, so it knows it was launched by us rather than run by hand.
	static let helperArgv0 = "-NewTermLoginHelper"

	/// What we actually spawn.
	///
	/// Deliberately not `login(1)`: it's setuid root, and an app can't count on being allowed to gain
	/// root through it — on roothide it starts and immediately exits, which surfaces as the terminal
	/// saying the session ended before a single character is drawn. We're already the user login would
	/// switch to and there's nothing to authenticate, so the only thing it was buying us is the
	/// controlling-terminal setup, and that's the helper's job anyway.
	static var launchPath: String {
		#if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
		return login
		#else
		return loginIsShell ? login : loginHelper
		#endif
	}

	static var loginArgv: [String] {
		#if targetEnvironment(simulator)
		return ["zsh", "--login", "-i"]
		#else
		// TODO: Temporary workaround for XinaA15
		if loginIsShell {
			return ["zsh", "--login", "-i"]
		}

		// Interestingly, despite what login(1) seems to imply, it still seems we need to manually
		// handle passing the -q (force hush login) flag. iTerm2 does this, so I guess it’s fine?
		let hushLoginURL = URL(fileURLWithPath: homeDirectory)/".hushlogin"
		let hushLogin = (try? hushLoginURL.checkResourceIsReachable()) == true
		return ["login", "-fp\(hushLogin ? "q" : "")", NSUserName(), loginHelper]
		#endif
	}

	private static let baseEnvp: [String] = [
		"TERM=xterm-256color",
		"COLORTERM=truecolor",
		"TERM_PROGRAM=NewTerm",
		"LC_TERMINAL=NewTerm"
	]

	private struct UserInfo {
		var shell: String
		var homeDirectory: String
	}

	/// `getpwuid_r` stores every string pointer inside its caller-owned buffer, so copy the values
	/// before freeing that buffer. Returning `passwd` itself would return dangling pointers.
	private static var userInfo: UserInfo? {
		var length = Int(sysconf(_SC_GETPW_R_SIZE_MAX))
		if length <= 0 {
			length = 16 * 1024
		}

		while length <= 1024 * 1024 {
			guard let buffer = malloc(length) else {
				return nil
			}
			var pwd = passwd()
			var result: UnsafeMutablePointer<passwd>?
			let status = ie_getpwuid_r(getuid(), &pwd, buffer, length, &result)
			if status == ERANGE {
				free(buffer)
				length *= 2
				continue
			}
			guard status == 0, result != nil else {
				free(buffer)
				return nil
			}

			let shell = pwd.pw_shell.map { String(cString: $0) } ?? ""
			let homeDirectory = pwd.pw_dir.map { String(cString: $0) } ?? ""
			free(buffer)
			return UserInfo(shell: shell, homeDirectory: homeDirectory)
		}
		return nil
	}

	static var shell: String {
		// The shell from the passwd entry is a jailbreak path too — `/usr/bin/zsh` means the one inside
		// the jailbreak root, not the (nonexistent) system one. The helper execs this, so if it’s wrong
		// the terminal opens and immediately dies.
		let fromPasswd = userInfo?.shell ?? ""
		#if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
		return fromPasswd.isEmpty ? "/bin/bash" : fromPasswd
		#else
		// The passwd entry can come back empty, and falling straight to /bin/bash then gives a shell
		// nobody configured. zsh is what the jailbreak sets up and what the user's dotfiles expect.
		for candidate in [fromPasswd, "/usr/bin/zsh", "/bin/zsh", "/bin/bash", "/bin/sh"] where !candidate.isEmpty {
			let resolved = resolve(candidate, fallback: "")
			if !resolved.isEmpty {
				return resolved
			}
		}
		return "/bin/sh"
		#endif
	}

	/// The user's home as the *shell* understands it.
	///
	/// Deliberately left exactly as the passwd entry gives it. On roothide that comes back inside the
	/// jailbreak directory, and it has to stay that way: the shell runs in roothide's view, where that
	/// directory is plain `/var/mobile`, while the real `/var/mobile` shows up as
	/// `/rootfs/private/var/mobile`. Point the shell at the real one and every prompt reads
	/// `yachohaiki:/rootfs/private/var/mobile mobile%` instead of `yachohaiki:~ mobile%`, and `~`
	/// stops expanding to anything useful.
	public static var homeDirectory: String {
		let homeDirectory = userInfo?.homeDirectory ?? ""
		return homeDirectory.isEmpty ? NSHomeDirectory() : homeDirectory
	}

	weak var delegate: SubProcessDelegate?

	private var childPID: pid_t?
	private var fileDescriptor: Int32?

	private let queue = DispatchQueue(label: "ws.hbang.Terminal.io-queue")
	private static let spawnLock = NSLock()
	private var readSource: DispatchSourceRead?
	private var signalSource: DispatchSourceProcess?

	private let logger = Logger(subsystem: "ws.hbang.Terminal", category: "SubProcess")

	var screenSize = ScreenSize.default {
		didSet { updateWindowSize() }
	}

	func start(initialDirectory: String? = nil) throws {
		if childPID != nil {
			throw SubProcessIllegalStateError.alreadyStarted
		}

		// Initialise the pty
		var windowSize = screenSize.windowSize
		var fds = (primary: Int32(), replica: Int32())
		if openpty(&fds.primary, &fds.replica, nil, nil, &windowSize) != 0 {
			// Opening pty failed.
			let error = errno
			logger.error("openpty() failed: \(error, format: .darwinErrno)")
			throw SubProcessIllegalStateError.openPtyFailed(errno: error)
		}

		fileDescriptor = fds.primary

		var actions: posix_spawn_file_actions_t!
		posix_spawn_file_actions_init(&actions)
		posix_spawn_file_actions_adddup2(&actions, fds.replica, STDIN_FILENO)
		posix_spawn_file_actions_adddup2(&actions, fds.replica, STDOUT_FILENO)
		posix_spawn_file_actions_adddup2(&actions, fds.replica, STDERR_FILENO)
		defer { posix_spawn_file_actions_destroy(&actions) }

		// `chdir` is process-wide. Serialise the short spawn window and restore our original directory
		// immediately afterwards so one terminal can't change where another session or app code starts.
		Self.spawnLock.lock()
		let originalDirectory = FileManager.default.currentDirectoryPath
		defer {
			if Self.loginIsShell {
				_ = chdir(originalDirectory)
			}
			Self.spawnLock.unlock()
		}

		// TODO: At some point, come up with some way to keep track of working directory changes.
		// When opening a new tab, we can switch straight to the previous tab’s working directory.
		let argv: [UnsafeMutablePointer<CChar>?]
		if Self.loginIsShell {
			argv = Self.loginArgv.cStringArray
			let directory = initialDirectory ?? Self.homeDirectory
			if chdir(directory) != 0 {
				logger.error("chdir(\(directory, privacy: .private)) failed: \(errno, format: .darwinErrno)")
				_ = chdir(Self.homeDirectory)
			}
		} else {
			argv = ([Self.helperArgv0, initialDirectory ?? Self.homeDirectory, Self.shell]).cStringArray
		}
		// COLUMNS and LINES are dropped rather than inherited: a shell that finds them already set in
		// its environment believes them over the pty, so whatever size our own process happened to be
		// launched with would override the real terminal — leaving zsh wrapping at the wrong column
		// and printing its `%` end-of-line marker before every prompt.
		let inherited = ProcessInfo.processInfo.environment
			.filter { $0.key != "COLUMNS" && $0.key != "LINES" }
			.map { "\($0)=\($1)" }
		let envp = (inherited + Self.baseEnvp + [
			"LANG=\(localeCode)",
			// Inherited by everything the shell starts, which is what lets a later launch recognise
			// what this one left behind. See OrphanReaper.
			OrphanReaper.environmentEntry
		]).cStringArray

		defer {
			argv.deallocate()
			envp.deallocate()
		}

		var pid = pid_t()
		let result = ie_posix_spawn(&pid, Self.launchPath, &actions, nil, argv, envp)
		close(fds.replica)
		if result != 0 {
			// Fork failed.
			close(fds.primary)
			fileDescriptor = nil
			logger.error("posix_spawn() failed: \(result, format: .darwinErrno)")
			throw SubProcessIllegalStateError.forkFailed(errno: result)
		}

		logger.debug("Process forked: \(pid)")
		childPID = pid

		// Go ahead and plug a file handle into the child tty.
		readSource = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor!, queue: queue)
		readSource?.setEventHandler { [weak self] in
			self?.handleRead()
		}
		signalSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
		signalSource?.setEventHandler { [weak self] in
			try? self?.stop()
		}

		readSource?.activate()
		signalSource?.activate()
		delegate!.subProcessDidConnect()
	}

	/// Ends the shell the way closing a terminal window does, so it takes its jobs down with it.
	///
	/// `SIGKILL` on the shell alone is what left `claude`, `codex` and the like running forever: the
	/// shell died without ever getting to hang up its own jobs, and every one of them was re-parented
	/// to launchd, holding its memory and its pid for the rest of the boot. A terminal emulator's job
	/// here is to hang up the line — `SIGHUP` — and let the shell do the reaping it already knows how
	/// to do.
	///
	/// Both the foreground job and the shell get it. A job-control shell puts each job in its own
	/// process group, so signalling only the shell's group misses whatever is actually running.
	private func hangUp(childPID: pid_t) {
		if let fileDescriptor = fileDescriptor {
			let foreground = tcgetpgrp(fileDescriptor)
			// Not our own group, and not the shell's own — that one is covered below, and `-1` would
			// mean every process we're allowed to signal.
			if foreground > 1 && foreground != getpgrp() {
				kill(-foreground, SIGHUP)
			}
		}
		kill(childPID, SIGHUP)

		// Long enough for a shell to hang up its jobs and exit, short enough not to be a stall the user
		// can feel when closing a tab. A shell that ignores it gets killed outright — but its jobs will
		// have had the signal by then either way.
		let deadline = Date().addingTimeInterval(Self.hangUpGracePeriod)
		while kill(childPID, 0) == 0 && Date() < deadline {
			usleep(20_000)
		}
		if kill(childPID, 0) == 0 {
			logger.debug("Shell \(childPID) ignored SIGHUP; killing")
			kill(childPID, SIGKILL)
		}
	}

	private static let hangUpGracePeriod: TimeInterval = 0.5

	func stop(fromError: Bool = false) throws {
		guard let childPID = childPID else {
			throw SubProcessIllegalStateError.notStarted
		}

		if kill(childPID, 0) == 0 {
			hangUp(childPID: childPID)

			var status = Int32()
			waitpid(childPID, &status, WUNTRACED)

			logger.debug("Process stopped with exit code: \(WEXITSTATUS(status))")
		}

		if let fileDescriptor = fileDescriptor {
			close(fileDescriptor)
		}

		self.childPID = nil
		fileDescriptor = nil
		readSource?.cancel()
		readSource = nil
		signalSource?.cancel()
		signalSource = nil

		if !fromError {
			// nil error means disconnected due to user request
			DispatchQueue.main.async {
				self.delegate?.subProcess(didDisconnectWithError: nil)
			}
		}
	}

	private func handleRead() {
		guard let fileDescriptor = fileDescriptor else {
			return
		}

		let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(BUFSIZ), alignment: MemoryLayout<CChar>.alignment)
		let bytesRead = read(fileDescriptor, buffer, Int(BUFSIZ))
		switch bytesRead {
		case -1:
			let code = errno
			switch code {
			case EAGAIN, EINTR:
				// Ignore, we’ll be called again when the source is ready.
				break

			default:
				// A permanent read error would otherwise leave the dispatch source active and report the
				// same failure repeatedly.
				try? stop(fromError: true)
				DispatchQueue.main.async {
					self.delegate?.subProcess(didDisconnectWithError: SubProcessIOError.readFailed(errno: code))
				}
			}

		case 0:
			// Zero-length data is an indicator of EOF. This can happen if the user exits the terminal by
			// typing `exit` or ^D, or if there’s a catastrophic failure (e.g. /bin/login is broken).
			try? stop(fromError: false)

		default:
			// Read from output and notify delegate.
			let bytes = buffer.bindMemory(to: UTF8Char.self, capacity: bytesRead)
			let data = Array(UnsafeBufferPointer(start: bytes, count: bytesRead))
			delegate?.subProcess(didReceiveData: data)
		}
		buffer.deallocate()
	}

	func write(data: [UTF8Char]) {
		queue.async {
			guard let fileDescriptor = self.fileDescriptor else {
				return
			}
			if let code = writeAll(fileDescriptor: fileDescriptor, data: data) {
				DispatchQueue.main.async {
					self.delegate?.subProcess(didReceiveError: SubProcessIOError.writeFailed(errno: code))
				}
			}
		}
	}

	private var localeCode: String {
		// Try and find a locale suitable for the user. Use en_US.UTF-8 as fallback.
		// TODO: There has to be a better way to get a gettext locale out of the Apple locale. For
		// instance, a phone set to Simplified Chinese but a region of Australia will only have the
		// language zh_AU… which isn’t a thing. But gettext only has languages in country pairs, no
		// safe generic fallbacks exist, like zh-Hans in this case.
		var languages = Locale.preferredLanguages
		let preferredLocale = Preferences.shared.preferredLocale
		if preferredLocale != "",
			 Locale(identifier: preferredLocale).languageCode != nil {
			languages.insert(preferredLocale, at: 0)
		}

		for language in languages {
			let locale = Locale(identifier: language)
			if let languageCode = locale.languageCode,
				 let regionCode = locale.regionCode {
				let identifier = "\(languageCode)_\(regionCode).UTF-8"
				let url = URL(fileURLWithPath: "/usr/share/locale")/identifier
				if (try? url.checkResourceIsReachable()) == true {
					return identifier
				}
			}
		}
		return "en_US.UTF-8"
	}

	private func updateWindowSize() {
		guard let fileDescriptor = fileDescriptor else {
			return
		}

		var windowSize = screenSize.windowSize
		if ioctl(fileDescriptor, TIOCSWINSZ, &windowSize) == -1 {
			let error = errno
			logger.error("Setting screen size failed: \(error, format: .darwinErrno)")
		}
	}

	/// Re-applies the window size and tells the foreground process group about it explicitly.
	///
	/// Setting the size isn’t enough on its own during startup. `login` hands off to the shell, and a
	/// size change during that handoff has no foreground process group to signal yet — so the shell
	/// comes up still believing the pty is 80×25, which is what left zsh printing its `%`
	/// end-of-line marker on every prompt and wrapping long lines at the wrong column. By the time
	/// the shell has produced output it definitely owns the terminal, so a poke then does land.
	func notifyWindowSizeChanged() {
		guard let fileDescriptor = fileDescriptor else {
			return
		}

		updateWindowSize()

		let processGroup = tcgetpgrp(fileDescriptor)
		if processGroup > 0 {
			kill(-processGroup, SIGWINCH)
		}
	}

	deinit {
		if childPID != nil {
			logger.error("Illegal state - SubProcess deallocated while still running")
		}

		try? stop(fromError: true)
	}

}
