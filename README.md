# single-thread

A focus layer for running several AI coding agents at once. When you click into one terminal window, single-thread dims and blurs every other agent window and puts the session's name on it, so the window you work in is the only one you can read. When an agent in a covered window needs you (a permission prompt, a question, a plan to approve, or a finished turn), its overlay gets an amber border and a "Needs you" line. single-thread is a native macOS menu-bar app. It works with Terminal, iTerm2, Warp, Ghostty, Visual Studio Code and the Claude app, and reads needs-input signals from Claude Code and GitHub Copilot CLI hooks.

```
 focused window             other agent windows
┌──────────────────┐   ┌──────────────────┐ ┌──────────────────┐
│ $ claude         │   │░░░░░░░░░░░░░░░░░░│ ┃▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓┃  amber border
│ ⏺ Reading tests… │   │░░   api-server  ░│ ┃▓▓  web-app     ▓▓┃
│ ⏺ Update(...)    │   │░░ Claude Code · ░│ ┃▓▓ Needs you ·  ▓▓┃
│ > _              │   │░░   working     ░│ ┃▓▓ permission   ▓▓┃
└──────────────────┘   └──────────────────┘ ┗━━━━━━━━━━━━━━━━━━┛
     sharp              dimmed + blurred     dimmed + blurred + flagged
```

## Quick start

You need macOS 14 or later and a Swift 6 toolchain (Xcode or the Command Line Tools).

