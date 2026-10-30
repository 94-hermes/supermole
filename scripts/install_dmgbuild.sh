#!/bin/bash
# Install dmgbuild, pinned by hash in installer/requirements.txt, into a new
# virtual environment, then print the folder to put on PATH so
# scripts/build_installer_dmg.sh finds it.
#
# Usage: scripts/install_dmgbuild.sh <venv-dir>
#   CI:    scripts/install_dmgbuild.sh "$RUNNER_TEMP/dmgbuild" >> "$GITHUB_PATH"
#   Local: PATH="$(scripts/install_dmgbuild.sh ~/.cache/supermole-dmgbuild):$PATH"

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ $# -eq 1 ]] || {
    echo "Usage: $0 <venv-dir>" >&2
    exit 2
}
venv_dir="$1"

# dmgbuild needs Python 3.10; the Command Line Tools python3 is 3.9, where pip
# fails with an unhelpful resolver error.
if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
    echo "dmgbuild needs Python 3.10 or newer; python3 is $(python3 -V 2>&1)" >&2
    exit 1
fi
python3 -m venv "$venv_dir"
"$venv_dir/bin/pip" install --quiet --disable-pip-version-check \
    --require-hashes -r "$PROJECT_ROOT/installer/requirements.txt" >&2
printf '%s\n' "$venv_dir/bin"
