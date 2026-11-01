#!/bin/bash
# Opened in Terminal by "Supermole Terminal.app", so the person installing can
# watch the installer and type an administrator password if it needs one. The
# install itself is the fork's one-line installer: install.sh on the main
# branch of the repository below, which install.sh also names (MOLE_REPO_SLUG).
# The app runs a temporary copy of this file (cmd/installer-launcher), which
# removes itself at the end; the file under its own name never does.

set -o pipefail

SUPERMOLE_REPO_SLUG="94-hermes/supermole"
SUPERMOLE_INSTALLER_URL="https://raw.githubusercontent.com/${SUPERMOLE_REPO_SLUG}/main/install.sh"

if [[ -t 1 ]]; then
    clear
fi

if curl -fsSL "$SUPERMOLE_INSTALLER_URL" | bash; then
    install_status=0
    printf '\nTu peux fermer cette fenêtre.\n'
else
    install_status=$?
    printf "\nL'installation n'a pas abouti : les messages ci-dessus disent pourquoi.\n"
    printf 'Rouvre « Supermole Terminal » pour réessayer.\n'
fi

case "${0##*/}" in
    install-supermole-*.command)
        rm -f -- "$0" # SAFE: the launcher's temporary copy, named by commandCopyPattern
        ;;
esac
exit "$install_status"
