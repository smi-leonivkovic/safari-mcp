// safari-mcp — Safari MCP server in pure Swift, no dependencies.
//   safari_*       → your real Safari (tabs, logins) via Apple Events
//   safari_auto_*  → full automation in a separate window via safaridriver (WebDriver)
//   safari_search_history → Safari's History.db (read-only)
import Foundation

let serverName = "safari-mcp"

let tabProps: [String: Any] = [
    "window": prop("integer", "Window number from safari_list_tabs (default: front window)"),
    "tab": prop("integer", "Tab number from safari_list_tabs (default: current tab)"),
]
let targetProps: [String: Any] = [
    "ref": prop("integer", "Element number from safari_auto_elements"),
    "selector": prop("string", "CSS selector (alternative to ref)"),
]

runServer(name: serverName, version: "1.0.0", tools: [
    // Real Safari
    Tool(name: "safari_list_tabs", description: "List open Safari windows and tabs (title + URL) in the user's real Safari.",
         properties: [:], required: [], handler: listTabs),
    Tool(name: "safari_get_page", description: "Read the text (or HTML) of a tab in the user's real Safari — works with pages they're logged into. Defaults to the current tab.",
         properties: tabProps.merging(["format": prop("string", "text (default) or html"),
                                       "maxChars": prop("integer", "Truncate after this many characters (default 30000)")]) { $1 },
         required: [], handler: getPage),
    Tool(name: "safari_open_url", description: "Open a URL in the user's real Safari (new tab by default).",
         properties: ["url": prop("string", "URL"), "newWindow": prop("boolean", "Open in a new window instead of a tab")],
         required: ["url"], handler: openURL),
    Tool(name: "safari_switch_tab", description: "Bring a tab of the user's real Safari to the front.",
         properties: tabProps, required: ["tab"], handler: switchTab),
    Tool(name: "safari_close_tab", description: "Close a tab in the user's real Safari.",
         properties: tabProps, required: ["tab"], handler: closeTab),
    Tool(name: "safari_run_javascript", description: "Run JavaScript in a tab of the user's real Safari and return the result. Requires Safari → Develop → 'Allow JavaScript from Apple Events'.",
         properties: tabProps.merging(["script": prop("string", "JavaScript; the value of the last expression is returned")]) { $1 },
         required: ["script"], handler: runJavaScriptInTab),
    Tool(name: "safari_search_history", description: "Search Safari browsing history by words in URL or title, newest first.",
         properties: ["query": prop("string", "Words that must all appear in the URL or title (empty = recent history)"),
                      "since": prop("string", "Only visits on/after YYYY-MM-DD"),
                      "limit": prop("integer", "Max results (default 25)")],
         required: [], handler: searchHistory),

    // Automation (safaridriver)
    Tool(name: "safari_auto_open", description: "Start (if needed) a separate Safari automation window via safaridriver and load a URL. Clean session: no user tabs, cookies or logins. One session at a time.",
         properties: ["url": prop("string", "URL")], required: ["url"], handler: autoOpen),
    Tool(name: "safari_auto_elements", description: "List visible interactive elements (links, buttons, inputs, selects) of the automation page with ref numbers to use in click/type.",
         properties: ["max": prop("integer", "Max elements (default 150)")], required: [], handler: autoElements),
    Tool(name: "safari_auto_click", description: "Click an element in the automation window.",
         properties: targetProps, required: [], handler: autoClick),
    Tool(name: "safari_auto_type", description: "Type into an input in the automation window.",
         properties: targetProps.merging(["text": prop("string", "Text to type"),
                                          "clear": prop("boolean", "Clear the field first (default true)"),
                                          "submit": prop("boolean", "Press Enter afterwards (default false)")]) { $1 },
         required: ["text"], handler: autoType),
    Tool(name: "safari_auto_select", description: "Choose an option in a <select> dropdown in the automation window.",
         properties: targetProps.merging(["option": prop("string", "Option text or value")]) { $1 },
         required: ["option"], handler: autoSelect),
    Tool(name: "safari_auto_get_text", description: "Read the visible text of the automation page (or of one element).",
         properties: ["selector": prop("string", "CSS selector (default body)"),
                      "maxChars": prop("integer", "Truncate after this many characters (default 30000)")],
         required: [], handler: autoGetText),
    Tool(name: "safari_auto_screenshot", description: "Screenshot of the automation window (returned as an image).",
         properties: [:], required: [], handler: autoScreenshot),
    Tool(name: "safari_auto_run_javascript", description: "Run JavaScript in the automation page; use `return` to return a value (JSON-serialisable).",
         properties: ["script": prop("string", "JavaScript function body")], required: ["script"], handler: autoRunJS),
    Tool(name: "safari_auto_navigate", description: "Go back, forward or refresh in the automation window.",
         properties: ["action": prop("string", "back, forward or refresh")], required: ["action"], handler: autoNavigate),
    Tool(name: "safari_auto_wait_for", description: "Wait until a selector exists and/or text appears on the automation page.",
         properties: ["selector": prop("string", "CSS selector"), "text": prop("string", "Text to wait for"),
                      "timeoutSeconds": prop("integer", "Max wait (default 10, max 60)")],
         required: [], handler: autoWaitFor),
    Tool(name: "safari_auto_close", description: "Close the automation window and stop safaridriver.",
         properties: [:], required: [], handler: autoClose),
])
