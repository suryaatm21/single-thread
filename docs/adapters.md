# Agent adapters

single-thread flags a window when its agent needs you: a permission prompt, a question, a plan waiting for approval, or a finished turn. It learns this from the agent's own hooks. Each hook runs `hooks/single-thread-hook <agent> <event>` with the hook's JSON payload on stdin. The script writes one small JSON file per session into `~/Library/Application Support/single-thread/sessions/` (override with `SINGLE_THREAD_STATE_DIR`), and the app watches that folder.

When a session ends, the script deletes its state file and writes an empty `<session_id>.ended` marker in the same folder. A hook that was still running when the session ended sees the marker and writes nothing, so the session stays gone; `SessionStart` removes the marker. The app ignores ended sessions and deletes markers older than 24 hours.

The script stores the session id, working directory, event name, notification type and message, tool name, tty, agent PID, and the app that launched the terminal (`__CFBundleIdentifier`). It does not store prompts, replies, or tool input. It prints nothing and exits 0 on every path, so it cannot block or alter the agent.

| Agent | Mechanism | Status |
|---|---|---|
| Claude Code | Documented hooks | Implemented, tested against a real `claude -p` session |
| GitHub Copilot CLI | Documented hooks | Implemented from the docs; not run against a live Copilot CLI |
| Any other terminal program | None | Window-title label only, no needs-input flag |

## Claude Code

Source: [Hooks reference](https://code.claude.com/docs/en/hooks), [Hooks guide](https://code.claude.com/docs/en/hooks-guide).

| Hook event | Matcher | single-thread state |
|---|---|---|
| `SessionStart` | | ready |
| `UserPromptSubmit` | | working |
| `PreToolUse` | `AskUserQuestion\|ExitPlanMode` | question, or plan ready for review |
| `PermissionRequest` | | needs permission (plan ready for review for `ExitPlanMode`) |
| `PostToolUse`, `PostToolUseFailure` | | working (clears a permission flag once the tool ran) |
| `Notification` | | `permission_prompt` needs permission, `elicitation_dialog` question, `idle_prompt` turn finished; other types ignored |
| `Stop` | | turn finished |
| `StopFailure` | | turn finished (the turn ended on an API error) |
| `SessionEnd` | | state file deleted, `.ended` marker written |

Why these events:

- `PermissionRequest` fires the moment a permission or plan-approval dialog opens. The `permission_prompt` notification waits about six seconds and only fires when you look away from the terminal, so the app treats it as a backup.
- `Stop` fires at the end of each turn that finishes normally. It does not fire on an interrupt.
- `UserPromptSubmit` injects any stdout into Claude's context. The hook prints nothing.
- Hooks run without a controlling terminal. The script walks up the process tree to find the agent's PID and tty.

Install into one project, without touching your user settings:

```sh
build/SingleThread.app/Contents/MacOS/SingleThread install-hooks claude \
  --settings /path/to/project/.claude/settings.local.json
```

`--print` prints the `hooks` block instead. The installer merges into the file, keeps your other hooks, saves a `.bak`, and gives the same result when you run it twice. `uninstall-hooks claude --settings <path>` removes only single-thread's entries. To cover every project, point `--settings` at `~/.claude/settings.json` yourself. The tool never writes a file you did not name.

## GitHub Copilot CLI

Copilot CLI documents a hook system with a `notification` event and an `agentStop` event, so single-thread ships an adapter.

Sources:

- [CLI hooks reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-hooks-reference): config format, file locations, event names and payloads.
- [CLI config directory reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference): `~/.copilot/hooks/`, `session-state/`, `logs/`, and the `beep`, `updateTerminalTitle` and `terminalProgress` settings.
- [Copilot CLI changelog](https://github.com/github/copilot-cli/blob/main/changelog.md): `notification` hook added in 1.0.18; `agentStop` in 0.0.401; `permission_prompt` limited to prompts the user sees in 1.0.26.

What the docs say:

- Hook files are JSON with `"version": 1` and a `hooks` map. Copilot loads them from `.github/hooks/*.json` in a repo and from `~/.copilot/hooks/*.json` for the user.
- Each hook entry runs a shell command from its `bash` key (`command` and `powershell` also exist) with a `timeoutSec` limit.
- Every payload carries `sessionId`, `timestamp` and `cwd`.
- `notification` fires asynchronously with `notification_type`: `permission_prompt` when the agent asks to run a tool, `elicitation_dialog` when it asks you for more information, plus shell and background-agent types that single-thread ignores.
- `agentStop` fires when the main agent finishes a turn.
- `permissionRequest` fires before Copilot's permission rules run, including for requests that never reach you. single-thread does not use it.

| Hook event | single-thread state |
|---|---|
| `sessionStart` | ready |
| `userPromptSubmitted` | working |
| `postToolUse`, `postToolUseFailure` | working |
| `notification` | `permission_prompt` needs permission, `elicitation_dialog` question; other types ignored |
| `agentStop` | turn finished |
| `sessionEnd` | state file deleted, `.ended` marker written |

Install:

```sh
# For one repository
build/SingleThread.app/Contents/MacOS/SingleThread install-hooks copilot \
  --hooks-file /path/to/repo/.github/hooks/single-thread.json
# For every session of your user
build/SingleThread.app/Contents/MacOS/SingleThread install-hooks copilot \
  --hooks-file ~/.copilot/hooks/single-thread.json
```

Copilot CLI also reads hooks from `.claude/settings.json` and `.claude/settings.local.json`. When a Claude Code hook fires from inside Copilot, the script sees `COPILOT_HOOK_DEPTH` in its environment and labels the session as Copilot CLI.

Gaps:

- The docs name no event or notification type for plan approval. A plan prompt may arrive as `permission_prompt` or `elicitation_dialog`; nobody has confirmed which.
- No Copilot CLI ran on the machine that built this adapter. The payload handling follows the docs and the unit tests feed it documented payloads.
- Copilot also writes `~/.copilot/session-state/<id>/events.jsonl` and process logs, and sets the terminal title to the current intent. The docs give no format or stability promise for these, so single-thread does not read them.

## Everything else

Plain shells, other agent CLIs, and editors without hooks get the overlay and a label built from the window title and working directory. They never get the needs-you flag. Shell-integration signals such as OSC 133 command-finished marks are a possible future source.
