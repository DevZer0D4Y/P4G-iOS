#!/bin/sh
# Refuses a commit (or a release) that would include game files, keys or code generated from the game.
# Installed as .git/hooks/pre-commit by tools/install_hooks.sh; run it by hand with --all before a push or a release.
# Output names only the offending paths, never file contents.

if [ "$1" = "--all" ]; then
    files=$(git ls-files)
else
    files=$(git diff --cached --name-only --diff-filter=ACMR)
fi
[ -z "$files" ] && exit 0

bad=0
say() { echo "check_private: $1: $2" >&2; bad=1; }

for f in $files; do
    [ -f "$f" ] || continue
    case "$f" in
        *.keys|*.key|*.tik|*.cert|*.p12|*.cer|*.mobileprovision) say "$f" "key or signing file" ;;
        *.nsp|*.nsz|*.xci|*.xcz|*.nca|*.ncz|*.nso|*.nro|*.npdm|*.cpk|*.usm|*.acb|*.awb|*.ipa) say "$f" "game or app binary" ;;
        generated/*|generated-*/*|*/generated/*|exefs/*|*/exefs/*|romfs/*|*/romfs/*) say "$f" "game-derived path" ;;
    esac
    # magic numbers of Switch containers and executables
    magic=$(head -c 4 "$f" 2>/dev/null)
    case "$magic" in
        PFS0|HFS0|NSO0|NRO0|NCA3|META|CPK*) say "$f" "Switch container or executable ($magic)" ;;
    esac
    # key files: lines like "header_key = <64 hex>" or a rights ID followed by a 32-hex title key
    if grep -IqE '^[[:space:]]*[a-z_0-9]+_key(_[0-9a-f]{2})?[[:space:]]*=[[:space:]]*[0-9a-fA-F]{32,}' "$f" 2>/dev/null \
       || grep -IqE '^[[:space:]]*[0-9a-fA-F]{32}[[:space:]]*=[[:space:]]*[0-9a-fA-F]{32}[[:space:]]*$' "$f" 2>/dev/null; then
        say "$f" "looks like a key file"
    fi
    # large blobs (game data, generated code) do not belong here
    size=$(wc -c < "$f" | tr -d ' ')
    if [ "$size" -gt 5242880 ]; then
        say "$f" "larger than 5 MB ($size bytes)"
    fi
done

if [ $bad -ne 0 ]; then
    echo "check_private: refused; move these out of the repository (game files and keys stay in the work folder)" >&2
    exit 1
fi
exit 0
