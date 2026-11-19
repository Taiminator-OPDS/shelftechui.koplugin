# ShelfTechUI

A complete retro-tech interface for KOReader, with **Bookshelf**, **Glimpse** and **Bookdrop** built in.

ShelfTechUI is a fork of AndyHazz's Bookshelf home screen 

## What's in it

| | Where | What |
|---|---|---|
| **Home** | KOReader's file browser | Shelves: hero card, chips, shelves — on line shelves, square covers on hard shadows, retro footer keys. Edge swipes: left = brightness, right = warmth, diagonal = full refresh |
| **For you** | Home shelf | Because you read…, Up next in series, Pick back up, More by authors you finish, your top genres, Discover, Want to read — from your own library (shelf sources) |
| **A book's window** | Hold a book | The book window (description, your review, tags, edit, cover), with a **Recommendations** tab: books from the internet for that one, big covers, "In library" on the ones you have; a tap opens the store on it |
| **Series & author pages** | From the library list (by series, by author) | A completion ruler, Up next with your time to read it, every book (and, with online picks, the ones you don't have) |
| **Library** | Start menu | Search, sort, filter, A–Z, select several to set status or add to a collection |
| **Online picks** (opt-in) | Settings → For you | From Open Library, Wi-Fi only, once a day: missing from your series, more by your authors, popular in your genres; FIND hands off to Bookdrop; + WANT |
| **Store** | First shelf in FOR YOU | Bookdrop, built in: its home, search, categories and manga reader as tiles. The manga reader downloads its runtime (about 25 MB) the first time you open it |
| **Transfer** | Quick Settings tile, start menu, Settings → Connect | Send books from a browser on the same Wi-Fi, and download or delete them: a small web server inside KOReader with a page in ShelfTechUI's look. Opening it turns it on and shows a QR code (scanning it signs the phone in; typed by hand, the address asks for the code on the page); folder, timer, code and port are on the same page |
| **Hardcover** | Toolbar and Quick Settings control, Settings → Connect, the About tab when you hold a book, a start-menu card, covers on home | Opens on a dashboard: your goal, what you're reading, what friends are reading, popular books, genres and moods. Library holds your Reading, Want to read and Read shelves; Explore browses books by genre or mood, as on hardcover.app; the search shows books and readers as you type. Your [hardcover.app](https://hardcover.app) shelves, and the readers you follow: a friends list of who's reading what and how far, each reader's page (reading now, finished lately) and figures. A book of yours that a friend is reading says so on its cover on home ("42% · Ana"). Books on your Reading and Want to read shelves that aren't on the device stand faded at the end of Home: a tap finds them in the store. A book's page has your shelf and rating for it, the friends who have it, the quotes readers liked most, and reviews without spoilers. Books you read on the device are put on your shelves by themselves, with how far along you are and a rating asked at the end; a highlight can be shared as a quote; the device's reading history can be sent in one go. Recommendations (the store, FOR YOU) start with books like the ones you rated highest. Sign in with a link code (needs an app ID from Hardcover) or with an API key pasted through Transfer's page |
| **Insights** | The summary you pull down on home, an action for gestures | Your reading as a dashboard: this device's statistics (the last 26 weeks, goal, forecast, when you read, records) and your Hardcover figures (books, pages, the year month by month, ratings, authors). A list at the top switches to any reader you follow |
| **Reading summary** | Swipe down on home | Today, plus an **Insights** page: 26 weeks day by day, the year's goal, when you'll finish, when you read, records |
| **Reading toolbar** | Tap the page | Home and Search keys, the book card (cover, chapter, progress, when you'll finish, bookmark key), Also reading; a track with chapter ticks; CONTENTS · NOTEBOOK · PAGES; GLIMPSE · PIN · STATS, each with a figure under its name: the pictures you've passed of those in the book, how many pages are pinned, and a reading figure that changes each time (streak, today, this week, time left in the chapter, pages an hour, books this year) |
| **Glimpse** | GLIMPSE on the toolbar | Erik Fanki's viewer for the maps, family trees and other pictures in the book, from anywhere in it, without losing your place; in the retro look. Settings → Glimpse |
| **Notebook** | Toolbar | Bookmarks, highlights and notes as cards, with All / Highlights / Notes / Marks |
| **Pages** | Toolbar, or KOReader's skim bar | The carousel (the page, its neighbours, a track with chapter ticks) or a grid of thumbnails |
| **Home layouts** | Settings → Home (or the Layout chip, if you add it to the home bar) | **Shelf** (shelves, with a search field for your books and the store at its top) or **Dash** (now reading, streak, this week, up next in series, a pick, and one row of covers) |
| **Highlight handles** | Select text | A knob at each end of the selection to drag |
| **Pinned pages** | PIN on the toolbar, or PIN PAGE on a selection | A badge on the page opens a drawer with your pins |
| **Quick Settings** | Swipe down in a book | Tiles (X-Ray when it's installed), the Wi-Fi network name, light sliders |
| **Text sheet (Aa)** | Swipe up, or the menu | KOReader's text options as a sheet |
| **Themes** | Settings → Themes | Six looks for the whole interface: Retro, Modern, Fantasy, Sci-fi, Rustic, Book (frames, shadows, type, tracks, handles, shelves), across ShelfTechUI's screens, home, the restyled KOReader screens (text sheet, dictionary, search, dialogs, lists), Glimpse and the store. KOReader restarts to apply one. The book's own page keeps your reading font |
| **Settings app** | ⚙, start menu, the pull-down | One app laid out like a phone's: a front page with search and the sections (Home · Reading · Look · Connect · Device · Tools · System), each a page of its own, with rows in cards, switches and values. Search finds any setting, ShelfTechUI's or KOReader's, sub-pages too, and opens its page with it marked. KOReader's own menus are folded into the section they belong to, and home's own settings sit in Settings → Home under plain headings (Shelves, Top panel, Covers and text, Library, More), each row with a line of explanation |

## Install

**Updates** come from inside ShelfTechUI: Settings → System → Updates checks this repository's releases (once a day on Wi-Fi, or when you tap Check for ShelfTechUI updates), shows what's new, installs, and keeps the previous version so you can go back. Storefront can also install and update it (search for *shelftechui*).

**By hand:**

1. **Delete** `bookshelf.koplugin` and `bookshelfos.koplugin` from `koreader/plugins` (ShelfTechUI includes both; with them still there it only asks you to remove them). Delete `glimpse.koplugin`, `bookdrop.koplugin` and `filebrowserplus.koplugin` too: all three are built in now (Transfer keeps FilebrowserPlus's folder, port and timer). Also delete the older `shortcutstoolbar`, `kobotoolbar` and `settingshub` plugins if you still have them.
2. Download `shelftechui.koplugin.zip` from the [latest release](https://github.com/Taiminator-OPDS/shelftechui.koplugin/releases/latest) and unzip it into `koreader/plugins` (you get `koreader/plugins/shelftechui.koplugin`).
3. Restart KOReader.

Your Bookshelf settings (shelves, chips, start menu, themes) and your Bookshelf OS settings carry over.

## Credits

- **Bookshelf** by AndyHazz — AGPL-3.0, included in full (`bookshelf_main.lua`, `lib/`, `micromodules/`, `assets/`, `fonts/`, `locale/`). ShelfTechUI changes: the retro look is applied at run time by `stui_retro.lua`; Bookshelf's self-updater is removed (it would install stock Bookshelf beside ShelfTechUI); it's called Home throughout, its settings folded into Settings → Home.
- **Glimpse** by Erik Fanki — AGPL-3.0, included (`glimpse/`), restyled in the retro look; its self-updater is removed (it would replace the bundled copy with stock Glimpse).
- **Bookdrop** — AGPL-3.0, included (`bookdrop/`, see `bookdrop/NOTICE`): its Z-Library client is ported from zlibrary.koplugin (AGPL-3.0), and its manga reader is RakuYomi (AGPL-3.0, `bookdrop/manga/`), whose per-device runtime is downloaded on first use rather than shipped.
- **Transfer** — takes the place of **FilebrowserPlus** by Neeraj Patel (derived from KOReader's filebrowser.koplugin, AGPL-3.0), keeping its settings. Its server is ShelfTechUI's own, in Lua (no File Browser program any more), so it runs on every device KOReader does.
- **Hardcover** — uses [Hardcover](https://hardcover.app)'s public API with your own account. The shape of its requests was checked against Hardcover's published schema and **hardcoverapp.koplugin** by Billiam (MIT); the code is ShelfTechUI's own.
- **Hardcover recommendations** — scored the way **Hardcover Sync** by CaptainCamin (AGPL-3.0, itself built on Billiam's plugin) scores its "For you": a book high in the similar-books lists of several books you rated 4 or more comes first.
- **Kobo-style toolbar** by Lina (nessnos) — MIT, see `THIRD_PARTY_NOTICES.md`.
- Inspired by **Shortcuts Toolbar** (xusoo) and **KoboUI** (nessnos), and by ideas from **Aleph** (BookOrbit): ShelfTechUI's versions are its own, written from the ideas; no Aleph code is used.
- Theme fonts: **Cinzel**, **EB Garamond**, **Share Tech Mono**, **Orbitron**, **Zilla Slab**, **Cormorant SC**, **Libre Caslon Text**: SIL OFL 1.1, see `fonts/CREDITS.md` and `fonts/OFL-themes.txt`.
- Online picks use the **Open Library** API (openlibrary.org, Internet Archive); covers from covers.openlibrary.org.

ShelfTechUI is released under AGPL-3.0 (`LICENSE`). Unofficial; not affiliated with AndyHazz, Erik Fanki, KOReader, Kobo or Amazon.

## Releasing (for the maintainer)

The source of the plugin is `shelftechui.koplugin/`; releases ship a pruned copy (comments stripped, line numbers kept) built by `tools/build.py`.

1. Bump `version` in `shelftechui.koplugin/_meta.lua` (and `Page.VERSION` in `bos_settings_page.lua`); a version like `1.5.0-beta.1` is published as a pre-release. Add a `## <version>` section to `CHANGELOG.md`: it becomes the release notes.
2. Commit, then run `sh tools/publish.sh`. It runs the full local build and checks and pushes `main`.
3. GitHub Actions (`.github/workflows/release.yml`) sees the new version, builds `shelftechui.koplugin.zip` and publishes release `v<version>`. Storefront shows it as an update.
