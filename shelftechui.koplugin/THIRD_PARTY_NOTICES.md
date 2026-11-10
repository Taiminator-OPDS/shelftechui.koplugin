# Third-party notices

The reading toolbar (bos_toolbar.lua, bos_toolbar_widget.lua, bos_toolbar_style.lua, bos_stats.lua) is based on the Kobo-style toolbar by Lina (https://github.com/nessnos/kobotoolbar.koplugin), used under the MIT License:

```
MIT License

Copyright (c) 2026 Lina

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

--------------------------------------------------------------------------------
Third-party notices
--------------------------------------------------------------------------------

KOReader
  This plugin runs inside KOReader (https://github.com/koreader/koreader), which
  is licensed under the GNU AGPL v3. No KOReader code is included; the plugin
  only uses KOReader's public Lua modules at run time.

Icons
  The SVG line icons in icons/ and icons/line/ are original drawings made for
  KoboUI and this plugin (same author, same licence).

Trademarks
  Kobo is a trademark of Rakuten Kobo Inc. This project is not affiliated with,
  endorsed by or sponsored by Rakuten Kobo. "Kobo-style" only describes the look
  and feel the plugin is inspired by.
```

Glimpse (glimpse/) is Glimpse by Erik Fanki, a viewer for the maps, family trees and other reference images in a book, restyled in the retro look and with its self-updater removed (it would replace the bundled copy). Glimpse is licensed under the GNU Affero General Public License v3, the same license as ShelfTechUI (see LICENSE).

Bookdrop (bookdrop/) is the Bookdrop store plugin, distributed under the GNU Affero General Public License v3 (see bookdrop/NOTICE and bookdrop/LICENSE-AGPL-3.0). It contains a Z-Library client ported from zlibrary.koplugin (https://github.com/ZlibraryKO/zlibrary.koplugin, AGPL-3.0) and bundles the RakuYomi manga plugin (https://github.com/tachibana-shin/rakuyomi, AGPL-3.0) under bookdrop/manga/. RakuYomi's server binary is not shipped: Bookdrop downloads the build for your device the first time the manga reader is opened. ShelfTechUI's changes: its style module follows ShelfTechUI's theme, and 30 of RakuYomi's translations are left out (the 15 kept are languages ShelfTechUI ships).

Transfer (bos_transfer.lua, transfer/) takes over from the FilebrowserPlus plugin by Neeraj Patel, itself derived from KOReader's filebrowser.koplugin (GNU AGPL v3). It runs the File Browser web server (https://filebrowser.org), Copyright the File Browser Contributors, licensed under the Apache License 2.0; the binary in transfer/ is unmodified (see transfer/NOTICE).
