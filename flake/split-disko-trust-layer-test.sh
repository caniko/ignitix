#!/usr/bin/env bash
set -euo pipefail

: "${TRUST_LAYER:?TRUST_LAYER must point to split-disko-trust-layer.sh}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

bin="$work/bin"
state="$work/state"
mkdir -p "$bin" "$state"

{
printf '#!%s\n' "$(command -v bash)"
cat <<'EOF'
set -euo pipefail

cmd="${@: -1}"
printf 'ssh\t%s\n' "$cmd" >>"$STATE/calls.log"

lookup() {
  local file=$1
  local key=$2
  awk -F '\t' -v key="$key" '$1 == key { print $2; found = 1; exit } END { exit !found }' "$STATE/$file"
}

set_actual() {
  local path=$1
  local value=$2
  local tmp="$STATE/actual.tmp"
  awk -F '\t' -v path="$path" -v value="$value" '
    BEGIN { OFS = FS }
    $1 == path { print path, value; done = 1; next }
    { print }
    END { if (!done) print path, value }
  ' "$STATE/actual" >"$tmp"
  mv "$tmp" "$STATE/actual"
}

case "$cmd" in
  "nix-store -qR "*)
    cat "$STATE/closure"
    ;;
  "nix-hash --type sha256 --base32 "*)
    path="${cmd#nix-hash --type sha256 --base32 }"
    lookup actual "$path"
    ;;
  "nix-store -q --deriver "*)
    rest="${cmd#nix-store -q --deriver }"
    path="${rest%% *}"
    lookup deriver "$path" || true
    ;;
  "nix-store --repair-path "*)
    path="${cmd#nix-store --repair-path }"
    printf '%s\n' "$path" >>"$STATE/repairs.log"
    if [[ -f "$STATE/repair-fail" ]]; then
      exit 1
    fi
    if value=$(lookup repair "$path"); then
      set_actual "$path" "$value"
    fi
    ;;
  *)
    echo "unexpected ssh command: $cmd" >&2
    exit 97
    ;;
esac
EOF
} >"$bin/ssh"

{
printf '#!%s\n' "$(command -v bash)"
cat <<'EOF'
set -euo pipefail

printf 'nix\t%s\n' "$*" >>"$STATE/calls.log"

lookup() {
  local file=$1
  local key=$2
  awk -F '\t' -v key="$key" '$1 == key { print $2; found = 1; exit } END { exit !found }' "$STATE/$file"
}

if [[ "$1" == "path-info" ]]; then
  path="${@: -1}"
  nar_hash=$(lookup registered "$path")
  printf '{"%s":{"narHash":%s}}\n' "$path" "$nar_hash"
  exit 0
fi

if [[ "$1" == "hash" && "$2" == "convert" ]]; then
  sri="${@: -1}"
  lookup conversions "$sri"
  exit 0
fi

echo "unexpected nix command: $*" >&2
exit 98
EOF
} >"$bin/nix"

chmod +x "$bin/ssh" "$bin/nix"

export PATH="$bin:$PATH"
export STATE="$state"
source "$TRUST_LAYER"

target_host=fake-installer
target_port=22
installer_ssh_args=(-T -p "$target_port")
ssh_opts=""
remote_store_uri="ssh-ng://fake-installer?compress=true"

reset_state() {
  rm -rf "$state"
  mkdir -p "$state"
  : >"$state/registered"
  : >"$state/conversions"
  : >"$state/actual"
  : >"$state/deriver"
  : >"$state/repair"
  : >"$state/calls.log"
  : >"$state/repairs.log"
}

put() {
  local file=$1
  local key=$2
  local value=$3
  printf '%s\t%s\n' "$key" "$value" >>"$state/$file"
}

run_verify() {
  local name=$1
  set +e
  (verify_or_repair_remote_disko_closure /nix/store/root-disko) >"$state/$name.out" 2>"$state/$name.err"
  local status=$?
  set -e
  printf '%s\n' "$status" >"$state/$name.status"
  return 0
}

status_of() {
  cat "$state/$1.status"
}

assert_status() {
  local name=$1
  local want=$2
  local got
  got=$(status_of "$name")
  if [[ "$got" != "$want" ]]; then
    echo "$name: expected status $want, got $got" >&2
    cat "$state/$name.out" >&2 || true
    cat "$state/$name.err" >&2 || true
    exit 1
  fi
}

assert_no_repair() {
  if [[ -s "$state/repairs.log" ]]; then
    echo "unexpected repair(s):" >&2
    cat "$state/repairs.log" >&2
    exit 1
  fi
}

assert_repairs() {
  local expected=$1
  local actual
  actual=$(sort "$state/repairs.log" | tr '\n' ' ')
  if [[ "$actual" != "$expected" ]]; then
    echo "expected repairs '$expected', got '$actual'" >&2
    cat "$state/calls.log" >&2
    exit 1
  fi
}

