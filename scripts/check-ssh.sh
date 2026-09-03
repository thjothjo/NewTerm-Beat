#!/bin/bash
# Checks the two things in ~/.ssh that this app writes to: the config, and the keys.
#
# Both rewrite files the user owns and that ssh depends on, so the risk isn't a wrong pixel — it's
# someone's ProxyJump quietly disappearing, or a key landing world-readable and ssh refusing it.
# There's no test target in the project, so this compiles the real sources against stubs for the few
# things they use from the rest of NewTermCommon, and runs them against a temporary home.
#
#   ./scripts/check-ssh.sh
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/Stub.swift" <<'SWIFT'
import Foundation

// What SSHConfig.swift and SSHKeys.swift use from the rest of NewTermCommon.
class SubProcess {
	static var homeDirectory = NSHomeDirectory()
}

enum AICatalog {
	// The Mac's own OpenSSH, so `generate` and `recoverPublicKey` really run.
	static var binaryDirectories = ["/usr/bin", "/bin"]
}

extension String {
	static func localize(_ key: String, bundle: Bundle? = nil, tableName: String? = nil, comment: String = "") -> String {
		key
	}
}

// Stands in for the C shim the app uses because posix_spawn is marked unavailable in the iOS SDK.
func ie_posix_spawn(_ pid: UnsafeMutablePointer<pid_t>?,
										_ path: UnsafePointer<CChar>,
										_ fileActions: UnsafePointer<posix_spawn_file_actions_t?>?,
										_ attrp: UnsafePointer<posix_spawnattr_t?>?,
										_ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>,
										_ envp: UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
	posix_spawn(pid, path, fileActions, attrp, argv, envp)
}
SWIFT

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

func check(_ condition: Bool, _ message: String) {
	if !condition {
		print("FAIL: \(message)")
		exit(1)
	}
}

let manager = FileManager.default
let home = NSTemporaryDirectory() + "sshcheck-\(getpid())"
SubProcess.homeDirectory = home
defer { try? manager.removeItem(atPath: home) }

// MARK: - The config

let original = """
# my hosts
Host web
  HostName 10.0.0.1
  User root
  ProxyJump bastion

Match host *.internal
  User deploy
  ProxyCommand ssh gateway -W %h:%p

# the box in the loft
Host nas nas.local
  HostName 192.168.1.9
  Port 2222

Host * !blocked
  ServerAliveInterval 60
"""

try manager.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
try original.write(toFile: home + "/.ssh/config", atomically: true, encoding: .utf8)

func config() throws -> String { try String(contentsOfFile: home + "/.ssh/config", encoding: .utf8) }

let hosts = SSHConfig.hosts()
check(hosts.map(\.name) == ["web", "nas"], "wildcard or negated pattern listed as a host: \(hosts.map(\.name))")
check(hosts[0].detail == "root@10.0.0.1", "detail: \(hosts[0].detail)")
check(hosts[1].detail == "192.168.1.9:2222", "detail with port: \(hosts[1].detail)")

// Names and ports become ssh_config syntax, so reject duplicates and values that would make a
// different entry or an unusable destination.
for invalid in [
	SSHHost(name: "web"),
	SSHHost(name: "bad name"),
	SSHHost(name: "bad\nHost evil"),
	SSHHost(name: "bad-port", port: "70000")
] {
	do {
		try SSHConfig.addHost(invalid)
		check(false, "accepted invalid or duplicate host: \(invalid)")
	} catch {}
}
check(try config() == original, "an invalid host changed the config")

var duplicateRename = hosts[1]
duplicateRename.name = "web"
do {
	try SSHConfig.updateHost(hosts[1], to: duplicateRename)
	check(false, "renamed a host over an existing alias")
} catch {}
check(try config() == original, "a duplicate rename changed the config")

