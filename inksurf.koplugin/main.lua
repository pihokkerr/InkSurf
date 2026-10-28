--[[
Web browser for KOReader
- Pages as link lists, form filling (GET/POST), and page text display
- Download any file (based on Content-Type / Content-Disposition, regardless of extension)
- Cookies, redirects, bookmarks, and a back button
Does NOT execute JavaScript.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local http = require("socket.http")
local socket = require("socket")
local ltn12 = require("ltn12")
local url = require("socket.url")
local Screen = Device.screen

local plugin_dir = (debug.getinfo(1, "S").source or ""):match("^@(.*)/[^/]*$") or "plugins/inksurf.koplugin"
if plugin_dir:sub(1, 1) ~= "/" then
    plugin_dir = lfs.currentdir() .. "/" .. plugin_dir:gsub("^%./", "")
end

local function loadModule(key, file)
    local m = package.loaded[key]
    if not m then
        m = dofile(plugin_dir .. "/" .. file)
        package.loaded[key] = m
    end
    return m
end
local H = loadModule("inksurf_html", "wb_html.lua")
local Render = loadModule("inksurf_render", "wb_render.lua")
local Readability = loadModule("inksurf_readability", "wb_readability.lua")
local Torrent = loadModule("inksurf_torrent", "wb_torrent.lua")
local VPN = loadModule("inksurf_vpn", "wb_vpn.lua")
local NetSurf = loadModule("inksurf_netsurf", "wb_netsurf.lua")
local I18N = loadModule("inksurf_i18n", "wb_i18n.lua")
local function S(s) return I18N.tr(s) end

-- Shared state: the file manager and reader receive separate plugin instances,
-- so browsing history, cookies, and pages are stored at module level.
local State = package.loaded["inksurf_state"]
if not State then
    State = { history = {}, cookies = {}, pages = {}, auth = {}, current = nil }
    package.loaded["inksurf_state"] = State
end

local has_socketutil, socketutil = pcall(require, "socketutil")
if not has_socketutil then socketutil = nil end

local UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

---------------------------------------------------------------------------
-- Helper functions
---------------------------------------------------------------------------

-- Case-insensitive Lua pattern: "a" -> "[aA]"
local function ci(s)
    return (s:gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end))
end

local function trim(s)
    return (s:match("^%s*(.-)%s*$"))
end

local function utf8char(cp)
    if not cp or cp < 0 then return "" end
    if cp < 0x80 then return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    elseif cp < 0x110000 then
        return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return ""
end

local ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
    ndash = "–", mdash = "—", hellip = "…", laquo = "«", raquo = "»", copy = "©",
    bdquo = "„", rdquo = "”", ldquo = "“", rsquo = "’", lsquo = "‘", middot = "·",
}

