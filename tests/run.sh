#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hremote-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

# Keep the generated config inside the disposable HOME on every runner.
unset XDG_CONFIG_HOME HREMOTE_CONFIG

fail() {
  printf 'test: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack=$1
  local needle=$2
  [[ $haystack == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_not_contains() {
  local haystack=$1
  local needle=$2
  [[ $haystack != *"$needle"* ]] || fail "expected output not to contain: $needle"
}

project_dir=$TEST_ROOT/project
second_project_dir=$TEST_ROOT/second-project
home_dir=$TEST_ROOT/home
stub_dir=$TEST_ROOT/stubs
bin_dir=$home_dir/bin
config_file=$home_dir/config/hremote.conf
log_file=$TEST_ROOT/commands.log
mkdir -p "$project_dir" "$second_project_dir" "$stub_dir" "$home_dir" "$TEST_ROOT/state"

for command_name in ssh herdr; do
  sed "s|COMMAND_NAME|$command_name|g" >"$stub_dir/$command_name" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' COMMAND_NAME "$*" >>"${HREMOTE_TEST_LOG:?}"
if [[ COMMAND_NAME == ssh ]]; then
  case " $* " in
    *' printf "%s\n" "$HOME" '*)
      printf '%s\n' "$HOME"
      exit 0
      ;;
    *" sh -s -- $HOME/work/example ")
      cat >/dev/null || true
      mkdir -p "$HOME/work/example"
      exit 0
      ;;
    *" sh -s -- example-session --version ")
      cat >/dev/null || true
      printf 'herdr 0.8.0-test\n'
      exit 0
      ;;
    *" sh -s -- example-session status server --json ")
      cat >/dev/null || true
      if [[ -f ${HREMOTE_FAKE_STATE:?}/server-running ]]; then
        printf '{"status":"running","running":true,"version":"0.8.0-test","compatible":true}\n'
      else
        printf '{"status":"not_running","running":false,"compatible":null}\n'
      fi
      exit 0
      ;;
    *" sh -s -- example-session workspace list ")
      cat >/dev/null || true
      printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"hremote-example-session"}]}}\n'
      exit 0
      ;;
    *" sh -s -- example-session pane list --workspace w1 ")
      cat >/dev/null || true
      printf '{"result":{"panes":[{"workspace_id":"w1","cwd":"%s/work/example"}]}}\n' "$HOME"
      exit 0
      ;;
    *" sh -s -- example-session workspace focus w1 ")
      cat >/dev/null || true
      exit 0
      ;;
    *" sh -s -- example-session ")
      cat >/dev/null || true
      : >"${HREMOTE_FAKE_STATE:?}/server-running"
      exit 0
      ;;
  esac
  if [[ $* == *'command -v herdr >/dev/null'* ]]; then
    [[ ${HREMOTE_TEST_HERDR_INSTALLED:-} == 1 ]] && exit 0
    exit 1
  fi
  cat >/dev/null || true
elif [[ COMMAND_NAME == herdr && " $* " == *" --version "* ]]; then
  printf 'herdr 0.8.0-test\n'
fi
exit 0
STUB
  chmod +x "$stub_dir/$command_name"
done

