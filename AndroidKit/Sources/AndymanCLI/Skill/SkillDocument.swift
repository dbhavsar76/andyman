import AndroidKit
import ArgumentParser
import Foundation

/// The agent skill (`SKILL.md`), generated from this build of the CLI so the commands it
/// describes always exist.
enum SkillDocument {
    static let description = """
    Manage the Android toolchain on macOS without Android Studio, using the andyman CLI: start, stop and create emulators (AVDs); install SDK platforms, build tools, NDK and CMake; fix JDK, JAVA_HOME and ANDROID_HOME problems; and diagnose React Native or Flutter Android builds (missing NDK or SDK, unaccepted licenses, wrong Java version). Use when running an app on an Android emulator, when an Android or Gradle build fails because something is missing, or when setting up Android development on a Mac.
    """

    /// The full SKILL.md. `executable` is how to run andyman when it isn't on PATH.
    static func render(executable: String) -> String {
        let body = body(executable: executable)
        let version = AgentSkills.version(cliVersion: AndymanCommand.version, body: body)
        return """
        ---
        name: \(AgentSkills.skillName)
        description: "\(description.replacingOccurrences(of: "\"", with: "\\\""))"
        metadata:
          generator: \(AgentSkills.generator)
          version: "\(version)"
        ---

        \(body)
        """
    }

    /// A short block for AGENTS.md / CLAUDE.md, for agents that don't load skills.
    static func agentsSnippet(executable: String) -> String {
        """
        ## Android toolchain

        Use `andyman` (Andyman's CLI\(executable == "andyman" ? "" : "; not on PATH? use `\(executable)`")) for Android emulators, SDK packages, JDKs and build problems. Always pass `--json`. Start with `andyman doctor --json`; for a failing React Native or Flutter build, `andyman project check <path> --json`. Boot an emulator with `andyman emulator start <avd> --wait-boot --json`. Never pass `--accept-licenses` or `--yes` without asking the user first. Run `andyman --help` for everything else.
        """
    }

    /// Where the running binary lives (the app bundle's copy when the app generates the skill).
    static var executablePath: String {
        let argument = CommandLine.arguments.first ?? "andyman"
        let url = URL(fileURLWithPath: argument).resolvingSymlinksInPath()
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : "andyman"
    }

