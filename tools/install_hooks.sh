#!/bin/sh
# Installs tools/check_private.sh as this clone's pre-commit hook.
root=$(git rev-parse --show-toplevel) || exit 1
mkdir -p "$root/.git/hooks"
printf '#!/bin/sh\nexec "$(git rev-parse --show-toplevel)/tools/check_private.sh"\n' > "$root/.git/hooks/pre-commit"
chmod +x "$root/.git/hooks/pre-commit" "$root/tools/check_private.sh"
echo "pre-commit hook installed"
