# Tabryo

A local desktop workbench for shells, the installed Codex CLI, files, Git and
worktrees. Target platforms: Windows 11 x64 and Ubuntu 24.04 x64.

## Install

Download your platform archive and `SHA256SUMS` from
[Releases](https://github.com/ftr-tuta/tabryo/releases). Extract the complete
archive into a directory you own, and run `tabryo.exe` on Windows or `./tabryo`
on Linux. Keep `data`, libraries, ConPTY and OpenConsole beside the executable.
Update manually by closing Tabryo and extracting a newer release into a new folder.

Windows requires the latest
[Microsoft Visual C++ v14 Redistributable for x64](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist).
Editing also requires the Microsoft Edge WebView2 Runtime on Windows.
Ubuntu 24.04 requires a graphical session and the GTK/OpenGL runtime:
`sudo apt install libgtk-3-0t64 libwebkit2gtk-4.1-0 libstdc++6 libgl1`.
The [Ubuntu GTK package](https://packages.ubuntu.com/noble/libgtk-3-0t64)
provides its dependent desktop libraries. Git and Codex are separate installations.

Compare `Get-FileHash <archive> -Algorithm SHA256` on Windows or run
`sha256sum --check SHA256SUMS` after downloading both archives on Linux.
Tabryo executables are unsigned; the included Microsoft ConPTY binaries retain
their original Microsoft signatures. No installer or automatic updater is included.

## Use

Open an absolute workspace directory, then choose **Shell**, **Codex**, or
**Resume**. Tabryo starts no process at boot. Codex uses your installed CLI and
its existing authentication; Tabryo does not implement an agent or store tokens.
Install Git and the Codex CLI separately and make them available on PATH.

Use the sidebar for paginated files, changes, history and worktrees. Text files
open in editor tabs; noneditable files and Git diffs use read-only previews.
Stage and unstage use literal paths. Commit displays Git's
effective identity and preserves hooks and signing. Fetch and push use a terminal
so credentials and prompts remain interactive. Worktree removal refuses the main
checkout, locked, dirty, untracked or ignored content, Tabryo-owned sessions and
open editor documents.
Close external editors and processes yourself before confirming removal.

Ctrl+Shift+P opens the command palette; Ctrl+O opens a workspace;
Ctrl+Shift+T starts a shell; Ctrl+Shift+D/E splits the focused pane;
Ctrl+Shift+J changes pane; Ctrl+Tab changes tab; Ctrl+Shift+W closes a pane.
Ctrl+Shift+C/V copies/pastes in terminals. Multiline paste requires confirmation.
Ctrl+Shift+F searches terminal scrollback; F5 refreshes the sidebar.

## Editor

Select a text file in **Files** to open an editor tab. **Editor** and **Terminals**
switch activities; open buffers and undo history survive activity and workspace
switches. Ctrl+Tab cycles tabs in the active activity. Ctrl+S saves the document;
Ctrl+Z/Ctrl+Y undo and redo. A dot marks unsaved changes. Closing a document,
workspace or the application offers Save, Discard and Cancel when needed.

The editor supports UTF-8, optional BOM, and consistent LF or CRLF line endings.
Monaco **0.56.0** supplies syntax colors, multiple selections, folding, snippets,
Ctrl+F search, Ctrl+H replacement, and disk comparison. Its assets and workers
ship inside the application and are served on a private loopback endpoint;
editing needs no CDN or internet connection. The embedded surface hides during
Flutter dialogs and inactive activities. Language intelligence can be started
explicitly from **Projects and toolchains → Language intelligence**.
The native editor scenario passes in Debug and Release on Windows and Ubuntu
24.04, including reconnection and Dart formatting. The
[desktop CI qualification](https://github.com/ftr-tuta/tabryo/actions/runs/34247734251)
also passes terminal/workbench integration, packaging and extracted-bundle startup
and shutdown on both platforms. Composition-aware synchronization waits for IME
commit and preserves composing text when a host replacement arrives. Native
tests exercise browser composition events and viewport dimensions. Linux GTK
bounds convert physical pixels to logical coordinates, with a dedicated 200%
scale CI case. Physical IME candidate windows and moving between monitors with
different scales still need desktop acceptance; the full IDE matrix is unfinished.
It retains up to 12 open documents, each within 512 KiB; an oversized edit is
refused without truncating the buffer. Binary, invalid UTF-8, mixed-newline and
larger files use bounded read-only previews. **Document actions** can compare
the buffer with disk or reload after confirmation.

Saving checks the original bytes, modification time and file mode, stages a
flushed replacement beside the file, rechecks the baseline and replaces it.
Conflicts, unavailable paths, unpreserved file modes and write failures preserve the buffer. This is
optimistic concurrency; it does not lock out other applications during the final
filesystem rename.

**Recover unsaved documents after a crash** is a separate opt-in preference.
It keeps flushed local copies of dirty buffers under
`%LOCALAPPDATA%/Tabryo/editor-recovery` on Windows or
`${XDG_STATE_HOME:-~/.local/state}/Tabryo/editor-recovery` on Linux. Copies can
contain sensitive source text. They are updated about 350 ms after an edit;
input not yet received from the editor or flushed to storage can be lost in a crash.
OS locks keep running windows' copies separate. After reopening, choose
**Review copies** or **Recover documents** in the command palette. At most 12
recovered documents are offered at a time; additional copies stay on disk.
Restore or discard offered copies, then **Refresh copies** to load more.
Each scan examines at most 128 sessions and reports a reached limit. Preview can
copy text even when its original file is missing. Restore opens an unsaved tab
and compares the current disk; changed files require **Keep local edits** or
reload before saving. Restoring never writes the source. UTF-8 text, selection,
BOM and line-ending metadata are retained; undo history starts fresh.
Save/Discard on normal exit clears this session's copies. Turning recovery off
clears this session and its offered copies; other running windows and unreadable
copies are retained. Storage failures are visible and preserve in-memory edits.

For **Dart format on save**, open a workspace and enter its Dart executable in
**Preferences**. Use an absolute `dart.exe` path on Windows (for Flutter, this is
`bin/cache/dart-sdk/bin/dart.exe`) or the Dart executable on Linux. Leave the field
empty to disable formatting for that workspace. **Remember appearance, editor
and monitoring preferences** also persists these explicit SDK selections.
Saving a `.dart` file runs that SDK's formatter on the captured buffer through
stdin, using the real filename for package language and formatting options.
Formatting preserves the primary selection, BOM, line endings and undo history;
it never writes the source directly. The normal conflict checks still govern
the final save. Syntax errors, unavailable SDKs, a 30-second timeout, or edits
arriving during formatting keep the buffer. Retry with Ctrl+S or use
**Document actions → Save without formatting** after a formatter failure.
Project SDK discovery is available from **Projects and toolchains**. An active
Dart language server supplies formatting; the selected SDK process is the fallback
when no server provides it. Flutter hot reload is available during a running session.

Preferences, remembered directories, layout and file watching are opt-in.
Disabling persistence clears the corresponding persisted data. Watching monitors
the selected root and polls the bounded set of open documents, including nested
files. Clean buffers reload external changes; dirty buffers retain local edits
and offer a disk comparison. F5 also refreshes open documents with watching off.
Input arriving while a replacement crosses the native bridge is retained and
requires an explicit **Keep local edits** or reload choice before saving.
Terminal output cannot silently access the clipboard, open links or download files.

## Projects and toolchains

Open **Projects and toolchains** from the toolbar or command palette to scan the
workspace for Dart/Flutter pubspecs and Python manifests. Mixed and nested roots
are listed separately. Scans exclude dependency/build directories and directory
links and are bounded to six levels, 512 directories, 12,000 entries and 64
projects. A notice identifies incomplete scans; open a narrower workspace when
needed. Opening a workspace or scanning starts no language server or command.

Select a project, choose a detected candidate or enter an absolute installed
path, then **Apply toolchains**. Detection reads PATH, FVM's local SDK link and
configured cache, Dart/Flutter SDK variables, project `.venv`, and installed
pyenv versions (including a `.python-version` pin). It recognizes uv and Poetry
manifests/locks. Cached Poetry environments can be supplied by interpreter path.
Windows Store aliases and pyenv shims are excluded from interpreter suggestions.
Discovery does not verify tool versions by executing them.

Flutter uses the Dart SDK bundled with the selected Flutter directory. Dart
format on save chooses the closest explicitly configured project inside the
document's authorized workspace, keeping sibling projects and separately opened
nested workspaces isolated. Selected paths remain local and persist only with
**Remember appearance, editor and monitoring preferences**. Clearing a selection
disables its formatter; detection never replaces an explicit choice.

**Prepare environment** shows one native command at a time, including its
directory, arguments and environment overrides. Review and run it to open an
owned terminal; no next step runs automatically. Unsaved project documents and
overlapping setup commands are refused. Closing the terminal stops its owned
process tree. Dart/Flutter offer dependency installation. Python offers local
`.venv` creation, uv synchronization, Poetry installation or pip requirements,
and optional development-tool installation. The detected manager is the default
and can be changed explicitly. Installations target the project `.venv`, refuse
linked environment directories, and can download packages and run build code.
uv synchronization may remove packages not declared in its lock. With no uv
installed, create `.venv` with Python, install uv there, scan and select it.
Official installation guides are available for missing SDKs and managers.

**Create project** previews the official Dart, Flutter or uv generator, with a
new lowercase project name and selected tool paths. Preview reserves an empty
temporary folder. Execution generates there and publishes the requested folder
only after success; existing destinations are refused. Cancel removes an empty
preview, while failed generator output remains at the reported path for recovery.
Dart and Flutter use `--no-pub`; Python uses uv without modifying a parent
workspace or initializing Git. Install dependencies as a separate reviewed step.
Language servers are started separately through Language intelligence.
**Tasks and tests** discovers test files and runs reviewed commands, as described
below. Run/debug sessions, Flutter devices and DevTools are described below.

The native project tests exercise Dart/Flutter generation, Python environment
creation, uv **0.8.22**, Poetry **2.2.1**, and pip with Python **3.12.10**.
Set `TABRYO_TEST_PROJECT_SETUP=1` to include the external-tool cases in
`flutter test test/projects_test.dart`. Python, uv and Poetry are discovered on
PATH, or supplied with `TABRYO_TEST_PYTHON`, `TABRYO_TEST_UV` and
`TABRYO_TEST_POETRY`. The Desktop workflow installs those tools for both platforms.

## MCP Hub

Open a workspace and choose **MCP Hub** from the toolbar or command palette.
Choose **Connect Codex** to start a local App Server and the MCP servers enabled
in Codex's trusted configuration. The Hub starts no process at application boot.
It uses the native Codex executable on PATH; the current integration is exercised
with Codex CLI **0.147.0** on Windows.

The Hub lists servers, authentication state, tools and resources. Add STDIO or
Streamable HTTP servers, edit their supported fields, enable/disable them, or
remove their user configuration entries. Each write has a review step and an
expected configuration version. Codex preserves unrelated options and comments;
conflicts require a fresh review. Existing advanced fields are retained. This
Codex version only accepts writes to user configuration, so project, plugin and
managed definitions are displayed as read-only. Remote URLs require HTTPS; new
URLs with credentials or query strings are not supported by this form.

For OAuth, choose **Authenticate**, then copy the sign-in link into your browser.
Codex owns authentication and credential storage. Bearer credentials are configured
by environment variable name. Inspect a tool's definition, enter JSON arguments,
and review the call before executing it. Resource reads and tool results are
displayed on demand; known credentials and sensitive keys are masked. Results are
transient and capped for display, and raw process logs are not retained.

**Reconnect servers** restarts this Hub's owned App Server and inspection session.
Closing the Hub disconnects it. Disconnecting does not guarantee cancellation of
work already running remotely. Other Codex clients may need a separate reconnect
after configuration changes. Disabling/removing a definition does not revoke
credentials at its provider. Server-initiated approvals and elicitation forms are
explicitly refused in this initial inspector; use the Codex terminal for those
flows. Authenticated remote providers and Linux interaction remain unqualified.
The editor can now publish a reviewed excerpt through its local MCP endpoint;
graphical Codex conversations remain planned.
see [metas e objetivos](TABRYO_METAS_E_OBJETIVOS.adoc).

The native `test/mcp_codex_test.dart` checks the real App Server with disposable
configuration and local STDIO/HTTP fixtures, without invoking a model or using
the user's credentials. Set `TABRYO_TEST_CODEX` and `TABRYO_TEST_DART` to the native
Codex and Dart executable paths to include these tests. Other MCP tests need no
Codex installation.

## Codex collaboration (Windows)

Choose **Collaboration** from the toolbar or command palette, start the local
service and create a group such as **API + Flutter**. Add each participant with
its project folder and authorized objective. Choose read-only or writer access;
Tabryo reserves one writer per Git repository, including its linked worktrees.
Enable **Continue automatically for requests** only for participants that may
resume their objective when another participant requests help or finishes a
dependency. Informational messages do not start idle work.

Use **Open in Tabryo** or **External terminal** to attach the installed Codex CLI
to that participant's conversation. Existing participants resume their saved
conversation after reconnection. Standalone CLIs join by launching these managed
connections; arbitrary already-running CLI processes are not attached or
controlled. Codex must be installed and logged in. Its user configuration is not
edited; each owned App Server receives its collaboration MCP configuration as a
process override. No additional model is needed for the service.

The panel shows participants, messages, versioned checkpoints, pending approvals
and session errors. **Pause** interrupts current work and prevents automatic
resumption. **Disconnect** stops that participant's owned App Server while
retaining the conversation, mailbox and writer reservation. **Complete** releases
ownership and retires the participant. Approvals are answered explicitly in the
panel or connected CLI; another client's answer invalidates the pending request.
Large or unavailable file-change reviews must be handled in the CLI.

Closing the panel or Tabryo keeps the detached service running. **Stop service**
explicitly stops the owned sessions and preserves pending data. Starting it again
restores active participants and reconciles delivery; paused, disconnected and
completed participants stay inactive. On Windows, a process job also closes the
owned Codex descendants if the service crashes.

SQLite stores groups, participants, messages and checkpoints under
`%LOCALAPPDATA%\Tabryo\collaboration`. The service binds only to `127.0.0.1`,
checks HTTP origins and authenticates controller, MCP and App Server connections.
Discovery credentials belong to the local OS user; participant tokens are hashed
in SQLite and are rotated on reconnection. Context remains local to this
computer, apart from the participant's ordinary Codex/model requests.

The MCP tools are `participants`, `messages`, `send`, `acknowledge`,
`publish_checkpoint`, `checkpoints` and `checkpoint_detail`. Sender and group
come from the authenticated connection. Each send or checkpoint uses a stable
`client_id` for safe retries. Checkpoints contain the objective, current state,
decisions, review, reported validations and next step. Tabryo adds the Git
revision and local-change state; summaries are listed separately from details.

A send commits before returning **stored**. Codex input acceptance produces
**forwarded**; only the recipient's `acknowledge` produces **confirmed**, without
calling a model. A crash or lost response produces **uncertain**. Such messages
are not blindly replayed: the service checks the conversation for positive
acceptance evidence, and the recipient can read and acknowledge its mailbox.
The service currently supports up to 16 non-completed participants and 100
groups, with bounded message and checkpoint pages.

This integration is qualified on Windows with Codex CLI **0.147.0**. The Codex
WebSocket transport remains experimental. Collaboration is not yet enabled on
Linux, and communication between computers is outside this release.

Native tests:

- `flutter test test/collaboration_test.dart test/collaboration_screen_test.dart`
  covers SQLite recovery, idempotency, group isolation, wake rules, HTTP/MCP and
  panel controls.
- `test/collaboration_sessions_test.dart` exercises the installed CLI, MCP tools,
  approvals, reconnection and the detached Windows executable. Set
  `TABRYO_TEST_CODEX` to the native Codex executable and `TABRYO_TEST_APP` to the
  built `tabryo.exe` to enable those checks. Put the complete Windows Release
  directory on PATH for the native session process library.
- Set `TABRYO_TEST_TERMINAL=1` for real CLI terminal tests.
  `TABRYO_TEST_CODEX_LIVE=1` separately enables
  an actual checkpoint/acknowledgement exchange between two agents using the
  installed login, disposable projects and read-only permissions. Unrelated MCP
  servers are disabled for that test; credentials are not copied.
- The existing `test/codex_connection_test.dart`, `test/codex_sessions_test.dart`
  and `test/mcp_codex_test.dart` cover the shared transport and MCP Hub. The latter
  also uses `TABRYO_TEST_DART` for its native Dart executable.

## MCP Studio

Choose **MCP Studio** from the toolbar or command palette. Select Dart, Python or
TypeScript and a new project name inside the current workspace. Review every
generated file and command, then choose **Create reviewed project**. Existing
folders are refused, including empty folders. Creation starts no process.

Each project includes a `greet` tool, a `greeting://info` resource, a `welcome`
prompt, instructions and a native test. Open its source in the editor, save your
changes and run the reviewed installation/build/test steps in order. Commands run
in owned terminals with one Studio command per project; unsaved project documents
block execution. Python uses a project virtual environment. TypeScript installation
disables npm lifecycle scripts. Choose an absolute native runtime executable;
missing runtimes can be supplied after creation with **Choose runtime**.

**Register in MCP Hub** connects Codex, previews the user configuration change
and reconnects after confirmation. The generated server can then be inspected
and called through Codex. Prompts are exercised by the native project tests;
interactive prompt inspection and sanitized application logs remain pending.
Terminal output is transient but is not a credential-redacting log viewer.
Created projects are listed for the current session; their files and registered
Hub entries remain on disk after closing Tabryo.

The STDIO templates were exercised on Windows with Dart 3.13.2,
Python 3.12.10, Node.js 26.5.1 and Codex CLI 0.147.0, using
[`dart_mcp` 0.5.2](https://pub.dev/packages/dart_mcp/versions/0.5.2),
[`mcp` 2.1.1](https://pypi.org/project/mcp/2.1.1/) and
[`@modelcontextprotocol/sdk` 1.30.0](https://www.npmjs.com/package/@modelcontextprotocol/sdk/v/1.30.0).
Direct dependencies are pinned; transitive dependency locks and Linux acceptance
remain pending. Generated HTTP projects are not offered in this initial Studio.

`test/mcp_studio_test.dart` includes opt-in native generated-project tests. Set
`TABRYO_TEST_CODEX` plus `TABRYO_TEST_DART`, `TABRYO_TEST_PYTHON` and/or
`TABRYO_TEST_NODE` to native executable paths. These tests install dependencies
into disposable projects, run their native tests and use an isolated Codex
configuration to discover/call tools and read resources without invoking a model.

## Language intelligence

Select a project in **Projects and toolchains**, apply its installed tool paths,
then open **Language intelligence** and review **Start language servers**.
Dart/Flutter use `dart language-server --protocol=lsp`. Python uses Node with
the installed `pyright/dist/pyright-langserver.js` file for types/navigation and
`ruff server` for lint, imports and formatting. Supply the project's Python
executable so Pyright resolves that environment's imports. The Node, Pyright and
Ruff paths can be selected alongside the existing toolchains; they persist only
when preference persistence is enabled. The dialog also accepts session overrides.
No server starts on opening a workspace. Changing applied toolchains stops the
project's servers; start them again explicitly.

Monaco provides completion, hover documentation, signature help, definition,
document symbols, rename and quick fixes when the selected server supports them.
**Document actions** also exposes completion, rename, symbols, references and
quick fixes. Ctrl+Space requests completion, F12 goes to definition, Ctrl+Shift+O
lists symbols and Shift+F12 opens the bounded project-reference list. Definitions
in the selected Dart SDK, declared package libraries, selected Python environment
or Pyright type stubs open in read-only tabs. Unrelated external files and links
escaping these roots are refused. Diagnostics appear as editor markers and in
**Problems**, with source, severity and code. Build/test/runtime output is not
included in this static-analysis panel.

Rename, quick fixes and available text refactorings require native review and apply only to unsaved buffers.
All affected files must already be open and synchronized with that language
session; open any reported missing file and retry. Every affected buffer is
checked again after review. Normal protected saves write to disk separately.
File creation/deletion/renaming and commands returned by servers are refused.
For Dart, select code and use **Extract Dart variable** or **Extract Dart method /
getter** from Document actions. Choose the symbol name and review the resulting
unsaved edits; Dart may choose a getter for an expression with no parameters.
The native Dart refactor command only supplies a proposal for this review.
Completion resolves additional imports in the current document, preserving undo
and unsaved text. A late response is accepted only for the exact suggestion
insertion; further typing invalidates it. Cross-file completion commands and
refactorings requiring resource operations remain open.
An active Ruff server enables Python format on save. To use Black instead, select
its installed executable in the project's toolchain form and apply the choice.
Black works without a language server; Ruff may remain active for lint and fixes.
Clear the Black path to return to Ruff. The closest configured Python project
controls the choice, including an explicitly cleared child selection. Paths
persist only with preference persistence. Install Black in the intended
environment yourself (`python -m pip install black`) before selecting it.
Black receives the captured buffer through stdin and reads project options using
the source filename; it never writes that source directly. Output and runtime
are bounded, and Windows streams use UTF-8. Formatter failures, changed tool
choices and concurrent input preserve the buffer and expose **Save without formatting**.

Sessions isolate workspace/project roots and known nested projects. At most four
servers run, with 32 pending requests per connection, 20-second request timeouts,
4 MiB protocol messages and bounded diagnostics (100 files, 200 per file, 2,000
total, 2 MiB retained). Reached diagnostic limits are visible. Versioned stale
responses are discarded; servers that omit diagnostic versions cannot provide
the same freshness guarantee. Stop/restart servers from the language dialog;
closing their workspace or Tabryo closes their connections and processes.
Server stderr is drained without retaining or exposing logs.

Native Flutter tests exercise Dart 3.13.2, Pyright 1.1.413 and Ruff 0.16.6 with
unsaved documents, a real Python virtual environment, review, formatting,
fragmented framing, cancellation, disconnect and project isolation. Pyright is
a pinned development dependency for these tests; language servers are not
bundled into the application. Desktop CI requires the Python language tests
with `TABRYO_TEST_LANGUAGE_PYTHON=1` and installed Node/Python/Ruff. Optional
`TABRYO_TEST_NODE`, `TABRYO_TEST_PYTHON` and `TABRYO_TEST_RUFF` paths override PATH.

## Editor context for Codex and MCP

Open **Document actions → Editor context for Codex / MCP**. Select an excerpt
first, or choose the whole document, then review the captured text, path, version
and saved/unsaved state. Publishing creates a temporary loopback Streamable HTTP
endpoint with a unique bearer credential. **Copy MCP connection** copies its URL
and Authorization header; **Copy context for Codex** copies the reviewed snapshot
for explicit pasting. Later typing is not transmitted automatically.
**Include captured diagnostics** adds up to 50 diagnostics (64 KiB), restricted
to ranges fully inside the excerpt. Review their messages, server/source, codes
and document versions with the text. A null diagnostic version means the server
did not report one; these captured results are not a live diagnostic feed.

MCP clients can read `tabryo://editor/context` or call `editor_context`, submit
`propose_replacement` with the snapshot ID and a retry-safe client ID, and inspect
`proposal_status`. Each proposal replaces exactly the shared excerpt. Native
before/after review is required to apply it to the unsaved buffer; saving remains
explicit. Changed buffers, disk contents, document versions or grants invalidate
the proposal. Up to eight proposals are retained per share.

**Revoke editor context**, closing the source document, changing workspace and
closing Tabryo revoke the endpoint. Clients cannot browse arbitrary files or
apply edits through MCP. The endpoint is local and temporary; remote exposure and
graphical agent conversations remain outside this slice.
Native tests cover authentication, revocation, stale edits, real Codex MCP calls
and Monaco review/undo without invoking a model.

## Run and debug

After applying project tools, open **Projects and toolchains → Run and debug**.
Enter a saved entrypoint, arguments and optional breakpoint line numbers, then
review the session before starting. Dart uses its SDK debug adapter; Flutter
uses its SDK adapter and an explicitly discovered/selected device. Python uses
`debugpy` installed in the chosen interpreter. No adapter or device scan starts
when the panel opens. Running without debugging is an explicit checkbox.

The panel shows verified/pending breakpoints, stack frames, scopes, variables,
console output and continue/pause/step controls. Stack source links use the
editor's project and read-only dependency boundaries. Evaluation is an explicit
action that can execute application code. Add watches while paused to evaluate
them again after each pause or frame change; stale results are discarded.
Expand **Directory, environment and breakpoint conditions** to set a working
directory within the project, in-memory environment overrides and conditions
such as `{"5":"count > 2"}` for declared breakpoint lines. An adapter lacking
conditional-breakpoint support refuses the session before launch.
Stop, workspace close and application
shutdown close the owned adapter process tree, including Python descendants.
The project stays reserved while startup or shutdown is pending.

**Attach to an existing local application** connects to a literal loopback
endpoint: the Dart/Flutter VM service URI, or `tcp://127.0.0.1:5678` for an
application started with debugpy listening there. Review the endpoint and project
source before attaching. **Disconnect debugger** leaves that application running;
it closes only Tabryo's connection, adapter and inspection tools. A Dart process
paused at startup can show an entry pause; Continue advances to its breakpoints.

Flutter provides hot reload/restart after application startup, requiring saved
project buffers. Successful Dart saves automatically reload the active Flutter
project; rapid saves coalesce and a paused session waits until continued. Disable
**Hot reload after successful Dart saves** to use manual controls only. A reload
failure leaves the saved file intact and reports the separate reload error.
Advanced settings also expose Flutter flavors, SDK tool arguments and
debug/profile/release modes. Availability depends on the chosen platform;
breakpoints and reload require debug mode.
**Open DevTools in Tabryo** starts the selected SDK's DevTools on loopback and
opens a resizable pane for this session's VM service. The pane has a separate
browser profile, permits navigation only on that server and hides while a dialog
covers it. Closing the pane keeps the session; Stop closes its DevTools server.
The session also owns a Dart Tooling Daemon (DTD), registers its VM service and
restricts DTD file access to that project's root. Its address and owner credential
remain in memory; stopping the session closes the daemon. **Select widget in app**
enables the real Flutter Inspector. Selection events navigate to the widget's
source through the editor's existing document and dependency protections.
**Open selected widget source** repeats that navigation, and **Exit widget
selection** returns the application to normal input. These controls require a
running Flutter debug application with Inspector extensions.
Debugger output and variables remain in memory, with bounded retained output.
Adapters and SDKs are not bundled.

Python profiles include Django (`manage.py runserver --noreload`) and FastAPI
(`python -m uvicorn package.module:app`). Both default to 127.0.0.1:8000 and
allow a chosen port and reviewed extra arguments. Install the framework in the
selected environment. Django check, migration plan, make migrations and migrate
are also available as separately reviewed tasks using the project's manage.py.

Native tests exercise Dart 3.13.2, Flutter 3.47.2, debugpy 1.8.21, Django 6.1.1,
FastAPI 0.140.6 and uvicorn 0.52.4. `TABRYO_TEST_DEBUG_PYTHON=1` enables the Python
adapter/framework cases; `TABRYO_TEST_FLUTTER_DEBUG=1` enables the desktop Flutter
run/Inspector/source navigation/reload/restart case, which requires the platform build tools and a graphical
session. Desktop CI runs both on Windows and Ubuntu.

## Tasks and tests

Open **Projects and toolchains → Tasks and tests** after applying the selected
project's SDK/interpreter. **Discover test files** lists `*_test.dart`,
`test_*.py` and `*_test.py` without importing or executing them. Discovery skips
known nested projects, dependency/build directories and directory links, with
limits of six levels, 512 directories, 12,000 entries and 1,000 files. A reached
limit is displayed. Nonstandard names can be entered manually; dynamic test
cases appear in the native results after execution.

Select a file, or leave it empty to run the native runner's default test scope.
An optional Dart/Flutter name substring or pytest `-k` expression narrows the
selection. **Review task** shows the executable, literal arguments, directory and
environment overrides. **Run reviewed task** starts an owned terminal only after
checking tool choices, current project paths and synchronized saved buffers.
Tests can execute project configuration, plugins and fixtures. Install pytest
in the selected Python environment; Dart/Flutter test dependencies must already
be available. Flutter commands use `--no-pub` so dependency setup remains explicit.

Tasks also offer Dart/Flutter analysis, Python Ruff analysis (`python -m ruff`),
Dart/Python script execution with a JSON argument list, Dart executable builds,
and Flutter builds for this desktop host, web or Android APK. Builds require
the corresponding installed platform toolchain. **Run and debug** provides
Flutter app execution with an explicitly selected device.

Overlapping project commands, including debugging, environment setup and Studio commands,
are refused. Up to four tasks in separate projects can run. **Show terminal**
opens the task's output; **Stop task**, closing its terminal, workspace or Tabryo
stops its owned process tree. Stopped tasks are marked cancelled. Results retain
the native exit code and separate passes, failures, skips and incomplete reports;
select a result to view details and open its project source location.

Dart/Flutter's JSON file reporter and pytest's JUnit XML supply structured results.
Temporary reports are read after exit and removed; unexpected filesystem content
is retained with its location. Reports are limited to 4 MiB and 2,000 test entries,
with 16 KiB of failure details per case. Missing, malformed or incomplete reports
cannot turn a test run green. Up to 20 task runs remain in memory for this session.
Results describe the files at execution time and are not refreshed after edits.
**Collect line coverage** adds the native runner's coverage options to the
reviewed test command. Flutter emits LCOV directly; Dart uses the official
`coverage:test_with_coverage` runner (install `coverage` as a project development
dependency); Python uses `pytest-cov` in the selected environment. These tools
are not installed automatically. The panel shows covered/total executable lines
and per-file hit counts, including uncovered lines, with source navigation.
Counts describe that run's saved sources; later edits can make locations stale.
Missing or invalid requested coverage leaves test results visible and marks the
task failed with a separate coverage error. Cancellation discards partial
coverage. Only sources inside the project appear. Reports are bounded to 4 MiB,
2,000 records and 100,000 line entries. Known native coverage outputs are removed
with the temporary test report; unexpected files are retained.

Expand **Shared tasks** and choose **Load shared tasks** to read optional
`.tabryo/project.json` inside the selected project. No task runs on loading.
**Review shared task** uses the same selected toolchain, command review,
document checks, process ownership and cancellation as the manual form.
Changes to the configuration after loading or review require loading it again.
Use **Open configuration** to edit an existing file with protected saves.
Create the optional file yourself; **Show example** provides its initial JSON:

```json
{
  "version": 1,
  "tasks": [
    {"name": "Analyze", "kind": "analyze"},
    {"name": "Tests", "kind": "test", "coverage": true}
  ]
}
```

Tasks accept `name`, `kind` (`analyze`, `test`, `run`, `build`), optional `target`,
`filter`, `buildTarget`, `arguments` and `coverage`. Targets use project-relative
paths with forward slashes. Application arguments are a JSON string list for
Run; coverage applies to Test. Existing language-specific command restrictions
still apply. The file is limited to 64 KiB and 32 uniquely named tasks. Unknown
fields, traversal and absolute targets are refused. Executable paths remain in
local toolchain selections; keep secrets and machine-specific values out of this
shared file. Generic shell commands and environment overrides are not part of
this task format.

Choose **Search workspace** from the sidebar or command palette for literal,
single-line text search in saved UTF-8 files. Case sensitivity, a file-path
substring and comma-separated excluded directory names narrow the search.
Known dependency/build directories and links are skipped; Git ignore rules are
not applied. Unsaved buffers are not searched. Results show file, line, UTF-16
column and a bounded text preview. Opening a changed result preserves the buffer
and asks for a fresh search when its location no longer matches.
Search starts only on request, can be cancelled or replaced, and discards stale
responses. Limits are 500 matches, six directory levels, 512 directories,
12,000 entries, 512 KiB per file and 32 MiB read per search. Reached limits and
skipped unreadable/binary/oversized files are visible.

Native tests exercise Black **26.5.1**, pytest **9.0.2**, pytest-cov **7.1.0**
and Dart coverage **1.15.1** with
`TABRYO_TEST_TASKS=1`; optional `TABRYO_TEST_BLACK` and `TABRYO_TEST_PYTHON`
override tool discovery. The desktop workbench test also runs real Flutter tests
through an owned terminal and checks coverage, source navigation, stale search
results and task cancellation.

## Build and test

Use Flutter **3.47.2**, Dart **3.13.2**, and the committed pubspec.lock. Dartitect
**1.1.0** packages resolve from the same canonical Git tag. Architecture is
native_strict MVVM with constructor-injected ports and an explicit composition root.

```sh
npm --prefix packages/editor_web ci --ignore-scripts --no-audit --no-fund
npm --prefix packages/editor_web run build
flutter pub get --enforce-lockfile
flutter analyze
dart run dartitect_cli:dartitect scan
flutter test --concurrency=1
flutter test integration_test/terminal_host_test.dart -d windows
flutter test integration_test/workbench_test.dart -d windows
flutter test integration_test/editor_test.dart -d windows
flutter build windows --release
```

Use Node.js 22 or newer to bundle the pinned editor before Flutter builds.
On Ubuntu install Flutter's Linux desktop dependencies plus `libwebkit2gtk-4.1-dev`, use `-d linux` and
`flutter build linux --release`. Native editor keyboard tests also require
`xdotool`; headless integration tests use `xvfb-run -a`.
The Desktop workflow runs the native tests and packages the entire Release
bundle on both operating systems. Distribute every file in the bundle, not just
the executable. Builds are unsigned.

## Limits and release status

The release workflow publishes only artifacts from a successful Desktop run at
the tagged commit, then downloads the published assets and verifies their hashes.
The matrix covers native PTY lifecycle, 100 open/close cycles, desktop interaction,
Git stage/commit/push against a disposable local remote, Release execution, and
startup of extracted bundles without child processes. See the
[executed checks](https://github.com/ftr-tuta/tabryo/actions/workflows/desktop.yml).

Real Codex CLI interaction was accepted on Windows 11: TUI, accented input,
resizing, an approval interaction and Ctrl+C. Linux validation is automated on
Ubuntu 24.04 with Xvfb; it is not manual desktop or authenticated Codex acceptance.

Release observations on Windows 11 (Flutter 3.47.2, September 2026): the actual
empty app used 104.7 MiB working set. The Release desktop integration entrypoint
used 108 MiB empty, 123 MiB with one terminal and 145 MiB with four terminals.
These latter observations include Flutter's integration binding and use small
local echo-loop fixtures. They exclude the shell/ConPTY/Codex child processes.
The initial Windows targets remain 120/180/260 MiB respectively; these observations
meet them under those conditions, not for arbitrary workloads or GPU drivers.

On the Ubuntu 24.04 Xvfb runner, Release integration RSS was 251/317/340 MiB
for the same empty/one/four fixture states. The extracted application used
257,156 KiB RSS empty and had zero child processes. These are Linux RSS readings
from a virtual display without DRI3 GPU acceleration, not Windows working-set
equivalents. The integration binding, renderer and driver contribute to the
process total. The original observations are in
[Desktop run 34000622109](https://github.com/ftr-tuta/tabryo/actions/runs/34000622109).

Each terminal retains 2,000 lines with a 160-column and 100-row viewport cap.
Native input is limited to 256 KiB per session and 2 MiB across sessions;
a rejected paste is reported without silently truncating it. File previews stop
at 512 KiB; the shared file/Git preview cache is limited to 24 MiB. Git reads are
bounded and cancellable, with two readers globally and one writer per common Git
directory. History retains one page of 100 commits. Per-tab splits are limited
to four panes. Working-set targets require measurement on Release builds and
are not guarantees derived from these bounds.

Tabryo is BSD-3-Clause. See LICENSE and THIRD_PARTY_NOTICES.md. The native host
retains the upstream flutter_pty MIT license and Dart SDK notices.