// URL fields are untrusted shell input. They must each stay inside one argument, options must
// precede the destination so ssh doesn't treat them as a remote command, and `--` must close the
// option list so a destination can never be read as one.
let safeURLCommand = SSHConfig.connectCommand(user: "x; touch /tmp/pwned", host: "example.com", port: 2200)
check(safeURLCommand == "ssh -p 2200 -- 'x; touch /tmp/pwned@example.com'",
			"unsafe URL command: \(String(describing: safeURLCommand))")

// A destination that would still look like an option is refused rather than handed to ssh.
check(SSHConfig.connectCommand(user: nil, host: "-oProxyCommand=touch /tmp/pwned", port: nil) == nil,
			"an option-shaped host was turned into a command")
check(SSHConfig.connectCommand(user: nil, host: "", port: nil) == nil, "an empty host made a command")

// The saved-host form quotes and closes the option list the same way.
check(SSHConfig.connectCommand(for: SSHHost(name: "web; touch /tmp/pwned")) == "ssh -- 'web; touch /tmp/pwned'",
			"unsafe saved-host command")

// An edit keeps what it doesn't model, and the comment belonging to the next entry.
var web = hosts[0]
web.user = "admin"
web.port = "2200"
web.identityFile = "~/.ssh/id_ed25519"
try SSHConfig.updateHost(hosts[0], to: web)
var text = try config()
check(text.contains("ProxyJump bastion"), "dropped an option it doesn't model:\n\(text)")
check(text.contains("Match host *.internal\n  User deploy\n  ProxyCommand ssh gateway -W %h:%p"),
			"changed the Match block:\n\(text)")
check(text.contains("# the box in the loft"), "ate the next entry's comment:\n\(text)")
check(text.contains("  User admin"), "didn't write the new user:\n\(text)")
check(!text.contains("User root"), "left the old user behind:\n\(text)")
check(text.contains("  IdentityFile ~/.ssh/id_ed25519"), "didn't write the key:\n\(text)")
check(text.contains("Host *"), "lost the wildcard defaults:\n\(text)")

// Saving twice doesn't repeat the options.
try SSHConfig.updateHost(web, to: web)
text = try config()
check(text.components(separatedBy: "IdentityFile").count == 2, "repeated an option:\n\(text)")

// Renaming keeps the entry's other patterns.
var nas = SSHConfig.hosts()[1]
let oldNas = nas
nas.name = "storage"
try SSHConfig.updateHost(oldNas, to: nas)
text = try config()
check(text.contains("Host storage nas.local"), "rename lost the second pattern:\n\(text)")

// Adding, then deleting, leaves the rest of the file alone.
try SSHConfig.addHost(SSHHost(name: "vps", hostName: "203.0.113.5", user: "yang"))
check(SSHConfig.hosts().map(\.name) == ["web", "storage", "vps"], "add: \(SSHConfig.hosts().map(\.name))")
try SSHConfig.removeHost(SSHConfig.hosts()[0])
text = try config()
check(SSHConfig.hosts().map(\.name) == ["storage", "vps"], "delete: \(SSHConfig.hosts().map(\.name))")
check(!text.contains("ProxyJump"), "deleted the entry but kept its options:\n\(text)")
check(text.contains("Match host *.internal\n  User deploy\n  ProxyCommand ssh gateway -W %h:%p"),
			"deleting a host deleted its Match block:\n\(text)")
check(text.contains("# the box in the loft"), "delete ate the next entry's comment:\n\(text)")
check(text.contains("Host *"), "delete lost the wildcard defaults:\n\(text)")

// A config that doesn't exist yet — the normal first run.
try manager.removeItem(atPath: home + "/.ssh")
check(SSHConfig.hosts().isEmpty, "no file should mean no hosts")
try SSHConfig.addHost(SSHHost(name: "first", hostName: "example.com"))
check(SSHConfig.hosts().map(\.name) == ["first"], "created the file: \(try config())")
check(try config().hasSuffix("\n"), "file should end with a newline: \(try config().debugDescription)")

