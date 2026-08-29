# Security policy

## Supported versions

Security fixes are provided for the latest Kangaroo 1.x release. Pre-release
and development snapshots are supported only until the next release.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's private
security advisory form for `P4suta/kangaroo` and include:

- affected version, target, runtime, and operating system;
- a minimal reproduction or protocol transcript;
- expected impact and any known workaround; and
- whether disclosure is time-sensitive.

Maintainers aim to acknowledge a report within 7 days, provide an initial
assessment within 14 days, and coordinate disclosure after a fix is available.
Please avoid accessing data that is not yours while producing a reproduction.

Kangaroo runs project test code and subprocesses with the invoking user's
authority. Treat untrusted test repositories and editor workspaces as
untrusted executable code. Deno users should review the permissions described
in [docs/runtimes.md](docs/runtimes.md).
