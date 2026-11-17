# safari-mcp — Safari MCP server

Pure Swift, one binary, no dependencies. It gives Claude two ways to use Safari:

**Your real Safari** (`safari_*`, via Apple Events): your open tabs and logins.
| Tool | What it does |
|---|---|
| `safari_list_tabs` | Windows and tabs (title + URL) |
| `safari_get_page` | Text or HTML of a tab. Works on pages you're logged into |
| `safari_open_url` | Open in a new tab or window |
| `safari_switch_tab` / `safari_close_tab` | Bring a tab to the front, or close it |
| `safari_run_javascript` | Run JS in a tab. Needs Develop → *Allow JavaScript from Apple Events* |
| `safari_search_history` | Search browsing history (reads `History.db`; needs Full Disk Access) |

Read tools never launch Safari. If it isn't running, they say so.

**Automation** (`safari_auto_*`, via `safaridriver`/WebDriver): a separate, clean window with no cookies or logins.
| Tool | What it does |
|---|---|
| `safari_auto_open` | Start a session and load a URL |
| `safari_auto_elements` | Numbered list of visible links, buttons, inputs and selects |
| `safari_auto_click` / `safari_auto_type` / `safari_auto_select` | Act on an element by `ref` number or CSS `selector` |
| `safari_auto_get_text` / `safari_auto_screenshot` | Read the page (screenshots come back as images) |
| `safari_auto_run_javascript` | Run JS and return JSON |
| `safari_auto_wait_for` / `safari_auto_navigate` | Wait for a selector or text; go back, forward or refresh |
| `safari_auto_close` | End the session and stop safaridriver (also happens on exit) |

One-time setup for automation: `sudo safaridriver --enable`.

```bash
swift build -c release
claude mcp add safari-mcp -s user "$PWD/.build/release/safari-mcp"
```
