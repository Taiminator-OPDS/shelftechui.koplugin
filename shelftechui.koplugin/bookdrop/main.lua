local CoverCache = require("bookdrop_covercache")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Language = require("ui/language")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Provider = require("bookdrop_catalog_provider")
local Zlibrary = require("bookdrop_zlibrary_provider")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template

local Bookdrop = WidgetContainer:extend{ name = "bookdrop", settings = nil }

local function showKeyboard(dialog)
    dialog.skip_first_show_keyboard = nil
    dialog:onShowKeyboard()
end
local CHECKED = "✓"
local UNCHECKED = "□"

local content_options = {
    { "", "All content" }, { "book_fiction", "Fiction" },
    { "book_nonfiction", "Non-fiction" },
    { "book_comic", "Comics" }, { "magazine", "Magazines" },
}
local format_options = {
    { "epub", "EPUB" }, { "pdf", "PDF" }, { "mobi", "MOBI" },
    { "djvu", "DJVU" }, { "cbz", "CBZ" }, { "txt", "TXT" },
}
local library_options = {
    { "gutenberg", "Project Gutenberg" },
    { "standardebooks", "Standard Ebooks" },
    { "textos", "textos.info" },
    { "gallica", "Gallica" },
    { "internet_archive", "Internet Archive" },
    { "zlibrary", "Z-Library" },
}
local language_options = {
    { "", "All languages" }, { "en", "English" }, { "es", "Spanish" },
    { "fr", "French" }, { "de", "German" }, { "ru", "Russian" },
    { "pt", "Portuguese" }, { "it", "Italian" }, { "zh", "Chinese" },
    { "ja", "Japanese" },
}
local sort_options = {
    { "", "Best match" }, { "title", "Title A–Z" },
    { "newest", "Newest publication" }, { "oldest", "Oldest publication" },
}
local ui_language_options = {
    { "C", "English" },
    { "es", "Español" },
    { "fr", "Français" },
    { "de", "Deutsch" },
    { "it_IT", "Italiano" },
    { "pt_PT", "Português" },
    { "pt_BR", "Português do Brasil" },
    { "ru", "Русский" },
    { "zh_CN", "简体中文" },
    { "zh_TW", "中文（台灣）" },
    { "ja", "日本語" },
}
local valid_sorts = { title = true, newest = true, oldest = true }
local valid_contents = {
    book_fiction = true, book_nonfiction = true, book_comic = true, magazine = true,
}
local LARGE_DOWNLOAD_BYTES = 50 * 1024 * 1024
local MACOS_DOWNLOAD_TOTAL_TIMEOUT = 15 * 60

function Bookdrop:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/bookdrop.lua")
    if not self.settings:readSetting("isolated_shelf_filters_v1", false) then
        local filters = self.settings:readSetting("filters", {})
        -- Older shelf callbacks modified the live settings table. Clear the
        -- leaked content constraint once; future explicit filter choices are
        -- stored normally, while shelf filters use copies.
        filters.content = nil
        self.settings:saveSetting("filters", filters)
        self.settings:saveSetting("isolated_shelf_filters_v1", true)
        self.settings:flush()
    end
    if not self.settings:readSetting("homepage_search_decoupled_v2", false) then
        local filters = self.settings:readSetting("filters", {})
        -- Category navigation used to share the persistent content field with
        -- normal searches. Remove that one stale value during this upgrade;
        -- category shelves now operate on independent copies.
        filters.content = nil
        self.settings:saveSetting("filters", filters)
        self.settings:saveSetting("homepage_search_decoupled_v2", true)
        self.settings:flush()
    end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self.manga_plugin = self:loadBundledManga()
end

