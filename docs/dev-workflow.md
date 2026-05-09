# Developer Workflow: Build → Install → Run → Inspect

When fixing compiler bugs (e.g. [#9](https://github.com/akostibas/perspective-cuts/issues/9)), the fast feedback loop is:

1. Edit the compiler / registry
2. `swift build`
3. Compile a fixture `.perspective` to a signed `.shortcut`
4. Install it into the Shortcuts library
5. Run it headlessly
6. Inspect captured stdout

`bin/run-shortcut-test` collapses steps 3–6 into one command.

## Usage

```sh
swift build
bin/run-shortcut-test path/to/fixture.perspective [-i input-file]
```

The script:
- Reads `#name:` from the source (falls back to capitalized basename).
- Compiles with `--sign`.
- Skips install if the shortcut is already in `shortcuts list` (idempotent — see gotcha below).
- Otherwise `open`s the `.shortcut` and uses `osascript` to press Return on the import dialog.
- Runs `shortcuts run <name> -o <tmpfile>` and prints the captured output.

## One-time setup

- **Accessibility permission for Terminal** — System Settings → Privacy & Security → Accessibility. macOS prompts on first run; without it `osascript` cannot drive System Events.
- **Automation permission for Terminal → System Events** — separate prompt, also one-time.

Per-fixture, the first run may show:
- "Allow `<name>` to output N text items?" — click "Always Allow" once.
- Permission prompts for resources the fixture touches (network, files, contacts, etc.).

## Why GUI scripting

The spike that produced this loop evaluated several alternatives:

| Approach | Result |
|----------|--------|
| `shortcuts import` subcommand | Doesn't exist. CLI has only `run`, `list`, `view`, `sign`. |
| AppleScript `add` / `import` verb | Not in the sdef. |
| Drop file into `~/Library/Group Containers/group.com.apple.shortcuts/` | CoreData + CloudKit; fragile, breaks across OS updates, risks sync corruption. |
| `shortcuts://import-shortcut?url=...` | Routes through the same import dialog. |
| `keystroke return` to default-action the dialog | **Works.** Default button is "Add Shortcut"; Return triggers it. |

## Idempotent install gotcha

The harness skips install if `shortcuts list` already shows the fixture's `#name:`. After editing fixture *logic*, either:

- Bump the name (`Foo` → `FooV2`) to force a fresh install, or
- Manually delete the existing shortcut from the Shortcuts app sidebar before re-running.

Otherwise your edits don't reach the running shortcut.

## Modals block `shortcuts run`

`shortcuts run` waits for completion. Any `showResult`, `alert`, `ask`, `chooseFromList` will block until dismissed. For test fixtures, prefer **UI-free** sources:

- The last action's value is what `-o` captures — no `showResult` needed.
- Input via `-i input-file`; the shortcut sees it as `shortcutInput`.

When the UI itself is the system under test, pre-arm a background `osascript` driver that polls for the modal window and dispatches keystrokes — same pattern as the install-dialog driver in `bin/run-shortcut-test`, generalized.

## Inspecting compiled output

Independent of the run loop, you can diff the generated plist against an Apple-built reference:

```sh
.build/debug/perspective-cuts compile fixture.perspective -o /tmp/x.shortcut
plutil -convert xml1 -o - /tmp/x.shortcut | less
```

Useful when debugging shape mismatches like #9 (`WFTextTokenAttachment` vs. `WFTextTokenString`). Build the same action in Shortcuts.app, export, and compare.

## Known limitations

- **No clean uninstall via CLI.** AppleScript `delete shortcut` returns no error but doesn't actually remove. Reuse stable names rather than create-and-destroy per run.
- **Brittle to UI changes.** If Apple adds a confirmation step to the import dialog, `keystroke return` may need to grow another step. The harness checks `shortcuts list` post-install and fails loudly.
- **macOS-only.** No CLI on iOS.

---

Adapted from Shannon-Assistant's `docs/client-shortcuts/automated-testing.md`.
