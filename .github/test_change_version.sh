#!/bin/bash
# Runs change_version.sh in a temp copy with git/curl/gitchangelog stubbed; checks the numbers it writes.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
fail=0
run() { # tag expected_build expected_msix
  local d; d=$(mktemp -d)
  mkdir -p "$d/bin" "$d/windows/packaging/msix" "$d/ios/Runner.xcodeproj"
  printf '#!/bin/sh\necho 200\n' >"$d/bin/curl"
  printf '#!/bin/sh\nexit 0\n' >"$d/bin/git"
  printf '#!/bin/sh\nexit 0\n' >"$d/bin/gitchangelog"
  chmod +x "$d/bin/"*
  echo "version: 4.1.2+40102" >"$d/pubspec.yaml"
  echo "msix_version: 4.1.2.0" >"$d/windows/packaging/msix/make_config.yaml"
  printf 'CURRENT_PROJECT_VERSION = 40102;\nMARKETING_VERSION = 4.1.2;\n' >"$d/ios/Runner.xcodeproj/project.pbxproj"
  (cd "$d" && echo "$1" | PATH="$d/bin:$PATH" bash "$here/change_version.sh" >/dev/null 2>&1)
  local rc=$?
  if [ "$2" = reject ]; then
    [ $rc -ne 0 ] && grep -q '^version: 4.1.2+40102$' "$d/pubspec.yaml" || { echo "FAIL accept $1"; fail=1; }
  else
    grep -q "^version: $2+$3\$" "$d/pubspec.yaml" && grep -q "msix_version: $2.$4\$" "$d/windows/packaging/msix/make_config.yaml" \
      && grep -q "CURRENT_PROJECT_VERSION = $3;" "$d/ios/Runner.xcodeproj/project.pbxproj" || { echo "FAIL $1"; fail=1; }
  fi
  rm -rf "$d"
}
run v4.1.2-derbent.3 4.1.2 4010203 3
run v4.1.2-derbent.1.dev 4.1.2 4010201 1
run v4.1.2-derbent.12 4.1.2 4010212 12
run v4.1.2-derbent.100 reject
run v4.1.2 reject
[ $fail = 0 ] && echo "change_version tests passed"
exit $fail