-- The RakuYomi manga plugin (AGPL-3.0, https://github.com/tachibana-shin/rakuyomi)
-- is bundled unchanged under manga/ so Bookdrop is the single plugin users
-- install. It is booted the way KOReader's plugin loader boots a plugin:
-- dofile its main.lua, then InputContainer:new{ ui = self.ui } runs its init,
-- and it is registered as a UI module so events reach it. Its Rust server
-- binary is started lazily on first use, so a missing binary (not built for
-- this device) only disables the Manga tab, never Bookdrop itself.
function Bookdrop:loadBundledManga()
    local manga_root = self.path .. "/manga"
    package.path = manga_root .. "/?.lua;" .. package.path
    local ok, RakuyomiMain = pcall(dofile, manga_root .. "/main.lua")
    if not ok or type(RakuyomiMain) ~= "table" then
        require("logger").warn("Bookdrop: bundled manga plugin failed to load: "
            .. tostring(RakuyomiMain))
        return nil
    end
    local instance_ok, instance = pcall(RakuyomiMain.new, RakuyomiMain, { ui = self.ui })
    if not instance_ok or not instance then
        require("logger").warn("Bookdrop: bundled manga plugin failed to initialize: "
            .. tostring(instance))
        return nil
    end
    if self.ui.registerModule then
        self.ui:registerModule("rakuyomi", instance)
    end
    -- Seed the Aidoku community source list and the bundled manga source files
    -- on first run.  Popular sources (7 .aix files downloaded at build time by
    -- dev/fetch-popular-sources.sh) are copied into the server's sources directory
    -- so users can search and download immediately without installing anything.
    pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        local data_dir = require("datastorage"):getDataDir()
        local rakuyomi_dir = data_dir .. "/rakuyomi"
        if lfs.attributes(rakuyomi_dir, "mode") ~= "directory" then
            lfs.mkdir(rakuyomi_dir)
        end
        local settings_path = rakuyomi_dir .. "/settings.json"
        if not lfs.attributes(settings_path, "mode") then
            local fh = io.open(settings_path, "w")
            if fh then
                fh:write([=[
{"source_lists":["https://raw.githubusercontent.com/tachibana-shin/aidoku-community-sources/gh-pages/index.min.json"]}
]=])
                fh:close()
            end
        end
        -- Seed bundled .aix source files (installed once, never overwritten)
        local bundled_dir = self.path .. "/manga/sources"
        if lfs.attributes(bundled_dir, "mode") == "directory" then
            local rakuyomi_sources = rakuyomi_dir .. "/sources"
            if lfs.attributes(rakuyomi_sources, "mode") ~= "directory" then
                lfs.mkdir(rakuyomi_sources)
            end
            -- Purge macOS resource-fork turds (._*) that may have been
            -- copied alongside real .aix files on previous installs.
            for file in lfs.dir(rakuyomi_sources) do
                if file:match("^%._") then
                    os.remove(rakuyomi_sources .. "/" .. file)
                end
            end
            local ffiutil = require("ffi/util")
            local first = true
            for file in lfs.dir(bundled_dir) do
                -- Skip macOS resource-fork turds (._*) and hidden files
                if file:match("%.aix$") and not file:match("^%.") then
                    local dest = rakuyomi_sources .. "/" .. file
                    if not lfs.attributes(dest, "mode") then
                        ffiutil.copyFile(bundled_dir .. "/" .. file, dest)
                        if first then
                            logger.dbg("Bookdrop: seeding pre-installed manga sources")
                            first = false
                        end
                    end
                end
            end
        end
    end)
    return instance
end

function Bookdrop:openManga()
    local manga = self.manga_plugin
    if not (manga and manga.openLibraryView) then
        UIManager:show(InfoMessage:new{
            text = _("Manga is not available in this build."),
        })
        return
    end

    local MangaDownloader = require("manga_downloader")
    local server_path = self.path .. "/manga/server"
    local valid, _ = MangaDownloader.validateBinary(server_path)

    if valid then
        -- Binary exists and matches this platform — launch immediately.
        local ok, err = pcall(manga.openLibraryView, manga)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Manga failed to start: %s"), tostring(err)),
            })
        end
        return
    end

    -- Invalid or missing binary — delete whatever is there and offer download.
    if valid == false then
        os.remove(server_path)
        os.remove(self.path .. "/manga/cbz_metadata_reader")
    end
    self:_offerMangaDownload(manga)
end