    private static func body(executable: String) -> String {
        let runHint = executable == "andyman"
            ? "Run `andyman`."
            : "Run `andyman`; if it isn't on PATH, use the full path: `\"\(executable)\"`."
        return """
        # Andyman (andyman)

        `andyman` manages emulators, SDK packages, JDKs and Android build prerequisites on this Mac, with no Android Studio needed. It works whether or not the Andyman app is open, and the app shows the same state. \(runHint)

        ## Rules

        - **Always pass `--json`.** Output is one JSON document with `schemaVersion`; long operations (installs, setup) print one JSON object per line and end with a `done` event. Errors are `{"error": {"code", "message", "hint", "exitCode"}}`.
        - **Branch on exit codes:** 0 ok · 1 failure · 2 usage · 3 not found · 4 license not accepted · 5 missing prerequisite (SDK, JDK, tools) · 6 timeout. Checks (`doctor`, `project check`) exit 5 when something they check is wrong: that's a result to read (see `checks`), not a crash.
        - **Your shell may not have the user's environment.** Agent shells often skip `~/.zshrc`, so `ANDROID_HOME` and `JAVA_HOME` can be missing even though the user's terminal has them. andyman fills them in from the user's shell profile and says so: `fromShellProfile` in `doctor` (under `environment`) and `project check` lists them, and messages say "from your shell profile". Build tools (Gradle, React Native, Expo, Flutter) don't do this, so when `fromShellProfile` isn't empty, run builds as `eval "$(andyman env)" && <build command>`.
        - **Licenses are the user's decision.** Exit code 4 means SDK licenses need accepting. A dry run lists the licenses a change involves (`licenses`, under `install` for `project check --fix --dry-run`) with `needsLicenseAcceptance`; if it's false, there's no license question to ask. If it's true, show the user the unaccepted ones (`andyman licenses show <id>`) and ask before passing `--accept-licenses`.
        - **Preview, then ask, before anything destructive or large.** Use `--dry-run` first (`sdk install`, `project check --fix`, `setup`, `cleanup run`, `project clean`, `jdk use`) and tell the user what would happen, including download sizes (system images are 1–3 GB, NDKs about 1 GB). Deleting also needs `--yes`.
        - **Ask before editing the user's shell profile** (`andyman jdk use`, `andyman setup --write-shell-profile`). The file is backed up, but it's still theirs. For a one-off build with a different JDK, set it just for that command instead: `JAVA_HOME=$(/usr/libexec/java_home -v 17) <build command>`.
        - Commands never prompt, so a missing argument is an error, not a question.
        - Don't open Android Studio or run `sdkmanager`/`avdmanager` directly; use andyman.

        ## Common tasks

        ### Something's wrong with the Android setup
        ```sh
        andyman doctor --json          # SDK, command-line tools, platform tools, emulator, JDK, ANDROID_HOME, PATH; each check has a hint
        andyman env                    # export lines for ANDROID_HOME / JAVA_HOME / PATH (eval-able); --json for structured output
        ```

        ### A React Native or Flutter Android build fails
        Typical errors: "NDK not configured", "failed to find target android-36", "Build-tools … is missing", "licences not accepted", "Unsupported class file major version", "SDK location not found".
        ```sh
        andyman project check <project-dir> --json               # what the project needs (compileSdk, build tools, NDK, CMake, JDK) vs what's installed
        andyman project check <project-dir> --fix --dry-run --json    # what --fix would install (sizes, licenses) and change
        andyman project check <project-dir> --fix --json         # after the user agrees (exit 4 → ask about licenses, add --accept-licenses)
        ```
        Then re-run the user's build (with the `eval "$(andyman env)" &&` prefix if needed) to confirm it's fixed.
        Each check has `status` (ok/warning/error), `message`, `hint` and sometimes `fix`: `{"action": "install_packages", "packages": [...]}` and `write_local_properties` are what `--fix` does; `install_jdk` / `use_jdk` (with `major`) are left to you and the user (see JDKs below). Messages say where each value came from (the project's files, React Native's or Flutter's defaults, the user's shell profile). For stale native build errors after upgrades, `andyman project clean <project-dir> --dry-run --json`, then with `--yes` once the user agrees.

        For Expo projects that regenerate `android/` (continuous native generation), prefer setting ANDROID_HOME for the build over writing `android/local.properties`, which `expo prebuild --clean` deletes.

        ### Run the app on an emulator
        ```sh
        andyman project check <project-dir> --json               # first: missing packages or a JDK problem will stop the build anyway
        andyman avd list --json                                  # virtual devices; `problems` explains any that can't start
        andyman emulator start <avd-name> --wait-boot --json     # returns once Android has booted, with the adb serial (emulator-5554)
        ```
        `project check` returns `suitableDevices`: phones and tablets new enough for the project's minSdk, closest to its target SDK first, so the first is usually the one to use. `emulator start` takes `--headless` (no window: for CI, or to avoid disturbing someone's screen) and `--cold` (ignore the quick-boot snapshot). If the start fails, the error includes `logPath` (the emulator's log); if it's already running you get that instance (`alreadyRunning: true`).

        Then build and launch the way the project normally does, targeting that device (prefix with `eval "$(andyman env)" &&` if `fromShellProfile` isn't empty). Note which identifier each tool wants:
        - Expo: `npx expo run:android --device <avd-name>` (the AVD name)
        - React Native CLI: `npx react-native run-android --deviceId <serial>` (the adb serial, like emulator-5554)
        - Flutter: `flutter run -d <serial>` (the adb serial)
        - Native Android: `./gradlew installDebug`, or Google's `android run --device=<serial>`

        These start Metro/port forwarding themselves. The emulator helpers are for when they don't (Metro started separately, or the emulator restarted):
        ```sh
        andyman emulator reverse <avd|serial> --json       # adb reverse tcp:8081 so the app reaches Metro; --port for others
        andyman emulator reload <avd|serial> --json        # reload the JS bundle
        andyman emulator dev-menu <avd|serial> --json
        andyman emulator screenshot <avd|serial> --output shot.png --json
        andyman emulator install <avd|serial> app.apk --json
        andyman emulator stop <avd|serial> --json
        ```

        ### Create an emulator
        ```sh
        andyman devices --json                         # hardware profiles (IDs like pixel_9, medium_phone)
        andyman images --device <profile-id> --json    # installed system images that fit
        andyman avd create --device <profile-id> --image "<system-image-id>" --json
        ```
        No suitable image? `andyman sdk list --available --category system-images --json`, then `andyman sdk install "<image-id>" --dry-run --json` to show the user its size before installing.

        ### Install or update SDK packages
        ```sh
        andyman sdk list --json                        # installed, with available updates
        andyman sdk list --available --category ndk --json
        andyman sdk install "<package-id>" … --dry-run --json    # packages (with dependencies), sizes, licenses
        andyman sdk install "<package-id>" … --json
        andyman sdk update --json
        ```
        Package IDs use sdkmanager syntax (`ndk;<version>`, `platforms;android-<api>`, `build-tools;<version>`); take exact versions from `project check` rather than guessing. Installs stream progress.

        ### Set up a Mac from nothing
        ```sh
        andyman setup --preset react-native --dry-run --json   # or --preset flutter / minimal / tools
        ```
        Show the user the plan (JDK, packages, sizes, licenses), then run it without `--dry-run`, adding `--accept-licenses` only after they agree. Presets follow the latest React Native and Flutter releases. Already-installed pieces are skipped, so it also fills gaps. Flutter itself isn't installed.

        ### JDK problems
        Gradle needs JDK 17 or newer, and each Gradle version has a newest JDK it supports; `project check` says which JDK Gradle would use and whether that works. If its `java` check is ok, leave the JDK alone, even though React Native recommends 17. Without JAVA_HOME, Gradle uses the macOS default (`/usr/libexec/java_home`), usually the newest JDK installed, which may be too new: the `java` check's hint says so.
        ```sh
        andyman jdk list --json
        andyman jdk install 17 --json
        andyman jdk use 17 --dry-run --json    # shows the profile change and any other line that sets JAVA_HOME (`otherAssignments`)
        ```
        `jdk use` (without `--dry-run`, once the user agrees) affects new terminals only. For this session, set `JAVA_HOME` on the build command instead.

        ### Free space or unstick Gradle
        ```sh
        andyman gradle status --json      # running daemons and their memory
        andyman gradle stop --json
        andyman cleanup list --json       # Gradle caches, old Gradle versions, emulator snapshots, Metro cache, with sizes
        andyman cleanup run <id…> --dry-run --json    # then --yes after the user agrees
        ```

        ## Google's `android` CLI
        The SDK's command-line tools include Google's `android` command (`$ANDROID_HOME/cmdline-tools/latest/bin/android`). It's useful alongside andyman for app work: `android run` (build, install and launch), `android layout` (the on-screen UI tree), `android screen capture`, and `android docs search <query>` (official Android docs). `android skills list` offers Google's Android development skills. Prefer andyman for emulators, SDK packages, licenses, JDKs and project checks (JSON output and stable exit codes).

        ## Command reference
        \(commandReference())

        Every command also takes `--json` and `--sdk <path>` (to use a specific SDK). `andyman help <command> <subcommand>` shows all options.
        """
    }

    /// One line per command and subcommand, from the CLI's own definitions.
    static func commandReference() -> String {
        var lines: [String] = []
        func name(_ command: ParsableCommand.Type) -> String {
            command.configuration.commandName ?? kebab(String(describing: command))
        }
        for command in AndymanCommand.configuration.subcommands where name(command) != "skill" {
            let subcommands = command.configuration.subcommands
            if subcommands.isEmpty {
                lines.append("- `andyman \(name(command))`: \(command.configuration.abstract)")
            } else {
                for subcommand in subcommands {
                    lines.append("- `andyman \(name(command)) \(name(subcommand))`: \(subcommand.configuration.abstract)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func kebab(_ typeName: String) -> String {
        var result = ""
        for character in typeName {
            if character.isUppercase, !result.isEmpty { result.append("-") }
            result.append(character.lowercased())
        }
        return result.replacingOccurrences(of: "-command", with: "")
    }
}
