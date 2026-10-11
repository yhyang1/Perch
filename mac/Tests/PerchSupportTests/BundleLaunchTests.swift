import Foundation
import XCTest
@testable import PerchSupport

final class BundleLaunchTests: XCTestCase {
    func testPackagedLaunchUsesOnlyBundledPathsWithSpaces() throws {
        let resources = try makeBundle(in: temporaryFolder())
        let launch = try configuration(resources: resources)

        XCTAssertEqual(launch.executableURL.path, resources.appendingPathComponent("python/bin/python3").path)
        XCTAssertEqual(launch.arguments, ["-I", "-S", "-B", "-u", resources.appendingPathComponent("bridge/bootstrap.py").path])
        XCTAssertEqual(launch.workingDirectoryURL.path, resources.appendingPathComponent("bridge").path)
        XCTAssertTrue(launch.executableURL.isFileURL)
        XCTAssertTrue(launch.executableURL.path.hasPrefix("/"))
        XCTAssertTrue(launch.executableURL.path.contains("Perch Preview.app"))
        // These intentionally invalid developer settings must never be consulted.
        XCTAssertFalse(launch.arguments.contains("-m"))
    }

    func testPackagedEnvironmentDropsPythonAndLoaderOverridesButKeepsSSH() throws {
        let resources = try makeBundle(in: temporaryFolder())
        let source = [
            "PYTHONPATH": "/outside/modules",
            "PYTHONHOME": "/outside/python",
            "PYTHONSTARTUP": "/outside/startup.py",
            "PYTHONUSERBASE": "/outside/user",
            "PYTHONUNBUFFERED": "0",
            "DYLD_LIBRARY_PATH": "/outside/libraries",
            "DYLD_INSERT_LIBRARIES": "/outside/inject.dylib",
            "PERCH_ROOT": "/outside/source",
            "HOME": "/Users/Someone With Spaces",
            "SSH_AUTH_SOCK": "/private/tmp/ssh-agent.sock",
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "LANG": "en_US.UTF-8"
        ]
        let launch = try configuration(resources: resources, environment: source)

        XCTAssertEqual(launch.environment, [
            "HOME": source["HOME"]!, "SSH_AUTH_SOCK": source["SSH_AUTH_SOCK"]!,
            "PATH": source["PATH"]!, "LANG": source["LANG"]!
        ])
        XCTAssertEqual(source["PYTHONUNBUFFERED"], "0")
    }

    func testMissingBundledRuntimeDoesNotFallBackToValidDeveloperRuntime() throws {
        let folder = try temporaryFolder()
        let resources = try makeBundle(in: folder)
        let bundledPython = resources.appendingPathComponent("python/bin/python3")
        try FileManager.default.removeItem(at: bundledPython)
        let developerRoot = folder.appendingPathComponent("Developer Project")
        let developerPython = developerRoot.appendingPathComponent("bin/python3")
        try makeFile(developerPython, executable: true)
        try makeFile(developerRoot.appendingPathComponent("perch/bridge.py"))

        XCTAssertThrowsError(try BundleLaunch.configuration(
            resourceURL: resources, isPackaged: true,
            pythonPath: developerPython.path, projectRoot: developerRoot.path,
            environment: ["PERCH_ROOT": developerRoot.path]
        )) { error in
            XCTAssertEqual(error as? BundleLaunch.ConfigurationError, .missingBundledRuntime(bundledPython.path))
        }
    }

    func testMissingBootstrapFailsClearly() throws {
        let resources = try makeBundle(in: temporaryFolder())
        let bootstrap = resources.appendingPathComponent("bridge/bootstrap.py")
        try FileManager.default.removeItem(at: bootstrap)

        XCTAssertThrowsError(try configuration(resources: resources)) { error in
            XCTAssertEqual(error as? BundleLaunch.ConfigurationError, .missingBundledBridge(bootstrap.path))
            XCTAssertTrue(error.localizedDescription.contains("Download or reinstall Perch"))
        }
    }

    func testMissingBridgeModuleFailsClearly() throws {
        let resources = try makeBundle(in: temporaryFolder())
        let module = resources.appendingPathComponent("bridge/perch/bridge.py")
        try FileManager.default.removeItem(at: module)

        XCTAssertThrowsError(try configuration(resources: resources)) { error in
            XCTAssertEqual(error as? BundleLaunch.ConfigurationError, .missingBundledBridge(module.path))
        }
    }

    func testMissingResourcesDoesNotUseDeveloperSettings() throws {
        let folder = try temporaryFolder()
        let python = folder.appendingPathComponent("python3")
        try makeFile(python, executable: true)
        try makeFile(folder.appendingPathComponent("perch/bridge.py"))

        for resources in [nil, folder.appendingPathComponent("Missing Resources")] as [URL?] {
            XCTAssertThrowsError(try BundleLaunch.configuration(
                resourceURL: resources, isPackaged: true,
                pythonPath: python.path, projectRoot: folder.path, environment: [:]
            )) { error in
                XCTAssertEqual(error as? BundleLaunch.ConfigurationError, .missingResources)
            }
        }
    }