cat >"$stub_dir/mutagen" <<'STUB'
#!/usr/bin/env bash
printf 'mutagen %s\n' "$*" >>"${HREMOTE_TEST_LOG:?}"
if [[ $1 == sync && $2 == list ]]; then
  case ${HREMOTE_TEST_SESSION:-missing} in
    missing)
      printf '[]\n'
      ;;
    mismatch)
      printf '[{"name":"example-sync","mode":"two-way-safe","symlink":{"mode":"portable"},"ignore":{"vcs":true},"alpha":{"path":"/wrong/project"},"beta":{"host":"example-host","path":"~/work/example"}}]\n'
      ;;
    second-mismatch)
      printf '[{"name":"second-sync","mode":"two-way-safe","symlink":{"mode":"portable"},"ignore":{"vcs":true,"paths":[".DS_Store",".venv",".tmpbin"]},"alpha":{"protocol":"local","path":"/wrong/project"},"beta":{"protocol":"ssh","host":"second-host","path":"~/work/second"}}]\n'
      ;;
    match)
      paused=true
      connected=false
      scanned=false
      if [[ -f ${HREMOTE_FAKE_STATE:?}/session-resumed ]]; then
        paused=false
        connected=true
        scanned=true
      fi
      printf '[{"name":"unrelated","alpha":{"path":"/other"}},{"name":"example-sync","paused":%s,"mode":"two-way-safe","symlink":{"mode":"portable"},"ignore":{"vcs":true,"paths":[".DS_Store",".venv",".tmpbin","build-cache","docs/current"]},"alpha":{"protocol":"local","path":"%s","connected":%s,"scanned":%s},"beta":{"protocol":"ssh","host":"example-host","path":"~/work/example","connected":%s,"scanned":%s}}]\n' \
        "$paused" "${HREMOTE_TEST_PROJECT:?}" "$connected" "$scanned" "$connected" "$scanned"
      ;;
  esac
  exit 0
fi
if [[ $1 == sync && $2 == resume ]]; then
  : >"${HREMOTE_FAKE_STATE:?}/session-resumed"
  exit 0
fi
exit 0
STUB
chmod +x "$stub_dir/mutagen"

TEST_PATH=$stub_dir:/usr/bin:/bin
# The remote shell, not this test process, must expand the leading tilde.
# shellcheck disable=SC2088
remote_path='~/work/example'
# shellcheck disable=SC2088
second_remote_path='~/work/second'
remote_path_prefix=${remote_path%example}

help_output=$(HOME="$home_dir" PATH="$TEST_PATH" "$ROOT/install.sh" --help)
assert_contains "$help_output" '--local-path'
assert_contains "$help_output" '--profile NAME'
assert_not_contains "$help_output" '--session-name'

if HOME="$home_dir" PATH="$TEST_PATH" "$ROOT/install.sh" --dry-run >/dev/null 2>&1; then
  fail 'installer accepted missing required arguments'
fi

dry_output=$(HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  "$ROOT/install.sh" \
  --local-path "$project_dir" \
  --ssh-target example-host \
  --remote-path "$remote_path" \
  --sync-name example-sync \
  --bin-dir "$bin_dir" \
  --config-file "$config_file" \
  --dry-run)
assert_contains "$dry_output" 'No files, synchronization sessions, or remote objects were changed.'
assert_contains "$dry_output" "config:   $config_file"
[[ ! -e $config_file && ! -e $bin_dir/hremote ]] || fail 'dry-run wrote installation files'
[[ ! -e $log_file ]] || fail 'dry-run executed an external command'

profile_custom_output=$(HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  "$ROOT/install.sh" \
  --local-path "$project_dir" \
  --ssh-target example-host \
  --remote-path "$remote_path" \
  --sync-name example-sync \
  --profile custom-name \
  --config-file "$config_file" \
  --dry-run)
assert_contains "$profile_custom_output" "config:   $config_file"
assert_not_contains "$profile_custom_output" 'profiles/custom-name.conf'

if HOME="$home_dir" PATH="$TEST_PATH" "$ROOT/install.sh" \
  --local-path "$project_dir" \
  --ssh-target example-host \
  --remote-path "$remote_path" \
  --sync-name example-sync \
  --profile ../unsafe \
  --dry-run >/dev/null 2>&1; then
  fail 'installer accepted an unsafe profile name'
fi

HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  "$ROOT/install.sh" \
  --local-path "$project_dir" \
  --ssh-target example-host \
  --remote-path "$remote_path" \
  --sync-name example-sync \
  --ignore build-cache \
  --ignore docs/current \
  --remote-symlink docs/current=../shared \
  --bin-dir "$bin_dir" \
  --config-file "$config_file" >/dev/null

[[ -x $bin_dir/hremote ]] || fail 'launcher was not installed executable'
[[ -f $config_file ]] || fail 'config was not generated'
if stat -c '%a' "$config_file" >/dev/null 2>&1; then
  config_mode=$(stat -c '%a' "$config_file")
else
  config_mode=$(stat -f '%Lp' "$config_file")
