--[[
Background torrent downloads with aria2c (controlled via JSON-RPC).
- .torrent file or magnet link -> aria2 downloads to Downloads/.torrent/<job>
- on completion: moves the book file(s) to the download directory and offers to open them
- no seeding (seed-time=0)
- stall monitoring: marked "STALLED" after a configurable timeout, with optional automatic deletion
Singleton module: only one poller runs, regardless of how many plugin instances call it.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local http = require("socket.http")
local socket = require("socket")
local ltn12 = require("ltn12")
local url = require("socket.url")
local Screen = Device.screen

local has_json, json = pcall(require, "json")
if not has_json then json = require("rapidjson") end
local has_socketutil, socketutil = pcall(require, "socketutil")
if not has_socketutil then socketutil = nil end

-- i18n (shared singleton; loaded from the plugin directory) ---------------------
local _i18n_pdir = (debug.getinfo(1, "S").source or ""):match("^@(.*)/[^/]*$") or "plugins/inksurf.koplugin"
local I18N = package.loaded["inksurf_i18n"]
if not I18N then
    I18N = dofile(_i18n_pdir .. "/wb_i18n.lua")
    package.loaded["inksurf_i18n"] = I18N
end
local function S(s) return I18N.tr(s) end


local RPC_PORT = 16800
local POLL_INTERVAL = 5

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function q(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local ARRAY_MT = {}
local function jarray(t) return setmetatable(t or {}, ARRAY_MT) end

local JESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function jstr(s)
    return '"' .. s:gsub('[%c"\\]', function(c) return JESC[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end

-- Custom JSON encoder to ensure an empty array is encoded as []
local function jencode(v)
    local t = type(v)
    if t == "string" then return jstr(v)
    elseif t == "number" or t == "boolean" then return tostring(v)
    elseif t == "table" then
        local out = {}
        if getmetatable(v) == ARRAY_MT or #v > 0 then
            for i = 1, #v do out[i] = jencode(v[i]) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        for k, val in pairs(v) do out[#out + 1] = jstr(tostring(k)) .. ":" .. jencode(val) end
        return "{" .. table.concat(out, ",") .. "}"
    end
    return "null"
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

local function fmtSize(n)
    n = n or 0
    if n >= 1073741824 then return string.format("%.2f GB", n / 1073741824) end
    if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
    return string.format("%d KB", math.ceil(n / 1024))
end

local function basename(p) return p:match("([^/]+)$") or p end

local function uniquePath(dir, name)
    local path = dir .. "/" .. name
    local base, ext = name:match("^(.-)(%.[%w]+)$")
    if not base or base == "" then base, ext = name, "" end
    local n = 1
    while lfs.attributes(path, "mode") do
        path = string.format("%s/%s (%d)%s", dir, base, n, ext)
        n = n + 1
    end
    return path
end

local function absPath(p)
    if p:sub(1, 1) == "/" then return p end
    return lfs.currentdir() .. "/" .. p:gsub("^%./", "")
end

local function ensureDir(d)
    if lfs.attributes(d, "mode") ~= "directory" then lfs.mkdir(d) end
    return d
end

-- Only allow deletion of our own .torrent/<job> directories
local function rmrf(dir)
    if dir and dir:find("/%.torrent/[^/]+$") then
        os.execute("rm -rf " .. q(dir))
    end
end

local function getPid()
    local ok, ffi = pcall(require, "ffi")
    if not ok then return nil end
    local ok2, pid = pcall(function() return ffi.C.getpid() end)
    if not ok2 then
        pcall(ffi.cdef, "int getpid(void);")
        ok2, pid = pcall(function() return ffi.C.getpid() end)
    end
    return ok2 and tonumber(pid) or nil
end

---------------------------------------------------------------------------
-- Module
---------------------------------------------------------------------------

local T = {
    jobs = nil,
    polling = false,
}

function T:setup(opts)
    self.plugin_dir = opts.plugin_dir
    self.data_dir = opts.data_dir
    self.download_dir_fn = opts.download_dir_fn
    self.before_open = opts.before_open
    self.can_run_fn = opts.can_run_fn -- e.g. "VPN only": do not start/resume if false
    self.on_unopenable = opts.on_unopenable -- completed files KOReader cannot open (e.g. azw3 -> offer EPUB conversion)
    if not self.settings then
        self.settings = LuaSettings:open(opts.settings_path or (DataStorage:getSettingsDir() .. "/inksurf_torrent.lua"))
        self.jobs = self.settings:readSetting("jobs") or {}
        self.secret = self.settings:readSetting("secret")
        if not self.secret then
            math.randomseed(os.time())
            self.secret = string.format("%08x%08x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
            self.settings:saveSetting("secret", self.secret)
            self.settings:flush()
        end
        self._poll = function() self:poll() end
        -- Resume unfinished downloads after restarting KOReader
        if self:hasActive() then
            UIManager:scheduleIn(15, function()
                if self:hasActive() and self:canRun() and self:ensureDaemon() then self:startPolling() end
            end)
        end
    end
end

function T:saveJobs()
    self.settings:saveSetting("jobs", self.jobs)
    self.settings:flush()
end

function T:stallMinutes() return self.settings:readSetting("stall_minutes") or 30 end
function T:autoDelete() return self.settings:isTrue("auto_delete") end

function T:canRun()
    return not self.can_run_fn or self.can_run_fn()
end

-- aria2 changes to the "/" directory when daemonized, so all paths must be absolute
function T:binPath() return absPath(self.plugin_dir .. "/bin/aria2c") end
function T:certPath() return absPath(self.plugin_dir .. "/bin/cacert.pem") end
function T:dataDir()
    local base = self.data_dir or DataStorage:getDataDir()
    return ensureDir(absPath(base .. "/aria2"))
end
function T:torrentRoot() return ensureDir(absPath(self.download_dir_fn() .. "/.torrent")) end

function T:hasActive()
    for _i, j in ipairs(self.jobs or {}) do
        if j.state == "active" or j.state == "paused" then return true end
    end
    return false
end

function T:countActive()
    local n = 0
    for _i, j in ipairs(self.jobs or {}) do
        if j.state == "active" then n = n + 1 end
    end
    return n
end

-- RPC -----------------------------------------------------------------------

function T:rpc(method, params)
    local p = { "token:" .. self.secret }
    for _i, v in ipairs(params or {}) do p[#p + 1] = v end
    local body = jencode({ jsonrpc = "2.0", id = "kb", method = method, params = p })
    local chunks = {}
    if socketutil then pcall(function() socketutil:set_timeout(3, 10) end) end
    local ok, code = pcall(function()
        return socket.skip(1, http.request{
            url = "http://127.0.0.1:" .. RPC_PORT .. "/jsonrpc",
            method = "POST",
            headers = { ["content-type"] = "application/json", ["content-length"] = tostring(#body) },
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(chunks),
        })
    end)
    if socketutil then pcall(function() socketutil:reset_timeout() end) end
    if not ok or type(code) ~= "number" then return nil, S("Nem érem el az aria2-t."), true end
    local okd, r = pcall(json.decode, table.concat(chunks))
    if not okd or type(r) ~= "table" then return nil, S("Hibás válasz az aria2-től.") end
    if type(r.error) == "table" then return nil, tostring(r.error.message or "aria2 error") end
    return r.result
end

function T:isRunning()
    return self:rpc("aria2.getVersion") ~= nil
end

function T:ensureDaemon()
    if self:isRunning() then return true end
    local bin = self:binPath()
    if lfs.attributes(bin, "mode") ~= "file" then
        return false, S("Nem találom az aria2c programot:\n") .. bin
    end
    os.execute("chmod +x " .. q(bin) .. " 2>/dev/null")
    local dd = self:dataDir()
    local session = dd .. "/session.txt"
    if not lfs.attributes(session, "mode") then
        local f = io.open(session, "w")
        if f then f:close() end
    end
    local args = {
        q(bin),
        "--enable-rpc=true", "--rpc-listen-all=false", "--rpc-listen-port=" .. RPC_PORT,
        "--rpc-secret=" .. self.secret,
        "--daemon=true", "--quiet=true",
        "--dir=" .. q(self:torrentRoot()),
        "--input-file=" .. q(session), "--save-session=" .. q(session), "--save-session-interval=30",
        "--continue=true", "--auto-save-interval=30",
        "--seed-time=0", "--max-overall-upload-limit=30K",
        "--file-allocation=none", "--disable-ipv6=true",
        "--enable-dht=true", "--dht-file-path=" .. q(dd .. "/dht.dat"),
        "--bt-save-metadata=false", "--max-concurrent-downloads=3",
        "--log=" .. q(dd .. "/aria2.log"), "--log-level=warn",
    }
    if lfs.attributes(self:certPath(), "mode") == "file" then
        table.insert(args, "--ca-certificate=" .. q(self:certPath()))
    end
    local pid = getPid()
    if pid then table.insert(args, "--stop-with-process=" .. pid) end
    os.execute(table.concat(args, " ") .. " >/dev/null 2>&1")
    for _i = 1, 20 do
        socket.sleep(0.2)
        if self:isRunning() then return true end
    end
    return false, S("Az aria2 nem indult el.\nNapló: ") .. dd .. "/aria2.log"
end

-- Adding ------------------------------------------------------------------

function T:newJobDir()
    math.randomseed(os.time())
    local d = self:torrentRoot() .. "/" .. os.time() .. "_" .. math.random(1000, 9999)
    lfs.mkdir(d)
    return d
end

function T:add(kind, payload, name)
    UIManager:show(InfoMessage:new{ text = S("Torrent indítása…"), timeout = 1 })
    UIManager:forceRePaint()
    local ok, err = self:ensureDaemon()
    if not ok then
        UIManager:show(InfoMessage:new{ text = S("Hiba:\n") .. tostring(err) })
        return
    end
    local dir = self:newJobDir()
    local opts = { dir = dir, ["seed-time"] = "0" }
    local gid, e
    if kind == "magnet" then
        gid, e = self:rpc("aria2.addUri", { { payload }, opts })
    else
        gid, e = self:rpc("aria2.addTorrent", { b64(payload), jarray(), opts })
    end
    if not gid then
        rmrf(dir)
        UIManager:show(InfoMessage:new{ text = S("Az aria2 nem fogadta el:\n") .. tostring(e) })
        return
    end
    table.insert(self.jobs, {
        gid = gid, name = name or "torrent", dir = dir, added = os.time(),
        state = "active", last_change = os.time(), last_completed = 0,
    })
    self:saveJobs()
    UIManager:show(InfoMessage:new{
        text = S("Letöltés a háttérben:\n") .. (name or "torrent")
            .. S("\n\nÁllapot: Eszközök → Torrent letöltések"),
        timeout = 4,
    })
    self:startPolling()
    self:refreshManager()
end

function T:addTorrent(data, name)
    self:add("torrent", data, name)
end

function T:addMagnet(magnet)
    local dn = magnet:match("[?&][dD][nN]=([^&]+)")
    local name = dn and url.unescape((dn:gsub("%+", " "))) or "magnet"
    self:add("magnet", magnet, name)
end

-- Monitoring --------------------------------------------------------------------

function T:startPolling()
    if self.polling then return end
    self.polling = true
    self.last_poll = os.time()
    UIManager:scheduleIn(2, self._poll)
end

function T:poll()
    local now = os.time()
    local gap = now - (self.last_poll or now)
    self.last_poll = now
    self.daemon_checked = false
    for i = #self.jobs, 1, -1 do
        local job = self.jobs[i]
        if job and (job.state == "active" or job.state == "paused") then
            local okj, perr = pcall(self.updateJob, self, job, now, gap)
            if not okj then job.state = "error"; job.error = tostring(perr) end
        end
    end
    self:saveJobs()
    self:refreshManager()
    if self:hasActive() and self:canRun() then
        UIManager:scheduleIn(POLL_INTERVAL, self._poll)
    else
        self.polling = false
    end
end

function T:updateJob(job, now, gap)
    local keys = jarray{ "status", "totalLength", "completedLength", "downloadSpeed",
        "numSeeders", "connections", "followedBy", "errorMessage", "bittorrent" }
    local st, err, conn = self:rpc("aria2.tellStatus", { job.gid, keys })
    if not st then
        if conn then
            -- aria2 is not running (e.g. KOReader restarted) -> restart it; the session resumes
            if not self.daemon_checked and self:canRun() then
                self.daemon_checked = true
                self:ensureDaemon()
            end
            job.last_change = now
            return
        end
        job.state = "lost"
        job.error = err
        self:notifyProblem(job)
        return
    end

    local completed = tonumber(st.completedLength) or 0
    job.total = tonumber(st.totalLength) or 0
    job.completed = completed
    job.speed = tonumber(st.downloadSpeed) or 0
    job.seeders = tonumber(st.numSeeders) or 0
    job.conns = tonumber(st.connections) or 0
    if type(st.bittorrent) == "table" and type(st.bittorrent.info) == "table" and st.bittorrent.info.name then
        job.name = st.bittorrent.info.name
    end

    if st.status == "complete" then
        if type(st.followedBy) == "table" and st.followedBy[1] then
            -- magnet: metadata has arrived; monitor the actual download from now on
            self:rpc("aria2.removeDownloadResult", { job.gid })
            job.gid = st.followedBy[1]
            job.last_change = now
            job.last_completed = 0
            return
        end
        self:finish(job)
    elseif st.status == "error" or st.status == "removed" then
        job.state = "error"
        job.error = st.errorMessage or st.status
        if self:autoDelete() then
            self:deleteJob(job, true)
        else
            self:notifyProblem(job)
        end
    elseif st.status == "paused" then
        job.state = "paused"
        job.last_change = now
    else
        job.state = "active"
        -- If the Kindle was asleep (a long gap between polls), do not count it as a stall
        if gap > POLL_INTERVAL * 6 or completed ~= job.last_completed then
            job.last_change = now
            job.last_completed = completed
        end
        local stall = self:stallMinutes()
        if stall > 0 and now - (job.last_change or now) >= stall * 60 then
            job.state = "stalled"
            self:rpc("aria2.forcePause", { job.gid })
            if self:autoDelete() then
                self:deleteJob(job, true)
            else
                self:notifyProblem(job)
            end
        end
    end
end

function T:finish(job)
    local files = self:rpc("aria2.getFiles", { job.gid }) or {}
    self:rpc("aria2.removeDownloadResult", { job.gid })
    local dest = self.download_dir_fn()
    local all, books = {}, {}
    for _i, f in ipairs(files) do
        local p = type(f) == "table" and f.path
        if type(p) == "string" and p ~= "" and lfs.attributes(p, "mode") == "file" then
            table.insert(all, p)
            if DocumentRegistry:hasProvider(p) then table.insert(books, p) end
        end
    end
    local to_move = (#books > 0) and books or all
    local moved = {}
    for _i, p in ipairs(to_move) do
        local target = uniquePath(dest, basename(p))
        if os.rename(p, target) then table.insert(moved, target) end
    end
    rmrf(job.dir)
    self:removeJob(job)

    pcall(function()
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then FileManager.instance:onRefresh() end
    end)

    local openable = {}
    for _i, p in ipairs(moved) do
        if DocumentRegistry:hasProvider(p) then table.insert(openable, p) end
    end
    if #openable == 1 then
        UIManager:show(ConfirmBox:new{
            text = S("Kész a torrent letöltés:\n") .. basename(openable[1]) .. "\n\nOpen it now?",
            ok_text = S("Megnyitás"),
            cancel_text = S("Később"),
            ok_callback = function() self:openFile(openable[1]) end,
        })
    elseif #openable > 1 then
        local dlg
        local buttons = {}
        for i = 1, math.min(#openable, 8) do
            local p = openable[i]
            table.insert(buttons, {{ text = basename(p), callback = function()
                UIManager:close(dlg)
                self:openFile(p)
            end }})
        end
        table.insert(buttons, {{ text = S("Bezárás"), callback = function() UIManager:close(dlg) end }})
        dlg = ButtonDialog:new{ title = S("Kész: ") .. job.name .. "\nWhich one should I open?", buttons = buttons }
        UIManager:show(dlg)
    elseif #moved > 0 and self.on_unopenable then
        -- KOReader cannot open it (e.g. azw3): the main module may offer EPUB conversion
        self.on_unopenable(moved)
    else
        UIManager:show(InfoMessage:new{
            text = S("Kész a torrent letöltés:\n") .. job.name .. "\n\n"
                .. (#moved > 0 and (S("A fájlok itt vannak: ") .. dest .. S("\n(A KOReader ezt a formátumot nem nyitja meg.)"))
                    or S("A letöltésben nem találtam fájlt.")),
        })
    end
end

-- When the VPN is disconnected: stop aria2 (the session saves progress)
function T:suspendAll()
    if self:isRunning() then
        self:rpc("aria2.shutdown")
        for _i = 1, 15 do
            socket.sleep(0.2)
            if not self:isRunning() then break end
        end
    end
    for _i, j in ipairs(self.jobs or {}) do j.last_change = os.time() end
    self:saveJobs()
end

-- When the VPN is connected: resume
function T:resumeAll()
    if self:hasActive() and self:canRun() then
        for _i, j in ipairs(self.jobs) do j.last_change = os.time() end
        if self:ensureDaemon() then self:startPolling() end
    end
end

function T:openFile(path)
    self:closeManager()
    if self.before_open then pcall(self.before_open) end
    require("apps/reader/readerui"):showReader(path)
end

function T:notifyProblem(job)
    if job.notified then return end
    job.notified = true
    local what = (job.state == "stalled") and "Stalled" or S("Hiba történt")
    UIManager:show(InfoMessage:new{
        text = what .. S(" a torrent letöltésnél:\n") .. job.name
            .. (job.error and ("\n\n" .. tostring(job.error)) or "")
            .. S("\n\nEszközök → Torrent letöltések: itt folytathatod vagy törölheted."),
    })
end

function T:removeJob(job)
    for i, j in ipairs(self.jobs) do
        if j == job then table.remove(self.jobs, i) break end
    end
    self:saveJobs()
end

function T:deleteJob(job, silent)
    self:rpc("aria2.forceRemove", { job.gid })
    self:rpc("aria2.removeDownloadResult", { job.gid })
    rmrf(job.dir)
    self:removeJob(job)
    if silent then
        UIManager:show(InfoMessage:new{ text = S("Elakadt/hibás torrent automatikusan törölve:\n") .. job.name, timeout = 5 })
    end
    self:refreshManager()
end

function T:deleteAll()
    for i = #self.jobs, 1, -1 do
        local job = self.jobs[i]
        self:rpc("aria2.forceRemove", { job.gid })
        rmrf(job.dir)
    end
    self.jobs = {}
    self:saveJobs()
    self:rpc("aria2.forceShutdown")
    local f = io.open(self:dataDir() .. "/session.txt", "w")
    if f then f:close() end
    local root = self.download_dir_fn() .. "/.torrent"
    if lfs.attributes(root, "mode") == "directory" then
        os.execute("rm -rf " .. q(root) .. "/* 2>/dev/null")
    end
    self:refreshManager()
    UIManager:show(InfoMessage:new{ text = S("Minden torrent letöltés törölve, az aria2 leállítva."), timeout = 3 })
end

-- User interface ---------------------------------------------------------------

local function statusText(job)
    if job.state == "active" then
        if (job.total or 0) == 0 then return "metadata…" end
        local pct = math.floor((job.completed or 0) * 100 / job.total)
        return string.format("%d%% · %s/s", pct, fmtSize(job.speed or 0))
    elseif job.state == "paused" then return S("szünetel")
    elseif job.state == "stalled" then return "STALLED"
    elseif job.state == "error" then return "HIBA"
    elseif job.state == "lost" then return "lost"
    end
    return job.state or ""
end

function T:jobActions(job)
    local info = string.format("%s\n\n%s / %s · %s\nSeeders: %d · connections: %d",
        job.name, fmtSize(job.completed), fmtSize(job.total), statusText(job), job.seeders or 0, job.conns or 0)
    if job.error then info = info .. "\n\nError: " .. tostring(job.error) end
    local dlg
    local buttons = {}
    if job.state == "active" then
        table.insert(buttons, {{ text = S("Szüneteltetés"), callback = function()
            UIManager:close(dlg)
            self:rpc("aria2.pause", { job.gid })
            job.state = "paused"
            self:saveJobs()
            self:refreshManager()
        end }})
    elseif job.state == "paused" or job.state == "stalled" then
        table.insert(buttons, {{ text = S("Folytatás"), callback = function()
            UIManager:close(dlg)
            self:rpc("aria2.unpause", { job.gid })
            job.state = "active"
            job.notified = nil
            job.last_change = os.time()
            self:saveJobs()
            self:startPolling()
            self:refreshManager()
        end }})
    end
    table.insert(buttons, {{ text = S("Törlés (a letöltött részekkel együtt)"), callback = function()
        UIManager:close(dlg)
        UIManager:show(ConfirmBox:new{
            text = S("Törlöd ezt a letöltést és a már letöltött részeit?\n") .. job.name,
            ok_text = S("Törlés"),
            cancel_text = S("Mégse"),
            ok_callback = function() self:deleteJob(job) end,
        })
    end }})
    table.insert(buttons, {{ text = S("Bezárás"), callback = function() UIManager:close(dlg) end }})
    dlg = ButtonDialog:new{ title = info, buttons = buttons }
    UIManager:show(dlg)
end

function T:chooseStall()
    local dlg
    local buttons = {}
    for _i, m in ipairs({ 0, 10, 20, 30, 60, 120 }) do
        table.insert(buttons, {{ text = (m == 0) and "Off (not monitored)" or (m .. " min"), callback = function()
            UIManager:close(dlg)
            self.settings:saveSetting("stall_minutes", m)
            self.settings:flush()
            self:refreshManager()
        end }})
    end
    dlg = ButtonDialog:new{ title = S("Ennyi ideig tartó haladás nélküli állapot után számítson elakadtnak:"), buttons = buttons }
    UIManager:show(dlg)
end

function T:managerItems()
    local items = {}
    for _i, job in ipairs(self.jobs) do
        table.insert(items, {
            text = job.name,
            mandatory = statusText(job),
            callback = function() self:jobActions(job) end,
        })
    end
    if #self.jobs == 0 then
        table.insert(items, { text = S("(Nincs torrent letöltés)") })
    end
    local stall = self:stallMinutes()
    table.insert(items, {
        text = S("⚙ Elakadásnak számít: ") .. ((stall == 0) and "off" or (stall .. S(" perc haladás nélkül"))),
        callback = function() self:chooseStall() end,
    })
    table.insert(items, {
        text = S("⚙ Elakadt/hibás letöltés automatikus törlése: ") .. (self:autoDelete() and "BE" or "KI"),
        callback = function()
            self.settings:saveSetting("auto_delete", not self:autoDelete())
            self.settings:flush()
            self:refreshManager()
        end,
    })
    table.insert(items, {
        text = S("⚙ Összes törlése + aria2 leállítása"),
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = S("Minden torrent letöltést törölsz (a félkész fájlokkal együtt), és leállítod az aria2-t?"),
                ok_text = S("Mindent töröl"),
                cancel_text = S("Mégse"),
                ok_callback = function() self:deleteAll() end,
            })
        end,
    })
    return items
end

function T:showManager()
    local title = S("Torrent letöltések")
    if self.menu then
        self.menu:switchItemTable(title, self:managerItems(), -1)
    else
        self.menu = Menu:new{
            title = title,
            item_table = self:managerItems(),
            width = Screen:getWidth(),
            height = Screen:getHeight(),
            is_borderless = true,
            is_popout = false,
            covers_fullscreen = true,
            onMenuSelect = function(_m, item)
                if item.callback then item.callback() end
                return true
            end,
            close_callback = function() self:closeManager() end,
        }
        UIManager:show(self.menu)
    end
    if self:hasActive() then self:startPolling() end
end

function T:refreshManager()
    if self.menu then
        self.menu:switchItemTable(S("Torrent letöltések"), self:managerItems(), -1)
    end
end

function T:closeManager()
    if self.menu then
        local m = self.menu
        self.menu = nil
        UIManager:close(m)
    end
end

return T
