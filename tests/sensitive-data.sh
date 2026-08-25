#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

files=()
while IFS= read -r file; do
  [[ -n $file ]] && files+=("$file")
done < <(git ls-files --cached --others --exclude-standard)

[[ ${#files[@]} -gt 0 ]] || {
  printf 'sensitive-data: no repository files found\n' >&2
  exit 1
}

personal_name='huy''inze'
production_alias='qqpw''-vds'
production_sync='herdr''-rt'
mac_home='/''Users/'
private_key='BEGIN .* PRIVATE ''KEY'
ipv4='(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)'
token='(api[_-]?key|access[_-]?token|client[_-]?secret)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9_./+-]{12,}'

failed=false
for pattern in "$personal_name" "$production_alias" "$production_sync" "$mac_home" "$private_key" "$ipv4" "$token"; do
  if LC_ALL=C grep -EnI "$pattern" "${files[@]}"; then
    failed=true
  fi
done

if [[ $failed == true ]]; then
  printf 'sensitive-data: forbidden sensitive or production-specific value found\n' >&2
  exit 1
fi

printf 'Sensitive-data scan passed.\n'
