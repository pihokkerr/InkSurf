--[[
Simple HTML -> DOM parser and CSS selector engine (without external dependencies).

Supported selectors:
  tag  *  #id  .class  [attr]  [attr=v]  [attr^=v]  [attr$=v]  [attr*=v]  [attr~=v]  :contains(text)
  compound:  div.item > a.title   (space = descendant, > = direct child)
  comma-separated alternatives:  h2 a, h3 a
Extraction:  "selector@attr"  (e.g. "a.link@href"),  "@href" (the element itself),  "." (the element's own text)
]]

local H = {}

local function set(list)
    local t = {}
    for w in list:gmatch("%S+") do t[w] = true end
    return t
end

local VOID = set("area base br col embed hr img input link meta param source track wbr")
local RAW = set("script style textarea title xmp")
local SCOPE = set("ul ol table dl select body html")
local CLOSES_P = set("p div ul ol table dl h1 h2 h3 h4 h5 h6 form pre blockquote section article header footer nav aside hr figure main")
local AUTOCLOSE = {
    li = set("li"),
    dt = set("dt dd"), dd = set("dt dd"),
    tr = set("tr td th"),
    td = set("td th"), th = set("td th"),
    option = set("option"),
    thead = set("thead tbody tfoot tr td th"), tbody = set("thead tbody tfoot tr td th"), tfoot = set("thead tbody tfoot tr td th"),
}
H.VOID = VOID

---------------------------------------------------------------------------
-- Entities
---------------------------------------------------------------------------

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

local ENT = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
    ndash = "–", mdash = "—", hellip = "…", laquo = "«", raquo = "»", copy = "©",
    bdquo = "„", rdquo = "”", ldquo = "“", rsquo = "’", lsquo = "‘", middot = "·",
    times = "×", rarr = "→", larr = "←", bull = "•", reg = "®", trade = "™",
}

function H.decode(s)
    if not s or not s:find("&", 1, true) then return s end
    s = s:gsub("&#[xX](%x+);", function(h) return utf8char(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return utf8char(tonumber(d)) end)
    s = s:gsub("&(%a+);", function(n) return ENT[n] end)
    return s
end

---------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------

local function parseAttrs(s)
    local attrs = {}
    local i, n = 1, #s
    while i <= n do
        local _s, e, name = s:find("^[%s/]*([^%s=/>\"']+)", i)
        if not name then break end
        i = e + 1
        local val = ""
        local _s2, e2 = s:find("^%s*=%s*", i)
        if e2 then
            i = e2 + 1
            local c = s:sub(i, i)
            if c == '"' or c == "'" then
                local close = s:find(c, i + 1, true)
                if close then
                    val = s:sub(i + 1, close - 1)
                    i = close + 1
                else
                    val = s:sub(i + 1)
                    i = n + 1
                end
            else
                local _s3, e3, v = s:find("^([^%s>]+)", i)
                if v then
                    val = v
                    i = e3 + 1
                end
            end
        end
        name = name:lower()
        if attrs[name] == nil then attrs[name] = H.decode(val) end
    end
    return attrs
end

-- return the end of the tag, skipping ">" characters inside quoted attribute values
local function tagEnd(html, i)
    local j = i
    while true do
        local p, _e, c = html:find("([\"'>])", j)
        if not p then return nil end
        if c == ">" then return p end
        local close = html:find(c, p + 1, true)
        if not close then return html:find(">", p + 1, true) end
        j = close + 1
    end
end

local function ci(s)
    return (s:gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end))
end

