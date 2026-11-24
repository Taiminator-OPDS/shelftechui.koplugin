--[[
THE STOREFRONT'S BUILT-IN SHELVES

Three rows on the store's front page come from here, not from a search, so
the storefront appears instantly and works offline:
  "Classics to start with"   shelves.fiction + shelves.nonfiction
  "Comics and magazines"     shelves.comics + shelves.magazines
  "In Spanish and French"    shelves.spanish + shelves.french
(Store:homeData in bos_store.lua joins them and gives the row titles.)

Each book here is a stub: title, author, and a cover image shipped in
assets/covers/<name>.jpg. When you open one, the store asks its library
for the rest (download links, description) through CatalogProvider:hydrate,
using provider + provider_id.

TO CHANGE A SHELF: edit the lists in CuratedHome.build. Use the helper for
the book's library and put a cover JPEG in assets/covers/ named as the
`cover` argument:
  gutenberg(..., "<ebook number>", title, author, "<cover>", "<language>")
      the number is the one in gutenberg.org/ebooks/<number>
  archive(..., "<archive.org identifier>", title, author, "<cover>", "<year>")
      the identifier is the one in archive.org/details/<identifier>
  textos(..., "<author-slug>/<book-slug>", title, author, "<cover>")
      the path after textos.info/
To add a new row, add a list here and a table.insert in Store:homeData.
--]]

local CuratedHome = {}

local function gutenberg(plugin_path, formats, id, title, author, cover, language)
    local detail_url = "https://www.gutenberg.org/ebooks/" .. id .. ".opds"
    return {
        id = "curated-gutenberg-" .. id,
        provider = "gutenberg",
        provider_id = detail_url,
        detail_url = detail_url,
        source = "Project Gutenberg",
        title = title,
        author = author,
        language = language or "",
        format = "EBOOK",
        acquisitions = {},
        allowed_formats = formats,
        cover_path = plugin_path .. "/assets/covers/" .. cover .. ".jpg",
    }
end

local function archive(plugin_path, formats, id, title, author, cover, year)
    return {
        id = id,
        provider = "internet_archive",
        provider_id = id,
        source = "Internet Archive",
        title = title,
        author = author,
        language = "eng",
        published_date = year,
        format = "EBOOK",
        acquisitions = {},
        allowed_formats = formats,
        cover_path = plugin_path .. "/assets/covers/" .. cover .. ".jpg",
    }
end

local function textos(plugin_path, formats, slug, title, author, cover)
    local base = "https://www.textos.info/" .. slug
    return {
        id = "curated-textos-" .. cover,
        provider = "textos",
        provider_id = base,
        source = "textos.info",
        title = title,
        author = author,
        language = "es",
        format = "EPUB",
        available_formats = "EPUB · MOBI · PDF",
        allowed_formats = formats,
        cover_path = plugin_path .. "/assets/covers/" .. cover .. ".jpg",
        acquisitions = {
            { extension = "epub", format = "EPUB", mime_type = "application/epub+zip", url = base .. "/epub" },
            { extension = "mobi", format = "MOBI", mime_type = "application/x-mobipocket-ebook", url = base .. "/mobi" },
            { extension = "pdf", format = "PDF", mime_type = "application/pdf", url = base .. "/pdf" },
        },
    }
end

function CuratedHome.build(plugin_path, formats)
    local fiction = {
        gutenberg(plugin_path, formats, "1342", "Pride and Prejudice",
            "Jane Austen", "pride-and-prejudice", "en"),
        gutenberg(plugin_path, formats, "345", "Dracula",
            "Bram Stoker", "dracula", "en"),
        gutenberg(plugin_path, formats, "1260", "Jane Eyre",
            "Charlotte Brontë", "jane-eyre", "en"),
    }
    local nonfiction = {
        gutenberg(plugin_path, formats, "2680", "Meditations",
            "Marcus Aurelius", "meditations", "en"),
        gutenberg(plugin_path, formats, "1497", "The Republic",
            "Plato", "republic", "en"),
        gutenberg(plugin_path, formats, "205", "Walden",
            "Henry David Thoreau", "walden", "en"),
    }
    local comics = {
        archive(plugin_path, formats, "twistedhistory00voor",
            "Twisted History", "Frank Corey Voorhies", "twisted-history", "1904"),
        archive(plugin_path, formats, "barneygooglehisf0000debe_d8b9",
            "Barney Google and Spark Plug", "Billy De Beck", "barney-google", "1923"),
        archive(plugin_path, formats, "bestofhtwebsterm00webs",
            "Best of H. T. Webster", "H. T. Webster", "ht-webster", "1953"),
    }
    local magazines = {
        archive(plugin_path, formats, "AmazingStoriesVolume01Number01",
            "Amazing Stories, April 1926", "Hugo Gernsback", "amazing-stories-01", "1926"),
        archive(plugin_path, formats, "AmazingStoriesVolume01Number02",
            "Amazing Stories, May 1926", "Hugo Gernsback", "amazing-stories-02", "1926"),
        archive(plugin_path, formats, "AmazingStoriesVolume01Number03",
            "Amazing Stories, June 1926", "Hugo Gernsback", "amazing-stories-03", "1926"),
    }
    local spanish = {
        textos(plugin_path, formats, "franz-kafka/la-metamorfosis",
            "La Metamorfosis", "Franz Kafka", "la-metamorfosis"),
        textos(plugin_path, formats, "federico-garcia-lorca/bodas-de-sangre",
            "Bodas de Sangre", "Federico García Lorca", "bodas-de-sangre"),
        textos(plugin_path, formats, "fiodor-mijailovich-dostoyevski/crimen-y-castigo",
            "Crimen y Castigo", "Fiódor M. Dostoyevski", "crimen-y-castigo"),
    }
    local french = {
        gutenberg(plugin_path, formats, "17489", "Les misérables: Fantine",
            "Victor Hugo", "les-miserables", "fr"),
        gutenberg(plugin_path, formats, "14155", "Madame Bovary",
            "Gustave Flaubert", "madame-bovary", "fr"),
        gutenberg(plugin_path, formats, "4650", "Candide, ou l'optimisme",
            "Voltaire", "candide", "fr"),
    }

    return {
        shelves = {
            fiction = fiction,
            nonfiction = nonfiction,
            comics = comics,
            magazines = magazines,
            spanish = spanish,
            french = french,
        },
    }
end

return CuratedHome
