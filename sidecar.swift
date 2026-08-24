// sidecar — connect/disconnect an iPad as a Sidecar display from the command line.
//
// Build:  swiftc -O sidecar.swift -o ~/.local/bin/sidecar
//
// Everything that touches Apple's private SidecarCore framework lives in the
// `SidecarCore` type below. The command layer never learns the framework exists.

import Foundation

// MARK: - Exit codes

enum ExitCode: Int32 {
    case success        = 0
    case usage          = 1
    case noDevices      = 2
    case deviceNotFound = 3
    case sidecarError   = 4
    case timedOut       = 5
}

func fail(_ message: String, _ code: ExitCode) -> Never {
    FileHandle.standardError.write(Data("sidecar: \(message)\n".utf8))
    exit(code.rawValue)
}

func emit(_ line: String) {
    FileHandle.standardOutput.write(Data("\(line)\n".utf8))
}

// MARK: - Private-API isolation layer
//
// The only part of the program that knows about SidecarCore, `perform(Selector(...))`,
// or Objective-C at all. It presents a small typed Swift interface and turns every
// missing class or selector into a `SidecarCoreError.unavailable` rather than a crash.

struct Device {
    let name: String
    let id: String
    fileprivate let object: NSObject
}

enum SidecarCoreError: Error {
    /// The private API is gone or has changed shape. The payload names what was missing.
    case unavailable(String)
    /// SidecarCore ran and reported a failure.
    case failed(code: Int, message: String)
    /// The completion block never fired within the deadline.
    case timedOut(TimeInterval)
}

final class SidecarCore {
    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore"

    private static let managerClassName  = "SidecarDisplayManager"
    private static let devicesSelector      = "devices"
    private static let connectedSelector    = "connectedDevices"
    private static let connectSelector      = "connectToDevice:completion:"
    private static let disconnectSelector   = "disconnectFromDevice:completion:"
    private static let nameSelector         = "name"
    private static let identifierSelector   = "identifier"

    private let manager: NSObject

    init() throws {
        guard dlopen(Self.frameworkPath, RTLD_LAZY) != nil else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            throw SidecarCoreError.unavailable("could not load \(Self.frameworkPath): \(reason)")
        }

        guard let managerClass = NSClassFromString(Self.managerClassName) as? NSObject.Type else {
            throw SidecarCoreError.unavailable("class \(Self.managerClassName) not found")
        }

        let shared = Selector(("sharedManager"))
        guard managerClass.responds(to: shared) else {
            throw SidecarCoreError.unavailable("+[\(Self.managerClassName) sharedManager] not found")
        }
        guard let instance = managerClass.perform(shared)?.takeUnretainedValue() as? NSObject else {
            throw SidecarCoreError.unavailable("+[\(Self.managerClassName) sharedManager] returned nothing")
        }
        manager = instance