local function decode(s)
    s = s:gsub("&#[xX](%x+);", function(h) return utf8char(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return utf8char(tonumber(d)) end)
    s = s:gsub("&(%a+);", function(n) return ENTITIES[n] end)
    return s
end

local function stripTags(s)
    s = s:gsub("<[^>]*>", " ")
    s = decode(s)
    s = s:gsub("%s+", " ")
    return trim(s)
end

-- Read an attribute from a tag's attribute text (must start with whitespace)
local function attr(attrs, name)
    if not attrs then return nil end
    local p = "%s" .. ci(name):gsub("%-", "%%-") .. "%s*=%s*"
    local v = attrs:match(p .. '"([^"]*)"') or attrs:match(p .. "'([^']*)'") or attrs:match(p .. "([^%s>\"']+)")
    return v and decode(v)
end

local function hasFlag(attrs, name)
    return (" " .. attrs):find("%s" .. ci(name) .. "[%s=/>]") ~= nil or (" " .. attrs):find("%s" .. ci(name) .. "$") ~= nil
end

local function hostOf(u)
    local p = url.parse(u or "")
    return p and p.host or ""
end

local function fmtSize(n)
    if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
    return string.format("%d KB", math.ceil(n / 1024))
end

local function formEscape(s)
    s = tostring(s or "")
    s = s:gsub("[^%w%-%._~ ]", function(c) return string.format("%%%02X", c:byte()) end)
    return (s:gsub(" ", "+"))
end

local FILE_EXTS = {
    epub = true, pdf = true, mobi = true, azw = true, azw3 = true, kfx = true, fb2 = true, fbz = true,
    djvu = true, djv = true, cbz = true, cbr = true, cbt = true, zip = true, rar = true, ["7z"] = true,
    txt = true, rtf = true, doc = true, docx = true, odt = true, chm = true, lit = true, prc = true,
    torrent = true, jpg = true, jpeg = true, png = true, gif = true, mp3 = true, xps = true, oxps = true,
}

local EXT_BY_TYPE = {
    ["application/epub+zip"] = "epub",
    ["application/pdf"] = "pdf",
    ["application/x-mobipocket-ebook"] = "mobi",
    ["application/vnd.amazon.ebook"] = "azw3",
    ["application/vnd.amazon.mobi8-ebook"] = "azw3",
    ["application/x-fictionbook+xml"] = "fb2",
    ["application/x-fictionbook"] = "fb2",
    ["image/vnd.djvu"] = "djvu",
    ["image/x-djvu"] = "djvu",
    ["application/vnd.comicbook+zip"] = "cbz",
    ["application/x-cbz"] = "cbz",
    ["application/x-cbr"] = "cbr",
    ["application/zip"] = "zip",
    ["application/x-rar-compressed"] = "rar",
    ["application/vnd.rar"] = "rar",
    ["application/x-7z-compressed"] = "7z",
    ["text/plain"] = "txt",
    ["application/rtf"] = "rtf",
    ["application/msword"] = "doc",
    ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"] = "docx",
    ["application/x-bittorrent"] = "torrent",
    ["image/jpeg"] = "jpg",
    ["image/png"] = "png",
}

-- azw3 / mobi / KF8 -> EPUB conversion using the bundled mobitool (libmobi, no external dependencies)
local MOBI_FAMILY = { mobi = true, azw = true, azw3 = true, prc = true, kf8 = true, pdb = true }
local function mobitoolBin() return plugin_dir .. "/bin/mobitool" end
local function hasConverter() return lfs.attributes(mobitoolBin(), "mode") == "file" end
local function convertToEpub(path)
    local bin = mobitoolBin()
    if lfs.attributes(bin, "mode") ~= "file" then return nil, S("A konverter (mobitool) nincs telepítve.") end
    os.execute(string.format("chmod +x %q 2>/dev/null", bin))
    local dir = path:match("^(.*)/[^/]*$") or "."
    local stem = (path:match("([^/]+)$") or path):gsub("%.[^.]+$", "")
    local epub = dir .. "/" .. stem .. ".epub"
    os.remove(epub)
    os.execute(string.format("%q -e %q >/dev/null 2>&1", bin, path))
    if lfs.attributes(epub, "mode") == "file" then
        -- Successful conversion: delete the unsupported original to avoid cluttering
        -- storage, leaving only the EPUB that KOReader can open.
        -- Only do this if KOReader cannot open the source and
        -- the EPUB is actually a different file from the source.
        if epub ~= path and not DocumentRegistry:hasProvider(path) then
            os.remove(path)
        end
        return epub
    end
    return nil, S("A konverzió nem sikerült (lehet, hogy Print Replica vagy DRM-es a fájl).")
end

local function linkExt(u)
    local p = url.parse(u or "")
    local path = p and p.path or ""
    local ext = path:match("%.([%w]+)$")
    if ext and FILE_EXTS[ext:lower()] then return ext:lower() end
    return nil
end

local function filenameFromDisposition(cd)
    if not cd or cd == "" then return nil end
    local star = cd:match(ci("filename") .. "%*%s*=%s*[^']*'[^']*'([^;]+)")
    if star then return url.unescape(trim(star)) end
    local q = cd:match(ci("filename") .. '%s*=%s*"([^"]+)"')
    if q then return q end
    local u = cd:match(ci("filename") .. "%s*=%s*([^;]+)")
    return u and trim(u)
end

local function filenameFromUrl(u)
    local p = url.parse(u or "")
    local path = p and p.path or ""
    local last = path:match("([^/]+)/?$")
    return last and url.unescape(last)
end

local function safeName(name)
    name = name:gsub("[%c\\/:%*%?\"<>|]", "_")
    name = trim(name)
    name = name:gsub("^%.+", "")
    if #name > 180 then
        local base, ext = name:match("^(.-)(%.[%w]+)$")
        if not base then base, ext = name, "" end
        base = base:sub(1, 170):gsub("[\128-\255]+$", "")
        name = base .. ext
    end
    if name == "" then name = "download" end
    return name
end

local function sniffHtml(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local head = (f:read(1024) or ""):lower()
    f:close()
    return head:find("<!doctype html", 1, true) or head:find("<html", 1, true) or head:find("<head", 1, true)
end

---------------------------------------------------------------------------
-- HTML processing
---------------------------------------------------------------------------

local function parsePage(html, page_url)
    local page = { url = page_url, links = {}, forms = {} }

    local title = html:match("<" .. ci("title") .. "[^>]*>(.-)</" .. ci("title") .. "%s*>")
    page.title = title and stripTags(title) or ""
    if page.title == "" then page.title = page_url end

    local base_tag = html:match("<" .. ci("base") .. "(%s[^>]*)>")
    local base_href = attr(base_tag, "href")
    local base = base_href and url.absolute(page_url, base_href) or page_url

    local clean = html:gsub("<!%-%-.-%-%->", "")
    clean = clean:gsub("<" .. ci("script") .. ".-</" .. ci("script") .. "%s*>", "")
    clean = clean:gsub("<" .. ci("style") .. ".-</" .. ci("style") .. "%s*>", "")
    clean = clean:gsub("<" .. ci("noscript") .. "[^>]*>", ""):gsub("</" .. ci("noscript") .. "%s*>", "")

    -- Links
    local seen = {}
    for attrs, inner in clean:gmatch("<[aA](%s[^>]*)>(.-)</[aA]%s*>") do
        local href = attr(attrs, "href")
        if href then href = trim(href) end
        if href and href ~= "" and not href:match("^#")
            and not href:lower():match("^javascript:") and not href:lower():match("^mailto:")
            and not href:lower():match("^tel:") then
            local abs = url.absolute(base, href)
            local uddg = abs:match("[?&]uddg=([^&]+)") -- DuckDuckGo redirect link
            if uddg then abs = url.unescape(uddg) end
            abs = abs:gsub("#.*$", "")
            local text = stripTags(inner)
            if text == "" then
                text = attr(attrs, "title") or attr(inner:match("<" .. ci("img") .. "(%s[^>]*)>"), "alt") or ""
                text = trim(text)
            end
            if text == "" then text = abs end
            local key = abs .. "\0" .. text
            if not seen[key] and #page.links < 800 then
                seen[key] = true
                local ext = abs:lower():match("^magnet:") and "magnet" or linkExt(abs)
                table.insert(page.links, { url = abs, text = text, ext = ext })
            end
        end
    end

    -- Forms
    local fnum = 0
    for fattrs, inner in clean:gmatch("<" .. ci("form") .. "([^>]*)>(.-)</" .. ci("form") .. "%s*>") do
        fnum = fnum + 1
        fattrs = " " .. fattrs
        local action = attr(fattrs, "action")
        action = (action and trim(action) ~= "") and url.absolute(base, trim(action)) or page_url:gsub("#.*$", "")
        local form = {
            action = action,
            method = (attr(fattrs, "method") or "get"):lower(),
            inputs = {},
        }
        for iattrs in inner:gmatch("<" .. ci("input") .. "(%s[^>]*)>") do
            iattrs = iattrs:gsub("/$", "")
            local t = (attr(iattrs, "type") or "text"):lower()
            local name = attr(iattrs, "name")
            if name then
                local value = attr(iattrs, "value") or ""
                if t == "hidden" then
                    table.insert(form.inputs, { name = name, value = value })
                elseif t == "checkbox" or t == "radio" then
                    if hasFlag(iattrs, "checked") then
                        table.insert(form.inputs, { name = name, value = (value ~= "" and value or "on") })
                    end
                elseif t == "submit" or t == "image" or t == "button" then
                    if not form.submit then form.submit = { name = name, value = value } end
                elseif t ~= "file" and t ~= "reset" then
                    table.insert(form.inputs, {
                        name = name, value = value, editable = true, password = (t == "password"),
                        hint = attr(iattrs, "placeholder") or attr(iattrs, "aria-label") or name,
                    })
                end
            end
        end
        -- <button> submit button (the default type is submit)
        for battrs in inner:gmatch("<" .. ci("button") .. "(%s[^>]*)>") do
            local bt = (attr(battrs, "type") or "submit"):lower()
            local bname = attr(battrs, "name")
            if bt == "submit" and bname and not form.submit then
                form.submit = { name = bname, value = attr(battrs, "value") or "" }
            end
        end
        form.onsubmit = attr(fattrs, "onsubmit")
        for sattrs, sinner in inner:gmatch("<" .. ci("select") .. "(%s[^>]*)>(.-)</" .. ci("select") .. "%s*>") do
            local name = attr(sattrs, "name")
            if name then
                local values, chosen = {}, nil
                for oattrs, otext in sinner:gmatch("<" .. ci("option") .. "([^>]*)>([^<]*)") do
                    local v = attr(" " .. oattrs, "value") or stripTags(otext)
                    table.insert(values, v)
                    if hasFlag(oattrs, "selected") then chosen = v end
                end
                local hint = name .. " (" .. table.concat(values, "/", 1, math.min(#values, 6)) .. ")"
                table.insert(form.inputs, { name = name, value = chosen or values[1] or "", editable = true, hint = hint })
            end
        end
        for tattrs, ttext in inner:gmatch("<" .. ci("textarea") .. "(%s[^>]*)>(.-)</" .. ci("textarea") .. "%s*>") do
            local name = attr(tattrs, "name")
            if name then
                table.insert(form.inputs, { name = name, value = decode(ttext), editable = true,
                    hint = attr(tattrs, "placeholder") or name })
            end
        end
        local label
        for _i, inp in ipairs(form.inputs) do
            if inp.editable then label = inp.hint break end
        end
        for _i, inp in ipairs(form.inputs) do
            if inp.password then form.is_login = true end
        end
        form.label = (form.is_login and S("Bejelentkezés: ") or "") .. (label or (S("Űrlap ") .. fnum))
        table.insert(page.forms, form)
    end

    -- Readable text
    local body = clean:match("<" .. ci("body") .. "[^>]*>(.*)") or clean
    body = body:gsub("<" .. ci("br") .. "[^>]*>", "\n")
    body = body:gsub("</" .. ci("p") .. "%s*>", "\n\n")
    body = body:gsub("</" .. ci("div") .. "%s*>", "\n")
    body = body:gsub("</" .. ci("tr") .. "%s*>", "\n")
    body = body:gsub("</" .. ci("li") .. "%s*>", "\n")
    body = body:gsub("<" .. ci("li") .. "%f[%s>][^>]*>", "• ")
    body = body:gsub("</[hH]%d%s*>", "\n\n")
    body = body:gsub("<[^>]*>", "")
    body = decode(body)
    body = body:gsub("[ \t\r]+", " "):gsub(" *\n *", "\n"):gsub("\n\n\n+", "\n\n")
    page.text = trim(body)

    return page
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64(s)
    local out = {}
    local function ch(n) return B64:sub(n + 1, n + 1) end
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        out[#out + 1] = ch(math.floor(n / 262144) % 64) .. ch(math.floor(n / 4096) % 64)
            .. (b and ch(math.floor(n / 64) % 64) or "=") .. (c and ch(n % 64) or "=")
    end
    return table.concat(out)
end

-- <meta http-equiv="refresh"> or a simple JavaScript redirect (e.g. after login)
local function findRedirect(html, base)
    local head = html:sub(1, 30000)
    for m in head:gmatch("<[mM][eE][tT][aA](%s[^>]*)>") do
        local he = attr(m, "http-equiv")
        if he and he:lower() == "refresh" then
            local c = attr(m, "content") or ""
            local delay, u = c:match("^%s*(%d*)%s*[;,]%s*[uU][rR][lL]%s*=%s*['\"]?([^'\"]+)")
            if u and (tonumber(delay) or 0) <= 10 then return url.absolute(base, trim(u)) end
        end
    end
    -- Only on short pages, so a conditional script on a large page does not redirect us
    if #html < 8000 then
        local u = html:match("location%.replace%(%s*['\"]([^'\"]+)['\"]")
            or html:match("location%.assign%(%s*['\"]([^'\"]+)['\"]")
            or html:match("location%.href%s*=%s*['\"]([^'\"]+)['\"]")
            or html:match("window%.location%s*=%s*['\"]([^'\"]+)['\"]")
            or html:match("document%.location%s*=%s*['\"]([^'\"]+)['\"]")
        if u and not u:match("^%s*javascript:") then return url.absolute(base, trim(u)) end
    end
    return nil
end

---------------------------------------------------------------------------
-- Plugin
---------------------------------------------------------------------------

local WebBrowser = WidgetContainer:extend{
    name = "inksurf",
    is_doc_only = false,
}

-- The plugin's own self-contained data directory. All browser data (favorites,
-- settings, NetSurf runtime files, cache, cookies) goes here to keep the
-- plugin self-contained: full removal = deleting the plugin directory.
-- When updating, exclude THIS data/ subdirectory from being overwritten.
local function pluginDataDir()
    local d = plugin_dir
    if d:sub(1, 1) ~= "/" then d = lfs.currentdir() .. "/" .. d:gsub("^%./", "") end
    d = d .. "/data"
    if lfs.attributes(d, "mode") ~= "directory" then lfs.mkdir(d) end
    return d
end

function WebBrowser:init()
    self.data_dir = pluginDataDir()
    self.settings = LuaSettings:open(self.data_dir .. "/inksurf.lua")
    I18N.set(self.settings:readSetting("ui_lang") or "en")
    VPN:setup{
        plugin_dir = plugin_dir,
        settings = self.settings,
        on_up = function() Torrent:resumeAll() end,
        on_down = function() if self:torrentVpnOnly() then Torrent:suspendAll() end end,
    }
    Torrent:setup{
        plugin_dir = plugin_dir,
        data_dir = self.data_dir,
        settings_path = self.data_dir .. "/inksurf_torrent.lua",
        download_dir_fn = function() return self:downloadDir() end,
        before_open = function() self:closeMenu() end,
        can_run_fn = function() return not self:torrentVpnOnly() or VPN:isUp() end,
        on_unopenable = function(paths) self:offerConvertOrSaved(paths) end,
    }
    NetSurf:setup{
        plugin_dir = plugin_dir,
        settings = self.settings,
        data_dir = self.data_dir,
        download_dir_fn = function() return self:downloadDir() end,
        on_downloads = function(paths) self:handleNetsurfDownloads(paths) end,
        on_menu = function() self:openKoreaderTopMenu() end,
        on_reader = function(u) self:openReaderView(u) end,
    }
    -- In the reader (graphical view): add custom buttons to the dialog shown when tapping a link
    if self.ui.link and self.ui.link.addToExternalLinkDialog then
        local function closeDlg(this)
            pcall(function() UIManager:close(this.external_link_dialog) end)
        end
        self.ui.link:addToExternalLinkDialog("01_inksurf", function(this, link_url)
            return {
                text = S("Megnyitás a böngészőben"),
                callback = function()
                    closeDlg(this)
                    self:go(link_url, { referer = State.current and State.current.url })
                end,
            }
        end)
        self.ui.link:addToExternalLinkDialog("02_inksurf_text", function(this, link_url)
            return {
                text = S("Megnyitás szöveges nézetben"),
                callback = function()
                    closeDlg(this)
                    self:go(link_url, { referer = State.current and State.current.url, view = "text" })
                end,
            }
        end)
        if NetSurf:available() then
            self.ui.link:addToExternalLinkDialog("03_inksurf_netsurf", function(this, link_url)
                return {
                    text = S("Megnyitás NetSurfben (JavaScript)"),
                    callback = function()
                        closeDlg(this)
                        NetSurf:run(link_url)
                    end,
                }
            end)
        end
    end
    self.ui.menu:registerToMainMenu(self)

    -- Quick access: (1) a gesture-bindable action (reliable, version-independent),
    -- (2) a best-effort icon in the file manager's top icon bar.
    self:registerQuickAccess()
    self:addTopBarIcon()
end

-- Open/resume InkSurf with one button press. Can be bound to a gesture
-- in KOReader's Settings → Gestures menu (if the plugin is available there).
function WebBrowser:registerQuickAccess()
    pcall(function()
        local Dispatcher = require("dispatcher")
        if Dispatcher.registerAction then
            Dispatcher:registerAction("inksurf_open", {
                category = "none",
                event = "InkSurfOpen",
                title = S("InkSurf: megnyitás / folytatás"),
                general = true,
                filemanager = true,
                reader = true,
            })
        end
    end)
end

function WebBrowser:onInkSurfOpen()
    if NetSurf:available() and NetSurf:hasMinimized() then
        NetSurf:resume()
    else
        self:start()
    end
    return true
end

-- Best effort: add a browser icon to the file manager's top icon bar. Depends on
-- the KOReader version; silently skip if unsupported (the menu remains available).
function WebBrowser:addTopBarIcon()
    pcall(function()
        local ui = self.ui
        local tb = ui and ui.title_bar
        if not tb then return end
        -- Only try in the file manager, and only if the title bar supports a right-side icon
        local IconButton = require("ui/widget/iconbutton")
        local Geom = require("ui/geometry")
        if not (tb.addWidget or tb[2]) then return end
        local btn = IconButton:new{
            icon = "appbar.search", -- Generic magnifying-glass-style icon
            width = tb.button_width or 36,
            height = tb.button_width or 36,
            padding = tb.button_padding or 0,
            callback = function() self:onInkSurfOpen() end,
        }
        if tb.addWidget then
            tb:addWidget(btn)
        end
        pcall(function() UIManager:setDirty(ui, "ui") end)
    end)
end

function WebBrowser:defaultView()
    return self.settings:readSetting("default_view") or "graphic"
end

function WebBrowser:imagesOn()
    return self.settings:nilOrTrue("images")
end

function WebBrowser:torrentVpnOnly()
    return self.settings:nilOrTrue("torrent_vpn_only")
end

-- Start a torrent: if "VPN only" is enabled and the VPN is off, first offer to turn it on
function WebBrowser:startTorrent(fn)
    if not self:torrentVpnOnly() or VPN:isUp() then
        fn()
        return
    end
    UIManager:show(ConfirmBox:new{
        text = S("A torrent csak VPN-en keresztül indulhat, de a VPN ki van kapcsolva.\n\nBekapcsoljam most?"),
        ok_text = S("VPN be + indítás"),
        cancel_text = S("Mégse"),
        ok_callback = function()
            VPN:up(function(ok) if ok then fn() end end)
        end,
    })
end

function WebBrowser:addToMainMenu(menu_items)
    menu_items.inksurf = {
        text = S("🌐 InkSurf böngésző"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = S("Keresés a weben…"),
                help_text = S("DuckDuckGo keresés (nem kell fiók/kulcs). A találati oldal a kiválasztott motorban nyílik."),
                callback = function()
                    local dlg
                    dlg = InputDialog:new{
                        title = S("Keresés a weben"),
                        input = "",
                        input_hint = "what are you looking for?",
                        buttons = {{
                            { text = S("Mégse"), callback = function() UIManager:close(dlg) end },
                            { text = S("Keresés"), is_enter_default = true, callback = function()
                                local qy = dlg:getInputText()
                                UIManager:close(dlg)
                                if qy and qy ~= "" then
                                    -- Open in NetSurf: DuckDuckGo treats the text browser as a bot (CAPTCHA)
                                    NetSurf:run("https://html.duckduckgo.com/html/?q=" .. url.escape(qy))
                                end
                            end },
                        }},
                    }
                    UIManager:show(dlg)
                    dlg:onShowKeyboard()
                end,
            },
            {
                text = S("Cím megnyitása…"),
                help_text = S("Webcím beírása és megnyitása a NetSurf motorban."),
                callback = function()
                    local dlg
                    dlg = InputDialog:new{
                        title = S("Cím megnyitása"),
                        input = "https://",
                        input_hint = "https://example.com",
                        buttons = {{
                            { text = S("Mégse"), callback = function() UIManager:close(dlg) end },
                            { text = S("Megnyitás"), is_enter_default = true, callback = function()
                                local u = dlg:getInputText()
                                UIManager:close(dlg)
                                if u and u ~= "" and u ~= "https://" then NetSurf:run(u) end
                            end },
                        }},
                    }
                    UIManager:show(dlg)
                    dlg:onShowKeyboard()
                end,
            },
            {
                text_func = function()
                    return NetSurf:hasMinimized() and S("▶ Folytatás (háttérben fut)") or S("Folytatás")
                end,
                help_text = S("A felső él lehúzásával (vagy a sáv _ gombjával) minimalizált böngészőt ébreszti fel, ott, ahol abbahagytad."),
                enabled_func = function() return NetSurf:hasMinimized() end,
                callback = function() NetSurf:resume() end,
            },
            {
                text = S("Kedvencek"),
                sub_item_table_func = function() return self:netsurfFavoritesMenu() end,
            },
            {
                text = S("Előzmények (utolsó 5)"),
                separator = true,
                sub_item_table_func = function() return self:netsurfHistoryMenu() end,
            },
            {
                text_func = function()
                    local n = Torrent:countActive()
                    return "Torrents" .. (n > 0 and (" – " .. n .. " running") or "")
                end,
                callback = function() Torrent:showManager() end,
            },
            {
                text_func = function() return "VPN  (" .. (VPN:isUp() and "BE" or "KI") .. ")" end,
                sub_item_table = VPN:menuItems(),
                separator = true,
            },
            {
                text = S("⚙ Beállítások"),
                sub_item_table = {
                    {
                        text_func = function() return S("Nyelv") end,
                        sub_item_table = {
                            {
                                text = "English",
                                radio = true,
                                checked_func = function() return I18N.get() == "en" end,
                                callback = function() self:setUiLang("en") end,
                            },
                            {
                                text = "Hungarian",
                                radio = true,
                                checked_func = function() return I18N.get() == "hu" end,
                                callback = function() self:setUiLang("hu") end,
                            },
                            {
                                text = "German",
                                radio = true,
                                checked_func = function() return I18N.get() == "de" end,
                                callback = function() self:setUiLang("de") end,
                            },
                        },
                        separator = true,
                    },
                    {
                        text = S("Megjelenítés"),
                        sub_item_table = {
                            { text = S("Alapértelmezett nézet:"), enabled = false },
                            {
                                text = S("Grafikus (képekkel)"),
                                radio = true,
                                checked_func = function() return self:defaultView() == "graphic" end,
                                callback = function()
                                    self.settings:saveSetting("default_view", "graphic")
                                    self.settings:flush()
                                end,
                            },
                            {
                                text = S("Szöveges (linklista, gyors)"),
                                radio = true,
                                checked_func = function() return self:defaultView() == "text" end,
                                callback = function()
                                    self.settings:saveSetting("default_view", "text")
                                    self.settings:flush()
                                end,
                            },
                            {
                                text = S("Képek betöltése (grafikus nézet)"),
                                checked_func = function() return self:imagesOn() end,
                                keep_menu_open = true,
                                callback = function()
                                    self.settings:saveSetting("images", not self:imagesOn())
                                    self.settings:flush()
                                end,
                            },
                        },
                    },
                    {
                        text = S("NetSurf: olvasó mód"),
                        help_text = S("A NetSurf motorra vonatkozik. Be: a bonyolult oldalakat egymás alatti blokkokká rendezi (olvashatóbb, de nincs hasábos nézet). Ki: böngészős elrendezés."),
                        checked_func = function() return self.settings:readSetting("netsurf_reader") == true end,
                        keep_menu_open = true,
                        callback = function()
                            self.settings:saveSetting("netsurf_reader", not (self.settings:readSetting("netsurf_reader") == true))
                            self.settings:flush()
                        end,
                    },
                    {
                        text = S("NetSurf: reklámtiltás (hosts)"),
                        help_text = S("A NetSurf motorra vonatkozik. A reklám-domaineket futás idejére a rendszer hosts-fájljához adja (0.0.0.0), majd visszaállítja."),
                        checked_func = function() return self.settings:readSetting("netsurf_hosts_adblock") ~= false end,
                        keep_menu_open = true,
                        callback = function()
                            self.settings:saveSetting("netsurf_hosts_adblock", not (self.settings:readSetting("netsurf_hosts_adblock") ~= false))
                            self.settings:flush()
                        end,
                    },
                    {
                        text = S("Böngésző-azonosító (User-Agent)"),
                        help_text = S("Alapértelmezett: NetSurf — ezt fogadja el a beépített DuckDuckGo-kereső is. A Firefox/Chrome egyes oldalakon segíthet, DE a beépített keresőt bot-ellenőrzésre válthatja. (Cloudflare JS-ellenőrzést egyik sem old meg.)"),
                        sub_item_table = {
                            {
                                text = S("NetSurf (a motor saját azonosítója)"),
                                radio = true,
                                checked_func = function() return (self.settings:readSetting("netsurf_ua") or "netsurf") == "netsurf" end,
                                callback = function() self.settings:saveSetting("netsurf_ua", "netsurf"); self.settings:flush() end,
                            },
                            {
                                text = "Firefox",
                                radio = true,
                                checked_func = function() return self.settings:readSetting("netsurf_ua") == "firefox" end,
                                callback = function() self.settings:saveSetting("netsurf_ua", "firefox"); self.settings:flush() end,
                            },
                            {
                                text = "Chrome",
                                radio = true,
                                checked_func = function() return self.settings:readSetting("netsurf_ua") == "chrome" end,
                                callback = function() self.settings:saveSetting("netsurf_ua", "chrome"); self.settings:flush() end,
                            },
                        },
                    },
                    {
                        text_func = function() return S("Letöltési mappa: ") .. (self:downloadDir() or "?") end,
                        help_text = S("Ide menti a böngésző a letöltött fájlokat (alapértelmezés: koreader/documents)."),
                        keep_menu_open = true,
                        callback = function() self:chooseDownloadDir() end,
                    },
                    {
                        text = S("Torrent: csak VPN-en keresztül"),
                        checked_func = function() return self:torrentVpnOnly() end,
                        keep_menu_open = true,
                        callback = function()
                            self.settings:saveSetting("torrent_vpn_only", not self:torrentVpnOnly())
                            self.settings:flush()
                        end,
                    },
                    {
                        text = S("Hibakereső napló"),
                        help_text = S("Fejlesztői: részletes naplót ír (netsurf.log, netsurf_field.log) a data mappába. Alapból ki. Csak hibakereséshez kapcsold be."),
                        checked_func = function() return self.settings:readSetting("netsurf_verbose") == true end,
                        keep_menu_open = true,
                        callback = function()
                            self.settings:saveSetting("netsurf_verbose", not (self.settings:readSetting("netsurf_verbose") == true))
                            self.settings:flush()
                        end,
                    },
                    {
                        text = S("Teljes kitakarítás / visszaállítás"),
                        help_text = S("Nullázza a böngésző data/ almappáját: kedvencek, előzmények, beállítások, NetSurf futásidejű fájlok, gyorsítótár és sütik. A plugin kódját, a VPN-konfigjaidat és a letöltött fájljaidat NEM bántja. (A régi verziók törzsmappába szórt fájljait is eltakarítja.)"),
                        separator = true,
                        keep_menu_open = true,
                        callback = function() self:confirmPurge() end,
                    },
                },
                separator = true,
            },
            {
                text = S("ℹ Súgó / Névjegy"),
                callback = function() self:showHelp() end,
            },
        },
    }
end

-- Full cleanup (the plugin's data/ subdirectory + legacy scattered files) ----------

function WebBrowser:confirmPurge()
    UIManager:show(ConfirmBox:new{
        text = S("Biztosan kitakarítasz MINDEN böngészőadatot?\n\n") ..
               S("Törlődik: kedvencek, előzmények, beállítások, NetSurf\n") ..
               S("futásidejű fájlok, gyorsítótár és sütik.\n\n") ..
               S("A plugin mappája és a letöltött fájljaid megmaradnak."),
        ok_text = S("Kitakarítás"),
        cancel_text = S("Mégse"),
        ok_callback = function() self:purgeAllData() end,
    })
end

function WebBrowser:purgeAllData()
    local removed = 0
    local function rmtree(path)
        if not path or lfs.attributes(path, "mode") ~= "directory" then return end
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                local p = path .. "/" .. entry
                if lfs.attributes(p, "mode") == "directory" then
                    rmtree(p)
                elseif os.remove(p) then
                    removed = removed + 1
                end
            end
        end
        os.remove(path)
    end

    -- All browser data is in the plugin's data/ subdirectory: delete it all.
    rmtree(self.data_dir)

    -- Scattered files in the root directory possibly left by old (0.x) installations +
    -- the old shared VPN key — remove these too for a truly clean reset.
    local legacy = DataStorage:getDataDir()
    for _, name in ipairs({
        "netsurf.log", "netsurf.pid", "netsurf.signal", "netsurf.state",
        "netsurf.history", "netsurf.inject", "netsurf_cookies",
        "netsurf_downloads.list", "netsurf_hosts.bak",
        "netsurf_launch.sh", "netsurf_resume.sh",
    }) do
        if os.remove(legacy .. "/" .. name) then removed = removed + 1 end
    end
    rmtree(legacy .. "/cache/webbrowser")
    rmtree(legacy .. "/cache/inksurf")
    rmtree(legacy .. "/webbrowser-aria2")
    local sdir = DataStorage:getSettingsDir()
    for _, old in ipairs({ "webbrowser.lua", "webbrowser_torrent.lua", "inksurf.lua", "inksurf_torrent.lua" }) do
        if os.remove(sdir .. "/" .. old) then removed = removed + 1 end
    end
    if G_reader_settings then
        G_reader_settings:delSetting("bookfetch_ovpn")
        G_reader_settings:flush()
    end

    -- Clear in-memory settings so they are not written back
    self.data_dir = pluginDataDir()
    self.settings = LuaSettings:open(self.data_dir .. "/inksurf.lua")

    UIManager:show(InfoMessage:new{
        text = S("Kész. ") .. removed .. S(" fájl törölve.\n\n") ..
               S("Minden böngészőadat visszaállt alaphelyzetbe.\n") ..
               S("A plugin teljes eltávolításához töröld a mappát:\n") ..
               "koreader/plugins/inksurf.koplugin",
    })
end

-- Language selection -------------------------------------------------------------

function WebBrowser:setUiLang(lang)
    I18N.set(lang)
    self.settings:saveSetting("ui_lang", lang)
    self.settings:flush()
    local msg = ({
        en = "Language set to English.\nRestart KOReader to apply it everywhere.",
        hu = "Nyelv: magyar.\nA teljes érvényhez indítsd újra a KOReadert.",
        de = "Sprache: Deutsch.\nStarte KOReader neu, um alles zu übernehmen.",
    })[lang]
    UIManager:show(InfoMessage:new{ text = msg })
end

function WebBrowser:start()
    self:showHome()
end

-- Download directory ------------------------------------------------------------

function WebBrowser:downloadDir()
    local dir = self.settings:readSetting("download_dir")
    if not dir then
        if Device:isKindle() then
            dir = "/mnt/us/koreader/documents"
        else
            dir = (G_reader_settings:readSetting("home_dir") or DataStorage:getDataDir()) .. "/Downloads"
        end
    end
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    return dir
end

function WebBrowser:chooseDownloadDir()
    local ok, PathChooser = pcall(require, "ui/widget/pathchooser")
    if not ok then return end
    local chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        path = self:downloadDir(),
        onConfirm = function(dir_path)
            self.settings:saveSetting("download_dir", dir_path)
            self.settings:flush()
            self:showHome()
        end,
    }
    UIManager:show(chooser)
end

-- UI helpers ---------------------------------------------------------------

function WebBrowser:status(text)
    if self.msg then
        UIManager:close(self.msg)
        self.msg = nil
    end
    if text then
        self.msg = InfoMessage:new{ text = text }
        UIManager:show(self.msg)
        UIManager:forceRePaint()
    end
end

function WebBrowser:showError(err)
    self:status(nil)
    UIManager:show(InfoMessage:new{ text = S("Hiba:\n") .. tostring(err) })
end

function WebBrowser:ensureMenu(title, items)
    if self.menu then
        self.menu:switchItemTable(title, items, 1)
        return
    end
    self.menu = Menu:new{
        title = title,
        item_table = items,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        onMenuSelect = function(_menu, item)
            if item.callback then item.callback() end
            return true
        end,
        onMenuHold = function(_menu, item)
            if item.hold_callback then item.hold_callback() end
            return true
        end,
        close_callback = function() self:closeMenu() end,
    }
    UIManager:show(self.menu)
end

function WebBrowser:closeMenu()
    if self.menu then
        local m = self.menu
        self.menu = nil
        UIManager:close(m)
    end
end

-- Bookmarks --------------------------------------------------------------

function WebBrowser:getBookmarks()
    local b = self.settings:readSetting("bookmarks")
    if not b then
        b = {
            { title = S("DuckDuckGo (keresés)"), url = "https://lite.duckduckgo.com/lite/" },
            { title = S("Project Gutenberg"), url = "https://www.gutenberg.org/" },
            { title = S("Standard Ebooks"), url = "https://standardebooks.org/ebooks" },
        }
    end
    return b
end

function WebBrowser:saveBookmarks(bms)
    self.settings:saveSetting("bookmarks", bms)
    self.settings:flush()
end

function WebBrowser:addBookmark(page)
    local dlg
    dlg = InputDialog:new{
        title = S("Kedvencekhez adás – név"),
        input = page.title or page.url,
        buttons = {{
            { text = S("Mégse"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = S("Mentés"), is_enter_default = true, callback = function()
                local name = trim(dlg:getInputText() or "")
                UIManager:close(dlg)
                if name == "" then name = page.url end
                local bms = self:getBookmarks()
                table.insert(bms, { title = name, url = page.url })
                self:saveBookmarks(bms)
                UIManager:show(InfoMessage:new{ text = S("Kedvencekhez adva:\n") .. name, timeout = 2 })
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function WebBrowser:bookmarkActions(i)
    local bms = self:getBookmarks()
    local b = bms[i]
    if not b then return end
    local dlg
    dlg = ButtonDialog:new{
        title = b.title .. "\n" .. b.url,
        buttons = {
            {{ text = S("Megnyitás grafikusan"), callback = function()
                UIManager:close(dlg); self:go(b.url, { view = "graphic" })
            end }},
            {{ text = S("Megnyitás szövegesen"), callback = function()
                UIManager:close(dlg); self:go(b.url, { view = "text" })
            end }},
            {{ text = S("Átnevezés"), callback = function()
                UIManager:close(dlg)
                local inp
                inp = InputDialog:new{
                    title = S("Kedvenc átnevezése"),
                    input = b.title,
                    buttons = {{
                        { text = S("Mégse"), id = "close", callback = function() UIManager:close(inp) end },
                        { text = S("Mentés"), is_enter_default = true, callback = function()
                            local name = trim(inp:getInputText() or "")
                            UIManager:close(inp)
                            if name ~= "" then b.title = name; self:saveBookmarks(bms); self:showHome() end
                        end },
                    }},
                }
                UIManager:show(inp)
                inp:onShowKeyboard()
            end }},
            {{ text = S("Feljebb"), enabled = i > 1, callback = function()
                UIManager:close(dlg)
                bms[i], bms[i - 1] = bms[i - 1], bms[i]
                self:saveBookmarks(bms); self:showHome()
            end }},
            {{ text = S("Törlés"), callback = function()
                UIManager:close(dlg); self:deleteBookmark(i)
            end }},
        },
    }
    UIManager:show(dlg)
end

function WebBrowser:deleteBookmark(i)
    local bms = self:getBookmarks()
    UIManager:show(ConfirmBox:new{
        text = S("Törlöd ezt a kedvencet?\n") .. (bms[i] and bms[i].title or ""),
        ok_text = S("Törlés"),
        cancel_text = S("Mégse"),
        ok_callback = function()
            table.remove(bms, i)
            self.settings:saveSetting("bookmarks", bms)
            self.settings:flush()
            self:showHome()
        end,
    })
end

-- Screens ------------------------------------------------------------------

function WebBrowser:showHome()
    local items = {
        { text = S("» Cím vagy keresés…"), callback = function() self:askUrl() end },
    }
    if State.current then
        table.insert(items, { text = S("« Vissza az oldalra"), callback = function() self:display(State.current, State.current.view) end })
    end
    table.insert(items, { text = S("— Kedvencek (hosszan nyomva: átnevezés, sorrend, törlés) —") })
    for i, b in ipairs(self:getBookmarks()) do
        table.insert(items, {
            text = "★ " .. b.title,
            mandatory = hostOf(b.url),
            callback = function() self:go(b.url) end,
            hold_callback = function() self:bookmarkActions(i) end,
        })
    end
    table.insert(items, {
        text = VPN:isUp() and S("VPN: BE  (kikapcsolás)") or S("VPN: KI  (bekapcsolás)"),
        callback = function()
            if VPN:isUp() then VPN:down() else VPN:up() end
            self:showHome()
        end,
    })
    local n = Torrent:countActive()
    table.insert(items, {
        text = S("⇩ Torrent letöltések") .. (n > 0 and (" (" .. n .. " running)") or ""),
        callback = function() Torrent:showManager() end,
    })
    table.insert(items, {
        text = S("Letöltési mappa: ") .. self:downloadDir(),
        callback = function() self:chooseDownloadDir() end,
    })
    self:ensureMenu(S("Web böngésző – kedvencek"), items)
end

local VIEW_NAMES = { graphic = "graphical", text = S("szöveges") }

function WebBrowser:chooseView(page)
    local dlg
    local buttons = {
        {{ text = S("Grafikus (képekkel)"), callback = function()
            UIManager:close(dlg); self:display(page, "graphic")
        end }},
        {{ text = S("Szöveges linklista"), callback = function()
            UIManager:close(dlg); self:display(page, "text")
        end }},
    }
    if NetSurf:available() then
        table.insert(buttons, {{ text = S("NetSurf motor (JavaScript)"), callback = function()
            UIManager:close(dlg); NetSurf:run(page.url)
        end }})
    end
    dlg = ButtonDialog:new{ title = S("Nézet kiválasztása"), buttons = buttons }
    UIManager:show(dlg)
end

function WebBrowser:itemActions(page, it)
    local dlg
    local buttons = {}
    if it.url then
        table.insert(buttons, {{ text = S("Megnyitás"), callback = function()
            UIManager:close(dlg); self:go(it.url, { referer = page.url })
        end }})
        table.insert(buttons, {{ text = S("Megnyitás grafikusan"), callback = function()
            UIManager:close(dlg); self:go(it.url, { referer = page.url, view = "graphic" })
        end }})
    end
    if it.download then
        table.insert(buttons, {{ text = S("Letöltés"), callback = function()
            UIManager:close(dlg); self:go(it.download, { referer = page.url })
        end }})
    end
    if it.url then
        table.insert(buttons, {{ text = S("Mentés fájlként"), callback = function()
            UIManager:close(dlg); self:go(it.url, { referer = page.url, force_save = true })
        end }})
        table.insert(buttons, {{ text = S("Kedvencekhez"), callback = function()
            UIManager:close(dlg); self:addBookmark({ title = it.title, url = it.url })
        end }})
    end
    if #buttons == 0 then return end
    dlg = ButtonDialog:new{
        title = it.title .. (it.sub and ("\n" .. it.sub) or "") .. (it.meta and ("\n" .. it.meta) or ""),
        buttons = buttons,
    }
    UIManager:show(dlg)
end

local function short(s, n)
    if not s then return nil end
    if #s <= n then return s end
    return s:sub(1, n):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "") .. "…"
end

function WebBrowser:showPage(page)
    if not page.view or page.view == "graphic" then page.view = "text" end
    local items = {}
    if #State.history > 0 then
        table.insert(items, { text = S("« Vissza"), callback = function() self:back() end })
    end
    table.insert(items, { text = S("» Cím / keresés…"), callback = function() self:askUrl() end })
    table.insert(items, {
        text = S("◐ Nézet: ") .. (VIEW_NAMES[page.view] or page.view) .. S("  (váltás)"),
        callback = function() self:chooseView(page) end,
    })
    table.insert(items, { text = S("★ Kedvencekhez adás"), callback = function() self:addBookmark(page) end })
    table.insert(items, { text = S("⌂ Kedvencek / kezdőlap"), callback = function() self:showHome() end })

    table.insert(items, { text = S("≡ Oldal szövege"), callback = function() self:showText(page) end })
    for _i, form in ipairs(page.forms) do
        table.insert(items, {
            text = "[ " .. form.label .. " … ]",
            mandatory = form.method:upper(),
            callback = function() self:fillForm(page, form) end,
        })
    end
    for _i, link in ipairs(page.links) do
        table.insert(items, {
            text = link.text,
            mandatory = link.ext and link.ext:upper() or nil,
            callback = function() self:go(link.url, { referer = page.url }) end,
            hold_callback = function() self:linkActions(page, link) end,
        })
    end
    local title = page.title
    if page.code and page.code >= 400 then title = "HTTP " .. page.code .. " – " .. title end
    self:ensureMenu(title, items)
end

function WebBrowser:showText(page)
    UIManager:show(TextViewer:new{
        title = page.title,
        text = (page.text ~= "" and page.text) or S("(Az oldalon nincs megjeleníthető szöveg.)"),
    })
end

function WebBrowser:back()
    local prev = table.remove(State.history)
    if prev then
        State.current = prev
        self:display(prev, prev.view)
    else
        self:showHome()
    end
end

function WebBrowser:linkActions(page, link)
    local dlg
    dlg = ButtonDialog:new{
        title = link.url,
        buttons = {
            {{ text = S("Megnyitás"), callback = function()
                UIManager:close(dlg)
                self:go(link.url, { referer = page.url })
            end }},
            {{ text = S("Mentés fájlként (letöltés)"), callback = function()
                UIManager:close(dlg)
                self:go(link.url, { referer = page.url, force_save = true })
            end }},
            {{ text = S("Megnyitás grafikusan"), callback = function()
                UIManager:close(dlg)
                self:go(link.url, { referer = page.url, view = "graphic" })
            end }},
            {{ text = S("Megnyitás szövegesen"), callback = function()
                UIManager:close(dlg)
                self:go(link.url, { referer = page.url, view = "text" })
            end }},
            {{ text = S("Kedvencekhez"), callback = function()
                UIManager:close(dlg)
                self:addBookmark({ title = link.text, url = link.url })
            end }},
            NetSurf:available() and {{ text = S("Megnyitás NetSurfben (JavaScript)"), callback = function()
                UIManager:close(dlg)
                NetSurf:run(link.url)
            end }} or nil,
        },
    }
    UIManager:show(dlg)
end

function WebBrowser:askUrl()
    local dlg
    dlg = InputDialog:new{
        title = S("Cím vagy keresőszó"),
        input = State.current and State.current.url or "",
        input_hint = S("pl. example.com vagy keresőszavak"),
        buttons = {{
            { text = S("Mégse"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = S("Keresés"), callback = function()
                local t = trim(dlg:getInputText() or "")
                UIManager:close(dlg)
                if t ~= "" then self:go("https://lite.duckduckgo.com/lite/?q=" .. formEscape(t)) end
            end },
            { text = S("Megnyitás"), is_enter_default = true, callback = function()
                local t = trim(dlg:getInputText() or "")
                UIManager:close(dlg)
                if t == "" then return end
                if t:match("^%a[%w+.-]*://") then
                    self:go(t)
                elseif not t:find("%s") and t:find("%.") then
                    self:go("https://" .. t)
                else
                    self:go("https://lite.duckduckgo.com/lite/?q=" .. formEscape(t))
                end
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- Forms --------------------------------------------------------------------

function WebBrowser:fillForm(page, form)
    local editable = {}
    for _i, inp in ipairs(form.inputs) do
        if inp.editable then table.insert(editable, inp) end
    end
    if #editable == 0 then return self:submitForm(page, form) end
    local fields = {}
    for _i, inp in ipairs(editable) do
        table.insert(fields, { text = inp.value or "", hint = inp.hint, text_type = inp.password and "password" or nil })
    end
    local dlg
    dlg = MultiInputDialog:new{
        title = form.label,
        fields = fields,
        buttons = {{
            { text = S("Mégse"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = S("Küldés"), is_enter_default = true, callback = function()
                local vals = dlg:getFields()
                UIManager:close(dlg)
                for i, inp in ipairs(editable) do inp.value = vals[i] or "" end
                self:submitForm(page, form)
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function WebBrowser:submitForm(page, form)
    local parts = {}
    for _i, inp in ipairs(form.inputs) do
        table.insert(parts, formEscape(inp.name) .. "=" .. formEscape(inp.value))
    end
    if form.submit then
        table.insert(parts, formEscape(form.submit.name) .. "=" .. formEscape(form.submit.value))
    end
    local q = table.concat(parts, "&")
    local sent = { url = page.url, is_login = form.is_login, onsubmit = form.onsubmit }
    if form.method == "post" then
        self:go(form.action, { method = "POST", body = q, referer = page.url, form_submit = sent })
    else
        local a = form.action:gsub("[?#].*$", "")
        self:go(a .. "?" .. q, { referer = page.url, form_submit = sent })
    end
end

-- Network --------------------------------------------------------------------

local function baseDomain(host)
    return host:match("[^.]+%.[^.]+$") or host
end

function WebBrowser:storeCookies(host, set_cookie)
    if not set_cookie or host == "" then return end
    local key = baseDomain(host)
    local jar = State.cookies[key] or {}
    for name, value in (", " .. set_cookie):gmatch(",%s*([^=;,%s]+)=([^;,]*)") do
        jar[name] = value
    end
    State.cookies[key] = jar
end

function WebBrowser:cookieHeader(host)
    local jar = State.cookies[baseDomain(host)]
    if not jar then return nil end
    local parts = {}
    for k, v in pairs(jar) do table.insert(parts, k .. "=" .. v) end
    if #parts == 0 then return nil end
    return table.concat(parts, "; ")
end

function WebBrowser:request(target, opts)
    local method = opts.method or "GET"
    local body = opts.body
    local referer = opts.referer
    local tmp = opts.tmp or (self:downloadDir() .. "/.inksurf.part")
    for _redirect = 1, 10 do
        local host = hostOf(target)
        local headers = {
            ["user-agent"] = UA,
            ["accept"] = "text/html,application/xhtml+xml,*/*;q=0.8",
            ["accept-language"] = "hu,de;q=0.8,en;q=0.7",
        }
        local ck = self:cookieHeader(host)
        if ck then headers["cookie"] = ck end
        if referer then headers["referer"] = referer end
        State.auth = State.auth or {}
        if State.auth[host] then headers["authorization"] = State.auth[host] end
        if method == "POST" and referer then headers["origin"] = referer:match("^(%a+://[^/]+)") end
        local source
        if body then
            headers["content-type"] = "application/x-www-form-urlencoded"
            headers["content-length"] = tostring(#body)
            source = ltn12.source.string(body)
        end

        local f, ferr = io.open(tmp, "wb")
        if not f then return nil, ferr end
        local received, last = 0, 0
        local sink = function(chunk)
            if chunk then
                f:write(chunk)
                received = received + #chunk
                if not opts.quiet and received - last >= 1048576 then
                    last = received
                    self:status(S("Letöltés… ") .. fmtSize(received) .. "\n" .. target)
                end
            end
            return 1
        end

        if socketutil then
            pcall(function() socketutil:set_timeout(opts.block_timeout or 30, opts.total_timeout or -1) end)
        end
        local ok, code, resp_headers = pcall(function()
            return socket.skip(1, http.request{
                url = target,
                method = method,
                headers = headers,
                source = source,
                sink = sink,
                redirect = false,
            })
        end)
        if socketutil then pcall(function() socketutil:reset_timeout() end) end
        f:close()

        if not ok or type(code) ~= "number" then
            os.remove(tmp)
            return nil, tostring(code)
        end
        resp_headers = resp_headers or {}
        self:storeCookies(host, resp_headers["set-cookie"])

        local loc = resp_headers["location"]
        if code >= 300 and code < 400 and loc then
            referer = target
            target = url.absolute(target, trim(loc))
            if code == 303 or ((code == 301 or code == 302) and method == "POST") then
                method, body = "GET", nil
            end
        else
            return { code = code, headers = resp_headers, url = target, tmp = tmp }
        end
    end
    os.remove(tmp)
    return nil, S("Túl sok átirányítás.")
end

function WebBrowser:go(target, opts)
    opts = opts or {}
    -- The "fill in" links that replace forms in the graphical view
    local fidx = target:match("^https?://wbform%.invalid/(%d+)")
    if fidx then
        local pg = State.current
        local f = pg and pg.forms and pg.forms[tonumber(fidx)]
        if f then self:fillForm(pg, f) end
        return
    end
    local action
    if target:lower():match("^magnet:") then
        action = function() self:startTorrent(function() Torrent:addMagnet(target) end) end
    else
        action = function() self:load(target, opts) end
    end
    if NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(action)
    else
        action()
    end
end

function WebBrowser:load(target, opts)
    self:status(S("Betöltés…\n") .. target)
    local res, err = self:request(target, opts)
    if not res then return self:showError(err) end

    local ctype = (res.headers["content-type"] or ""):lower()
    local cdisp = res.headers["content-disposition"] or ""

    -- HTTP Basic authentication (the browser's own password prompt)
    if res.code == 401 then
        local wa = res.headers["www-authenticate"] or ""
        if wa:lower():find("basic", 1, true) then
            os.remove(res.tmp)
            self:status(nil)
            return self:askBasicAuth(target, opts, hostOf(res.url), wa:match('[rR][eE][aA][lL][mM]%s*=%s*"([^"]*)"'))
        end
    end

    -- .torrent -> aria2 in the background (long-pressing "Save as file" still saves the raw file)
    local fname = filenameFromDisposition(cdisp) or filenameFromUrl(res.url) or ""
    if not opts.force_save and res.code < 400
        and (ctype:find("bittorrent", 1, true) or fname:lower():match("%.torrent$")) then
        local f = io.open(res.tmp, "rb")
        local data = f and f:read("*a") or ""
        if f then f:close() end
        if data:sub(1, 1) == "d" then -- bencode dictionary = a real torrent file
            os.remove(res.tmp)
            self:status(nil)
            local name = fname:gsub("%.[tT][oO][rR][rR][eE][nN][tT]$", "")
            self:startTorrent(function() Torrent:addTorrent(data, name ~= "" and name or "torrent") end)
            return
        end
    end

    local is_html = not opts.force_save
        and not cdisp:lower():find("attachment", 1, true)
        and (ctype:find("html", 1, true) or (ctype == "" and sniffHtml(res.tmp)))

    if is_html then
        local f = io.open(res.tmp, "rb")
        local html = f and f:read("*a") or ""
        if f then f:close() end
        os.remove(res.tmp)
        -- Redirect (meta refresh / simple JS), e.g. after a successful login
        local redirect = findRedirect(html, res.url)
        if redirect and redirect ~= res.url and (opts.hops or 0) < 3 and not redirect:lower():match("^javascript:") then
            return self:load(redirect, {
                referer = res.url, hops = (opts.hops or 0) + 1, view = opts.view, form_submit = opts.form_submit,
            })
        end

        local ok, page = pcall(parsePage, html, res.url)
        if not ok then return self:showError(S("Az oldal feldolgozása nem sikerült: ") .. tostring(page)) end
        page.code = res.code
        page.html = html
        page.charset = ctype:match("charset=([%w%-_]+)")
            or html:sub(1, 4096):match("<[mM][eE][tT][aA][^>]-[cC][hH][aA][rR][sS][eE][tT]=[\"']?([%w%-_]+)")
            or "utf-8"


        if State.current then
            State.current.html = nil -- Memory: only keep the raw HTML of the current page
            table.insert(State.history, State.current)
            if #State.history > 30 then table.remove(State.history, 1) end
        end
        State.current = page
        self:status(nil)
        local view = opts.view or self:defaultView()
        local warn = opts.form_submit and self:loginFailureText(page, html, opts.form_submit)
        self:display(page, view)
        if warn then
            UIManager:scheduleIn(0.5, function() UIManager:show(InfoMessage:new{ text = warn }) end)
        end
    else
        if res.code >= 400 then
            os.remove(res.tmp)
            return self:showError("HTTP " .. res.code)
        end
        self:saveDownload(res, ctype, cdisp)
    end
end

function WebBrowser:askBasicAuth(target, opts, host, realm)
    local had = State.auth[host] ~= nil
    local dlg
    dlg = MultiInputDialog:new{
        title = S("Bejelentkezés: ") .. host .. (realm and ("\n" .. realm) or "")
            .. (had and S("\n(az előző adatok nem voltak jók)") or ""),
        fields = {
            { text = "", hint = S("Felhasználónév") },
            { text = "", hint = S("Jelszó"), text_type = "password" },
        },
        buttons = {{
            { text = S("Mégse"), id = "close", callback = function()
                UIManager:close(dlg)
                State.auth[host] = nil
            end },
            { text = S("Belépés"), is_enter_default = true, callback = function()
                local f = dlg:getFields()
                UIManager:close(dlg)
                State.auth[host] = "Basic " .. b64((f[1] or "") .. ":" .. (f[2] or ""))
                self:go(target, opts)
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- If submitting a form returns another page with a password field from the same site,
-- login probably failed: notify the user and show the page's error message.
function WebBrowser:loginFailureText(page, html, sent)
    if not sent.is_login then return nil end
    if hostOf(page.url) ~= hostOf(sent.url) then return nil end
    local still_login = false
    for _i, f in ipairs(page.forms or {}) do
        if f.is_login then still_login = true end
    end
    if not still_login then return nil end
    local msgs = {}
    pcall(function()
        local dom = H.parse(html)
        local sel = "[class*=error], [class*=alert], [class*=warning], [class*=invalid], [class*=message], "
            .. "[class*=hiba], [id*=error], [role=alert]"
        for _i, n in ipairs(H.select(dom, sel, 6)) do
            local t = H.text(n)
            if t ~= "" and #t < 300 then
                local dup = false
                for _j, m in ipairs(msgs) do if m == t then dup = true end end
                if not dup then msgs[#msgs + 1] = t end
            end
        end
    end)
    local scripts = 0
    for _ in html:gmatch("<[sS][cC][rR][iI][pP][tT]") do scripts = scripts + 1 end
    local text = S("A szerver újra a belépő oldalt adta vissza – a bejelentkezés nem sikerült.")
    if #msgs > 0 then
        text = text .. S("\n\nAz oldal üzenete:\n") .. table.concat(msgs, "\n")
    end
    text = text .. S("\n\nLehetséges okok:\n• hibás felhasználónév vagy jelszó")
    if sent.onsubmit or scripts > 0 then
        text = text .. S("\n• az oldal JavaScripttel küldi a belépést (ezt a böngésző nem tudja futtatni)")
    end
    text = text .. S("\n\nHa nem jutsz tovább, futtasd rá a PowerShell-elemzőt, és küldd el az eredményt.")
    return text
end

-- Reader view: extract the article at the given URL locally (without a third party)
-- and display it in the existing graphical view. Called by the NetSurf bar's reader icon.
function WebBrowser:openReaderView(target)
    if not target or target == "" or target == "about:welcome" then
        return self:showError(S("Nincs megnyitott cikk az olvasó nézethez."))
    end
    self:status(S("Olvasó nézet – letöltés…"))
    local res, err = self:request(target, {})
    if not res or not res.tmp then
        self:status(nil)
        return self:showError(S("Az oldal letöltése nem sikerült:\n") .. tostring(err))
    end
    local f = io.open(res.tmp, "rb")
    local html = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(res.tmp)
    self:status(S("Olvasó nézet – kivonatolás…"))
    local clean = Readability.clean(html, H)
    self:status(nil)
    if not clean then
        return self:showError(S("Nem sikerült cikket kivonatolni ebből az oldalból.\n(Lehet, hogy nem szöveges cikk.)"))
    end
    local ok, page = pcall(parsePage, clean, res.url)
    if not ok or not page then
        return self:showError(S("Megjelenítési hiba az olvasó nézetben."))
    end
    page.html = clean
    page.reader = true
    page.title = (page.title and page.title ~= "" and page.title) or S("Olvasó nézet")
    State.current = page
    self:display(page, "graphic")
end

function WebBrowser:display(page, view)
    page.view = view or page.view or self:defaultView()
    if page.view == "graphic" then
        self:openGraphic(page)
    else
        self:showPage(page)
    end
end

local IMG_EXT = {
    ["image/jpeg"] = "jpg", ["image/jpg"] = "jpg", ["image/pjpeg"] = "jpg", ["image/png"] = "png",
    ["image/gif"] = "gif", ["image/webp"] = "webp", ["image/svg+xml"] = "svg", ["image/bmp"] = "bmp",
}

function WebBrowser:cacheRoot()
    local root = self.data_dir .. "/cache"
    if lfs.attributes(root, "mode") ~= "directory" then lfs.mkdir(root) end
    return root
end

-- New directory for a page; delete old ones (beyond the 25 most recent)
function WebBrowser:newPageDir()
    local root = self:cacheRoot()
    local dirs = {}
    for f in lfs.dir(root) do
        if f:match("^p_%d+_%d+$") then table.insert(dirs, f) end
    end
    table.sort(dirs)
    local keep = {}
    if State.current and State.current.file then keep[State.current.file] = true end
    for i = 1, #dirs - 25 do
        local d = root .. "/" .. dirs[i]
        if not keep[d .. "/index.html"] then
            pcall(function() require("readhistory"):removeItemByPath(d .. "/index.html") end)
            os.execute("rm -rf '" .. d:gsub("'", "'\\''") .. "'")
            State.pages[d .. "/index.html"] = nil
        end
    end
    State.page_counter = (State.page_counter or 0) + 1
    local dir = string.format("%s/p_%d_%04d", root, os.time(), State.page_counter % 10000)
    lfs.mkdir(dir)
    return dir
end

function WebBrowser:fetchImage(img_url, dest_base, referer)
    local res = self:request(img_url, {
        referer = referer, tmp = dest_base .. ".part", quiet = true,
        block_timeout = 10, total_timeout = 30,
    })
    if not res then return nil end
    local ct = (res.headers["content-type"] or ""):lower():match("^[^;%s]+") or ""
    local ext = IMG_EXT[ct]
    if not ext then
        local e = (img_url:match("%.(%a%a%a%a?)$") or ""):lower()
        if e == "jpeg" then e = "jpg" end
        if ct:match("^image/") or e == "jpg" or e == "png" or e == "gif" or e == "webp" then ext = (e ~= "" and e) or "jpg" end
    end
    if res.code >= 400 or not ext then
        os.remove(res.tmp)
        return nil
    end
    local final = dest_base .. "." .. ext
    if not os.rename(res.tmp, final) then
        os.remove(res.tmp)
        return nil
    end
    return final:match("([^/]+)$")
end

-- Profile 1: graphical rendering with KOReader's own HTML engine
function WebBrowser:openGraphic(page)
    if page.file and lfs.attributes(page.file, "mode") == "file" then
        return self:openInReader(page.file)
    end
    if not page.html then
        -- Older page, HTML no longer retained: download it again
        return self:go(page.url, { view = "graphic" })
    end
    self:status(S("Oldal előkészítése…\n") .. page.url)
    local okp, dom = pcall(H.parse, page.html)
    if not okp then return self:showError(S("Az oldal feldolgozása nem sikerült: ") .. tostring(dom)) end
    local dir = self:newPageDir()
    local okr, path, err = pcall(Render.render, {
        dom = dom,
        page_url = page.url,
        title = page.title,
        charset = page.charset,
        out_dir = dir,
        images = self:imagesOn(),
        max_images = 40,
        fetch_image = function(u, base) return self:fetchImage(u, base, page.url) end,
        form_labels = (function()
            local t = {}
            for i, f in ipairs(page.forms or {}) do t[i] = f.label end
            return t
        end)(),
        progress = function(n, total) self:status(string.format(S("Képek betöltése… %d / %d"), n, total)) end,
    })
    self:status(nil)
    if not okr or not path then return self:showError(S("Megjelenítési hiba: ") .. tostring(okr and err or path)) end
    page.file = path
    State.pages[path] = page
    self:openInReader(path)
end

function WebBrowser:openInReader(path)
    self:closeMenu()
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance and ReaderUI.instance.switchDocument then
        local ok = pcall(function() ReaderUI.instance:switchDocument(path) end)
        if ok then return end
    end
    ReaderUI:showReader(path)
end

function WebBrowser:saveDownload(res, ctype, cdisp)
    local name = filenameFromDisposition(cdisp) or filenameFromUrl(res.url) or "download"
    if not name:match("%.[%w]+$") then
        local ext = EXT_BY_TYPE[ctype:match("^[^;%s]+") or ""]
        if ext then name = name .. "." .. ext end
    end
    name = safeName(name)

    local dir = self:downloadDir()
    local base, ext = name:match("^(.-)(%.[%w]+)$")
    if not base or base == "" then base, ext = name, "" end
    local path = dir .. "/" .. name
    local n = 1
    while lfs.attributes(path, "mode") do
        path = string.format("%s/%s (%d)%s", dir, base, n, ext)
        n = n + 1
    end

    local ok, e = os.rename(res.tmp, path)
    if not ok then
        os.remove(res.tmp)
        return self:showError(S("Mentés sikertelen: ") .. tostring(e))
    end
    self:status(nil)

    pcall(function()
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then FileManager.instance:onRefresh() end
    end)

    local size = lfs.attributes(path, "size") or 0
    local text = S("Letöltve (") .. fmtSize(size) .. "):\n" .. path
    if DocumentRegistry:hasProvider(path) then
        UIManager:show(ConfirmBox:new{
            text = text .. "\n\nOpen it now?",
            ok_text = S("Megnyitás"),
            cancel_text = S("Később"),
            ok_callback = function()
                self:closeMenu()
                require("apps/reader/readerui"):showReader(path)
            end,
        })
    else
        -- Unsupported format: if it belongs to the azw3/mobi family AND a converter is available, convert to EPUB
        local dlext = (path:match("%.([%w]+)$") or ""):lower()
        if MOBI_FAMILY[dlext] and hasConverter() then
            UIManager:show(ConfirmBox:new{
                text = text .. S("\n\nEzt a KOReader nem nyitja meg közvetlenül.\nÁtalakítsam EPUB-ba és megnyissam?\n(Az eredeti fájl a sikeres konvertálás után törlődik.)"),
                ok_text = S("Konvertálás"),
                cancel_text = S("Később"),
                ok_callback = function()
                    self:status(S("Konvertálás EPUB-ba…"))
                    local epub, err = convertToEpub(path)
                    self:status(nil)
                    if epub then
                        self:closeMenu()
                        require("apps/reader/readerui"):showReader(epub)
                    else
                        self:showError(err or S("A konverzió nem sikerült."))
                    end
                end,
            })
        else
            UIManager:show(InfoMessage:new{
                text = text .. S("\n\n(Ezt a formátumot a KOReader nem nyitja meg, de a fájl el van mentve.)"),
            })
        end
    end
end

-- NetSurf favorites (stored in settings: a list of {title, url} pairs)
function WebBrowser:getNetsurfFavorites()
    local f = self.settings:readSetting("netsurf_favorites")
    if type(f) ~= "table" then f = {} end
    return f
end

function WebBrowser:saveNetsurfFavorites(f)
    self.settings:saveSetting("netsurf_favorites", f)
    self.settings:flush()
end

-- NetSurf history submenu (last 5 unique visited URLs)
function WebBrowser:netsurfHistoryMenu()
    local items = {}
    local list = NetSurf:historyList(5)
    if #list == 0 then
        items[#items + 1] = { text = S("Nincs előzmény"), enabled = false }
        return items
    end
    for _, u in ipairs(list) do
        local label = u:gsub("^https?://", ""):gsub("/+$", "")
        if #label > 48 then label = label:sub(1, 47) .. "…" end
        items[#items + 1] = {
            text = label,
            callback = function() NetSurf:run(u) end,
        }
    end
    items[#items + 1] = {
        text = S("— Előzmények törlése —"),
        separator = true,
        keep_menu_open = true,
        callback = function()
            NetSurf:historyClear()
            UIManager:show(InfoMessage:new{ text = S("Előzmények törölve."), timeout = 2 })
        end,
    }
    return items
end

-- Help / About
local HELP_TEXT = {
    hu = table.concat({
        "InkSurf böngésző – súgó / névjegy",
        "==================================",
        "",
        "Motor: NetSurf (framebuffer, korlátozott JavaScript).",
        "",
        "Cím megnyitása: webcím beírása a NetSurf motorban.",
        "Keresés a weben: DuckDuckGo, a NetSurf motorban nyílik.",
        "",
        "NETSURF MOTOR (JavaScriptes oldalakhoz)",
        "• Saját felső sáv: ◀ vissza, ▶ előre, ⟳ újratöltés, középen",
        "  az URL, jobbra _ (minimalizál) és ✕ (bezár).",
        "• Az URL-sorra koppintva a KOReader billentyűzete jön fel",
        "  (ékezetekkel); cím vagy keresőszó is lehet.",
        "• _ : a böngésző a háttérben marad; a „Folytatás” ponttal",
        "  ugyanott folytatod. ✕ : bezárás (új munkamenet).",
        "• A felső élről lefelé húzva is minimalizál.",
        "• Két ujjal csippentés: nagyítás; rázoomolva húzással mozgatható.",
        "• Előzmények: az utolsó 5 látogatott cím.",
        "",
        "LETÖLTÉSEK",
        "• A letöltött fájlok a Beállítások → Letöltési mappába kerülnek",
        "  (alapértelmezés: koreader/documents).",
        "• A KOReader által nem támogatott formátum (pl. azw3) a sikeres",
        "  EPUB-konvertálás után törlődik (csak az EPUB marad).",
        "• .torrent: átadás a torrentkezelőnek, a .torrent nem halmozódik.",
        "",
        "VPN (OpenVPN)",
        "• Tedd a .ovpn fájl(oka)t a plugin vpn/ mappájába (bármely",
        "  szolgáltató: Express, Nord, stb.).",
        "• Szerverenként külön belépési adat: a kiválasztott szerverhez",
        "  mentve (NordVPN: a „szolgáltatási” hitelesítő adatok).",
        "• Kill switch + DNS-védelem; kikapcsolás után a net visszaáll.",
        "",
        "TIPP: a böngészőt a Beállításokban és a főmenüből éred el.",
    }, "\n"),
    en = table.concat({
        "InkSurf browser – help / about",
        "==============================",
        "",
        "Engine: NetSurf (framebuffer, limited JavaScript).",
        "",
        "Open address: type a web address into the NetSurf engine.",
        "Search the web: DuckDuckGo, opens in the NetSurf engine.",
        "",
        "NETSURF ENGINE (for JavaScript pages)",
        "• Own top bar: ◀ back, ▶ forward, ⟳ reload, URL in the",
        "  middle, _ (minimize) and ✕ (close) on the right.",
        "• Tap the URL bar to bring up the KOReader keyboard",
        "  (with accents); it takes an address or a search term.",
        "• _ : the browser stays in the background; resume right",
        "  where you left off via “Resume”. ✕ : close (new session).",
        "• Dragging down from the top edge also minimizes.",
        "• Two-finger pinch: zoom; when zoomed, drag to pan.",
        "• History: the last 5 visited addresses.",
        "",
        "DOWNLOADS",
        "• Downloaded files go to Settings → Download folder",
        "  (default: koreader/documents).",
        "• A format KOReader can't open (e.g. azw3) is deleted after",
        "  a successful EPUB conversion (only the EPUB remains).",
        "• .torrent: handed to the torrent manager; .torrents don't pile up.",
        "",
        "VPN (OpenVPN)",
        "• Put your .ovpn file(s) into the plugin's vpn/ folder (any",
        "  provider: Express, Nord, etc.).",
        "• Separate credentials per server: saved for the selected",
        "  server (NordVPN: the “service” credentials).",
        "• Kill switch + DNS protection; the net is restored after turning off.",
        "",
        "TIP: reach the browser from Settings and from the main menu.",
    }, "\n"),
    de = table.concat({
        "InkSurf-Browser – Hilfe / Info",
        "==============================",
        "",
        "Engine: NetSurf (Framebuffer, eingeschränktes JavaScript).",
        "",
        "Adresse öffnen: Webadresse in der NetSurf-Engine eingeben.",
        "Im Web suchen: DuckDuckGo, öffnet in der NetSurf-Engine.",
        "",
        "NETSURF-ENGINE (für JavaScript-Seiten)",
        "• Eigene obere Leiste: ◀ zurück, ▶ vor, ⟳ neu laden, URL in",
        "  der Mitte, _ (minimieren) und ✕ (schließen) rechts.",
        "• Tippe auf die URL-Leiste für die KOReader-Tastatur",
        "  (mit Umlauten); Adresse oder Suchbegriff möglich.",
        "• _ : der Browser bleibt im Hintergrund; mit „Fortsetzen“",
        "  genau dort weiter. ✕ : schließen (neue Sitzung).",
        "• Vom oberen Rand nach unten ziehen minimiert ebenfalls.",
        "• Zwei-Finger-Pinch: zoomen; im Zoom durch Ziehen verschieben.",
        "• Verlauf: die letzten 5 besuchten Adressen.",
        "",
        "DOWNLOADS",
        "• Heruntergeladene Dateien landen unter Einstellungen → Download-Ordner",
        "  (Standard: koreader/documents).",
        "• Ein von KOReader nicht unterstütztes Format (z. B. azw3) wird nach",
        "  erfolgreicher EPUB-Konvertierung gelöscht (nur das EPUB bleibt).",
        "• .torrent: wird dem Torrent-Manager übergeben; .torrents sammeln sich nicht an.",
        "",
        "VPN (OpenVPN)",
        "• Lege deine .ovpn-Datei(en) in den vpn/-Ordner des Plugins (beliebiger",
        "  Anbieter: Express, Nord, usw.).",
        "• Eigene Zugangsdaten pro Server: für den gewählten Server",
        "  gespeichert (NordVPN: die „Service“-Zugangsdaten).",
        "• Kill-Switch + DNS-Schutz; nach dem Ausschalten wird das Netz wiederhergestellt.",
        "",
        "TIPP: Den Browser erreichst du über Einstellungen und das Hauptmenü.",
    }, "\n"),
}

function WebBrowser:showHelp()
    local text = HELP_TEXT[I18N.get()] or HELP_TEXT.en
    UIManager:show(TextViewer:new{ title = S("InkSurf – súgó"), text = text })
end

function WebBrowser:netsurfFavoritesMenu()
    local items = {}
    items[#items + 1] = {
        text = S("➕ Hozzáadás…"),
        separator = true,
        callback = function()
            local dlg
            dlg = MultiInputDialog:new{
                title = S("Kedvenc hozzáadása"),
                fields = {
                    { description = S("Név (opcionális)"), text = "" },
                    { description = "URL", text = "https://" },
                },
                buttons = {{
                    { text = S("Mégse"), callback = function() UIManager:close(dlg) end },
                    { text = S("Mentés"), callback = function()
                        local vals = dlg:getFields()
                        UIManager:close(dlg)
                        local title = trim(vals[1] or "")
                        local u = trim(vals[2] or "")
                        if u ~= "" and u ~= "https://" then
                            local favs = self:getNetsurfFavorites()
                            favs[#favs + 1] = { title = (title ~= "" and title or u), url = u }
                            self:saveNetsurfFavorites(favs)
                        end
                    end },
                }},
            }
            UIManager:show(dlg)
        end,
    }
    local favs = self:getNetsurfFavorites()
    if #favs == 0 then
        items[#items + 1] = { text = S("(nincs még kedvenc)"), enabled = false }
    else
        for i, fav in ipairs(favs) do
            items[#items + 1] = {
                text = fav.title or fav.url,
                callback = function() NetSurf:run(fav.url) end,
                hold_callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = S("Törlöd ezt a kedvencet?\n") .. (fav.title or fav.url),
                        ok_text = S("Törlés"), cancel_text = S("Mégse"),
                        ok_callback = function()
                            local list = self:getNetsurfFavorites()
                            table.remove(list, i)
                            self:saveNetsurfFavorites(list)
                        end,
                    })
                end,
            }
        end
    end
    return items
end

-- Handle files downloaded in NetSurf after exiting: open / convert to EPUB
-- Open KOReader's top menu (by swiping down from the browser's top edge).
-- Version-independent best effort: try known methods on the menu object.
function WebBrowser:openKoreaderTopMenu()
    pcall(function()
        local ui = self.ui
        local menu = ui and ui.menu
        if not menu then return end
        local tries = { "onShowMenu", "onTapShowMenu", "onShowReaderMenu", "showMenu" }
        for _, m in ipairs(tries) do
            if type(menu[m]) == "function" then
                menu[m](menu)
                return
            end
        end
    end)
end

-- Completed files that KOReader CANNOT open: if any belong to the MOBI family
-- (azw3/mobi/…) and a converter is available, offer conversion to EPUB; otherwise
-- just report that they were saved. Shared path for NetSurf downloads and torrents.
function WebBrowser:offerConvertOrSaved(paths)
    if not paths or #paths == 0 then return end
    local target
    for _, p in ipairs(paths) do
        local ext = (p:match("%.([%w]+)$") or ""):lower()
        if MOBI_FAMILY[ext] then target = p; break end
    end
    if target and hasConverter() then
        UIManager:show(ConfirmBox:new{
            text = target .. S("\n\nEzt a KOReader nem nyitja meg közvetlenül.\nÁtalakítsam EPUB-ba és megnyissam?\n(Az eredeti fájl a sikeres konvertálás után törlődik.)"),
            ok_text = S("Konvertálás"), cancel_text = S("Később"),
            ok_callback = function()
                self:status(S("Konvertálás EPUB-ba…"))
                local epub, err = convertToEpub(target)
                self:status(nil)
                if epub then
                    require("apps/reader/readerui"):showReader(epub)
                else
                    self:showError(err or S("A konverzió nem sikerült."))
                end
            end,
        })
    else
        UIManager:show(InfoMessage:new{ text = (paths[#paths] or "") .. S("\n\n(A fájl el van mentve.)") })
    end
end

function WebBrowser:handleNetsurfDownloads(paths)
    if not paths or #paths == 0 then return end

    -- Do NOT open .torrent files; pass them to aria2, then delete them
    local rest = {}
    for _, p in ipairs(paths) do
        if (p:match("%.([%w]+)$") or ""):lower() == "torrent" then
            local f = io.open(p, "rb")
            local data = f and f:read("*a") or nil
            if f then f:close() end
            if data and data ~= "" then
                local name = (p:match("([^/]+)$") or "torrent")
                self:startTorrent(function() Torrent:addTorrent(data, name) end)
            end
            os.remove(p)   -- Prevent .torrent files from accumulating
        else
            rest[#rest + 1] = p
        end
    end
    if #rest == 0 then return end
    paths = rest

    local path = paths[#paths]
    local extra = #paths - 1
    local size = lfs.attributes(path, "size") or 0
    local text = S("Letöltve (") .. fmtSize(size) .. "):\n" .. path
    if extra > 0 then text = text .. "\n(+" .. extra .. S(" további fájl a letöltési mappában)") end
    if DocumentRegistry:hasProvider(path) then
        UIManager:show(ConfirmBox:new{
            text = text .. "\n\nOpen it now?",
            ok_text = S("Megnyitás"), cancel_text = S("Később"),
            ok_callback = function() require("apps/reader/readerui"):showReader(path) end,
        })
    else
        local dlext = (path:match("%.([%w]+)$") or ""):lower()
        if MOBI_FAMILY[dlext] and hasConverter() then
            UIManager:show(ConfirmBox:new{
                text = text .. S("\n\nEzt a KOReader nem nyitja meg közvetlenül.\nÁtalakítsam EPUB-ba és megnyissam?\n(Az eredeti fájl a sikeres konvertálás után törlődik.)"),
                ok_text = S("Konvertálás"), cancel_text = S("Később"),
                ok_callback = function()
                    self:status(S("Konvertálás EPUB-ba…"))
                    local epub, err = convertToEpub(path)
                    self:status(nil)
                    if epub then
                        require("apps/reader/readerui"):showReader(epub)
                    else
                        self:showError(err or S("A konverzió nem sikerült."))
                    end
                end,
            })
        else
            UIManager:show(InfoMessage:new{ text = text .. S("\n\n(A fájl el van mentve.)") })
        end
    end
end

return WebBrowser
