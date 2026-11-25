# Changelog

Each version's section is its release notes (GitHub releases and Storefront show them).

## 1.33.0

- A chip with books from several places: in the chip editor, Source → More → Several sources. Tick the places to combine: the Home library, Favorites, Recently read, the Kindle Virtual Library (on a Kindle), the Kobo library (on a Kobo), and any folders you add (each with everything under it). Their books show together in one shelf, sorted and filtered as the chip says; a book in two of the places shows once. Kindle books still open the Kindle's way; the others are ordinary books.

## 1.32.5

- Details from Hardcover: Home now shows them, and the book keeps its cover. The details were saved, but Home kept showing the old ones and the book lost its thumbnail: it was taken out of the cover cache to be read again, but a snapshot of that cache Home keeps (to start quickly) still had the old entry, so Home never read the book again. The same could happen with Home's own "Refresh metadata". Now a refreshed book is read again at once: its cover comes back and the new title, author and description show, in the top panel too.
- The store: Gutendex (Gutenberg's catalogue, asked when Gutenberg's own search is down) is given longer to answer; on the Kindle it was given up on as it started ("wantread"). A library that's too slow now says "too slow to answer".

## 1.32.4

- Home's top panel: the progress bar fills again. With the Retro theme on a sharp screen (a Paperwhite), the bar's frame and padding grew with the screen but the bar itself didn't, so a bar the height of its line of text was all frame and looked empty at any percentage. A thin bar now gets a lighter frame and a solid fill; bars with room look as before.

## 1.32.3

- Libraries you add (catalogues and websites) are now asked the way a web browser asks: a browser's identification and language, cookies kept while following the site's redirects, and the page a book came from sent along with its download. Sites that simply refused unfamiliar apps (a bare "403 Forbidden") now answer. The built-in libraries are still asked as KOReader.
- A site behind bot protection is named as such: "Couldn't reach: Example Books (blocks apps: Cloudflare check)", or DDoS-Guard, or a captcha, or "too many requests: try again later", instead of a bare 403. Those checks look for a real browser running the page, which the store doesn't pretend to be.

## 1.32.2

- Project Gutenberg: when its own search fails (it often answers "503 Service Unavailable" these days, overloaded by AI scrapers), the store asks Gutendex, an open copy of Gutenberg's catalogue, instead. The books, their files (still downloaded from gutenberg.org) and their download counts are the same. Only if both fail does Gutenberg show under "Couldn't reach".

## 1.32.1

- The "Couldn't reach: …" line now shows for searches of two or more words. When a library failed on such a search, the store tried parts of the query too and, finding nothing, counted the library as answered with no books, so its failure was never shown (and when every library failed, it said "Nothing found" instead of "couldn't be reached").

## 1.32.0

- Library priority: Settings → Connect → Store → Library priority lists every library, built-in and your own, in order. Tap one to move it to the top, up, down or to the bottom; "Back to the default order" undoes it.
- What the order does: the first libraries are asked first (three at a time), they win ties in Best match, and a new sort, By library, lists every book of your first library, then the next's.
- With your own order, Internet Archive goes where you put it (by default it's always listed last).

## 1.31.2

- Fixed a crash in the store: with the store open while Wi-Fi was coming on (right after waking the Kindle, for instance), drawing the "Turning on…" message crashed KOReader.
- The store only offers the formats you've ticked (Settings → Connect → Store → Formats). A book with an EPUB and a PDF used to list its PDF too, and could offer it as the download; now the PDF is left out, and a book only in switched-off formats isn't shown. Formats that setting doesn't list (FB2, CBR…) are always kept.
- When a library can't be reached but others answer, a line under the results now says which and why (for example "Couldn't reach: Gallica (HTTP 503)"). Before, its books were simply missing.
- On a new install, Store and Transfer are added to the start menu as intended (a leftover check stopped it).

## 1.31.1

- Settings → Connect → Store → Order of results is now the same setting as the Sort menu on the store's results (it was an older, separate one that still offered Title A–Z and took over whenever the store's Sort was on Best match). A sort chosen there before carries over.
- "Reset the store's choices" leaves Z-Library off, as it says, instead of switching it on.
- Z-Library no longer keeps your password on the device after signing in (only the session it returns); one kept by an older version is deleted at the next sign-in or sign-out.
- Manga: the bundled sources are all copied on first use (a broken line stopped it after the first one).
- The store's code (and Bookdrop's, the engine under it) has detailed comments on the libraries, how a search works and how each sort works; the manga folder has a map (bookdrop/manga/README.md). Unused code removed.