function H.parse(html)
    local root = { tag = "#root", attrs = {}, children = {} }
    local stack = { root }
    local pos, len = 1, #html

    local function cur() return stack[#stack] end
    local function addText(t)
        if t ~= "" then
            local p = cur()
            table.insert(p.children, { text = t, parent = p })
        end
    end
    local function closeFrom(i)
        for j = #stack, i, -1 do stack[j] = nil end
    end

    while pos <= len do
        local lt = html:find("<", pos, true)
        if not lt then
            addText(html:sub(pos))
            break
        end
        if lt > pos then addText(html:sub(pos, lt - 1)) end
        local nxt = html:sub(lt + 1, lt + 1)
        if html:sub(lt, lt + 3) == "<!--" then
            local e = html:find("-->", lt + 4, true)
            pos = e and e + 3 or len + 1
        elseif nxt == "!" or nxt == "?" then
            local e = html:find(">", lt, true)
            pos = e and e + 1 or len + 1
        elseif nxt == "/" then
            local _s, e, name = html:find("^</%s*([%w:%-]+)[^>]*>", lt)
            if not e then
                addText("<")
                pos = lt + 1
            else
                name = name:lower()
                pos = e + 1
                for i = #stack, 2, -1 do
                    if stack[i].tag == name then
                        closeFrom(i)
                        break
                    end
                end
            end
        else
            local name = html:match("^<([%a][%w:%-]*)", lt)
            if not name then
                addText("<")
                pos = lt + 1
            else
                local te = tagEnd(html, lt + 1 + #name)
                if not te then
                    addText(html:sub(lt))
                    break
                end
                local attrstr = html:sub(lt + 1 + #name, te - 1)
                pos = te + 1
                name = name:lower()

                -- implicit closing tags (e.g. a new <li> closes the previous one)
                local ac = AUTOCLOSE[name]
                if ac or CLOSES_P[name] then
                    local idx
                    for i = #stack, 2, -1 do
                        local t = stack[i].tag
                        if (ac and ac[t]) or (CLOSES_P[name] and t == "p") then idx = i end
                        if SCOPE[t] then break end
                    end
                    if idx then closeFrom(idx) end
                end

                local parent = cur()
                local node = { tag = name, attrs = parseAttrs(attrstr), children = {}, parent = parent }
                table.insert(parent.children, node)

                if RAW[name] then
                    local cs, ce = html:find("</%s*" .. ci(name) .. "%s*>", pos)
                    local content = html:sub(pos, (cs or len + 1) - 1)
                    if content ~= "" then
                        table.insert(node.children, { text = content, parent = node })
                    end
                    pos = ce and ce + 1 or len + 1
                elseif not VOID[name] and not attrstr:match("/%s*$") then
                    table.insert(stack, node)
                end
            end
        end
    end
    return root
end

---------------------------------------------------------------------------
-- Text
---------------------------------------------------------------------------

local SKIP_TEXT = set("script style head title template noscript")
-- without CSS, their contents would run into the following text
local SPACE_AFTER = set("td th li p div span label dt dd tr h1 h2 h3 h4 h5 h6 section article header footer")

function H.rawText(node, out, is_root)
    out = out or {}
    if node.text then
        out[#out + 1] = node.text
    elseif is_root or not SKIP_TEXT[node.tag] then
        if node.tag == "br" then out[#out + 1] = " " end
        for _i, ch in ipairs(node.children or {}) do H.rawText(ch, out) end
        if SPACE_AFTER[node.tag] then out[#out + 1] = " " end
    end
    return out
end

function H.text(node)
    if not node then return "" end
    local s = table.concat(H.rawText(node, nil, true))
    s = H.decode(s):gsub("%s+", " ")
    return (s:match("^%s*(.-)%s*$"))
end

---------------------------------------------------------------------------
-- Selectors
---------------------------------------------------------------------------

local function parseCompound(tok)
    local c = { classes = {}, attrs = {} }
    local rest = tok
    local tag = rest:match("^([%w%*%-]+)")
    if tag then
        c.tag = tag:lower()
        rest = rest:sub(#tag + 1)
    end
    while #rest > 0 do
        local ch = rest:sub(1, 1)
        if ch == "#" then
            local id = rest:match("^#([%w_%-]+)") or ""
            c.id = id
            rest = rest:sub(#id + 2)
        elseif ch == "." then
            local cl = rest:match("^%.([%w_%-]+)") or ""
            table.insert(c.classes, cl)
            rest = rest:sub(#cl + 2)
        elseif ch == "[" then
            local inner = rest:match("^%[([^%]]*)%]") or ""
            rest = rest:sub(#inner + 3)
            local name, op, val = inner:match("^%s*([%w_:%-]+)%s*([%^%$%*~|]?=)%s*(.-)%s*$")
            if name then
                val = val:gsub("^[\"'](.*)[\"']$", "%1")
                table.insert(c.attrs, { name = name:lower(), op = op, val = val })
            else
                table.insert(c.attrs, { name = (inner:match("[%w_:%-]+") or ""):lower(), op = "exists" })
            end
        elseif ch == ":" then
            local arg = rest:match("^:contains%((.-)%)")
            if arg then
                c.contains = arg:gsub("^[\"'](.*)[\"']$", "%1"):lower()
                rest = rest:sub(#arg + 12)
            else
                local ps = rest:match("^:([%w%-]+)") or ""
                c.pseudo = ps
                rest = rest:sub(#ps + 2)
            end
        else
            break
        end
    end
    return c
end

-- split a selector chain into tokens (preserving spaces inside [])
local function tokenize(sel)
    local toks, buf, depth = {}, {}, 0
    sel = sel:gsub("%s*>%s*", " > ")
    for i = 1, #sel do
        local ch = sel:sub(i, i)
        if ch == "[" or ch == "(" then depth = depth + 1 elseif ch == "]" or ch == ")" then depth = depth - 1 end
        if ch:match("%s") and depth == 0 then
            if #buf > 0 then toks[#toks + 1] = table.concat(buf); buf = {} end
        else
            buf[#buf + 1] = ch
        end
    end
    if #buf > 0 then toks[#toks + 1] = table.concat(buf) end
    return toks
end

local cache = {}
local function compile(selector)
    if cache[selector] then return cache[selector] end
    local alts = {}
    for part in (selector .. ","):gmatch("([^,]*),") do
        part = part:match("^%s*(.-)%s*$")
        if part ~= "" then
            local chain, comb = {}, " "
            for _i, tok in ipairs(tokenize(part)) do
                if tok == ">" then
                    comb = ">"
                else
                    table.insert(chain, { c = parseCompound(tok), comb = comb })
                    comb = " "
                end
            end
            if #chain > 0 then table.insert(alts, chain) end
        end
    end
    cache[selector] = alts
    return alts
end

local function matchCompound(node, c)
    if not node.tag or node.tag:sub(1, 1) == "#" then return false end
    if c.tag and c.tag ~= "*" and node.tag ~= c.tag then return false end
    local a = node.attrs
    if c.id and a.id ~= c.id then return false end
    if #c.classes > 0 then
        local cls = " " .. (a.class or ""):gsub("%s+", " ") .. " "
        for _i, cl in ipairs(c.classes) do
            if not cls:find(" " .. cl .. " ", 1, true) then return false end
        end
    end
    for _i, at in ipairs(c.attrs) do
        local v = a[at.name]
        if at.op == "exists" then
            if v == nil then return false end
        else
            if v == nil then return false end
            local val = at.val
            if at.op == "=" then
                if v ~= val then return false end
            elseif at.op == "^=" then
                if v:sub(1, #val) ~= val then return false end
            elseif at.op == "$=" then
                if val == "" or v:sub(-#val) ~= val then return false end
            elseif at.op == "*=" then
                if not v:find(val, 1, true) then return false end
            elseif at.op == "~=" then
                if not (" " .. v .. " "):find(" " .. val .. " ", 1, true) then return false end
            elseif at.op == "|=" then
                if v ~= val and v:sub(1, #val + 1) ~= val .. "-" then return false end
            end
        end
    end
    if c.contains and not H.text(node):lower():find(c.contains, 1, true) then return false end
    return true
end

local function matchChain(node, chain, idx, scope)
    if not matchCompound(node, chain[idx].c) then return false end
    if idx == 1 then return true end
    local stop = scope and scope.parent
    local p = node.parent
    if chain[idx].comb == ">" then
        return p ~= nil and p ~= stop and matchChain(p, chain, idx - 1, scope)
    end
    while p and p ~= stop do
        if matchChain(p, chain, idx - 1, scope) then return true end
        p = p.parent
    end
    return false
end

local function walk(node, fn)
    for _i, ch in ipairs(node.children or {}) do
        if ch.tag then
            if fn(ch) == false then return false end
            if walk(ch, fn) == false then return false end
        end
    end
end

-- all matching descendants (in document order)
function H.select(node, selector, limit)
    local alts = compile(selector)
    local out = {}
    if #alts == 0 then return out end
    walk(node, function(n)
        for _i, chain in ipairs(alts) do
            if matchChain(n, chain, #chain, node) then
                out[#out + 1] = n
                break
            end
        end
        if limit and #out >= limit then return false end
    end)
    return out
end

function H.first(node, selector)
    return H.select(node, selector, 1)[1]
end

-- extract "selector@attr" / "@attr" / "." from an element
function H.extract(node, spec)
    if not node or not spec then return nil end
    local sel, at = spec:match("^(.-)@([%w_:%-]+)$")
    if not sel then sel = spec end
    sel = sel:match("^%s*(.-)%s*$")
    local target = (sel == "" or sel == ".") and node or H.first(node, sel)
    if not target then return nil end
    if at then
        local v = target.attrs and target.attrs[at]
        if v and v ~= "" then return v end
        return nil
    end
    local t = H.text(target)
    return t ~= "" and t or nil
end

function H.extractAll(node, spec)
    local sel, at = spec:match("^(.-)@([%w_:%-]+)$")
    if not sel then sel = spec end
    local out = {}
    for _i, n in ipairs(H.select(node, sel)) do
        local v
        if at then v = n.attrs[at] else v = H.text(n) end
        if v and v ~= "" then out[#out + 1] = { node = n, value = v } end
    end
    return out
end

return H
