--[[
Local "reader view" – extract the main article body WITHOUT third parties.
Input: raw HTML + the wb_html module (H). Output: cleaned HTML
(title + article), rendered by the existing renderer. Heuristic scoring:
select the block containing the most paragraph text, penalizing link-heavy
(menu/footer) blocks.
]]

local Readability = {}

local DROP = {
    script = true, style = true, nav = true, header = true, footer = true,
    aside = true, form = true, iframe = true, noscript = true, svg = true,
    button = true, select = true, head = true, template = true, input = true,
    object = true, embed = true, video = true, audio = true,
}
local KEEP = {
    h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
    p = true, ul = true, ol = true, li = true, blockquote = true, pre = true,
    code = true, br = true, hr = true, strong = true, b = true, em = true,
    i = true, u = true, a = true, img = true, figure = true, figcaption = true,
    table = true, thead = true, tbody = true, tr = true, td = true, th = true,
}
local BLOCKCAND = { div = true, article = true, section = true, main = true, td = true }

local function escAttr(v)
    return (tostring(v):gsub('[&"<>]', { ["&"] = "&amp;", ['"'] = "&quot;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

-- total text length of a node and text length of the links it contains
local function measure(H, node)
    local t = #(H.text(node) or "")
    local lt = 0
    local links = H.select(node, "a", 2000) or {}
    for _, a in ipairs(links) do lt = lt + #(H.text(a) or "") end
    return t, lt
end

-- find the block containing the most article text
local function findArticle(H, root)
    local best, bestScore = nil, 0
    local function walk(node)
        if node.tag and BLOCKCAND[node.tag] then
            local t, lt = measure(H, node)
            if t > 160 then
                local np = #(H.select(node, "p", 1000) or {})
                local score = (t - lt) + np * 30
                if t > 0 and (lt / t) > 0.5 then score = score * 0.25 end  -- penalize link-heavy blocks
                if score > bestScore then best, bestScore = node, score end
            end
        end
        for _, ch in ipairs(node.children or {}) do
            if ch.tag then walk(ch) end
        end
    end
    walk(root)
    return best
end

-- convert the selected block to cleaned HTML (using an allowlist)
local function emit(node, out)
    if node.text then
        out[#out + 1] = node.text        -- raw text (with entities) is valid as HTML
        return
    end
    local tag = node.tag
    if not tag or DROP[tag] then return end
    if tag == "img" then
        local src = node.attrs and (node.attrs.src or node.attrs["data-src"])
        if src and src ~= "" then out[#out + 1] = '<img src="' .. escAttr(src) .. '"/>' end
        return
    end
    if tag == "a" then
        local href = node.attrs and node.attrs.href
        local has = href and href ~= ""
        if has then out[#out + 1] = '<a href="' .. escAttr(href) .. '">' end
        for _, ch in ipairs(node.children or {}) do emit(ch, out) end
        if has then out[#out + 1] = "</a>" end
        return
    end
    if KEEP[tag] then
        out[#out + 1] = "<" .. tag .. ">"
        for _, ch in ipairs(node.children or {}) do emit(ch, out) end
        out[#out + 1] = "</" .. tag .. ">"
    else
        for _, ch in ipairs(node.children or {}) do emit(ch, out) end
    end
end

-- html: raw HTML; H: the wb_html module. Returns: cleaned HTML or nil.
function Readability.clean(html, H)
    if not html or html == "" then return nil end
    local ok, root = pcall(H.parse, html)
    if not ok or not root then return nil end

    local title = H.text(H.first(root, "h1"))
    if not title or title == "" then title = H.text(H.first(root, "title")) end

    local body = findArticle(H, root)
    if not body then
        body = H.first(root, "article") or H.first(root, "main") or H.first(root, "body") or root
    end

    local out = {}
    for _, ch in ipairs(body.children or {}) do emit(ch, out) end
    local inner = table.concat(out)

    -- if the extracted text is too short, it is probably not an article
    local plain = inner:gsub("<[^>]*>", "")
    if #plain < 200 then return nil end

    return table.concat({
        '<html><head><meta charset="utf-8"></head><body>',
        (title and title ~= "") and ("<h1>" .. escAttr(title) .. "</h1>") or "",
        inner,
        "</body></html>",
    })
end

return Readability
