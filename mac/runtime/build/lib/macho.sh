# shellcheck shell=bash
# Mach-O helpers: make bundled binaries relocatable and free of build-machine paths.

is_macho() { file -b "$1" 2>/dev/null | grep -q 'Mach-O'; }

# relpath_to_lib <file> <runtime_root>  ->  @loader_path-relative path from file's dir to <root>/lib
relpath_to_lib() {
  local f="$1" root="$2" dir rel up
  dir="$(cd "$(dirname "$f")" && pwd)"
  rel="${dir#"$root"}"; rel="${rel#/}"
  up=""
  if [ -n "$rel" ]; then
    up="$(printf '%s' "$rel" | awk -F/ '{for(i=1;i<=NF;i++) printf "../"}')"
  fi
  printf '@loader_path/%slib' "$up"
}

# fix_macho <file> <runtime_root> <build_prefix_to_scrub>
#  - LC_LOAD_DYLIB pointing into the build prefix   -> @rpath/<leaf>
#  - LC_RPATH pointing into the build prefix        -> removed
#  - if the file then uses @rpath, add one @loader_path-relative rpath to <root>/lib
#  - remove any (now invalid) code signature; x86_64 code needs none, and Wine refuses
#    signed unixlibs in the B2 bridge tests (INTERFACES.md §2.1).
fix_macho() {
  local f="$1" root="$2" scrub="$3" ref rp want
  otool -L "$f" | tail -n +2 | awk '{print $1}' | while IFS= read -r ref; do
    case "$ref" in "$scrub"*) install_name_tool -change "$ref" "@rpath/$(basename "$ref")" "$f" ;; esac
  done
  otool -l "$f" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | while IFS= read -r rp; do
    case "$rp" in "$scrub"*) install_name_tool -delete_rpath "$rp" "$f" ;; esac
  done
  if otool -L "$f" | tail -n +2 | grep -q '@rpath/'; then
    want="$(relpath_to_lib "$f" "$root")"
    otool -l "$f" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | grep -qx "$want" \
      || install_name_tool -add_rpath "$want" "$f"
  fi
  if codesign -dv "$f" >/dev/null 2>&1; then codesign --remove-signature "$f"; fi
}

# Fail if any Mach-O under <root> still references <scrub> or a Homebrew/MacPorts path.
assert_no_build_paths() {
  local root="$1" scrub="$2" bad=0 f
  while IFS= read -r f; do
    is_macho "$f" || continue
    if otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -Eq "^($scrub|/usr/local/|/opt/homebrew/|/opt/local/)"; then
      printf 'build path in load commands: %s\n' "$f" >&2; otool -L "$f" >&2; bad=1
    fi
    if otool -l "$f" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | grep -Eq "^($scrub|/usr/local/|/opt/homebrew/|/opt/local/)"; then
      printf 'build path in rpaths: %s\n' "$f" >&2; bad=1
    fi
  done <<EOF
$(find "$root" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \))
EOF
  return "$bad"
}
