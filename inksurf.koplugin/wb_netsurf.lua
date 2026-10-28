--[[
NetSurf launcher – run a real browser engine (with limited JavaScript support)
on the Kindle framebuffer without leaving KOReader.

Operation: KOReader is single-threaded, so while the blocking os.execute runs,
KOReader neither draws nor reads /dev/input. NetSurf thus takes over the screen
and touch input; on return, KOReader refreshes the entire screen.

MINIMIZING: swiping down from the top edge makes NetSurf stop itself (SIGSTOP),
but it STAYS ALIVE in the background. The supervisor script then returns control
to KOReader (state file = "minimized", PID retained). Choosing "Resume" from the
menu wakes NetSurf with SIGCONT, resuming exactly where it left off.

The netsurf binary is located under netsurf.koplugin/bin/ (a separate package,
built by CI), or at the path specified in settings. The menu indicates if it is missing.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
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


local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local NS = {}

function NS:setup(opts)
    self.plugin_dir = opts.plugin_dir
    self.settings = opts.settings
    self.data_dir = opts.data_dir
    self.download_dir_fn = opts.download_dir_fn   -- where NetSurf should save files
    self.on_downloads = opts.on_downloads         -- callback with the list of downloaded files
    self.on_menu = opts.on_menu                   -- open KOReader's top menu (swipe down from the top edge)
    self.on_reader = opts.on_reader               -- reader view for the current article (reader icon in the bar)
end

-- possible locations of the binary
function NS:binary()
    local custom = self.settings and self.settings:readSetting("netsurf_bin")
    local cands = {}
    if custom then cands[#cands + 1] = custom end
    -- netsurf.koplugin next to the inksurf plugin
    local parent = self.plugin_dir:gsub("/[^/]+/?$", "")
    cands[#cands + 1] = parent .. "/netsurf.koplugin/bin/netsurf"
    cands[#cands + 1] = parent .. "/netsurf.koplugin/bin/nsfb"
    cands[#cands + 1] = self.plugin_dir .. "/bin/netsurf"
    for _i, p in ipairs(cands) do
        if lfs.attributes(p, "mode") == "file" then return p end
    end
    return nil
end

function NS:available()
    return self:binary() ~= nil
end

-- state files (written by the supervisor script, read by us)
function NS:_pidfile()   return (self.data_dir or "/mnt/us/koreader") .. "/netsurf.pid" end
function NS:_statefile() return (self.data_dir or "/mnt/us/koreader") .. "/netsurf.state" end
-- reason for minimizing: the frontend (kindlefb.c) writes "min" / "menu" / "url" here
function NS:_signalfile() return (self.data_dir or "/mnt/us/koreader") .. "/netsurf.signal" end
-- visited URL log (NetSurf appends here on every navigation)
function NS:_historyfile() return (self.data_dir or "/mnt/us/koreader") .. "/netsurf.history" end
-- text to inject into the field (entered with the KOReader keyboard)
-- Browser identifier (User-Agent). Defaults to Firefox (better site compatibility than
-- the hardcoded NetSurf UA); "netsurf" keeps the engine's own UA (no environment export).
local UA_STRINGS = {
    firefox = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0",
    chrome  = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
}
function NS:_userAgent()
    -- Default: NetSurf (the built-in UA) — also accepted by the built-in DuckDuckGo
    -- HTML search. Firefox/Chrome are optional (for some sites), but may trigger
    -- bot verification in DDG search.
    local pref = (self.settings and self.settings:readSetting("netsurf_ua")) or "netsurf"
    return UA_STRINGS[pref]   -- "netsurf"/unknown -> nil -> keep the built-in UA
end

function NS:_injectfile() return (self.data_dir or "/mnt/us/koreader") .. "/netsurf.inject" end
function NS:_fieldtextfile() return (self.data_dir or "/mnt/us/koreader") .. "/netsurf.fieldtext" end
function NS:_fieldlog() return (self.data_dir or "/mnt/us/koreader") .. "/netsurf_field.log" end

-- the last N unique visited URLs, newest first
function NS:historyList(n)
    n = n or 5
    local seen, order = {}, {}
    local f = io.open(self:_historyfile(), "r")
    if not f then return {} end
    for line in f:lines() do
        line = line:gsub("%s+$", "")
        if line ~= "" then
            if seen[line] then
                -- already seen: move to the end (most recent)
                for i = #order, 1, -1 do if order[i] == line then table.remove(order, i) break end end
            end
            seen[line] = true
            order[#order + 1] = line
        end
    end
    f:close()
    -- if it has grown too large, write back the last ~50 unique URLs (maintenance)
    if #order > 80 then
        local keep = {}
        for i = math.max(1, #order - 50 + 1), #order do keep[#keep + 1] = order[i] end
        local w = io.open(self:_historyfile(), "w")
        if w then w:write(table.concat(keep, "\n"), "\n"); w:close() end
        order = keep
    end
    local out = {}
    for i = #order, math.max(1, #order - n + 1), -1 do out[#out + 1] = order[i] end
    return out
end

function NS:historyClear()
    os.remove(self:_historyfile())
end

-- is there a minimized session (stopped but alive)?
function NS:hasMinimized()
    local sf = io.open(self:_statefile(), "r")
    if not sf then return false end
    local st = sf:read("*l"); sf:close()
    if st ~= "minimized" then return false end
    local pf = io.open(self:_pidfile(), "r")
    if not pf then return false end
    local pid = tonumber((pf:read("*l") or "")); pf:close()
    if not pid then return false end
    -- is it still alive? (kill -0)
    local ok = os.execute("kill -0 " .. pid .. " 2>/dev/null")
    return (ok == true or ok == 0), pid
end

-- shell code for the supervisor loop (shared by fresh launches and resumes).
-- Assumes $NSPID is already set in the shell.
local function monitorTail(opts)
    local log = opts.log
    local dl_list = opts.dl_list
    local timeout = opts.timeout
    local pidfile = opts.pidfile
    local statefile = opts.statefile
    local fbink = opts.fbink
    local has_fbink = opts.has_fbink
    local s = {}
    s[#s+1] = "echo $NSPID > " .. q(pidfile) .. "\n"
    s[#s+1] = "rm -f " .. q(statefile) .. "\n"
    -- fallback e-ink refresh (skipped while stopped)
    if has_fbink then
        s[#s+1] = "( while kill -0 $NSPID 2>/dev/null; do "
            .. "S=$(sed -e 's/.*) //' /proc/$NSPID/stat 2>/dev/null | cut -d' ' -f1); "
            .. "case \"$S\" in T|t) sleep 1; continue;; esac; "
            .. "sleep 4; " .. q(fbink) .. " -s >/dev/null 2>&1; done ) &\n"
        s[#s+1] = "FBPID=$!\n"
        -- download monitor: display at the top of the screen (KOReader is frozen)
        s[#s+1] = "( LAST=0; while kill -0 $NSPID 2>/dev/null; do "
            .. "if [ -f " .. q(dl_list) .. " ]; then "
            .. "C=$(wc -l < " .. q(dl_list) .. " 2>/dev/null || echo 0); "
            .. "if [ \"$C\" -gt \"$LAST\" ]; then "
            .. "N=$(tail -n1 " .. q(dl_list) .. " | sed 's#.*/##'); "
            .. q(fbink) .. " -q -y 1 -m \"Downloaded: $N\" >/dev/null 2>&1; LAST=$C; fi; fi; "
            .. "sleep 1; done ) &\n"
        s[#s+1] = "DLPID=$!\n"
    else
        s[#s+1] = "FBPID=\nDLPID=\n"
    end
    -- watchdog: kill after the specified timeout if frozen (not stopped, but in R/S state)
    s[#s+1] = "( sleep " .. tostring(timeout) .. "; kill $NSPID 2>/dev/null; sleep 2; kill -9 $NSPID 2>/dev/null ) &\n"
    s[#s+1] = "WDPID=$!\n"
    -- main supervisor loop: stopped (T) -> minimized; gone -> closed
    s[#s+1] = "MINI=0\n"
    s[#s+1] = "while kill -0 $NSPID 2>/dev/null; do "
        .. "S=$(sed -e 's/.*) //' /proc/$NSPID/stat 2>/dev/null | cut -d' ' -f1); "
        .. "case \"$S\" in T|t) MINI=1; break;; esac; "
        .. "sleep 0.3 2>/dev/null || sleep 1; done\n"
    s[#s+1] = "[ -n \"$FBPID\" ] && kill $FBPID 2>/dev/null\n"
    s[#s+1] = "[ -n \"$DLPID\" ] && kill $DLPID 2>/dev/null\n"
    s[#s+1] = "kill $WDPID 2>/dev/null\n"
    s[#s+1] = "if [ \"$MINI\" = \"1\" ]; then echo minimized > " .. q(statefile)
        .. "; else rm -f " .. q(pidfile) .. " " .. q(statefile) .. "; fi\n"
    -- restore the Kindle system status bar (KOReader redraws its own UI anyway)
    s[#s+1] = "lipc-set-prop com.lab126.pillow disableEnablePillow enable >/dev/null 2>&1\n"
    s[#s+1] = "lipc-set-prop com.lab126.pillow interactive 1 >/dev/null 2>&1\n"
    s[#s+1] = "lipc-set-prop com.lab126.pillow hideAll 0 >/dev/null 2>&1\n"
    s[#s+1] = "start statusbar >/dev/null 2>&1\n"
    if opts.verbose then s[#s+1] = "echo \"supervisor finished (MINI=$MINI) $(date)\" >> " .. q(log) .. "\n" end
    return table.concat(s)
end

-- Stop the Kindle system status bar ("pillow": clock at top left, battery at top right).
-- Try several MTK methods, log each result to NETSURF_FIELD_LOG,
-- and list the lipc properties/events offered by pillow so that if none
-- works, we can see exactly what the firmware supports.
-- Only FAST commands (enumeration was removed because it caused the ~15-second delay).
-- Your firmware responded OK to: disableEnablePillow disable and stop statusbar.
local function pillowStopBlock()
    return table.concat({
        "lipc-set-prop com.lab126.pillow disableEnablePillow disable >/dev/null 2>&1\n",
        "stop statusbar >/dev/null 2>&1\n",
    })
end

local function pillowStartCmd()
    return table.concat({
        "lipc-set-prop com.lab126.pillow disableEnablePillow enable >/dev/null 2>&1\n",
        "lipc-set-prop com.lab126.pillow interactive 1 >/dev/null 2>&1\n",
        "lipc-set-prop com.lab126.pillow hideAll 0 >/dev/null 2>&1\n",
        "start statusbar >/dev/null 2>&1\n",
    })
end

-- shell code for hosts-based ad blocking (append on startup, restore on EXIT)
local function hostsBlock(nsdir, data, enabled)
    if not (enabled and lfs.attributes(nsdir .. "/ad_hosts.txt", "mode") == "file") then return "" end
    return "HB=/etc/hosts\n"
        .. "HBAK=" .. q(data .. "/netsurf_hosts.bak") .. "\n"
        .. "[ -f \"$HBAK\" ] && cp \"$HBAK\" \"$HB\" 2>/dev/null && rm -f \"$HBAK\"\n"
        .. "AD=" .. q(nsdir .. "/ad_hosts.txt") .. "\n"
        .. "if [ -f \"$AD\" ] && [ -w \"$HB\" ]; then "
        .. "cp \"$HB\" \"$HBAK\" && cat \"$AD\" >> \"$HB\" && "
        .. "trap 'cp \"$HBAK\" \"$HB\" 2>/dev/null; rm -f \"$HBAK\"' EXIT INT TERM; fi\n"
end

-- run the script: release KOReader input, execute synchronously, then
-- reclaim input, redraw, process downloads, and read the state.
function NS:_execute(launch, dl_list)
    logger.info("NetSurf supervisor script:", launch)
    os.remove(self:_signalfile())   -- clear the previous reason for minimizing
    -- WARNING: do NOT delete the inject file here! resume() also goes through this
    -- _execute, and the field text is written just before resuming; deleting it here
    -- would leave the browser with an empty file. gui.c deletes it after reading,
    -- while a fresh launch clears it in run().
    local Screen = Device.screen
    pcall(function() Screen:refreshFull() end)
    UIManager:forceRePaint()

    -- KOReader grabs touch input exclusively (EVIOCGRAB); release it so NetSurf
    -- can receive events, then reopen it on return.
    local closed_paths = {}
    pcall(function()
        local input = Device and Device.input
        if input then
            if input.opened_devices then
                for path, _ in pairs(input.opened_devices) do
                    closed_paths[#closed_paths + 1] = path
                end
            end
            if #closed_paths == 0 then closed_paths[1] = "/dev/input/event1" end
            for _, path in ipairs(closed_paths) do
                pcall(function() input:close(path) end)
            end
        end
    end)

    local ok = os.execute("sh " .. q(launch))

    pcall(function()
        local input = Device and Device.input
        if input then
            for _, path in ipairs(closed_paths) do
                pcall(function() input:open(path) end)
            end
        end
    end)

    -- read the reason for minimizing EARLY, since redrawing depends on it
    local reason = nil
    pcall(function()
        local sf = io.open(self:_signalfile(), "r")
        if sf then reason = (sf:read("*l") or ""):gsub("%s+$", ""); sf:close() end
    end)
    os.remove(self:_signalfile())

    -- OVERLAY: for "url" (URL entry) and "menu" (swipe down from the top edge), do NOT
    -- redraw all of KOReader, so the input dialog / top menu appears ABOVE the frozen
    -- browser image (the browser stays visible). In all other cases, perform a full
    -- redraw (actual minimizing, closing, reader view, etc.).
    local overlay = (reason == "url" or reason == "menu" or reason == "field")
    if not overlay then
        pcall(function()
            UIManager:setDirty("all", "full")
            UIManager:forceRePaint()
        end)
        pcall(function()
            UIManager:scheduleIn(0.6, function()
                UIManager:setDirty("all", "full")
                UIManager:forceRePaint()
            end)
        end)
    end

    -- process files downloaded in NetSurf
    pcall(function()
        local f = io.open(dl_list, "r")
        if f then
            local paths = {}
            for line in f:lines() do
                line = line:gsub("%s+$", "")
                if line ~= "" and lfs.attributes(line, "mode") == "file" then
                    paths[#paths + 1] = line
                end
            end
            f:close()
            os.remove(dl_list)
            if #paths > 0 and self.on_downloads then
                self.on_downloads(paths)
            end
        end
    end)

    if reason == "url" then
        local recent = self:historyList(1)
        self:_promptUrl(recent and recent[1])
    elseif reason == "field" then
        self:_promptField()
    elseif reason == "reader" then
        local recent = self:historyList(1)
        local u = recent and recent[1]
        if self.on_reader and u then self.on_reader(u) end
    elseif reason == "menu" then
        if self.on_menu then pcall(self.on_menu) end
    end

    return ok
end

-- Enter text in a page field using the KOReader keyboard (as an overlay, with the
-- browser visible in the background). Write the entered text to netsurf.inject;
-- on resume, the engine injects it into the focused field (with accents, as Unicode).
function NS:_promptField()
    local InputDialog = require("ui/widget/inputdialog")
    -- the browser wrote the field's current contents -> prefill for editing
    local cur = ""
    do
        local rf = io.open(self:_fieldtextfile(), "rb")
        if rf then cur = rf:read("*a") or ""; rf:close() end
        os.remove(self:_fieldtextfile())
        cur = cur:gsub("[\r\n]+$", "")
    end
    local dlg
    dlg = InputDialog:new{
        title = S("Beírás a mezőbe (a böngésző a háttérben marad)"),
        input = cur,
        input_hint = S("írd be a szöveget (pl. felhasználónév, jelszó)"),
        allow_newline = false,
        buttons = {{
            { text = S("Mégse"), callback = function()
                UIManager:close(dlg)
                self:resume()
            end },
            { text = S("Beírás"), is_enter_default = true, callback = function()
                local t = dlg:getInputText() or ""
                UIManager:close(dlg)
                local w = io.open(self:_injectfile(), "w")
                if w then w:write(t); w:close() end
                self:resume()
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- Enter a URL using the KOReader keyboard (with accents), prefilled with the CURRENT
-- URL; either resume the minimized background session (Cancel), or discard it
-- and launch with the new URL (Open).
function NS:_promptUrl(current)
    local InputDialog = require("ui/widget/inputdialog")
    local prefill = (current and current ~= "" and current:match("^%a[%w+.-]*://")) and current or "https://"
    local dlg
    dlg = InputDialog:new{
        title = S("InkSurf – cím vagy keresés"),
        input = prefill,
        input_hint = S("https://pelda.hu vagy keresőszó"),
        buttons = {{
            { text = S("Mégse"), callback = function()
                UIManager:close(dlg)
                self:resume()          -- return to the page in the background
            end },
            { text = S("Megnyitás"), is_enter_default = true, callback = function()
                local u = dlg:getInputText()
                UIManager:close(dlg)
                if u and u ~= "" and u ~= "https://" then
                    -- no scheme and contains a space / no dot -> search
                    if not u:match("^%a[%w+.-]*://") then
                        if u:find("%s") or not u:find("%.") then
                            u = "https://html.duckduckgo.com/html/?q=" .. u:gsub("[^%w]", function(c)
                                return string.format("%%%02X", string.byte(c)) end)
                        else
                            u = "https://" .. u
                        end
                    end
                    self:run(u)        -- discard the minimized session, start a fresh one with the new URL
                else
                    self:resume()
                end
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function NS:run(url)
    -- DIAGNOSTICS: clear the field log on each browser launch (resumes append)
    pcall(function() os.remove(self:_fieldlog()) end)
    -- discard any orphaned injection text on a fresh launch (NOT on resume!)
    os.remove(self:_injectfile())
    os.remove(self:_fieldtextfile())
    local bin = self:binary()
    if not bin then
        UIManager:show(InfoMessage:new{
            text = S("A NetSurf motor nincs telepítve.\n\nA netsurf.koplugin csomagot a plugins mappába kell másolni ")
                .. S("(a binárist GitHub Actions építi a Kindle-re)."),
        })
        return
    end

    -- if a minimized session exists and no SPECIFIC new URL was provided, resume it
    local mini = self:hasMinimized()
    if mini and (url == nil or url == "" or url == "about:welcome") then
        return self:resume()
    end
    -- discard the minimized session for a specific new URL (start a new session)
    if mini then self:_killSaved() end

    os.execute("chmod +x " .. q(bin) .. " 2>/dev/null")
    local nsdir = bin:gsub("/[^/]+$", "")

    -- NetSurf configuration file (Choices)
    local cacert = nsdir .. "/cacert.pem"
    if lfs.attributes(cacert, "mode") == "file" then
        local ch = io.open(nsdir .. "/res/Choices", "w")
        if ch then
            ch:write("ca_bundle:", cacert, "\n")
            ch:write("fb_depth:32\n")
            -- DISABLE the NATIVE toolbar ('q'): the frontend (kindlefb.c) instead draws
            -- its own KOReader-like top bar (large, spaced-out buttons, a smaller URL row,
            -- close/minimize always visible and not covered by the status bar).
            ch:write("fb_toolbar_layout:q\n")
            ch:write("fb_furniture_size:44\n")
            -- NetSurf's own OSK is OFF: all input fields (URL AND page fields) use
            -- the KOReader keyboard as an OVERLAY above the browser
            -- (the browser stays in the background). Text entered in page fields
            -- is injected back as Unicode.
            ch:write("fb_osk:0\n")
            ch:write("block_advertisements:1\n")
            local fdir = nsdir .. "/res/fonts/"
            if lfs.attributes(fdir .. "DejaVuSans.ttf", "mode") == "file" then
                ch:write("fb_face_sans_serif:", fdir, "DejaVuSans.ttf\n")
                ch:write("fb_face_sans_serif_bold:", fdir, "DejaVuSans-Bold.ttf\n")
                ch:write("fb_face_sans_serif_italic:", fdir, "DejaVuSans-Oblique.ttf\n")
                ch:write("fb_face_sans_serif_italic_bold:", fdir, "DejaVuSans-BoldOblique.ttf\n")
                ch:write("fb_face_serif:", fdir, "DejaVuSerif.ttf\n")
                ch:write("fb_face_serif_bold:", fdir, "DejaVuSerif-Bold.ttf\n")
                ch:write("fb_face_monospace:", fdir, "DejaVuSansMono.ttf\n")
                ch:write("fb_face_monospace_bold:", fdir, "DejaVuSansMono-Bold.ttf\n")
                ch:write("fb_face_cursive:", fdir, "DejaVuSerif.ttf\n")
                ch:write("fb_face_fantasy:", fdir, "DejaVuSans-Bold.ttf\n")
            end
            ch:write("cookie_file:", (self.data_dir or "/mnt/us/koreader"), "/netsurf_cookies\n")
            ch:write("cookie_jar:", (self.data_dir or "/mnt/us/koreader"), "/netsurf_cookies\n")
            ch:close()
        end
    end

    -- User stylesheet (images, ads, reader mode)
    local reader = self.settings and self.settings:readSetting("netsurf_reader") or false
    local ucss = nsdir .. "/res/user.css"
    local uf = io.open(ucss, "w")
    if uf then
        uf:write("img,svg,video,canvas,iframe{max-width:100% !important;height:auto !important;}\n")
        uf:write(
            "ins.adsbygoogle,[class*=\"adsbygoogle\"],",
            "[id^=\"google_ads\"],[id*=\"div-gpt-ad\"],[id*=\"gpt-ad\"],",
            "iframe[src*=\"doubleclick\"],iframe[src*=\"googlesyndication\"],",
            "iframe[src*=\"adserver\"],iframe[src*=\"/ads/\"],iframe[src*=\"amazon-adsystem\"],",
            "[class*=\"hirdetes\"],[class*=\"hirdetés\"],[id*=\"hirdetes\"],",
            "[class*=\"reklam\"],[class*=\"reklám\"],[class*=\"-ad-\"],[class*=\"_ad_\"],",
            "[class*=\"banner-ad\"],[class*=\"ad-banner\"],[data-ad],[data-ad-slot]",
            "{display:none !important;}\n")
        if reader then
            uf:write(
                "*,*::before,*::after{position:static !important;float:none !important;",
                "clear:none !important;transform:none !important;}\n",
                "*{overflow:visible !important;max-height:none !important;}\n",
                "[style*=\"display:flex\"],[style*=\"display: flex\"],",
                "[style*=\"display:grid\"],[style*=\"display: grid\"]{display:block !important;}\n",
                "img,svg{max-width:360px !important;}\n")
        end
        uf:close()
    end

    local data = self.data_dir or "/mnt/us/koreader"
    local log = data .. "/netsurf.log"
    local launch = data .. "/netsurf_launch.sh"
    local hosts_adblock = not (self.settings and self.settings:readSetting("netsurf_hosts_adblock") == false)
    local dl_dir = (self.download_dir_fn and self.download_dir_fn()) or (data .. "/Downloads")
    local dl_list = data .. "/netsurf_downloads.list"
    os.remove(dl_list)
    local timeout = self.settings and self.settings:readSetting("netsurf_timeout") or 1800
    -- Debug logging: OFF by default. Enable in settings (netsurf_verbose=true)
    -- to create netsurf.log and netsurf_field.log for detailed tracing.
    local verbose = self.settings and self.settings:readSetting("netsurf_verbose") == true or false

    local fbink = nsdir .. "/fbink"
    local has_fbink = lfs.attributes(fbink, "mode") == "file"

    local sh = io.open(launch, "w")
    if not sh then
        UIManager:show(InfoMessage:new{ text = S("Nem tudok írni ide:\n") .. launch })
        return
    end
    sh:write(
        "#!/bin/sh\n",
        verbose and ("echo \"NetSurf launch: $(date)\" > " .. q(log) .. "\n") or "",
        "export NETSURFRES=", q(nsdir .. "/res"), "\n",
        "export HOME=", q(os.getenv("HOME") or "/mnt/us"), "\n",
        has_fbink and ("chmod +x " .. q(fbink) .. " 2>/dev/null\n") or "",
        "export FRAMEBUFFER=/dev/fb0\n",
        "export NETSURF_DOWNLOAD_DIR=", q(dl_dir), "\n",
        "export NETSURF_DL_LIST=", q(dl_list), "\n",
        "export NETSURF_SIGNAL_FILE=", q(self:_signalfile()), "\n",
        "export NETSURF_HISTORY_FILE=", q(self:_historyfile()), "\n",
        "export NETSURF_INJECT_FILE=", q(self:_injectfile()), "\n",
        "export NETSURF_FIELD_TEXT=", q(self:_fieldtextfile()), "\n",
        (function() local _ua = self:_userAgent(); return _ua and ("export NETSURF_USER_AGENT=" .. q(_ua) .. "\n") or "" end)(),
        verbose and ("export NETSURF_FIELD_LOG=" .. q(self:_fieldlog()) .. "\n") or "",
        hostsBlock(nsdir, data, hosts_adblock),
        -- hide the Kindle system status bar (clock/battery chrome) while browsing
        pillowStopBlock(),
        has_fbink and (q(fbink) .. " -f -k >/dev/null 2>&1\n") or "",
        q(bin), verbose and " -v" or "", " -f kindle -w 1272 -h 1696 ", q(url or "about:welcome"),
        verbose and (" >> " .. q(log) .. " 2>&1 &\n") or " >/dev/null 2>&1 &\n",
        "NSPID=$!\n",
        monitorTail{ log = log, dl_list = dl_list, timeout = timeout, verbose = verbose,
                     pidfile = self:_pidfile(), statefile = self:_statefile(),
                     fbink = fbink, has_fbink = has_fbink }
    )
    sh:close()

    self:_execute(launch, dl_list)
end

-- wake (SIGCONT) and supervise a minimized session
function NS:resume()
    local alive, pid = self:hasMinimized()
    if not alive then
        -- nothing to resume: fresh launch
        return self:run("about:welcome")
    end
    local bin = self:binary()
    local nsdir = bin and bin:gsub("/[^/]+$", "") or ""
    local data = self.data_dir or "/mnt/us/koreader"
    local log = data .. "/netsurf.log"
    local resume_sh = data .. "/netsurf_resume.sh"
    local dl_list = data .. "/netsurf_downloads.list"
    local hosts_adblock = not (self.settings and self.settings:readSetting("netsurf_hosts_adblock") == false)
    local timeout = self.settings and self.settings:readSetting("netsurf_timeout") or 1800
    local verbose = self.settings and self.settings:readSetting("netsurf_verbose") == true or false
    local fbink = nsdir .. "/fbink"
    local has_fbink = lfs.attributes(fbink, "mode") == "file"

    local sh = io.open(resume_sh, "w")
    if not sh then
        UIManager:show(InfoMessage:new{ text = S("Nem tudok írni ide:\n") .. resume_sh })
        return
    end
    sh:write(
        "#!/bin/sh\n",
        verbose and ("echo \"NetSurf resume: $(date)\" >> " .. q(log) .. "\n") or "",
        "export NETSURF_SIGNAL_FILE=", q(self:_signalfile()), "\n",
        "export NETSURF_HISTORY_FILE=", q(self:_historyfile()), "\n",
        "export NETSURF_INJECT_FILE=", q(self:_injectfile()), "\n",
        "export NETSURF_FIELD_TEXT=", q(self:_fieldtextfile()), "\n",
        (function() local _ua = self:_userAgent(); return _ua and ("export NETSURF_USER_AGENT=" .. q(_ua) .. "\n") or "" end)(),
        verbose and ("export NETSURF_FIELD_LOG=" .. q(self:_fieldlog()) .. "\n") or "",
        "NSPID=", tostring(pid), "\n",
        hostsBlock(nsdir, data, hosts_adblock),
        pillowStopBlock(),
        -- wake up: SIGCONT. The frontend immediately redisplays its saved image.
        "kill -CONT $NSPID 2>/dev/null\n",
        monitorTail{ log = log, dl_list = dl_list, timeout = timeout, verbose = verbose,
                     pidfile = self:_pidfile(), statefile = self:_statefile(),
                     fbink = fbink, has_fbink = has_fbink }
    )
    sh:close()

    self:_execute(resume_sh, dl_list)
end

-- permanently kill the saved (minimized) session
function NS:_killSaved()
    local pf = io.open(self:_pidfile(), "r")
    if pf then
        local pid = tonumber((pf:read("*l") or "")); pf:close()
        if pid then
            -- resume a stopped process first so TERM can take effect
            os.execute("kill -CONT " .. pid .. " 2>/dev/null; kill " .. pid
                .. " 2>/dev/null; sleep 1; kill -9 " .. pid .. " 2>/dev/null")
        end
    end
    os.remove(self:_pidfile())
    os.remove(self:_statefile())
end

function NS:openUrl(url)
    if not self:available() then return self:run(url) end
    UIManager:show(ConfirmBox:new{
        text = S("Megnyitod a NetSurf motorban?\n(valódi böngésző, korlátozott JavaScripttel)\n\n") .. (url or ""),
        ok_text = S("Megnyitás"),
        cancel_text = S("Mégse"),
        ok_callback = function() self:run(url) end,
    })
end

return NS