function Bookdrop:_offerMangaDownload(manga)
    local MangaDownloader = require("manga_downloader")
    local platform = MangaDownloader.detectPlatform()
    UIManager:show(ConfirmBox:new{
        text = T(_(
            "The manga reader needs a small runtime (~25 MB) to be downloaded "
            .. "once for your device (%1).\n\nDownload now?"
        ), platform),
        ok_text = _("Download"),
        ok_callback = function()
            -- Defer to next tick so the offer dialog fully closes
            -- before the download progress UI appears.
            UIManager:nextTick(function()
                self:_startMangaDownload(manga)
            end)
        end,
        cancel_text = _("Not now"),
        cancel_callback = function()
            self:showStoreHome()
        end,
    })
end

function Bookdrop:_startMangaDownload(manga)
    local MangaDownloader = require("manga_downloader")
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenConnected(function()
        local loading = InfoMessage:new{
            text = _("Downloading manga runtime…\n\nPlease wait."),
            dismissable = false,
        }
        UIManager:show(loading)
        UIManager:forceRePaint()

        local ok, err
        Trapper:wrap(function()
            ok, err = MangaDownloader.downloadAndInstall(self.path .. "/manga")
        end)

        UIManager:close(loading)

        if ok then
            UIManager:show(InfoMessage:new{
                text = _("Manga reader is ready."),
                timeout = 1.5,
            })
            UIManager:scheduleIn(0.3, function()
                local launch_ok, launch_err = pcall(manga.openLibraryView, manga)
                if not launch_ok then
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Manga failed to start: %s"), tostring(launch_err)),
                    })
                end
            end)
        else
            UIManager:show(ConfirmBox:new{
                text = T(_("Could not download the manga runtime:\n%1\n\nTry again?"), err or _("unknown error")),
                ok_text = _("Retry"),
                ok_callback = function()
                    UIManager:nextTick(function()
                        self:_startMangaDownload(manga)
                    end)
                end,
                cancel_text = _("Not now"),
                cancel_callback = function()
                    self:showStoreHome()
                end,
            })
        end
    end)
end

function Bookdrop:onDispatcherRegisterActions()
    Dispatcher:registerAction("bookdrop_show", {
        category = "none", event = "ShowBookdrop", title = _("Bookdrop"), filemanager = true,
    })
end

function Bookdrop:addToMainMenu(menu_items)
    if not self.ui.document then
        menu_items.bookdrop = {
            text = _("Bookdrop store"),
            sorting_hint = "search",
            callback = function() self:showStoreHome() end,
        }
    end
end

function Bookdrop:onShowBookdrop() self:showStoreHome() end

function Bookdrop:getFilters()
    local filters = self.settings:readSetting("filters", {})
    local changed = false
    if type(filters.formats) ~= "table" then
        filters.formats = {}
        if filters.extension then
            for option_number, option in ipairs(format_options) do
                if option[1] == filters.extension then
                    filters.formats[option[1]] = true
                    break
                end
            end
        end
        if not next(filters.formats) then
            for option_number, option in ipairs(format_options) do
                filters.formats[option[1]] = true
            end
        end
        filters.extension = nil
        changed = true
    end
    if type(filters.libraries) ~= "table" then
        filters.libraries = {}
        for option_number, option in ipairs(library_options) do
            filters.libraries[option[1]] = true
        end
        filters.libraries.zlibrary = nil
        changed = true
    end
    if filters.libraries.manybooks ~= nil then
        filters.libraries.manybooks = nil
        changed = true
    end
    if filters.sort and not valid_sorts[filters.sort] then
        filters.sort = nil
        changed = true
    end
    if filters.content and not valid_contents[filters.content] then
        filters.content = nil
        changed = true
    end
    if changed then
        self.settings:saveSetting("filters", filters)
        self.settings:flush()
    end
    return filters
end

function Bookdrop:setFilter(key, value)
    local filters = self:getFilters()
    filters[key] = value ~= "" and value or nil
    self.settings:saveSetting("filters", filters)
    self.settings:flush()
end

function Bookdrop:resetFilters()
    local formats = {}
    for option_number, option in ipairs(format_options) do
        formats[option[1]] = true
    end
    local libraries = {}
    for option_number, option in ipairs(library_options) do
        libraries[option[1]] = true
    end
    self.settings:saveSetting("filters", { formats = formats, libraries = libraries })
    self.settings:flush()
    self:refreshSettingsMenu()
end

local function selectedOptionLabel(options, value)
    for option_number, option in ipairs(options) do
        if option[1] == value then return _(option[2]) end
    end
