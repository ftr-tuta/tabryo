# Third-party notices

`src/` begins from `flutter_pty` 0.4.2 by xuty, licensed under the MIT License.
Tabryo retains the original license in
[`UPSTREAM_FLUTTER_PTY_LICENSE`](UPSTREAM_FLUTTER_PTY_LICENSE). Changes are
limited to lifecycle, environment, and bounded-read behaviour for this host.

The Dart API dynamic-linking headers in `src/upstream_include/` retain their
upstream notices.

Windows also bundles Microsoft.Windows.Console.ConPTY 1.24.260710001 (MIT) to
replace older inbox implementations. Its DLL and OpenConsole.exe are copied
from the hash-pinned NuGet archive at build time. The full MIT notice is included
in the application's THIRD_PARTY_NOTICES.md and every distributed bundle.
