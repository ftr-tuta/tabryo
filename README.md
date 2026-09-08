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
Ubuntu 24.04 requires a graphical session and the GTK/OpenGL runtime:
`sudo apt install libgtk-3-0t64 libstdc++6 libgl1`.
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
It retains up to 12 open documents, each within 512 KiB; an oversized edit is
refused without truncating the buffer. Binary, invalid UTF-8, mixed-newline and
larger files use bounded read-only previews. **Document actions** can compare
the buffer with disk or reload after confirmation.

Saving checks the original bytes, modification time and file mode, stages a
flushed replacement beside the file, rechecks the baseline and replaces it.
Conflicts, unavailable paths, unpreserved file modes and write failures preserve the buffer. This is
optimistic concurrency; it does not lock out other applications during the final
filesystem rename. Unsaved buffers live in memory; crash recovery remains planned.

Preferences, remembered directories, layout and file watching are opt-in.
Disabling persistence clears the corresponding persisted data. Watching monitors
the selected root, not an unbounded recursive tree. Refresh after nested changes.
Terminal output cannot silently access the clipboard, open links or download files.

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
The Tabryo MCP server and graphical Codex conversations remain planned;
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

## Build and test

Use Flutter **3.47.2**, Dart **3.13.2**, and the committed pubspec.lock. Dartitect
**1.1.0** packages resolve from the same canonical Git tag. Architecture is
native_strict MVVM with constructor-injected ports and an explicit composition root.

```sh
flutter pub get --enforce-lockfile
flutter analyze
dart run dartitect_cli:dartitect scan
flutter test --concurrency=1
flutter test integration_test/terminal_host_test.dart -d windows
flutter test integration_test/workbench_test.dart -d windows
flutter build windows --release
```

On Ubuntu install Flutter's Linux desktop dependencies, use `-d linux` and
`flutter build linux --release`. Headless integration tests use `xvfb-run -a`.
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