end

function Bookdrop:toggleFormat(format)
    local filters = self:getFilters()
    if filters.formats[format] then
        local enabled = 0
        for format_name, is_enabled in pairs(filters.formats) do
            if is_enabled then enabled = enabled + 1 end
        end
        if enabled <= 1 then
            UIManager:show(InfoMessage:new{ text = _("At least one format must remain selected.") })
            return
        end
        filters.formats[format] = nil
    else
        filters.formats[format] = true
    end
    self.settings:saveSetting("filters", filters)
    self.settings:flush()
    self:refreshSettingsMenu()
end

function Bookdrop:toggleLibrary(library)
    local filters = self:getFilters()
    if filters.libraries[library] then
        local enabled = 0
        for library_name, is_enabled in pairs(filters.libraries) do
            if is_enabled then enabled = enabled + 1 end
        end
        if enabled <= 1 then
            UIManager:show(InfoMessage:new{ text = _("At least one library must remain selected.") })
            return
        end
        filters.libraries[library] = nil
    else
        filters.libraries[library] = true
    end
    self.settings:saveSetting("filters", filters)
    self.settings:flush()
    self:refreshSettingsMenu()
end

function Bookdrop:loadCoversProgressively(books, widget, limit)
    -- what's already on disk shows at once; only the rest is fetched (in a
    -- background process), and the screen redraws just its page as covers land
    local missing = {}
    for _, book in ipairs(books) do
        if not book.cover_path then
            book.cover_path = CoverCache:get(book)
            if not book.cover_path and book.cover_url then missing[#missing + 1] = book end
        end
    end
    if widget.refreshCovers and not widget._bookdrop_closed then widget:refreshCovers() end
    if #missing == 0 then return end
    if not CoverCache:prefetchInBackground(missing, limit or #missing) then return end

    local function poll()
        if widget._bookdrop_closed then return end
        local changed = false
        for i = #missing, 1, -1 do
            local book = missing[i]
            local path = CoverCache:get(book)
            if path then
                book.cover_path = path
                table.remove(missing, i)
                changed = true
            end
        end
        if changed and widget.refreshCovers then widget:refreshCovers() end
        if #missing > 0 and CoverCache:isPrefetching() then
            UIManager:scheduleIn(0.5, poll)
        end
    end
    UIManager:scheduleIn(0.3, poll)
end

local function safeFilename(value)
    value = tostring(value or "book"):gsub("[%z\1-\31/\\:*?\"<>|]", "-")
    value = value:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return value ~= "" and value or "book"
end

--- Where a book's file goes (and is, once downloaded).
function Bookdrop:destinationFor(book, acquisition)
    local download_dir = G_reader_settings:readSetting("download_dir")
        or G_reader_settings:readSetting("home_dir")
        or G_reader_settings:readSetting("lastdir")
        or Device.home_dir
        or "."
    local extension = acquisition and acquisition.extension or "epub"
    return download_dir .. "/" .. safeFilename(book.title)
        .. " - " .. safeFilename(book.author) .. "." .. extension
end

function Bookdrop:downloadBook(book, acquisition)
    if not acquisition or not acquisition.url then
        UIManager:show(InfoMessage:new{ text = _("No downloadable file is available.") })
        return
    end
    local extension = acquisition.extension or "epub"
    local destination = self:destinationFor(book, acquisition)

    local existing = io.open(destination, "rb")
    if existing then
        existing:close()
        UIManager:show(InfoMessage:new{
            text = T(_("Already downloaded to:\n%1"), destination),
        })
        return
    end

    local confirmation_text = T(_("Download %1 (%2) from %3?"), book.title,
        acquisition.format or extension:upper(), book.source or _("the catalog"))
    local download_size = tonumber(acquisition.size)
    if download_size and download_size >= LARGE_DOWNLOAD_BYTES then
        confirmation_text = confirmation_text .. "\n\n" .. T(
            _("This is a large file (%1) and may take several minutes. Keep KOReader open until it finishes."),
            string.format("%.1f MB", download_size / 1024 / 1024))
    end

    UIManager:show(ConfirmBox:new{
        text = confirmation_text,
        ok_text = _("DOWNLOAD"),
        ok_callback = function() self:startBookDownload(book, acquisition, destination) end,
    })
end

function Bookdrop:startBookDownload(book, acquisition, destination)
    local part_path = destination .. ".part"
    os.remove(part_path)
    local size_text = acquisition.size and string.format("%.1f MB", acquisition.size / 1024 / 1024)
        or _("unknown size")

    Trapper:wrap(function()
        Trapper:setPausedText(
            T(_("Downloading %1 is paused."), book.title),
            _("Cancel download"), _("Continue")
        )
        local function downloadTask()
            local task_ok, task_result = xpcall(function()
                local http = require("socket.http")
                local ltn12 = require("ltn12")
                local socketutil = require("socketutil")
                local active_acquisition = acquisition
                local headers
                if book.provider == "zlibrary" then
                    local zlibrary = require("bookdrop_zlibrary_provider")
                    local resolved, resolve_err = zlibrary.resolveDownload(book)
                    if not resolved then error(resolve_err or "could not resolve a fresh download link") end
                    active_acquisition = resolved
                    headers = zlibrary.getDownloadHeaders(active_acquisition.referer)
                else
                    headers = {
                        ["Accept-Encoding"] = "identity",
                        ["User-Agent"] = "KOReader Bookdrop/0.7",
                    }
                    if active_acquisition.referer then headers.Referer = active_acquisition.referer end
                end

                local output, open_err = io.open(part_path, "wb")
                if not output then error(open_err or "cannot create destination") end
                -- Real e-readers use KOReader's normal streaming sink inside a
                -- cancellable subprocess. The macOS emulator must run this task
                -- in-process (see below), so retain a generous safety ceiling
                -- there instead of allowing the UI to remain blocked forever.
                local download_sink
                if jit.os == "OSX" then
                    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT,
                        MACOS_DOWNLOAD_TOTAL_TIMEOUT)
                    download_sink = socketutil.file_sink(output)
                else
                    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT,
                        socketutil.FILE_TOTAL_TIMEOUT)
                    download_sink = ltn12.sink.file(output)
                end
                local request_ok, request_result, download_code, response_headers, status = pcall(http.request, {
                    url = active_acquisition.url,
                    method = "GET",
                    redirect = true,
                    headers = headers,
                    sink = download_sink,
                })
                socketutil:reset_timeout()
                pcall(function() output:close() end)
                if not request_ok then error(request_result) end
                if not request_result then error(status or tostring(download_code)) end
                if tonumber(download_code) ~= 200 then
                    error("download server returned HTTP " .. tostring(download_code)
                        .. (status and (" (" .. tostring(status) .. ")") or ""))
                end
                local content_type = response_headers
                    and (response_headers["content-type"] or response_headers["Content-Type"])
                if content_type and content_type:lower():find("text/html", 1, true) then
                    error("download server returned a sign-in page instead of the book")
                end
                local downloaded = io.open(part_path, "rb")
                local prefix = downloaded and (downloaded:read(512) or "") or ""
                if downloaded then downloaded:close() end
                local normalized_prefix = prefix:lower():gsub("^%s+", "")
                if prefix == "" then
                    error("download server returned an empty file")
                elseif normalized_prefix:find("<html", 1, true)
                    or normalized_prefix:find("<!doctype html", 1, true) then
                    error("download server returned a sign-in page instead of the book")
                end
                if active_acquisition.md5 and active_acquisition.md5 ~= "" then
                    local md5 = require("ffi/MD5")
                    if md5.sumFile(part_path) ~= active_acquisition.md5 then
                        error("file integrity check failed")
                    end
                end
                if not os.rename(part_path, destination) then
                    error("could not save the completed file")
                end
                return { success = true }
            end, function(err)
                local message = tostring(err or "unknown error")
                message = message:match("^[^\n]+") or message
                message = message:gsub("^.-main%.lua:%d+:%s*", "")
                if message == "sink timeout" or message == "timeout" then
                    return "the download timed out because the server was too slow; please try again"
                end
                return message
            end)
            if not task_ok then
                os.remove(part_path)
                return { success = false, error = tostring(task_result) }
            end
            return task_result
        end

        local completed, result
        if jit.os == "OSX" then
            -- On the macOS emulator KOReader's Trapper-managed return pipe can
            -- report a completed child with no payload after a successful TLS
            -- transfer. The same task is reliable in-process. Real e-readers
            -- keep the cancellable subprocess path below.
            completed, result = true, downloadTask()
        else
            completed, result = Trapper:dismissableRunInSubprocess(downloadTask,
                T(_("Downloading %1\n%2 · %3\n\nTap to pause or cancel."),
                    book.title, acquisition.format or _("EBOOK"), size_text))
        end

        if not completed then
            os.remove(part_path)
            UIManager:show(InfoMessage:new{ text = _("Download cancelled.") })
        elseif result and result.success then
            if self.ui and self.ui.onRefresh then self.ui:onRefresh() end
            -- (the store offers to read it now)
            local handled = false
            if self.on_downloaded then
                local ok_h, res = pcall(self.on_downloaded, destination, book)
                handled = ok_h and res == true
            end
            if not handled then
                UIManager:show(InfoMessage:new{
                    text = T(_("Downloaded successfully to:\n%1"), destination),
                })
            end
        else
            UIManager:show(InfoMessage:new{
                text = T(_("Download failed: %1"),
                    tostring(result and result.error or "download process exited without a result")),
            })
        end
    end)
