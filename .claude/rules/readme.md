---
paths:
  - "README.md"
---

# README

- This fork keeps one README, in English; the translated copies were removed (Airkul, 2026-10-29). Do not add `README_<lang>.md` files back.
- README.md opens with the fork preamble: unofficial fork modified by Airkul, not affiliated with the Mole project (`TRADEMARK.md`), then a short list of what the fork changes, without detail. Keep it first and short, and update the list when the fork gains or drops a user-visible change.
- Sample output and code blocks stay as the CLI prints them. The detailed Analyze, Status, history JSON, and zombie-process paragraphs and the `mo analyze --json` example are kept on purpose as the best demonstration of what Mole reports; do not trim or move them in README cleanups (maintainer, 2026-10-10).
- Quick Start installs this fork with its one-line installer on unpinned `main` (`curl -fsSL https://raw.githubusercontent.com/94-hermes/supermole/main/install.sh | bash`, the repository `MOLE_REPO_SLUG` names) and updates it with `mo update`; the clone install (`make build`, `./install.sh`, updated with `git pull`) lives under Other install options. Never point it at upstream's `install.sh`, Homebrew formula or `llms.txt`, which install upstream Mole over the fork. The distribution line names upstream's official sources as upstream's. README says that the `Trash` whitelist row keeps `~/.Trash` (`.claude/rules/clean.md`).