1. **Create a signing identity, once.** See [Stable signing](#stable-signing). Skip this and macOS forgets the Accessibility grant after every rebuild.
2. **Build the app:**
   ```sh
   scripts/bundle.sh
   ```
   This writes `build/SingleThread.app`, a menu-bar app with the bundle ID `local.single-thread`.
3. **Run it:**
   ```sh
   open build/SingleThread.app
   ```
   A stacked-windows icon appears in the menu bar.
4. **Grant Accessibility.** Open the menu, choose *Accessibility: not granted… Grant…*, then turn on **single-thread** in System Settings > Privacy & Security > Accessibility. If the menu still says *not granted*, quit and reopen the app.
5. **Install the Claude Code hooks** in the project you will demo from:
   ```sh
   build/SingleThread.app/Contents/MacOS/SingleThread install-hooks claude \
     --settings /path/to/project/.claude/settings.local.json
   ```
   Use `--print` to see the JSON without writing anything. For Copilot CLI, see [docs/adapters.md](docs/adapters.md).
6. Open two or three terminal windows, start an agent in each, and click between them.

The menu also has *Copy Claude Code hook config*, which puts the `hooks` block on your clipboard.

## Modes

Pick a mode from the menu bar. *Focus overlay: On/Off* toggles everything.

| Mode | Unfocused windows |
|---|---|
| Dim only | 55% black. You can still read the text. |
| Dim + blur | Blur plus 25% black. The text is unreadable. |
| Dim + blur + label | Same, with the session name, app, window title and agent status in the middle. |

The needs-you flag shows in all three modes.

*Keep last agent window clear when another app is in front* (on by default) leaves your last terminal window sharp while you read docs in a browser. Turn it off to cover every agent window whenever a non-agent app has focus.

## How needs-input works

```
agent hook ──▶ single-thread-hook ──▶ ~/Library/Application Support/single-thread/sessions/<agent>-<id>.json
                                                                   │ (folder watch)
terminal windows ──▶ window list + Accessibility ──▶ match session ↔ window ──▶ overlays
```

1. Claude Code runs `hooks/single-thread-hook` on `PermissionRequest`, `PreToolUse` (questions and plans), `Notification`, `Stop`, `UserPromptSubmit`, `PostToolUse`, `SessionStart` and `SessionEnd`.
2. The script writes the session's latest state to one JSON file: session id, working directory, event, tty, agent PID, and the app that launched the terminal. It never stores prompts or replies.
3. The app matches each session to a window. It scores the launching app, the working directory a terminal window reports through Accessibility (when it reports one), the project name in the window title, and the tty.
4. A session that needs input gets an amber border and a *Needs you* line on its overlay. Clicking into that window clears the flag. The flag returns when the agent needs you for something new.

Sessions the app cannot place on a window still appear in the menu, marked *window not identified*, and the menu-bar icon shows the count of sessions waiting on you.

[docs/adapters.md](docs/adapters.md) has the full event table, the Copilot CLI adapter, and links to both hook references.

## Permissions

To run the live demo, a person must grant one permission in System Settings:

| Permission | Needed for | Without it |
|---|---|---|
| **Accessibility** for single-thread | Window titles, the working directory each terminal reports, session-to-window matching, faster move and resize tracking, raising a window from the menu | Overlays, blur and focus still work. Labels show the app name only, and the needs-you flag lands only when the agent's terminal app has a single window. |
| Screen Recording | Not needed. Accessibility provides titles. | |

The menu's *Permissions* section shows what is granted and opens the right System Settings pane. The app never changes settings on its own. If *Reduce Transparency* is on, macOS draws the blur as a solid tint and the menu says so.

## Stable signing

macOS ties the Accessibility grant to the app's code signature. An ad-hoc signature changes with every build, so after a rebuild the switch in System Settings stays on while macOS ignores it. A named signing identity, even a self-signed one, keeps the signature stable.

One-time setup:

1. Open **Keychain Access** and choose *Keychain Access > Certificate Assistant > Create a Certificate…*
2. Name: `single-thread local signing`. Identity Type: *Self Signed Root*. Certificate Type: *Code Signing*. Click *Create*.
3. Run `scripts/bundle.sh`. It finds the identity by name and signs with it.

You do not need to change the certificate's trust settings. To use another identity, set `SINGLE_THREAD_SIGN_IDENTITY="Your identity name"`. Without an identity, `scripts/bundle.sh` signs ad hoc and prints a warning. You then need to toggle the Accessibility switch off and on after each build.

## Configuration

| Setting | How |
|---|---|
| Supported apps | `defaults write local.single-thread supportedApps -array com.apple.Terminal com.mitchellh.ghostty` (bundle IDs). Default: Terminal, iTerm2, Warp, Ghostty, Visual Studio Code, Claude. |
| Supported apps for one run | `open --env SINGLE_THREAD_APPS=com.apple.Terminal build/SingleThread.app` |
| State folder | `SINGLE_THREAD_STATE_DIR`, for both the hook and the app |
| Debug log | `open --env SINGLE_THREAD_DEBUG=1 --stderr /tmp/single-thread.log build/SingleThread.app` writes one line per change |

`SingleThread sessions` lists the sessions the hooks have reported. `SingleThread --help` lists every command.

## Blur strength

The default blur is AppKit's public `NSVisualEffectView` (`.hudWindow` material, behind-window blending), and it is enough. We rendered Claude-Code-style output at 12, 13 and 14 pt in a terminal-like window, covered it with each overlay, captured the result, and ran Apple's Vision text recognizer on the capture:

| Overlay | Words recognized (12 / 13 / 14 pt) |
|---|---|
| None | 100% / 100% / 100% |
| Dim only | 100% / 100% / 100% |
| Dim + public blur | 0% / 0% / 0% |

The public blur leaves no readable text, so single-thread does not use the private `CGSSetWindowBackgroundBlurRadius` call. That keeps the app on public drawing APIs. The one private call in the app is `_AXUIElementGetWindow`, which maps an Accessibility window to its window number. The app resolves it at runtime and falls back to matching window frames if it is missing.

## Known limits

- Blur covers whole windows. Panes inside one window (tmux, iTerm2 split panes, Warp and Ghostty splits) share one overlay.
- Inside tmux, the hook cannot tell which terminal app hosts the session, so matching relies on the working directory and window title.
- Two windows of the same app with the same project and no title hints can swap labels.
- An overlay can trail a window that moves while unfocused by up to a quarter second.
- The Copilot CLI adapter follows the documentation and has not run against a live Copilot CLI session yet.
- Window titles are only as good as what each terminal and agent set. Claude Code replaces the title with its task summary.

## Development

```sh
swift build
swift test
```

If `swift test` stops with `plugin for module 'TestingMacros' not found`, run `scripts/test.sh` instead. Some Command Line Tools installs (seen with Swift 6.4) lose the swift-testing macro plugin between builds, and the script names the plugin folder for the compiler.

`Sources/SingleThreadCore` holds the pure logic: coordinate conversion, preferences, state-file parsing, session-to-window matching, labels, overlay planning, and hook-config merging. `Tests/SingleThreadCoreTests` covers it, including end-to-end runs of the hook script. `Sources/SingleThread` holds the AppKit app and the command-line subcommands. GitHub Actions runs the build and tests on macOS for every push and pull request.

## Not in this release

- An agent monitor with one summary row per agent.
- Per-pane blur for tmux and iTerm2 splits.
- Command-finished signals from plain shells (OSC 133).
- Signed and notarized releases.