end

function Bookdrop:showZlibraryBaseUrlDialog(home)
    local dialog
    dialog = InputDialog:new{
        title = _("Z-Library base URL"),
        input = Zlibrary.getBaseUrl(),
        input_hint = _("https://your.zlibrary.domain"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
            end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local value = dialog:getInputText()
                UIManager:close(dialog)
                local ok, err = Zlibrary.setBaseUrl(value)
                UIManager:show(InfoMessage:new{
                    text = ok and _("Base URL saved.") or (err or _("Invalid base URL.")),
                })
                if home then home:showSettings(self:settingsDropdownEntries(home)) end
            end },
        }},
    }
    UIManager:show(dialog)
    showKeyboard(dialog)
end

function Bookdrop:showZlibrarySignInDialog(home)
    local dialog
    dialog = InputDialog:new{
        title = _("Z-Library email"),
        input = Zlibrary.getCredentials().email or "",
        input_hint = _("Email"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
            end },
            { text = _("Next"), is_enter_default = true, callback = function()
                local email = dialog:getInputText()
                UIManager:close(dialog)
                self:showZlibraryPasswordDialog(home, email)
            end },
        }},
    }
    UIManager:show(dialog)
    showKeyboard(dialog)
end

function Bookdrop:showZlibraryPasswordDialog(home, email)
    local dialog
    dialog = InputDialog:new{
        title = _("Z-Library password"),
        input = "",
        input_type = "password",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
            end },
            { text = _("Sign in"), is_enter_default = true, callback = function()
                local password = dialog:getInputText()
                UIManager:close(dialog)
                self:performZlibraryLogin(home, email, password)
            end },
        }},
    }
    UIManager:show(dialog)
    showKeyboard(dialog)