        // Check every selector we depend on up front, so a broken API is reported once
        // and clearly rather than mid-operation.
        for selector in [Self.devicesSelector, Self.connectedSelector,
                         Self.connectSelector, Self.disconnectSelector] {
            guard manager.responds(to: Selector((selector))) else {
                throw SidecarCoreError.unavailable("-[\(Self.managerClassName) \(selector)] not found")
            }
        }
    }

    /// Every Sidecar-capable device currently reachable, connected or not.
    func devices() throws -> [Device] {
        try deviceList(Self.devicesSelector)
    }

    /// The devices with a live Sidecar session. Empty when nothing is connected.
    func connectedDevices() throws -> [Device] {
        try deviceList(Self.connectedSelector)
    }

    func connect(_ device: Device, timeout: TimeInterval) throws {
        try invoke(Self.connectSelector, on: device, timeout: timeout)
    }

    func disconnect(_ device: Device, timeout: TimeInterval) throws {
        try invoke(Self.disconnectSelector, on: device, timeout: timeout)
    }

    // MARK: private

    private func deviceList(_ selectorName: String) throws -> [Device] {
        guard let raw = manager.perform(Selector((selectorName)))?
            .takeUnretainedValue() as? [NSObject] else { return [] }

        return try raw.map { object in
            let nameSel = Selector((Self.nameSelector))
            guard object.responds(to: nameSel) else {
                throw SidecarCoreError.unavailable("-[SidecarDevice \(Self.nameSelector)] not found")
            }
            let name = object.perform(nameSel)?.takeUnretainedValue() as? String ?? "(unnamed device)"

            // The identifier is nice to have for --json but not worth failing over.
            var id = ""
            let idSel = Selector((Self.identifierSelector))
            if object.responds(to: idSel),
               let value = object.perform(idSel)?.takeUnretainedValue() {
                if let uuid = value as? UUID { id = uuid.uuidString }
                else if let uuid = value as? NSUUID { id = uuid.uuidString }
                else { id = String(describing: value) }
            }

            return Device(name: name, id: id, object: object)
        }
    }

    /// Calls a `…Device:completion:` selector and waits for the completion block,
    /// giving up after `timeout`. SidecarCore delivers the completion on its own
    /// queue, but the run loop is kept spinning so a main-queue delivery would also
    /// land instead of deadlocking.
    private func invoke(_ selectorName: String, on device: Device, timeout: TimeInterval) throws {
        let lock = NSLock()
        var finished = false
        var failure: NSError?

        let completion: @convention(block) (NSError?) -> Void = { error in
            lock.lock()
            finished = true
            failure = error
            lock.unlock()
        }

        _ = manager.perform(Selector((selectorName)), with: device.object, with: completion)

        let deadline = Date().addingTimeInterval(timeout)

        // A repeating timer gives the run loop a source, so run(mode:before:) blocks
        // for a tick instead of returning instantly and burning CPU.
        let keepAlive = Timer(timeInterval: 0.05, repeats: true) { _ in }
        RunLoop.current.add(keepAlive, forMode: .default)
        defer { keepAlive.invalidate() }

        while true {
            lock.lock()
            let done = finished
            let error = failure
            lock.unlock()

            if done {
                if let error {
                    throw SidecarCoreError.failed(code: error.code,
                                                  message: error.localizedDescription)
                }
                return
            }
            if Date() >= deadline {
                throw SidecarCoreError.timedOut(timeout)
            }
            RunLoop.current.run(mode: .default, before: deadline)
        }
    }
}

// MARK: - Name matching

/// Folds case, diacritics, curly apostrophes and whitespace runs so that
/// `Joe's iPad`, `joe‘s ipad` and `Joe’s  iPad` all compare equal.
func normalize(_ string: String) -> String {
    var value = string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                               locale: nil)
    for variant in ["\u{2018}", "\u{2019}", "\u{201B}", "\u{FF07}", "\u{00B4}", "\u{0060}"] {
        value = value.replacingOccurrences(of: variant, with: "'")
    }
    return value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// Picks one device by name. Prefers an exact (normalized) match, then an unambiguous
/// substring match. Never guesses between candidates.
func selectDevice(from devices: [Device], matching query: String?) -> Device {
    if devices.isEmpty {
        fail("no Sidecar-capable devices are reachable", .noDevices)
    }

    guard let query, !query.isEmpty else {
        if devices.count == 1 { return devices[0] }
        fail("""
             more than one device is reachable, so a name is required. Candidates:
             \(devices.map { "  \($0.name)" }.joined(separator: "\n"))
             """, .deviceNotFound)
    }

    let target = normalize(query)

    let exact = devices.filter { normalize($0.name) == target }
    if exact.count == 1 { return exact[0] }
    if exact.count > 1 {
        fail("""
             '\(query)' matches more than one device exactly. Candidates:
             \(exact.map { "  \($0.name)" }.joined(separator: "\n"))
             """, .deviceNotFound)
    }

    let partial = devices.filter { normalize($0.name).contains(target) }
    if partial.count == 1 { return partial[0] }
    if partial.count > 1 {
        fail("""
             '\(query)' is ambiguous. Candidates:
             \(partial.map { "  \($0.name)" }.joined(separator: "\n"))
             """, .deviceNotFound)
    }

    fail("""
         no device matches '\(query)'. Reachable devices:
         \(devices.map { "  \($0.name)" }.joined(separator: "\n"))
         """, .deviceNotFound)
}

// MARK: - Error reporting

/// Apple returns this when the iPad is unreachable over the wireless link — in practice,
/// almost always because it is locked or asleep. It still appears in the device list.
let deviceWiFiNotEnabled = -203

