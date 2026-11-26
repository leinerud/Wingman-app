# Wingman

A menu bar and Dock companion for GitHub Copilot, made for designers. Not affiliated with or endorsed by GitHub. Shows your Copilot sessions, their status and step progress, and offers quick actions (open Copilot, folder, editor, branch, PRs).

On first launch a welcome screen lets you choose where it lives: the Dock (opens as a window), the menu bar, or both. Change it later in Settings (⌘, or the gear in the popover). There's also a desktop widget (small, medium, large): right-click the desktop → Edit Widgets → Wingman. The app keeps the widget up to date through a shared App Group, so the app needs to be running.

Reads `~/.copilot` read-only. Build with `./Scripts/build-app.sh` or the Xcode project (macOS 15+, signed with the RD223D229Z team; `swift build` still works but has no widget); the app lands in `build/Wingman.app`.

## Review, organise and preview (read-only)

- **Pin, rename and colour-tag** sessions (right-click a card, or the ⋯ menu; double-click a title to rename). Stored on this Mac only. Pins also work from the desktop widget.
- **Review window** (the "Review" chip on a card): *Changes* shows what changed per screen/component in plain words (colour #333 → #000, text size 12 → 13); *Tokens* flags hard-coded colours, text sizes and spacing that aren't in the project's own token/theme files (or the 4-pt grid); *Timeline* lists git versions and shows what each changed; *Preview* shows the project's dev server (auto-detected) at desktop/tablet/phone width, reloads as the session works, and compares a saved "before" against now with a slider.
- Everything reads git read-only. Restoring an older version is a command you copy and run yourself.

## Branches

The **Branches** tab (next to Sessions at the top of the window, or the branch icon in the menu bar panel) lists every repository and branch your Copilot sessions have used, split into *In progress*, *Paused* and *Done · safe to close*, each with a suggested next step. Finished branches can be removed from your Mac with **Clean up**: you review the list first, it only removes what is confirmed merged into GitHub's main unless you tick it, and **Undo** brings them back. Only local copies are removed, never anything on GitHub. If a branch is still open in another workspace, Wingman shows that folder with **Open in GitHub Copilot**, **Show in Finder**, **Open in Terminal** and **Copy path**. Needs git; without it you can copy the commands instead.
