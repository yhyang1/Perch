import Foundation
import PerchSupport

struct BridgeFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Main-actor-owned subprocess. stdout is framed JSON only; stderr is diagnostic text.
@MainActor
final class BridgeClient {
    typealias Completion = (Result<Any, Error>) -> Void
    var onEvent: ((String, [String: Any]) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    var onExit: ((String) -> Void)?

    private var process: Process?
    private var stdin: Pipe?
    private var stdout: Pipe?
    private var stderr: Pipe?
    private var framer = JSONLineFramer()
    private var pending: [String: Completion] = [:]
    private var generation = UUID()
    private let resourceURL: URL?
    let isPackaged: Bool

    init(bundle: Bundle = .main) {
        resourceURL = bundle.resourceURL
        isPackaged = bundle.object(forInfoDictionaryKey: "PerchBundledRuntime") as? Bool == true
    }

    var isRunning: Bool { process?.isRunning == true }

    func start(pythonPath: String, projectRoot: String) throws {
        stop()
        let launch = try BundleLaunch.configuration(
            resourceURL: resourceURL,
            isPackaged: isPackaged,
            pythonPath: pythonPath,
            projectRoot: projectRoot,
            environment: ProcessInfo.processInfo.environment
        )

        let task = Process()
        let input = Pipe(), output = Pipe(), diagnostics = Pipe()
        let token = UUID()
        generation = token
        framer = JSONLineFramer()
        task.executableURL = launch.executableURL
        task.arguments = launch.arguments
        task.currentDirectoryURL = launch.workingDirectoryURL
        task.environment = launch.environment
        task.standardInput = input
        task.standardOutput = output
        task.standardError = diagnostics
        process = task
        stdin = input
        stdout = output
        stderr = diagnostics

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.consume(data)
            }
        }
        diagnostics.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, !data.isEmpty else { return }
                self.onDiagnostic?(String(decoding: data, as: UTF8.self))
            }
        }
        task.terminationHandler = { [weak self] task in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                let message = self.isPackaged
                    ? "Connection service exited (status \(task.terminationStatus)). Check your SSH configuration and Diagnostics."
                    : "Bridge exited (status \(task.terminationStatus)). Check the Python runtime, SSH configuration, and diagnostics."
                self.stop()
                self.onExit?(message)
            }
        }
        do {
            try task.run()
        } catch {
            stop()
            throw BridgeFailure(message: "Could not start the connection service: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func request(_ method: String, params: [String: Any] = [:], completion: Completion? = nil) -> String? {
        guard isRunning, let input = stdin?.fileHandleForWriting else {
            completion?(.failure(BridgeFailure(message: "The local bridge is not running.")))
            return nil
        }
        let id = UUID().uuidString
        do {
            var data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
            data.append(10)
            pending[id] = completion ?? { _ in }
            try input.write(contentsOf: data)
            return id
        } catch {
            pending.removeValue(forKey: id)
            completion?(.failure(error))
            return nil
        }
    }

    func stop() {
        generation = UUID()
        let task = process
        process = nil
        stdout?.fileHandleForReading.readabilityHandler = nil
        stderr?.fileHandleForReading.readabilityHandler = nil
        task?.terminationHandler = nil
        try? stdin?.fileHandleForWriting.close()
        try? stdout?.fileHandleForReading.close()
        try? stderr?.fileHandleForReading.close()
        stdin = nil
        stdout = nil
        stderr = nil
        if task?.isRunning == true { task?.terminate() }
        let callbacks = Array(pending.values)
        pending.removeAll()
        for callback in callbacks {
            callback(.failure(BridgeFailure(message: "The bridge was stopped.")))
        }
    }

    private func consume(_ data: Data) {
        do {
            for line in try framer.append(data) {
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw BridgeFailure(message: "The bridge wrote a non-object JSON frame to stdout.")
                }
                if let event = message["event"] as? String {
                    onEvent?(event, message["payload"] as? [String: Any] ?? [:])
                } else if let id = message["id"] as? String, let callback = pending.removeValue(forKey: id) {
                    if let error = message["error"], !(error is NSNull) {
                        let description = (error as? [String: Any])?["message"] as? String ?? String(describing: error)
                        callback(.failure(BridgeFailure(message: description)))
                    } else if let result = message["result"] {
                        callback(.success(result))
                    } else {
                        callback(.failure(BridgeFailure(message: "The bridge response has no result or error.")))
                    }
                }
            }
        } catch {
            let message = "Bridge protocol error: \(error.localizedDescription)"
            stop()
            onExit?(message)
        }
    }
}
