# The manga reader (RakuYomi, bundled)

This folder is the **RakuYomi** manga plugin
(https://github.com/tachibana-shin/rakuyomi, AGPL-3.0; licence in
`LICENSE-AGPL-3.0`). It is RakuYomi's own code, bundled so you don't install a
second plugin. It opens from the store's ☰ → Manga.

It is kept as close to upstream as possible, so that newer RakuYomi versions
can be copied over it. Prefer changing how ShelfTechUI *uses* it
(`../main.lua`, `Bookdrop:loadBundledManga` / `Bookdrop:openManga`) over editing
files here. Every local change is marked with a `ShelfTechUI:` or `Bookdrop`
comment. Search for those before updating, and carry them over:

- `main.lua`: no entry in KOReader's main menu (the store is the way in);
  `LibraryView` and `MangaReader` are loaded on first use, not at start.
- `gettext+.lua`: translations are found under this folder's new path.
- `RakuyomiShared.lua`: one module loaded when used rather than at start.

## How it works

RakuYomi is in two halves:

1. **A helper program, `server`** (written in Rust, not in this repository).
   It does the actual work: it runs the manga *sources* (the `.aix` files),
   searches them, downloads chapters and packs them as `.cbz` files. It is
   built for each kind of device, so it isn't in the zip. The first time you
   open Manga, `../manga_downloader.lua` downloads the right one (about 25 MB)
   from RakuYomi's GitHub releases into this folder, alongside
   `cbz_metadata_reader`.
2. **This Lua code**, the screens. It starts the server in the background and
   talks to it over HTTP with JSON (`Backend.lua`).

Your manga, sources and settings live in `koreader/rakuyomi/` (see `Paths.lua`),
not here. `Bookdrop:loadBundledManga` creates `settings.json` there with the
community source list. On first run, it also copies the seven sources in
`sources/` (MangaDex, Webtoon, Batoto, Asura Scans, MangaPill, TCB Scans and
Weeb Central).

## Where things are

### Starting up and talking to the server

| File | What it does |
|---|---|
| `main.lua` | The plugin: `init` registers the `.cbz` reader and a gesture action, `openLibraryView` opens the library. |
| `Backend.lua` | Starts and stops `server`, and has one function per server request (search, chapters, download, settings, sources…). Start here to see what the server can do. |
| `Platform.lua`, `platform/` | How the server is started on Android vs. other devices. |
| `Paths.lua` | Where RakuYomi keeps its data (`koreader/rakuyomi`). |
| `jobs/` | Long tasks run by the server (download a chapter, the unread ones, refresh the library). The screens poll them once a second (`jobs/Job.lua`). |
| `extensions/CbzDocument.lua` | Lets KOReader open the downloaded `.cbz` chapters. |
| `RakuyomiShared.lua` | Reads which manga and chapter a `.cbz` came from (stored in the zip's comment). |

### Screens

| File | Screen |
|---|---|
| `LibraryView.lua` | Your manga library: the first screen, and its menu (search, sources, settings, updates…). |
| `MangaSearchResults.lua` | Results of a search across your sources. |
| `MangaInfoWidget.lua` | A manga's page: cover, description, status, add to library. |
| `ChapterListing.lua` | A manga's chapters: download, read, mark as read, filter by language or scanlator. |
| `ChapterListPopup.lua`, `ChapterMenuItem.lua` | The chapter list shown from inside the reader. |
| `MangaReader.lua` | Opening a chapter in KOReader's reader, and what happens at its end (on to the next chapter). |
| `MangaReaderExtend.lua` | The reader's chapter toolbar: previous, next, the chapter's name. |
| `AvailableSourcesListing.lua` | Sources you can install. |
| `InstalledSourcesListing.lua`, `SourceSettings.lua` | Sources you have, and each one's own settings. |
| `Settings.lua` | RakuYomi's settings (storage, languages, downloads…). |
| `TrackingMenu.lua`, `TrackingSettings.lua`, `TrackingServices.lua`, `OAuthFlowView.lua` | Syncing reading progress to AniList and MyAnimeList (sign-in included). |
| `CookieSyncView.lua` | Passing a website's cookies to a source that needs them. |
| `NotificationView.lua` | New-chapter notifications. |
| `PlaylistDialog.lua`, `handlers/addToPlaylist.lua` | Reading lists. |
| `UpdateChecker.lua` | Checks for a newer RakuYomi. |
| `OfflineAlertDialog.lua` | The "you're offline" notice. |

### Building blocks

| File | What it is |
|---|---|
| `BasicJobDialog.lua`, `DownloadUnreadChaptersJobDialog.lua`, `LoadingDialog.lua` | Progress dialogs for jobs, with cancel. |
| `CustomDialog.lua`, `CheckboxDialog.lua`, `ErrorDialog.lua` | Dialogs. |
| `MenuItem.lua`, `widgets/`, `patch/` | List rows, menus, cover grids and the top-edge gesture (copies of KOReader's widgets with changes). |
| `Icons.lua` | Icon characters (from KOReader's symbol font). |
| `chapters/` | Finding the next and previous chapter. |
| `utils/` | Small helpers (dates, file sizes, chapter names, filters). |
| `gettext+.lua`, `l10n/` | RakuYomi's translations. |
| `testing.lua` | Only active when `RAKUYOMI_IS_TESTING=1` (RakuYomi's own automated tests); otherwise does nothing. |
| `_meta.lua` | The plugin's name and description. |
