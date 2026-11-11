# ShelfTechUI

A complete retro-tech interface for KOReader, with **Bookshelf**, **Glimpse** and **Bookdrop** built in.

ShelfTechUI is a fork of AndyHazz's Bookshelf home screen

## What's in it

| | Where | What |
|---|---|---|
| **Home** | KOReader's file browser | Bookshelf's home: hero card, chips, shelves — on line shelves, square covers on hard shadows, retro footer keys. Edge swipes: left = brightness, right = warmth, diagonal = full refresh |
| **For you** | Home shelf | Because you read…, Up next in series, Pick back up, More by authors you finish, your top genres, Discover, Want to read — from your own library (Bookshelf shelf sources) |
| **Book page** | Hold a book, or BOOK in a book | Stars, status, description, genres, the series, Similar / More by the author / Online, ‹ › to the books beside it; Bookshelf's own window under ⋯ |
| **Series & author pages** | From a book page | A completion ruler, Up next with your time to read it, every book (and, with online picks, the ones you don't have) |
| **Library** | Start menu | Search, sort, filter, A–Z, select several to set status or add to a collection |
| **Online picks** (opt-in) | Settings → For you | From Open Library, Wi-Fi only, once a day: missing from your series, more by your authors, popular in your genres; FIND hands off to Bookdrop; + WANT |
| **Store** | First shelf in FOR YOU | Bookdrop, built in: its home, search, categories and manga reader as tiles. The manga reader downloads its runtime (about 25 MB) the first time you open it |
| **Transfer** | Quick Settings tile, start menu, Settings → Connect | Send books from a browser on the same Wi-Fi (the File Browser server; takes over from FilebrowserPlus, with its settings and password). Opening it turns it on and shows a QR code; folder, timer, password and port are on the same page |
| **Reading summary** | Swipe down on home | Today, plus an **Insights** page: 26 weeks day by day, the year's goal, when you'll finish, when you read, records |
| **Reading toolbar** | Tap the page | Home and Search keys, the book card (cover, chapter, progress, when you'll finish, bookmark key), Also reading; a track with chapter ticks; CONTENTS · NOTEBOOK · PAGES; GLIMPSE · PIN · STATS, each with a figure under its name: the pictures you've passed of those in the book, how many pages are pinned, and a reading figure that changes each time (streak, today, this week, time left in the chapter, pages an hour, books this year) |
| **Glimpse** | GLIMPSE on the toolbar | Erik Fanki's viewer for the maps, family trees and other pictures in the book, from anywhere in it, without losing your place; in the retro look. Settings → Glimpse |
| **Notebook** | Toolbar | Bookmarks, highlights and notes as cards, with All / Highlights / Notes / Marks |
| **Pages** | Toolbar, or KOReader's skim bar | The carousel (the page, its neighbours, a track with chapter ticks) or a grid of thumbnails |
| **Home layouts** | Settings → Home → Home layout, or the Layout chip | **Shelf** (Bookshelf's home), **Read** (a row for each shelf, Continue reading first; swipe a row sideways, tap its name for all of it) or **Dash** (now reading, streak, this week, up next in series, a pick, and one row of covers) |
| **Highlight handles** | Select text | A knob at each end of the selection to drag |
| **Pinned pages** | PIN on the toolbar, or PIN PAGE on a selection | A badge on the page opens a drawer with your pins |
| **Quick Settings** | Swipe down in a book | Tiles (X-Ray when it's installed), the Wi-Fi network name, light sliders |
| **Text sheet (Aa)** | Swipe up, or the menu | KOReader's text options as a sheet |
| **Themes** | Settings → Themes | Seven looks for the whole interface: Retro, Modern, Fantasy, Sci-fi, Rustic, Parchment, Book (frames, shadows, type, tracks, handles, shelves), across ShelfTechUI's screens, Bookshelf's home, the restyled KOReader screens (text sheet, dictionary, search, dialogs, lists), Glimpse and the store. KOReader restarts to apply one. The book's own page keeps your reading font |
| **Settings app** | ⚙, start menu, the pull-down | One app, by what things are for: HOME · READING · LOOK · CONNECT · DEVICE · TOOLS · SYSTEM. KOReader's and Bookshelf's own menus are folded into the section they belong to, each row with a line of explanation |

## Install

**Updates** come from inside ShelfTechUI: Settings → System → Updates checks this repository's releases (once a day on Wi-Fi, or when you tap Check for updates), shows what's new, installs, and keeps the previous version so you can go back. Storefront can also install and update it (search for *shelftechui*).

**By hand:**

1. **Delete** `bookshelf.koplugin` and `bookshelfos.koplugin` from `koreader/plugins` (ShelfTechUI includes both; with them still there it only asks you to remove them). Delete `glimpse.koplugin`, `bookdrop.koplugin` and `filebrowserplus.koplugin` too: all three are built in now (start ShelfTechUI once before deleting FilebrowserPlus, so its password is taken over). Also delete the older `shortcutstoolbar`, `kobotoolbar` and `settingshub` plugins if you still have them.
2. Download `shelftechui.koplugin.zip` from the [latest release](https://github.com/Taiminator-OPDS/shelftechui.koplugin/releases/latest) and unzip it into `koreader/plugins` (you get `koreader/plugins/shelftechui.koplugin`).
3. Restart KOReader.

Your Bookshelf settings (shelves, chips, start menu, themes) and your Bookshelf OS settings carry over.

## Credits

- **Bookshelf** by AndyHazz — AGPL-3.0, included in full (`bookshelf_main.lua`, `lib/`, `micromodules/`, `assets/`, `fonts/`, `locale/`). ShelfTechUI changes: the retro look is applied at run time by `stui_retro.lua`; Bookshelf's self-updater is switched off (it would install stock Bookshelf beside ShelfTechUI).
- **Glimpse** by Erik Fanki — AGPL-3.0, included (`glimpse/`), restyled in the retro look; its self-updater is removed (it would replace the bundled copy with stock Glimpse).
- **Bookdrop** — AGPL-3.0, included (`bookdrop/`, see `bookdrop/NOTICE`): its Z-Library client is ported from zlibrary.koplugin (AGPL-3.0), and its manga reader is RakuYomi (AGPL-3.0, `bookdrop/manga/`), whose per-device runtime is downloaded on first use rather than shipped.
- **Transfer** — takes over from **FilebrowserPlus** by Neeraj Patel (derived from KOReader's filebrowser.koplugin, AGPL-3.0) and runs the **File Browser** server (Apache-2.0, `transfer/NOTICE`). The bundled server is for 32-bit ARM e-readers (Kobo, Kindle, PocketBook).
- **Kobo-style toolbar** by Lina (nessnos) — MIT, see `THIRD_PARTY_NOTICES.md`.
- Inspired by **Shortcuts Toolbar** (xusoo) and **KoboUI** (nessnos), and by ideas from **Aleph** (BookOrbit): ShelfTechUI's versions are its own, written from the ideas; no Aleph code is used.
- Theme fonts: **Cinzel**, **EB Garamond**, **Share Tech Mono**, **Orbitron**, **Zilla Slab**, **IM Fell English**, **Cormorant SC**, **Libre Caslon Text**: SIL OFL 1.1, see `fonts/CREDITS.md` and `fonts/OFL-themes.txt`.
- Online picks use the **Open Library** API (openlibrary.org, Internet Archive); covers from covers.openlibrary.org.

ShelfTechUI is released under AGPL-3.0 (`LICENSE`). Unofficial; not affiliated with AndyHazz, Erik Fanki, KOReader, Kobo or Amazon.
