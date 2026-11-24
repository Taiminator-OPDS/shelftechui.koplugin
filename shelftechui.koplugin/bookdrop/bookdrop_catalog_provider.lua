--[[
THE STORE'S BUILT-IN LIBRARIES, AND HOW RESULTS ARE FILTERED AND RANKED
=======================================================================

Where this file sits in a store search:

  you type  ->  bos_store.lua  Store:onTyped / Store:runSearch
            ->  bos_store.lua  Search.start: one background job per library,
                each calling  CatalogProvider:searchSource(id, query, ...)
                (this file), which hands the request to the right provider:
                  * internet_archive -> bookdrop_provider.lua
                  * zlibrary         -> bookdrop_zlibrary_provider.lua
                  * everything else  -> bookdrop_opds_provider.lua (OPDS feeds)
                  * your own added libraries ("user_1", "user_2", ...) are
                    routed by bos_store_libs.lua, which wraps searchSource
                    and hydrate before they get here
            ->  as each library answers, bos_store.lua's merge() keeps only
                books that pass CatalogProvider.matchesQuery (below), then
                orders them with M.sortBooks, which for "Best match" (and as
                the first step of the others) calls CatalogProvider:sortBooks.

TO ADD A BUILT-IN LIBRARY
  1. Give it an id and add the id to `source_order` (that is also the order
     the libraries are listed in the store's Libraries... menu).
  2. Give it a display name in `sources`.
  3. Give it a rank in `SOURCE_PRIORITY` (only a small tie-breaker, see
     relevance()).
  4. If it has an OPDS feed, add its URLs to OPDS.sources in
     bookdrop_opds_provider.lua and you are done: searchSource sends any id
     it doesn't know to the OPDS provider. If it has no feed, write a
     provider with :search(query, page, filters) and :hydrate(book), and add
     a branch for it in searchSource() and hydrate() at the end of this file.
  5. Whether it is ticked by default is decided in bos_store.lua
     (Store:filters / Libs.withLibraries).

TO REMOVE ONE: take its id out of `source_order` (that alone stops it being
searched or offered); the other tables can keep or lose their entry.
]]

local InternetArchive = require("bookdrop_provider")
local OPDS = require("bookdrop_opds_provider")
local ZlibraryProvider = require("bookdrop_zlibrary_provider")

local CatalogProvider = { page_size = 10 }

-- Every built-in library, in the order they are asked and listed.
CatalogProvider.source_order = {
    "gutenberg", "standardebooks", "textos", "gallica", "internet_archive", "zlibrary",
}

-- The names shown for them (store menus, the line under each book, errors).
CatalogProvider.sources = {
    gutenberg = "Project Gutenberg",
    standardebooks = "Standard Ebooks",
    textos = "textos.info",
    gallica = "Gallica",
    internet_archive = "Internet Archive",
    zlibrary = "Z-Library",
}

-- Which library wins when two books are otherwise equally good matches: a
-- lower number is better. relevance() gives each book 60 - 8 * priority
-- points (Standard Ebooks 52, Gutenberg 44, ... Z-Library 12). That is tiny
-- next to the title/author points (hundreds), so it only orders books that
-- matched the query equally well, e.g. the same title found in two places.
-- A library missing from this table counts as 6.
local SOURCE_PRIORITY = {
    standardebooks = 3,
    gutenberg = 2,
    textos = 3,
    gallica = 4,
    internet_archive = 2,
    zlibrary = 1,
}

-- normalize("Les Misérables, Tome I") -> "les miserables tome i"
-- Strips Spanish/French/Portuguese accents, lowercases, turns every run of
-- punctuation into one space. Everything below compares normalized text, so
-- "Misérables" and "miserables" are the same word. Add a pair to
-- `replacements` to fold another accented letter.
local function normalize(value)
    value = tostring(value or "")
    local replacements = {
        { "[ÁÀÂÄÃáàâäã]", "a" }, { "[ÉÈÊËéèêë]", "e" },
        { "[ÍÌÎÏíìîï]", "i" }, { "[ÓÒÔÖÕóòôöõ]", "o" },
        { "[ÚÙÛÜúùûü]", "u" }, { "[Ññ]", "n" }, { "[Çç]", "c" },
    }
    for _, replacement in ipairs(replacements) do
        value = value:gsub(replacement[1], replacement[2])
    end
    return value:lower():gsub("[^%w]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

-- The distinct words (2+ letters) of a text, normalized and in order.
local function words(value)
    local result, seen = {}, {}
    for word in normalize(value):gmatch("%S+") do
        if #word > 1 and not seen[word] then
            seen[word] = true
            result[#result + 1] = word
        end
    end
    return result
end

-- Words ignored in what you type when deciding whether a book matches,
-- so "the count of monte cristo by dumas" asks for count, monte, cristo,
-- dumas. "by" (and par/por/von) is here so "Dracula by Bram Stoker" works.
-- Add a word here if typing it makes good results disappear.
local QUERY_STOP_WORDS = {
    a = true, al = true, de = true, del = true, el = true, en = true,
    la = true, las = true, los = true, un = true, una = true, y = true,
    the = true, of = true, ["and"] = true, le = true, les = true, des = true, et = true,
    by = true, par = true, por = true, von = true,
}

-- The words of a query that must be found. If every word is a stop word
-- (searching for "The"), the stop words are kept so something is asked.
local function queryWords(value)
    local filtered = {}
    for _, word in ipairs(words(value)) do
        if not QUERY_STOP_WORDS[word] then filtered[#filtered + 1] = word end
    end
    return #filtered > 0 and filtered or words(value)
end

-- True when two words differ by at most one typo (a letter added, dropped
-- or changed): "dostoevsky" ~ "dostoyevsky". Only for words of 5+ letters;
-- short words must match exactly (otherwise "cat" would match "car").
local function withinOneEdit(left, right)
    if left == right then return true end
    if #left < 5 or #right < 5 or math.abs(#left - #right) > 1 then return false end
    local left_index, right_index, edits = 1, 1, 0
    while left_index <= #left and right_index <= #right do
        if left:byte(left_index) == right:byte(right_index) then
            left_index, right_index = left_index + 1, right_index + 1
        else
            edits = edits + 1
            if edits > 1 then return false end
            if #left > #right then
                left_index = left_index + 1
            elseif #right > #left then
                right_index = right_index + 1
            else
                left_index, right_index = left_index + 1, right_index + 1
            end
        end
    end
    if left_index <= #left or right_index <= #right then edits = edits + 1 end
    return edits <= 1
end

-- True when every term is one of the words of `value` (with one typo
-- allowed per word when `fuzzy`). Word order doesn't matter.
local function fieldMatchesTerms(value, terms, fuzzy)
    local field_words = words(value)
    for _, term in ipairs(terms) do
        local matched = false
        for _, field_word in ipairs(field_words) do
            if field_word == term or (fuzzy and withinOneEdit(field_word, term)) then
                matched = true
                break
            end
        end
        if not matched then return false end
    end
    return #terms > 0
end

-- True when the normalized phrase appears in the text as whole words.
local function containsPhrase(haystack, phrase)
    return (" " .. normalize(haystack) .. " "):find(" " .. phrase .. " ", 1, true) ~= nil
end

-- THE FILTER: is this book an answer to what was typed? Libraries send
-- back plenty that isn't (full-text hits, loose keyword matches), so every
-- book a library returns goes through this before it is shown. A book is
-- kept when ANY of these holds:
--   1. the exact phrase appears in its title + author
--      ("moby dick" in "Moby Dick; Or, The Whale Herman Melville");
--   2. every query word (stop words dropped) appears somewhere in title +
--      author, in any order, one typo allowed per word of 5+ letters
--      ("melville moby", "dostoyevsky idiot");
--   3. the query is its ISBN (spaces and dashes ignored);
--   4. every query word is exactly a word of its subjects/tags (so "whaling"
--      finds books filed under Whaling, but descriptions never count).
-- An empty query (a shelf such as the storefront's lists) keeps everything.
-- To loosen the search, add a rule that returns true; to tighten it, drop
-- the fuzzy `true` in rule 2 or remove rule 4.
local function matchesQuery(book, query)
    local phrase = normalize(query)
    if phrase == "" then return true end
    local title_author = tostring(book.title or "") .. " " .. tostring(book.author or "")
    local terms = queryWords(query)
    if containsPhrase(title_author, phrase) then return true end
    if fieldMatchesTerms(title_author, terms, true) then return true end
    local isbn = normalize(book.isbn):gsub(" ", "")
    local normalized_query = phrase:gsub(" ", "")
    if isbn ~= "" and isbn == normalized_query then return true end
    -- Subjects remain useful for genuine keyword searches, but only as exact
    -- whole-word matches; descriptions and full book text never qualify alone.
    return fieldMatchesTerms(book.subjects, terms, false)
end

-- (ShelfTechUI's store filters each library's answer as it arrives)
CatalogProvider.matchesQuery = matchesQuery

-- True when every needle is a whole word of the haystack (exact, no typos).
local function containsAll(haystack, needles)
    haystack = " " .. normalize(haystack) .. " "
    for _, needle in ipairs(needles) do
        if not haystack:find(" " .. needle .. " ", 1, true) then return false end
    end
    return #needles > 0
end

-- THE "BEST MATCH" SCORE. Higher is better. Points add up:
--
--   library rank (SOURCE_PRIORITY)          60 - 8 x priority   (12..52)
--   Z-Library ticked and this is from it    +48
--   TITLE (only the first that applies):
--     title is exactly the query            +1200
--     title starts with the query           +1000   "Dracula's Guest"
--     query appears in the title            +850
--     every query word is in the title      +700
--   AUTHOR (only the first that applies):
--     author is exactly the query           +900
--     query appears in the author           +650
--     every query word is in the author     +500
--   every query word in title+author+subjects  +180
--
-- So a title match beats an author match, and a book whose title is exactly
-- what you typed beats one that merely contains it. With no query (a
-- shelf), only the library rank counts and the library's own order is kept.
-- To make authors weigh more than titles, raise the AUTHOR numbers above
-- the TITLE ones; keep gaps of 100+ so the library rank stays a tie-breaker.
local function relevance(book, query, filters)
    local phrase = normalize(query)
    local title, author = normalize(book.title), normalize(book.author)
    local combined = title .. " " .. author .. " " .. normalize(book.subjects)
    local tokens = queryWords(query)
    local score = 60 - 8 * (SOURCE_PRIORITY[book.provider] or 6)
    if filters and filters.libraries and filters.libraries.zlibrary
        and book.provider == "zlibrary" then
        score = score + 48
    end
    if phrase == "" then return score end
    if title == phrase then score = score + 1200
    elseif (title .. " "):find(phrase .. " ", 1, true) == 1 then score = score + 1000
    elseif containsPhrase(title, phrase) then score = score + 850
    elseif containsAll(title, tokens) then score = score + 700 end
    if author == phrase then score = score + 900
    elseif containsPhrase(author, phrase) then score = score + 650
    elseif containsAll(author, tokens) then score = score + 500 end
    if containsAll(combined, tokens) then score = score + 180 end
    return score
end

-- The year a book came out, from `year` or the first 4 digits of
-- `published_date`; nil when the library didn't say.
local function publicationYear(book)
    return tonumber(book.year) or tonumber(tostring(book.published_date or ""):match("(%d%d%d%d)"))
end

-- Orders `books` in place (and returns them). `sort` is the store's sort id
-- (see M.SORTS in bos_store.lua). The comparison, key by key:
--   1. Internet Archive books always go after everyone else's, whatever the
--      sort: its scans are often poor, so the cleaner editions come first.
--      Delete that block to mix them in.
--   2. "newest"/"oldest": by publication year; books with no year go last.
--   3. relevance() score, highest first (this is "Best match").
--   4. title A-Z, then the order the libraries sent them (so equal books
--      never jump around between redraws).
-- The other sorts (Most popular, file size) are applied afterwards in
-- bos_store.lua's M.sortBooks, on top of this order.
function CatalogProvider:sortBooks(books, query, sort, filters)
    for position, book in ipairs(books or {}) do
        book._catalog_position = position
        book._catalog_relevance = relevance(book, query, filters)
        book._catalog_title = normalize(book.title)
        book._catalog_year = publicationYear(book)
    end
    table.sort(books, function(left, right)
        local left_is_archive = left.provider == "internet_archive"
        local right_is_archive = right.provider == "internet_archive"
        if left_is_archive ~= right_is_archive then
            return not left_is_archive
        end
        if (sort == "newest" or sort == "oldest")
            and left._catalog_year ~= right._catalog_year then
            if not left._catalog_year then return false end
            if not right._catalog_year then return true end
            if sort == "newest" then return left._catalog_year > right._catalog_year end
            return left._catalog_year < right._catalog_year
        end
        if left._catalog_relevance ~= right._catalog_relevance then
            return left._catalog_relevance > right._catalog_relevance
        end
        if left._catalog_title ~= right._catalog_title then
            return left._catalog_title < right._catalog_title
        end
        return left._catalog_position < right._catalog_position
    end)
    for _, book in ipairs(books or {}) do
        book._catalog_position = nil
        book._catalog_relevance = nil
        book._catalog_title = nil
        book._catalog_year = nil
    end
    return books
end

--- One library's search (the unit that runs in its own process).
--- Returns { books = {...}, total = n, has_next = bool } or nil, why.
--- Each book is a table with at least title, author, provider (the
--- library id), id/provider_id, and whatever else the library knows:
--- year, language, subjects, cover, size, downloads, acquisitions (the
--- download links, filled in later by hydrate if missing).
--- This is the switchboard: add a branch here for a new non-OPDS library.
function CatalogProvider:searchSource(source_id, query, page, filters)
    if source_id == "internet_archive" then
        local result, err = InternetArchive:search(query, page, filters)
        if result then
            for _, book in ipairs(result.books) do book.provider = source_id end
        end
        return result, err
    elseif source_id == "zlibrary" then
        return ZlibraryProvider:search(query, page, filters)
    end
    return OPDS:searchSource(source_id, query, page, filters)
end

--- Fill in what a search result left out (download links, description,
--- cover) when a book is opened. Same switchboard as searchSource.
function CatalogProvider:hydrate(book)
    if book and (book.provider == "internet_archive" or not book.provider) then
        return InternetArchive:hydrate(book)
    elseif book and book.provider == "zlibrary" then
        return ZlibraryProvider:hydrate(book)
    end
    return OPDS:hydrate(book)
end

return CatalogProvider
