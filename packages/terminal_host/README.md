# terminal_host

Owned FFI PTY host for Tabryo on Windows and Linux. Windows uses ConPTY and a
kill-on-close job; Linux uses forkpty and an owned process group. Dart owns the
ports and asynchronous close future. Output acknowledgement, EOF and process
exit are separate signals. Native queues and shutdown are bounded.

Public API: TerminalPty.start, output, exitCode, drained, write, resize and close.
Call close even after natural process exit. No method invokes a shell implicitly;
Windows command scripts use a validated, explicit cmd.exe launch.

Run the parent application's integration_test/terminal_host_test.dart on each
native target. Third-party source notices are retained next to the source.