fi
[[ $config_mode == 600 ]] || fail "config mode is $config_mode, expected 600"
grep -Fq "SSH_TARGET='example-host'" "$config_file" || fail 'SSH target was not rendered'
grep -Fq "REMOTE_PATH='~/work/example'" "$config_file" || fail 'remote path did not round-trip literally'
grep -Fq 'REMOTE_SYMLINKS=(' "$config_file" || fail 'remote symlink config was not rendered'
if grep -Fq 'HERDR_SESSION=' "$config_file"; then
  fail 'new default config persisted a Herdr session'
fi
printf "HERDR_SESSION='legacy-config-session'\n" >>"$config_file"

if HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  "$ROOT/install.sh" \
  --local-path "$project_dir" \
  --ssh-target example-host \
  --remote-path "$remote_path" \
  --sync-name example-sync \
  --bin-dir "$bin_dir" \
  --config-file "$config_file" >/dev/null 2>&1; then
  fail 'installer overwrote existing files without --force'
fi

profile_dir=$home_dir/.config/hremote/profiles
primary_profile=$profile_dir/primary.conf
second_profile=$profile_dir/second.conf

HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  "$ROOT/install.sh" \
  --local-path "$project_dir" \
  --ssh-target example-host \
  --remote-path "$remote_path" \
  --sync-name example-sync \
  --profile primary \
  --bin-dir "$bin_dir" >/dev/null

HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  "$ROOT/install.sh" \
  --local-path "$second_project_dir" \
  --ssh-target second-host \
  --remote-path "$second_remote_path" \
  --sync-name second-sync \
  --profile second \
  --bin-dir "$bin_dir" >/dev/null

[[ -f $primary_profile && -f $second_profile ]] || fail 'profile configs were not generated in the profile directory'
cmp -s "$ROOT/bin/hremote" "$bin_dir/hremote" || fail 'profile installation changed the shared launcher'
grep -Fq "SSH_TARGET='example-host'" "$primary_profile" || fail 'primary profile has the wrong SSH target'
grep -Fq "SSH_TARGET='second-host'" "$second_profile" || fail 'second profile has the wrong SSH target'
grep -Fq "SYNC_NAME='second-sync'" "$second_profile" || fail 'second profile has the wrong Mutagen session'
if grep -Fq 'HERDR_SESSION=' "$second_profile"; then
  fail 'new profile config persisted a Herdr session'
fi
printf "HERDR_SESSION='legacy-profile-session'\n" >>"$second_profile"

if HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  "$ROOT/install.sh" \
  --local-path "$project_dir" \
  --ssh-target example-host \
  --remote-path "$remote_path" \
  --sync-name example-sync \
  --profile primary \
  --bin-dir "$bin_dir" >/dev/null 2>&1; then
  fail 'installer overwrote an existing profile config without --force'
fi

launcher_backup=$TEST_ROOT/hremote.backup
cp "$bin_dir/hremote" "$launcher_backup"
printf '\n# locally changed launcher\n' >>"$bin_dir/hremote"
if HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  "$ROOT/install.sh" \
  --local-path "$project_dir" \
  --ssh-target example-host \
  --remote-path "$remote_path" \
  --sync-name unused-sync \
  --profile unused \
  --bin-dir "$bin_dir" >/dev/null 2>&1; then
  fail 'installer accepted a different existing launcher without --force'
fi
mv "$launcher_backup" "$bin_dir/hremote"

launcher_help=$(HOME="$home_dir" PATH="$TEST_PATH" "$bin_dir/hremote" --help)
assert_contains "$launcher_help" '--session NAME'
assert_contains "$launcher_help" '--profile NAME'
assert_contains "$launcher_help" '--list-profiles'

profile_list=$(HOME="$home_dir" PATH="$TEST_PATH" "$bin_dir/hremote" --list-profiles)
[[ $profile_list == $'primary\nsecond' ]] || fail "unexpected profile list: $profile_list"
assert_not_contains "$profile_list" 'example-host'
assert_not_contains "$profile_list" "$remote_path_prefix"

