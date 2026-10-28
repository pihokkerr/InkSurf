--[[
VPN (OpenVPN) control – adapted from the BookFetch plugin.
The actual work is done by vpn.sh (disabling IPv6, kill switch, DNS).
Singleton module.
]]

local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

-- i18n (shared singleton; loaded from the plugin directory) ---------------------
local _i18n_pdir = (debug.getinfo(1, "S").source or ""):match("^@(.*)/[^/]*$") or "plugins/inksurf.koplugin"
local I18N = package.loaded["inksurf_i18n"]
if not I18N then
    I18N = dofile(_i18n_pdir .. "/wb_i18n.lua")
    package.loaded["inksurf_i18n"] = I18N
end
local function S(s) return I18N.tr(s) end


local SETTING_OVPN = "bookfetch_ovpn" -- shared with the old plugin to preserve the selected server

local function q(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function notify(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

local function fileExists(path)
    return lfs.attributes(path, "mode") == "file"
end

local function withBusy(text, fn)
    local msg = InfoMessage:new{ text = text }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local ok, res = pcall(fn)
    UIManager:close(msg)
    if not ok then
        logger.warn("WebBrowser VPN error:", res)
        return "HIBA " .. tostring(res)
    end
    return res
end

-- The last "OK ..." or "HIBA ..." line
local function parseResult(out)
    local status, msg
    for line in out:gmatch("[^\n]+") do
        local s, m = line:match("^(OK)%s*(.-)%s*$")
        if not s then s, m = line:match("^(HIBA)%s*(.-)%s*$") end
        if s then status, msg = s, m end
    end
    if not status then return "HIBA", out:sub(-300) end
    return status, msg
end

-- The KOReader process caches the contents of /etc/resolv.conf at startup.
-- Reload it after switching VPNs; otherwise it uses the old (router) DNS.
-- Try several libc symbols (glibc: __res_init / res_init; possibly libresolv too).
local function resInit()
    local ok, ffi = pcall(require, "ffi")
    if not ok then return false, "ffi unavailable" end
    pcall(ffi.cdef, "int __res_init(void); int res_init(void);")
    local tried = {}
    for _i, sym in ipairs({ "__res_init", "res_init" }) do
        local okc, rv = pcall(function() return ffi.C[sym]() end)
        if okc then return true, sym .. "=" .. tostring(rv) end
        tried[#tried + 1] = sym
        -- Also try libresolv.so if the symbol is not in the main namespace
        for _j, lib in ipairs({ "resolv", "libresolv.so.2", "libresolv.so" }) do
            local okl, L = pcall(ffi.load, lib)
            if okl then
                local ok2, rv2 = pcall(function() return L[sym]() end)
                if ok2 then return true, lib .. ":" .. sym .. "=" .. tostring(rv2) end
            end
        end
    end
    return false, "none available: " .. table.concat(tried, ", ")
end

local UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

-- Test connectivity from KOReader's own process (using exactly the same path as the browser).
-- Returns: ip | nil, info, reached  (reached=true if ANY HTTP response was received –
-- in that case the network is fine; only the test endpoint rejected the request)
local function selfTest()
    local okh, http = pcall(require, "socket.http")
    if not okh then return nil, "socket.http unavailable", false end
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local okt, socketutil = pcall(require, "socketutil")
    if okt then pcall(function() socketutil:set_timeout(8, 15) end) end
    local chunks = {}
    local ok, code = pcall(function()
        return socket.skip(1, http.request{
            url = "http://api.ipify.org/",
            headers = { ["user-agent"] = UA, ["accept"] = "*/*" },
            sink = ltn12.sink.table(chunks),
        })
    end)
    if okt then pcall(function() socketutil:reset_timeout() end) end
    if ok and code == 200 then
        return (table.concat(chunks):match("[%d%.:a-fA-F]+")), nil, true
    end
    if ok and type(code) == "number" then
        return nil, "HTTP " .. code, true -- reached the server: the network is fine
    end
    return nil, tostring(code), false
end

-- Resolve a hostname from the KOReader process (this uses the glibc resolver)
local function resolveHost(host)
    local socket = require("socket")
    local okt, socketutil = pcall(require, "socketutil")
    if okt then pcall(function() socketutil:set_timeout(6, 10) end) end
    local ip, err = socket.dns.toip(host)
    if okt then pcall(function() socketutil:reset_timeout() end) end
    return ip, err
end

-- HTTP probe DIRECTLY to an IP (without DNS) – tests the network route/kill switch
local function httpToIp(ip, host, path)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local okt, socketutil = pcall(require, "socketutil")
    if okt then pcall(function() socketutil:set_timeout(6, 12) end) end
    local chunks = {}
    local ok, code = pcall(function()
        return socket.skip(1, http.request{
            url = "http://" .. ip .. (path or "/"),
            headers = host and { ["host"] = host } or nil,
            sink = ltn12.sink.table(chunks),
        })
    end)
    if okt then pcall(function() socketutil:reset_timeout() end) end
    if ok and type(code) == "number" then return code, table.concat(chunks) end
    return nil, tostring(code)
end

-- A fresh process (wget) at the system level – if this works but KOReader's probe does not,
-- the KOReader process's DNS cache is at fault (resInit is needed).
local function wgetProbe()
    local p = io.popen("wget -T 10 -qO- http://ifconfig.me/ip 2>/dev/null")
    if not p then return nil end
    local out = (p:read("*a") or ""):gsub("%s+$", "")
    p:close()
    return out ~= "" and out or nil
end

local VPN = {}

function VPN:setup(opts)
    self.plugin_dir = opts.plugin_dir
    self.settings = opts.settings -- the plugin's own separate settings file (if any)
    self.vpn_dir = opts.plugin_dir .. "/vpn/"
    self.script = opts.plugin_dir .. "/vpn.sh"
    self.auth = self.vpn_dir .. "auth.txt"
    self.on_up = opts.on_up
    self.on_down = opts.on_down
    if lfs.attributes(self.vpn_dir, "mode") ~= "directory" then lfs.mkdir(self.vpn_dir) end
    -- Self-healing at startup: clean up a stuck kill switch / locked resolv.conf
    -- from a previous run (no internet) in the background (only if the VPN is not running)
    pcall(function()
        os.execute("sh " .. q(self.script) .. " heal >/dev/null 2>&1 &")
    end)
end

function VPN:runScript(args)
    local p = io.popen("sh " .. q(self.script) .. " " .. args .. " 2>&1")
    if not p then return S("HIBA nem indítható a vpn.sh") end
    local out = p:read("*a") or ""
    p:close()
    logger.dbg("WebBrowser vpn.sh", args, "->", out)
    return out
end

function VPN:isUp()
    return fileExists("/tmp/bookfetch/ovpn.pid")
        and lfs.attributes("/sys/class/net/tun0", "mode") ~= nil
end

function VPN:listOvpn()
    local files = {}
    if lfs.attributes(self.vpn_dir, "mode") == "directory" then
        for f in lfs.dir(self.vpn_dir) do
            if f:lower():match("%.ovpn$") then table.insert(files, f) end
        end
    end
    table.sort(files)
    return files
end

function VPN:_ovpnGet()
    if self.settings then return self.settings:readSetting(SETTING_OVPN) end
    return G_reader_settings:readSetting(SETTING_OVPN)
end

function VPN:_ovpnSet(name)
    if self.settings then
        self.settings:saveSetting(SETTING_OVPN, name)
        self.settings:flush()
    else
        G_reader_settings:saveSetting(SETTING_OVPN, name)
    end
end

function VPN:currentOvpn()
    local name = self:_ovpnGet()
    if name and fileExists(self.vpn_dir .. name) then return name end
    local files = self:listOvpn()
    if #files == 1 then return files[1] end
    return nil
end

-- Per-provider credentials: use <servername>.auth in the vpn/ directory if present
-- (so Express and Nord can coexist with separate logins);
-- otherwise fall back to the shared auth.txt.
function VPN:authFor(ovpn)
    if ovpn then
        local per = self.vpn_dir .. ovpn:gsub("%.ovpn$", "") .. ".auth"
        if fileExists(per) then return per end
    end
    return self.auth
end

-- When saving: if a server is selected, write to its <name>.auth file;
-- otherwise write to the shared auth.txt (backward compatible).
function VPN:authWritePath(ovpn)
    if ovpn then
        return self.vpn_dir .. ovpn:gsub("%.ovpn$", "") .. ".auth"
    end
    return self.auth
end

-- done(ok) is an optional callback
function VPN:up(done)
    local ovpn = self:currentOvpn()
    if not ovpn then
        notify(S("Előbb válassz szervert (.ovpn fájl).\nA fájlokat ide másold:\n") .. self.vpn_dir)
        if done then done(false) end
        return
    end
    local auth = self:authFor(ovpn)
    if not fileExists(auth) then
        notify(S("Előbb add meg a VPN felhasználónevet és jelszót\n(a kiválasztott szerverhez: ") .. ovpn:gsub("%.ovpn$", "") .. ").")
        if done then done(false) end
        return
    end
    local out = withBusy(S("VPN kapcsolódás…\n(legfeljebb 40 mp)"), function()
        return self:runScript("up " .. q(self.vpn_dir .. ovpn) .. " " .. q(auth))
    end)
    local status, msg = parseResult(out)
    if status == "OK" then
        resInit()
        local ip, err, reached = withBusy(S("Kapcsolat ellenőrzése…"), function() return selfTest() end)
        local text = S("VPN bekapcsolva ✓\nSzerver: ") .. ovpn:gsub("%.ovpn$", "") .. S("\nIP-cím: ") .. (msg or "")
        if ip then
            text = text .. S("\n\nBöngésző kapcsolat: OK (") .. ip .. ")"
        elseif reached then
            text = text .. S("\n\nBöngésző kapcsolat: OK (a hálózat működik)")
        else
            text = text .. S("\n\nFIGYELEM: a böngésző még nem éri el az internetet (") .. tostring(err) .. ")."
                .. S("\nHa ez így marad, kapcsold ki és be a VPN-t, vagy indítsd újra a KOReadert.")
        end
        notify(text, (ip or reached) and 6 or nil)
        if self.on_up then pcall(self.on_up) end
        if done then done(ip ~= nil or reached == true) end
    else
        notify("VPN error:\n" .. (msg or ""))
        if done then done(false) end
    end
end

function VPN:down()
    -- Stop torrents first so they do not continue downloading without the VPN
    if self.on_down then pcall(self.on_down) end
    local out = withBusy(S("VPN leállítása…"), function() return self:runScript("down") end)
    resInit()
    local status, msg = parseResult(out)
    if status == "OK" then
        notify(S("VPN kikapcsolva.\nA hálózat visszaállt az eredeti állapotra."), 4)
    else
        notify(S("Hiba a leállításnál:\n") .. (msg or ""))
    end
end

function VPN:status()
    local out = withBusy(S("Állapot lekérdezése…"), function() return self:runScript("status") end)
    local _status, msg = parseResult(out)
    resInit()
    local own_ip, own_err, own_reached = withBusy(S("Böngésző kapcsolat ellenőrzése…"), function() return selfTest() end)
    local own = own_ip and (S("Böngésző kapcsolat: OK (") .. own_ip .. ")")
        or (own_reached and S("Böngésző kapcsolat: OK (a hálózat működik)"))
        or (S("Böngésző kapcsolat: NINCS (") .. tostring(own_err) .. ")")
    if msg and msg:match("^BE") then
        local ip = msg:gsub("^BE%s*", "")
        notify(S("VPN: BE\nKülső IP-cím: ") .. (ip ~= "" and ip or "?") .. "\n" .. own)
    else
        notify("VPN: KI\n" .. own)
    end
end

-- Find step by step where the connection fails while using the VPN.
function VPN:diagnose()
    local L = {}
    local function add(s) L[#L + 1] = s end
    local route_ok, dns_ok, fetch_ok, reach_ok = false, false, false, false
    withBusy("Running diagnostics…\n(10-20 s)", function()
        add(S("tun0 létezik: ") .. (lfs.attributes("/sys/class/net/tun0", "mode") and "YES" or "NO"))
        add("ovpn.pid: " .. (fileExists("/tmp/bookfetch/ovpn.pid") and "present" or "missing"))
        local rf = io.open("/etc/resolv.conf", "r")
        if rf then
            local c = (rf:read("*a") or ""):gsub("%s+$", "")
            rf:close()
            add("resolv.conf:\n  " .. c:gsub("\n", "\n  "))
        end
        local okr, info = resInit()
        add(S("DNS újratöltés (res_init): ") .. (okr and ("OK [" .. info .. "]") or ("FAILED [" .. tostring(info) .. "]")))

        add("")
        add(S("1) Útvonal DNS nélkül (IP-re, 1.1.1.1):"))
        local code, body = httpToIp("1.1.1.1", nil, "/cdn-cgi/trace")
        if code then
            route_ok = true
            local ip = body and body:match("ip=([%d%.:a-fA-F]+)")
            add("   OK (HTTP " .. code .. ")" .. (ip and (S(", kimenő IP: ") .. ip) or ""))
        else
            add("   FAILED (" .. tostring(body) .. S(")  → a kill switch vagy az útvonal a hibás"))
        end

        add("")
        add(S("2) Hosztnév feloldása (DNS) a böngésző folyamatából:"))
        local dip, derr = resolveHost("one.one.one.one")
        if dip then
            dns_ok = true
            add("   OK: one.one.one.one -> " .. dip)
        else
            add("   FAILED (" .. tostring(derr) .. S(")  → a DNS-gyorsítótár a hibás"))
        end

        add("")
        add(S("3) Teljes letöltés hosztnévvel (ahogy a böngésző is):"))
        local sip, serr, reached = selfTest()
        fetch_ok = sip ~= nil
        reach_ok = reached == true
        if sip then
            add(S("   OK, külső IP: ") .. sip)
        elseif reached then
            add(S("   Kapcsolat OK, de a tesztcím elutasított (") .. tostring(serr) .. S(") – a hálózat MŰKÖDIK"))
        else
            add("   FAILED (" .. tostring(serr) .. ")")
        end
    end)

    local summary
    if not route_ok then
        summary = S("A baj: a hálózati útvonal / kill switch nem engedi ki a forgalmat (még IP-re sem). A vpn.sh tűzfalszabályai a gyanúsak.")
    elseif not dns_ok then
        summary = S("A baj: a DNS nem megy. A VPN által adott DNS nem érhető el; próbáld másik szerverrel vagy indítsd újra a KOReadert.")
    elseif fetch_ok or reach_ok then
        summary = S("A VPN rendben működik. Nyugodtan böngéssz; ha egy konkrét oldal nem jön be, az már az oldalon múlik, nem a VPN-en.")
    else
        summary = S("A feloldás és az útvonal is megy, a teljes letöltés mégsem – valószínűleg HTTPS/tanúsítvány gond vagy a cél blokkolja a kérést.")
    end
    table.insert(L, 1, "VPN DIAGNOSTICS\n===============\n")
    table.insert(L, "\n>>> " .. summary)
    UIManager:show(TextViewer:new{ title = S("VPN diagnosztika"), text = table.concat(L, "\n") })
end

function VPN:showCredentialsDialog()
    local ovpn = self:currentOvpn()
    local server = ovpn and ovpn:gsub("%.ovpn$", "") or nil
    local readPath = self:authFor(ovpn)
    local writePath = self:authWritePath(ovpn)
    local user = ""
    local f = io.open(readPath, "r")
    if f then
        user = (f:read("*l") or ""):gsub("\r", "")
        f:close()
    end
    local dialog
    dialog = MultiInputDialog:new{
        title = S("VPN bejelentkezés") .. (server and (" – " .. server) or "")
            .. S("\n(Manual Config / OpenVPN; NordVPN: a „szolgáltatási") ..
               S("\nhitelesítő adatok”, nem a fiók jelszava)"),
        fields = {
            { text = user, hint = S("Felhasználónév") },
            { text = "", hint = S("Jelszó"), text_type = "password" },
        },
        buttons = {{
            { text = S("Mégse"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = S("Mentés"), is_enter_default = true, callback = function()
                local fields = dialog:getFields()
                local u = (fields[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                local p = (fields[2] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if u == "" or p == "" then
                    notify(S("Mindkét mezőt ki kell tölteni."), 3)
                    return
                end
                local out = io.open(writePath, "w")
                if not out then
                    notify(S("Nem sikerült menteni: ") .. writePath)
                    return
                end
                out:write(u, "\n", p, "\n")
                out:close()
                UIManager:close(dialog)
                notify(S("Bejelentkezési adatok elmentve") .. (server and (" for: " .. server) or "") .. ".", 2)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function VPN:serverMenu()
    local items = {}
    local files = self:listOvpn()
    if #files == 0 then
        table.insert(items, { text = S("Nincs .ovpn fájl – másold ide: vpn/"), enabled = false })
        return items
    end
    for _i, name in ipairs(files) do
        table.insert(items, {
            text = name:gsub("%.ovpn$", ""),
            radio = true,
            checked_func = function() return self:currentOvpn() == name end,
            callback = function() self:_ovpnSet(name) end,
        })
    end
    return items
end

-- Submenu items for the KOReader main menu
function VPN:menuItems()
    return {
        {
            text_func = function()
                return self:isUp() and S("VPN: BE  (kikapcsolás)") or S("VPN: KI  (bekapcsolás)")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                if self:isUp() then self:down() else self:up() end
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text = S("VPN állapot és IP-cím"),
            keep_menu_open = true,
            callback = function() self:status() end,
        },
        {
            text_func = function()
                local cur = self:currentOvpn()
                return "VPN server: " .. (cur and cur:gsub("%.ovpn$", "") or S("nincs kiválasztva"))
            end,
            sub_item_table_func = function() return self:serverMenu() end,
        },
        {
            text = S("VPN bejelentkezési adatok"),
            keep_menu_open = true,
            callback = function() self:showCredentialsDialog() end,
        },
        {
            text = S("VPN diagnosztika (hol akad el?)"),
            keep_menu_open = true,
            callback = function() self:diagnose() end,
        },
    }
end

return VPN
