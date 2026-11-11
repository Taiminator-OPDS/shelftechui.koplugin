# Changelog

Each version's section is its release notes (GitHub releases and Storefront show them).

## 1.7.0

- **A new store**, drawn in your theme like the rest of ShelfTechUI, in place of Bookdrop's own screens (Bookdrop still does the fetching and downloading underneath).
  - **Search as you type.** The search field is always at the top. After three letters and a short pause the list under it follows what you've typed; each library is asked on its own in the background, and results appear as each one answers. A library that is slow or down no longer holds up the others, and if none can be reached the store says which and why.
  - **The storefront**: Recommended for you, Recently viewed, shelves of covers, and categories to browse.
  - **A book's page**: cover, title, author, where it's from, one Download key, other formats, the description, more by the author, and + Want.
- **FOR YOU on home is recommendations from the internet**, from what you read (Open Library): more in your series, more by authors you read, popular in your genres, and Want to read. Tapping one opens its page in the store, where the libraries are asked for it. (The lists from your own library are rows on the Read and Dash layouts.) On by default; Settings → Connect → Recommendations.
- **Add your own libraries by address.** Settings → Connect → Your libraries, or ⚙ in the store: give the address of any catalogue that speaks OPDS (your own Calibre, Calibre-Web, Kavita or Komga server, or a library's or publisher's feed). It's then asked when you search, and gets a shelf under Browse. For a catalogue with a password: https://name:password@address.
- Removed: Bookdrop's old home, results, book and menu screens (about 2,000 lines).

## 1.6.5

- **Coming home from a book is lighter.** When you leave a book, Bookshelf keeps it open under home for a moment, and closes it properly before the start menu or Settings opens. Most of that close was KOReader rebuilding the file browser's list of your whole home folder, which sits hidden under Bookshelf's home. That list is now built only when the file browser is actually shown. Closing a book takes about half the time it did (more with a big library), so the start menu after a book opens sooner.
- **Settings at home is home's.** Opened from home while the last book is still being kept open, Settings now closes the book first (as the start menu does) and shows home's settings, not the book's.
- Clears the lists of Settings rows 1.6.3 saved (about 40 KB that KOReader wrote out every time a book closed).

## 1.6.4

- Back to 1.6.2: 1.6.3's changes to the start menu and Settings are undone while their slowdown is looked into.

## 1.6.2

- **Share the whole Wrapped**, not just the summary: Pictures now sends every card to your phone, in order, each as its own picture (hold one to save or share it, or Save all). The cards are also kept on the device, in your screenshots folder under wrapped-<year>.

## 1.6.1

- **Share your Wrapped.** A last card (or Share › on the year-on-one-page card) shows a QR code for your phone:
  - **Picture**: scan it on the same Wi-Fi and your year opens on the phone, ready to hold and save or share, with a Copy key for the text. The device serves it itself, on this Wi-Fi only, at a link nobody could guess; it stops after 10 minutes or when you close Wrapped.
  - **Text**: the QR code holds your year as a few lines of text, to paste anywhere. No Wi-Fi needed.

## 1.6.0

- **Wrapped: your year in books.** A story of full-screen cards, drawn in your theme: the hours you read and each month's share, the books you finished (a wall of their covers), the book of your year, your top authors and genres, when you read (your hour, busiest day, longest streak), your reader type (one of 30), the lines you marked, and the year on one page, which you can save as a picture and use as your sleep screen. Tap the right of the screen for the next card, the left to go back; swipe down to close.
- **The long haul**: a card that shows only when you finished a book this year that you started in an earlier one, with how many days it took.
- From 1 December a card on home tells you your year is ready (once, never over a book); if you haven't opened it by New Year, it reminds you once in January. Open it any time from Settings → Reading → Wrapped (this year so far, or last year), or give it a gesture (ShelfTechUI: Wrapped). Everything is worked out on the device from Reading statistics and your books' highlights; nothing is sent anywhere.

## 1.5.4

- **Faster start.** Home no longer waits for parts only a book or the store needs: the manga reader (and the whole reader it pulled in), the text sheet, and the hooks for the skim bar, pins, highlight handles and book search now load with the first book or the first visit to the store. About 10% less work before home appears.
- **Read and Dash come back from a book quicker**: the book you just read moves to the front with its new progress, instead of the whole library being read again.

## 1.5.3

- The Parchment theme is gone: its torn edges and grey paper didn't show well on e-ink. If you were using it, ShelfTechUI is back on Retro; pick another theme in Settings → Look. (Its three IM Fell fonts are removed too: the plugin is about 250 KB smaller.)

## 1.5.2

- **Updates are at the top of Settings → System**: Check for ShelfTechUI updates first, then KOReader's own updater (named KOReader updates).
- **The start menu on Read and Dash** opens down from the ☰ key at the top, where you tapped, instead of growing up from the bottom of the screen.
- **Switching layouts moved to the Settings app**: Settings → Home now starts with Shelf, Read and Dash, one tap each. The layout key is gone from the top of Read and Dash, and the Layout chip is off the home bar; add it back yourself if you want it (Settings → Home → Status bar). Hold it for the next layout.

## 1.5.1

- Settings → System → Updates: **Check for ShelfTechUI updates** comes first. KOReader's own updater (it updates KOReader, not ShelfTechUI) is moved there too, as **KOReader updates**, instead of an "Update" row among the shortcuts.

## 1.5.0

- **Updates from inside ShelfTechUI.** Settings → System → Updates: Check for updates shows what's new and installs it (KOReader restarts). It also checks once a day on Wi-Fi and offers a new version on home, never over a book. A download is checked before anything changes, and the previous version is kept: "Go back to …" puts it back. Beta versions are opt-in.

## 1.4.1

- The reading summary (pull down on home): switching from Insights back to Today no longer leaves the bottom of Insights on screen.

## 1.4.0

- **Home layouts.** Choose what home shows in Settings → Home → Home layout, or with the new Layout chip on the home bar (hold it for the next layout):
  - **Shelf**: Bookshelf's home, as before.
  - **Read**: a row for each shelf of your library, Continue reading first. Swipe a row sideways; tap its name for all of it.
  - **Dash**: the book you're reading, your streak, this week, what's next in a series and a pick, with one row of covers chosen by chips.
- New gesture action: "ShelfTechUI: next home layout".

## 1.3.2

- Book margins removed (use Bookends instead). The pinned-page badge sits above KOReader's status bar.
- Quick Settings in a book answers at once: every tile shows it was pressed before it acts, and only that tile redraws.

## 1.3.1

- Transfer: the password can be changed, the folder chooser works with a tap, and the page opens straight away.
- Settings app: faster, the top-left corner closes it, and Restart, Sleep, Power off, Reboot and Exit are one tap each under System → Power.
- Bookshelf's own themes, wallpapers, plank designs and ornaments are gone (ShelfTechUI's themes style everything), with their menus.

## 1.3.0

- Transfer (FilebrowserPlus built in): send books from a browser on the same Wi-Fi, with a QR code.
- One Settings app, by purpose: Home, Reading, Look, Connect, Device, Tools, System.
- The home bar's shortcuts are quicker, and plugin shortcuts work every time.