func report(_ error: Error, action: String, device: Device?) -> Never {
    guard let error = error as? SidecarCoreError else {
        fail("\(action) failed: \(error.localizedDescription)", .sidecarError)
    }

    switch error {
    case .unavailable(let missing):
        fail("""
             the private SidecarCore API this tool depends on is unavailable: \(missing).
             A macOS update has probably changed or removed it.
             """, .sidecarError)

    case .timedOut(let seconds):
        let name = device.map { " '\($0.name)'" } ?? ""
        fail("\(action)\(name) timed out after \(formatSeconds(seconds))s. "
             + "Use --timeout to allow longer.", .timedOut)

    case .failed(let code, let message):
        let name = device.map { " '\($0.name)'" } ?? ""
        if code == deviceWiFiNotEnabled {
            fail("""
                 could not connect to\(name): the iPad is not reachable. It is almost \
                 always locked or asleep — wake it and unlock it, then try again.
                 (SidecarErrorDeviceWiFiNotEnabled, \(code))
                 """, .sidecarError)
        }
        fail("\(action)\(name) failed: \(message) (\(code))", .sidecarError)
    }
}

func formatSeconds(_ value: TimeInterval) -> String {
    value == value.rounded() ? String(Int(value)) : String(value)
}

// MARK: - JSON output

func printJSON(_ object: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                 options: [.sortedKeys, .fragmentsAllowed]),
          let text = String(data: data, encoding: .utf8) else {
        fail("could not encode JSON output", .sidecarError)
    }
    emit(text)
}

// MARK: - Help

let helpText = """
sidecar — connect and disconnect an iPad Sidecar display

USAGE
  sidecar <command> [name] [options]

COMMANDS
  devices              List reachable Sidecar-capable device names, one per line
  status               Print the connected device name, or 'disconnected'
  connect [name]       Connect to a device
  disconnect [name]    Disconnect from a device
  toggle [name]        Connect if disconnected, disconnect if connected
  help                 Show this text

  With no [name], commands use the only reachable device. If more than one is
  reachable they report the candidates rather than picking one. A name may be
  given unquoted; matching ignores case, accents and curly-vs-straight
  apostrophes, and accepts any unambiguous substring.

OPTIONS
  --json               Machine-readable output (devices, status)
  --timeout <seconds>  How long to wait for a connect or disconnect (default 15)
  --help, -h           Show this text

EXIT CODES
  0  success
  1  bad usage or invalid arguments
  2  no Sidecar-capable devices reachable
  3  named device not found, or the name is ambiguous
  4  SidecarCore reported an error, or its private API is unavailable
  5  timed out waiting for SidecarCore

NOTES
  Connecting fails with SidecarErrorDeviceWiFiNotEnabled (-203) when the iPad is
  locked or asleep, even though it still appears in 'sidecar devices'.
"""

// MARK: - Argument parsing

struct Arguments {
    var command = ""
    var name: String?
    var json = false
    var timeout: TimeInterval = 15
}

func parseArguments(_ argv: [String]) -> Arguments {
    var result = Arguments()
    var words: [String] = []
    var index = 0

    while index < argv.count {
        let argument = argv[index]
        switch argument {
        case "--help", "-h":
            emit(helpText)
            exit(ExitCode.success.rawValue)

        case "--json":
            result.json = true

        case "--timeout":
            index += 1
            guard index < argv.count else {
                fail("--timeout needs a value in seconds", .usage)
            }
            guard let seconds = TimeInterval(argv[index]), seconds > 0 else {
                fail("--timeout needs a positive number of seconds, got '\(argv[index])'", .usage)
            }
            result.timeout = seconds

        default:
            if argument.hasPrefix("-") {
                fail("unknown option '\(argument)'. Run 'sidecar --help'.", .usage)
            }
            words.append(argument)
        }
        index += 1
    }

    guard let command = words.first else {
        FileHandle.standardError.write(Data("\(helpText)\n".utf8))
        exit(ExitCode.usage.rawValue)
    }
    result.command = command

    // Remaining words are the device name; joining them means it need not be quoted.
    let rest = words.dropFirst().joined(separator: " ")
    result.name = rest.isEmpty ? nil : rest
    return result
}

