#!/bin/sh
# Compile every example with Free Pascal.
# Output: bin/<program-name>; compiled units go to lib/
# Units shared by several examples live in examples/common/
#
# Compiler selection:
#   - FPC=/path/to/compiler ./build.sh   uses that compiler
#   - otherwise, if an fpc.sh wrapper sits next to the fpc in PATH
#     (as created by fpcupdeluxe), it is used so the right fpc.cfg is loaded
#   - otherwise, plain fpc
set -e
cd "$(dirname "$0")"

if [ -z "$FPC" ]; then
  FPC=fpc
  FPC_PATH=$(command -v fpc 2>/dev/null || true)
  if [ -n "$FPC_PATH" ] && [ -x "$(dirname "$FPC_PATH")/fpc.sh" ]; then
    FPC="$(dirname "$FPC_PATH")/fpc.sh"
  fi
fi
echo "Using compiler: $FPC"

mkdir -p lib bin
for f in examples/*/*.lpr; do
  echo "== $f"
  "$FPC" -Mdelphi -Fusrc -Fuexamples/common -FUlib -FEbin "$f"
done
