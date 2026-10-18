# Minecraft modpack server manager - updates

This repository is the update channel for the Minecraft modpack server manager.
Installed copies download `version.json` and the files in `program/` from here when they start,
check every file against its SHA-256 hash, and only then replace their program files.

It contains program files only. No servers, worlds, keys or personal data are ever published here.

`join.html` is the friend invite page, served by GitHub Pages (Settings → Pages → Deploy from branch `main`, folder `/ (root)`).
The invite code travels after `#` in the link, so it never reaches GitHub or any other server; the page decodes it in the browser.