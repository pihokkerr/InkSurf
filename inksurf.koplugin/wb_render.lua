--[[
Profile 1 – general graphical rendering.
Convert the downloaded page to a cleaned HTML file (with images), rendered by
KOReader's own engine (crengine). Links are given absolute URLs so that tapping
them shows the "Open in browser" button in KOReader's link dialog.
]]

local H = package.loaded["inksurf_html"]
    or dofile(((debug.getinfo(1, "S").source or ""):match("^@(.*/)") or "") .. "wb_html.lua")
local url = require("socket.url")

local R = {}

local function set(list)
    local t = {}
    for w in list:gmatch("%S+") do t[w] = true end
    return t
end

-- elements omitted entirely
local DROP = set("script style link meta base iframe frame frameset object embed applet canvas video audio "
    .. "template svg math input select textarea button head dialog map")
-- only the contents of these elements are needed
local UNWRAP = set("html body noscript font center span label picture")
-- add a space after these elements so adjacent text does not run together without CSS
local SPACE_AFTER = set("span label")
local KEEP_ATTRS = set("id name colspan rowspan title lang dir")

local function escAttr(v)
    return (v:gsub("&", "&amp;"):gsub('"', "&quot;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function escText(v)
    return (v:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function isHidden(a)
    if a.hidden ~= nil then return true end
    if a["aria-hidden"] == "true" then return true end
    local st = a.style
    if st then
        st = st:lower():gsub("%s", "")
        if st:find("display:none", 1, true) or st:find("visibility:hidden", 1, true) then return true end
    end
    return false
end

-- Parameters:
--   dom, page_url, title, charset
--   out_dir: destination for index.html and images
--   images: download images (bool), max_images
--   fetch_image(abs_url, dest_base) -> filename (dest_base + extension) or nil
--   progress(n, total): optional
function R.render(o)
    local out = {}
    local function emit(s) out[#out + 1] = s end
    local img_count, img_cache = 0, {}
    local form_idx = 0
    local base = o.page_url

    -- estimate the image count in advance for the progress indicator
    local total_imgs = 0
    if o.images then
        total_imgs = math.min(#H.select(o.dom, "img"), o.max_images or 40)
    end

    local function absolutize(href)
        href = href:match("^%s*(.-)%s*$")
        if href == "" then return nil end
        if href:sub(1, 1) == "#" then return href end
        local l = href:lower()
        if l:match("^javascript:") or l:match("^data:") then return nil end
        return url.absolute(base, href)
    end

    local function emitImg(a)
        local src = a["data-src"] or a["data-lazy-src"] or a["data-original"] or a["data-url"] or a.src
        local alt = a.alt and a.alt ~= "" and a.alt or nil
        if not src or src == "" then
            if alt then emit("[" .. escText(alt) .. "]") end
            return
        end
        if src:sub(1, 5):lower() == "data:" then
            -- embedded image (often just a 1x1 placeholder) – skip it
            if alt then emit("[" .. escText(alt) .. "]") end
            return
        end
        if not o.images or img_count >= (o.max_images or 40) then
            if alt then emit("[" .. escText(alt) .. "]") end
            return
        end
        local abs = url.absolute(base, src)
        local fname = img_cache[abs]
        if fname == nil then
            img_count = img_count + 1
            if o.progress then pcall(o.progress, img_count, total_imgs) end
            fname = o.fetch_image(abs, o.out_dir .. "/img" .. img_count) or false
            img_cache[abs] = fname
        end
        if fname then
            emit('<img src="' .. escAttr(fname) .. '"' .. (alt and (' alt="' .. escAttr(alt) .. '"') or "") .. ">")
        elseif alt then
            emit("[" .. escText(alt) .. "]")
        end
    end

    local function walk(node)
        for _i, ch in ipairs(node.children) do
            if ch.text then
                if node.tag ~= "title" then emit(ch.text) end
            else
                local t, a = ch.tag, ch.attrs
                if DROP[t] or isHidden(a) then
                    -- omitted
                elseif t == "form" then
                    -- form fields do not work here: replace them with a "fill in" link
                    -- that opens the browser's form dialog
                    form_idx = form_idx + 1
                    local label = o.form_labels and o.form_labels[form_idx]
                    if label then
                        emit('<p><a href="https://wbform.invalid/' .. form_idx .. '"><b>[ ✎ ' .. escText(label)
                            .. ' – tap here to fill in ]</b></a></p>')
                    end
                    walk(ch)
                elseif UNWRAP[t] then
                    walk(ch)
                    if SPACE_AFTER[t] then emit(" ") end
                elseif t == "img" then
                    emitImg(a)
                else
                    local parts = { "<" .. t }
                    if t == "a" and a.href then
                        local href = absolutize(a.href)
                        if href then parts[#parts + 1] = ' href="' .. escAttr(href) .. '"' end
                    end
                    for k, v in pairs(a) do
                        if KEEP_ATTRS[k] then parts[#parts + 1] = " " .. k .. '="' .. escAttr(v) .. '"' end
                    end
                    emit(table.concat(parts) .. ">")
                    if not H.VOID[t] then
                        walk(ch)
                        emit("</" .. t .. ">")
                    end
                end
            end
        end
    end

    walk(o.dom)

    local charset = o.charset or "utf-8"
    local doc = table.concat{
        "<!DOCTYPE html>\n<html><head>",
        '<meta http-equiv="Content-Type" content="text/html; charset=', escAttr(charset), '">',
        "<title>", escText(o.title or base), "</title>",
        "<style>",
        "body{margin:0.4em;line-height:1.3}",
        "img{max-width:100%}",
        "table{border-collapse:collapse}",
        "td,th{padding:0.15em 0.3em;vertical-align:top}",
        "a{text-decoration:underline}",
        ".wbhdr{font-size:70%;color:#555;border-bottom:1px solid #999;margin-bottom:0.5em;word-break:break-all}",
        "</style></head><body>",
        '<div class="wbhdr">', escText(base), "</div>",
        table.concat(out),
        "</body></html>",
    }
    local path = o.out_dir .. "/index.html"
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    f:write(doc)
    f:close()
    return path
end

return R
