// Minimal MCP stdio server core: newline-delimited JSON-RPC 2.0, no dependencies.
// Handlers return a String (text content) or [[String: Any]] (raw MCP content, e.g. images).
import Foundation

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Tool {
    let name: String
    let description: String
    let properties: [String: Any]
    let required: [String]
    let handler: ([String: Any]) throws -> Any
}

func prop(_ type: String, _ description: String) -> [String: Any] { ["type": type, "description": description] }

func log(_ message: String) { fputs("[\(serverName)] \(message)\n", stderr) }

/// Cleanup hooks run on EOF / SIGTERM / SIGINT (e.g. stop safaridriver).
var exitHooks: [() -> Void] = []
func runExitHooksAndExit(_ code: Int32) -> Never {
    for h in exitHooks { h() }
    exit(code)
}

private func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String, _ def: String = "") -> String {
        let v: String
        if let s = self[k] as? String { v = s } else if let n = self[k] as? NSNumber { v = n.stringValue } else { v = "" }
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? def : v
    }
    func int(_ k: String, _ def: Int) -> Int {
        if let i = self[k] as? Int { return i }
        if let d = self[k] as? Double { return Int(d) }
        if let s = self[k] as? String, let i = Int(s) { return i }
        return def
    }
    func optBool(_ k: String) -> Bool? {
        if let b = self[k] as? Bool { return b }
        if let s = self[k] as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
        return nil
    }
    func bool(_ k: String, _ def: Bool) -> Bool { optBool(k) ?? def }
    func require(_ k: String) throws -> String {
        let v = str(k)
        if v.isEmpty { throw ToolError("Missing required argument '\(k)'") }
        return v
    }
}

func runServer(name: String, version: String, tools: [Tool]) -> Never {
    setbuf(stdout, nil)
    setbuf(stderr, nil)
    signal(SIGTERM) { _ in runExitHooksAndExit(0) }
    signal(SIGINT) { _ in runExitHooksAndExit(0) }

    func handle(_ json: [String: Any]) {
        guard let method = json["method"] as? String else { return }
        let id = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]
        func result(_ r: [String: Any]) { if let id { send(["jsonrpc": "2.0", "id": id, "result": r]) } }
        func error(_ code: Int, _ message: String) {
            if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) }
        }
        switch method {
        case "initialize":
            result([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-03-26",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": name, "version": version],
            ])
        case "ping":
            result([:])
        case "tools/list":
            result(["tools": tools.map { t in
                ["name": t.name, "description": t.description,
                 "inputSchema": ["type": "object", "properties": t.properties, "required": t.required]] as [String: Any]
            }])
        case "tools/call":
            let toolName = params["name"] as? String ?? ""
            guard let tool = tools.first(where: { $0.name == toolName }) else { return error(-32602, "Unknown tool: \(toolName)") }
            do {
                let out = try tool.handler(params["arguments"] as? [String: Any] ?? [:])
                let content = (out as? [[String: Any]]) ?? [["type": "text", "text": "\(out)"]]
                result(["content": content])
            } catch {
                log("\(toolName) failed: \(error)")
                result(["content": [["type": "text", "text": "Error: \(error)"]], "isError": true])
            }
        default:
            if !method.hasPrefix("notifications/") { error(-32601, "Method not found: \(method)") }
        }
    }

    var buffer = Data()
    while true {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty { runExitHooksAndExit(0) }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            handle(obj)
        }
    }
}

/// Block on an async callback (CLI tool; callbacks arrive on background queues).
func waitFor<T>(timeout: TimeInterval = 120, _ start: (@escaping (T) -> Void) -> Void) -> T? {
    let sem = DispatchSemaphore(value: 0)
    var value: T?
    start { v in value = v; sem.signal() }
    return sem.wait(timeout: .now() + timeout) == .success ? value : nil
}

func truncate(_ s: String, _ max: Int) -> String {
    s.count > max ? String(s.prefix(max)) + "\n\n[… truncated at \(max) characters; pass a higher maxChars to see more]" : s
}