    func testBundledRuntimeMustBeExecutable() throws {
        let resources = try makeBundle(in: temporaryFolder())
        let python = resources.appendingPathComponent("python/bin/python3")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: python.path)

        XCTAssertThrowsError(try configuration(resources: resources)) { error in
            XCTAssertEqual(error as? BundleLaunch.ConfigurationError, .missingBundledRuntime(python.path))
        }
    }

    func testBundledRuntimeMayLinkToAnotherFileInsideBundle() throws {
        let resources = try makeBundle(in: temporaryFolder())
        let python = resources.appendingPathComponent("python/bin/python3")
        let versionedPython = resources.appendingPathComponent("python/bin/python3.13")
        try FileManager.default.moveItem(at: python, to: versionedPython)
        try FileManager.default.createSymbolicLink(atPath: python.path, withDestinationPath: "python3.13")

        XCTAssertEqual(try configuration(resources: resources).executableURL, python)
    }

    func testBundledRuntimeCannotLinkToExternalInterpreter() throws {
        let folder = try temporaryFolder()
        let resources = try makeBundle(in: folder)
        let python = resources.appendingPathComponent("python/bin/python3")
        let outside = folder.appendingPathComponent("outside-python3")
        try makeFile(outside, executable: true)
        try FileManager.default.removeItem(at: python)
        try FileManager.default.createSymbolicLink(at: python, withDestinationURL: outside)

        XCTAssertThrowsError(try configuration(resources: resources)) { error in
            XCTAssertEqual(error as? BundleLaunch.ConfigurationError, .missingBundledRuntime(python.path))
        }
    }

    func testBundledBootstrapCannotLinkToExternalSource() throws {
        let folder = try temporaryFolder()
        let resources = try makeBundle(in: folder)
        let bootstrap = resources.appendingPathComponent("bridge/bootstrap.py")
        let outside = folder.appendingPathComponent("outside-bootstrap.py")
        try makeFile(outside)
        try FileManager.default.removeItem(at: bootstrap)
        try FileManager.default.createSymbolicLink(at: bootstrap, withDestinationURL: outside)

        XCTAssertThrowsError(try configuration(resources: resources)) { error in
            XCTAssertEqual(error as? BundleLaunch.ConfigurationError, .missingBundledBridge(bootstrap.path))
        }
    }

    func testDeveloperLaunchRetainsConfiguredInterpreterProjectAndEnvironment() throws {
        let folder = try temporaryFolder()
        let resources = try makeBundle(in: folder)
        let project = folder.appendingPathComponent("Developer Project")
        let python = folder.appendingPathComponent("Developer Python/bin/python3")
        try makeFile(python, executable: true)
        try makeFile(project.appendingPathComponent("perch/bridge.py"))
        let launch = try BundleLaunch.configuration(
            resourceURL: resources, isPackaged: false,
            pythonPath: python.path, projectRoot: project.path,
            environment: ["PERCH_ROOT": project.path, "PYTHONPATH": "/developer/modules"]
        )

        XCTAssertEqual(launch.executableURL, python)
        XCTAssertEqual(launch.arguments, ["-u", "-m", "perch.bridge"])
        XCTAssertEqual(launch.workingDirectoryURL.path, project.path)
        XCTAssertEqual(launch.environment["PERCH_ROOT"], project.path)
        XCTAssertEqual(launch.environment["PYTHONPATH"], "/developer/modules")
        XCTAssertEqual(launch.environment["PYTHONUNBUFFERED"], "1")
    }

    func testDeveloperLaunchStillRejectsMissingPythonAndSource() throws {
        let folder = try temporaryFolder()
        let python = folder.appendingPathComponent("python3")
        XCTAssertThrowsError(try BundleLaunch.configuration(
            resourceURL: nil, isPackaged: false, pythonPath: python.path,
            projectRoot: folder.path, environment: [:]
        )) { error in
            XCTAssertEqual(error as? BundleLaunch.ConfigurationError, .invalidDeveloperPython(python.path))
        }
        try makeFile(python, executable: true)
        XCTAssertThrowsError(try BundleLaunch.configuration(
            resourceURL: nil, isPackaged: false, pythonPath: python.path,
            projectRoot: folder.path, environment: [:]
        )) { error in
            XCTAssertEqual(error as? BundleLaunch.ConfigurationError, .invalidProjectRoot)
        }
    }

    private func configuration(resources: URL, environment: [String: String] = [:]) throws -> BundleLaunch {
        try BundleLaunch.configuration(
            resourceURL: resources, isPackaged: true,
            pythonPath: "invalid developer python", projectRoot: "invalid developer root",
            environment: environment
        )
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Perch Launch Tests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func makeBundle(in folder: URL) throws -> URL {
        let resources = folder.appendingPathComponent("Perch Preview.app/Contents/Resources", isDirectory: true)
        try makeFile(resources.appendingPathComponent("python/bin/python3"), executable: true)
        try makeFile(resources.appendingPathComponent("bridge/bootstrap.py"))
        try makeFile(resources.appendingPathComponent("bridge/perch/bridge.py"))
        return resources
    }

    private func makeFile(_ url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# Test fixture; not executed.\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }
}