if HOME="$home_dir" PATH="$TEST_PATH" "$bin_dir/hremote" \
  --session example-session --profile ../unsafe --dry-run >/dev/null 2>&1; then
  fail 'launcher accepted an unsafe profile name'
fi
if HOME="$home_dir" PATH="$TEST_PATH" "$bin_dir/hremote" \
  --session example-session --profile primary --config "$config_file" --dry-run >/dev/null 2>&1; then
  fail 'launcher combined --profile and --config'
fi
if HOME="$home_dir" PATH="$TEST_PATH" "$bin_dir/hremote" --list-profiles --dry-run >/dev/null 2>&1; then
  fail 'launcher combined --list-profiles with another mode'
fi
if HOME="$home_dir" PATH="$TEST_PATH" "$bin_dir/hremote" \
  --list-profiles --session example-session >/dev/null 2>&1; then
  fail 'launcher combined --list-profiles with --session'
fi

for omitted_mode in attach dry-run setup-only; do
  : >"$log_file"
  omitted_output=$TEST_ROOT/omitted-$omitted_mode.out
  if [[ $omitted_mode == attach ]]; then
    if HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
      HREMOTE_CONFIG="$config_file" "$bin_dir/hremote" \
      </dev/null >"$omitted_output" 2>&1; then
      fail 'launcher accepted an omitted session in attach mode'
    fi
  elif HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
    HREMOTE_CONFIG="$config_file" "$bin_dir/hremote" "--$omitted_mode" \
    </dev/null >"$omitted_output" 2>&1; then
    fail "launcher accepted an omitted session in $omitted_mode mode"
  fi
  assert_contains "$(<"$omitted_output")" '--session NAME is required when input is not interactive'
  [[ ! -s $log_file ]] || fail "omitted session executed an external command in $omitted_mode mode"
done

: >"$log_file"
if HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  HREMOTE_CONFIG="$config_file" "$bin_dir/hremote" --session 'bad/name' --dry-run \
  >/dev/null 2>&1; then
  fail 'launcher accepted an invalid explicit session'
fi
[[ ! -s $log_file ]] || fail 'invalid explicit session executed an external command'

: >"$log_file"
if HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  HREMOTE_CONFIG="$config_file" "$bin_dir/hremote" \
  --session first --session second --dry-run >/dev/null 2>&1; then
  fail 'launcher accepted duplicate --session options'
fi
[[ ! -s $log_file ]] || fail 'duplicate --session options executed an external command'

