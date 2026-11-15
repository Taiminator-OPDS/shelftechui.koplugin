# Changelog

Each version's section is its release notes (GitHub releases and Storefront show them).

## 1.11.1

- **Hardcover's recommendations everywhere.** Signed in to Hardcover, the day's picks start with books like the ones you rated highest there, then what the readers you follow are reading, then what's popular (never a book on your shelves or on the device). They're in the store's Recommended row, in FOR YOU on home and in a book's Recommendations tab, taken in turn with the ones from your own reading.
- **The search screen starts with recommendations.** Tapping the search field shows covers you might want in the room above the keyboard, as large as fits; a tap opens one. Typing takes over as before.
- **Transfer: the usual reasons a phone can't open the page are on its screen** ("Same Wi-Fi, and any VPN off"), with the steps a tap away, a VPN first.

## 1.11.0

- **Hardcover.** A new app for [hardcover.app](https://hardcover.app), in ShelfTechUI's look (a toolbar and Quick Settings control, Settings → Connect → Hardcover, and an action for gestures):
  - **Friends**: what the readers you follow are reading and have just finished, with their ratings.
  - **Reading, Want, Read**: your shelves, with how far along you are and your stars.
  - **Popular**: this month's most read on Hardcover. **Search** finds any book.
  - **A book's page**: put it on a shelf with one tap, rate it by half stars, read about it, see the **quotes readers liked most** and reviews (those marked as spoilers are left out), and go to the store to find it in your libraries.
- **It keeps up as you read**, as a Kindle does with Goodreads. Opening a book puts it on your Reading shelf; closing it sends how far along you are; finishing it moves it to Read and asks for your rating. What can't be sent without Wi-Fi waits and goes when the device is next connected (Wi-Fi is never turned on for it). Each of these can be turned off in Hardcover's settings.
- **Share a highlight as a quote**: "Hardcover" in the highlight menu.
- **A Hardcover tab when you hold a book** on home: your shelf and rating for it, quotes and reviews. The book is found by its title and author; when that isn't certain it asks "Is it this one?", and "Not this book?" lets you choose.
- **Signing in**: the device shows a QR code to a page of Transfer's, where you get a key from Hardcover (with the right permissions already ticked) and paste it; it's kept only on the device. With an app ID from Hardcover (Hardcover's settings → App ID) signing in is a short link code approved on a phone instead, like linking a Kindle to Goodreads.
- Nothing waits on Hardcover: every request runs in the background, and covers are fetched a few at a time and kept for a month.

## 1.10.2

- **The Transfer control is back.** It had gone from the toolbar and Quick Settings (and couldn't be added again) since 1.10.0; it's where you put it.
- **Download a whole folder.** Every folder on the Transfer page has a ↓, and "↓ This folder" downloads the one that's open: one zip file, made as it's sent, with everything inside (up to 4 GB and 5,000 files at a time).
- **The Transfer page on a monitor.** On a wide screen, sending is on the left and stays put; the device's folders take the rest, with a column each for size and date. On a phone it's as it was.
- **Transfer and phones, again.** Signing in no longer depends on the phone's browser keeping a cookie (the page carries the code itself). While Transfer is on, the device's Wi-Fi is kept awake, so a phone that has never talked to it gets an answer at the first try. The Transfer screen names the Wi-Fi network the phone must be on, says "Opened from…" when a browser reaches it, and has "A phone can't open it?" under ⋯ with what to check. A browser that can't show the page says why instead of showing nothing.
- **Connect has its own icon** in Settings (a globe), no longer the Wi-Fi sign.

## 1.10.1

- **Home's toolbar keeps up.** The battery shows charging within a second of plugging in (and stops when unplugged), the clock moves each minute, and Wi-Fi, the light and night mode show their state as it changes, also after waking up. Only the toolbar's strip is refreshed, only when something it shows has changed, and never over another window.
- **FOR YOU fills your grid.** It shows as many picks a day as home holds swiped up: columns × rows as you set them (3 × 2 gives six), taken in turn from your series, authors and genres. Covers for the extra picks are fetched once.
- **The store opens on Browse.** The Browse keys are at the top of the first page, in a compact grid, above Recommended and Recently viewed; rows show five covers.
- **Transfer reaches every folder.** While a code is asked for, the page can go anywhere on the device: a path bar from "Device" down, a key back to the home folder, and a switch for hidden files. Without a code it stays inside the folder it opens in.
- **Transfer and phones.** The QR code's address now answers with the page itself (no redirect), the sign-in survives being opened from a scanner app, and a browser that tries https first is turned round at once instead of being left waiting. The Transfer page on the device says "Opened from …" when a browser reaches it: if a phone's visit never shows there, the phone isn't reaching the device (see the notes).
- **"Ask for a code" is a plain switch.** One tap, either way, with what it means written under it (it used to open a confirmation box, which didn't answer on some devices). Changing a Transfer setting takes effect at once.

## 1.10.0

- **Transfer has its own server.** The File Browser program is gone: Transfer is now a small web server of ShelfTechUI's own, inside KOReader, so it runs on every device KOReader does and there is nothing separate to fail to start. Open Transfer, scan the QR code, and the page opens on your phone or computer.
- **The address is the Wi-Fi one.** The QR code used to carry the first address the device reported, which on some devices (a Kindle with its USB network) isn't the Wi-Fi's: the phone was sent nowhere. It's now taken from the wireless connection.
- **A page in ShelfTechUI's look.** Drop books on it or choose them (several at once, with progress for each), browse the folder, make folders, download a book back, delete one. A book with the same name as one already there is kept as "Name (2)".
- **A code in place of the password.** Each time Transfer turns on it shows a new six-digit code. Scanning the QR code signs you in by itself; typing the address asks for the code. "Ask for a code" in Transfer's settings turns it off.
- **Books appear by themselves.** A couple of seconds after the last book arrives, home refreshes and says how many came. Transfer never turns itself off in the middle of a transfer.
- **A smaller download.** Without the File Browser program the plugin is about 4 MB (it was about 13 MB).
- Wrapped's sharing uses the same more dependable way of opening its port.

## 1.9.2

- **The update window is fixed.** It was KOReader's confirmation box, which grows with its text: a release with long notes made it taller than the screen, so its frame was drawn over itself (borders inside borders) and its keys were cut off at the bottom. It's now a window of ShelfTechUI's own, in your theme: as tall as what it says and never more than about two thirds of the screen, with What's new shown a page at a time (‹ ›, or swipe) and Not now / Update and restart always inside it.

## 1.9.1

- **FOR YOU is three picks a day.** In place of folders, the FOR YOU tab on home shows three recommendations: one from your series, one by your authors, one from your genres, never a book you already have. The same three all day; tomorrow, the next in each list, so over a few weeks the whole list comes round. (Once, on the first start, the tab's folders are replaced by the three.)
- **Lighter.** Only those three covers are fetched ahead of time (it used to be up to eight for each list). The store's Recommended row and a book's Recommendations tab fetch the covers of what they show when you open them.
- **Want to read** is a row in the store (it was a folder in FOR YOU). The store's Recommended row starts with today's three, then the rest of the list.

## 1.9.0

- **Holding a book opens Bookshelf's own book window again.** ShelfTechUI's separate book page is gone (and its setting with it): everything that opened it (holding a book on Shelf or Dash, a series or author page, the library list, a recommendation you already have) now opens Bookshelf's window, with its Description, My review, Tags, Edit and Cover tabs.
- **A Recommendations tab in that window.** Books from the internet for the one you're looking at: its series and author first, then the rest of your recommendations. Big covers, three across, with title and author under each, "In library" on the ones you have, and ‹ › for more. Tapping one closes the window and opens the store on it (or your own copy's window). With none on file yet, a Get recommendations key.
- In a book, BOOK on the reading toolbar opens KOReader's book information.
- Removed: the book page (about 500 lines) and what only it used.

## 1.8.4

- **Back from the search screen is home.** Opened from home's search field, the search screen's Back (its × key, the Back button, or a swipe right) now closes it in one go, keyboard and all, instead of stepping through the storefront first. Swiping the keyboard down still only puts the keyboard away.
- **A storefront key beside the field** on that search screen (the cart): one tap for the store's main page. From there, Back is home too.
- Opened as the store (the Store chip), nothing changes: Back puts the keyboard away, then leaves.

## 1.8.3

- **The search field is a piece of the home bar you can place.** It's now in the bar's own list (Settings → Home → Status bar → Search field), so you can put chips on either side of it, and it always stretches to take whatever room its row has left: from the chip before it to the chip after it. The same on Dash. (It was added once at the front of your bar; with a great many chips it keeps a minimum width and the rest wrap to a second row.)
- **Fixed: Settings wouldn't close after editing in Bookshelf's settings** (Edit top panel content and its other line editors). Those editors take the Settings screen away while they're open and put it back themselves; by then Settings had lost track of its own screen, so its close corner and Back did nothing. It now picks its screen up again when it's shown, and closes it either way.
- **The search field goes straight to the search screen.** The storefront used to be drawn first and the search screen over it a moment later (two flashes); the field is now focused and the keyboard up before anything is painted, so it's one screen, once.
- Pruned: 29 functions nothing called any more (about 400 lines), left from the old toolbar, the old Settings chrome and Bookdrop's old menus.

## 1.8.2

- **One search on home.** The search field now finds exactly what Bookshelf's own search found: it uses Bookshelf's matching (title, author, series, and genres if Bookshelf is set to include them), and keeps every match, not just the first few. "All N in your library ›" beside the first matches opens Bookshelf's own results view on Shelf (with its groups by author, series and genre), or a page of covers on Dash.
- **Bookshelf's magnifier is off the shelf's tabs**, since the field does its job. To have it back: Settings → Home → Bookshelf's search key.
- Fixed: the keyboard could stay on screen after the store closed itself (opening one of your own books from the search).

## 1.8.1

- **The Read home layout is removed.** Home is Shelf or Dash; if you were on Read, you're on Shelf.
- **A search field at the top of the Shelf layout**, in the room the chips left empty on their row: tap it and type for your own books first, then the store's libraries. Hold it for KOReader's search by file name. It takes whatever width the chips don't use (the whole row if you have no chips there).

## 1.8.0

- **Edit a book's details from its page.** Hold a book: its page now has an **Edit** key beside Resume, which opens Bookshelf's own editor straight on its Edit tab (also "Edit details…" under ⋯).
- **Recommendations on a book's page work.** The Online tab used to download covers while it was being drawn, which could hang the page; it now shows what's on file at once: this book's series and author first, then the rest of your recommendations, with a "Get recommendations" key when there are none yet. Tapping one opens it in the store, in front.
- **One Recommendations shelf** in FOR YOU, in place of three: more in your series, more by your authors and popular in your genres, taken in turn. (Once, on the first start.) The same single row on Read, Dash and in the store.
- **"In library" on a recommendation you already have**, across the foot of its cover, everywhere recommendations show. Tapping it opens your own copy's page instead of the store.
- **The store turns like a book.** A swipe left is the next page and right the one before, anywhere on the storefront (a row of covers moves on with the › beside its name). A swipe right on the first page no longer closes it.
- **The store's ⚙ menu opens under its key**, on the right, not at the left edge.
- **Updates**: ShelfTechUI now checks when KOReader starts and when Wi-Fi comes on (every three hours at most, not once a day), and Settings → System → Check for ShelfTechUI updates says what the last check found and when, and GitHub's own words if it couldn't be reached.

## 1.7.2

Things answer when you touch them, and say what they're doing while they do it.

- **Wi-Fi tells you what it's doing.** In the Wi-Fi card on the home bar, the switch flips the moment you tap it and the line under it follows along: Turning on… → Connecting… → Connected to your network (or Turning off…). The card keeps itself up to date while it's open, so there's no closing and reopening it to see whether it joined. The Wi-Fi chip, and the Wi-Fi tile in Quick Settings (its second line), follow the same steps. It checks once a second only while Wi-Fi is in between, and stops when it settles.
- **Turn on Wi-Fi keys** (the store when you're offline, sharing your Wrapped) are replaced by the same Turning on… / Connecting… while it happens, then carry on by themselves.
- **Keys and rows in the store, in Wrapped and on its December card flash under your finger** before they act, like the home chips and Quick Settings tiles already did: a fast refresh of just that spot, then the action.

## 1.7.1

- **The store is part of home.**
  - **One search field at the top of Read and Dash** (where the magnifier key was): tap it and type. Your own books that match show at once, from the second letter and without Wi-Fi, each with a Read key; under them, the store's libraries fill in as they answer. Hold the field for KOReader's search by file name.
  - **A Store chip on the home bar**, on every layout (Shelf too): tap for the storefront, hold to go straight to its search. It's added once, first on the bar; move or remove it in Settings → Home → Status bar.
  - The Search chip, if you use it, is now this same search (hold it for the search by file name).

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
