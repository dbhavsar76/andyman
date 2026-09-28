import AndroidKit
import Foundation

/// Resolved environment shared by commands: SDK, AVD folder, settings.
struct CommandContext {
    /// This process's environment plus toolchain variables from the user's login shell when
    /// they're missing here (agents' shells often skip ~/.zshrc). See `LoginEnvironment`.
    let environment: [String: String]
    /// Variables taken from the login shell rather than this process.
    let fromProfile: Set<String>
    let sdk: SDKLocation?
    let avdDirectory: URL

    init(_ options: GlobalOptions) {
        let overlay = LoginEnvironment.overlay(ProcessInfo.processInfo.environment)
        environment = overlay.environment
        fromProfile = overlay.fromProfile
        let resolution = SDKLocator().resolve(
            flag: options.sdk,
            settings: SharedPreferences().sdkPathOverride,
            environment: environment
        )
        sdk = resolution.isValid ? resolution.location : nil
        avdDirectory = AVDCatalog.defaultDirectory(environment: environment)
    }

    var catalog: AVDCatalog { AVDCatalog(directory: avdDirectory, sdkRoot: sdk?.url) }

    func requireSDK() throws -> SDKLocation {
        guard let sdk else {
            throw CLIError.sdkNotFound("No usable Android SDK found.", hint: "Run `andyman doctor` for details, or pass --sdk <path>.")
        }
        return sdk
    }

    func controller() throws -> EmulatorController {
        EmulatorController(sdkRoot: try requireSDK().url, avdDirectory: avdDirectory)
    }

    func device(named name: String) throws -> VirtualDevice {
        do {
            return try catalog.device(named: name)
        } catch {
            throw CLIError(error)
        }
    }
}

extension CLIError {
    /// Maps library errors to stable codes and exit statuses.
    init(_ error: any Error) {
        switch error {
        case let error as CLIError:
            self = error
        case let error as AVDError:
            switch error {
            case .notFound:
                self.init(code: "avd_not_found", message: error.localizedDescription, hint: "Run `andyman avd list` to see available names.", exitStatus: .notFound)
            case .running:
                self.init(code: "avd_running", message: error.localizedDescription, hint: "Run `andyman emulator stop <name>` first.")
            }
        case let error as EmulatorError:
            switch error {
            case .emulatorNotInstalled:
                self.init(code: "emulator_not_installed", message: error.localizedDescription, exitStatus: .missingPrerequisite)
            case .adbNotInstalled:
                self.init(code: "adb_not_installed", message: error.localizedDescription, exitStatus: .missingPrerequisite)
            case .cannotLaunch:
                self.init(code: "cannot_launch", message: error.localizedDescription, exitStatus: .missingPrerequisite)
            case .alreadyRunning:
                self.init(code: "already_running", message: error.localizedDescription)
            case let .exitedDuringStartup(_, logPath):
                self.init(code: "emulator_exited", message: error.localizedDescription, hint: "Check the log: \(logPath)")
            case .notRunning:
                self.init(code: "not_running", message: error.localizedDescription, exitStatus: .notFound)
            case .timedOut:
                self.init(code: "timeout", message: error.localizedDescription, hint: "Pass a longer --timeout.", exitStatus: .timeout)
            }
        default:
            self.init(code: "failure", message: error.localizedDescription)
        }
    }

    static func confirmationRequired(_ action: String) -> CLIError {
        CLIError(code: "confirmation_required", message: "\(action) needs --yes to confirm.", exitStatus: .usage)
    }
}
