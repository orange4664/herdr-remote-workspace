#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hremote-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'test: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack=$1
  local needle=$2
  [[ $haystack == *"$needle"* ]] || fail "expected output to contain: $needle"
}

project_dir=$TEST_ROOT/project
home_dir=$TEST_ROOT/home
stub_dir=$TEST_ROOT/stubs
bin_dir=$home_dir/bin
config_file=$home_dir/config/hremote.conf
log_file=$TEST_ROOT/commands.log
mkdir -p "$project_dir" "$stub_dir" "$home_dir" "$TEST_ROOT/state"

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

help_output=$(HOME="$home_dir" PATH="$TEST_PATH" "$ROOT/install.sh" --help)
assert_contains "$help_output" '--local-path'

if HOME="$home_dir" PATH="$TEST_PATH" "$ROOT/install.sh" --dry-run >/dev/null 2>&1; then
  fail 'installer accepted missing required arguments'
fi

dry_output=$(HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  "$ROOT/install.sh" \
  --local-path "$project_dir" \
  --ssh-target example-host \
  --remote-path "$remote_path" \
  --sync-name example-sync \
  --session-name example-session \
  --bin-dir "$bin_dir" \
  --config-file "$config_file" \
  --dry-run)
assert_contains "$dry_output" 'No files, synchronization sessions, or remote objects were changed.'
[[ ! -e $config_file && ! -e $bin_dir/hremote ]] || fail 'dry-run wrote installation files'
[[ ! -e $log_file ]] || fail 'dry-run executed an external command'

HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  "$ROOT/install.sh" \
  --local-path "$project_dir" \
  --ssh-target example-host \
  --remote-path "$remote_path" \
  --sync-name example-sync \
  --session-name example-session \
  --ignore build-cache \
  --ignore docs/current \
  --remote-symlink docs/current=../shared \
  --bin-dir "$bin_dir" \
  --config-file "$config_file" >/dev/null

[[ -x $bin_dir/hremote ]] || fail 'launcher was not installed executable'
[[ -f $config_file ]] || fail 'config was not generated'
config_mode=$(stat -f '%Lp' "$config_file" 2>/dev/null || stat -c '%a' "$config_file")
[[ $config_mode == 600 ]] || fail "config mode is $config_mode, expected 600"
grep -Fq "SSH_TARGET='example-host'" "$config_file" || fail 'SSH target was not rendered'
grep -Fq "REMOTE_PATH='~/work/example'" "$config_file" || fail 'remote path did not round-trip literally'
grep -Fq 'REMOTE_SYMLINKS=(' "$config_file" || fail 'remote symlink config was not rendered'

if HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  "$ROOT/install.sh" \
  --local-path "$project_dir" \
  --ssh-target example-host \
  --remote-path "$remote_path" \
  --sync-name example-sync \
  --session-name example-session \
  --bin-dir "$bin_dir" \
  --config-file "$config_file" >/dev/null 2>&1; then
  fail 'installer overwrote existing files without --force'
fi

: >"$log_file"
launcher_dry_output=$(HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  HREMOTE_CONFIG="$config_file" "$bin_dir/hremote" --dry-run)
assert_contains "$launcher_dry_output" 'Configuration and local dependencies are valid.'
[[ ! -s $log_file ]] || fail 'launcher dry-run executed an external command'

: >"$log_file"
if ! HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  HREMOTE_TEST_PROJECT="$project_dir" HREMOTE_CONFIG="$config_file" \
  "$bin_dir/hremote" >"$TEST_ROOT/missing-session.out" 2>&1; then
  sed -n '1,120p' "$TEST_ROOT/missing-session.out" >&2
  fail 'launcher failed while creating a missing Mutagen session'
fi
grep -Fq 'mutagen sync create' "$log_file" || fail 'launcher did not create a missing Mutagen session'
grep -Fq 'mutagen sync flush example-sync' "$log_file" || fail 'launcher did not flush the Mutagen session'
grep -Fq 'herdr --remote example-host --session example-session' "$log_file" || fail 'launcher did not fall back to remote Herdr bootstrap'

: >"$log_file"
if HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  HREMOTE_TEST_PROJECT="$project_dir" HREMOTE_TEST_SESSION=mismatch \
  HREMOTE_CONFIG="$config_file" "$bin_dir/hremote" >/dev/null 2>&1; then
  fail 'launcher accepted a same-named Mutagen session with different endpoints'
fi
if grep -Fq 'mutagen sync resume' "$log_file"; then
  fail 'launcher resumed a mismatched Mutagen session'
fi

: >"$log_file"
if ! HOME="$home_dir" PATH="$TEST_PATH" HREMOTE_TEST_LOG="$log_file" \
  HREMOTE_TEST_PROJECT="$project_dir" HREMOTE_TEST_SESSION=match \
  HREMOTE_TEST_HERDR_INSTALLED=1 HREMOTE_FAKE_STATE="$TEST_ROOT/state" \
  HREMOTE_CONFIG="$config_file" "$bin_dir/hremote" --setup-only >"$TEST_ROOT/matching-session.out" 2>&1; then
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