assert_file_contains() {
  local file=$1
  local needle=$2
  if ! grep -F "$needle" "$file" >/dev/null; then
    echo "missing '$needle' in $file" >&2
    cat "$file" >&2 || true
    exit 1
  fi
}

assert_file_lacks() {
  local file=$1
  local needle=$2
  if grep -F "$needle" "$file" >/dev/null; then
    echo "unexpected '$needle' in $file" >&2
    cat "$file" >&2 || true
    exit 1
  fi
}

seed_common_hashes() {
  put conversions sha256-good good
  put conversions sha256-expected expected
  put conversions sha256-expected2 expected2
  put conversions sha256-root root
}

reset_state
seed_common_hashes
printf '%s\n' /nix/store/root-disko /nix/store/good-dep >"$state/closure"
put registered /nix/store/root-disko '"sha256-root"'
put registered /nix/store/good-dep '"sha256-good"'
put actual /nix/store/root-disko root
put actual /nix/store/good-dep good
run_verify clean
assert_status clean 0
assert_no_repair

reset_state
seed_common_hashes
printf '%s\n' /nix/store/root-disko /nix/store/bad-dep >"$state/closure"
put registered /nix/store/root-disko '"sha256-root"'
put registered /nix/store/bad-dep '"sha256-expected"'
put actual /nix/store/root-disko root
put actual /nix/store/bad-dep actual
put deriver /nix/store/bad-dep /nix/store/bad-dep.drv
put repair /nix/store/bad-dep expected
run_verify corrupt_repaired
assert_status corrupt_repaired 0
assert_repairs '/nix/store/bad-dep '
assert_file_contains "$state/corrupt_repaired.err" 'registered NAR hash: expected'
assert_file_contains "$state/corrupt_repaired.err" 'actual:    actual'
grep -F 'nix-store -qR /nix/store/root-disko' "$state/calls.log" | wc -l | grep -x 2 >/dev/null

reset_state
seed_common_hashes
printf '%s\n' /nix/store/root-disko /nix/store/bad-dep >"$state/closure"
put registered /nix/store/root-disko '"sha256-root"'
put registered /nix/store/bad-dep '"sha256-expected"'
put actual /nix/store/root-disko root
put actual /nix/store/bad-dep actual
run_verify repair_does_not_blindly_accept_actual
assert_status repair_does_not_blindly_accept_actual 1
assert_repairs '/nix/store/bad-dep '
assert_file_contains "$state/repair_does_not_blindly_accept_actual.err" 'registered NAR hash: expected'
assert_file_contains "$state/repair_does_not_blindly_accept_actual.err" 'actual:    actual'
assert_file_lacks "$state/repair_does_not_blindly_accept_actual.err" 'registered NAR hash: actual'

reset_state
seed_common_hashes
printf '%s\n' /nix/store/root-disko /nix/store/missing-hash >"$state/closure"
put registered /nix/store/root-disko '"sha256-root"'
put registered /nix/store/missing-hash null
put actual /nix/store/root-disko root
put actual /nix/store/missing-hash observed
run_verify missing_trusted_hash
assert_status missing_trusted_hash 1
assert_no_repair
assert_file_contains "$state/missing_trusted_hash.err" 'Refusing to derive expected hash from actual path contents.'
assert_file_lacks "$state/calls.log" 'nix-hash --type sha256 --base32 /nix/store/missing-hash'

reset_state
seed_common_hashes
printf '%s\n' /nix/store/root-disko /nix/store/good-dep /nix/store/bad-one /nix/store/bad-two >"$state/closure"
put registered /nix/store/root-disko '"sha256-root"'
put registered /nix/store/good-dep '"sha256-good"'
put registered /nix/store/bad-one '"sha256-expected"'
put registered /nix/store/bad-two '"sha256-expected2"'
put actual /nix/store/root-disko root
put actual /nix/store/good-dep good
put actual /nix/store/bad-one actual-one
put actual /nix/store/bad-two actual-two
put repair /nix/store/bad-one expected
put repair /nix/store/bad-two expected2
run_verify multiple_mismatches
assert_status multiple_mismatches 0
assert_repairs '/nix/store/bad-one /nix/store/bad-two '
assert_file_lacks "$state/repairs.log" '/nix/store/good-dep'

reset_state
seed_common_hashes
printf '%s\n' /nix/store/root-disko /nix/store/bad-dep >"$state/closure"
put registered /nix/store/root-disko '"sha256-root"'
put registered /nix/store/bad-dep '"sha256-expected"'
put actual /nix/store/root-disko root
put actual /nix/store/bad-dep actual
copy_after_verify() {
  verify_or_repair_remote_disko_closure /nix/store/root-disko
  printf 'copy\n' >>"$state/calls.log"
}
set +e
(copy_after_verify) >"$state/copy_gate.out" 2>"$state/copy_gate.err"
copy_gate_status=$?
set -e
if [[ "$copy_gate_status" == 0 ]]; then
  echo "copy gate unexpectedly succeeded" >&2
  exit 1
fi
assert_file_lacks "$state/calls.log" 'copy'

touch "$out"
