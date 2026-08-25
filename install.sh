#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_BIN_DIR=${HOME:+"$HOME/.local/bin"}
DEFAULT_CONFIG_DIR=${XDG_CONFIG_HOME:-${HOME:+"$HOME/.config"}}/hremote
DEFAULT_CONFIG_FILE=$DEFAULT_CONFIG_DIR/config

LOCAL_PATH=
SSH_TARGET=
REMOTE_PATH=
SYNC_NAME=
BIN_DIR=$DEFAULT_BIN_DIR
CONFIG_FILE=$DEFAULT_CONFIG_FILE
CONFIG_FILE_EXPLICIT=false
PROFILE=
DRY_RUN=false
FORCE=false
IGNORE_PATHS=(.DS_Store .venv .tmpbin)
REMOTE_SYMLINKS=()

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Required:
  --local-path PATH       Absolute path to the local project
  --ssh-target TARGET     OpenSSH host or alias
  --remote-path PATH      Absolute remote path or a path beginning with ~/
  --sync-name NAME        Mutagen synchronization name

Optional:
  --ignore PATH           Add a Mutagen ignore path (repeatable)
  --remote-symlink A=B    Ensure remote-root/A points to relative target B
  --bin-dir DIR           Launcher destination (default: ~/.local/bin)
  --config-file FILE      Generated config path
  --profile NAME          Write profiles/NAME.conf unless --config-file is set
  --dry-run               Validate and print the planned local changes only
  --force                 Replace an existing managed launcher or config
  --help                  Show this help

The installer never creates a Mutagen session or remote directory. Those
actions occur on the first non-dry-run hremote invocation.
EOF
}

die() {
  printf 'install: %s\n' "$*" >&2
  exit 1
}

require_value() {
  [[ $# -ge 2 && -n $2 ]] || die "$1 requires a value"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --local-path)
      require_value "$@"
      LOCAL_PATH=$2
      shift 2
      ;;
    --ssh-target)
      require_value "$@"
      SSH_TARGET=$2
      shift 2
      ;;
    --remote-path)
      require_value "$@"
      REMOTE_PATH=$2
      shift 2
      ;;
    --sync-name)
      require_value "$@"
      SYNC_NAME=$2
      shift 2
      ;;
    --ignore)
      require_value "$@"
      IGNORE_PATHS+=("$2")
      shift 2
      ;;
    --remote-symlink)
      require_value "$@"
      REMOTE_SYMLINKS+=("$2")
      shift 2
      ;;
    --bin-dir)
      require_value "$@"
      BIN_DIR=$2
      shift 2
      ;;
    --config-file)
      require_value "$@"
      CONFIG_FILE=$2
      CONFIG_FILE_EXPLICIT=true
      shift 2
      ;;
    --profile)
      require_value "$@"
      PROFILE=$2
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ -n $LOCAL_PATH ]] || die '--local-path is required'
[[ -n $SSH_TARGET ]] || die '--ssh-target is required'
[[ -n $REMOTE_PATH ]] || die '--remote-path is required'
[[ -n $SYNC_NAME ]] || die '--sync-name is required'

