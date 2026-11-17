// Control the user's real Safari (their windows, tabs and logins) via Apple Events.
import AppKit
import Foundation
import SQLite3

let FS = "\u{1F}"
let RS = "\u{1E}"

func q(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

func safariRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty
}

func requireSafariRunning() throws {
    if !safariRunning() { throw ToolError("Safari isn't running. Use safari_open_url to start it.") }
}

@discardableResult
func runSafari(_ body: String) throws -> String {
    let source = """
    with timeout of 120 seconds
    tell application "Safari"
    \(body)
    end tell
    end timeout
    """
    guard let script = NSAppleScript(source: source) else { throw ToolError("Could not create AppleScript") }
    var errorInfo: NSDictionary?
    let result = script.executeAndReturnError(&errorInfo)
    if let errorInfo {
        let msg = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
        let num = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
        if num == -1743 {
            throw ToolError("Not allowed to control Safari. Allow it in System Settings → Privacy & Security → Automation.")
        }
        if msg.lowercased().contains("javascript") {
            throw ToolError("\(msg)\nEnable it once: Safari → Settings → Advanced → 'Show features for web developers', then Develop → 'Allow JavaScript from Apple Events'.")
        }
        throw ToolError("\(msg) (\(num))")
    }
    return result.stringValue ?? ""
}

/// AppleScript reference to a tab: explicit window/tab indexes, or the front window's current tab.
func tabRef(_ a: [String: Any]) -> String {
    let w = a.int("window", 0), t = a.int("tab", 0)
    if w > 0 && t > 0 { return "tab \(t) of window \(w)" }
    if w > 0 { return "current tab of window \(w)" }
    if t > 0 { return "tab \(t) of front window" }
    return "current tab of front window"
}

func listTabs(_ a: [String: Any]) throws -> Any {
    try requireSafariRunning()
    let raw = try runSafari("""
    set FS to character id 31
    set RS to character id 30
    set out to ""
    set wi to 0
    repeat with w in windows
        set wi to wi + 1
        try
            set ct to index of current tab of w
            set ti to 0
            repeat with t in tabs of w
                set ti to ti + 1
                set u to ""
                try
                    set u to URL of t
                end try
                if u is missing value then set u to ""
                set out to out & wi & FS & ti & FS & (name of t) & FS & u & FS & ((ti = ct) as string) & RS
            end repeat
        end try
    end repeat
    return out
    """)
    let rows = raw.components(separatedBy: RS).filter { !$0.isEmpty }.map { $0.components(separatedBy: FS) }
    if rows.isEmpty { return "Safari has no open tabs." }
    var lines: [String] = []
    var lastWindow = ""
    for r in rows where r.count >= 5 {
        if r[0] != lastWindow { lines.append("\(lines.isEmpty ? "" : "\n")Window \(r[0])\(r[0] == "1" ? " (front)" : "")"); lastWindow = r[0] }
        lines.append("  \(r[4] == "true" ? "▶" : " ") [\(r[1])] \(r[2])\n      \(r[3])")
    }
    return "\(rows.count) tab(s):\n\n" + lines.joined(separator: "\n") + "\n\nAddress a tab with window + tab numbers."
}

func getPage(_ a: [String: Any]) throws -> Any {
    try requireSafariRunning()
    let html = a.str("format", "text").lowercased() == "html"
    let raw = try runSafari("""
    set FS to character id 31
    set t to \(tabRef(a))
    set u to ""
    try
        set u to URL of t
    end try
    return (name of t) & FS & u & FS & (\(html ? "source" : "text") of t)
    """)
    let f = raw.components(separatedBy: FS)
    guard f.count >= 3 else { return raw }
    return "Title: \(f[0])\nURL:   \(f[1])\n\n" + truncate(f[2...].joined(separator: FS), max(500, a.int("maxChars", 30000)))
}