// An existing config that can't be decoded must never be treated as an empty file and overwritten.
let invalidConfig = Data([0xff, 0xfe, 0xfd])
try invalidConfig.write(to: URL(fileURLWithPath: home + "/.ssh/config"))
do {
	try SSHConfig.addHost(SSHHost(name: "must-not-overwrite"))
	check(false, "overwrote an unreadable config")
} catch {}
check(try Data(contentsOf: URL(fileURLWithPath: home + "/.ssh/config")) == invalidConfig,
			"changed an unreadable config")

// Restore a valid config for the key checks below.
try "".write(toFile: home + "/.ssh/config", atomically: true, encoding: .utf8)

// MARK: - The keys

// A generated key is listed, is 0600, and has its public half.
let generated = try SSHKeys.generate(name: "id_ed25519")
check(generated.type == "ed25519", "type read from the public key: \(generated.type)")
check(generated.arePermissionsSafe, "generated key isn't 0600: \(String(generated.permissions, radix: 8))")
check(generated.hasPublicKey, "generated key has no public half")
check(SSHKeys.keys().map(\.name) == ["id_ed25519"], "listed: \(SSHKeys.keys().map(\.name))")

// Every offered type actually makes a key, with the name and algorithm it promised. ECDSA rather
// than RSA here: same code path, and 4096-bit RSA makes this check take seconds for nothing.
for type in [SSHKeyType.ecdsa] {
	let made = try SSHKeys.generate(name: type.defaultFileName, type: type, comment: "check@\(type.rawValue)")
	check(made.name == type.defaultFileName, "\(type.rawValue) name: \(made.name)")
	check(made.type.contains(type.rawValue), "\(type.rawValue) made a \(made.type) key")
	check(made.comment == "check@\(type.rawValue)", "\(type.rawValue) comment: \(made.comment)")
	try SSHKeys.remove(made)
}

// The config file, known_hosts and the public half are in the same folder and are not keys.
try "example.com ssh-ed25519 AAAA".write(toFile: home + "/.ssh/known_hosts", atomically: true, encoding: .utf8)
check(SSHKeys.keys().map(\.name) == ["id_ed25519"], "listed a non-key: \(SSHKeys.keys().map(\.name))")

// Making the same key again is refused rather than overwriting it.
do {
	try SSHKeys.generate(name: "id_ed25519")
	check(false, "overwrote an existing key")
} catch {}

// A key with no public half beside it is still listed, and the public half can be recovered.
try manager.removeItem(atPath: home + "/.ssh/id_ed25519.pub")
let bare = SSHKeys.keys()[0]
check(!bare.hasPublicKey, "should have noticed the missing public half")
check(bare.type.isEmpty, "type can't be known without the public half: \(bare.type)")
try SSHKeys.recoverPublicKey(for: bare)
let recovered = SSHKeys.keys()[0]
check(recovered.hasPublicKey, "didn't recover the public half")
// Type and key material, not the comment: whether `ssh-keygen -y` prints one has varied by version.
func material(_ publicKey: String) -> String {
	publicKey.components(separatedBy: " ").prefix(2).joined(separator: " ")
}
check(material(recovered.publicKey) == material(generated.publicKey),
			"recovered a different key:\n\(recovered.publicKey)\n\(generated.publicKey)")

// Permissions ssh would refuse are spotted, and fixed.
try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: recovered.path)
check(!SSHKeys.keys()[0].arePermissionsSafe, "didn't spot a world-readable key")
try SSHKeys.fixPermissions(for: SSHKeys.keys()[0])
check(SSHKeys.keys()[0].arePermissionsSafe, "didn't fix the permissions")

// Importing a folder takes the keys in it and passes over everything else.
let incoming = home + "/incoming"
try manager.createDirectory(atPath: incoming, withIntermediateDirectories: true)
try manager.copyItem(atPath: home + "/.ssh/id_ed25519", toPath: incoming + "/backup_key")
try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: incoming + "/backup_key")
try "not a key".write(toFile: incoming + "/README.md", atomically: true, encoding: .utf8)
try "-----BEGIN NOT A PRIVATE KEY-----\nnot-a-key".write(toFile: incoming + "/pretender",
																	 atomically: true,
																	 encoding: .utf8)
