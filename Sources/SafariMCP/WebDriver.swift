// Full browser automation through safaridriver (W3C WebDriver, built into macOS).
// Runs in a separate, clean automation window — not the user's tabs or logins.
import Foundation

private let elementKey = "element-6066-11e4-a52e-4f735466cecf"

final class SafariDriver {
    static let shared = SafariDriver()

    private var process: Process?
    private var port = 0
    private var sessionId: String?

    private init() {
        exitHooks.append { [weak self] in self?.shutdown() }
    }

    // MARK: Lifecycle

    private func startDriver() throws {
        if let process, process.isRunning { return }
        port = Int.random(in: 20000...40000)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/safaridriver")
        p.arguments = ["--port", String(port)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        // Wait until it answers /status.
        for _ in 0..<40 {
            if (try? http("GET", "/status", timeout: 1)) != nil { return }
            Thread.sleep(forTimeInterval: 0.15)
        }
        throw ToolError("safaridriver didn't start")
    }

    func session() throws -> String {
        if let sessionId { return sessionId }
        try startDriver()
        do {
            let v = try http("POST", "/session", ["capabilities": ["alwaysMatch": ["browserName": "safari"]]], timeout: 60)
            guard let id = (v as? [String: Any])?["sessionId"] as? String else { throw ToolError("No sessionId from safaridriver") }
            sessionId = id
            return id
        } catch let e as ToolError {
            let m = e.description.lowercased()
            if m.contains("remote automation") || m.contains("enable") || m.contains("allow") {
                throw ToolError("\(e)\nOne-time setup: run `sudo safaridriver --enable` in Terminal (and if asked, Safari → Develop → Allow Remote Automation).")
            }
            if m.contains("session") && m.contains("already") {
                throw ToolError("\(e)\nSafari allows one automation session at a time — close the other one (or call safari_auto_close).")
            }
            throw e
        }
    }

    func shutdown() {
        if let sessionId { _ = try? http("DELETE", "/session/\(sessionId)", timeout: 5) }
        sessionId = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    var active: Bool { sessionId != nil }

    // MARK: HTTP

    @discardableResult
    func http(_ method: String, _ path: String, _ body: [String: Any]? = nil, timeout: TimeInterval = 60) throws -> Any? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw ToolError("Bad URL") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if method == "POST" {
            req.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:])
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let res: (Data?, Error?)? = waitFor(timeout: timeout + 5) { done in
            URLSession.shared.dataTask(with: req) { d, _, e in done((d, e)) }.resume()
        }
        guard let res else { throw ToolError("safaridriver timed out") }
        if let e = res.1 { throw ToolError("safaridriver: \(e.localizedDescription)") }
        guard let data = res.0, !data.isEmpty else { return nil }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let value = json?["value"]
        if let v = value as? [String: Any], let err = v["error"] as? String {
            let msg = v["message"] as? String ?? ""
            if err == "invalid session id" { sessionId = nil }
            throw ToolError("\(err): \(msg)")
        }
        return value
    }

    func cmd(_ method: String, _ path: String, _ body: [String: Any]? = nil, timeout: TimeInterval = 60) throws -> Any? {
        let s = try session()
        return try http(method, "/session/\(s)\(path)", body, timeout: timeout)
    }

    func script(_ js: String, _ args: [Any] = []) throws -> Any? {
        try cmd("POST", "/execute/sync", ["script": js, "args": args])
    }

    func find(_ selector: String) throws -> String {
        let v = try cmd("POST", "/element", ["using": "css selector", "value": selector])
        guard let id = (v as? [String: Any])?[elementKey] as? String else { throw ToolError("No element matches \(selector)") }
        return id
    }

    func pageInfo() -> String {
        let title = (try? cmd("GET", "/title")) as? String ?? ""
        let url = (try? cmd("GET", "/url")) as? String ?? ""
        return "Title: \(title)\nURL:   \(url)"
    }
}

let driver = SafariDriver.shared

/// `ref` (from safari_auto_elements) or `selector` (CSS) → CSS selector.
func targetSelector(_ a: [String: Any]) throws -> String {
    let ref = a.int("ref", 0)
    if ref > 0 { return "[data-mcp-ref=\"\(ref)\"]" }
    return try a.require("selector")
}

// MARK: - Tools

func autoOpen(_ a: [String: Any]) throws -> Any {
    var url = try a.require("url")
    if !url.contains("://") { url = "https://" + url }
    try driver.cmd("POST", "/url", ["url": url], timeout: 90)
    return driver.pageInfo() + "\n\nNext: safari_auto_elements to see clickable elements, or safari_auto_get_text."
}

let elementsJS = """
const max = arguments[0];
document.querySelectorAll('[data-mcp-ref]').forEach(e => e.removeAttribute('data-mcp-ref'));
const els = document.querySelectorAll('a[href],button,input:not([type=hidden]),select,textarea,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[contenteditable=true],summary,[onclick]');
const out = []; let n = 0;
for (const e of els) {
  const r = e.getBoundingClientRect(), st = getComputedStyle(e);
  if ((r.width === 0 && r.height === 0) || st.visibility === 'hidden' || st.display === 'none') continue;
  n++; e.setAttribute('data-mcp-ref', n);
  let label = (e.innerText || e.value || e.getAttribute('aria-label') || e.getAttribute('placeholder') || e.getAttribute('title') || e.getAttribute('name') || e.getAttribute('alt') || '').trim().replace(/\\s+/g, ' ').slice(0, 80);
  let kind = e.tagName.toLowerCase() + (e.type && e.tagName !== 'BUTTON' ? '[' + e.type + ']' : '');
  if (e.tagName === 'SELECT') label += ' {' + [...e.options].slice(0, 8).map(o => o.text.trim()).join(' | ') + '}';
  const href = e.getAttribute('href');
  out.push('[' + n + '] ' + kind + '  ' + label + (href ? '  → ' + href.slice(0, 100) : '') + (r.top > innerHeight ? '  (below fold)' : ''));
  if (n >= max) break;
}
return out.join('\\n');
"""