func openURL(_ a: [String: Any]) throws -> Any {
    var url = try a.require("url")
    if !url.contains("://") { url = "https://" + url }
    let newWindow = a.bool("newWindow", false)
    try runSafari("""
    activate
    if (count of windows) = 0 or \(newWindow) then
        make new document with properties {URL:\(q(url))}
    else
        tell front window to set current tab to (make new tab with properties {URL:\(q(url))})
    end if
    return "ok"
    """)
    return "Opened \(url) in Safari\(newWindow ? " (new window)" : " (new tab)")."
}

func switchTab(_ a: [String: Any]) throws -> Any {
    try requireSafariRunning()
    let w = max(1, a.int("window", 1)), t = a.int("tab", 0)
    guard t > 0 else { throw ToolError("Missing required argument 'tab'") }
    let name = try runSafari("""
    set current tab of window \(w) to tab \(t) of window \(w)
    set index of window \(w) to 1
    activate
    return name of current tab of front window
    """)
    return "Switched to “\(name)”."
}

func closeTab(_ a: [String: Any]) throws -> Any {
    try requireSafariRunning()
    guard a.int("tab", 0) > 0 else { throw ToolError("Missing required argument 'tab' (see safari_list_tabs)") }
    let name = try runSafari("""
    set t to \(tabRef(a))
    set n to name of t
    close t
    return n
    """)
    return "Closed tab “\(name)”."
}

func runJavaScriptInTab(_ a: [String: Any]) throws -> Any {
    try requireSafariRunning()
    let script = try a.require("script")
    let out = try runSafari("""
    set r to do JavaScript \(q(script)) in \(tabRef(a))
    if r is missing value then return ""
    return r as string
    """)
    return out.isEmpty ? "(no return value — end your script with an expression, e.g. JSON.stringify(...))" : truncate(out, 30000)
}

// MARK: - History (Safari's History.db, read-only; needs Full Disk Access)

func searchHistory(_ a: [String: Any]) throws -> Any {
    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/History.db").path
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        throw ToolError("Can't read Safari history. Grant Full Disk Access to the Claude app (System Settings → Privacy & Security).")
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 2000)

    let appleEpoch = 978_307_200.0
    var conds = ["v.load_successful = 1"]
    var binds: [String] = []
    for w in a.str("query").split(whereSeparator: \.isWhitespace) {
        conds.append("(i.url LIKE ? ESCAPE '\\' OR v.title LIKE ? ESCAPE '\\')")
        let pat = "%" + String(w).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        binds += [pat, pat]
    }
    if !a.str("since").isEmpty {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: a.str("since")) else { throw ToolError("Invalid since, expected YYYY-MM-DD") }
        conds.append("v.visit_time >= \(d.timeIntervalSince1970 - appleEpoch)")
    }
    let limit = max(1, min(a.int("limit", 25), 500))
    let sql = """
    SELECT i.url, IFNULL((SELECT title FROM history_visits WHERE history_item = i.id AND title IS NOT NULL ORDER BY visit_time DESC LIMIT 1), ''),
           MAX(v.visit_time), i.visit_count
    FROM history_items i JOIN history_visits v ON v.history_item = i.id
    WHERE \(conds.joined(separator: " AND "))
    GROUP BY i.id ORDER BY MAX(v.visit_time) DESC LIMIT \(limit)
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw ToolError("History query failed: \(String(cString: sqlite3_errmsg(db)))")
    }
    defer { sqlite3_finalize(stmt) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (i, b) in binds.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), b, -1, transient) }
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm"
    var lines: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let url = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let when = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2) + appleEpoch)
        let count = sqlite3_column_int(stmt, 3)
        lines.append("• \(title.isEmpty ? url : title)\n  \(url)\n  last visit \(df.string(from: when)) · \(count) visit(s)")
    }
    return lines.isEmpty ? "No history matches." : "\(lines.count) result(s):\n\n" + lines.joined(separator: "\n\n")
}
