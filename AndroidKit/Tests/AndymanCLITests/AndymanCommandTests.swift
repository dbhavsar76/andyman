import Foundation
import Testing
@testable import AndymanCLI

@Suite struct AndymanCommandTests {
    @Test func parsesSubcommandsWithGlobalOptions() throws {
        let command = try AndymanCommand.parseAsRoot(["doctor", "--json", "--sdk", "/tmp/sdk"])
        let doctor = try #require(command as? DoctorCommand)
        #expect(doctor.options.json)
        #expect(doctor.options.sdk == "/tmp/sdk")
    }

    @Test func parsesShellOption() throws {
        let env = try #require(try AndymanCommand.parseAsRoot(["env", "--shell", "fish"]) as? EnvCommand)
        #expect(env.shell == .fish)
    }

    @Test func unknownOptionIsAUsageError() async {
        #expect(await AndymanCommand.run(arguments: ["doctor", "--bogus"]) == ExitStatus.usage.rawValue)
    }

    @Test func missingSDKExitsWithMissingPrerequisite() async {
        let code = await AndymanCommand.run(arguments: ["env", "--json", "--sdk", "/does/not/exist"])
        #expect(code == ExitStatus.missingPrerequisite.rawValue)
    }

    @Test func errorEncodesStableShape() throws {
        let error = CLIError(code: "sdk_not_found", message: "No SDK", hint: "Set ANDROID_HOME", exitStatus: .missingPrerequisite)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(error)) as? [String: Any]
        #expect(json?["code"] as? String == "sdk_not_found")
        #expect(json?["exitCode"] as? Int == 5)
        #expect(json?["hint"] as? String == "Set ANDROID_HOME")
    }
}
