import Foundation

/// Resolves a launch without starting a process. Bundle inputs are explicit so the
/// installed app and the developer executable can be checked independently.
public struct BundleLaunch {
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectoryURL: URL
    public let environment: [String: String]

    public enum ConfigurationError: Error, LocalizedError, Equatable {
        case missingResources
        case missingBundledRuntime(String)
        case missingBundledBridge(String)
        case invalidDeveloperPython(String)
        case invalidProjectRoot

        public var errorDescription: String? {
            switch self {
            case .missingResources:
                return "The Perch app is incomplete: its Resources folder is missing. Download or reinstall Perch."
            case .missingBundledRuntime(let path):
                return "The Perch app's built-in Python runtime is missing or unusable at \(path). Download or reinstall Perch."
            case .missingBundledBridge(let path):
                return "The Perch app's built-in bridge is missing or unreadable at \(path). Download or reinstall Perch."
            case .invalidDeveloperPython(let path):
                return "Python is not executable at \(path). Choose an existing Python 3.9+ interpreter."
            case .invalidProjectRoot:
                return "Choose the Perch project root containing perch/bridge.py."
            }
        }
    }

    public static func configuration(
        resourceURL: URL?,
        isPackaged: Bool,
        pythonPath: String,
        projectRoot: String,
        environment: [String: String]
    ) throws -> BundleLaunch {
        let files = FileManager.default
        if isPackaged {
            guard let resources = resourceURL?.standardizedFileURL,
                  resources.isFileURL,
                  InputValidation.absolutePath(resources.path) else {
                throw ConfigurationError.missingResources
            }
            var isDirectory: ObjCBool = false
            guard files.fileExists(atPath: resources.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ConfigurationError.missingResources
            }

            let python = resources.appendingPathComponent("python/bin/python3")
            let bridge = resources.appendingPathComponent("bridge", isDirectory: true)
            let bootstrap = bridge.appendingPathComponent("bootstrap.py")
            guard regularFile(python, within: resources), files.isExecutableFile(atPath: python.path) else {
                throw ConfigurationError.missingBundledRuntime(python.path)
            }
            for file in [bootstrap, bridge.appendingPathComponent("perch/bridge.py")] {
                guard regularFile(file, within: resources), files.isReadableFile(atPath: file.path) else {
                    throw ConfigurationError.missingBundledBridge(file.path)
                }
            }
            return BundleLaunch(
                executableURL: python,
                arguments: ["-I", "-S", "-B", "-u", bootstrap.path],
                workingDirectoryURL: bridge,
                environment: cleanEnvironment(environment)
            )
        }

        // `swift run` keeps its configurable interpreter and project directory.
        guard InputValidation.absolutePath(pythonPath), files.isExecutableFile(atPath: pythonPath) else {
            throw ConfigurationError.invalidDeveloperPython(pythonPath)
        }
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL
        guard InputValidation.absolutePath(projectRoot),
              files.fileExists(atPath: root.appendingPathComponent("perch/bridge.py").path) else {
            throw ConfigurationError.invalidProjectRoot
        }
        var developerEnvironment = environment
        developerEnvironment["PYTHONUNBUFFERED"] = "1"
        return BundleLaunch(
            executableURL: URL(fileURLWithPath: pythonPath),
            arguments: ["-u", "-m", "perch.bridge"],
            workingDirectoryURL: root,
            environment: developerEnvironment
        )
    }

    /// Keep SSH settings, HOME and PATH; discard inherited runtime overrides.
    public static func cleanEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            !key.hasPrefix("PYTHON") && !key.hasPrefix("DYLD_") && key != "PERCH_ROOT"
        }
    }

    private static func regularFile(_ url: URL, within resources: URL) -> Bool {
        let root = resources.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
