# Tabryo

A local desktop workbench for shells, the installed Codex CLI, files, Git and
worktrees. Target platforms: Windows 11 x64 and Ubuntu 24.04 x64.

## Use

Open an absolute workspace directory, then choose **Shell**, **Codex**, or
**Resume**. Tabryo starts no process at boot. Codex uses your installed CLI and
its existing authentication; Tabryo does not implement an agent or store tokens.
Install Git and the Codex CLI separately and make them available on PATH.

Use the sidebar for paginated files, changes, history and worktrees. File and Git
previews are read-only. Stage and unstage use literal paths. Commit displays Git's
effective identity and preserves hooks and signing. Fetch and push use a terminal
so credentials and prompts remain interactive. Worktree removal refuses the main
checkout, locked, dirty, untracked or ignored content, and Tabryo-owned sessions.
Close external editors and processes yourself before confirming removal.

Ctrl+Shift+P opens the command palette; Ctrl+O opens a workspace;
Ctrl+Shift+T starts a shell; Ctrl+Shift+D/E splits the focused pane;
Ctrl+Shift+J changes pane; Ctrl+Tab changes tab; Ctrl+Shift+W closes a pane.
Ctrl+Shift+C/V copies/pastes in terminals. Multiline paste requires confirmation.
Ctrl+Shift+F searches terminal scrollback; F5 refreshes the sidebar.

Preferences, remembered directories, layout and file watching are opt-in.
Disabling persistence clears the corresponding persisted data. Watching monitors
the selected root, not an unbounded recursive tree. Refresh after nested changes.
Terminal output cannot silently access the clipboard, open links or download files.

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
flutter build windows --release
```

On Ubuntu install Flutter's Linux desktop dependencies, use `-d linux` and
`flutter build linux --release`. Headless integration tests use `xvfb-run -a`.
The Desktop workflow runs the native tests and packages the entire Release
bundle on both operating systems. Distribute every file in the bundle, not just
the executable. Builds are unsigned.

## Limits and release status

This is the 0.1.0 implementation candidate. A Git tag/release is not acceptance
until both platform checks, downloaded bundles and real Codex interaction pass.
Synthetic CLI tests do not certify authentication, paid prompts or real Codex UX.

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
