#!/usr/bin/env bash
# Copies the runtime bytecode of the geas registration contracts from a checkout of
# ethereum/sys-asm, which the tests compare the Solidity contracts with.
#
#     contracts/scripts/sync-sys-asm.sh <path to sys-asm>
#
# It reads the committed bytecode of the validator contract (bytecode/pq_registrations/main.hex)
# and of the builder contract (bytecode/pq_builder_registrations/main.hex), and writes them to
# contracts/test/vectors/sys-asm/, along with the commit of that checkout.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <path to sys-asm>" >&2
  exit 1
fi

src=$(cd "$1" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
dest="$here/../test/vectors/sys-asm"

mkdir -p "$dest"
printf '0x%s\n' "$(cat "$src/bytecode/pq_registrations/main.hex")" >"$dest/validator.hex"
printf '0x%s\n' "$(cat "$src/bytecode/pq_builder_registrations/main.hex")" >"$dest/builder.hex"

commit=$(git -C "$src" rev-parse HEAD)
if [[ -n "$(git -C "$src" status --porcelain)" ]]; then
  commit="$commit-dirty"
fi
echo "$commit" >"$dest/COMMIT"
echo "copied the sys-asm runtime bytecode at $commit"