// MARK: - Commands

func makeCore() -> SidecarCore {
    do { return try SidecarCore() }
    catch { report(error, action: "startup", device: nil) }
}

func listDevices(_ core: SidecarCore, json: Bool) -> Never {
    let all: [Device]
    let connected: [Device]
    do {
        all = try core.devices()
        connected = try core.connectedDevices()
    } catch {
        report(error, action: "listing devices", device: nil)
    }

    let connectedIDs = Set(connected.map(\.id))

    if json {
        printJSON(all.map { device in
            ["name": device.name,
             "id": device.id,
             "connected": connectedIDs.contains(device.id)] as [String: Any]
        })
        exit(ExitCode.success.rawValue)
    }

    if all.isEmpty {
        fail("no Sidecar-capable devices are reachable", .noDevices)
    }
    for device in all { emit(device.name) }
    exit(ExitCode.success.rawValue)
}

func showStatus(_ core: SidecarCore, json: Bool) -> Never {
    let connected: [Device]
    do { connected = try core.connectedDevices() }
    catch { report(error, action: "reading status", device: nil) }

    let device = connected.first

    if json {
        printJSON(["connected": device != nil,
                   "device": device?.name as Any? ?? NSNull(),
                   "id": device?.id as Any? ?? NSNull()] as [String: Any])
    } else {
        emit(device?.name ?? "disconnected")
    }
    exit(ExitCode.success.rawValue)
}

func connectCommand(_ core: SidecarCore, name: String?, timeout: TimeInterval) -> Never {
    let devices: [Device]
    do { devices = try core.devices() }
    catch { report(error, action: "listing devices", device: nil) }

    let device = selectDevice(from: devices, matching: name)
    do { try core.connect(device, timeout: timeout) }
    catch { report(error, action: "connecting to", device: device) }

    emit("connected: \(device.name)")
    exit(ExitCode.success.rawValue)
}

func disconnectCommand(_ core: SidecarCore, name: String?, timeout: TimeInterval) -> Never {
    let devices: [Device]
    do { devices = try core.devices() }
    catch { report(error, action: "listing devices", device: nil) }

    let device = selectDevice(from: devices, matching: name)
    do { try core.disconnect(device, timeout: timeout) }
    catch { report(error, action: "disconnecting from", device: device) }

    emit("disconnected: \(device.name)")
    exit(ExitCode.success.rawValue)
}

func toggleCommand(_ core: SidecarCore, name: String?, timeout: TimeInterval) -> Never {
    let devices: [Device]
    let connected: [Device]
    do {
        devices = try core.devices()
        connected = try core.connectedDevices()
    } catch {
        report(error, action: "reading status", device: nil)
    }

    // With no name and a live session, the connected device is the obvious target
    // even if several devices are reachable — so the hotkey never reports ambiguity
    // when there is something to turn off.
    let device: Device
    if name == nil, let live = connected.first {
        device = live
    } else {
        device = selectDevice(from: devices, matching: name)
    }

    if connected.contains(where: { $0.id == device.id }) {
        do { try core.disconnect(device, timeout: timeout) }
        catch { report(error, action: "disconnecting from", device: device) }
        emit("disconnected: \(device.name)")
    } else {
        do { try core.connect(device, timeout: timeout) }
        catch { report(error, action: "connecting to", device: device) }
        emit("connected: \(device.name)")
    }
    exit(ExitCode.success.rawValue)
}

// MARK: - Entry point

let arguments = parseArguments(Array(CommandLine.arguments.dropFirst()))

switch arguments.command {
case "help":
    emit(helpText)
    exit(ExitCode.success.rawValue)
case "devices":
    listDevices(makeCore(), json: arguments.json)
case "status":
    showStatus(makeCore(), json: arguments.json)
case "connect":
    connectCommand(makeCore(), name: arguments.name, timeout: arguments.timeout)
case "disconnect":
    disconnectCommand(makeCore(), name: arguments.name, timeout: arguments.timeout)
case "toggle":
    toggleCommand(makeCore(), name: arguments.name, timeout: arguments.timeout)
default:
    fail("unknown command '\(arguments.command)'. Run 'sidecar --help'.", .usage)
}
