//
//  TerminalSceneDelegate.swift
//  NewTerm
//
//  Created by Adam Demasi on 16/6/19.
//  Copyright © 2019 HASHBANG Productions. All rights reserved.
//

import UIKit
import NewTermCommon

extension NSUserActivity {
	static let terminalScene = NSUserActivity(activityType: TerminalSceneDelegate.activityType)
}

class TerminalSceneDelegate: UIResponder, UIWindowSceneDelegate, IdentifiableSceneDelegate {

	static let activityType = "ws.hbang.Terminal.TerminalSceneActivity"

	var window: UIWindow?

	private var rootViewController: RootViewController! {
		(window?.rootViewController as? UINavigationController)?.viewControllers.first as? RootViewController
	}

	override init() {
		super.init()

		#if DEBUG
		// What an `ssh://` link is allowed to turn into. The two refused ones are option injection —
		// `-oProxyCommand=` runs a shell command — reached through either the user or the host field.
		assert(SSHConfig.connectCommand(user: nil, host: "-oProxyCommand=evil", port: nil) == nil)
		assert(SSHConfig.connectCommand(user: "-oProxyCommand=x", host: "h", port: nil) == nil)
		assert(SSHConfig.connectCommand(user: "me", host: "h", port: 2222) == "ssh -p 2222 -- 'me@h'")
		assert(SSHConfig.connectCommand(user: nil, host: "it's", port: 22) == "ssh -- 'it'\\''s'")
		#endif

		NotificationCenter.default.addObserver(self, selector: #selector(preferencesUpdated), name: Preferences.didChangeNotification, object: nil)
	}

	func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
		guard let scene = scene as? UIWindowScene else {
			return
		}

		window = UIWindow(windowScene: scene)
		window!.tintColor = .tint
		let restored = SessionStore.shared.load(identifier: session.persistentIdentifier)
		let rootViewController = RootViewController(restoring: restored)
		if let activity = connectionOptions.userActivities.first(where: { $0.activityType == Self.activityType }),
			 let command = activity.userInfo?["sshCommand"] as? String {
			rootViewController.initialCommand = command
		}
		window!.rootViewController = UINavigationController(rootViewController: rootViewController)
		window!.makeKeyAndVisible()

		scene.title = .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")

		#if targetEnvironment(macCatalyst)
		scene.titlebar?.separatorStyle = .none
		scene.titlebar?.toolbarStyle = .unifiedCompact
		#endif

		preferencesUpdated()
	}

	func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
		for context in URLContexts {
			let url = context.url
			switch url.scheme {
			case "ssh":
				createWindow(asTab: true, openingURL: url)

			default: break
			}
		}
	}

	// MARK: - Window management

	func createWindow(asTab: Bool, openingURL url: URL? = nil) {
		// Handle SSH URL
		var sshCommand: String?
		if let url = url,
			 let host = url.host,
			 url.scheme == "ssh" {
			sshCommand = SSHConfig.connectCommand(user: url.user, host: host, port: url.port)
		}

		if UIApplication.shared.supportsMultipleScenes {
			let options = UIScene.ActivationRequestOptions()
			#if targetEnvironment(macCatalyst)
			if asTab {
				options.requestingScene = window!.windowScene
			}
			options.collectionJoinBehavior = asTab ? .preferred : .disallowed
			#else
			options.requestingScene = window!.windowScene
			#endif

			let activity = NSUserActivity(activityType: Self.activityType)
			if let sshCommand = sshCommand {
				activity.userInfo = ["sshCommand": sshCommand]
			}

			UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity, options: options, errorHandler: nil)
		} else {
			if let sshCommand = sshCommand {
				rootViewController.initialCommand = sshCommand
			}
			rootViewController.addTerminal()
		}
	}

	@objc func removeWindow() {
		UIApplication.shared.requestSceneSessionDestruction(window!.windowScene!.session, options: nil, errorHandler: nil)
	}

	// MARK: - Preferences

	@objc private func preferencesUpdated() {
		let preferences = Preferences.shared
		// Following the system means leaving the window alone so it can — overriding the style would
		// pin it, and then the "system" it's meant to follow never changes. Otherwise the window is
		// forced to match the chosen theme's light/dark, so an SF Symbol or a sheet drawn over the
		// terminal doesn't come up in the wrong appearance.
		window?.overrideUserInterfaceStyle = preferences.followsSystemAppearance
			? .unspecified
			: preferences.userInterfaceStyle
	}

	// MARK: - Updates

	func handleUpdateAvailable(_ response: UpdateCheckResponse) {
		guard let viewController = window?.rootViewController else {
			return
		}

		let infoPlist = Bundle.main.infoDictionary!
		let appVersion = infoPlist["CFBundleShortVersionString"] as! String

		let alertController = UIAlertController(title: "Update Available",
																						message: "Version \(response.versionString) is available to install. You’re currently using version \(appVersion).",
																						preferredStyle: .alert)
		alertController.addAction(UIAlertAction(title: "Dismiss", style: .cancel, handler: nil))
		alertController.addAction(UIAlertAction(title: "Download", style: .default, handler: { _ in
			UIApplication.shared.open(URL(string: response.url)!, options: [:], completionHandler: nil)
		}))
		viewController.present(alertController, animated: true, completion: nil)
	}

}
