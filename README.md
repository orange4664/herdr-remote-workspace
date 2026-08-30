# Herdr Remote Workspace

Run Herdr as a local thin client while Herdr terminals execute on an SSH host
against a Mutagen-synchronized project copy. The package is project-neutral:
real paths, SSH aliases, and synchronization names live only in a generated
local config. The Herdr session is selected for each launcher invocation.

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
  --dry-run
```

Remove `--dry-run` to validate key-only SSH and install:

- `hremote` under `~/.local/bin`;
- a mode-600 config under `~/.config/hremote/config`.

This no-profile form remains the default for a single project. To configure
multiple servers or projects behind the same command, install a named profile:

```bash
./install.sh \
  --local-path /absolute/path/to/second-project \
  --ssh-target second-ssh-alias \
  --remote-path '~/work/second-project' \
  --sync-name second-project-sync \
  --profile second
```

Named profiles are written to `~/.config/hremote/profiles/NAME.conf`, or to
`$XDG_CONFIG_HOME/hremote/profiles/NAME.conf` when `XDG_CONFIG_HOME` is set. An
explicit `--config-file FILE` takes precedence over that generated profile
path. Profile names must start with an ASCII letter or digit and may contain
only ASCII letters, digits, `.`, `_`, and `-`.

One launcher is shared by all profiles. Installing another profile reuses an
existing byte-identical executable launcher without requiring `--force`. The
installer still refuses a different existing launcher or an existing target
config unless `--force` is supplied. Use `--bin-dir` and `--config-file` to
choose other local destinations. Installation does not create a Mutagen session
or remote directory.

Ensure the selected bin directory is already on `PATH`; the installer does not
edit startup files. Verify with `command -v hremote` in a fresh shell.

## Use

Preview launcher validation without SSH or writes:

```bash
hremote --session project-session --dry-run
```

Then run `hremote --session project-session`. It performs these steps in order:

1. validates the generated config and local dependencies;
2. verifies key-only SSH access and creates the configured remote directory;
3. verifies that any same-named Mutagen session has exactly the configured
   endpoints, then creates or resumes it using `two-way-safe`, `portable`
   symlinks, VCS ignores, and configured path ignores;
4. flushes synchronization and stops on a conflict or propagation error;
5. checks optional remote symlink translations without replacing unexpected
   remote objects;
6. starts or reuses the named remote Herdr server, creates or focuses the
   project workspace, and attaches the local thin client. The managed workspace
   label is `hremote-<session>-<sync-name>`.
7. when the client exits, the terminal closes, setup finishes, or a later step
   fails, performs a best-effort final flush and pauses the selected Mutagen
   session. It stops the Mutagen daemon only when no other session is active.

Mutagen session metadata and both synchronized directory trees persist, but the
watcher and its SSH connection are active only while `hremote` is running. The
remote Herdr server and panes remain running after the local client exits.

On the first run, Herdr may need an interactive attach to bootstrap its matching
remote component. Exit after bootstrap and run
`hremote --session project-session` again so it can create the project-rooted
workspace with the same selected session.

`--session NAME` is the only non-interactive way to select a Herdr session. If
it is omitted while standard input and standard error are attached to a
terminal, `hremote` prompts for a non-empty validated name with no default. If
either stream is not a terminal, omission fails before SSH, Mutagen, or Herdr is
run. This includes pipelines, redirected input, and unattended jobs.

List configured profile names without displaying their SSH targets or paths,
then select one by name:

```bash
hremote --list-profiles
hremote --session second-session --profile second --dry-run
hremote --session second-session --profile second
```

`--profile` and `--config` are mutually exclusive. Without either option,
`hremote` keeps loading the original default config (including
`HREMOTE_CONFIG`, when set). Each profile supplies its own SSH target, remote
path, and Mutagen synchronization name; profiles do not select a Herdr session.
Legacy configs that still contain `HERDR_SESSION` remain sourceable, but that
field is ignored and never acts as a default. The same endpoint and
synchronization-policy checks run after profile selection, so a same-named
Mutagen session with different endpoints remains a fail-closed error.

Different profiles may deliberately share one Herdr session. Give every profile
a unique local path, remote path, and Mutagen sync name, then pass the same
`--session` value when launching them:

```bash
hremote --session team --profile project
hremote --session team --profile notes
```

Their managed workspace labels will be different, for example
`hremote-team-project-sync` and `hremote-team-notes-sync`. Herdr's ordinary
display labels are not unique, so `hremote` ignores unrelated duplicates and
selects only the exact managed label. It still stops if that managed label is
duplicated or its pane cwd does not match the configured remote path.

To configure and validate everything without opening the TUI, run:

```bash
hremote --session project-session --setup-only
```

`--setup-only` uses the same lifecycle: it resumes and validates the selected
sync, then final-flushes and pauses it before returning.

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

To uninstall the local command, remove only the installed launcher and the
specific generated config or profile configs you no longer need. To stop
synchronization, first verify each profile's endpoints, then run:

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
