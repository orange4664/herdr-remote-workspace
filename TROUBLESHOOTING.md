# Troubleshooting

## A required command is missing

Confirm `ssh`, `mutagen`, `herdr`, and `python3` are available in the same shell
that launches `hremote`. On macOS, install Mutagen from its supported Homebrew
formula shown in the README. Open a fresh interactive shell after changing PATH.

If Homebrew stalls while auto-updating a configured mirror, interrupt that
attempt and retry the official formula without an update for that invocation:

```bash
HOMEBREW_NO_AUTO_UPDATE=1 brew install mutagen-io/mutagen/mutagen
```

Recent Homebrew versions may require explicit trust for this third-party tap.
Verify `brew tap-info mutagen-io/mutagen` points to
`https://github.com/mutagen-io/homebrew-mutagen` before running
`brew trust mutagen-io/mutagen`.

## A non-interactive hremote run requires --session NAME

Pass the Herdr named session for each non-interactive invocation:

```bash
hremote --session <name> --dry-run
hremote --session <name>
```

When run directly from an interactive terminal, omitting `--session` opens a
prompt with no default. Redirected input, pipelines, and unattended jobs fail
closed instead of reading `HERDR_SESSION` from a config or choosing a session
implicitly. A legacy config may still contain that field, but the launcher
intentionally ignores it.

## Key-only SSH validation fails

Run `ssh -o BatchMode=yes <ssh-target> true`. Repair the existing local SSH
alias, agent, or public-key setup without placing private keys in this repository
or generated config. The package does not alter SSH server or firewall policy.

## The first run opens Herdr outside the project

The remote Herdr component was not installed yet. The first interactive remote
attach bootstraps a matching binary. Exit that attach and run
`hremote --session <name>` again; the launcher will start the named server and
create or focus the configured project workspace.

## Mutagen reports conflicts

Do not use an overwrite mode as a quick fix. Run:

```bash
mutagen sync list <sync-name>
```

Compare both conflicting versions, preserve the intended content manually, and
flush again. `two-way-safe` intentionally stops when automatic reconciliation
would discard unsynchronized work.

## Synchronization is paused or stale

The launcher resumes the configured session and runs `mutagen sync flush`. If
that fails, inspect the session for endpoint connectivity, permissions, ignored
paths, non-portable symlinks, or conflicts. Large first synchronizations may take
substantially longer than later flushes.

If `mutagen sync list --long <sync-name>` reports that it cannot walk to the
transition root parent, create the configured remote parent directory and flush
again. Current `hremote` creates the remote root before a new session, so this
message usually indicates an older launcher or a manually created session.

## A symlink is rejected

Mutagen `portable` mode accepts safe relative links and rejects non-portable
links. Ignore a machine-local runtime link. For an absolute link whose target is
inside the project, configure an ignored path plus `--remote-symlink A=B`, where
`B` is the equivalent relative target.

The launcher will stop if the remote link path contains a regular file,
directory, or a different symlink. Inspect it manually; the launcher will never
replace it automatically.

## A Mutagen synchronization name already exists

Inspect the named Mutagen session and verify both endpoints. Choose another name
or explicitly terminate the old session only after confirming it belongs to the
same project. The installer does not terminate existing sessions.

With named profiles, confirm that you selected the intended profile before
changing anything:

```bash
hremote --list-profiles
hremote --session <herdr-session> --profile <name> --dry-run
```

The list command prints names only; it does not display SSH targets, local
paths, or remote paths. Every profile should use its own Mutagen synchronization
name. Profiles do not choose a Herdr session; pass `--session` for each
invocation. If the selected profile's Mutagen name already belongs to different
endpoints or policy, `hremote` stops instead of resuming or replacing it.

## A profile is missing or rejected

Named profiles live under `~/.config/hremote/profiles/` and use a `.conf`
suffix. If `XDG_CONFIG_HOME` is set, both the installer and launcher use
`$XDG_CONFIG_HOME/hremote/profiles/` instead. Check that variable first when a
profile exists on disk but is absent from `hremote --list-profiles`. Profile
names must begin with an ASCII letter or digit and contain only ASCII letters,
digits, `.`, `_`, and `-`; path separators and `..` traversal are rejected.

Do not combine `--profile` with `--config`. Use `--profile NAME` for a generated
named profile, `--config FILE` for an explicit config path, or neither for the
original default config.

## Installing another profile reports a launcher collision

The installer reuses the existing launcher only when it is a byte-identical,
regular executable copy of this repository's `bin/hremote`. A symlink,
non-executable file, or locally modified launcher is refused without `--force`.
Review the existing file and the proposed launcher before deciding whether an
intentional replacement is appropriate. Existing profile configs are always
refused without `--force`, even when the shared launcher is reusable.

## The Herdr server does not become ready

Check the remote Herdr installation and the remote log at
`~/.config/herdr/hremote-server.log`. Confirm the selected named session is
valid and that the remote user can write under its own config directory. No
inbound VPS port is required; both Herdr and Mutagen connect over SSH.

Do not use the exit status of `herdr status server` as a running-state test: a
valid `not_running` JSON response exits successfully. Automation should parse
the `--json` response, as this launcher's implementation does.

## Clean rollback

Remove the exact installed launcher and only the generated default/profile
configs being retired. Verify each Mutagen session's endpoints before
terminating it. Keep synchronized trees by default, and do not delete remote
project data as part of rollback.