func autoElements(_ a: [String: Any]) throws -> Any {
    let list = try driver.script(elementsJS, [max(10, a.int("max", 150))]) as? String ?? ""
    return driver.pageInfo() + "\n\n" + (list.isEmpty ? "No interactive elements found." : list + "\n\nUse ref numbers with safari_auto_click / safari_auto_type.")
}

func autoClick(_ a: [String: Any]) throws -> Any {
    let sel = try targetSelector(a)
    let el = try driver.find(sel)
    do {
        try driver.cmd("POST", "/element/\(el)/click")
    } catch {
        // Fallback for elements WebDriver considers not interactable (overlays, off-screen).
        _ = try driver.script("const e = document.querySelector(arguments[0]); e.scrollIntoView({block:'center'}); e.click(); return true;", [sel])
    }
    Thread.sleep(forTimeInterval: 0.4)
    return "Clicked \(sel).\n" + driver.pageInfo()
}

func autoType(_ a: [String: Any]) throws -> Any {
    let sel = try targetSelector(a)
    let text = a.str("text")
    let el = try driver.find(sel)
    if a.bool("clear", true) { _ = try? driver.cmd("POST", "/element/\(el)/clear") }
    try driver.cmd("POST", "/element/\(el)/value", ["text": text + (a.bool("submit", false) ? "\u{E007}" : "")])
    if a.bool("submit", false) { Thread.sleep(forTimeInterval: 0.8) }
    return "Typed into \(sel)\(a.bool("submit", false) ? " and pressed Enter" : "").\n" + driver.pageInfo()
}

func autoSelect(_ a: [String: Any]) throws -> Any {
    let sel = try targetSelector(a)
    let option = try a.require("option")
    let r = try driver.script("""
    const s = document.querySelector(arguments[0]); if (!s) return 'not found';
    const o = [...s.options].find(o => o.text.trim() === arguments[1] || o.value === arguments[1]) || [...s.options].find(o => o.text.toLowerCase().includes(arguments[1].toLowerCase()));
    if (!o) return 'no option ' + arguments[1];
    s.value = o.value; s.dispatchEvent(new Event('input', {bubbles:true})); s.dispatchEvent(new Event('change', {bubbles:true}));
    return 'selected ' + o.text.trim();
    """, [sel, option]) as? String ?? ""
    return r
}

func autoGetText(_ a: [String: Any]) throws -> Any {
    let sel = a.str("selector", "body")
    let text = try driver.script("const e = document.querySelector(arguments[0]); return e ? e.innerText : null;", [sel]) as? String
    guard let text else { throw ToolError("No element matches \(sel)") }
    return driver.pageInfo() + "\n\n" + truncate(text, max(500, a.int("maxChars", 30000)))
}

func autoScreenshot(_ a: [String: Any]) throws -> Any {
    guard let b64 = try driver.cmd("GET", "/screenshot") as? String else { throw ToolError("No screenshot returned") }
    return [["type": "image", "data": b64, "mimeType": "image/png"], ["type": "text", "text": driver.pageInfo()]] as [[String: Any]]
}

func autoRunJS(_ a: [String: Any]) throws -> Any {
    let js = try a.require("script")
    let body = js.contains("return") ? js : "return (\(js));"
    let v = try driver.script(body)
    if v == nil || v is NSNull { return "(no return value)" }
    if let s = v as? String { return truncate(s, 30000) }
    if let d = try? JSONSerialization.data(withJSONObject: v!, options: [.prettyPrinted, .fragmentsAllowed]), let s = String(data: d, encoding: .utf8) {
        return truncate(s, 30000)
    }
    return "\(v!)"
}

func autoNavigate(_ a: [String: Any]) throws -> Any {
    let action = a.str("action", "back").lowercased()
    guard ["back", "forward", "refresh"].contains(action) else { throw ToolError("action must be back, forward or refresh") }
    try driver.cmd("POST", "/\(action)")
    return driver.pageInfo()
}

func autoWaitFor(_ a: [String: Any]) throws -> Any {
    let sel = a.str("selector")
    let text = a.str("text")
    guard !sel.isEmpty || !text.isEmpty else { throw ToolError("Pass selector and/or text") }
    let deadline = Date().addingTimeInterval(TimeInterval(max(1, min(a.int("timeoutSeconds", 10), 60))))
    while Date() < deadline {
        let ok = try driver.script("""
        const s = arguments[0], t = arguments[1];
        const scope = s ? document.querySelector(s) : document.body;
        if (!scope) return false;
        return t ? scope.innerText.includes(t) : true;
        """, [sel, text]) as? Bool ?? false
        if ok { return "Found \(sel.isEmpty ? "" : sel + " ")\(text.isEmpty ? "" : "“\(text)”").\n" + driver.pageInfo() }
        Thread.sleep(forTimeInterval: 0.25)
    }
    throw ToolError("Timed out waiting for \(sel.isEmpty ? "" : sel + " ")\(text.isEmpty ? "" : "“\(text)”")")
}

func autoClose(_ a: [String: Any]) throws -> Any {
    let was = driver.active
    driver.shutdown()
    return was ? "Automation session closed." : "No automation session was running."
}
