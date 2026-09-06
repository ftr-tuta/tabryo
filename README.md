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
