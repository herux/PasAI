#!/bin/sh
# Compile every example with Free Pascal. (For Delphi on Windows: build-delphi.bat)
# Output: bin/<program-name>; compiled units go to lib/
# Units shared by several examples live in examples/common/
#
# Compiler selection:
#   - FPC=/path/to/compiler ./build.sh   overrides automatic detection
#   - otherwise, use the project developer's FPC 3.2.4 fpcupdeluxe wrapper
#   - otherwise, use an fpc.sh wrapper next to an fpc in PATH
#   - otherwise, use plain fpc
set -e
cd "$(dirname "$0")"

if [ -z "$FPC" ]; then
  FPC_324="$HOME/fpcupdeluxe324/fpc/bin/aarch64-darwin/fpc.sh"
  if [ -x "$FPC_324" ]; then
    FPC="$FPC_324"
  else
    FPC=fpc
    FPC_PATH=$(command -v fpc 2>/dev/null || true)
    if [ -n "$FPC_PATH" ] && [ -x "$(dirname "$FPC_PATH")/fpc.sh" ]; then
      FPC="$(dirname "$FPC_PATH")/fpc.sh"
    fi
  fi
fi
echo "Using compiler: $FPC"

mkdir -p lib bin
for f in examples/*/*.dpr; do
  echo "== $f"
  "$FPC" -Mdelphi -Fusrc -Fuexamples/common -FUlib -FEbin "$f"
done