try "ssh-ed25519 AAAA someone@somewhere".write(toFile: incoming + "/loose.pub", atomically: true, encoding: .utf8)

let imported = try SSHKeys.importKeys(from: [URL(fileURLWithPath: incoming)])
check(imported == 1, "imported \(imported), expected only the key")
check(SSHKeys.keys().map(\.name) == ["backup_key", "id_ed25519"], "after import: \(SSHKeys.keys().map(\.name))")
let copied = SSHKeys.keys()[0]
check(copied.arePermissionsSafe, "imported key kept loose permissions: \(String(copied.permissions, radix: 8))")
check(copied.hasPublicKey, "didn't work out the imported key's public half")

// A sibling public key must actually belong to the private key. Blindly copying a stale `.pub`
// makes the UI hand the user a key that can never authenticate with the private half ssh uses.
let other = try SSHKeys.generate(name: "other_key")
try manager.copyItem(atPath: home + "/.ssh/id_ed25519", toPath: incoming + "/mismatched_key")
try other.publicKey.write(toFile: incoming + "/mismatched_key.pub", atomically: true, encoding: .utf8)
try SSHKeys.remove(other)
do {
	try SSHKeys.importKeys(from: [URL(fileURLWithPath: incoming + "/mismatched_key")])
	check(false, "accepted a public key that does not match its private key")
} catch {}
check(!manager.fileExists(atPath: home + "/.ssh/mismatched_key"),
			"left a private key after rejecting its mismatched public half")

// If ssh-keygen can't verify a sibling public half, keep the usable private key but don't claim the
// unverified public file belongs to it.
try manager.copyItem(atPath: home + "/.ssh/id_ed25519", toPath: incoming + "/unverified_key")
try generated.publicKey.write(toFile: incoming + "/unverified_key.pub", atomically: true, encoding: .utf8)
AICatalog.binaryDirectories = []
check(try SSHKeys.importKeys(from: [URL(fileURLWithPath: incoming + "/unverified_key")]) == 1,
			"could not import a private key without ssh-keygen")
let unverified = SSHKeys.keys().first { $0.name == "unverified_key" }!
check(!unverified.hasPublicKey, "copied an unverifiable public half")
try SSHKeys.remove(unverified)
AICatalog.binaryDirectories = ["/usr/bin", "/bin"]

// A stale public half must not be silently paired with a newly imported private key.
try manager.copyItem(atPath: home + "/.ssh/id_ed25519", toPath: incoming + "/paired_key")
try generated.publicKey.write(toFile: incoming + "/paired_key.pub", atomically: true, encoding: .utf8)
try "ssh-ed25519 AAAA-stale stale@key".write(toFile: home + "/.ssh/paired_key.pub",
															 atomically: true,
															 encoding: .utf8)
do {
	try SSHKeys.importKeys(from: [URL(fileURLWithPath: incoming + "/paired_key")])
	check(false, "paired a new private key with a stale public key")
} catch {}
check(!manager.fileExists(atPath: home + "/.ssh/paired_key"),
			"left a half-imported private key beside a stale public key")

// Importing the same name again is refused rather than overwriting what's there.
do {
	try SSHKeys.importKeys(from: [URL(fileURLWithPath: incoming + "/backup_key")])
	check(false, "overwrote a key that was already there")
} catch {}

// Deleting takes both halves.
try SSHKeys.remove(copied)
check(!manager.fileExists(atPath: copied.path), "left the private key behind")
check(!manager.fileExists(atPath: copied.path + ".pub"), "left the public key behind")

print("ok")
SWIFT

swiftc -o "$WORK/check" "$WORK/main.swift" "$WORK/Stub.swift" \
	Common/Controllers/SSHConfig.swift Common/Controllers/SSHKeys.swift
"$WORK/check"