[[ $LOCAL_PATH == /* ]] || die '--local-path must be absolute'
[[ -d $LOCAL_PATH ]] || die '--local-path must name an existing directory'
[[ $SSH_TARGET =~ ^([A-Za-z0-9._-]+@)?[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'invalid --ssh-target'
[[ $REMOTE_PATH =~ ^(~\/|\/)[A-Za-z0-9._\/-]+$ ]] || die 'invalid --remote-path'
[[ $SYNC_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'invalid --sync-name'
[[ -z $PROFILE || $PROFILE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'invalid --profile'
[[ $BIN_DIR == /* ]] || die '--bin-dir must be absolute'

if [[ -n $PROFILE && $CONFIG_FILE_EXPLICIT != true ]]; then
  CONFIG_FILE=$DEFAULT_CONFIG_DIR/profiles/$PROFILE.conf
fi
[[ $CONFIG_FILE == /* ]] || die '--config-file must be absolute'

remote_path_tail=${REMOTE_PATH#~/}
remote_path_tail=${remote_path_tail#/}
IFS=/ read -r -a remote_path_parts <<<"$remote_path_tail"
for part in "${remote_path_parts[@]}"; do
  [[ -n $part && $part != . && $part != .. ]] || die 'invalid --remote-path component'
done

for command_name in ssh mutagen herdr python3; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

for mapping in "${REMOTE_SYMLINKS[@]-}"; do
  [[ -n $mapping ]] || continue
  [[ $mapping == *=* ]] || die "invalid --remote-symlink (expected A=B): $mapping"
  link_path=${mapping%%=*}
  link_target=${mapping#*=}
  [[ $link_path =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || die "invalid remote symlink path: $link_path"
  [[ $link_target =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+|/\.\.|/\.)*$|^(\.\.?/)+[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || die "invalid remote symlink target: $link_target"

  IFS=/ read -r -a link_parts <<<"$link_path"
  for part in "${link_parts[@]}"; do
    [[ $part != . && $part != .. ]] || die "invalid remote symlink path: $link_path"
  done
  depth=$((${#link_parts[@]} - 1))
  IFS=/ read -r -a target_parts <<<"$link_target"
  for part in "${target_parts[@]}"; do
    case $part in
      .) ;;
      ..)
        (( depth > 0 )) || die "remote symlink target escapes the project root: $mapping"
        (( depth -= 1 )) || true
        ;;
      *) (( depth += 1 )) || true ;;
    esac
  done

  mapping_is_ignored=false
  for ignore_path in "${IGNORE_PATHS[@]-}"; do
    [[ ${ignore_path#/} == "$link_path" ]] && mapping_is_ignored=true
  done
  [[ $mapping_is_ignored == true ]] || die "remote symlink path must also be ignored: $link_path"
done

quote_config_value() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

render_config() {
  printf '# Generated by herdr-remote-workspace. Do not commit this file.\n'
  printf 'LOCAL_PATH='
  quote_config_value "$LOCAL_PATH"
  printf '\nSSH_TARGET='
  quote_config_value "$SSH_TARGET"
  printf '\nREMOTE_PATH='
  quote_config_value "$REMOTE_PATH"
  printf '\nSYNC_NAME='
  quote_config_value "$SYNC_NAME"
  printf '\n'
  printf 'IGNORE_PATHS=('
  for ignore_path in "${IGNORE_PATHS[@]-}"; do
    if [[ -n $ignore_path ]]; then
      printf ' '
      quote_config_value "$ignore_path"
    fi
  done
  printf ' )\n'
  printf 'REMOTE_SYMLINKS=('
  for mapping in "${REMOTE_SYMLINKS[@]-}"; do
    if [[ -n $mapping ]]; then
      printf ' '
      quote_config_value "$mapping"
    fi
  done
  printf ' )\n'
}

launcher_target=$BIN_DIR/hremote

if [[ $DRY_RUN == true ]]; then
  printf 'Configuration is valid.\n'
  printf 'Would verify key-only SSH access, then install:\n'
  printf '  launcher: %s\n' "$launcher_target"
  printf '  config:   %s\n' "$CONFIG_FILE"
  printf 'No files, synchronization sessions, or remote objects were changed.\n'
  exit 0
fi

install_launcher=true
if [[ -e $launcher_target || -L $launcher_target ]]; then
  if [[ $FORCE == true ]]; then
    :
  elif [[ -f $launcher_target && ! -L $launcher_target && -x $launcher_target ]] \
    && cmp -s "$SCRIPT_DIR/bin/hremote" "$launcher_target"; then
    install_launcher=false
  else
    die "a different launcher already exists: $launcher_target (use --force to replace)"
  fi
fi

if [[ $FORCE != true && ( -e $CONFIG_FILE || -L $CONFIG_FILE ) ]]; then
  die "config already exists: $CONFIG_FILE (use --force to replace)"
fi

ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" true >/dev/null \
  || die 'key-only SSH validation failed'

mkdir -p "$BIN_DIR" "$(dirname "$CONFIG_FILE")"
config_tmp=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")
trap 'rm -f "$config_tmp"' EXIT
render_config >"$config_tmp"
chmod 600 "$config_tmp"
mv -f "$config_tmp" "$CONFIG_FILE"
trap - EXIT

if [[ $install_launcher == true ]]; then
  install -m 755 "$SCRIPT_DIR/bin/hremote" "$launcher_target"
fi

printf 'Installed hremote.\n'
printf '  launcher: %s\n' "$launcher_target"
printf '  config:   %s\n' "$CONFIG_FILE"
printf 'Run hremote --session NAME --dry-run, then hremote --session NAME.\n'