## 1.31.0

- The store's results: a Most popular sort, the most downloaded books first from every library together. The Internet Archive counts its downloads; Project Gutenberg's counts are asked of Gutendex (its catalogue's open API: the last 30 days). Books from libraries that don't count downloads come after, best match first. A book's line shows its downloads when known.
- The Title sort is gone (Best match does that job); a list kept on Title shows as Best match.

## 1.30.1

- Settings no longer opens every menu (plugins' too) in the background as soon as it opens, only once you start a search; the search waits a moment more the first time. On a Paperwhite, Settings crashed right after opening, while that was going on.
- Settings opened on a page by a link (the store's "Libraries, formats and language") forgets that at once, so after a crash it opens on its front page again, not on that page every time.
- With the slow-step recorder on (koreader/settings/stui_perf), Settings writes each page drawn, row tapped and menu opened to koreader/stui_trace.log first, so a crash can be traced to the menu that caused it.

## 1.30.0

- Fixed a crash in Settings: shown again after stepping aside (or reopened within ten minutes), it drew its search field, whose text and keyboard had been freed when it closed. It's now made afresh each time Settings shows again.
- Removing a library: the store's ☰ → Remove a library…, or Settings → Connect → Your libraries → a library → Remove. Asked first; books downloaded from it stay.
- The top panel's stars: a tap redraws only the panel's text column, not the whole home, so the stars change at once. Their size: Settings → Home → Top panel → Edit top panel content → Rating → Stars: Small, Medium, Large, Extra large.
- A rating goes to Hardcover three minutes after your last tap on the stars, as you left it (changing it a few times sends it once).

## 1.29.0

- Any website can be one of your libraries in the store, not only catalogues (OPDS): "Add a library by address…" with the site's address. Its search box is found on the page, and the store searches through it as you would, reading the page of results: a book's page is read when you open it for the files it offers (EPUB first), its cover and its description; a link straight to a file downloads as it is. Only results matching every word you typed are kept, so the site's menus drop out. If the search box isn't found, search the site for a word in a browser and add the address of the results with {q} where that word was.

## 1.28.0

- The top panel's stars (Rating, interactive) are your Hardcover rating too: a tap there is sent to Hardcover for a book linked to it (now, or when next connected). A book not linked yet is linked first when Hardcover certainly has it. Beside your stars, Hardcover's readers' rating of the book, like "(4.4★)" (asked once a day).
- The keyboard shows a key pressed the moment your finger lands on it, in the screen's quickest mode, instead of after the tap (which comes once the finger lifts, and later still with double-tap on). The letter is typed on the tap as before; the key goes back quickly, and the keyboard is drawn properly once you pause.
- For finding stutters on waking: ShelfTechUI's slow-step recorder can be turned on with a file (koreader/settings/stui_perf); it writes to crash.log what took long and whose it was.

## 1.27.0

- Hold the shelf's chip: a Series card switches the whole shelf between series grouped (a stack per series; box sets on spines) and one book at a time. The shelf behind changes as you tap.
- Series one at a time: hold a series stack → This series → Grouped on this shelf, on or off (off opens it out into its books). Hold a book of a series → Edit → Group this series / Ungroup this series. With the shelf's grouping off, a series grouped this way is the only stack; with it on, a series ungrouped this way stays book by book. Each shelf keeps its own.

## 1.26.0

- The store takes an author in the search: "dracula bram stoker", "Dracula by Bram Stoker" or "stoker dracula". When a library's own search finds few books for all of it, the title and the author are asked for on their own too, and only the books matching every word you typed are kept.
- A Hardcover key on a store book's page (signed in to Hardcover): it opens the same book on Hardcover (filled when it's already been found there).
- Hold a book → Edit → Details from Hardcover: the book's title, authors, series and number, description and genres from Hardcover (and its cover, if you like), kept as KOReader's own custom details of the book (Book information shows them; Reset there takes them off). The book it's linked to on Hardcover, else Hardcover's closest match, shown first to say yes to.
- Every full-screen page ShelfTechUI has (Hardcover, the store, Settings, Transfer, Insights, the lists of home, Wrapped…) goes back at the top left and home at the top right. A page's own menu is the ☰ beside home (the store's settings and its storefront are in it). Pages of the book you're reading (Contents, Notebook, Pages, X-Ray) keep their own.

## 1.25.0

- Settings comes back: a row that opens something of its own (a plugin's settings, a dialog, a page over the book) steps Settings aside so the book or home shows under it, and when that's closed, Settings is back where you were, on the same page. Actions with nothing to show leave Settings up. Opening a book or going home from a row still leaves Settings.
- Settings opens faster the second time: closed less than 10 minutes ago, the same app is shown again on its front page instead of being built anew, and its search is ready at once. No flash when it steps aside.
- Hold a series stack: "This shelf" comes first, with Group books in series (on or off, for the shelf you're on) and the look of the shelf's series stacks (Divider card, Ribbon, Book stack, Collage, Text, None, or the default).

## 1.24.0

- X-Ray from the dictionary is a pop-up now: look up a name and tap X-Ray, and a card takes the dictionary's place with who it is, how often they're mentioned so far, where in the book (the strip), and the start of their Wikipedia article (or the passage they first appear in). Its keys: Passages (every passage, tap one to go there) and Everyone in X-Ray. A word that isn't a name says so. A tap outside closes it.
- The whole X-Ray (everyone, people and places) is in the reader menu, beside Contents, Notebook and Pages. With no X-Ray yet it offers to download one.

## 1.23.0

- Home: "Group books in series" for any shelf (hold the shelf's chip → View mode). A series' books show as one stack with a count, where its first book would be; a tap opens the series in order. Works in Covers and List (in Spines it's the series boxes, as before). Shelves that already had Series boxes on now group in Covers and List too.
- X-Ray downloads in the background: you go back to the book and keep reading, and a notification says when it's ready (open it from the dictionary's X-Ray key). Much faster: Open Library and Wikidata are asked at the same time, Wikipedia in one request for up to 20 characters instead of one each, the fan wiki for fewer pages, and the book is searched for every name in one pass instead of one pass per name (about 8 times faster on Moby Dick). Shorter waits on a slow source, and one retry when Open Library drops the connection.

## 1.22.2

- X-Ray finds more books by itself: an author filed as "Melville, Herman" is read as Herman Melville, subtitles like "; Or, The Whale" are left out, and Open Library is asked a second, looser way, trying its first few matches until one lists characters.
- When a book still isn't found, X-Ray lists the closest matches from Open Library and Wikidata (title, author, year, what it is), the book's own author first: pick the right one to download its X-Ray. "Search for something else" looks under another title.
- "Couldn't be reached" (no connection) is now told apart from "not found".

## 1.22.1

- Fixed the selection menu not answering (and a tap outside not closing it) while the handles kept working. With a plugin that keeps an invisible layer at the top of the screen (Bookends does), the handles were put over the menu instead of under it, and took every tap. They now always go just under the menu.

## 1.22.0

- X-Ray, as on a Kindle, from the dictionary: look a word up and tap X-Ray for the book's people and places, the most mentioned first, each with a strip showing where in the book it appears. An entry has Wikidata's line on it, the start of its Wikipedia article and, when the book has a fan wiki, what that says (folded away: fan wikis spoil), then every passage it's in; tap one to go there (Back returns). Looking up a name opens its entry straight away. Spoiler-free is on: only passages up to where you are (⋯ to change it, download again or remove).
- The first time for a book, X-Ray asks to download: the names come from Open Library and Wikidata, the rest from Wikipedia and the fan wiki, once (a few seconds with Wi-Fi); then the book itself is searched for them on the Kindle. It's kept beside the book and works offline after that. Books without characters on Open Library or Wikidata get none.
- The dictionary window is more modern: rounded, the word big at the top with the dictionary and count under it (tap for the other dictionaries), ✎ and × at the right, the definition without a box, and rounded keys at the bottom: Dicts ▾ · Dict | Wiki · X-Ray · Highlight. The vocabulary builder is in the Dicts ▾ menu.

## 1.21.0

- A compact selection menu, as on a phone: when you select text, a small bar hovers just under the selection (or over it, when there's no room under) with Highlight · Note · Copy · Look up · ⋯. The ⋯ key turns it into the rest of the actions (Select, Wikipedia, Translate, Search, Share, and what plugins add: Pin page, Hardcover, QR code…). It keeps clear of the handles at the ends of the selection, and stays on top of them, so its keys always answer, also after dragging a handle. A tap outside closes it and the selection. Settings → Reading → Compact selection menu (off: KOReader's menu).

## 1.20.1

- Fixed a freeze in a book after selecting text. The handles at the ends of a selection treated a quick flick or a tap on a knob as a knob still held, and kept the whole screen for it, so nothing else answered (easily hit after a selection across pages). Now any way a touch ends lets go, and a knob that's somehow left "held" is let go after 3 seconds.

## 1.20.0

- The pull-down works from any screen: a swipe down from the top edge of Settings, Hardcover, the store, Bookdrop's screens and ShelfTechUI's other full-screen pages opens what a swipe down on home opens (the reading summary: today's reading and the books to jump back into; or Settings, as chosen in Settings → Home → Swipe down on home). Over a book's own pages (Contents, Notebook, Pages) it's what a swipe down in a book opens. Only a swipe that starts at the very top, so the pages' own swipes still work. Settings → Home → Swipe down from any screen.

## 1.19.0

- Hardcover's search works like the store's: the search key opens a field with the keyboard, and books and readers that match show under it as you type, under their own headings (Books, People; All opens the whole list). Cancel or a swipe right goes back.
- Hardcover's Reading, Want and Read tabs are one tab, Library, with its shelves as keys at its top (Reading, Want to read, Read). It opens on the shelf you last looked at. Tabs: Home · Friends · Library · Explore.

## 1.18.2

- Settings → Home → Top panel: the status line didn't take your edits while ShelfTechUI's icon row was showing in its place. The switch (Status line with icons) now sits beside it; your own line can be edited when it's off, and is what the top panel shows then.
- Dash can do without its line of the time, date and battery: Settings → Home → Time and battery line on Dash (keep the Time and Battery chips on the home bar instead).

## 1.18.1

- Find in the store (from Hardcover, or a pick) searches the libraries by the title and the author's full name ("Dracula, Bram Stoker"), so a common title doesn't bury the book. If that finds nothing (a library that writes the name otherwise, "B. Stoker"), it tries the title and surname ("Dracula Stoker"), then the title alone. The Internet Archive and Gallica now take a title and an author in one search (each word in any field).

## 1.18.0

- The store can sort its results: Best match, Smallest file first, Largest file first, Title, Newest, Oldest (the Sort key above a list). It's kept for the next searches, and changing it reorders the list there and then.
- Each result shows its file size (when the library gives it), beside its library, format and year.
- A book from Hardcover (Find in the store), or a pick, opens the copy that takes the least room. Every library is asked; once a copy turns up the others get a few seconds more, then the smallest copy of the very same book (same title and author) is opened.
- Other matches: on such a book's page, every other copy the libraries have (smallest first), then books with the title and more to it, then the same title by someone else.

## 1.17.2

- "Connecting to Wi-Fi…" and "Waiting for network connectivity…" are hidden too, with KOReader's other Wi-Fi progress messages (they show while something waits for the network: the store, Hardcover, a sync). Settings → Connect → Wi-Fi → Hide Wi-Fi progress messages.

## 1.17.1

- Opening and closing a book no longer waits for KOReader's progress sync (KOSync). It asked its server for your place as a book opened and sent it as the book closed, and the screen (the reading toolbar included) waited for the answer: about 2 s each time on a Paperwhite, sometimes 7 s. Now that's done in the background and the answer used when it comes. Settings → Reading → Progress sync in the background.
- Home tidies up after a book a few seconds later, not just as the book comes up (it held the first moments of reading up by about half a second).
- USB drive: the question comes as soon as the computer is seen (from 0.4 s; it was 1.5 s), and a wall charger still doesn't ask.
- Hardcover: no separate Search tab. Search results, a genre's or a mood's books and Popular open under Explore, with a key back to it.
- Hardcover: stars no longer overlap. Your rating is drawn at the right size for the screen, halves shown; the rating dialog's stars are spaced.

## 1.17.0

- Hardcover opens on a dashboard: your reading goal with how you're doing, what you're reading, what your friends are reading, this month's popular books (when there's room) and a line each of genres and moods. Each heading opens its full list.
- Browse Hardcover by genre or mood, as on hardcover.app: Explore shows every genre and mood (the ones your books and popular books carry first, by Hardcover's own names), and a tap lists their books, the most read first. A book's page shows its genres and moods too; a tap on one lists more like it.
- Popular moved into Explore (and opens as a list from there or the dashboard).
- Buttons with words on them lose their arrows (Reviews, Read more, More by…, Open in Hardcover, Insights): they pointed the same way wherever they sat.
- USB drive: the question only comes up for a computer. The Kindle's USB port and charger say what's at the other end (a computer talks to it; a wall charger only gives power); when they don't say, it asks as before. What was seen is kept in koreader/stui_usbprobe.log.
- Smoother home: closing Settings, the store, Hardcover or Wrapped puts home's screen back as it was instead of drawing it all again (that took about half a second on a Paperwhite). Only what changed meanwhile, like the clock, is drawn again.
- The home bar's clock and battery redraw just the bar each minute, not the whole home screen.
- Hardcover covers are kept small (at most 360 × 540), so its pages show quicker; covers fetched before are made small in the background.

## 1.16.0

- Bookshelf is now simply Home. Its settings are part of Settings → Home, under plain headings beside the rest: Shelves (edit shelves, shelf and top panel size), Top panel (status line, content, modules), Covers and text, Library and More (behaviour, advanced). There's no separate "Bookshelf" heading or "Bookshelf settings" page any more, and "Start menu position" sits with the start menu's entries.
- Everywhere else too: gesture actions read "Home: …" (gestures you've set keep working), "Start with: home", "Go to the file browser", "Home font", "Home menu" and so on. Start menu entries saved under the old names are renamed.
- Settings opens and searches more smoothly: the search index is built in the background a moment after Settings opens, in small steps, and kept for half an hour, so the first search no longer stalls.
- Removed Bookshelf's old self-updater code, which was switched off (ShelfTechUI updates it).

## 1.15.2

- A key you tap changes colour at once. Its pressed colour used to wait behind the typing of the letter and reach the screen with it. It's now sent to the screen first, in the screen's quickest mode, and the key is drawn back properly when you let go (the quick mode can't show the grey keys).
- Typing in the store's search field is quicker. Your own matching books are looked up, and the list redrawn, once you pause for a moment, not on every key.

## 1.15.1

- A borderless Kindle-style keyboard: with KOReader's "Key border" unchecked (Keyboard → Keyboard appearance), the keys sit on one white board, touching, with the keys that don't type (shift, backspace, return…) in a light grey and a line along its top. With it checked, the keys stand apart on the grey panel as before.
- A roomier compact keyboard: with KOReader's "Compact" checked (Keyboard → Keyboard appearance), the Kindle-style keyboard is lower still than KOReader's compact one (an eighth less height), and less crowded: labels sized to the keys, no long-press hints in the keys' corners (holding a key still offers them), narrow gaps and no margin round the board.

## 1.15.0

- USB drive on a Kindle without leaving KOReader by hand. Plugging in asks "USB drive" or "Just charge". Choose USB drive and KOReader saves what's open and closes, the Kindle's own USB drive mode takes over, and when you eject it on the computer KOReader opens again by itself. It can't stay open meanwhile, because it lives on the drive the computer takes. Also a Quick Settings tile and home chip (USB drive), Settings → Device → USB drive, and a gesture action. "Don't ask when plugged in" turns the question off, since a Kindle can't tell a computer from a charger.
- A quicker keyboard, as a Kindle's own: a key types at once. KOReader's keyboard waits for the screen twice for every letter, to show the key pressed and then released. Now the letter is typed straight away, the key shows pressed for a moment without waiting, and the text you type uses the screen's fast mode, tidied up when you pause. Settings → Device → Keyboard → Quick keyboard.
- USB drive: when the cable was already plugged in before you chose USB drive, the USB link is switched off and on (as a replug), so the Kindle goes into USB drive mode by itself, in a few seconds.
- After you eject, KOReader isn't started a second time if it's already running or starting (two starting at once could close one another).
- The keyboard looks like a Kindle's: white keys for letters, numbers and the space bar, grey ones for shift, backspace and return, on a light grey panel, in a plain sans-serif font. A key you press turns darker for a moment. Corners follow your theme (square in Retro). Done to KOReader's keyboard as it's built, without changing KOReader's files. Settings → Device → Keyboard → Kindle-style keyboard.

## 1.14.2

- KOReader's Wi-Fi progress messages ("Scanning for networks…", "Turning on Wi-Fi…", "Connecting to network…", "Wi-Fi off.") aren't shown. The Wi-Fi chip and status line already say what Wi-Fi is doing. Questions such as "Do you want to turn on Wi-Fi?", the list of networks, and other messages that mention Wi-Fi still show. Turn it off in Settings → Connect → Wi-Fi.
- If you used a patch to hide those messages, you can remove it. A patch that hides every popup mentioning Wi-Fi also hides questions, which makes the actions behind them do nothing (turning on Wi-Fi for the store or Hardcover, choosing a network, Transfer's code switch).

## 1.14.1

- Home's Wi-Fi chip shows the right state after its popup closes. It used to keep its pressed (inverted) look and its old on/off state, because the toolbar was asked to repaint while the popup was still on screen.
- On a Kindle, the chip and the popup ask the Kindle's own Wi-Fi switch. Some Kindles keep the Wi-Fi interface loaded after the radio is turned off, which read as "on".
- The popup shows the network's name as soon as the device knows it ("Connected to HomeNet"), without reopening. The name is asked for again for a little while after joining, since a Kindle gives an empty name for a moment.
- Tapping the Wi-Fi switch and closing the popup straight away no longer leaves a ghost "Wi-Fi" row painted over home.

## 1.14.0

- Settings has a search field. Type a word or two and every setting that matches shows as you type: ShelfTechUI's and KOReader's, sub-pages too, each with the way to it ("Device › Screen › Sleep screen"). Tap one to land on its page with the setting marked. "Wi-Fi" and "wifi" find the same things.
- Settings looks like a phone's now. A front page has a big title, the search field, and the sections as rows: an icon, the name, and what's inside. Each section is a page of its own, with "‹ Settings" to go back and a search key at the top.
- Rows stand in cards. On/off settings are switches, a choice in a list has a tick, and a setting's current value shows in grey on the right. Pages show dots for how many there are. Swiping right on a section's first page goes back.

## 1.13.1

- Transfer on a Kindle: phones and computers can reach it. The Kindle's firewall drops connections from other devices, and the way Transfer opened it could fail. Its rule now goes first in the list. Kindles whose firewall has no "conntrack" get a plain rule for the port instead. When the Kindle reloads its firewall (Wi-Fi reconnecting, waking up), Transfer notices within a minute and opens the port again.
- If the firewall refuses outright, Transfer's screen says so. The phone tips gain a Kindle line.

## 1.13.0

- Hardcover in your library: books on your Hardcover Reading and Want to read shelves that aren't on this device stand at the end of Home, faded, with a small GET. Tap one to open it in the store, where the libraries are searched for it. Hold it to see its Hardcover page.
- Once the book is on the device (from the store, Transfer, anywhere), the faded one goes. It also goes when you take the book off your Hardcover shelves.
- Settings → Hardcover → "On Home, your books not on this device": Reading and Want to read (default), Reading only, or None.
- A shelf of them alone can be made from the shelf editor ("Hardcover: not on this device").
- Nothing waits on the network: your shelves are kept on the device and fetched again in the background over Wi-Fi.

## 1.12.2

- Wi-Fi control (home toolbar and Quick Settings): turning Wi-Fi on no longer freezes the screen on a Kindle or Kobo. It comes back the way it does after sleep: the device joins the network it knows by itself. If it can't join one, a note says to hold the control to choose a network.
- The Wi-Fi chip and tile always show where Wi-Fi is going (on, connecting, off) and follow it as it changes, including on the home toolbar while it's turning on or off.
- A second tap while Wi-Fi is still turning on now turns it off again, instead of getting stuck.
- The network's name is asked for far less often (on a Kindle that lookup can stall while Wi-Fi is busy).

## 1.12.1

- **Find people.** Hardcover's search now has two keys, Books and People: type a name or a username, and the readers found are listed (the ones you follow already say so). A tap opens a reader's page.
- **Follow and unfollow.** A reader's page has a Follow key; on someone you follow it reads "✓ Following", and a tap (asked first) stops. The friends list, home's badges and the start-menu card follow suit. A key made before this version can read who you follow but not change it: sign out and in again with a new key (the link now asks for that permission).
- **Remove a book from your shelves.** A book's Hardcover page has a Remove key beside your rating, for one that got there by mistake: it's taken off your Hardcover shelves altogether, with your rating, dates and progress for it (asked first; the book on the device isn't touched). Reading it afterwards doesn't put it back: only choosing a shelf for it again does.

## 1.12.0

Hardcover becomes a social hub, and the book window loses most of its tabs.

- **A friends list.** Hardcover's Friends tab is a row a reader, those reading now first: the cover of what they're on, the book, and how far along they are (a bar, the percentage, the page). A tap opens **their page**: reading now, finished lately with their stars, their counts, and a key to their figures.
- **On home's covers.** A book of yours that a reader you follow is reading says so across the top of its cover: "42% · Ana" ("★ 5 · Tomás" when they've finished it, "+2" when more friends have it). Matched by the book's Hardcover link, else its title. Hardcover's settings turn it off.
- **A start-menu card: Friends reading.** Who's reading what, and how far, in the start menu (add it in the start menu's editor). A tap on a reader opens their page.
- **On a book's page**: the friends who have it, as keys with how far they are; a tap opens their page.
- **Insights is an app.** The summary you pull down on home has one page now, and an **Insights** key where "Reading calendar" was (the calendar is a key on Insights). Insights shows your reading as a dashboard: this device's statistics, and a second page of your Hardcover figures (books and pages, this year month by month, the last years, your ratings, the authors you read most, your goal). **The list at the top switches to any reader you follow** and shows theirs.
- **Send this device's reading history to Hardcover** (Hardcover's settings): the books you've finished here, with the day you finished them, and the ones you're in the middle of, with how far. Only a book Hardcover has under the same title and author is sent, and a book already on your shelves there is left as it is. Reading time itself can't be sent: Hardcover has no place for it.
- **FOR YOU's hero shows the book.** A recommendation in the hero has its description, and Hardcover's rating when the hero is set to show Hardcover ratings.
- **Recommendations say why.** Hardcover's picks are scored: a book high in the "similar" lists of several books you rated 4 or more comes first.
- **The book window has three tabs, not eight.** About (Description · Reviews · Similar · Hardcover, as a row of keys inside it), Highlights and Tags when the book has them, and Edit (Details · Cover). It opens on the description as before, and anything that asked for a particular tab lands on its key.
- Home was timed again with all of this: the cover badges add about a millisecond to drawing home, and nothing new runs while it sits idle.

Hardcover knows the page a reader is on, not the chapter: the friends list shows the percentage and the page.

## 1.11.2

- **Hardcover's ratings and reviews on the store's books.** Signed in to Hardcover, a book's page in the store shows its rating there ("★ 4.3 · 1.3k ratings on Hardcover · 2 reviews"), and a page of what its readers say: reviews (none marked as spoilers), then the quotes readers liked most, with a key to Hardcover's own page for it (your shelf and rating). Shown only when it's certainly the same book (the same title and author).
- **The × that clears a search is inside the search field**, at its right end, as on a phone. The key beside the field is always the store's settings now, so there's one cross on the bar, not two.

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