end

function Bookdrop:performZlibraryLogin(home, email, password)
    local loading = InfoMessage:new{ text = _("Signing in…"), dismissable = false }
    UIManager:show(loading)
    local finished = false
    local function finish(success, err)
        if finished then return end
        finished = true
        UIManager:close(loading)
        if success then
            UIManager:show(InfoMessage:new{ text = _("Signed in to Z-Library.") })
        else
            UIManager:show(InfoMessage:new{ text = err or _("Z-Library sign-in failed.") })
        end
        if home then home:showSettings(self:settingsDropdownEntries(home)) end
    end
    Trapper:wrap(function()
        local ok, err = Zlibrary.login(email, password)
        finish(ok, err)
    end)
end

function Bookdrop:rememberBook(book)
    local recent, stored = self.settings:readSetting("recent_books", {}), {}
    for key, value in pairs(book) do
        if type(value) == "string" then stored[key] = value end
    end
    if type(book.acquisitions) == "table" then
        stored.acquisitions = {}
        for _, acquisition in ipairs(book.acquisitions) do
            local acquisition_copy = {}
            for key, value in pairs(acquisition) do
                if type(value) == "string" or type(value) == "number" then
                    acquisition_copy[key] = value
                end
            end
            stored.acquisitions[#stored.acquisitions + 1] = acquisition_copy
        end
    end
    local updated = { stored }
    for _, previous in ipairs(recent) do
        if previous.id ~= book.id and #updated < 12 then updated[#updated + 1] = previous end
    end
    self.settings:saveSetting("recent_books", updated)
    self.settings:flush()
end

-- ---------------------------------------------------------------------------
-- The screens are ShelfTechUI's store (bos_store): Bookdrop keeps the
-- libraries, the filters, the cover cache and the downloads.
-- ---------------------------------------------------------------------------

function Bookdrop:refreshSettingsMenu() end -- (the Settings app redraws its own rows)

function Bookdrop:showStoreHome() require("bos_store").open() end
function Bookdrop:runSearch(query) require("bos_store").open{ query = query } end

--- The store's settings, as rows for the Settings app.
function Bookdrop:settingsItems()
    local function summary(values, options)
        local n = 0
        for _i, o in ipairs(options) do if values[o[1]] then n = n + 1 end end
        return n == #options and _("All") or T(_("%1 of %2"), n, #options)
    end
    local function checks(options, key, toggle)
        local items = {}
        for _i, o in ipairs(options) do
            local value, label = o[1], o[2]
            items[#items + 1] = {
                text = _(label), keep_menu_open = true,
                checked_func = function() return self:getFilters()[key][value] == true end,
                callback = function() toggle(self, value) end,
            }
        end
        return items
    end
    local function radios(options, key)
        local items = {}
        for _i, o in ipairs(options) do
            local value, label = o[1], o[2]
            items[#items + 1] = {
                text = _(label), radio = true, keep_menu_open = true,
                checked_func = function() return (self:getFilters()[key] or "") == value end,
                callback = function() self:setFilter(key, value) end,
            }
        end
        return items
    end
    return {
        {
            text = _("Libraries"),
            description = _("Which libraries the store asks. Each is asked on its own, so a slow one doesn't hold up the rest."),
            mandatory_func = function() return summary(self:getFilters().libraries, library_options) end,
            sub_item_table_func = function() return checks(library_options, "libraries", self.toggleLibrary) end,
        },
        {
            text = _("Formats"),
            description = _("The kinds of file to offer."),
            mandatory_func = function() return summary(self:getFilters().formats, format_options) end,
            sub_item_table_func = function() return checks(format_options, "formats", self.toggleFormat) end,
        },
        {
            text = _("Language of the books"),
            mandatory_func = function() return _(selectedOptionLabel(language_options, self:getFilters().language or "") or "All languages") end,
            sub_item_table_func = function() return radios(language_options, "language") end,
        },
        {
            text = _("Order of results"),
            mandatory_func = function() return _(selectedOptionLabel(sort_options, self:getFilters().sort or "") or "Best match") end,
            sub_item_table_func = function() return radios(sort_options, "sort") end,
        },
        {
            text = _("Z-Library"),
            description = _("An account of your own, for the Z-Library library."),
            mandatory_func = function() return Zlibrary.isSignedIn() and _("Signed in") or _("Not signed in") end,
            sub_item_table_func = function()
                return {
                    { text = _("Sign in…"), callback = function() self:showZlibrarySignInDialog() end },
                    { text = _("Address…"), mandatory_func = function() return Zlibrary.getBaseUrl() end,
                        callback = function() self:showZlibraryBaseUrlDialog() end },
                    { text = _("Sign out"), enabled_func = function() return Zlibrary.isSignedIn() end, callback = function()
                        Zlibrary.signOut()
                        UIManager:show(InfoMessage:new{ text = _("Signed out of Z-Library.") })
                    end },
                }
            end,
        },
        {
            text = _("Reset the store's choices"),
            description = _("Every library but Z-Library, every format, every language."),
            callback = function() self:resetFilters() UIManager:show(InfoMessage:new{ text = _("Reset."), timeout = 2 }) end,
        },
        {
            text = _("Clear the store's covers"),
            callback = function()
                CoverCache:clear()
                UIManager:show(InfoMessage:new{ text = _("Cached covers cleared.") })
            end,
        },
    }
end

return Bookdrop
