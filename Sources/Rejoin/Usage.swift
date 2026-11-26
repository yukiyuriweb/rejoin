import Darwin
import Foundation

struct UsageWindow: Codable, Sendable {
    let remainingPercent: Double
    let resetsAt: Date?

    init?(usedPercent: Double?, resetEpoch: Double?) {
        guard let usedPercent, (0...100).contains(usedPercent) else { return nil }
        remainingPercent = 100 - usedPercent
        resetsAt = resetEpoch.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
    }

    func isCurrent(at date: Date) -> Bool {
        resetsAt.map { $0 > date } ?? true
    }
}

struct UsageSnapshot: Codable, Sendable {
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
    let receivedAt: Date

    init?(fiveHour: UsageWindow?, weekly: UsageWindow?, receivedAt: Date = .now) {
        guard fiveHour != nil || weekly != nil else { return nil }
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.receivedAt = receivedAt
    }
}

enum ClaudeUsage {
    private struct StatusLine: Decodable {
        struct Limits: Decodable {
            struct Window: Decodable {
                let used_percentage: Double?
                let resets_at: Double?

                var usage: UsageWindow? { UsageWindow(usedPercent: used_percentage, resetEpoch: resets_at) }
            }

            let five_hour: Window?
            let seven_day: Window?
        }

        let rate_limits: Limits?
    }

    static let cache = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Caches/local.rejoin/claude-usage.json")

    static func load(from file: URL = cache) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    static func record(_ input: Data, to file: URL = cache) throws {
        let limits = try JSONDecoder().decode(StatusLine.self, from: input).rate_limits
        guard let snapshot = UsageSnapshot(fiveHour: limits?.five_hour?.usage, weekly: limits?.seven_day?.usage) else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
    }
}

enum CodexUsage {
    private struct Response: Decodable {
        struct Result: Decodable {
            struct Limits: Decodable {
                struct Window: Decodable {
                    let usedPercent: Double?
                    let windowDurationMins: Int?
                    let resetsAt: Double?

                    var usage: UsageWindow? { UsageWindow(usedPercent: usedPercent, resetEpoch: resetsAt) }
                }

                let primary: Window?
                let secondary: Window?

                func usage(minutes: Int) -> UsageWindow? {
                    [primary, secondary].compactMap { $0 }.first { $0.windowDurationMins == minutes }?.usage
                }
            }

            let rateLimits: Limits?
            let rateLimitsByLimitId: [String: Limits]?

            var snapshot: UsageSnapshot? {
                guard let limits = rateLimitsByLimitId?["codex"] ?? rateLimits else { return nil }
                return UsageSnapshot(fiveHour: limits.usage(minutes: 300), weekly: limits.usage(minutes: 10_080))
            }
        }

        let id: Int?
        let result: Result?
    }

    static func load(timeout: TimeInterval = 12) -> UsageSnapshot? {
        let process = codexProcess(["app-server", "--listen", "stdio://"])
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let writer = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { return nil }

        do {
            try process.run()
            defer {
                try? writer.close()
                try? reader.close()
                if process.isRunning { process.terminate() }
            }
            return try readLimits(writer: writer, reader: reader, timeout: timeout)
        } catch {
            return nil
        }
    }

    private static func readLimits(writer: FileHandle, reader: FileHandle, timeout: TimeInterval) throws -> UsageSnapshot? {
        func send(_ message: String) throws {
            try writer.write(contentsOf: Data((message + "\n").utf8))
        }

        try send(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"rejoin","title":"Rejoin","version":"0.1.0"}}}"#)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        let decoder = JSONDecoder()
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(ceil(remaining * 1000)))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let count = chunk.withUnsafeMutableBytes { read(reader.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            pending.append(contentsOf: chunk.prefix(count))

            while let newline = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                guard let response = try? decoder.decode(Response.self, from: line) else { continue }
                switch response.id {
                case 1:
                    guard response.result != nil else { return nil }
                    try send(#"{"method":"initialized"}"#)
                    try send(#"{"id":2,"method":"account/rateLimits/read"}"#)
                case 2:
                    return response.result?.snapshot
                default:
                    continue
                }
            }
            guard pending.count <= 1_048_576 else { return nil }
        }
    }
}
