# Herdr Remote Workspace

Run Herdr as a local thin client while Herdr terminals execute on an SSH host
against a Mutagen-synchronized project copy. The package is project-neutral:
real paths, SSH aliases, and session names live only in a generated local config.

```text
local project -- Mutagen two-way-safe --> SSH host project copy
       |                                      |
       +---- local Herdr thin client ---------+-- remote Herdr server
```

## Prerequisites

- macOS or Linux with Bash, OpenSSH, and Python 3
- [Herdr](https://herdr.dev/) installed locally
- [Mutagen](https://mutagen.io/) installed locally
- Key-only SSH access through an existing OpenSSH host or alias
- Herdr and Mutagen available on the invoking shell's `PATH`

On macOS, Mutagen's supported stable Homebrew formula is:

```bash
brew install mutagen-io/mutagen/mutagen
```

This repository does not install SSH keys, edit SSH or shell configuration,
open inbound ports, install agent CLIs, or relay credentials.

## Install

Clone the repository, review the scripts, and run a dry run with explicit values:

```bash
./install.sh \
  --local-path /absolute/path/to/project \
  --ssh-target ssh-config-alias \
  --remote-path '~/work/project' \
  --sync-name project-sync \
  --session-name project-session \
  --dry-run
```

Remove `--dry-run` to validate key-only SSH and install:

- `hremote` under `~/.local/bin`;
- a mode-600 config under `~/.config/hremote/config`.

The installer refuses to replace either file unless `--force` is supplied. Use
`--bin-dir` and `--config-file` to choose other local destinations. It does not
create a Mutagen session or remote directory.

Ensure the selected bin directory is already on `PATH`; the installer does not
edit startup files. Verify with `command -v hremote` in a fresh shell.

## Use

Preview launcher validation without SSH or writes:

```bash
hremote --dry-run
```

Then run `hremote`. It performs these steps in order:

1. validates the generated config and local dependencies;
2. verifies key-only SSH access and creates the configured remote directory;
3. verifies that any same-named Mutagen session has exactly the configured
   endpoints, then creates or resumes it using `two-way-safe`, `portable`
   symlinks, VCS ignores, and configured path ignores;
4. flushes synchronization and stops on a conflict or propagation error;
5. checks optional remote symlink translations without replacing unexpected
   remote objects;
6. starts or reuses the named remote Herdr server, creates or focuses the
   project workspace, and attaches the local thin client.

On the first run, Herdr may need an interactive attach to bootstrap its matching
remote component. Exit after bootstrap and run `hremote` again so it can create
the project-rooted workspace.

To configure and validate everything without opening the TUI, run:

```bash
hremote --setup-only
```

Mutagen preserves ordinary large files because synchronization is independent
of Git object limits. Git remains the source-history and formal-commit workflow.

## Ignore and symlink options

The installer ignores `.DS_Store`, `.venv`, and `.tmpbin` by default. Add more
repeatable ignores with `--ignore PATH`.

Portable relative project symlinks synchronize naturally. For a local absolute
symlink whose target is inside the project, ignore the link path and recreate it
remotely as a relative link:

```bash
./install.sh ... \
  --ignore docs/current \
  --remote-symlink docs/current=../shared
```

The launcher refuses to overwrite a non-link object or a link with a different
target. See `config/hremote.conf.example` for the generated config shape.

## Safety and rollback

Mutagen's `two-way-safe` mode gives both endpoints equal precedence and surfaces
conflicting unsynchronized edits instead of silently choosing a winner. Inspect
conflicts with `mutagen sync list <sync-name>` before retrying.

To uninstall the local command, remove only the installed launcher and generated
config. To stop synchronization, first verify its endpoints, then run:

```bash
mutagen sync terminate <sync-name>
```

Termination does not delete either synchronized tree. Remote project deletion
is deliberately not automated. A named remote Herdr session can be stopped
separately after confirming its name.

## Development checks

Run the local test suite before publishing changes:

```bash
./scripts/check.sh
```

It checks Bash syntax, exercises dry-run and isolated installation behavior with
stubbed external commands, verifies generated config permissions, and scans all
repository candidates for private-key markers, address-like values, tokens,
personal paths, and production-specific identifiers.

## License

MIT. See `LICENSE`.