: >"$log_file"
interactive_output=$(HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  HREMOTE_CONFIG="$config_file" python3 -c '
import errno, os, pty, select, subprocess, sys, time

master, slave = pty.openpty()
process = subprocess.Popen(sys.argv[1:], stdin=slave, stdout=slave, stderr=slave, close_fds=True)
os.close(slave)
deadline = time.monotonic() + 5
try:
    os.write(master, b"\nexample-session\n")
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("interactive launcher timed out")
        readable, _, _ = select.select([master], [], [], min(0.1, remaining))
        if readable:
            try:
                chunk = os.read(master, 4096)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                chunk = b""
            if chunk:
                os.write(sys.stdout.fileno(), chunk)
            elif process.poll() is not None:
                break
        if process.poll() is not None and not readable:
            break
    status = process.wait(timeout=1)
finally:
    os.close(master)
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
raise SystemExit(status)
' "$bin_dir/hremote" --dry-run 2>&1)
assert_contains "$interactive_output" 'Herdr session name:'
assert_contains "$interactive_output" 'session name cannot be empty'
assert_contains "$interactive_output" 'Configuration and local dependencies are valid.'
[[ ! -s $log_file ]] || fail 'interactive dry-run executed an external command'

: >"$log_file"
second_profile_dry_output=$(HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  "$bin_dir/hremote" --session second-session --profile second --dry-run)
assert_contains "$second_profile_dry_output" 'Configuration and local dependencies are valid.'
[[ ! -s $log_file ]] || fail 'profile dry-run executed an external command'

: >"$log_file"
if HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  HREMOTE_TEST_SESSION=second-mismatch \
  "$bin_dir/hremote" --session second-session --profile second >/dev/null 2>&1; then
  fail 'profile accepted a same-named Mutagen session with different endpoints'
fi
if grep -Fq 'mutagen sync resume second-sync' "$log_file" || grep -Fq 'mutagen sync create' "$log_file"; then
  fail 'profile changed a mismatched Mutagen session'
fi

: >"$log_file"
if ! HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  "$bin_dir/hremote" --session second-session --profile second >"$TEST_ROOT/second-profile.out" 2>&1; then
  sed -n '1,120p' "$TEST_ROOT/second-profile.out" >&2
  fail 'launcher failed to select the second profile'
fi
grep -Fq 'mutagen sync flush second-sync' "$log_file" || fail 'second profile did not use its Mutagen session'
grep -Fq 'second-host:~/work/second' "$log_file" || fail 'second profile did not use its remote endpoint'
grep -Fq 'herdr --remote second-host --session second-session' "$log_file" || fail 'explicit session was not used with the second profile'
if grep -Fq 'legacy-profile-session' "$log_file"; then
  fail 'second profile implicitly selected its legacy Herdr session'
fi

: >"$log_file"
launcher_dry_output=$(HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  HREMOTE_CONFIG="$config_file" "$bin_dir/hremote" --session example-session --dry-run)
assert_contains "$launcher_dry_output" 'Configuration and local dependencies are valid.'
[[ ! -s $log_file ]] || fail 'launcher dry-run executed an external command'

: >"$log_file"
if ! HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  HREMOTE_TEST_PROJECT="$project_dir" HREMOTE_CONFIG="$config_file" \
  "$bin_dir/hremote" --session example-session >"$TEST_ROOT/missing-session.out" 2>&1; then
  sed -n '1,120p' "$TEST_ROOT/missing-session.out" >&2
  fail 'launcher failed while creating a missing Mutagen session'
fi
grep -Fq 'mutagen sync create' "$log_file" || fail 'launcher did not create a missing Mutagen session'
grep -Fq 'mutagen sync flush example-sync' "$log_file" || fail 'launcher did not flush the Mutagen session'
grep -Fq 'herdr --remote example-host --session example-session' "$log_file" || fail 'launcher did not fall back to remote Herdr bootstrap'
if grep -Fq 'legacy-config-session' "$log_file"; then
  fail 'default config implicitly selected its legacy Herdr session'
fi

: >"$log_file"
if HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  HREMOTE_TEST_PROJECT="$project_dir" HREMOTE_TEST_SESSION=mismatch \
  HREMOTE_CONFIG="$config_file" "$bin_dir/hremote" --session example-session >/dev/null 2>&1; then
  fail 'launcher accepted a same-named Mutagen session with different endpoints'
fi
if grep -Fq 'mutagen sync resume' "$log_file"; then
  fail 'launcher resumed a mismatched Mutagen session'
fi

: >"$log_file"
if ! HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  HREMOTE_TEST_PROJECT="$project_dir" HREMOTE_TEST_SESSION=match \
  HREMOTE_TEST_HERDR_INSTALLED=1 HREMOTE_FAKE_STATE="$TEST_ROOT/state" \
  HREMOTE_CONFIG="$config_file" "$bin_dir/hremote" \
  --session example-session --setup-only >"$TEST_ROOT/matching-session.out" 2>&1; then
  sed -n '1,120p' "$TEST_ROOT/matching-session.out" >&2
  fail 'launcher failed while resuming a matching Mutagen session'
fi
grep -Fq 'mutagen sync resume example-sync' "$log_file" || fail 'launcher did not resume a matching Mutagen session'
grep -Fq 'status server --json' "$log_file" || fail 'launcher did not inspect structured server status'
grep -Fq 'pane list --workspace w1' "$log_file" || fail 'launcher did not verify workspace cwd'
if grep -Fq 'herdr --remote' "$log_file"; then
  fail 'setup-only mode opened the Herdr client'
fi
if grep -Fq 'mutagen sync create' "$log_file"; then
  fail 'launcher recreated a matching Mutagen session'
fi

printf 'Behavior tests passed.\n'
