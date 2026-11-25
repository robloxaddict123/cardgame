--[[
    PibbleHub
    =====================================================================
    Layout of this file (search for the "== N." headers):
       1. Services & remotes
       2. Config & static data
       3. Shared state (one table per feature)
       4. Settings (saved to a file, restored on the next launch)
       5. Generic helpers
       6. Window & UI builders
       7. GUI automation helpers (find / press the game's buttons)
      7b. Anti-AFK
      7c. World teleport (Auto Boss: each boss NPC lives in its own world)
       8. Feature: Auto Mine
      10. Feature: Auto Boss
      11. Feature: Infinite Tower (auto give up when a weather appears)
     11b. Feature: Auto Raid (4 fights at xx:00 and xx:30, 15 min window)
     11c. Feature: Auto Dungeon (left when the raid opens, restarted after the raid)
     11d. Feature: Auto World Boss (Berserk Creation: up 1 h / gone 1 h, even UTC hours)
     11e. Feature: Priority (the user orders the automations: who gets the player first)
     11f. Feature: Settings tab (UI scale, window position)
     11h. Feature: Expeditions (auto claim / redeploy / deploy)
     11i. Feature: Watchdog (resets a stuck automation, anti-AFK, Discord alert)
     11j. Feature: Performance mode (black screen, low graphics, no effects, mute, FPS cap)
     11g. Feature: Generations (Infinite Tower results -> its own Discord webhook, with card pictures and a ping)
      12. BattleEnd router + restore of the saved switches
      13. Start-up (the icon was removed: the toggle button shows a "P")

    Every feature lives in its own do ... end block: its UI, its logic and its
    event wiring are all in one place. Features talk to each other only through
    the state tables from section 3 (Boss, Infinite, Raid, Dungeon, WorldBoss) and through
    the Prio helpers of section 4b (the user's priority list).
]]

local ICON_B64 -- base64 JPEG of the toggle-button icon (empty: the button shows a "P")

-- ===== DEBUG LOG =====
-- Every print / warn of the script is kept (last 900 lines, with the time), saved to PibbleHub_combo.txt every few
-- seconds and can be copied with the "Copy log" button of the Fishing tab: paste it to get a problem looked at.
local rawPrint, rawWarn = print, warn
local ComboLog = { lines = {}, max = 900, dirty = false, t0 = os.clock() }
local function logPush(kind, ...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = ("%s +%.1fs %s%s"):format(os.date("%H:%M:%S"), os.clock() - ComboLog.t0, kind, table.concat(parts, " "))
    local L = ComboLog.lines
    L[#L + 1] = line:sub(1, 400)
    if #L > ComboLog.max then table.remove(L, 1) end
    ComboLog.dirty = true
end
local print = function(...) rawPrint(...); pcall(logPush, "", ...) end
local warn = function(...) rawWarn(...); pcall(logPush, "WARN ", ...) end
ComboLog.push = function(...) pcall(logPush, "", ...) end
local logTok = {}
do local g = (getgenv and getgenv()) or _G; g.PibbleLogTok = logTok end
task.spawn(function()
    while ((getgenv and getgenv()) or _G).PibbleLogTok == logTok do -- a newer launch replaces this writer
        task.wait(5)
        if ComboLog.dirty and typeof(writefile) == "function" then
            ComboLog.dirty = false
            pcall(writefile, "PibbleHub_combo.txt", table.concat(ComboLog.lines, "\n"))
        end
    end
end)

local function runHub()
    -- =====================================================================
    -- == 1. SERVICES & REMOTES
    -- =====================================================================
    local Players = game:GetService("Players")
    local HttpService = game:GetService("HttpService")
    local R = game:GetService("ReplicatedStorage"):WaitForChild("Remotes")

    local Remotes = {
        BattleEnd = R:WaitForChild("BattleEnd"),
        EndTower = R:WaitForChild("EndTowerRemote", 5),     -- "Give up"
        Teleport = R:WaitForChild("TeleportToWorld", 5),    -- :FireServer("lobby")
        SetNPCDiff = R:WaitForChild("SetNPCDifficulty", 5), -- :FireServer("boss_rimuru", "impossible")
        StartNPC = R:WaitForChild("StartNPCBattle", 5),     -- :FireServer("boss_rimuru")
        StartRaid = R:WaitForChild("StartRaidBattle", 5),   -- :FireServer()  (Auto Raid)
    }
    local player = Players.LocalPlayer
    print("[PibbleHub] loading...")

    -- =====================================================================
    -- == 2. CONFIG & STATIC DATA
    -- =====================================================================
    local CFG = {
        AUTO_DELAY = 3,      -- seconds between two milestones / retries
        END_ARG = 1,         -- argument sent to EndTowerRemote (as logged when clicking Give up)
        BOSS_TIMEOUT = 300,  -- seconds: if no BattleEnd arrives, the fight is considered over
        BOSS_RETRIES = 2,    -- retries of the SAME boss + difficulty after a loss, before moving on
        BOSS_MIN_FIGHT = 5,  -- seconds: a BattleEnd received sooner than this is a stale event of the previous fight
        TIMER_CHECK_DELAY = 2.5, -- seconds after StartNPCBattle during which a "cooldown" answer is looked for
        TIMER_MARGIN = 2,    -- seconds added to a detected timer before trying that boss again
        RESYNC_SECS = 300,   -- the NPC dialog (timers of every difficulty) is read once per boss, then again only after this many seconds
        DIFF_DELAY = 0.3,    -- seconds to wait after SetNPCDifficulty (raise it if a fight starts on the wrong difficulty)
        BOSS_DELAY = 0.1,    -- seconds between the end of a boss fight and the next one
        BOSS_STAY_RANGE = 14, -- studs: closer than this to the boss NPC, Auto Boss stays put instead of teleporting again
        WIN_COOLDOWN = 600,  -- seconds a boss + difficulty stays on cooldown after a WIN (the dialog corrects it with the real timer on the next visit)
        COOLDOWN_BY_NPC = {}, -- NPCs whose cooldown is not WIN_COOLDOWN (seconds), e.g. { goku = 300 }
        UNKNOWN_COOLDOWN = 600, -- seconds a boss is put aside when the server refused it without telling the timer
        REFUSE_IF_SILENT = true, -- true: if the server sends NOTHING back after StartNPCBattle, the fight is treated as refused (cooldown)
        IGNORE_REMOTES = { CandyState = true }, -- legacy background events that do not count as a battle response
        TRUST_NPC_TIMER = false, -- true: also use the timer written above the NPC (it is NOT per difficulty, so it is off). The real per-difficulty timers are read from the NPC dialog
        DEBUG_TIMER = false,  -- print what the game shows / sends around each boss attempt (F9 console)
        RESTORE_DELAY = 3,   -- seconds after launch before the saved switches are restored
        POP_GIVEUP_LEFT = 60, -- Infinite Tower: a wanted weather is only given up when this many seconds (or less) are left on it
        GEN_SUFFIXES = {"k", "m", "b", "t", "qa", "qi", "sx", "sp", "oc", "no", "dc"}, -- amount suffixes in order (k = 1e3, m = 1e6 ... qa = 1e15): used to read card values like 85B and the "good" value the user types
        POTION_WORDS = {"weather"}, -- Infinite Tower potions: an inventory item whose name / text contains one of these words is a weather potion
        POTION_OVER_WEATHER = true, -- true: a potion is also used while a weather BELOW "Pop from" is active (to roll a new one); false: only while no weather is active
        POTION_CLOSE_DELAY = 1.2, -- seconds the inventory stays open after the last potion click
        POTION_COOLDOWN = 3, -- seconds between two potion uses while no weather has rolled yet
        ICON_ID = "",        -- optional: force an image, e.g. "rbxassetid://123456789" (empty = no icon, a "P" is shown)

        -- Auto Raid
        RAID_WORLD = "RaidWorld",   -- world id sent to TeleportToWorld
        RAID_FIGHTS = 4,            -- fights launched per raid
        RAID_INTERVAL = 30 * 60,    -- a raid slot every 30 min (xx:00 and xx:30, real clock)
        RAID_WINDOW = 15 * 60,      -- the raid can be done during the first 15 min of each slot
        RAID_TP_TIMEOUT = 25,       -- max seconds to wait for the teleport to RaidWorld to really happen (the character moves)
        RAID_LOAD_DELAY = 4,        -- extra seconds to let the raid world finish loading once we are there
        -- The raids. Each one has its own switch in the Auto Raid tab and is done once per slot (RAID_FIGHTS fights).
        --   id / label : short name (saved in the settings file) / name shown in the UI
        --   key        : word looked for in the boss's NPCId attribute (case, spaces and _ are ignored)
        --   npcId      : exact NPCId of the boss, when known (optional)
        --   names      : accepted model names / billboard texts of the boss
        --   portal     : model in Workspace.Portals, stepped into only when the boss is not found after the teleport
        --   world      : world id for TeleportToWorld (default RAID_WORLD)
        --   pos        : optional fixed position to stand at (overrides the boss detection)
        --   startArgs  : optional arguments for StartRaidBattle (default: none first, then the raid id on the next tries)
        --   interval / window : optional own schedule in seconds (default RAID_INTERVAL / RAID_WINDOW)
        --   genericFallback   : last resort, accept any NPC whose NPCId contains "raid" (and no other raid's key)
        --   fightAnyway       : fire the fights even when the boss was not found (how the first raid always worked)
        -- If a boss is not found, the "Scan raids" button prints the portals and raid NPCs to the F9 console.
        RAIDS = {
            { id = "soul_king", label = "Soul King", key = "soulking", npcId = "raid_soul_king_npc",
              names = {"Yhwach", "Soul King"}, portal = "RaidPortal", genericFallback = true, fightAnyway = true },
            { id = "beerus", label = "Beerus", key = "beerus", names = {"Beerus", "Destroyer Cat"}, portal = "RaidPortal_Beerus" },
            { id = "reid", label = "Reid", key = "reid", names = {"Reid"}, portal = "RaidPortal_Reid" },
        },
        RAID_NEAR = 1500,           -- if the raid boss is closer than this many studs, we are already in the raid world (no teleport)
        RAID_RETRY_EVERY = 60,      -- Auto: new attempt every X seconds when the raid could not start (until it really starts)
        RAID_START_TRIES = 3,       -- how many times StartRaidBattle is fired (and the game's own start button pressed) if the server does not react (fights 2-4 get 3 more tries)
        RAID_START_CHECK = 5,       -- seconds to wait for a server reaction after each try
        RAID_START_EVENTS = {"battle", "raid", "fight"}, -- a server event whose name contains one of these words = the fight was accepted
        RAID_FIGHT_DELAY = 2,       -- seconds between the end of a fight and the next one
        RAID_FIGHT_TIMEOUT = 10,    -- seconds: if no BattleEnd arrives after StartRaidBattle, go on with the next fight
        RAID_MIN_FIGHT = 2,         -- seconds: a BattleEnd received sooner than this is a stale event
        RAID_WAIT_OTHERS = 120,     -- max seconds to wait for a running boss fight before the raid starts
        RAID_SILENT_IS_COOLDOWN = false, -- no longer used: the 4 fights are ALWAYS attempted, the cooldown is read after them
        RAID_REFUSE_WORDS = {"cooldown", "cool down", "already", "limit", "come back", "try again", "not available", "no attempts", "no more", "completed"}, -- server texts with one of these are only logged / used to read the cooldown timer after the 4 fights, they never stop the raid
        RAID_END_EVENTS = {"end", "result", "complete", "finish", "victory", "defeat"}, -- fallback: a *raid* remote (not sync/state) whose name has one of these = the fight is over

        -- Auto Dungeon
        DUNGEON_NPC = "DungeonNPC",   -- name of the dungeon NPC model (Workspace.NPCs.DungeonNPC, prompt "Talk", "Marine Dungeon")
        DUNGEON_START_REMOTE = "",    -- optional: exact name of the remote that starts the dungeon (empty = auto-detect *dungeon* + start/enter/join)
        DUNGEON_LEAVE_REMOTE = "",    -- optional: exact name of the remote that leaves the dungeon (empty = auto-detect *dungeon* + leave/exit/quit)
        DUNGEON_ARGS = {},            -- optional: arguments sent with the start remote, e.g. {"marine_dungeon"}
        DUNGEON_LEAVE_ARGS = {},      -- optional: arguments sent with the leave remote
        DUNGEON_START_TRIES = 2,      -- how many times the start is attempted (remote, then NPC) before giving up
        DUNGEON_START_CHECK = 6,      -- seconds to wait for a server reaction / a teleport after each attempt
        DUNGEON_TIMEOUT = 0,          -- seconds: a dungeon running longer than this is left (0 = never)
        DUNGEON_COOLDOWN = 30,        -- seconds between the end of a dungeon and the next one (Tower / Boss get their turn in between)
        DUNGEON_GONE_AFTER = 20,      -- seconds without the dungeon's Exit button / dungeon events: we consider the dungeon was left (manually)
        DUNGEON_NEAR_NPC = 150,       -- studs: being this close to the DungeonNPC while a dungeon is "running" also means it was left

        -- Auto World Boss (Berserk Creation / CellMax: up 1 h, gone 1 h, real clock = UTC)
        WB_INTERVAL = 2 * 3600,       -- one slot every 2 hours
        WB_WINDOW = 3600,             -- the boss is up during the first hour of each slot (22:00-23:00 UTC = 2-3pm PST: even UTC hours)
        WB_OFFSET = 0,                -- seconds: shifts the slots (e.g. 3600 if the boss is up on ODD UTC hours instead)
        WB_LEAVE_MARGIN = 15,         -- seconds before the end of the window: Repeat is switched off and the arena is left
        WB_NEED_BANNER = true,        -- true: only start while "LEAVES xx:xx" is on screen (banner, or the World Boss window itself); false: trust the clock only
        WB_STOP_AT_FULL = true,       -- true: stop (Repeat off, leave the arena) once the server meter is full ("10M / 10M"), until the next window
        WB_BANNER_GRACE = 25,         -- seconds the "LEAVES" text may be missing during a run before the run is ended (the game hides the banner while its window is open)
        WB_PORTAL = "WorldBossPortal",     -- Workspace.WorldBossPortal (prompt "Travel", press E)
        WB_ARENA = "WorldBossArena",       -- Workspace.WorldBossArena
        WB_BOSS = "CellMax",               -- Workspace.WorldBossArena.CellMax
        WB_GUI = "WorldBossGui",           -- PlayerGui: the window with "Repeat: Off" and "FIGHT!"
        WB_STOP_GUI = "WorldBossStopRepeatGui", -- PlayerGui: the "stop repeat" button shown while repeating
        WB_BANNER = "WorldBossBannerGui",  -- PlayerGui: the banner with the timer
        WB_ARENA_NEAR = 1500,         -- studs: closer than this to CellMax = we are in the arena
        WB_PORTAL_NEAR = 1500,        -- studs: farther than this from the portal = go to the lobby first
        WB_STAND_DIST = 8,            -- studs in front of CellMax where we stand to open its window
        WB_ENTER_TRIES = 3,           -- how many times E is pressed at the portal
        WB_ENTER_CHECK = 12,          -- seconds to wait for the arena after each try
        WB_LOAD_DELAY = 2,            -- seconds to let the arena load after the teleport
        WB_UI_CHECK = 4,              -- seconds to wait for the window after standing next to CellMax
        WB_START_TRIES = 3,           -- how many times FIGHT! is pressed
        WB_START_CHECK = 6,           -- seconds to look for a sign that the fight started after each press
        WB_IDLE_RESTART = 120,        -- seconds without any sign of fighting before the entry steps are redone
        WB_WAIT_OTHERS = 120,         -- max seconds to wait for a running boss fight before entering
        WB_MAX_FAILS = 4,             -- failed attempts in a row before giving up (Auto tries again later)
        WB_RETRY_EVERY = 30,          -- Auto: new attempt every X seconds when the world boss could not start
        WB_CYCLE_DELAY = 4,           -- seconds between two attempts
    }

    local FONT = Enum.Font.SourceSansBold
    local ORANGE = Color3.fromRGB(255, 170, 58)
    local BLUE = Color3.fromRGB(72, 120, 244)
    local DARK = Color3.fromRGB(38, 43, 66)
    local RED = Color3.fromRGB(150, 54, 72)
    local GREEN = Color3.fromRGB(36, 158, 102)

    -- Weathers shown in the Infinite Tower menu
    local WEATHERS = {"Typhoon", "Blizzard", "Windstorm", "Sharingan", "Singularity", "Lightning",
                  "Monarch Domain", "Void", "Made in Heaven", "Manga"}

    -- Rarity order of the weathers, lowest first. "Pop from X +" pops X and every weather further down this list; the ones above X in the list are skipped.
    -- (Edit the order here if the game ranks them differently.)
    local WEATHER_ORDER = {"Typhoon", "Blizzard", "Windstorm", "Sharingan", "Singularity", "Lightning",
                  "Monarch Domain", "Void", "Made in Heaven", "Manga"}

    -- Auto Boss difficulties
    local DIFFS = {"normal", "medium", "hard", "extreme", "impossible"}

    -- Every NPC of every world, in progression order (the last one of each world is its boss)
    local BOSS_WORLDS = {
        {"Namek", {"goku", "vegeta", "boss_frieza"}},
        {"Leaf Village", {"naruto", "kakashi", "boss_pain"}},
        {"Dressrosa", {"usopp", "sanji", "boss_doflamingo"}},
        {"Shibuya", {"itadori", "toji", "boss_sukuna"}},
        {"Soul Society", {"rukia", "ichigo", "boss_aizen"}},
        {"Train to Kyoto", {"power", "denji", "boss_makima"}},
        {"Isekai", {"ise_tanya_npc", "ise_smith_npc", "boss_rimuru"}},
        {"Clover Kingdom", {"bc_magna_npc", "bc_nacht_npc", "boss_yami"}},
    }
    -- Reward of the first clear (grows with the difficulty), shown next to each NPC
    local FIRST_CLEAR = {
        boss_aizen = 800, boss_doflamingo = 60, boss_frieza = 40, boss_makima = 1000, boss_pain = 50,
        boss_rimuru = 1200, boss_sukuna = 400, denji = 300, goku = 20, ichigo = 250, ise_smith_npc = 350, ise_tanya_npc = 350,
        itadori = 200, kakashi = 30, naruto = 30, power = 300, rukia = 250, sanji = 40, toji = 200,
        usopp = 40, vegeta = 20,
    }

    -- Any of these battle results counts as a loss -> retry the SAME stage
    local LOSS = { lose = true, loss = true, lost = true, defeat = true, fail = true, failed = true }

    -- =====================================================================
    -- == 3. SHARED STATE
    -- =====================================================================
    local Boss = {
        auto = false,
        active = false,    -- a fight started by this script is running
        waiting = false,
        run = 0,           -- id of the current fight (for the timeout)
        current = nil,     -- {id, difficulty} of the fight in progress
        lastDone = nil,    -- key "id|difficulty" of the last finished fight (the queue resumes right after it)
        retries = 0,       -- losses in a row on the current fight
        started = false,   -- true once StartNPCBattle was fired for the current fight
        startedAt = 0,     -- os.clock() when it was fired
        lastEnd = 0,       -- os.clock() of the last handled BattleEnd
        cooldown = {},     -- "id|difficulty" -> os.time() when that fight is available again (saved to the file)
        timerWait = false, -- true while waiting in the lobby for a cooldown to end
        selected = {boss_rimuru = true}, -- selected NPC ids
        diffs = {},        -- selected difficulties (none = normal)
        setAuto = nil,     -- set by the Boss feature (used to restore the saved switch)
        resume = nil,      -- set by the Boss feature (restarts the queue after a raid)
    }
    local Infinite = {
        on = false,        -- "Pop" switch
        minFloor = 1,
        floor = 1,         -- current floor of the run
        lastGiveUp = 0,
        weathers = {},     -- selected weathers, lowercase name -> true (empty = any)
        popBusy = false,   -- the pop has the player: a good weather is waiting to be given up (or being given up), or a potion is being used. The portals wait while this is true
        potion = false,    -- "Potion" switch: use weather potions while no weather is active (needs "Pop from")
        potionAmount = "one", -- how many are used each time: "one" | "ten" | "all" | "custom"
        potionCustom = 10, -- the amount used when potionAmount is "custom"
        untilWeather = nil, -- "Pop from": lowercase weather name; only this weather or a better one is popped, lower ones are skipped
        setPop = nil,      -- set by the Infinite feature (used to restore the saved switch)
    }
    local Raid = {
        auto = false,
        running = false,   -- a raid is in progress: every other automation is paused
        fightStarted = false, -- StartRaidBattle was fired and its BattleEnd is awaited
        fightDone = false, -- the BattleEnd of the current raid fight arrived
        startedAt = 0,     -- os.clock() when the current raid fight was fired
        fights = 0,        -- fights finished in the current raid
        enabled = {},      -- raid id -> true/false: the raid's own switch (saved)
        slotsDone = {},    -- raid id -> slot number (os.time() // interval) in which its fights were done, one raid per slot (saved)
        counts = {},       -- raid id -> { slot = n, n = fights finished in that slot } (an interrupted raid continues from there)
        current = nil,     -- the raid (entry of CFG.RAIDS) being done right now
        setAuto = nil,     -- set by the Raid feature (used to restore the saved switch)
        onBattleEnd = nil, -- set by the Raid feature (used by the BattleEnd router)
        isOpen = nil,      -- set by the Raid feature: true while a raid is waiting to be done (Auto Raid ON, window open, not done)
    }
    -- The Portals feature fills this table, the other automations read it (who goes first is decided by Prio, section 4b).
    local Portal = {
        active = false,    -- a portal is being created / joined / played: nothing else may touch the player
        setFollow = nil,   -- set by the Portals feature (used to restore the saved Follow switch)
        ready = false,     -- a portal can be done right now (one is in the inventory, or a gate is up): Boss does not start new fights
        fighting = false,  -- inside the portal and its fight runs (Auto Fight is on): the player may leave for the Dagon (combo test)
    }
    local Dungeon = {
        auto = false,
        active = false,    -- a dungeon is starting / running: Boss leave the player alone
        startedAt = 0,
        lastEnd = -1e9,    -- os.clock() of the last end (the next dungeon waits DUNGEON_COOLDOWN)
        setAuto = nil,     -- set by the Dungeon feature (used to restore the saved switch)
        leave = nil,       -- set by the Dungeon feature (used by Auto Raid: leaves the dungeon when the raid opens)
        resume = nil,      -- set by the Dungeon feature (used by Auto Raid: starts the dungeon again after the raid)
        onBattleEnd = nil, -- set by the Dungeon feature (used by the BattleEnd router)
    }

    local WorldBoss = {
        auto = false,
        active = false,    -- the world boss is being entered / fought: every other automation is paused
        startedAt = 0,
        setAuto = nil,     -- set by the World Boss feature (used to restore the saved switch)
        leave = nil,       -- set by the World Boss feature (used by Auto Raid: leaves when the raid opens)
        resume = nil,      -- set by the World Boss feature (used by Auto Raid: goes back after the raid)
        wantsRun = nil,    -- set by the World Boss feature: true while it should be running (Auto ON, window open, boss up)
        onBattleEnd = nil, -- set by the World Boss feature (used by the BattleEnd router)
    }

    -- Auto Dagon (Fishing tab): fish with the game's Auto, fly to the sea boss zone when it appears, fight Dagon.
    local Dagon = {
        on = false,
        busy = false,      -- travelling to the zone / fighting: every automation ranked below it is paused
        wantsFn = nil,     -- set by the Fishing tab: true while Auto Dagon is on and the zone exists
        stop = nil,        -- set by the Fishing tab: stops a flight
        combo = false,     -- COMBO TEST: portal first (walk in, Auto on), then fly to the island while the portal fight runs
        faceWater = nil,   -- set by the Fishing tab: turns the player toward the water
        release = nil,     -- set by the Fishing tab: un-anchors the hovering player
        barUp = false,     -- the blue Dagon bar is on screen: a Dagon has appeared
        savedPos = nil,    -- the Dagon's location, saved when found and kept until the island is gone
        holdUntil = 0,     -- os.clock() until which the player counts as being at the fight (he stands next to the Dagon)
        ghostOn = false,   -- ghost mode is active (the character has no touch / query / collision while hovering)
        ghost = nil,       -- set by the Fishing tab: no touch / query / collision on the character while hovering in a portal
        edgeDir = nil,     -- combo: the outward direction at the island edge where the player hovers
        standoff = 0,      -- combo: studs the hover spot is kept away from the island (grows by 15 after every ejection)
        tpBlockUntil = 0,  -- os.clock() until which the teleport onto the Dagon is paused (after an ejection)
        hoverSpot = nil,   -- where the anchored player was put (a big jump away from it = ejected back to the portal)
        hoverRoot = nil,   -- combo test: the anchored root part while the player hovers above the island
        atZone = false,    -- Auto Dagon: on the island (or fighting): only then is the game's Auto fish switched on
        home = nil,        -- where the last flight to the zone started: the way back when the player ends up in the water
    }

    -- Priority list (helpers in section 4b, editor in the "Priority" tab): index 1 goes first.
    -- The default order below is the one the script always used.
    local Prio = {
        DEFAULT = {"Pop", "Dagon", "Raid", "WorldBoss", "Portal", "Boss", "Dungeon"},
        LABELS = { Pop = "Auto Pop", Dagon = "Auto Dagon", Raid = "Auto Raid", WorldBoss = "World Boss", Portal = "Portals", Boss = "Auto Boss", Dungeon = "Auto Dungeon" },
        order = {"Pop", "Dagon", "Raid", "WorldBoss", "Portal", "Boss", "Dungeon"}, -- the user's order (saved)
    }

    -- Window scale (editor in the "Settings" tab, applied by UI.apply once the window exists)
    local UI = { scale = 1, MIN = 0.6, MAX = 1.6, apply = nil }

    -- =====================================================================
    -- == 4. SETTINGS (saved to a file, restored on the next launch)
    -- =====================================================================
    -- Saved: selected bosses, difficulties, weathers, tower stage, min floor
    -- and the state of the Auto / Pop switches (restored a few seconds after launch,
    -- see the end of section 12).
    local Settings = {
        file = "PibbleHub_" .. tostring(player.UserId) .. ".json",
        armed = false,     -- saving only starts once the UI is built and the switches are restored
        queued = false,
        data = {},         -- what was loaded from the file
    }

    Settings.gen = { url = "", on = false, ping = "", good = "10b", sent = 0 } -- Generations webhook (its own URL, saved)
    Settings.exp = { on = false, tiers = { easy = true, medium = true, insane = true, nightmare = true, abyss = true, oblivion = true },
        redeploy = true, pick = "low", ends = {} } -- Expeditions (saved): ends[tier] = epoch time when it returns
    Settings.wd = { on = true, minutes = 30, afk = true, alert = true, resets = 0 } -- Watchdog (saved)
    Settings.fish = { on = false, travel = false, dagon = false } -- Auto Fish (saved)
    Settings.perf = { on = false, black = true, low = false, strip = true, mute = false, fps = 20 } -- Performance mode (saved)
    Settings.hook = { url = "", on = false, totals = { n = 0, items = {} } } -- Discord webhook of the portals (url is saved in the settings file)
    Settings.guard = { on = false, names = "" } -- Guard: stop everything when someone outside the whitelist joins (saved)
    Settings.follow = { name = "", on = false } -- Follow Join: the player whose portals are joined (saved)
    Settings.host = { on = false, names = "" }               -- Host wait: Auto Create holds Start until the picked player is in the room (saved)

    local function keysOf(t)
        local out = {}
        for k, v in pairs(t) do
            if v then out[#out + 1] = k end
        end
        table.sort(out)
        return out
    end

    -- keeps only the known values of a saved list
    local function toSet(list, valid)
        local set = {}
        if type(list) ~= "table" then return nil end
        for _, v in ipairs(list) do
            if valid[v] then set[v] = true end
        end
        return set
    end

    local function toValidSet(list)
        local s = {}
        for _, v in ipairs(list) do s[v] = true end
        return s
    end

    function Settings.load()
        local ok, data = pcall(function()
            if isfile and readfile and isfile(Settings.file) then
                return HttpService:JSONDecode(readfile(Settings.file))
            end
        end)
        Settings.data = (ok and type(data) == "table") and data or {}
    end

    -- cooldowns that are still running (expired ones are not worth saving)
    local function liveCooldowns()
        local out, now = {}, os.time()
        for k, v in pairs(Boss.cooldown) do
            if type(v) == "number" and v > now then out[k] = v end
        end
        return out
    end

    -- debounced: several changes in a row produce a single write
    function Settings.save()
        if not Settings.armed or Settings.queued then return end
        Settings.queued = true
        task.delay(0.5, function()
            Settings.queued = false
            pcall(function()
                if not writefile then return end
                writefile(Settings.file, HttpService:JSONEncode({
                    bosses = keysOf(Boss.selected),
                    diffs = keysOf(Boss.diffs),
                    weathers = keysOf(Infinite.weathers),
                    minFloor = Infinite.minFloor,
                    untilWeather = Infinite.untilWeather,
                    potion = Infinite.potion,
                    potionAmount = Infinite.potionAmount,
                    potionCustom = Infinite.potionCustom,
                    autoBoss = Boss.auto,
                    autoRaid = Raid.auto,
                    autoDungeon = Dungeon.auto,
                    autoWorldBoss = WorldBoss.auto,
                    pop = Infinite.on,
                    raidSlots = Raid.slotsDone,
                    raidsOn = (function()
                        local on = {}
                        for _, r in ipairs(CFG.RAIDS) do on[r.id] = Raid.enabled[r.id] == true end
                        return on
                    end)(),
                    genUrl = Settings.gen.url,
                    genOn = Settings.gen.on,
                    genPing = Settings.gen.ping,
                    genGood = Settings.gen.good,
                    expOn = Settings.exp.on,
                    expTiers = keysOf(Settings.exp.tiers),
                    expRedeploy = Settings.exp.redeploy,
                    expPick = Settings.exp.pick,
                    expEnds = Settings.exp.ends,
                    fishOn = Settings.fish.on,
                    fishTravel = Settings.fish.travel,
                    fishDagon = Settings.fish.dagon,
                    fishCombo = Settings.fish.combo,
                    fishStand = Settings.fish.stand,
                    perfOn = Settings.perf.on,
                    perfBlack = Settings.perf.black,
                    perfLow = Settings.perf.low,
                    perfStrip = Settings.perf.strip,
                    perfMute = Settings.perf.mute,
                    perfFps = Settings.perf.fps,
                    wdOn = Settings.wd.on,
                    wdMinutes = Settings.wd.minutes,
                    wdAfk = Settings.wd.afk,
                    wdAlert = Settings.wd.alert,
                    hookUrl = Settings.hook.url,
                    hookOn = Settings.hook.on,
                    hookTotals = Settings.hook.totals,
                    guardOn = Settings.guard.on,
                    guardNames = Settings.guard.names,
                    followName = Settings.follow.name,
                    followOn = Settings.follow.on,
                    hostOn = Settings.host.on,
                    hostNames = Settings.host.names,
                    cooldowns = liveCooldowns(),
                    priority = Prio.order,
                    uiScale = UI.scale,
                    theme = Settings.theme,
                }))
            end)
        end)
    end

    -- apply the saved values to the state tables
    Settings.load()
    do
        local d = Settings.data
        local validBosses, validDiffs, validWeathers = {}, toValidSet(DIFFS), {}
        for _, w in ipairs(BOSS_WORLDS) do
            for _, id in ipairs(w[2]) do validBosses[id] = true end
        end
        for _, w in ipairs(WEATHERS) do validWeathers[w:lower()] = true end

        Boss.selected = toSet(d.bosses, validBosses) or Boss.selected
        Boss.diffs = toSet(d.diffs, validDiffs) or Boss.diffs
        Infinite.weathers = toSet(d.weathers, validWeathers) or Infinite.weathers
        if type(d.untilWeather) == "string" and validWeathers[d.untilWeather:lower()] then
            Infinite.untilWeather = d.untilWeather:lower()
        end
        Infinite.potion = d.potion == true
        if d.potionAmount == "one" or d.potionAmount == "ten" or d.potionAmount == "all" or d.potionAmount == "custom" then
            Infinite.potionAmount = d.potionAmount
        end
        if tonumber(d.potionCustom) then Infinite.potionCustom = math.max(1, math.floor(tonumber(d.potionCustom))) end
        if tonumber(d.minFloor) then
            Infinite.minFloor = math.max(1, math.floor(tonumber(d.minFloor)))
        end
        if type(d.theme) == "string" then Settings.theme = d.theme end
        if tonumber(d.uiScale) then UI.scale = math.clamp(tonumber(d.uiScale), UI.MIN, UI.MAX) end
        if type(d.genUrl) == "string" then Settings.gen.url = d.genUrl end
        Settings.gen.on = d.genOn == true
        if type(d.genPing) == "string" then Settings.gen.ping = d.genPing end
        if type(d.genGood) == "string" then Settings.gen.good = d.genGood end
        Settings.exp.on = d.expOn == true
        local et = toSet(d.expTiers, { easy = true, medium = true, insane = true, nightmare = true, abyss = true, oblivion = true })
        if et then Settings.exp.tiers = et end
        if d.expRedeploy ~= nil then Settings.exp.redeploy = d.expRedeploy == true end
        if d.expPick == "high" or d.expPick == "low" then Settings.exp.pick = d.expPick end
        if d.fishOn ~= nil then Settings.fish.on = d.fishOn == true end
        if d.fishTravel ~= nil then Settings.fish.travel = d.fishTravel == true end
        if d.fishDagon ~= nil then Settings.fish.dagon = d.fishDagon == true end
        if d.fishCombo ~= nil then Settings.fish.combo = d.fishCombo == true end
        -- (the saved stand mode is no longer loaded: Auto Dagon always starts by standing at the middle)
        if d.perfOn ~= nil then Settings.perf.on = d.perfOn == true end
        if d.perfBlack ~= nil then Settings.perf.black = d.perfBlack == true end
        if d.perfLow ~= nil then Settings.perf.low = d.perfLow == true end
        if d.perfStrip ~= nil then Settings.perf.strip = d.perfStrip == true end
        if d.perfMute ~= nil then Settings.perf.mute = d.perfMute == true end
        if type(d.perfFps) == "number" and d.perfFps >= 10 and d.perfFps <= 240 then Settings.perf.fps = d.perfFps end
        if d.wdOn ~= nil then Settings.wd.on = d.wdOn == true end
        if type(d.wdMinutes) == "number" and d.wdMinutes >= 5 and d.wdMinutes <= 240 then Settings.wd.minutes = d.wdMinutes end
        if d.wdAfk ~= nil then Settings.wd.afk = d.wdAfk == true end
        if d.wdAlert ~= nil then Settings.wd.alert = d.wdAlert == true end
        if type(d.expEnds) == "table" then
            for k, v in pairs(d.expEnds) do
                if type(k) == "string" and type(v) == "number" then Settings.exp.ends[k] = v end
            end
        end
        if type(d.hookUrl) == "string" then Settings.hook.url = d.hookUrl end
        Settings.hook.on = d.hookOn == true
        if type(d.hookTotals) == "table" and type(d.hookTotals.items) == "table" then
            Settings.hook.totals = { n = tonumber(d.hookTotals.n) or 0, items = {} }
            for k, v in pairs(d.hookTotals.items) do
                if type(k) == "string" and type(v) == "number" then Settings.hook.totals.items[k] = v end
            end
        end
        if type(d.followName) == "string" then Settings.follow.name = d.followName end
        Settings.host.on = d.hostOn == true
        Settings.guard.on = d.guardOn == true
        if type(d.guardNames) == "string" then Settings.guard.names = d.guardNames end
        if type(d.hostNames) == "string" then Settings.host.names = d.hostNames end
        -- the raid of the slot that was already done / refused is not tried again after a relaunch
        if tonumber(d.raidSlot) then Raid.slotsDone.soul_king = math.floor(tonumber(d.raidSlot)) end -- save file of an older version
        if type(d.raidSlots) == "table" then
            for k, v in pairs(d.raidSlots) do
                if type(k) == "string" and tonumber(v) then Raid.slotsDone[k] = math.floor(tonumber(v)) end
            end
        end
        for _, r in ipairs(CFG.RAIDS) do
            local saved = type(d.raidsOn) == "table" and d.raidsOn[r.id] or nil
            Raid.enabled[r.id] = saved ~= false -- every raid is ON until the user switches it off
        end
        -- boss cooldowns still running (absolute times, so they stay valid after a relaunch)
        if type(d.cooldowns) == "table" then
            local now = os.time()
            for k, v in pairs(d.cooldowns) do
                if type(k) == "string" and type(v) == "number" and v > now then Boss.cooldown[k] = v end
            end
        end
    end

    -- =====================================================================
    -- == 4b. PRIORITY (the user's own order of the automations)
    -- =====================================================================
    -- Rules:
    --  * A feature does not START (automatically) while a feature ranked ABOVE it is running or ready to run.
    --  * Raid and World Boss are timed events: when they start they interrupt the running features ranked BELOW them
    --    (the dungeon is left, the world boss stops) and wait for the ones that cannot be interrupted (boss fight, portal).
    --  * Features never run at the same time, whatever the order is: a running feature is only ever waited for, or
    --    interrupted by Raid / World Boss.
    do
        local saved = Settings.data.priority
        if type(saved) == "table" then
            -- an order saved before a feature existed (Auto Pop, Auto Dagon): it is added at its default place
            local has = {}
            for _, n in ipairs(saved) do has[n] = true end
            for i, n in ipairs(Prio.DEFAULT) do
                if not has[n] then table.insert(saved, math.min(i, #saved + 1), n) end
            end
        end
        if type(saved) == "table" and #saved == #Prio.DEFAULT then
            local seen, valid = {}, true
            for _, n in ipairs(saved) do
                if type(n) ~= "string" or not Prio.LABELS[n] or seen[n] then valid = false break end
                seen[n] = true
            end
            if valid then
                Prio.order = {}
                for i, n in ipairs(saved) do Prio.order[i] = n end
            end
        end
    end

    function Prio.label(name) return Prio.LABELS[name] or tostring(name) end

    function Prio.rank(name)
        for i, n in ipairs(Prio.order) do
            if n == name then return i end
        end
        return #Prio.order + 1
    end

    function Prio.outranks(a, b) return Prio.rank(a) < Prio.rank(b) end

    -- the feature has the player right now (a fight / raid / dungeon / portal is going on)
    function Prio.running(name)
        if name == "Pop" then return Infinite.popBusy == true
        elseif name == "Dagon" then return Dagon.busy == true
        elseif name == "Raid" then return Raid.running == true
        elseif name == "WorldBoss" then return WorldBoss.active == true
        elseif name == "Portal" then return Portal.active == true
        elseif name == "Boss" then return Boss.active == true
        elseif name == "Dungeon" then return Dungeon.active == true end
        return false
    end

    -- the feature is switched on
    function Prio.enabled(name)
        if name == "Pop" then return Infinite.on == true
        elseif name == "Dagon" then return Dagon.on == true
        elseif name == "Raid" then return Raid.auto == true
        elseif name == "WorldBoss" then return WorldBoss.auto == true
        elseif name == "Portal" then return Portal.isOn ~= nil and Portal.isOn() == true
        elseif name == "Boss" then return Boss.auto == true
        elseif name == "Dungeon" then return Dungeon.auto == true end
        return false
    end

    -- the feature is ready to run and only waits for its turn
    function Prio.wants(name)
        if name == "Dagon" then
            return not Dagon.busy and Dagon.wantsFn ~= nil and Dagon.wantsFn() == true
        elseif name == "Raid" then
            return not Raid.running and Raid.isOpen ~= nil and Raid.isOpen() and true or false
        elseif name == "WorldBoss" then
            return not WorldBoss.active and WorldBoss.wantsRun ~= nil and WorldBoss.wantsRun() and true or false
        elseif name == "Portal" then
            return not Portal.active and Portal.ready == true
        elseif name == "Boss" then
            return Boss.auto and not Boss.active and not Boss.timerWait
                and (Boss.hasWork == nil or Boss.hasWork()) and true or false
        elseif name == "Dungeon" then
            return Dungeon.auto and not Dungeon.active
                and os.clock() - Dungeon.lastEnd >= CFG.DUNGEON_COOLDOWN and true or false
        end
        return false
    end

    -- the first feature ranked above `name` that is running or ready to run (nil = nothing is in front of it)
    function Prio.blockedBy(name)
        for i = 1, Prio.rank(name) - 1 do
            local other = Prio.order[i]
            -- combo: a new portal is only created while no Dagon is up; with the Dagon bar on screen the portals wait
            if not (other == "Dagon" and name == "Portal" and Dagon.combo and not Dagon.barUp) then
                if Prio.running(other) then return other end
                local ok, w = pcall(Prio.wants, other)
                if ok and w then return other end
            end
        end
        return nil
    end

    -- after a raid / world boss: gives every switched-on feature its turn back, in priority order
    -- (each one still checks the start rules above). Returns false when nothing was resumed.
    function Prio.resumeAll()
        local any = false
        for _, n in ipairs(Prio.order) do
            if n == "WorldBoss" then
                if WorldBoss.wantsRun and WorldBoss.wantsRun() and WorldBoss.resume then
                    any = true
                    WorldBoss.resume()
                end
            elseif n == "Boss" then
                if Boss.auto and Boss.resume then any = true; Boss.resume() end
            elseif n == "Dungeon" then
                if Dungeon.auto and Dungeon.resume then any = true; Dungeon.resume() end
            end
        end
        return any
    end

    -- stops a running feature (same steps the Watchdog uses to free a stuck one). Used by Auto Pop: a pop that is
    -- ranked above a feature takes the player away from it, and the feature gets its turn back when the pop is over.
    function Prio.interrupt(name)
        if name == "Dagon" then
            if Dagon.stop then pcall(Dagon.stop) end
        elseif name == "Boss" then
            Boss.run = Boss.run + 1 -- cancels the pending timeout of the fight
            Boss.active, Boss.started, Boss.timerWait = false, false, false
        elseif name == "Raid" then
            Raid.running, Raid.fightStarted = false, false
        elseif name == "Dungeon" then
            if Dungeon.leave then task.spawn(function() pcall(Dungeon.leave) end) end
            Dungeon.active = false
            Dungeon.lastEnd = os.clock()
        elseif name == "WorldBoss" then
            if WorldBoss.leave then task.spawn(function() pcall(WorldBoss.leave) end) end
            WorldBoss.active = false
        elseif name == "Portal" then
            Portal.active = false
        end
    end

    function Prio.move(i, dir)
        local j = i + dir
        if j < 1 or j > #Prio.order then return false end
        Prio.order[i], Prio.order[j] = Prio.order[j], Prio.order[i]
        Settings.save()
        return true
    end

    function Prio.reset()
        Prio.order = {}
        for i, n in ipairs(Prio.DEFAULT) do Prio.order[i] = n end
        Settings.save()
    end

    -- =====================================================================
    -- == 5. GENERIC HELPERS
    -- =====================================================================
    local function clean(t) return (tostring(t):gsub("<[^>]+>", "")) end

    -- true when the object and all its parents are visible / enabled
    local function shown(o)
        local x = o
        while x and x ~= game do
            if x:IsA("LayerCollector") then -- ScreenGui, BillboardGui, SurfaceGui
                if not x.Enabled then return false end
            elseif x:IsA("GuiObject") then
                if not x.Visible then return false end
            end
            x = x.Parent
        end
        return true
    end

    -- "boss_rimuru" -> "Rimuru", "hw_seras_integra" -> "Seras Integra"
    local BOSS_DISPLAY_NAMES = {
        bc_magna_npc = "Flaming Bat",
        bc_nacht_npc = "Quad Devil User",
        boss_yami = "Bull Captain",
    }

    local function niceName(id)
        if BOSS_DISPLAY_NAMES[id] then return BOSS_DISPLAY_NAMES[id] end
        local n = id:gsub("^boss_", ""):gsub("^hw_", ""):gsub("_npc$", ""):gsub("_", " ")
        return (n:gsub("(%a)([%w]*)", function(f, r) return f:upper() .. r end))
    end

    local function getHRP()
        return player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    end

    local function logEnd(tag, data)
        pcall(function()
            print("[PibbleHub] BattleEnd (" .. tag .. "):", HttpService:JSONEncode(data))
        end)
    end

    local function b64decode(data)
        local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        local map = {}
        for i = 1, #alphabet do map[alphabet:byte(i)] = i - 1 end
        local out, buf, bits = {}, 0, 0
        for i = 1, #data do
            local v = map[data:byte(i)]
            if v then
                buf = buf * 64 + v
                bits += 6
                if bits >= 8 then
                    bits -= 8
                    local byte = math.floor(buf / 2 ^ bits)
                    buf = buf - byte * 2 ^ bits
                    out[#out + 1] = string.char(byte)
                end
            end
        end
        return table.concat(out)
    end

    -- =====================================================================
    -- == 6. WINDOW & UI BUILDERS
    -- =====================================================================
    local UserInputService = game:GetService("UserInputService")

    -- Relaunch: unload the previous copy first (stops its loops, removes its window)
    do
        local genv = (getgenv and getgenv()) or _G
        if genv.PibbleUnload then pcall(genv.PibbleUnload) end
    end

    local ExecName = "unknown"
    -- Executor check (any executor: Delta, Potassium, ...): prints which of the functions the hub uses are missing, so a feature that does
    -- not work can be traced to the executor. The hub itself has a fallback for most of them.
    do
        local ex = "unknown"
        pcall(function() if typeof(identifyexecutor) == "function" then ex = tostring((identifyexecutor())) end end)
        ExecName = ex:lower()
        local want = {
            "gethui", "getgenv", "request", "http_request", "writefile", "readfile", "isfile", "appendfile", "setclipboard",
            "firesignal", "getconnections", "fireproximityprompt", "firetouchinterest",
        }
        local missing = {}
        for _, n in ipairs(want) do
            local v = (getgenv and getgenv() or _G)[n]
            if v == nil then v = _G[n] end
            if typeof(v) ~= "function" then missing[#missing + 1] = n end
        end
        if typeof(syn) == "table" or typeof(http) == "table" or typeof(fluxus) == "table" then
            for i = #missing, 1, -1 do if missing[i] == "request" or missing[i] == "http_request" then table.remove(missing, i) end end
        end
        print("[PibbleHub] executor: " .. ex .. (#missing > 0 and ("  |  missing: " .. table.concat(missing, ", ")) or "  |  all functions present"))
    end

    local guiParent = (gethui and gethui()) or player:WaitForChild("PlayerGui")
    for _, n in ipairs({"PibbleHub", "HalloweenUI"}) do
        local old = guiParent:FindFirstChild(n)
        if old then old:Destroy() end
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = "PibbleHub"
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = guiParent

    -- every connection to a long-lived signal (input, remotes, frame properties, frame loop) goes through connect():
    -- all of them are dropped together when the hub unloads, so a relaunch never stacks old listeners
    local Conns = {}
    local function connect(signal, fn)
        local c = signal:Connect(fn)
        Conns[#Conns + 1] = c
        return c
    end
    gui.Destroying:Connect(function()
        for _, c in ipairs(Conns) do pcall(function() c:Disconnect() end) end
        Conns = {}
    end)

    -- a remote that fires more than 12 times a second is background traffic, not a battle message: it is skipped
    -- (building text from every chatty event costs a lot of CPU and garbage on a small emulator)
    local eventRate = setmetatable({}, { __mode = "k" })
    local function tooChatty(r)
        local now = os.clock()
        local e = eventRate[r]
        if not e then e = { now, 0 }; eventRate[r] = e end
        if now - e[1] > 1 then e[1], e[2] = now, 0 end
        e[2] += 1
        return e[2] > 12
    end

    -- theme (ORANGE / BLUE / DARK / RED / GREEN come from section 2)
    -- colour themes (picked in the Settings tab, applied on the next launch). ACCENT is the heading / highlight colour
    -- (the variable keeps its old name ORANGE), ACCENT2 is the second colour of every gradient.
    local function rgb(r, g, b) return Color3.fromRGB(r, g, b) end
    local THEMES = {
        { name = "Aurora", BG = rgb(12, 9, 30), PANEL = rgb(23, 17, 50), PANEL2 = rgb(38, 29, 78), BORDER = rgb(86, 66, 150),
          MUTED = rgb(172, 160, 214), TEXT = rgb(246, 242, 255), OFFC = rgb(110, 98, 150),
          ACCENT = rgb(190, 132, 255), ACCENT2 = rgb(64, 226, 255), BLUE = rgb(112, 88, 245), DARK = rgb(48, 38, 94) },
        { name = "Ocean", BG = rgb(5, 15, 27), PANEL = rgb(9, 28, 47), PANEL2 = rgb(15, 45, 73), BORDER = rgb(36, 92, 130),
          MUTED = rgb(140, 188, 214), TEXT = rgb(238, 249, 255), OFFC = rgb(84, 124, 150),
          ACCENT = rgb(58, 218, 255), ACCENT2 = rgb(96, 128, 255), BLUE = rgb(34, 136, 232), DARK = rgb(19, 52, 82) },
        { name = "Rose", BG = rgb(24, 9, 18), PANEL = rgb(40, 15, 31), PANEL2 = rgb(62, 25, 48), BORDER = rgb(122, 48, 90),
          MUTED = rgb(216, 152, 188), TEXT = rgb(255, 242, 248), OFFC = rgb(142, 90, 118),
          ACCENT = rgb(255, 98, 164), ACCENT2 = rgb(255, 176, 92), BLUE = rgb(218, 70, 140), DARK = rgb(72, 28, 56) },
        { name = "Emerald", BG = rgb(5, 20, 15), PANEL = rgb(9, 35, 28), PANEL2 = rgb(15, 54, 43), BORDER = rgb(34, 116, 90),
          MUTED = rgb(142, 208, 188), TEXT = rgb(236, 255, 249), OFFC = rgb(82, 134, 118),
          ACCENT = rgb(52, 232, 164), ACCENT2 = rgb(122, 222, 255), BLUE = rgb(24, 168, 128), DARK = rgb(17, 62, 49) },
        { name = "Sunset", BG = rgb(20, 10, 24), PANEL = rgb(34, 17, 40), PANEL2 = rgb(54, 27, 62), BORDER = rgb(112, 58, 108),
          MUTED = rgb(206, 160, 196), TEXT = rgb(255, 245, 240), OFFC = rgb(134, 96, 130),
          ACCENT = rgb(255, 148, 58), ACCENT2 = rgb(255, 78, 140), BLUE = rgb(236, 96, 78), DARK = rgb(66, 32, 74) },
        { name = "Midnight", BG = rgb(11, 13, 21), PANEL = rgb(18, 21, 33), PANEL2 = rgb(29, 33, 51), BORDER = rgb(52, 58, 88),
          MUTED = rgb(143, 150, 180), TEXT = rgb(238, 240, 249), OFFC = rgb(96, 102, 128),
          ACCENT = rgb(255, 170, 58), ACCENT2 = rgb(110, 130, 255), BLUE = rgb(72, 120, 244), DARK = rgb(38, 43, 66) },
    }
    local theme = THEMES[1]
    for _, t in ipairs(THEMES) do
        if t.name == Settings.theme then theme = t end
    end
    Settings.theme = theme.name
    local BG, PANEL, PANEL2, BORDER = theme.BG, theme.PANEL, theme.PANEL2, theme.BORDER
    local MUTED, TEXT, OFFC, ACCENT2 = theme.MUTED, theme.TEXT, theme.OFFC, theme.ACCENT2
    ORANGE, BLUE, DARK = theme.ACCENT, theme.BLUE, theme.DARK
    local TweenService = game:GetService("TweenService")

    local WIN_W, WIN_H, BAR_H = 460, 660, 40

    local function addStroke(o, color, thickness, transparency)
        local s = Instance.new("UIStroke")
        s.Color = color or BORDER
        s.Thickness = thickness or 1
        s.Transparency = transparency or 0
        s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        s.Parent = o
        return s
    end

    local function round(o, r)
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, r or 8)
        c.Parent = o
        return c
    end

    -- soft vertical gradient. The colours are WHITE-ish multipliers, so a feature can still recolour the object
    -- (ON = green / OFF = red) and the gradient just adds depth on top of that colour.
    local function shade(o, top, bottom, rotation)
        local g = Instance.new("UIGradient")
        g.Color = ColorSequence.new(top or Color3.fromRGB(255, 255, 255), bottom or Color3.fromRGB(205, 208, 220))
        g.Rotation = rotation or 90
        g.Parent = o
        return g
    end

    local function tween(o, props, t)
        pcall(function() TweenService:Create(o, TweenInfo.new(t or 0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play() end)
    end

    -- Drag by a handle (mouse and touch). Returns a table whose .moved is the longest drag distance of the
    -- last press, so a click handler can ignore a click that was really a drag.
    local function makeDraggable(handle, target)
        local state = {moved = 0}
        local dragging, startMouse, startPos = false, nil, nil
        handle.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                state.moved = 0
                startMouse = input.Position
                startPos = target.Position
                input.Changed:Connect(function()
                    if input.UserInputState == Enum.UserInputState.End then dragging = false end
                end)
            end
        end)
        connect(UserInputService.InputChanged, function(input)
            if not dragging or not target.Parent then return end
            if input.UserInputType == Enum.UserInputType.MouseMovement
                or input.UserInputType == Enum.UserInputType.Touch then
                local d = input.Position - startMouse
                state.moved = math.max(state.moved, d.Magnitude)
                target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                    startPos.Y.Scale, startPos.Y.Offset + d.Y)
            end
        end)
        return state
    end

    local win = Instance.new("Frame")
    win.Name = "Window"
    win.Size = UDim2.fromOffset(WIN_W, WIN_H)
    win.AnchorPoint = Vector2.new(0.5, 0.5)
    win.Position = UDim2.fromScale(0.5, 0.5)
    win.BackgroundColor3 = BG
    win.BorderSizePixel = 0
    win.Active = true
    win.ClipsDescendants = true
    win.ZIndex = 1
    win.Parent = gui
    round(win, 14)
    shade(win, Color3.fromRGB(255, 255, 255), Color3.fromRGB(175, 180, 205), 90)
    do
        local ws = addStroke(win, BORDER, 1.5, 0)
        local g = Instance.new("UIGradient")
        g.Color = ColorSequence.new(ORANGE, ACCENT2)
        g.Rotation = 35
        g.Parent = ws
    end

    local winScale = Instance.new("UIScale")
    winScale.Scale = UI.scale
    winScale.Parent = win
    -- a small pop-in each time the window is shown
    win:GetPropertyChangedSignal("Visible"):Connect(function()
        if win.Visible then
            winScale.Scale = UI.scale * 0.95
            tween(winScale, { Scale = UI.scale }, 0.18)
        end
    end)

    -- soft drop shadow that follows the window
    do
        local shadow = Instance.new("Frame")
        shadow.Name = "Shadow"
        shadow.AnchorPoint = Vector2.new(0.5, 0.5)
        shadow.BackgroundColor3 = Color3.new(0, 0, 0)
        shadow.BackgroundTransparency = 0.62
        shadow.BorderSizePixel = 0
        shadow.ZIndex = 0
        shadow.Parent = gui
        round(shadow, 20)
        local function follow()
            shadow.Visible = win.Visible
            shadow.Position = UDim2.new(win.Position.X.Scale, win.Position.X.Offset, win.Position.Y.Scale, win.Position.Y.Offset + 6)
            shadow.Size = UDim2.fromOffset(win.Size.X.Offset + 18, win.Size.Y.Offset + 18)
        end
        follow()
        win:GetPropertyChangedSignal("Position"):Connect(follow)
        win:GetPropertyChangedSignal("Size"):Connect(follow)
        win:GetPropertyChangedSignal("Visible"):Connect(follow)

        -- the shadow is scaled together with the window
        local shadowScale = Instance.new("UIScale")
        shadowScale.Scale = UI.scale
        shadowScale.Parent = shadow
        -- step 0.05, kept between UI.MIN and UI.MAX; returns the scale that was really applied
        function UI.apply(v)
            v = math.clamp(math.floor((tonumber(v) or 1) * 20 + 0.5) / 20, UI.MIN, UI.MAX)
            UI.scale = v
            winScale.Scale = v
            shadowScale.Scale = v
            Settings.save()
            return v
        end
    end

    -- everything below the title bar lives in `body` (so the window can be minimised to the bar)
    local body = Instance.new("Frame")
    body.Name = "Body"
    body.Position = UDim2.fromOffset(0, BAR_H)
    body.Size = UDim2.new(1, 0, 1, -BAR_H)
    body.BackgroundTransparency = 1
    body.ClipsDescendants = true
    body.Parent = win

    local featurePage = body
    local featureOffset = 0

    local function label(text, y, color, size)
        local l = Instance.new("TextLabel")
        l.Size = UDim2.new(1, -20, 0, 20)
        l.Position = UDim2.fromOffset(10, y - featureOffset)
        l.BackgroundTransparency = 1
        l.Font = FONT
        l.TextSize = size or 16
        l.TextColor3 = color or TEXT
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.TextTruncate = Enum.TextTruncate.AtEnd
        l.Text = text
        l.ZIndex = 5
        l.Parent = featurePage
        if color == ORANGE and not size then
            -- feature heading: a bigger title with a fading accent line under it
            l.TextSize = 18
            local line = Instance.new("Frame")
            line.Size = UDim2.new(1, 0, 0, 2)
            line.Position = UDim2.new(0, 0, 1, 0)
            line.BackgroundColor3 = ORANGE
            line.BorderSizePixel = 0
            line.ZIndex = 5
            line.Parent = l
            local g = Instance.new("UIGradient")
            g.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1)})
            g.Parent = line
        end
        return l
    end

    local function button(text, x, y, w, h, color, parentFrame, z)
        local b = Instance.new("TextButton")
        b.Size = UDim2.fromOffset(w, h)
        b.Position = UDim2.fromOffset(x, parentFrame and y or y - featureOffset)
        b.BackgroundColor3 = color
        b.BorderSizePixel = 0
        b.Font = FONT
        b.TextSize = 15
        b.TextColor3 = TEXT
        b.TextTruncate = Enum.TextTruncate.AtEnd
        b.Text = text
        b.ZIndex = z or 5
        b.Parent = parentFrame or featurePage
        round(b, 8)
        shade(b, Color3.fromRGB(255, 255, 255), Color3.fromRGB(196, 200, 214))
        -- hover / press: only the outline changes, so features can keep recolouring the button for ON / OFF
        local stroke = addStroke(b, Color3.new(1, 1, 1), 1, 0.88)
        b.MouseEnter:Connect(function() tween(stroke, {Transparency = 0.45, Color = ORANGE}) end)
        b.MouseLeave:Connect(function() tween(stroke, {Transparency = 0.88, Color = Color3.new(1, 1, 1)}) end)
        b.MouseButton1Down:Connect(function() tween(stroke, {Transparency = 0.1}, 0.06) end)
        b.MouseButton1Up:Connect(function() tween(stroke, {Transparency = 0.45}, 0.12) end)
        return b
    end

    local function textbox(placeholder, x, y, w, h, text, size)
        local t = Instance.new("TextBox")
        t.Size = UDim2.fromOffset(w, h)
        t.Position = UDim2.fromOffset(x, y - featureOffset)
        t.BackgroundColor3 = PANEL2
        t.BorderSizePixel = 0
        t.Font = FONT
        t.TextSize = size or 16
        t.TextColor3 = TEXT
        t.PlaceholderText = placeholder
        t.PlaceholderColor3 = MUTED
        t.ClearTextOnFocus = true
        t.Text = text or ""
        t.ZIndex = 5
        t.Parent = featurePage
        round(t, 8)
        local ts = addStroke(t, BORDER, 1, 0.3)
        t.Focused:Connect(function() tween(ts, {Color = ORANGE, Transparency = 0}) end)
        t.FocusLost:Connect(function() tween(ts, {Color = BORDER, Transparency = 0.3}) end)
        return t
    end


    -- A name list: type a name and press Enter to add it; every name is a row with a x button to remove it. Stored as one comma
    -- separated string (getStr / setStr), so older saved lists keep working. onChange(totalHeight) is called after every rebuild.
    local function nameList(parentFrame, x, y, w, getStr, setStr, placeholder, onChange)
        local z = parentFrame and 21 or 5
        local parent = parentFrame or featurePage
        local yy = parentFrame and y or y - featureOffset
        local box = Instance.new("TextBox")
        box.Size = UDim2.fromOffset(w, 28); box.Position = UDim2.fromOffset(x, yy)
        box.BackgroundColor3 = PANEL2; box.BorderSizePixel = 0; box.Font = FONT; box.TextSize = 13
        box.TextColor3 = TEXT; box.PlaceholderText = placeholder; box.PlaceholderColor3 = MUTED
        box.ClearTextOnFocus = false; box.Text = ""; box.ZIndex = z; box.Parent = parent
        round(box, 8)
        local bs = addStroke(box, BORDER, 1, 0.3)
        box.Focused:Connect(function() tween(bs, {Color = ORANGE, Transparency = 0}) end)
        local holder = Instance.new("Frame")
        holder.BackgroundTransparency = 1; holder.BorderSizePixel = 0
        holder.Size = UDim2.fromOffset(w, 0); holder.Position = UDim2.fromOffset(x, yy + 32)
        holder.ZIndex = z; holder.Parent = parent
        local function names()
            local out, seen = {}, {}
            for n in tostring(getStr() or ""):gmatch("[^,;%s]+") do
                if not seen[n:lower()] then seen[n:lower()] = true; out[#out + 1] = n end
            end
            return out
        end
        local rebuild
        rebuild = function()
            for _, c in ipairs(holder:GetChildren()) do c:Destroy() end
            local list = names()
            for i, n in ipairs(list) do
                local row = Instance.new("Frame")
                row.Size = UDim2.fromOffset(w, 22); row.Position = UDim2.fromOffset(0, (i - 1) * 24)
                row.BackgroundColor3 = PANEL2; row.BorderSizePixel = 0; row.ZIndex = z; row.Parent = holder
                round(row, 6)
                local l = Instance.new("TextLabel")
                l.BackgroundTransparency = 1; l.Size = UDim2.new(1, -30, 1, 0); l.Position = UDim2.fromOffset(8, 0)
                l.Font = FONT; l.TextSize = 13; l.TextColor3 = TEXT; l.TextXAlignment = Enum.TextXAlignment.Left
                l.TextTruncate = Enum.TextTruncate.AtEnd; l.Text = n; l.ZIndex = z + 1; l.Parent = row
                local rm = Instance.new("TextButton")
                rm.Size = UDim2.fromOffset(22, 22); rm.Position = UDim2.new(1, -22, 0, 0)
                rm.BackgroundTransparency = 1; rm.Font = FONT; rm.TextSize = 14; rm.TextColor3 = Color3.fromRGB(230, 90, 100)
                rm.Text = "x"; rm.ZIndex = z + 1; rm.Parent = row
                rm.Activated:Connect(function()
                    local keep = {}
                    for _, o in ipairs(names()) do if o ~= n then keep[#keep + 1] = o end end
                    setStr(table.concat(keep, ","))
                    rebuild()
                end)
            end
            holder.Size = UDim2.fromOffset(w, #list * 24)
            if onChange then pcall(onChange, 32 + #list * 24, #list) end
        end
        box.FocusLost:Connect(function(enter)
            tween(bs, {Color = BORDER, Transparency = 0.3})
            local added = false
            local cur = names()
            for n in box.Text:gmatch("[^,;%s]+") do
                local dup = false
                for _, o in ipairs(cur) do if o:lower() == n:lower() then dup = true; break end end
                if not dup then cur[#cur + 1] = n; added = true end
            end
            if added then setStr(table.concat(cur, ",")) end
            box.Text = ""
            rebuild()
            if enter then task.defer(function() pcall(function() box:CaptureFocus() end) end) end -- stay in the box for the next name
        end)
        rebuild()
        return { box = box, refresh = rebuild, names = names }
    end

    -- Picker panel beneath the feature controls
    local function sidePanel(className, w, h)
        local f = Instance.new(className)
        f.Size = UDim2.fromOffset(w, h)
        f.Position = UDim2.fromOffset(10, 162)
        f.BackgroundColor3 = PANEL2
        f.BorderSizePixel = 0
        f.Visible = false
        f.ZIndex = 20
        f.Parent = featurePage
        if className == "ScrollingFrame" then
            f.ScrollBarImageColor3 = BORDER
        end
        round(f, 8)
        addStroke(f, BORDER, 1, 0.2)
        return f
    end

    -- ---- title bar ----
    local bar = Instance.new("Frame")
    bar.Name = "TitleBar"
    bar.Size = UDim2.new(1, 0, 0, BAR_H)
    bar.BackgroundColor3 = PANEL
    bar.BorderSizePixel = 0
    bar.Active = true
    bar.ZIndex = 3
    bar.Parent = win
    round(bar, 14)
    shade(bar, Color3.fromRGB(255, 255, 255), Color3.fromRGB(190, 195, 220))
    do
        -- accent line under the title bar
        local acc = Instance.new("Frame")
        acc.Size = UDim2.new(1, -28, 0, 2)
        acc.Position = UDim2.new(0, 14, 1, -2)
        acc.BackgroundColor3 = ORANGE
        acc.BorderSizePixel = 0
        acc.ZIndex = 4
        acc.Parent = bar
        local g = Instance.new("UIGradient")
        g.Color = ColorSequence.new(ORANGE, ACCENT2)
        g.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(0.7, 0.45), NumberSequenceKeypoint.new(1, 1)})
        g.Parent = acc
    end

    local logo = Instance.new("TextLabel")
    logo.Size = UDim2.fromOffset(24, 24)
    logo.Position = UDim2.fromOffset(10, 8)
    logo.BackgroundColor3 = ORANGE
    logo.BorderSizePixel = 0
    logo.Font = FONT
    logo.TextSize = 16
    logo.TextColor3 = BG
    logo.Text = "P"
    logo.ZIndex = 4
    logo.Parent = bar
    round(logo, 8)
    shade(logo, Color3.fromRGB(255, 255, 255), Color3.fromRGB(150, 150, 170), 135)

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -150, 1, 0)
    title.Position = UDim2.fromOffset(42, 0)
    title.BackgroundTransparency = 1
    title.Font = FONT
    title.TextSize = 18
    title.TextColor3 = TEXT
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "PibbleHub"
    title.ZIndex = 4
    title.Parent = bar

    local hint = Instance.new("TextLabel")
    hint.Size = UDim2.fromOffset(120, 40)
    hint.Position = UDim2.new(1, -226, 0, 0)
    hint.BackgroundTransparency = 1
    hint.Font = FONT
    hint.TextSize = 12
    hint.TextColor3 = MUTED
    hint.TextXAlignment = Enum.TextXAlignment.Right
    hint.Text = "RightShift: show / hide"
    hint.ZIndex = 4
    hint.Parent = bar

    local minBtn = button("-", WIN_W - 72, 6, 28, 28, PANEL2, bar, 4)
    local closeBtn = button("x", WIN_W - 38, 6, 28, 28, RED, bar, 4)
    minBtn.TextSize = 18
    closeBtn.TextSize = 16

    local minimized = false
    minBtn.Activated:Connect(function()
        minimized = not minimized
        body.Visible = not minimized
        win.Size = minimized and UDim2.fromOffset(WIN_W, BAR_H) or UDim2.fromOffset(WIN_W, WIN_H)
        minBtn.Text = minimized and "+" or "-"
    end)
    closeBtn.Activated:Connect(function() win.Visible = false end)

    makeDraggable(bar, win)

    connect(UserInputService.InputBegan, function(input, processed)
        if processed or not gui.Parent then return end
        if input.KeyCode == Enum.KeyCode.RightShift then win.Visible = not win.Visible end
    end)

    -- ---- navigation (tabs + live status + stop / unload) ----
    local nav = Instance.new("Frame")
    nav.Name = "Nav"
    nav.Position = UDim2.fromOffset(6, 6)
    nav.Size = UDim2.new(0, 132, 1, -12)
    nav.BackgroundColor3 = PANEL
    nav.BorderSizePixel = 0
    nav.Parent = body
    round(nav, 12)
    shade(nav, Color3.fromRGB(255, 255, 255), Color3.fromRGB(190, 195, 215))
    addStroke(nav, BORDER, 1, 0.45)

    -- the tab buttons live in a scrolling list (there are more tabs than the sidebar is tall)
    local tabList = Instance.new("ScrollingFrame")
    tabList.Name = "Tabs"
    tabList.Position = UDim2.fromOffset(0, 0)
    tabList.Size = UDim2.new(1, 0, 1, -232)
    tabList.BackgroundTransparency = 1
    tabList.BorderSizePixel = 0
    tabList.ScrollBarThickness = 3
    tabList.ScrollBarImageColor3 = BORDER
    tabList.ScrollingDirection = Enum.ScrollingDirection.Y
    tabList.CanvasSize = UDim2.fromOffset(0, 0)
    tabList.ClipsDescendants = true
    tabList.Parent = nav

    local tabs = {}
    local function featureTab(name, originalTop)
        -- a scrolling page: when the window is taller than the screen (small emulator) or a tab has more rows than fit, drag / wheel scrolls it
        local page = Instance.new("ScrollingFrame")
        page.Name = name
        page.ScrollBarThickness = 5
        page.ScrollBarImageColor3 = BORDER
        page.ScrollingDirection = Enum.ScrollingDirection.Y
        page.CanvasSize = UDim2.fromOffset(0, 0)
        page.AutomaticCanvasSize = Enum.AutomaticSize.Y
        page.ElasticBehavior = Enum.ElasticBehavior.Never
        page.Size = UDim2.new(1, -154, 1, -12)
        page.Position = UDim2.fromOffset(146, 6)
        page.BackgroundColor3 = PANEL
        page.BorderSizePixel = 0
        page.Visible = #tabs == 0
        page.Parent = body
        round(page, 12)
        shade(page, Color3.fromRGB(255, 255, 255), Color3.fromRGB(190, 195, 215))
        addStroke(page, BORDER, 1, 0.45)

        local tab = button(name, 8, 4 + #tabs * 31, 114, 28,
            page.Visible and BLUE or DARK, tabList)
        tab.TextSize = 13
        tab.TextXAlignment = Enum.TextXAlignment.Left
        local pad = Instance.new("UIPadding")
        pad.PaddingLeft = UDim.new(0, 14)
        pad.Parent = tab
        -- accent bar on the active tab
        local ind = Instance.new("Frame")
        ind.Size = UDim2.new(0, 3, 1, -10)
        ind.Position = UDim2.fromOffset(-6, 5)
        ind.BackgroundColor3 = ORANGE
        ind.BorderSizePixel = 0
        ind.ZIndex = 7
        ind.Visible = page.Visible
        ind.Parent = tab
        round(ind, 2)
        tabs[#tabs + 1] = {name = name, page = page, button = tab, ind = ind}
        tab.Activated:Connect(function()
            for _, entry in ipairs(tabs) do
                local on = entry.page == page
                entry.page.Visible = on
                entry.ind.Visible = on
                tween(entry.button, {BackgroundColor3 = on and BLUE or DARK}, 0.18)
            end
        end)
        featurePage = page
        featureOffset = originalTop - 10
    end

    -- puts the tabs into groups with small headings (called once, after every feature has made its tab)
    local TAB_GROUPS = {
        { "FARMING", { "Auto Mine", "Auto Boss", "Infinite Tower" } },
        { "ACTIVITIES", { "Auto Raid", "Auto Dungeon", "World Boss", "Portals & Islands", "Expeditions", "Fishing" } },
        { "TOOLS", { "Generations", "Watchdog", "Performance" } },
        { "SETUP", { "Priority", "Settings" } },
    }
    local function layoutTabs()
        local byName, used = {}, {}
        for _, t in ipairs(tabs) do byName[t.name] = t end
        local y = 2
        local function header(text)
            local h = Instance.new("TextLabel")
            h.Size = UDim2.new(1, -16, 0, 14)
            h.Position = UDim2.fromOffset(12, y)
            h.BackgroundTransparency = 1
            h.Font = FONT
            h.TextSize = 11
            h.TextColor3 = MUTED
            h.TextXAlignment = Enum.TextXAlignment.Left
            h.Text = text
            h.Parent = tabList
            y += 16
        end
        local function place(t)
            t.button.Position = UDim2.fromOffset(8, y)
            used[t.name] = true
            y += 31
        end
        for _, g in ipairs(TAB_GROUPS) do
            local found = {}
            for _, nm in ipairs(g[2]) do
                if byName[nm] then found[#found + 1] = byName[nm] end
            end
            if #found > 0 then
                header(g[1])
                for _, t in ipairs(found) do place(t) end
                y += 4
            end
        end
        local rest = {}
        for _, t in ipairs(tabs) do
            if not used[t.name] then rest[#rest + 1] = t end
        end
        if #rest > 0 then
            header("OTHER")
            for _, t in ipairs(rest) do place(t) end
        end
        tabList.CanvasSize = UDim2.fromOffset(0, y + 4)
    end

    -- Runs one feature block. If it errors, only that feature is lost: the rest of the hub still loads.
    local function safeFeature(name, fn)
        local ok, err = xpcall(fn, debug.traceback)
        if not ok then
            warn("[PibbleHub] feature '" .. name .. "' failed to load:", err)
            pcall(function()
                game:GetService("StarterGui"):SetCore("SendNotification", {
                    Title = "PibbleHub",
                    Text = name .. " failed to load (see F9)",
                    Duration = 6,
                })
            end)
        end
    end

    -- live status of every automation
    local statusRows = {}
    do
        local head = Instance.new("TextLabel")
        head.Size = UDim2.new(1, -16, 0, 16)
        head.Position = UDim2.new(0, 10, 1, -218)
        head.BackgroundTransparency = 1
        head.Font = FONT
        head.TextSize = 12
        head.TextColor3 = MUTED
        head.TextXAlignment = Enum.TextXAlignment.Left
        head.Text = "STATUS"
        head.Parent = nav

        for i, n in ipairs({"Boss", "Raid", "Dungeon", "Pop", "WBoss", "Exped"}) do
            local row = Instance.new("Frame")
            row.Size = UDim2.new(1, -16, 0, 18)
            row.Position = UDim2.new(0, 8, 1, -(198 - (i - 1) * 20))
            row.BackgroundColor3 = PANEL2
            row.BackgroundTransparency = 0.45
            row.BorderSizePixel = 0
            row.Parent = nav
            round(row, 6)

            local dot = Instance.new("Frame")
            dot.Size = UDim2.fromOffset(8, 8)
            dot.Position = UDim2.fromOffset(5, 5)
            dot.BackgroundColor3 = OFFC
            dot.BorderSizePixel = 0
            dot.Parent = row
            round(dot, 4)

            local nameL = Instance.new("TextLabel")
            nameL.Size = UDim2.fromOffset(52, 18)
            nameL.Position = UDim2.fromOffset(19, 0)
            nameL.BackgroundTransparency = 1
            nameL.Font = FONT
            nameL.TextSize = 13
            nameL.TextColor3 = TEXT
            nameL.TextXAlignment = Enum.TextXAlignment.Left
            nameL.Text = n
            nameL.Parent = row

            local stateL = Instance.new("TextLabel")
            stateL.Size = UDim2.new(1, -78, 1, 0)
            stateL.Position = UDim2.fromOffset(70, 0)
            stateL.BackgroundTransparency = 1
            stateL.Font = FONT
            stateL.TextSize = 13
            stateL.TextColor3 = OFFC
            stateL.TextXAlignment = Enum.TextXAlignment.Right
            stateL.Text = "off"
            stateL.Parent = row
            local pad = Instance.new("UIPadding")
            pad.PaddingRight = UDim.new(0, 2)
            pad.Parent = stateL

            statusRows[n] = {dot = dot, state = stateL}
        end
    end

    local function setRow(name, text, color)
        local r = statusRows[name]
        if not r then return end
        if r.state.Text ~= text then
            tween(r.dot, {BackgroundColor3 = color}, 0.2)
            tween(r.state, {TextColor3 = color}, 0.2)
            r.state.Text = text
        end
    end

    task.spawn(function()
        while gui.Parent do
            pcall(function()
                if not Boss.auto then setRow("Boss", "off", OFFC)
                elseif Boss.active then setRow("Boss", "fighting", GREEN)
                elseif Boss.timerWait then setRow("Boss", "waiting", ORANGE)
                else setRow("Boss", "armed", BLUE) end

                if Raid.running then setRow("Raid", "running", ORANGE)
                elseif Raid.auto then setRow("Raid", "armed", BLUE)
                else setRow("Raid", "off", OFFC) end

                if Dungeon.active then setRow("Dungeon", "running", GREEN)
                elseif Dungeon.auto then setRow("Dungeon", "armed", BLUE)
                else setRow("Dungeon", "off", OFFC) end

                if Infinite.on then setRow("Pop", "watching", GREEN) else setRow("Pop", "off", OFFC) end

                if WorldBoss.active then setRow("WBoss", "running", GREEN)
                elseif WorldBoss.auto then setRow("WBoss", "armed", BLUE)
                else setRow("WBoss", "off", OFFC) end

                if not Settings.exp.on then setRow("Exped", "off", OFFC)
                elseif Settings.exp.busy then setRow("Exped", "working", GREEN)
                else setRow("Exped", "armed", BLUE) end
            end)
            task.wait(0.5)
        end
    end)

    -- turns every automation switch off (they are created later, so they are looked up when clicked)
    local function stopAll()
        pcall(function() if Boss.setAuto then Boss.setAuto(false) end end)
        pcall(function() if Raid.setAuto then Raid.setAuto(false) end end)
        pcall(function() if Dungeon.setAuto then Dungeon.setAuto(false) end end)
        pcall(function() if WorldBoss.setAuto then WorldBoss.setAuto(false) end end)
        pcall(function() if Infinite.setPop then Infinite.setPop(false) end end)
    end

    local stopBtn = button("Stop all", 8, 0, 116, 28, RED, nav)
    stopBtn.Position = UDim2.new(0, 8, 1, -68)
    stopBtn.Activated:Connect(stopAll)

    -- Unload: removes the window and stops every loop WITHOUT changing the saved switches,
    -- so the next launch resumes exactly where this one was.
    local function unload()
        Settings.armed = false
        stopAll()
        if gui.Parent then gui:Destroy() end
    end
    do
        local genv = (getgenv and getgenv()) or _G
        genv.PibbleUnload = unload
    end

    local unloadBtn = button("Unload", 8, 0, 116, 28, DARK, nav)
    unloadBtn.Position = UDim2.new(0, 8, 1, -36)
    unloadBtn.Activated:Connect(unload)

    -- Open / collapse button (square, rounded corners): the embedded icon if any, or a "P"
    do
        local iconId = CFG.ICON_ID
        if iconId == "" and ICON_B64 and #ICON_B64 > 100 then
            pcall(function()
                if writefile and getcustomasset then
                    writefile("pibblehub_icon.jpg", b64decode(ICON_B64))
                    iconId = getcustomasset("pibblehub_icon.jpg")
                end
            end)
        end

        local toggle
        if iconId ~= "" then
            toggle = Instance.new("ImageButton")
            toggle.Image = iconId
            toggle.ScaleType = Enum.ScaleType.Crop
        else
            toggle = Instance.new("TextButton")
            toggle.Font = FONT
            toggle.TextSize = 22
            toggle.TextColor3 = ORANGE
            toggle.Text = "P"
        end
        toggle.Name = "ToggleButton"
        toggle.Size = UDim2.fromOffset(44, 44)
        toggle.Position = UDim2.new(0, 30, 0.3, -52)
        toggle.BackgroundColor3 = BG
        toggle.BorderSizePixel = 0
        toggle.Active = true
        toggle.ZIndex = 50
        toggle.Parent = gui
        Instance.new("UICorner", toggle).CornerRadius = UDim.new(0, 12)
        local stroke = Instance.new("UIStroke", toggle)
        stroke.Color = ORANGE
        stroke.Thickness = 2
        stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

        local drag = makeDraggable(toggle, toggle)
        toggle.MouseButton1Click:Connect(function()
            if drag.moved > 6 then return end -- it was a drag, not a click
            win.Visible = not win.Visible
        end)
    end

    -- =====================================================================
    -- == 7. GUI AUTOMATION HELPERS (find / press the game's own buttons)
    -- =====================================================================
    local function btnText(o)
        if o:IsA("TextButton") or o:IsA("TextLabel") then return clean(o.Text):lower() end
        return ""
    end

    -- First visible button whose text matches pred (a hidden one is used as a fallback)
    local function findButton(pred)
        local pg = player:FindFirstChild("PlayerGui")
        if not pg then return nil end
        local best
        for _, d in ipairs(pg:GetDescendants()) do
            if d ~= gui and not d:IsDescendantOf(gui) and pred(btnText(d)) then
                -- a label inside a button: use the button
                local b = d
                if not (b:IsA("TextButton") or b:IsA("ImageButton")) then
                    b = d:FindFirstAncestorWhichIsA("TextButton") or d:FindFirstAncestorWhichIsA("ImageButton")
                end
                if b then
                    if shown(b) then return b end
                    best = best or b
                end
            end
        end
        return best
    end

    -- Fires the button's real click handlers
    local function activateButton(b)
        local fired = false
        for _, sig in ipairs({"MouseButton1Click", "Activated"}) do
            if typeof(firesignal) == "function" then
                if pcall(function() firesignal(b[sig]) end) then fired = true end
            elseif typeof(getconnections) == "function" then
                pcall(function()
                    for _, c in ipairs(getconnections(b[sig])) do c:Fire(); fired = true end
                end)
            end
            if fired then break end
        end
        return fired
    end

    -- Remembers which buttons of a game window were clickable before the script pressed things in it, and gives that
    -- state back a moment later. A game button that a handler we fired switched off (a debounce that never came back)
    -- is switched on again, so the window works for the player afterwards. Only buttons that were fine BEFORE are touched.
    local function snapButtons(sg)
        local snap = setmetatable({}, {__mode = "k"})
        if not sg then return snap end
        for _, d in ipairs(sg:GetDescendants()) do
            if d:IsA("GuiButton") then
                local okI, inter = pcall(function() return d.Interactable end)
                snap[d] = { active = d.Active, inter = okI and inter or nil }
            end
        end
        return snap
    end
    local function fixButtons(snap, after)
        task.delay(after or 2.5, function()
            for b, st in pairs(snap) do
                if b.Parent then
                    pcall(function()
                        if st.active and not b.Active then b.Active = true end
                        if st.inter == true and b.Interactable == false then b.Interactable = true end
                    end)
                end
            end
        end)
    end

    -- ---- the game's own inventory: opened with ITS button and closed with ITS close button ----
    -- (forcing ItemFrame.Visible skips the game's open / close code: the window stays half-open, its item panel gets
    -- stuck on screen and its buttons stop answering. The forced way is only the fallback.)
    -- Lets go of every synthetic mouse button / key. A click whose "up" never arrived (the thread was stopped between
    -- the press and the release) leaves the mouse "held" for the game, and then NO game button answers any more.
    local function releaseInput()
        pcall(function()
            local vim = game:GetService("VirtualInputManager")
            local cam = workspace.CurrentCamera
            local v = cam and cam.ViewportSize or Vector2.new(400, 300)
            for b = 0, 2 do pcall(function() vim:SendMouseButtonEvent(v.X * 0.5, v.Y * 0.5, b, false, game, 1) end) end
            for _, k in ipairs({Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift, Enum.KeyCode.LeftControl}) do
                if k ~= Enum.KeyCode.RightShift then pcall(function() vim:SendKeyEvent(false, k, false, game) end) end
            end
        end)
        pcall(function() game:GetService("GuiService").SelectedObject = nil end)
    end
    gui.Destroying:Connect(releaseInput) -- never leave anything held when the hub is closed

    local function realClick(obj)
        return pcall(function()
            local vim = game:GetService("VirtualInputManager")
            local sg = obj:FindFirstAncestorWhichIsA("ScreenGui")
            local inset = (sg and sg.IgnoreGuiInset) and Vector2.new(0, 0) or game:GetService("GuiService"):GetGuiInset()
            local p = obj.AbsolutePosition + obj.AbsoluteSize / 2 + inset
            vim:SendMouseButtonEvent(p.X, p.Y, 0, true, game, 1)
            task.wait(0.05)
            vim:SendMouseButtonEvent(p.X, p.Y, 0, false, game, 1)
            releaseInput()
        end)
    end

    local function waitState(frame, wantShown, secs)
        local t0 = os.clock()
        repeat
            if (frame.Parent ~= nil and shown(frame)) == wantShown then return true end
            task.wait(0.1)
        until os.clock() - t0 > secs
        return (frame.Parent ~= nil and shown(frame)) == wantShown
    end

    -- The HUD has two similar buttons: "InventoryBtn" (not the item window) and "ItemBtn" (opens ItemGui, the window with
    -- the potions). Only the item one is used; InventoryBtn opens something else.
    local ITEM_OPENERS = { itembtn = true, itemsbtn = true, itembutton = true, itemsbutton = true }
    local function inventoryOpener(itemGui)
        local pg = player:FindFirstChildOfClass("PlayerGui")
        if not pg then return nil end
        for _, d in ipairs(pg:GetDescendants()) do
            if d:IsA("GuiButton") and ITEM_OPENERS[d.Name:lower()] and not d:IsDescendantOf(gui)
                and not (itemGui and d:IsDescendantOf(itemGui)) and shown(d) then
                return d
            end
        end
        return nil
    end

    -- true when the window was opened by the game's own button
    local function openInventoryNative(itemGui, frame)
        if shown(frame) then return true end
        local opener = inventoryOpener(itemGui)
        if not opener then print("[PibbleHub] inventory: no opener button found, using the forced open"); return false end
        print("[PibbleHub] inventory: opening with " .. opener:GetFullName())
        if not activateButton(opener) then realClick(opener) end
        if waitState(frame, true, 2) then return true end
        realClick(opener)
        return waitState(frame, true, 2)
    end

    local CLOSE_TEXT = { x = true, ["\u{2715}"] = true, ["\u{2716}"] = true, ["\u{00D7}"] = true, close = true }
    local function closeInventoryNative(itemGui, frame)
        if not (frame.Parent and shown(frame)) then return true end
        local root = itemGui or frame
        local btn
        for _, d in ipairs(root:GetDescendants()) do
            if d:IsA("GuiButton") and shown(d) then
                local n = d.Name:lower()
                local t = ""
                if d:IsA("TextButton") then t = clean(d.Text):lower():match("^%s*(.-)%s*$") end
                if n:find("close", 1, true) or n:find("exit", 1, true) or CLOSE_TEXT[t] then btn = d break end
            end
        end
        print("[PibbleHub] inventory: close button = " .. (btn and btn:GetFullName() or "not found, using the forced close"))
        if btn then
            if not activateButton(btn) then realClick(btn) end
            if waitState(frame, false, 1) then return true end
            realClick(btn)
            if waitState(frame, false, 1) then return true end
        end
        -- no close button found / it did not work: the item button toggles the window
        local opener = inventoryOpener(itemGui)
        if opener then
            print("[PibbleHub] inventory: closing with the item button")
            if not activateButton(opener) then realClick(opener) end
            if waitState(frame, false, 1.5) then return true end
        end
        return false
    end

    -- Some games ask "are you sure?": press Yes / Confirm if it appears
    local function confirmDialog()
        local b = findButton(function(t)
            return t == "yes" or t == "confirm" or t == "give up!" or t:find("^yes[%s%p]") ~= nil
        end)
        if b and shown(b) then activateButton(b) end
    end

    -- =====================================================================
    -- == 7b. ANTI-AFK
    -- =====================================================================
    -- Roblox fires Players.LocalPlayer.Idled after ~20 min without input:
    -- we answer with a virtual click so the player is never kicked for being idle.
    do
        local VirtualUser = game:GetService("VirtualUser")
        local VIM = game:GetService("VirtualInputManager")
        local GuiService = game:GetService("GuiService")
        local nudges = 0
        -- layered: VirtualUser (works on PC) + a real mouse move/click and a tiny key tap through
        -- VirtualInputManager (what a touch/emulator client actually counts as input)
        local function nudge()
            nudges = nudges + 1
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new())
            end)
            pcall(function()
                local cam = workspace.CurrentCamera
                local v = cam and cam.ViewportSize or Vector2.new(400, 300)
                VIM:SendMouseMoveEvent(v.X * 0.5 + (nudges % 2), v.Y * 0.5, game)
                VIM:SendKeyEvent(true, Enum.KeyCode.LeftShift, false, game)
                task.wait(0.05)
            end)
            pcall(function() VIM:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game) end) -- always released
        end
        -- the exact disconnect / kick text goes to the log file (and Discord) so the real cause is known
        local lastMsg, lastAt = nil, 0
        local function logDisconnect(msg)
            if type(msg) ~= "string" or msg == "" then return end
            if msg == lastMsg and os.clock() - lastAt < 30 then return end
            lastMsg, lastAt = msg, os.clock()
            local line = os.date("%Y-%m-%d %H:%M:%S") .. "  DISCONNECT/ERROR: " .. msg .. "\n"
            pcall(function()
                if typeof(appendfile) == "function" then appendfile("PibbleHub_watchdog.log", line)
                elseif writefile then writefile("PibbleHub_watchdog.log", line) end
            end)
            pcall(function()
                local g = Settings.gen
                local url = g and g.url
                if type(url) ~= "string" or not url:find("/api/webhooks/", 1, true) then return end
                local req = (syn and syn.request) or (http and http.request) or http_request or request or (fluxus and fluxus.request)
                if not req then return end
                local pingId = tostring(g.ping or ""):match("^%s*(%d+)%s*$")
                local payload = { username = "PibbleHub", embeds = {{
                    title = "Disconnected / error", description = msg, color = 0xE5484D,
                    footer = { text = player.Name }, timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                }}}
                if pingId then
                    payload.content = "<@" .. pingId .. ">"
                    payload.allowed_mentions = { parse = {}, users = { pingId } }
                end
                task.spawn(pcall, req, { Url = url, Method = "POST", Headers = { ["Content-Type"] = "application/json" },
                    Body = HttpService:JSONEncode(payload) })
            end)
        end
        pcall(function()
            local genv = (getgenv and getgenv()) or _G
            if genv.PibbleAFK then pcall(function() genv.PibbleAFK:Disconnect() end) end
            genv.PibbleAFKGen = (genv.PibbleAFKGen or 0) + 1
            local myGen = genv.PibbleAFKGen
            genv.PibbleAFK = connect(player.Idled, nudge)
            -- safety net: Idled is swallowed on some executors/emulators, so also nudge every 30 s
            task.spawn(function()
                while gui.Parent and genv.PibbleAFKGen == myGen do
                    task.wait(30)
                    if gui.Parent and genv.PibbleAFKGen == myGen then nudge() end
                end
            end)
            connect(GuiService.ErrorMessageChanged, function()
                local okM, m = pcall(function() return GuiService:GetErrorMessage() end)
                if okM then logDisconnect(m) end
            end)
        end)
    end

    -- =====================================================================
    -- == 7c. WORLD TELEPORT (Auto Boss: every boss NPC lives in its own world)
    -- =====================================================================
    -- Closes the game's teleport menu if it is open (a menu left open is what makes the world button toggle the wrong way later).
    local function closeTeleportMenu()
        pcall(function()
            local pg = player:FindFirstChild("PlayerGui")
            if not pg then return end
            local function menuRoot()
                for _, d in ipairs(pg:GetDescendants()) do
                    if not d:IsDescendantOf(gui) and (d:IsA("TextButton") or d:IsA("TextLabel")) and btnText(d) == "islands" and shown(d) then
                        return d:FindFirstAncestorWhichIsA("ScreenGui") or d:FindFirstAncestorWhichIsA("LayerCollector")
                    end
                end
            end
            local root = menuRoot()
            if not root then return end
            for _, d in ipairs(root:GetDescendants()) do
                if d:IsA("GuiButton") and shown(d) then
                    local t = ""
                    for _, c in ipairs(d:GetDescendants()) do
                        if c:IsA("TextLabel") then t = clean(c.Text):lower() break end
                    end
                    if d:IsA("TextButton") then t = clean(d.Text):lower() end
                    if t == "x" or t == "close" or t == "\u{2715}" or t == "\u{2716}" or d.Name == "CloseButton" or d.Name == "Close" then
                        activateButton(d)
                        task.wait(0.3)
                        return
                    end
                end
            end
            -- no close button found: the opener toggles the menu
            if menuRoot() then
                local opener = findButton(function(t) return t == "worlds" or t == "world" end)
                if opener and shown(opener) then activateButton(opener) end
            end
        end)
    end

    local Worlds = {}
    do
        local function norm(s) return (tostring(s):lower():gsub("[^%w]+", "")) end

        local function textOf(x)
            if x:IsA("TextButton") then return clean(x.Text) end
            for _, c in ipairs(x:GetDescendants()) do
                if c:IsA("TextLabel") then return clean(c.Text) end
            end
            return ""
        end

        -- The world list has one "World_<id>" card per world (a title + an "Enter" button).
        -- The card is found by its id ("World_namek") or by its title ("Namek"); returns card, id.
        local function findCard(name)
            local pg = player:FindFirstChild("PlayerGui")
            if not pg then return nil end
            local want = norm(name)
            for _, d in ipairs(pg:GetDescendants()) do
                if not d:IsDescendantOf(gui) and d.Name:sub(1, 6) == "World_" then
                    local id = d.Name:sub(7)
                    if norm(id) == want then return d, id end
                    for _, c in ipairs(d:GetDescendants()) do
                        if c:IsA("TextLabel") then
                            local n = norm(c.Text)
                            if n == want or (#want >= 4 and n:find(want, 1, true)) then return d, id end
                        end
                    end
                end
            end
            return nil
        end

        local function enterButton(card)
            local hidden
            for _, x in ipairs(card:GetDescendants()) do
                if (x:IsA("TextButton") or x:IsA("ImageButton")) and textOf(x):lower():find("enter", 1, true) then
                    if shown(x) then return x end
                    hidden = hidden or x
                end
            end
            return hidden
        end

        -- Teleports to a world by its name ("Leaf Village", "Namek"...): presses the Enter button of its card
        -- (opening the worlds menu first if needed), or fires TeleportToWorld with the id read from the card.
        -- useRemote = true tries the remote first. Returns the method used (nil if nothing worked).
        function Worlds.go(name, useRemote)
            local card, id = findCard(name)
            if not card then
                local m = findButton(function(t)
                    return t:find("teleport", 1, true) ~= nil or t == "world" or t == "worlds"
                end)
                if m and shown(m) and activateButton(m) then
                    task.wait(0.35)
                    card, id = findCard(name)
                end
            end
            print("[PibbleHub] world teleport:", name, "| card =", card and card:GetFullName() or "not found")
            local snap = snapButtons(card and card:FindFirstAncestorWhichIsA("ScreenGui"))
            task.delay(0, function() fixButtons(snap, 3) end)
            local guess = id or (name:lower():gsub("%s+", "_"))
            -- Potassium (a PC executor): pressing the card's Enter button can hit another card, so the teleport goes by the remote with
            -- the exact world id read from the card (when that id is known)
            if not useRemote and id and ExecName:find("potassium", 1, true) then useRemote = true end
            if useRemote and Remotes.Teleport then
                Remotes.Teleport:FireServer(guess)
                return "remote"
            end
            local b = card and enterButton(card)
            if b and activateButton(b) then
                task.wait(0.35)
                confirmDialog()
                task.delay(1, closeTeleportMenu)
                return "button"
            end
            if Remotes.Teleport then
                Remotes.Teleport:FireServer(guess)
                return "remote"
            end
            return nil
        end
    end

    local teleportToIsland
    safeFeature("Portals & Islands", function()
        featureTab("Portals & Islands", 10)
        local destinations = {"Abandoned Island", "Twin Beaches", "Windmill Isle", "Sky Quarry"}
        local openBtn = button("Island Teleports & Portals", 10, 10, 286, 28, DARK)
        local menu = Instance.new("Frame")
        menu.Size = UDim2.fromOffset(230, 152)
        menu.Position = UDim2.fromOffset(10, 596)
        menu.BackgroundColor3 = DARK
        menu.ZIndex = 20
        menu.Visible = false
        menu.Parent = featurePage
        Instance.new("UICorner", menu)

        local status = label("", 126, nil, 13)
        status.Parent = menu
        status.ZIndex = 21

        local function visibleButton(text)
            local b = findButton(function(t) return t == text end)
            return b and shown(b) and b or nil
        end

        local function islandButton(name)
            local pg = player:FindFirstChild("PlayerGui")
            if not pg then return nil end
            for _, title in ipairs(pg:GetDescendants()) do
                if (title:IsA("TextLabel") or title:IsA("TextButton"))
                    and clean(title.Text) == name and shown(title) and not title:IsDescendantOf(gui) then
                    local card = title.Parent
                    while card and not card:IsA("LayerCollector") do
                        local match
                        for _, child in ipairs(card:GetDescendants()) do
                            if child:IsA("TextLabel") or child:IsA("TextButton") then
                                if btnText(child) == "teleport" then
                                    local b = child:IsA("TextButton") and child
                                        or child:FindFirstAncestorWhichIsA("GuiButton")
                                    if b and b:IsDescendantOf(card) and shown(b) then
                                        if match and match ~= b then return nil end
                                        match = b
                                    end
                                end
                            end
                        end
                        if match then return match end
                        card = card.Parent
                    end
                end
            end
            return nil
        end

        local function rawTeleport(name, shouldContinue)
            local target = islandButton(name)
            for attempt = 1, 3 do
                if target then break end
                local tab = visibleButton("islands")
                if not tab then
                    local opener = findButton(function(t)
                        return t == "worlds" or t == "world" or t == "teleport"
                    end)
                    if opener and shown(opener) and activateButton(opener) then
                        task.wait(0.45)
                        tab = visibleButton("islands")
                    end
                end
                if tab and activateButton(tab) then
                    for _ = 1, 10 do
                        task.wait(0.15)
                        if shouldContinue and not shouldContinue() then return false end
                        target = islandButton(name)
                        if target then break end
                    end
                end
                if not target then
                    -- the menu is half open / on the wrong tab: close it so the next try starts clean
                    closeTeleportMenu()
                    task.wait(0.4)
                end
            end
            if shouldContinue and not shouldContinue() then return false end
            local okT = target ~= nil and activateButton(target)
            if okT then task.delay(1, closeTeleportMenu) end
            return okT
        end

        teleportToIsland = function(name, shouldContinue)
            local ref = visibleButton("islands") or findButton(function(t) return t == "worlds" or t == "world" end)
            local snap = snapButtons(ref and ref:FindFirstAncestorWhichIsA("ScreenGui"))
            local r = rawTeleport(name, shouldContinue)
            fixButtons(snap, 2.5)
            return r
        end


        menu.Size = UDim2.fromOffset(286, 566)
        menu.Position = UDim2.fromOffset(10, 44)
        menu.BackgroundColor3 = PANEL2

        -- small section titles + a divider above the status line
        local function section(text, y)
            local l = label(text, y, MUTED, 11)
            l.Parent = menu
            l.ZIndex = 21
            l.Position = UDim2.fromOffset(10, y)
            l.Size = UDim2.fromOffset(160, 16)
            return l
        end
        -- layout (top to bottom): PORTALS (8 rows) | AUTOMATION (switches + wait list) | DISCORD WEBHOOK | status line.
        -- Everything below the wait list is moved by layoutBelow(), because the wait list grows with every name.
        section("PORTALS", 8)
        section("AUTOMATION", 244)
        local secHook = section("DISCORD WEBHOOK", 400)
        local function makeDivider()
            local div = Instance.new("Frame")
            div.Size = UDim2.fromOffset(266, 1)
            div.Position = UDim2.fromOffset(10, 490)
            div.BackgroundColor3 = BORDER
            div.BackgroundTransparency = 0.3
            div.BorderSizePixel = 0
            div.ZIndex = 21
            div.Parent = menu
            return div
        end
        local divHook, divStatus = makeDivider(), makeDivider()
        status.Position = UDim2.fromOffset(10, 520)
        status.Size = UDim2.fromOffset(266, 34)
        status.TextWrapped = true
        status.TextTruncate = Enum.TextTruncate.None
        status.TextYAlignment = Enum.TextYAlignment.Top
        local busy = false

        local portalChoices = {
            {label = "Clover Kingdom", item = "clover_kingdom", world = "BlackCloverWorld"},
            {label = "Dressrosa", item = "dressrosa", world = "Dressrosa"},
            {label = "Isekai", item = "isekai", world = "Isekai"},
            {label = "Leaf Village", item = "leaf_village", world = "Leaf Village"},
            {label = "Namek", item = "namek", world = "Namek"},
            {label = "Shibuya", item = "shibuya", world = "Shibuya"},
            {label = "Soul Society", item = "soul_society", world = "Soul Society"},
            {label = "Train to Kyoto", item = "train_to_kyoto", world = "Train to Kyoto"},
        }
        local selectedPortals = {}

        local function getInventory()
            local pg = player:FindFirstChildOfClass("PlayerGui")
            return pg and pg:FindFirstChild("ItemGui")
        end

        -- The inventory name of a portal is "Item_portal_<world>[_nightmare]". When that exact name is not in the grid (a different
        -- spelling of the world, e.g.), the grid is searched for a portal item whose name has the world's first letters and the right
        -- difficulty; what was found (or all the portal names in the grid) is printed, so a wrong name can be seen in the log.
        local loggedPortalNames = {}
        local function resolvePortalName(grid, choice)
            local exact = "Item_portal_" .. choice.item
            if not grid then return exact end
            if grid:FindFirstChild(exact) then return exact end
            local function norm(x) return (tostring(x):lower():gsub("[^%a]", "")) end
            local base = norm(choice.item:gsub("_nightmare$", ""))
            local key = base:sub(1, 4)
            local wantNm = choice.difficulty == "Nightmare"
            local names = {}
            for _, c in ipairs(grid:GetChildren()) do
                if c.Name:lower():find("portal", 1, true) then
                    names[#names + 1] = c.Name
                    local n = norm(c.Name)
                    local isNm = n:find("nightmare", 1, true) ~= nil or n:find("nm", #n - 1, true) ~= nil
                    if n:find(key, 1, true) and isNm == wantNm then
                        if not loggedPortalNames["r" .. choice.label] then
                            loggedPortalNames["r" .. choice.label] = true
                            print(("[PibbleHub] portal item for %s: '%s' not in the grid, using '%s'"):format(choice.label, exact, c.Name))
                        end
                        return c.Name
                    end
                end
            end
            local sig = table.concat(names, ",")
            if not loggedPortalNames[sig .. choice.label] then
                loggedPortalNames[sig .. choice.label] = true
                print(("[PibbleHub] portal item for %s: '%s' not found. Portal items in the grid: %s"):format(choice.label, exact, #names > 0 and sig or "(none)"))
            end
            return exact
        end

        local function findPortalItem(inventory, itemName)
            local frame = inventory and inventory:FindFirstChild("ItemFrame")
            local grid = frame and frame:FindFirstChild("ItemGrid")
            local item = grid and grid:FindFirstChild(itemName)
            if not item or not shown(item) then return nil end
            if item:IsA("GuiButton") then return item end
            local control = item:FindFirstChildWhichIsA("GuiButton", true)
            if control and shown(control) then return control end
            control = item:FindFirstAncestorWhichIsA("GuiButton")
            return control and control:IsDescendantOf(grid) and shown(control) and control or nil
        end


        local function visibleButtonIn(root, name)
            for _, item in ipairs(root:GetDescendants()) do
                if (item:IsA("TextButton") or item:IsA("TextLabel")) and btnText(item) == name then
                    local control = item:IsA("GuiButton") and item
                        or item:FindFirstAncestorWhichIsA("GuiButton")
                    if control and shown(control) then return control end
                end
            end
            return nil
        end

        local function inventoryIsOpen(inventory)
            local frame = inventory and inventory:FindFirstChild("ItemFrame")
            return frame and shown(frame)
        end

        local openedItemGui, nativeInv
        local function openInventory()
            local inventory = getInventory()
            local frame = inventory and inventory:FindFirstChild("ItemFrame")
            if not frame or not frame:IsA("GuiObject") then return end
            if openInventoryNative(inventory, frame) then nativeInv = true; return end
            nativeInv = false
            if inventory:IsA("ScreenGui") and not inventory.Enabled then
                inventory.Enabled = true
                openedItemGui = inventory
            end
            frame.Visible = true
        end

        local function closeInventory()
            local inventory = getInventory()
            local frame = inventory and inventory:FindFirstChild("ItemFrame")
            if frame and frame:IsA("GuiObject") then
                if not (nativeInv and closeInventoryNative(inventory, frame)) then frame.Visible = false end
            end
            nativeInv = false
            if openedItemGui then
                openedItemGui.Enabled = false
                openedItemGui = nil
            end
        end


        -- =====================================================================
        -- PORTAL ENGINE (Auto Create / Follow Join). Settings are in PCFG below.
        -- =====================================================================
        local PCFG = {
            RESULT_TITLES = { ["out of lives"] = true }, -- results screen titles (lowercase, punctuation ignored)
            REQUIRE_PORTAL_TEXT = false, -- true: the results panel must also contain the word "portal"
            INSIDE_WAVE_TEXT = true,     -- a visible "Wave N" text counts as "inside a portal" and its wave number / lives are read (like the Infinite Tower floor)
            INSIDE_LIVES_TEXT = true,    -- a visible text with "lives" counts as "inside a portal" (set false if the lobby shows it too)
            RESULT_WAIT = 2,             -- seconds to wait after the results screen closes, before the next portal (was 5)
            MAX_RUN = 20 * 60,           -- seconds before a portal that never shows results is given up
            GONE_AFTER = 25,             -- seconds without any portal UI (after having seen it) = the portal ended
            INSIDE_WAIT = 30,            -- max seconds to wait for a previous portal to end before creating the next
            WALK_TIMEOUT = 40,           -- seconds to get into a gate / start the run (includes the delays above)
            PRE_WALK_DELAY = 0.8,        -- seconds to settle (free, on the ground) before walking into a gate
            MAX_OVERSHOOT = 14,          -- studs the walk target may lie behind the gate centre (a fast walker used to run right through)
            REWALKS = 3,                 -- times the character walks back to the gate centre when it ran through without entering
            NO_ROOM_AFTER = 10,          -- seconds inside with no waiting room = the run already started
            WORLD_TIMEOUT = 15,          -- seconds to wait for a world teleport to finish
            WORLD_TRIES = 2,             -- teleport attempts per world (2nd one uses the remote)
            FOLLOW_SCAN = 0.25,          -- Follow Join: seconds between two looks for the followed player's gate (was 1)
            FOLLOW_POLL = 0.12,          -- Follow Join: seconds between two "am I inside yet?" checks while walking in (was 0.3)
            FOLLOW_ON_GATE_FIRST = true, -- Follow Join: true = stand ON the gate first, walking in is the backup; false = the other way round
            FOLLOW_WAIT_OWNER = true,    -- Follow Join: do not walk in before the followed player has gone in himself
            FOLLOW_OWNER_MAX = 10,       -- Follow Join: longest wait (seconds) for the owner to go in, then the follower goes anyway
            FOLLOW_OWNER_DELAY = 1,      -- Follow Join: seconds after the owner went in before the follower goes in
            FOLLOW_OWNER_OUT = 35,       -- Follow Join: the owner counts as inside when he is this far (studs) from the gate
            FOLLOW_REPICKS = 3,          -- Follow Join: failed rounds (each FOLLOW_TRIES tries) before a gate is left alone for JOIN_RETRY seconds
            FOLLOW_TRIES = 4,            -- Follow Join: how many times the player tries to get into the portal
            FOLLOW_TRY_SECS = 5,         -- Follow Join: seconds one try may take before it counts as failed
            FOLLOW_ENTER_WAIT = 2,       -- Follow Join: seconds the first way in may take before the other one is tried
            FOLLOW_TELEPORT = true,      -- Follow Join: teleport next to the gate instead of walking there (much faster)
            HOST_WAIT = 40,             -- Host wait: max seconds the owner waits for the picked player before pressing Start
            HOST_NEAR = 120,             -- Host wait: the picked player counts as in the room when his character is this close (studs)
            HOST_AFTER_JOIN = 3,         -- Host wait: seconds between the player showing up and Start
            FOLLOW_NEAR = 60,            -- Follow Join: a gate without owner information counts as the followed player's when he stands this close (studs)
            STOCK_RECHECK = 20,          -- seconds between two looks into the inventory for a new portal while none is left (Auto Boss runs meanwhile)
            STOCK_IGNORE = 120,          -- seconds a portal that could not be found after all is ignored
            MAX_FAILS = 3,               -- after this many failed portals in a row Auto Create pauses (it does NOT stop for good)
            FAIL_COOLDOWN = 300,         -- seconds it pauses before trying again (an AFK night must not end after three bad portals)
            RETRY_DELAY = 5,             -- seconds between two failed attempts
            JOIN_RETRY = 45,             -- seconds before Follow Join tries the same gate again
            ARRIVE_WAIT = 1,             -- seconds to let a world load after a teleport (lobby / portal world) before going on (was 2)
            LOOP_PAUSE = 1,              -- seconds between two Auto Create rounds (was 2)
            GATE_SPAWN_WAIT = 0.5,       -- seconds after using the portal item before looking for the new gate (was 2)
            HOOK_CAPTURE_DELAY = 0.8,    -- seconds the results screen is given to fill in its rewards before they are read for the webhook
            ROOM_SETTLE = 2,             -- seconds after the waiting room appears before ANYTHING is pressed (lets its UI finish loading)
            FIGHT_CLICK_DELAY = 1,       -- seconds between the Auto Fight row appearing and the toggle being clicked
            AFTER_TOGGLE_DELAY = 2,      -- seconds after the Auto Fight toggle was clicked before Start may be pressed
            START_TIMEOUT = 25,          -- seconds the Start step may take (finding the button, clicking it, the waiting room closing)
            START_DELAY = 1.5,           -- seconds everything has to be settled (room loaded, Auto Fight done) before Start is pressed
            AUTO_FIGHT_CLICKS = 1,       -- max times the Auto Fight toggle is clicked per portal (0 = never touch it)
            PARTY_LEAVE_WAIT = 600,      -- seconds the owner waits for the rest of the party to leave the old portal before creating a new one
            PARTY_BACK_RANGE = 300,      -- studs: a party member this close to the owner (in the lobby) has left the portal
            PORTAL_MAX_SECS = 660,       -- seconds after the start when a party member that cannot be seen is assumed to be out of the portal
            AUTO_FIGHT_GRACE = 5,        -- seconds (counted from when the Auto Fight row first appears) the run waits for Auto Fight to read as ON; after that it moves on to the next step anyway
            AUTO_FIGHT_DEBUG = true,     -- print the Auto Fight row and its surroundings to F9 once per portal (to see what the game really has)
            AUTO_FIGHT_BY_COLOR = true,  -- read the Auto Fight state from the toggle's color (green = ON, gray = OFF)
            AUTO_FIGHT_BLOCK_WORDS = {"start", "abandon", "continue", "close", "exit", "leave", "claim"}, -- buttons with these texts are never read as the toggle
        }

        -- ---------- small helpers ----------
        local function normText(t)
            return (tostring(t):lower():gsub("%p", ""):match("^%s*(.-)%s*$"))
        end

        local function normWorld(s)
            return (tostring(s):lower():gsub("^world_", ""):gsub("[^%w]", ""))
        end

        local function sameWorld(a, b)
            return type(a) == "string" and type(b) == "string" and a ~= "" and b ~= ""
                and normWorld(a) == normWorld(b)
        end

        local function currentWorld()
            return player:GetAttribute("CurrentWorld") or player:GetAttribute("WorldId")
        end

        -- gate world attribute -> the world name the teleport menu knows
        local function worldFor(value)
            for _, c in ipairs(portalChoices) do
                if sameWorld(value, c.world) or sameWorld(value, c.label) then return c.world end
            end
            return value
        end

        local function othersBusy()
            return Raid.running or Boss.active or Dungeon.active or WorldBoss.active
                or Prio.blockedBy("Portal") ~= nil -- something the user ranked above the portals is ready to run
        end

        -- who is holding the portals back (shown in the status line and logged)
        local lastBusyLog, lastBusyText = -1e9, ""
        local function busyReason()
            local parts = {}
            if Raid.running then parts[#parts + 1] = "raid running" end
            if Boss.active then parts[#parts + 1] = "boss fight" end
            if Dungeon.active then parts[#parts + 1] = "dungeon" end
            if WorldBoss.active then parts[#parts + 1] = "world boss" end
            local by = Prio.blockedBy("Portal")
            if by then
                local why = Prio.running(by) and "running" or "ready to run"
                if by == "Dagon" then why = why .. (Dagon.barUp and ", Dagon bar/waypoint up" or "") end
                parts[#parts + 1] = (Prio.label and Prio.label(by) or by) .. " " .. why
            end
            local text = #parts > 0 and table.concat(parts, ", ") or "unknown"
            if text ~= lastBusyText or os.clock() - lastBusyLog > 30 then
                lastBusyText, lastBusyLog = text, os.clock()
                print("[PibbleHub] portal waiting because: " .. text)
            end
            return text
        end

        local function climb(node, fn)
            while node do
                local r = fn(node)
                if r then return r end
                if node:IsA("LayerCollector") then break end
                node = node.Parent
            end
            return nil
        end

        -- A real mouse click on the control (for buttons that ignore fired signals).
        local function physicalClick(control)
            local ok = pcall(function()
                local vim = game:GetService("VirtualInputManager")
                local sg = control:FindFirstAncestorWhichIsA("ScreenGui")
                local inset = (sg and sg.IgnoreGuiInset) and Vector2.new(0, 0)
                    or game:GetService("GuiService"):GetGuiInset()
                local p = control.AbsolutePosition + control.AbsoluteSize / 2 + inset
                vim:SendMouseButtonEvent(p.X, p.Y, 0, true, game, 1)
                task.wait(0.05)
                vim:SendMouseButtonEvent(p.X, p.Y, 0, false, game, 1)
                releaseInput()
            end)
            return ok
        end

        local function clickPortalControlSync(control)
            if typeof(getconnections) == "function" then
                for _, signal in ipairs({control.Activated, control.MouseButton1Click}) do
                    local ok, fired = pcall(function()
                        local connections = getconnections(signal)
                        for _, connection in ipairs(connections) do connection:Fire() end
                        return #connections > 0
                    end)
                    if ok and fired then return true end
                end
            end
            return activateButton(control) or physicalClick(control)
        end

        -- Never blocks the automation. The game's own click handler runs INSIDE our thread when a connection is
        -- fired, and a handler that yields (e.g. the Start button waiting for the server) would freeze the whole
        -- Auto Create loop until the handler returns, which is why the script "did not notice" the portal had started.
        -- So the click runs in its own thread; we wait at most 0.5 s for its result.
        local function clickPortalControl(control)
            local done, result = false, false
            task.spawn(function()
                local okc, r = pcall(clickPortalControlSync, control)
                result = okc and r or false
                done = true
            end)
            local t = os.clock()
            while not done and os.clock() - t < 0.5 do task.wait(0.05) end
            if not done then return true end -- the handler is still running (it yields): the click did happen
            return result
        end

        -- ---------- gates in the workspace ----------
        local function portalGateSnapshot()
            local seen = {}
            for _, folderName in ipairs({"PortalModeGates", "PortalModeArenas"}) do
                local folder = workspace:FindFirstChild(folderName)
                if folder then
                    for _, instance in ipairs(folder:GetDescendants()) do
                        seen[instance] = true
                    end
                end
            end
            return seen
        end

        local function findNewPortal(snapshot)
            local root = getHRP()
            if not root then return nil end
            local closest, closestDistance = nil, math.huge
            for _, folderName in ipairs({"PortalModeGates", "PortalModeArenas"}) do
                local folder = workspace:FindFirstChild(folderName)
                if folder then
                    for _, instance in ipairs(folder:GetDescendants()) do
                        if not snapshot[instance] and instance:IsA("BasePart") then
                            local distance = (instance.Position - root.Position).Magnitude
                            if distance < closestDistance then
                                closest, closestDistance = instance, distance
                            end
                        end
                    end
                end
            end
            return closest
        end

        -- the value label (a "3/3" or a "9:04") closest to a caption label such as "LIVES" or "TIME":
        -- looked for inside the caption's parent, then its grandparent, then one level higher
        local function nearestValue(caption, list)
            local node = caption.Parent
            local cx = caption.AbsolutePosition.X + caption.AbsoluteSize.X / 2
            local cy = caption.AbsolutePosition.Y + caption.AbsoluteSize.Y / 2
            for _ = 1, 3 do
                if not node then break end
                local best, bestD
                for _, it in ipairs(list) do
                    if it.obj:IsDescendantOf(node) then
                        local dx = it.obj.AbsolutePosition.X + it.obj.AbsoluteSize.X / 2 - cx
                        local dy = it.obj.AbsolutePosition.Y + it.obj.AbsoluteSize.Y / 2 - cy
                        local d = math.sqrt(dx * dx + dy * dy)
                        if d <= 150 and (not bestD or d < bestD) then best, bestD = it, d end
                    end
                end
                if best then return best end
                if node:IsA("LayerCollector") then break end
                node = node.Parent
            end
            return nil
        end

        -- one scan of the interface: what portal UI is visible right now.
        -- Also reads the portal HUD like the Infinite Tower reads its floor:
        --   found.wave (number), found.livesNow / found.livesMax (numbers), found.timeText ("9:04")
        local function scanUI()
            local found = {}
            local pg = player:FindFirstChildOfClass("PlayerGui")
            if not pg then return found end
            local fractions, times = {}, {}
            for _, d in ipairs(pg:GetDescendants()) do
                if d:IsA("TextLabel") or d:IsA("TextButton") then
                    local t = clean(d.Text):lower():match("^%s*(.-)%s*$")
                    if t ~= "" and not d:IsDescendantOf(gui) and shown(d) then
                        -- HUD values
                        if PCFG.INSIDE_WAVE_TEXT and not found.wave then
                            local wv = t:match("^wave%s*(%d+)")
                            if wv then found.wave = tonumber(wv) end
                        end
                        local fa, fb = t:match("^(%d+)%s*/%s*(%d+)$")
                        if fa then fractions[#fractions + 1] = {obj = d, a = tonumber(fa), b = tonumber(fb)} end
                        if t:match("^%d+:%d%d$") then times[#times + 1] = {obj = d, text = t} end
                        if t == "lives" and not found.livesLabel then found.livesLabel = d end
                        if t == "time" and not found.timeLabel then found.timeLabel = d end
                        -- "3/3 lives", "lives: 3/3", "3 lives"
                        if not found.livesNow and t:find("lives", 1, true) and not PCFG.RESULT_TITLES[normText(t)] then
                            local la, lb = t:match("(%d+)%s*/%s*(%d+)")
                            if la then
                                found.livesNow, found.livesMax = tonumber(la), tonumber(lb)
                            else
                                local ln = t:match("^(%d+)%s*lives") or t:match("lives%s*:?%s*(%d+)")
                                if ln then found.livesNow = tonumber(ln) end
                            end
                        end
                    end

                    if t ~= "" then
                        local kind
                        if t == "auto fight" then
                            kind = "fight"
                        elseif t == "waiting room" then
                            kind = "room"
                        elseif PCFG.RESULT_TITLES[normText(t)] then
                            kind = "result"
                        elseif PCFG.INSIDE_LIVES_TEXT and t:find("lives", 1, true) then
                            kind = "lives"
                        end
                        if kind and not found[kind] and not d:IsDescendantOf(gui) and shown(d) then
                            found[kind] = d
                        end
                    end
                end
            end
            -- pair the "LIVES" / "TIME" captions with their values
            if found.livesLabel and not found.livesNow then
                local f = nearestValue(found.livesLabel, fractions)
                if f then found.livesNow, found.livesMax = f.a, f.b end
            end
            if found.timeLabel then
                local tm = nearestValue(found.timeLabel, times)
                if tm then found.timeText = tm.text end
            end
            return found
        end

        -- green -> true, gray -> false, anything else -> nil
        local function colorState(c)
            local r, g, b = c.R * 255, c.G * 255, c.B * 255
            if g > r + 25 and g > b + 25 then return true end
            if math.max(r, g, b) - math.min(r, g, b) <= 30 then return false end
            return nil
        end

        local function isBlockedText(t)
            for _, w in ipairs(PCFG.AUTO_FIGHT_BLOCK_WORDS) do
                if t:find(w, 1, true) then return true end
            end
            return false
        end

        -- The clickable control of the Auto Fight row, when the colour scan did not give one:
        -- 1) the row's own text sits inside a button   2) the closest button on the same line as the row
        local function findFightToggle(row)
            local own = row:IsA("GuiButton") and row or row:FindFirstAncestorWhichIsA("GuiButton")
            if own and shown(own) and not isBlockedText(btnText(own)) then
                local nested = false
                for _, d in ipairs(own:GetDescendants()) do
                    if d:IsA("GuiButton") and d ~= row then nested = true; break end
                end
                if not nested then return own end
            end
            local rowY = row.AbsolutePosition.Y + row.AbsoluteSize.Y / 2
            local rowX = row.AbsolutePosition.X + row.AbsoluteSize.X / 2
            local node = row.Parent
            for _ = 1, 2 do
                if not node or node:IsA("LayerCollector") then break end
                local best, bestD = nil, math.huge
                for _, d in ipairs(node:GetDescendants()) do
                    if d:IsA("GuiButton") and d ~= row and shown(d) and not d:IsDescendantOf(gui) then
                        local t = btnText(d)
                        local cy = d.AbsolutePosition.Y + d.AbsoluteSize.Y / 2
                        if not isBlockedText(t) and not isBlockedText((d.Name or ""):lower())
                            and math.abs(cy - rowY) <= 30 then
                            local dist = math.abs(d.AbsolutePosition.X + d.AbsoluteSize.X / 2 - rowX)
                            if dist < bestD then best, bestD = d, dist end
                        end
                    end
                end
                if best then return best end
                node = node.Parent
            end
            return nil
        end

        -- debug: what the game really has around the Auto Fight row (printed once per portal)
        local function dumpFightRow(row)
            if not PCFG.AUTO_FIGHT_DEBUG then return end
            local node, out, seen = row, {}, {}
            for _ = 1, 3 do
                if not node or node:IsA("LayerCollector") then break end
                for _, d in ipairs(node:GetDescendants()) do
                    if #out >= 30 then break end
                    if d:IsA("GuiObject") and not seen[d] and shown(d) then
                        seen[d] = true
                        local c = d.BackgroundColor3
                        local txt = (d:IsA("TextButton") or d:IsA("TextLabel")) and clean(d.Text) or ""
                        out[#out + 1] = ("%s[%s] text=%q bg=%d,%d,%d tr=%.2f"):format(
                            d.Name, d.ClassName, txt, c.R * 255, c.G * 255, c.B * 255, d.BackgroundTransparency)
                    end
                end
                node = node.Parent
            end
            print("[PibbleHub] Auto Fight row '" .. row:GetFullName() .. "' and neighbours:\n  " .. table.concat(out, "\n  "))
        end

        -- Auto Fight row -> (true = ON, false = OFF, nil = unknown), toggle button when it is OFF
        local function fightState(row)
            -- 1) the toggle usually just says "ON" / "OFF": that is the most reliable reading
            --    (its colour can be a gradient, so the colour alone may be wrong).
            --    The ON/OFF text closest to the Auto Fight row, on the same line, wins.
            do
                local rowY = row.AbsolutePosition.Y + row.AbsoluteSize.Y / 2
                local bestO, bestTx, bestD = nil, nil, math.huge
                local node = row.Parent
                for _ = 1, 3 do
                    if not node or node:IsA("LayerCollector") then break end
                    for _, d in ipairs(node:GetDescendants()) do
                        if (d:IsA("TextButton") or d:IsA("TextLabel")) and shown(d) and not d:IsDescendantOf(gui) then
                            local tx = btnText(d):match("^%s*(.-)%s*$")
                            if tx == "on" or tx == "off" then
                                local dy = math.abs(d.AbsolutePosition.Y + d.AbsoluteSize.Y / 2 - rowY)
                                if dy <= 30 and dy < bestD then bestO, bestTx, bestD = d, tx, dy end
                            end
                        end
                    end
                    if bestO then break end
                    node = node.Parent
                end
                if bestO then
                    if bestTx == "on" then return true, nil end
                    local btn = bestO:IsA("GuiButton") and bestO or bestO:FindFirstAncestorWhichIsA("GuiButton")
                    return false, btn or findFightToggle(row)
                end
            end

            if PCFG.AUTO_FIGHT_BY_COLOR then
                local candidates, seen = {}, {}
                local function add(o)
                    if not seen[o] then seen[o] = true; candidates[#candidates + 1] = o end
                end
                add(row)
                local node = row.Parent
                for _ = 1, 2 do
                    if not node or node:IsA("LayerCollector") then break end
                    for _, d in ipairs(node:GetDescendants()) do add(d) end
                    node = node.Parent
                end

                local anyOn, offButton, anyOff
                for _, o in ipairs(candidates) do
                    if o:IsA("GuiObject") and o.BackgroundTransparency < 0.9 and shown(o) then
                        local t = btnText(o)
                        local toggleLike = o:IsA("GuiButton")
                            or t == "on" or t == "off"
                            or o.Name:lower():find("toggle", 1, true) or o.Name:lower():find("switch", 1, true)
                        if toggleLike and not isBlockedText(t) then
                            local state = colorState(o.BackgroundColor3)
                            if state == true then
                                anyOn = true
                            elseif state == false then
                                anyOff = true
                                offButton = offButton or (o:IsA("GuiButton") and o or o:FindFirstAncestorWhichIsA("GuiButton"))
                            end
                        end
                    end
                end
                if anyOn then return true, nil end
                if anyOff then return false, offButton or findFightToggle(row) end
            end

            -- fallback: a button whose text is exactly "on" / "off"
            local enabled, toggle
            climb(row.Parent, function(node)
                local off = visibleButtonIn(node, "off")
                local on = visibleButtonIn(node, "on")
                if off and not on then enabled, toggle = false, off; return true end
                if on and not off then enabled = true; return true end
                if off or on then return true end
                return nil
            end)
            if enabled == false and not toggle then toggle = findFightToggle(row) end
            return enabled, toggle
        end

        local function roomStart(title)
            -- 1) the usual layout: a Start and an Abandon button side by side
            local strict = climb(title.Parent, function(node)
                local start = visibleButtonIn(node, "start")
                if start and visibleButtonIn(node, "abandon") then return start end
            end)
            if strict then return strict end
            -- 2) fallback: any visible button reading "start" (or starting with it) around the waiting room,
            --    in case the Abandon button is named differently or is not visible
            return climb(title.Parent, function(node)
                for _, d in ipairs(node:GetDescendants()) do
                    if (d:IsA("TextButton") or d:IsA("TextLabel")) and shown(d) and not d:IsDescendantOf(gui) then
                        local t = btnText(d):match("^%s*(.-)%s*$")
                        if t == "start" or (t:find("^start") and not t:find("abandon", 1, true)) then
                            local c = d:IsA("GuiButton") and d or d:FindFirstAncestorWhichIsA("GuiButton")
                            if c and shown(c) then return c end
                        end
                    end
                end
            end)
        end

        -- debug: every visible text / button around the waiting room (printed once when Start cannot be found)
        local function dumpRoom(room, why)
            local node, out, seen = room, {}, {}
            for _ = 1, 3 do
                if not node or node:IsA("LayerCollector") then break end
                for _, d in ipairs(node:GetDescendants()) do
                    if #out >= 40 then break end
                    if (d:IsA("TextButton") or d:IsA("TextLabel") or d:IsA("ImageButton")) and not seen[d]
                        and shown(d) and not d:IsDescendantOf(gui) then
                        seen[d] = true
                        out[#out + 1] = ("%s[%s] text=%q"):format(d.Name, d.ClassName, btnText(d))
                    end
                end
                node = node.Parent
            end
            print("[PibbleHub] Waiting room: " .. (why or "Start button NOT found") .. ". Visible controls:\n  " .. table.concat(out, "\n  "))
        end

        local function resultContinue(title)
            return climb(title.Parent, function(node)
                local c = visibleButtonIn(node, "continue")
                if not c then return nil end
                if not PCFG.REQUIRE_PORTAL_TEXT then return c end
                for _, x in ipairs(node:GetDescendants()) do
                    if (x:IsA("TextLabel") or x:IsA("TextButton")) and btnText(x):find("portal", 1, true) and shown(x) then
                        return c
                    end
                end
            end)
        end

        -- {inside, fightRow, fightOn, toggle, room, start, continue}
        local function portalState()
            local s = scanUI()
            local st = {}
            if s.fight then
                st.fightRow = true
                st.fightObj = s.fight
                st.fightOn, st.toggle = fightState(s.fight)
            end
            if s.room then
                st.room = true
                st.roomObj = s.room
                st.start = roomStart(s.room)
            end
            if s.result then st.continue = resultContinue(s.result); st.resultObj = s.result end
            st.wave, st.lives, st.maxLives, st.time = s.wave, s.livesNow, s.livesMax, s.timeText
            st.inside = (st.fightRow or st.room or s.lives or st.continue or s.wave) and true or false
            return st
        end

        -- The portal panel has a "Stop Auto On Loss" switch (new in the game): it must stay OFF, otherwise a lost wave
        -- turns Auto Fight off. Checked at most every 2.5 s; clicked (like the Auto Fight toggle) when it reads ON.
        local lastStopScan, lastStopClick = -1e9, -1e9
        -- returns "on" (it was ON: a click was sent or is coming), "off" (confirmed OFF) or nil (row not found / scan skipped)
        local function ensureStopAutoOff(force)
            if not force and os.clock() - lastStopScan < 2.5 then return end
            lastStopScan = os.clock()
            local pg = player:FindFirstChildOfClass("PlayerGui")
            if not pg then return end
            for _, d in ipairs(pg:GetDescendants()) do
                if (d:IsA("TextLabel") or d:IsA("TextButton")) and not d:IsDescendantOf(gui) and shown(d)
                    and btnText(d):match("^%s*(.-)%s*$") == "stop auto on loss" then
                    local on, btn = fightState(d)
                    if on == true then
                        -- fightState returns the toggle only for OFF; look for the ON button on the same line
                        local rowY = d.AbsolutePosition.Y + d.AbsoluteSize.Y / 2
                        local node, target = d.Parent, nil
                        for _ = 1, 3 do
                            if not node or node:IsA("LayerCollector") then break end
                            for _, x in ipairs(node:GetDescendants()) do
                                if (x:IsA("TextButton") or x:IsA("TextLabel")) and shown(x) and not x:IsDescendantOf(gui)
                                    and btnText(x):match("^%s*(.-)%s*$") == "on"
                                    and math.abs(x.AbsolutePosition.Y + x.AbsoluteSize.Y / 2 - rowY) <= 30 then
                                    target = x:IsA("GuiButton") and x or x:FindFirstAncestorWhichIsA("GuiButton") or x
                                    break
                                end
                            end
                            if target then break end
                            node = node.Parent
                        end
                        if target and os.clock() - lastStopClick >= (force and 1.2 or 3) then
                            lastStopClick = os.clock()
                            print("[PibbleHub] portal: Stop Auto On Loss was ON, switching it off")
                            clickPortalControl(target)
                        end
                        return "on"
                    end
                    return "off"
                end
            end
        end

        -- ---------- worlds ----------
        -- Goes to a world (by menu name) and waits until it really happened.
        local function enterWorld(world, ok, force)
            if not ok() then return false end
            -- the Dagon hover keeps the player anchored: an anchored player cannot be teleported to another world
            if Dagon.free then Dagon.free("teleport to another world") end
            local cur = currentWorld()
            if sameWorld(cur, world) and not force then return true end
            local curBefore = cur
            local sameAtStart = force and sameWorld(cur, world) -- the game says we are there already (maybe stale): short, best-effort try

            local root
            for _ = 1, 20 do
                root = getHRP()
                if root then break end
                task.wait(0.5)
            end
            if not root then status.Text = "Character unavailable"; return false end

            for attempt = 1, (sameAtStart and 2 or PCFG.WORLD_TRIES) do
                if not ok() then return false end
                local origin = getHRP() and getHRP().Position or root.Position
                status.Text = ("Teleporting to %s... (%d/%d)"):format(world, attempt, PCFG.WORLD_TRIES)
                local method = Worlds.go(world, attempt == 2)
                if method then
                    local deadline = os.clock() + (sameAtStart and 4 or PCFG.WORLD_TIMEOUT)
                    repeat
                        if not ok() then return false end
                        task.wait(0.2)
                        local hrp = getHRP()
                        cur = currentWorld()
                        local moved = hrp and (hrp.Position - origin).Magnitude or 0
                        local arrived
                        if type(cur) == "string" and cur ~= "" then
                            arrived = moved >= 100 or (sameWorld(cur, world) and (not force or cur ~= curBefore))
                        else
                            arrived = moved >= 25
                        end
                        if arrived then
                            task.wait(Portal.fast and 0.3 or PCFG.ARRIVE_WAIT)
                            return ok()
                        end
                    until os.clock() >= deadline
                end
            end
            if sameAtStart then return ok() end
            -- the game does not tell which world we are in: we may simply have been there already
            cur = currentWorld()
            if not (type(cur) == "string" and cur ~= "") then
                status.Text = world .. ": arrival not confirmed, continuing"
                return ok()
            end
            status.Text = world .. " arrival timed out"
            return false
        end

        -- ---------- walking into a gate ----------
        -- startRun = true: also presses Start in the waiting room (Auto Create). Returns true, or false + reason.
        -- the other player of a Follow / Host pair (the one picked in the portal menu)
        local function partnerPlayer()
            local name = Settings.follow.name
            if name == "" then return nil end
            for _, p in ipairs(Players:GetPlayers()) do
                if p.Name == name and p ~= player then return p end
            end
            return nil
        end

        -- HOST WAIT list: the names typed in the "Wait for" box (comma / space separated; a player may be matched by name or display
        -- name, any case). Empty box = the one picked with the Player button. Only players that are in the server are waited for.
        local function waitPlayers()
            local wanted = {}
            for w in tostring(Settings.host.names or ""):gmatch("[^,;%s]+") do wanted[#wanted + 1] = w:lower() end
            if #wanted == 0 and Settings.follow.name ~= "" then wanted[1] = Settings.follow.name:lower() end
            local out = {}
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= player then
                    for _, w in ipairs(wanted) do
                        if p.Name:lower() == w or p.DisplayName:lower() == w then out[#out + 1] = p; break end
                    end
                end
            end
            return out
        end

        -- is this player in our waiting room / arena? (his name shows in the room's texts, or his character is next to ours)
        local function playerPresent(p, st)
            if st and st.roomObj then
                local ln, dn = p.Name:lower(), p.DisplayName:lower()
                for _, d in ipairs(st.roomObj:GetDescendants()) do
                    if (d:IsA("TextLabel") or d:IsA("TextButton")) and shown(d) then
                        local t = clean(d.Text):lower()
                        if t ~= "" and (t:find(ln, 1, true) or (#dn >= 3 and t:find(dn, 1, true))) then return true end
                    end
                end
            end
            local mine = getHRP()
            local ch = p.Character
            local his = ch and ch:FindFirstChild("HumanoidRootPart")
            return mine ~= nil and his ~= nil and (mine.Position - his.Position).Magnitude <= PCFG.HOST_NEAR
        end
        -- (here, total): how many of the waited-for players are in the room
        local function waitCount(st)
            local list, here = waitPlayers(), 0
            for _, p in ipairs(list) do
                if playerPresent(p, st) then here += 1 end
            end
            return here, #list
        end
        -- the players that were in OUR portal room when the run started (for "wait until they have all left the portal")
        local Party = { names = nil, locs = {} }
        -- Auto Boss is SWITCHED OFF while a portal is being played (Auto Create / Follow Join) and switched back ON when no portal is
        -- left (nothing in the inventory / no gate to join / the portal feature stops). Only a switch that was ON is touched.
        local bossHeld = false
        local function holdBoss()
            if bossHeld or not (Boss.auto and Boss.setAuto) then return end
            bossHeld = true
            pcall(Boss.setAuto, false)
            print("[PibbleHub] portal: Auto Boss switched off while the portal is played")
        end
        local function releaseBoss(why)
            if not bossHeld then return end
            bossHeld = false
            if Boss.setAuto then pcall(Boss.setAuto, true) end
            print("[PibbleHub] portal: Auto Boss switched back on (" .. tostring(why or "no portal") .. ")")
        end
        local function recordParty(st)
            local names = {}
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= player and playerPresent(p, st) then names[#names + 1] = p.Name end
            end
            Party.names = names
            local mine0 = getHRP()
            Party.pos = mine0 and mine0.Position or nil -- (fallback) where the portal world is
            Party.locs = {}                              -- positions seen INSIDE this portal (filled by Party.sample while it runs)
            Party.t0 = os.clock()
            if #names > 0 then print("[PibbleHub] party at the start: " .. table.concat(names, ", ")) end
        end
        -- logs where the party is INSIDE the portal: the owner and every party member whose character can be seen. Called every few
        -- seconds while the portal runs; the "left the portal" check is the distance to these places.
        function Party.sample()
            if not Party.names then return end
            local added = 0
            local function add(pos)
                if not pos then return end
                for _, l in ipairs(Party.locs) do
                    if (l - pos).Magnitude < 15 then return end
                end
                if #Party.locs >= 24 then table.remove(Party.locs, 1) end
                Party.locs[#Party.locs + 1] = pos
                added += 1
            end
            local mine = getHRP()
            add(mine and mine.Position)
            for _, n in ipairs(Party.names) do
                local p = Players:FindFirstChild(n)
                local his = p and p.Character and p.Character:FindFirstChild("HumanoidRootPart")
                add(his and his.Position)
            end
            if added > 0 then
                local p1 = Party.locs[#Party.locs]
                print(("[PibbleHub] party: %d place(s) logged inside the portal (latest %d, %d, %d)"):format(#Party.locs, p1.X, p1.Y, p1.Z))
            end
        end
        local function partnerPresent(st)
            local here, total = waitCount(st)
            return total > 0 and here >= total
        end

        -- plain wait that honours the stop switch (returns false when stopped)
        local function pause0(seconds, ok)
            local untilT = os.clock() + seconds
            while os.clock() < untilT do
                if not ok() then return false end
                task.wait(0.1)
            end
            return ok()
        end

        local function joinPortal(gate, ok, walkSeconds, startRun, enterTimeout, pollDelay, jumpIn)
            local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
            if not humanoid then
                status.Text = "Character unavailable"
                return false, "character"
            end
            -- The Dagon hover (anchored, ghost = no touch / collision, PlatformStand) must be gone and the character must stand on the
            -- ground before he walks: a ghost character does not trigger the gate and simply walks through it.
            if Dagon.free then Dagon.free("walking into a portal") end
            do
                local hm0 = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
                local r0 = getHRP()
                if hm0 then pcall(function() hm0.PlatformStand = false end) end
                if r0 and r0.Anchored then pcall(function() r0.Anchored = false end) end
            end
            if not pause0(PCFG.PRE_WALK_DELAY or 0.8, ok) then return false, "stopped" end
            humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid") or humanoid
            status.Text = "Walking into portal..."
            local destination = gate.Position
            local root = getHRP()
            if walkSeconds and root then
                local offset = destination - root.Position
                local direction = Vector3.new(offset.X, 0, offset.Z)
                if direction.Magnitude < 0.1 then direction = root.CFrame.LookVector end
                -- a few studs behind the gate centre are enough; a fast walker (boosted WalkSpeed) used to run 100 studs past it
                local over = math.min(humanoid.WalkSpeed * walkSeconds, PCFG.MAX_OVERSHOOT or 14)
                destination = destination + direction.Unit * over
            end
            if not jumpIn then humanoid:MoveTo(destination) end -- (jumpIn: the player already stands on the gate and jumps, no walking)

            local lastJump, flip = -1, false
            local function jumpPulse()
                if PCFG.FOLLOW_TP_PULSE ~= false then
                    -- no jumping: the player stands right next to the gate and takes small steps left / right across its middle
                    -- (every 0.7 s a new MoveTo target 4 studs to the other side), so the gate's touch fires
                    if os.clock() - lastJump < 0.7 then return end
                    lastJump = os.clock()
                    flip = not flip
                    local hm = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
                    if hm and gate and gate:IsDescendantOf(workspace) then
                        local side = gate.CFrame.RightVector * (flip and 4 or -4)
                        pcall(function() hm:MoveTo(Vector3.new(gate.Position.X + side.X, getHRP() and getHRP().Position.Y or gate.Position.Y, gate.Position.Z + side.Z)) end)
                    end
                    return
                end
                if os.clock() - lastJump < 0.45 then return end
                lastJump = os.clock()
                local hm = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
                if hm then
                    -- a plain jump (Humanoid.Jump), only from the ground: no forced Jumping state, so no extra-high hop over the gate
                    pcall(function()
                        if hm.FloorMaterial ~= Enum.Material.Air then hm.Jump = true end
                    end)
                end
            end

            local function halt()
                local r = getHRP()
                if r then humanoid:MoveTo(r.Position) end
            end

            -- =============================================================
            -- STRICTLY SEQUENTIAL: every step must finish before the next one begins
            --   1. ENTER   walk into the gate until the waiting room (or the portal) is on screen
            --   2. SETTLE  wait ROOM_SETTLE s for the waiting room UI to finish loading
            --   3. FIGHT   turn Auto Fight on and confirm it; SKIPPED after AUTO_FIGHT_GRACE s
            --   4. START   wait START_DELAY s, press Start, confirm the waiting room closed
            -- =============================================================
            local stopWalkingAt = walkSeconds and os.clock() + walkSeconds

            -- timeline of everything seen / done, printed to F9: shows who really starts the run
            -- (a "wave HUD appeared" line BEFORE a "Start pressed" line = the game started it by itself)
            local t0 = os.clock()
            local function log(msg)
                print(("[PibbleHub] portal +%.1fs: %s"):format(os.clock() - t0, msg))
            end
            log(jumpIn and "standing on the gate, jumping to get in" or "walking into the gate")
            local seen = {}
            local startClicked = false

            -- Polls the interface every 0.3 s until cond(st) returns something truthy.
            -- Returns: the truthy value | false (timeout) | nil (stopped by the user)
            local roomSeen, roomLostAt, autoStarted = false, nil, false
            local haltedAt, rewalks = nil, 0
            local function poll(cond, timeout)
                local limit = os.clock() + timeout
                while gui.Parent do
                    if not ok() then halt(); return nil end
                    pcall(ensureStopAutoOff)
                    if jumpIn and not (portalState().room or portalState().inside) then jumpPulse() end
                    if stopWalkingAt and os.clock() >= stopWalkingAt then
                        halt()
                        stopWalkingAt = nil
                        haltedAt = os.clock()
                    end
                    local st = portalState()
                    if st.room and not seen.room then
                        seen.room = true
                        halt()
                        log("waiting room appeared")
                        dumpRoom(st.roomObj, "texts on screen when it appeared (look for a countdown / auto-start text)")
                    end
                    if st.start and not seen.start then seen.start = true; log("Start button found") end
                    if st.fightRow and not seen.fight then
                        seen.fight = true
                        log("Auto Fight row appeared, reads " .. (st.fightOn == true and "ON" or st.fightOn == false and "OFF" or "unknown"))
                    end
                    if st.wave and not seen.wave then
                        seen.wave = true
                        log(("wave HUD appeared (wave %d, lives %s) | Start pressed yet: %s"):format(
                            st.wave, tostring(st.lives), tostring(startClicked)))
                    end
                    if seen.room and not st.room and not seen.roomGone then
                        seen.roomGone = true
                        log("waiting room closed | Start pressed yet: " .. tostring(startClicked))
                    end
                    -- the waiting room was on screen and is gone while the portal HUD is still up:
                    -- the run has already started (by the game, or by hand). Nothing left to press.
                    if startRun then
                        if st.room then
                            roomSeen, roomLostAt = true, nil
                        elseif roomSeen and st.inside then
                            roomLostAt = roomLostAt or os.clock()
                            if os.clock() - roomLostAt >= 1 then autoStarted = true; return "autostarted" end
                        else
                            roomLostAt = nil
                        end
                    end
                    local r = cond(st)
                    if r then return r end
                    if os.clock() >= limit then return false end
                    task.wait(pollDelay or 0.3)
                end
                return nil
            end

            -- plain wait (still honours Stop and the walking cut-off). Returns false if stopped.
            local function pause(seconds)
                if seconds <= 0 then return ok() end
                return poll(function() return false end, seconds) ~= nil
            end

            -- true when the run was found already started: finishes joinPortal successfully
            local function alreadyStarted()
                if not autoStarted then return false end
                status.Text = "Portal started"
                print("[PibbleHub] portal: run already started (waiting room gone), skipping the remaining steps")
                return true
            end

            -- ---------- 1. ENTER ----------
            status.Text = "Walking into portal..."
            local insideSince, hudSince
            local entered = poll(function(st)
                if st.inside then insideSince = insideSince or os.clock() else insideSince = nil end
                -- walked through the gate without entering (nothing on screen 1.5 s after the walk was cut off): back to its middle
                if haltedAt and rewalks < (PCFG.REWALKS or 3) and os.clock() - haltedAt > 1.5
                    and not st.inside and not st.room and not st.wave then
                    rewalks += 1
                    haltedAt = nil
                    log(("did not get in, walking back to the middle of the gate (%d/%d)"):format(rewalks, PCFG.REWALKS or 3))
                    local r1 = getHRP()
                    local hm1 = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
                    if r1 and hm1 then
                        pcall(function() hm1.PlatformStand = false; r1.Anchored = false end)
                        hm1:MoveTo(Vector3.new(gate.Position.X, r1.Position.Y, gate.Position.Z))
                        stopWalkingAt = os.clock() + 2.5
                    end
                end
                if startRun then
                    if st.room then return "room" end
                    -- the wave HUD is up and there is no waiting room: the run has started by itself
                    if st.wave and not st.room then
                        hudSince = hudSince or os.clock()
                        if os.clock() - hudSince >= 2 then return "noroom" end
                    else
                        hudSince = nil
                    end
                    -- no waiting room at all: the run has started by itself
                    if insideSince and os.clock() - insideSince >= PCFG.NO_ROOM_AFTER then return "noroom" end
                    return false
                end
                return st.inside and "inside" or false
            end, enterTimeout or PCFG.WALK_TIMEOUT)

            if entered == nil then return false, "stopped" end
            if entered == false then
                halt()
                if startRun then
                    status.Text = "Waiting room not found"
                    return false, "waiting room"
                end
                status.Text = "Portal entry not confirmed"
                return false, "enter"
            end
            -- stop the walk the moment the room / portal is reached: the MoveTo target is still the gate's world position, and a player
            -- that keeps walking toward it simply walks back OUT of the waiting room
            stopWalkingAt = nil
            halt()
            if entered == "noroom" then
                status.Text = "Portal running (no waiting room)"
                return true
            end

            -- ---------- 2. SETTLE ----------
            log("step 2: settle")
            status.Text = "Waiting room loading..."
            if not pause(PCFG.ROOM_SETTLE) then return false, "stopped" end
            if alreadyStarted() then return true end

            -- ---------- 3. AUTO FIGHT (skipped after AUTO_FIGHT_GRACE seconds) ----------
            if PCFG.AUTO_FIGHT_CLICKS > 0 then
                log("step 3: Auto Fight")
                status.Text = "Checking Auto Fight..."
                local stepStart = os.clock()
                local clicks, lastClick, dumped = 0, -9, false
                local fightResult = poll(function(st)
                    if st.fightObj and not dumped then
                        dumped = true
                        dumpFightRow(st.fightObj)
                    end
                    if st.fightOn == true then return "on" end
                    if st.fightRow and st.fightOn == false and st.toggle and clicks < PCFG.AUTO_FIGHT_CLICKS
                        and os.clock() - stepStart >= PCFG.FIGHT_CLICK_DELAY
                        and os.clock() - lastClick >= 2 then
                        lastClick = os.clock()
                        clicks += 1
                        status.Text = "Turning Auto Fight on..."
                        log("Auto Fight toggle clicked")
                        clickPortalControl(st.toggle)
                    end
                    return false
                end, PCFG.AUTO_FIGHT_GRACE)

                if fightResult == nil then return false, "stopped" end
                if alreadyStarted() then return true end
                if fightResult == "on" then
                    status.Text = "Auto Fight is on"
                    -- we clicked it ourselves: give the game a moment before the next step
                    if clicks > 0 and not pause(PCFG.AFTER_TOGGLE_DELAY) then return false, "stopped" end
                    if alreadyStarted() then return true end
                else
                    status.Text = "Auto Fight skipped (not detected after " .. PCFG.AUTO_FIGHT_GRACE .. "s)"
                    print("[PibbleHub] Auto Fight not detected as ON after " .. PCFG.AUTO_FIGHT_GRACE .. "s, skipped")
                    if not pause(1) then return false, "stopped" end -- let the message be seen
                    if alreadyStarted() then return true end
                end
            end

            -- ---------- 3b. STOP AUTO ON LOSS must be OFF before the run is started ----------
            do
                local t0, lastState = os.clock(), nil
                while os.clock() - t0 < 8 do
                    if alreadyStarted() then return true end
                    lastState = ensureStopAutoOff(true)
                    if lastState ~= "on" then break end
                    status.Text = "Switching Stop Auto On Loss off..."
                    if not pause(0.6) then return false, "stopped" end
                end
                log("Stop Auto On Loss: " .. tostring(lastState))
                if lastState == "on" then print("[PibbleHub] portal: Stop Auto On Loss is still ON after 8s, starting anyway") end
            end

            -- ---------- 4. START ----------
            log("step 4: Start")
            status.Text = "Waiting before Start..."
            if not pause(PCFG.START_DELAY) then return false, "stopped" end
            if alreadyStarted() then return true end

            if not startRun then
                status.Text = "In portal"
                return true
            end

            -- HOST WAIT (owner side): hold Start until the picked player is in the room (or HOST_WAIT seconds are over)
            if Settings.host.on and #waitPlayers() > 0 then
                local t1 = os.clock()
                local names = {}
                for _, p in ipairs(waitPlayers()) do names[#names + 1] = p.Name end
                local who = table.concat(names, ", ")
                log("host wait for " .. who)
                local got = poll(function(st)
                    if partnerPresent(st) then return "here" end
                    local here, total = waitCount(st)
                    status.Text = ("Waiting for players %d/%d... %ds"):format(here, total, math.max(0, math.floor(PCFG.HOST_WAIT - (os.clock() - t1))))
                    return false
                end, PCFG.HOST_WAIT)
                if got == nil then return false, "stopped" end
                if alreadyStarted() then return true end
                if got == "here" then
                    status.Text = "All joined, starting..."
                    if not pause(PCFG.HOST_AFTER_JOIN) then return false, "stopped" end
                    if alreadyStarted() then return true end
                else
                    status.Text = "Not everyone joined, starting anyway"
                    print("[PibbleHub] host wait: not everyone showed up in time, starting without them (" .. who .. ")")
                end
            end

            pcall(recordParty, portalState())
            local lastStart, startTries = -9, 0
            local roomGoneSince, roomDumped, lookingSince = nil, false, os.clock()
            local lastLog = -9
            local started = poll(function(st)
                if os.clock() - lastLog >= 5 then
                    lastLog = os.clock()
                    print(("[PibbleHub] portal Start step: room=%s start=%s inside=%s wave=%s lives=%s clicked=%s tries=%d"):format(
                        tostring(st.room == true), tostring(st.start ~= nil), tostring(st.inside),
                        tostring(st.wave), tostring(st.lives), tostring(startClicked), startTries))
                end
                -- the waiting room closed: the run has started
                if not st.room then
                    roomGoneSince = roomGoneSince or os.clock()
                    if startClicked or os.clock() - roomGoneSince >= PCFG.NO_ROOM_AFTER then return "started" end
                    return false
                end
                roomGoneSince = nil
                if st.start then
                    lookingSince = os.clock()
                    -- first try fires the button's handlers, later tries (every 3 s) use a real mouse click
                    if startTries < 4 and os.clock() - lastStart >= 3 then
                        lastStart = os.clock()
                        startTries += 1
                        local clicked
                        log(("Start pressed (try %d)"):format(startTries))
                        if startTries >= 2 then clicked = physicalClick(st.start) else clicked = clickPortalControl(st.start) end
                        startClicked = clicked or startClicked
                        if startClicked then status.Text = ("Starting portal run... (try %d)"):format(startTries) end
                    end
                elseif not startClicked and os.clock() - lookingSince >= 2 then
                    status.Text = "Waiting room open, looking for Start..."
                    if not roomDumped then
                        roomDumped = true
                        local sc = scanUI()
                        if sc.room then dumpRoom(sc.room) end
                    end
                end
                return false
            end, PCFG.START_TIMEOUT)

            if started == nil then return false, "stopped" end
            if alreadyStarted() then return true end
            if started == false then
                halt()
                status.Text = startClicked and "Start was clicked but the waiting room is still open"
                    or "Waiting Room Start button not found"
                return false, startClicked and "start" or "waiting room"
            end
            status.Text = "Portal started"
            return true
        end

        -- ---------- waiting for the end of a portal ----------
        local function portalPause(ok)
            if Portal.fast then return ok() end -- Follow Join: straight on to the next gate
            for left = PCFG.RESULT_WAIT, 1, -1 do
                if not ok() then return false end
                status.Text = ("Portal over, next one in %ds..."):format(left)
                task.wait(1)
            end
            return ok()
        end

        -- ---------- Discord webhook (portal results) ----------
        -- Roblox scripts cannot take a picture of the screen, so the REWARDS ARE READ AS TEXT from the results
        -- screen (every visible label, grouped by row) and posted as a clean list (no pictures).
        local Hook = {}

        -- (Lua patterns cannot make a group optional, so the accepted prefixes are listed one by one)
        local HOOK_PREFIXES = {
            "https://discord.com/api/webhooks/",
            "https://discordapp.com/api/webhooks/",
            "https://canary.discord.com/api/webhooks/",
            "https://ptb.discord.com/api/webhooks/",
        }
        function Hook.valid(url)
            if type(url) ~= "string" then return false end
            for _, prefix in ipairs(HOOK_PREFIXES) do
                if url:sub(1, #prefix) == prefix and #url > #prefix + 10 then return true end
            end
            return false
        end

        function Hook.enabled()
            return Settings.hook.on and Hook.valid(Settings.hook.url)
        end

        local function trunc(t, n)
            t = tostring(t)
            if #t <= n then return t end
            return t:sub(1, n - 3) .. "..."
        end

        -- Reads the results panel BY SECTION (what the game shows):
        --   header   "ISEKAI PORTAL" / "Out Of Lives" / "Party Waves: 59  You Cleared: 59"
        --   PLAYERS  "1. Name (You)   59 Waves"
        --   YOUR REWARDS  cards: an amount ("x6") + a name ("Evolution Potion") under it
        -- Each amount is paired with the name of ITS card (closest name, each used once), never with another section's text.
        local function collectResultTexts(st)
            local res = {rewards = {}, players = {}, lines = {}}
            local title, btn = st.resultObj, st.continue
            if not title then return res end
            local root = title.Parent
            while root and not root:IsA("LayerCollector") do
                if not btn or btn:IsDescendantOf(root) then break end
                root = root.Parent
            end
            if not root or root:IsA("LayerCollector") then root = title.Parent and title.Parent.Parent or title.Parent end
            res.title = clean(title.Text):match("^%s*(.-)%s*$")

            local items = {}
            for _, d in ipairs(root:GetDescendants()) do
                if (d:IsA("TextLabel") or d:IsA("TextButton")) and shown(d) and not d:IsDescendantOf(gui) then
                    local t = clean(d.Text):match("^%s*(.-)%s*$")
                    if t ~= "" and d ~= title and not (btn and (d == btn or d:IsDescendantOf(btn))) then
                        local it = {t = t, low = t:lower(), obj = d, x = d.AbsolutePosition.X,
                            cx = d.AbsolutePosition.X + d.AbsoluteSize.X / 2,
                            cy = d.AbsolutePosition.Y + d.AbsoluteSize.Y / 2}
                        local dup = false -- outlined texts are often drawn twice on top of each other
                        for _, o in ipairs(items) do
                            if o.t == it.t and math.abs(o.cx - it.cx) < 6 and math.abs(o.cy - it.cy) < 6 then dup = true; break end
                        end
                        if not dup then items[#items + 1] = it end
                    end
                end
            end

            local playersY, rewardsY
            for _, it in ipairs(items) do
                if it.low:match("^players?$") then playersY = playersY or it.cy
                elseif it.low:match("^your rewards") then rewardsY = rewardsY or it.cy end
            end
            local function byReading(p, q)
                local rp, rq = math.floor(p.cy / 20), math.floor(q.cy / 20)
                if rp ~= rq then return rp < rq end
                return p.x < q.x
            end

            -- header
            local headEnd = playersY or rewardsY or math.huge
            local head = {}
            for _, it in ipairs(items) do
                if it.cy < headEnd then
                    head[#head + 1] = it.low
                    if not res.portal and it.low:find("portal", 1, true) and not it.low:find("waves", 1, true) then
                        res.portal = it.t
                    end
                end
            end
            local joined = table.concat(head, " ")
            res.partyWaves = tonumber(joined:match("party waves%s*:?%s*(%d+)"))
            res.cleared = tonumber(joined:match("you cleared%s*:?%s*(%d+)"))

            -- players
            if playersY then
                local rows = {}
                for _, it in ipairs(items) do
                    if it.cy > playersY and (not rewardsY or it.cy < rewardsY) then
                        local row
                        for _, r in ipairs(rows) do
                            if math.abs(r.cy - it.cy) <= 10 then row = r; break end
                        end
                        if not row then row = {cy = it.cy, list = {}}; rows[#rows + 1] = row end
                        row.list[#row.list + 1] = it
                    end
                end
                table.sort(rows, function(p, q) return p.cy < q.cy end)
                for _, r in ipairs(rows) do
                    table.sort(r.list, function(p, q) return p.x < q.x end)
                    local name, waves
                    for _, it in ipairs(r.list) do
                        local w = it.low:match("^(%d+)%s*waves?$")
                        if w then
                            waves = w
                        else
                            local nm = (it.t:gsub("^%d+%.%s*", ""))
                            if nm ~= "" and not name then name = nm end
                        end
                    end
                    if name then res.players[#res.players + 1] = {name = name, waves = waves} end
                end
            end

            -- rewards
            local names, amts = {}, {}
            for _, it in ipairs(items) do
                if rewardsY and it.cy > rewardsY then
                    local isAmount = #it.t <= 10 and it.t:find("%d") ~= nil and it.t:find("%a%a%a") == nil
                    if isAmount then amts[#amts + 1] = it else names[#names + 1] = it end
                end
            end
            -- 1) by card: an amount and a name that sit in the same card frame belong together (the smallest frame around the
            --    amount that holds exactly one still-unpaired name). This does not depend on how the card is laid out.
            local nameOwner = {}
            for ni, nm in ipairs(names) do nameOwner[nm.obj] = ni end
            local usedN, usedA = {}, {}
            for ai, am in ipairs(amts) do
                local anc = am.obj and am.obj.Parent
                local depth = 0
                while anc and anc ~= root and depth < 6 do
                    local found, count = nil, 0
                    for _, d in ipairs(anc:GetDescendants()) do
                        local ni = nameOwner[d]
                        if ni then count += 1; found = ni end
                        if count > 1 then break end
                    end
                    if count == 1 then
                        if not usedN[found] then
                            usedN[found], usedA[ai] = true, true
                            names[found].amount = am.t
                        end
                        break
                    elseif count > 1 then
                        break -- the frame already holds several cards: the card frame is not found, use the position below
                    end
                    anc = anc.Parent
                    depth += 1
                end
            end
            -- 2) the rest by position: the amount closest to a name, each used once
            local pairsList = {}
            for ni, nm in ipairs(names) do
                if usedN[ni] then continue end
                for ai, am in ipairs(amts) do
                    if usedA[ai] then continue end
                    local dx, dy = am.cx - nm.cx, am.cy - nm.cy
                    if math.abs(dx) <= 120 then
                        pairsList[#pairsList + 1] = {ni = ni, ai = ai, d = math.abs(dx) + math.abs(dy) * 0.4}
                    end
                end
            end
            table.sort(pairsList, function(p, q) return p.d < q.d end)
            for _, p in ipairs(pairsList) do
                if not usedN[p.ni] and not usedA[p.ai] then
                    usedN[p.ni], usedA[p.ai] = true, true
                    names[p.ni].amount = amts[p.ai].t
                end
            end
            table.sort(names, byReading)
            for _, nm in ipairs(names) do
                res.rewards[#res.rewards + 1] = {name = nm.t, amount = nm.amount}
                print(("[PibbleHub] reward read: '%s' x '%s'"):format(nm.t, tostring(nm.amount)))
            end
            for ai, am in ipairs(amts) do
                if not usedA[ai] then print(("[PibbleHub] reward amount '%s' has no name"):format(am.t)) end
            end

            -- fallback: no "YOUR REWARDS" section found -> every text as a plain line
            if #res.rewards == 0 and not rewardsY then
                table.sort(items, byReading)
                for _, it in ipairs(items) do
                    if #res.lines < 20 then res.lines[#res.lines + 1] = it.t end
                end
            end
            return res
        end

        -- ---- running totals of every reward (kept in the settings file, survive a relaunch) ----
        -- k, m, b, t, qa, qi ... (the same list the Generations tab uses: every step is x1000)
        local SUFFIX, SUFFIX_NAMES = {}, {}
        for i, sfx in ipairs(CFG.GEN_SUFFIXES) do
            SUFFIX[sfx:lower()] = 1000 ^ i
            SUFFIX_NAMES[i] = sfx:upper()
        end
        -- "x6", "+6", "6x", "1.2K", "3 M", "1,234" -> a number. Returns nil when no number is in the text.
        local function parseAmount(a)
            local t = tostring(a or ""):lower():gsub(",", "")
            local n, suf = t:match("(%d+%.?%d*)%s*(%a*)")
            n = tonumber(n)
            if not n then return nil end
            return n * (SUFFIX[suf] or 1)
        end
        local function fmtAmount(v)
            for i = #SUFFIX_NAMES, 1, -1 do
                local base = 1000 ^ i
                if v >= base then
                    local x = v / base
                    local txt = x >= 100 and ("%d"):format(math.floor(x)) or (x >= 10 and ("%.1f"):format(x) or ("%.2f"):format(x))
                    if txt:find("%.") then txt = txt:gsub("0+$", ""):gsub("%.$", "") end
                    return txt .. SUFFIX_NAMES[i]
                end
            end
            return tostring(math.floor(v + 0.5))
        end

        local Session = { n = 0, items = {}, t0 = os.time() } -- rewards since this launch (not saved)

        function Hook.addTotals(res)
            local T = Settings.hook.totals
            if type(res) ~= "table" or not T then return end
            T.n = (T.n or 0) + 1
            Session.n += 1
            for _, rw in ipairs(res.rewards or {}) do
                if rw.name and rw.name ~= "" then
                    local v = parseAmount(rw.amount)
                    if v == nil then
                        -- a card without an amount counts as one; an amount that could not be read is skipped (and printed)
                        if rw.amount and tostring(rw.amount) ~= "" then
                            print("[PibbleHub] totals: could not read the amount '" .. tostring(rw.amount) .. "' of " .. rw.name)
                            v = 0
                        else
                            v = 1
                        end
                    end
                    print(("[PibbleHub] totals: +%s %s (read '%s')"):format(tostring(v), rw.name, tostring(rw.amount)))
                    T.items[rw.name] = (T.items[rw.name] or 0) + v
                    Session.items[rw.name] = (Session.items[rw.name] or 0) + v
                end
            end
            Settings.save()
        end

        local function totalsBlock(items)
            local list = {}
            for name, v in pairs(items) do list[#list + 1] = {name = name, v = v} end
            table.sort(list, function(x, y) return x.v > y.v end)
            local width = 0
            for _, r in ipairs(list) do r.txt = fmtAmount(r.v); width = math.max(width, #r.txt) end
            local out = {}
            for i, r in ipairs(list) do
                if i > 15 then break end
                out[#out + 1] = r.txt .. string.rep(" ", width - #r.txt + 2) .. r.name
            end
            if #out == 0 then return "*Nothing yet*" end
            return "```\n" .. trunc(table.concat(out, "\n"), 950) .. "\n```"
        end

        function Hook.sendTotals()
            local url = Settings.hook.url
            if not Hook.valid(url) then return false, "invalid url" end
            local req = (syn and syn.request) or (http and http.request) or http_request or request or (fluxus and fluxus.request)
            if not req then return false, "no request function" end
            local T = Settings.hook.totals
            local mins = math.max(0, math.floor((os.time() - Session.t0) / 60))
            local embed = {
                author = {name = "PibbleHub  •  Total rewards"},
                title = "📊  Rewards gained",
                fields = {
                    {name = ("This session  ·  %d portals  ·  %dh %02dm"):format(Session.n, mins // 60, mins % 60),
                        value = totalsBlock(Session.items), inline = false},
                    {name = ("All time  ·  %d portals"):format(T.n or 0), value = totalsBlock(T.items), inline = false},
                },
                color = 0x4276EB,
                footer = {text = player.Name},
                timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            }
            local okReq = pcall(req, {Url = url, Method = "POST", Headers = {["Content-Type"] = "application/json"},
                Body = HttpService:JSONEncode({username = "PibbleHub", embeds = {embed}})})
            return okReq
        end

        function Hook.resetTotals()
            Settings.hook.totals = { n = 0, items = {} }
            Session.n, Session.items, Session.t0 = 0, {}, os.time()
            Settings.save()
        end

        -- ---- message layout ----
        -- One clean embed, no pictures: result header, a stats row (waves / lives / time), the players and the rewards.
        local LOSS_WORDS = {"defeat", "lose", "lost", "fail", "game over"}
        local function isLossTitle(t)
            t = tostring(t or ""):lower()
            for _, w in ipairs(LOSS_WORDS) do
                if t:find(w, 1, true) then return true end
            end
            return false
        end

        -- info = {name, title, res, wave, lives, maxLives, secs, test}
        function Hook.send(info)
            local url = Settings.hook.url
            if not Hook.valid(url) then return false, "invalid url" end
            local req = (syn and syn.request) or (http and http.request) or http_request or request
                or (fluxus and fluxus.request)
            if not req then
                warn("[PibbleHub] webhook: this executor has no request function")
                return false, "no request function"
            end

            local embed
            if info.test then
                embed = {
                    title = "PibbleHub connected",
                    description = "Portal results will be posted in this channel.",
                    color = 0x4276EB,
                    footer = {text = "PibbleHub  •  " .. player.Name},
                    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                }
            else
                local r = info.res or {rewards = {}, players = {}, lines = {}}
                local lost = isLossTitle(info.title)
                local outOfLives = tostring(info.title or ""):lower():find("out of lives", 1, true) ~= nil
                local secs = math.max(0, math.floor(info.secs or 0))
                -- "You Cleared" from the results screen is the real count (the live wave counter is already one ahead)
                local cleared = r.cleared or info.wave
                local maxL = info.maxLives or info.lives
                local livesText = "-"
                if outOfLives then
                    livesText = maxL and ("0 / %d"):format(maxL) or "0"
                elseif info.lives then
                    livesText = ("%d / %d"):format(info.lives, maxL or info.lives)
                end
                local fields = {
                    {name = "🌊  Waves", value = "**" .. (cleared and tostring(cleared) or "-") .. "**", inline = true},
                    {name = "❤️  Lives", value = "**" .. livesText .. "**", inline = true},
                    {name = "⏱️  Time", value = "**" .. ("%d:%02d"):format(secs // 60, secs % 60) .. "**", inline = true},
                }
                if #r.players > 0 then
                    local pl = {}
                    for i, p in ipairs(r.players) do
                        if i > 8 then break end
                        pl[#pl + 1] = ("**%s**%s"):format(p.name, p.waves and ("  ·  %s waves"):format(p.waves) or "")
                    end
                    fields[#fields + 1] = {name = "👥  Players", value = trunc(table.concat(pl, "\n"), 1000), inline = false}
                end
                -- rewards: an aligned block, amounts on the left
                local rows, width = {}, 0
                for i, rw in ipairs(r.rewards) do
                    if i > 14 then break end
                    local am = rw.amount or "-"
                    width = math.max(width, #am)
                    rows[#rows + 1] = {am, rw.name}
                end
                local rewardText
                if #rows > 0 then
                    local out = {}
                    for _, row in ipairs(rows) do
                        out[#out + 1] = row[1] .. string.rep(" ", width - #row[1] + 2) .. row[2]
                    end
                    rewardText = "```\n" .. trunc(table.concat(out, "\n"), 950) .. "\n```"
                elseif r.lines and #r.lines > 0 then
                    rewardText = trunc("• " .. table.concat(r.lines, "\n• "), 1000)
                else
                    rewardText = "*No rewards found on the results screen*"
                end
                fields[#fields + 1] = {name = "🎁  Rewards", value = rewardText, inline = false}

                local result = (info.title and info.title ~= "") and info.title or (lost and "Defeat" or "Victory")
                local desc = "### " .. trunc(result, 100)
                if r.partyWaves and r.cleared and r.partyWaves ~= r.cleared then
                    desc = desc .. ("\nParty reached wave %d"):format(r.partyWaves)
                end
                -- green = cleared, gold = ran out of lives (the normal end of a portal), red = defeat
                local color = lost and 0xB83A4B or (outOfLives and 0xE8A33D or 0x2C9860)
                embed = {
                    author = {name = "PibbleHub  •  Portal report"},
                    title = trunc("🌀  " .. tostring(info.name or r.portal or "Portal"), 250),
                    description = desc,
                    color = color,
                    fields = fields,
                    footer = {text = player.Name .. "  •  portal finished"},
                    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                }
            end

            local body = {
                username = "PibbleHub",
                embeds = {embed},
            }
            local okReq, res = pcall(req, {
                Url = url,
                Method = "POST",
                Headers = {["Content-Type"] = "application/json"},
                Body = HttpService:JSONEncode(body),
            })
            local code = okReq and type(res) == "table" and (res.StatusCode or res.Status) or nil
            if okReq and (code == nil or (tonumber(code) and tonumber(code) >= 200 and tonumber(code) < 300)) then
                print("[PibbleHub] webhook sent" .. (code and (" (" .. tostring(code) .. ")") or ""))
                return true
            end
            warn("[PibbleHub] webhook failed:", okReq and tostring(code) or tostring(res))
            return false, okReq and tostring(code) or tostring(res)
        end

        -- true = the portal is over (results closed / ended / timed out); false = stopped by the user
        local function waitForPortalResultsInner(ok, assumeInside, portalName)
            local started = os.clock()
            local seen = assumeInside == true
            local goneSince, closeStarted
            local lastClick = -9
            local lastWave, lastLives, lastMax, reported
            local deadSince, deathTried = nil, 0
            Portal.lobbyAt = nil
            while gui.Parent and ok() do
                pcall(ensureStopAutoOff)
                local st = portalState()
                -- out of lives / dead: do not wait on the death screen, go back to the lobby right away (the owner sees who has left)
                if PCFG.DEATH_TO_LOBBY ~= false and not st.continue and st.inside then
                    local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
                    local dead = (st.lives ~= nil and st.lives <= 0 and lastWave ~= nil and st.wave ~= nil)
                        or (hum ~= nil and hum.Health <= 0 and lastWave ~= nil)
                    if dead then
                        deadSince = deadSince or os.clock()
                        if os.clock() - deadSince >= 2 and deathTried < 4 and os.clock() - (Portal.lastDeathTry or -99) >= 6 then
                            deathTried = deathTried + 1
                            Portal.lastDeathTry = os.clock()
                            print(("[PibbleHub] portal: dead / out of lives (lives=%s), going to the lobby (try %d)"):format(tostring(st.lives), deathTried))
                            status.Text = "Out of lives, going to the lobby..."
                            task.spawn(function()
                                local okT, r = pcall(enterWorld, "Lobby", function() return gui.Parent ~= nil end, true)
                                if okT and r then Portal.lobbyAt = os.clock() end
                            end)
                        end
                    else
                        deadSince = nil
                    end
                end
                if st.wave then
                    lastWave = st.wave
                    if os.clock() - (Party.lastSample or -9) >= 5 then Party.lastSample = os.clock(); pcall(Party.sample) end
                end
                if st.lives then lastLives, lastMax = st.lives, st.maxLives end
                if st.continue then
                    -- the results screen is up: read the rewards and post them (before Continue removes the panel)
                    if not reported then
                        reported = true
                        if Hook.enabled() then
                            status.Text = "Reading rewards..."
                            task.wait(PCFG.HOOK_CAPTURE_DELAY)
                            local snap = portalState()
                            if not snap.continue then snap = st end
                            local res = collectResultTexts(snap)
                            local info = {
                                name = portalName, title = res.title, res = res,
                                wave = lastWave, lives = lastLives, maxLives = lastMax,
                                secs = os.clock() - started,
                            }
                            task.spawn(function() pcall(Hook.addTotals, res); pcall(Hook.send, info) end)
                        end
                    end
                    closeStarted = closeStarted or os.clock()
                    goneSince = nil
                    status.Text = "Closing portal results..."
                    if os.clock() - lastClick >= 2 then
                        lastClick = os.clock()
                        clickPortalControl(st.continue)
                    end
                    if os.clock() - closeStarted >= 15 then
                        status.Text = "Continue did not work, leaving anyway"
                        return portalPause(ok)
                    end
                elseif closeStarted then
                    task.wait(Portal.fast and 0.3 or 1)
                    if not portalState().continue then return portalPause(ok) end
                else
                    if st.inside then
                        seen = true
                        goneSince = nil
                    elseif seen then
                        goneSince = goneSince or os.clock()
                        if os.clock() - goneSince >= (Portal.fast and 6 or PCFG.GONE_AFTER) then
                            status.Text = "Portal ended (no results screen seen)"
                            return portalPause(ok)
                        end
                    end
                    local secs = math.floor(os.clock() - started)
                    -- like the Infinite Tower status ("Void | F5 | ..."): wave | lives | time left
                    if st.wave or st.lives then
                        local parts = {}
                        if st.wave then parts[#parts + 1] = "Wave " .. st.wave end
                        if st.lives then parts[#parts + 1] = ("Lives %d/%d"):format(st.lives, st.maxLives or st.lives) end
                        parts[#parts + 1] = st.time or ("%d:%02d"):format(secs // 60, secs % 60)
                        status.Text = table.concat(parts, " | ")
                    else
                        status.Text = ("Portal running... %d:%02d"):format(secs // 60, secs % 60)
                    end
                    if secs >= PCFG.MAX_RUN then
                        status.Text = "Portal timed out, leaving"
                        return portalPause(ok)
                    end
                end
                task.wait(0.5)
            end
            return false
        end

        -- marks the portal fight for the Dagon combo (Portal.fighting) while the results are awaited
        local function waitForPortalResults(ok, assumeInside, portalName)
            Portal.fighting = true
            local okW, r = pcall(waitForPortalResultsInner, ok, assumeInside, portalName)
            Portal.fighting = false
            if not okW then error(r, 0) end
            return r
        end

        -- ---------- creating a portal from the inventory ----------
        -- returns true, or false + reason ("stopped", "stock", "lobby", "world", "item click", "use", "gate", or a joinPortal reason)
        -- The owner can be out of lives long before the rest of the party. Before a new portal is created, wait until every player of
        -- the party has left the old one (they are back in the lobby = close to us). Players who left the game do not count.
        local function waitPartyGone(ok)
            local names = Party.names
            if not names or #names == 0 then return true end
            local t0, lastLog = os.clock(), -9
            local maxSecs = PCFG.PORTAL_MAX_SECS or 660
            -- The owner is in the lobby now and everybody else also goes back to the lobby when his run is over (Auto Boss is off while
            -- portals are played). So a party member has left the portal when his character is seen next to ours; one who is not seen
            -- is still in the portal, until the portal's longest possible time is over. Players who left the server do not count.
            while ok() and gui.Parent and os.clock() - t0 < (PCFG.PARTY_LEAVE_WAIT or 600) do
                local away, mine = {}, getHRP()
                for _, n in ipairs(names) do
                    local p = Players:FindFirstChild(n)
                    if p then
                        local his = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
                        local dist = (his and mine) and (his.Position - mine.Position).Magnitude or nil
                        local back = dist ~= nil and dist <= (PCFG.PARTY_BACK_RANGE or 300)
                        local stillIn = not back and (os.clock() - (Party.t0 or 0) < maxSecs)
                        if stillIn then away[#away + 1] = n end
                        if os.clock() - lastLog >= 15 then
                            print(("[PibbleHub] party wait: %s | character seen: %s | distance to me: %s | %s"):format(
                                n, tostring(his ~= nil), dist and tostring(math.floor(dist)) or "?", stillIn and "still in the portal" or "back / out"))
                        end
                    end
                end
                if #away == 0 then break end
                if os.clock() - lastLog >= 15 then lastLog = os.clock() end
                status.Text = ("Waiting for the party to leave the portal: %s (%ds)"):format(table.concat(away, ", "), math.floor(os.clock() - t0))
                task.wait(1)
            end
            Party.names = nil
            return ok()
        end

        local function createPortal(choice, ok)
            if not enterWorld("Lobby", ok) then return false, ok() and "lobby" or "stopped" end
            if not enterWorld(choice.world, ok) then return false, ok() and "world" or "stopped" end

            local snapshot = portalGateSnapshot()
            status.Text = "Opening inventory..."
            openInventory()
            local item
            local deadline = os.clock() + 6
            repeat
                local inventory = getInventory()
                if inventory and inventoryIsOpen(inventory) then
                    local ig = inventory:FindFirstChild("ItemFrame") and inventory.ItemFrame:FindFirstChild("ItemGrid")
                    item = findPortalItem(inventory, resolvePortalName(ig, choice))
                end
                if not item then task.wait(0.2) end
            until not ok() or item or os.clock() >= deadline
            if not ok() then closeInventory(); return false, "stopped" end
            if not item then
                closeInventory()
                return false, "stock"
            end
            if not activateButton(item) then
                closeInventory()
                return false, "item click"
            end

            local useButton
            deadline = os.clock() + 5
            repeat
                task.wait(0.2)
                local inventory = getInventory()
                if inventory then useButton = visibleButtonIn(inventory, "use") end
            until not ok() or useButton or os.clock() >= deadline
            local used = ok() and useButton and activateButton(useButton)
            closeInventory()
            if not ok() then return false, "stopped" end
            if not used then return false, "use" end

            status.Text = "Waiting for " .. choice.label .. " portal..."
            task.wait(PCFG.GATE_SPAWN_WAIT)
            local gate
            deadline = os.clock() + 8
            repeat
                if not ok() then return false, "stopped" end
                task.wait(0.2)
                gate = findNewPortal(snapshot)
            until gate or os.clock() >= deadline
            if not gate then
                status.Text = "Portal spawned, but its gate was not found"
                return false, "gate"
            end

            local joined, why = joinPortal(gate, ok, 2, true)
            if not joined then return false, why end
            if not waitForPortalResults(ok, true, choice.label) then return false, "stopped" end
            -- combo: the player is at the island (or flying there): no trip back to the lobby
            if not (Dagon.combo and Dagon.hoverRoot ~= nil) then
                -- always really teleport (the game's world name can be stale); skipped only if the death handler already did it
                local already = false -- always send him to the lobby once the results are closed (a death teleport may not have worked)
                for try = 1, 3 do
                    if not ok() then break end
                    if enterWorld("Lobby", ok, not already) then break end
                end
            end
            if not waitPartyGone(ok) then return false, "stopped" end
            return true
        end

        -- ---------- UI: portal checkboxes + switches ----------
        local choices, choiceButtons = {}, {}
        local function refreshChoice(choice)
            choiceButtons[choice].Text = (selectedPortals[choice] and "☑ " or "☐ ") .. choice.difficulty
        end

        for index, world in ipairs(portalChoices) do
            local y = 28 + (index - 1) * 26
            local worldLabel = label(world.label, y + 3, nil, 13)
            worldLabel.Parent = menu
            worldLabel.Size = UDim2.fromOffset(98, 20)
            worldLabel.ZIndex = 21

            for column, difficulty in ipairs({"Normal", "Nightmare"}) do
                local choice = {
                    label = world.label .. " " .. difficulty,
                    item = world.item .. (difficulty == "Nightmare" and "_nightmare" or ""),
                    world = world.world,
                    difficulty = difficulty,
                }
                local portalButton = button("☐ " .. difficulty, 108 + (column - 1) * 88, y, column == 1 and 84 or 82, 24, DARK, menu, 21)
                portalButton.TextSize = 12
                choices[#choices + 1] = choice
                choiceButtons[choice] = portalButton
                portalButton.Activated:Connect(function()
                    if busy then return end
                    selectedPortals[choice] = not selectedPortals[choice] or nil
                    refreshChoice(choice)
                end)
            end
        end

        local useSelectedBtn = button("Auto Create: OFF", 8, 264, 164, 28, DARK, menu, 21)
        local selectAllBtn = button("Toggle All", 198, 5, 80, 20, DARK, menu, 21)
        selectAllBtn.TextSize = 11
        local hostBtn = button("Wait: OFF", 176, 264, 102, 28, DARK, menu, 21)
        hostBtn.TextSize = 12
        -- Follow Join: join the portals opened by ONE chosen player of the server
        local pickBtn = button("Player: none", 8, 296, 164, 28, DARK, menu, 21)
        pickBtn.TextSize = 12
        local followBtn = button("Follow: OFF", 176, 296, 102, 28, DARK, menu, 21)
        followBtn.TextSize = 12

        -- Discord webhook: URL box (shows "Webhook saved" once set, the URL itself is not displayed) + ON/OFF
        local hookBox = Instance.new("TextBox")
        hookBox.Size = UDim2.fromOffset(164, 28)
        hookBox.Position = UDim2.fromOffset(8, 420)
        hookBox.BackgroundColor3 = DARK
        hookBox.BorderSizePixel = 0
        hookBox.Font = FONT
        hookBox.TextSize = 12
        hookBox.TextColor3 = Color3.new(1, 1, 1)
        hookBox.PlaceholderText = "Discord webhook URL"
        hookBox.PlaceholderColor3 = Color3.fromRGB(150, 155, 175)
        hookBox.ClearTextOnFocus = true
        hookBox.TextTruncate = Enum.TextTruncate.AtEnd
        hookBox.Text = Settings.hook.url ~= "" and "Webhook saved" or ""
        hookBox.ZIndex = 21
        hookBox.Parent = menu
        Instance.new("UICorner", hookBox).CornerRadius = UDim.new(0, 8)
        addStroke(hookBox, BORDER, 1, 0.3)
        local hookBtn = button("Hook: OFF", 176, 420, 102, 28, DARK, menu, 21)
        hookBtn.TextSize = 12

        local totalsBtn = button("Post total rewards", 8, 452, 164, 28, BLUE, menu, 21)
        totalsBtn.TextSize = 12
        local resetTotalsBtn = button("Reset totals", 176, 452, 102, 28, DARK, menu, 21)
        resetTotalsBtn.TextSize = 12
        totalsBtn.Activated:Connect(function()
            if not Hook.valid(Settings.hook.url) then status.Text = "Paste a Discord webhook URL first"; return end
            status.Text = "Posting session + all-time totals..."
            task.spawn(function()
                local okT = Hook.sendTotals()
                status.Text = okT and "Totals posted" or "Could not post totals"
            end)
        end)
        local resetArmed = 0
        resetTotalsBtn.Activated:Connect(function()
            if os.clock() - resetArmed < 4 then
                resetArmed = 0
                Hook.resetTotals()
                resetTotalsBtn.Text = "Reset totals"
                status.Text = "Totals reset"
            else
                resetArmed = os.clock()
                resetTotalsBtn.Text = "Tap again"
                status.Text = "Tap Reset again to clear all totals"
                task.delay(4, function() if resetArmed ~= 0 then resetTotalsBtn.Text = "Reset totals" end end)
            end
        end)

        local function setHookUI()
            hookBtn.Text = Settings.hook.on and "Hook: ON" or "Hook: OFF"
            hookBtn.BackgroundColor3 = Settings.hook.on and GREEN or DARK
        end
        setHookUI()

        hookBox.FocusLost:Connect(function()
            local txt = hookBox.Text:match("^%s*(.-)%s*$")
            if txt == "clear" then
                Settings.hook.url, Settings.hook.on = "", false
                setHookUI()
                Settings.save()
                status.Text = "Webhook removed"
            elseif Hook.valid(txt) then
                Settings.hook.url = txt
                Settings.save()
                status.Text = "Webhook saved"
            elseif txt ~= "" and txt ~= "Webhook saved" then
                status.Text = "Invalid webhook URL (type clear to remove it)"
            end
            hookBox.Text = Settings.hook.url ~= "" and "Webhook saved" or ""
        end)

        hookBtn.Activated:Connect(function()
            if not Settings.hook.on and not Hook.valid(Settings.hook.url) then
                status.Text = "Paste a Discord webhook URL first"
                return
            end
            Settings.hook.on = not Settings.hook.on
            setHookUI()
            Settings.save()
            if Settings.hook.on then
                status.Text = "Webhook ON (test message sent)"
                task.spawn(function() pcall(Hook.send, {test = true}) end)
            else
                status.Text = "Webhook OFF"
            end
        end)

        selectAllBtn.Activated:Connect(function()
            if busy then return end
            local allSelected = true
            for _, choice in ipairs(choices) do
                if not selectedPortals[choice] then allSelected = false; break end
            end
            for _, choice in ipairs(choices) do
                selectedPortals[choice] = not allSelected or nil
                refreshChoice(choice)
            end
        end)

        local autoCreate, followOn = false, false
        local runToken = 0 -- only the newest Auto Create loop may run (no double loops)

        local function setCreateUI(on)
            useSelectedBtn.Text = on and "Auto Create: ON" or "Auto Create: OFF"
            useSelectedBtn.BackgroundColor3 = on and GREEN or DARK
        end
        local function setFollowUI(on)
            followBtn.Text = on and "Follow: ON" or "Follow: OFF"
            followBtn.BackgroundColor3 = on and GREEN or DARK
        end
        -- moves the webhook section and the status line below the wait list (h = height of the wait box + its names)
        local function layoutBelow(h)
            local y0 = 328 + h + 4
            divHook.Position = UDim2.fromOffset(10, y0)
            secHook.Position = UDim2.fromOffset(10, y0 + 8)
            hookBox.Position = UDim2.fromOffset(8, y0 + 28)
            hookBtn.Position = UDim2.fromOffset(176, y0 + 28)
            totalsBtn.Position = UDim2.fromOffset(8, y0 + 60)
            resetTotalsBtn.Position = UDim2.fromOffset(176, y0 + 60)
            divStatus.Position = UDim2.fromOffset(10, y0 + 98)
            status.Position = UDim2.fromOffset(10, y0 + 106)
            menu.Size = UDim2.fromOffset(286, y0 + 106 + 40)
        end
        local waitList = nameList(menu, 8, 328, 270, function() return Settings.host.names end,
            function(v) Settings.host.names = v; Settings.save() end, "Wait for: type a name, press Enter",
            function(h) layoutBelow(h) end)
        local function setHostUI()
            hostBtn.Text = Settings.host.on and "Wait: ON" or "Wait: OFF"
            hostBtn.BackgroundColor3 = Settings.host.on and GREEN or DARK
        end
        setHostUI()
        local function refreshPick()
            local n = Settings.follow.name
            pickBtn.Text = n ~= "" and ("Player: " .. n) or "Player: none"
        end
        refreshPick()

        -- ---------- which selected portals are in the inventory right now? ----------
        -- If the item grid already holds its items while closed, it is read silently; otherwise the inventory is opened
        -- for a moment (once for all the selected portals) and closed again.
        local function stockedChoices(ignoredUntil)
            local out = {}
            local inv = getInventory()
            local frame = inv and inv:FindFirstChild("ItemFrame")
            local grid = frame and frame:FindFirstChild("ItemGrid")
            local silent = grid ~= nil and #grid:GetChildren() > 0
            if not silent then
                openInventory()
                local t0 = os.clock()
                repeat
                    task.wait(0.15)
                until inventoryIsOpen(getInventory()) or os.clock() - t0 > 1.5
                task.wait(0.3)
            end
            for _, c in ipairs(choices) do
                if selectedPortals[c] and os.clock() >= (ignoredUntil[c] or 0) then
                    local inv2 = getInventory()
                    local g2 = inv2 and inv2:FindFirstChild("ItemFrame") and inv2.ItemFrame:FindFirstChild("ItemGrid")
                    local name = resolvePortalName(g2, c)
                    local found
                    if silent then
                        local node = grid and grid:FindFirstChild(name)
                        found = node and (not node:IsA("GuiObject") or node.Visible)
                    else
                        found = findPortalItem(getInventory(), name)
                    end
                    if found then out[#out + 1] = c end
                end
            end
            if not silent then closeInventory() end
            -- priority: every Nightmare portal first, the Normal ones after them (each group keeps the list's order)
            local nm, normal = {}, {}
            for _, c in ipairs(out) do
                if c.difficulty == "Nightmare" then nm[#nm + 1] = c else normal[#normal + 1] = c end
            end
            for _, c in ipairs(normal) do nm[#nm + 1] = c end
            return nm
        end

        -- ---------- Auto Create loop ----------
        -- Priority: Auto Create works on the portals that are in the inventory. When there are none, Auto Boss
        -- gets the turn (Portal.ready = false); the inventory is looked at every STOCK_RECHECK seconds, and as soon
        -- as a portal is there again the next boss fight is held back and the portals go first.
        local function startCreate()
            runToken += 1
            local token = runToken
            local function ok() return autoCreate and runToken == token and gui.Parent ~= nil end

            task.spawn(function()
                busy = true
                local fails, stopReason = 0, nil
                local lastPeek, stocked, ignoredUntil, handed = -1e9, {}, {}, false
                local okRun, err = pcall(function()
                    while ok() do
                        -- look into the inventory (also while a boss fight runs: a portal found then waits for that fight to end)
                        if os.clock() - lastPeek >= PCFG.STOCK_RECHECK and not Raid.running and not Dungeon.active then
                            lastPeek = os.clock()
                            stocked = stockedChoices(ignoredUntil)
                            Portal.ready = #stocked > 0
                        end
                        if not ok() then break end
                        if othersBusy() then
                            status.Text = Portal.ready and ("Portal found, waiting: " .. busyReason())
                                or "Paused (another automation is running)"
                            task.wait(1)
                        elseif #stocked == 0 then
                            status.Text = "No portal in the inventory (Auto Boss goes on)"
                            Portal.ready = false
                            if not handed then
                                handed = true
                                releaseBoss("no portal in the inventory")
                                if Boss.resume then Boss.resume() end -- the boss queue takes over
                            end
                            task.wait(1)
                        else
                            handed = false
                            Portal.active = true
                            holdBoss()
                            for _, choice in ipairs(stocked) do
                                if not ok() or othersBusy() then break end

                                -- still inside the previous portal? give it time to end
                                local waited = 0
                                while ok() and waited < PCFG.INSIDE_WAIT and portalState().inside do
                                    status.Text = ("Waiting for the previous portal to end... %ds"):format(waited)
                                    task.wait(1)
                                    waited += 1
                                end
                                if not ok() then break end

                                local success, reason = createPortal(choice, ok)
                                if success then
                                    fails = 0
                                    -- one portal per round: the inventory is read again, so a Nightmare portal that is still in stock
                                    -- always goes before the Normal ones (the old loop went on down the list after the first one)
                                    break
                                elseif reason == "stopped" then
                                    break
                                elseif reason == "stock" then
                                    ignoredUntil[choice] = os.clock() + PCFG.STOCK_IGNORE
                                    status.Text = choice.label .. " not found in the inventory"
                                    task.wait(1)
                                else
                                    fails += 1
                                    status.Text = ("Portal step failed: %s (%d/%d)"):format(tostring(reason), fails, PCFG.MAX_FAILS)
                                    if fails >= PCFG.MAX_FAILS then
                                        local why = tostring(reason)
                                        for left = PCFG.FAIL_COOLDOWN, 1, -1 do
                                            if not ok() then break end
                                            status.Text = ("%d failures (last: %s), trying again in %d:%02d"):format(fails, why, left // 60, left % 60)
                                            task.wait(1)
                                        end
                                        fails = 0
                                        break
                                    end
                                    task.wait(PCFG.RETRY_DELAY)
                                end
                            end
                            Portal.active = false
                            stocked, lastPeek = {}, -1e9 -- look at the inventory again right away
                            task.wait(PCFG.LOOP_PAUSE)
                        end
                    end
                end)
                if not okRun then
                    stopReason = "Error: " .. tostring(err):sub(1, 80)
                    warn("[PibbleHub] portal Auto Create error:", err)
                end
                Portal.active, Portal.ready = false, false
                if runToken == token then
                    autoCreate = false
                    setCreateUI(false)
                    closeInventory()
                    busy = false
                    status.Text = stopReason or "Auto Create stopped"
                    releaseBoss("Auto Create stopped")
                    if Boss.resume then Boss.resume() end
                end
            end)
        end

        useSelectedBtn.Activated:Connect(function()
            if autoCreate then
                autoCreate = false
                setCreateUI(false)
                status.Text = "Stopping Auto Create..."
                return
            end
            if not next(selectedPortals) then
                status.Text = "Check a portal first"
                return
            end
            if followOn then -- nor with Follow Join
                followOn = false
                Settings.follow.on = false
                setFollowUI(false)
                Settings.save()
            end
            local waited = 0
            while busy and waited < 10 do
                status.Text = "Waiting for the previous action to stop..."
                task.wait(0.5)
                waited += 0.5
            end
            if busy then
                status.Text = "Still busy, try again in a moment"
                return
            end
            autoCreate = true
            setCreateUI(true)
            startCreate()
        end)

        -- ---------- Follow Join loop ----------
        local attempted = setmetatable({}, {__mode = "k"})
        local failCount = setmetatable({}, {__mode = "k"}) -- Follow Join: failed rounds per gate

        local function pickGate(ignoreAttempted)
            local gates = workspace:FindFirstChild("PortalModeGates")
            local root = getHRP()
            if not gates or not root then return nil end
            local bestGate, bestPart, bestD = nil, nil, math.huge
            for _, gate in ipairs(gates:GetChildren()) do
                if ignoreAttempted or not attempted[gate] or os.clock() >= attempted[gate] then
                    local part = gate:IsA("BasePart") and gate
                        or (gate:IsA("Model") and gate.PrimaryPart)
                        or gate:FindFirstChildWhichIsA("BasePart", true)
                    if part then
                        local d = (part.Position - root.Position).Magnitude
                        if d < bestD then bestGate, bestPart, bestD = gate, part, d end
                    end
                end
            end
            return bestGate, bestPart, bestD
        end

        -- ---------- Follow Join: the gates that belong to the followed player ----------
        local function textHasName(t, p)
            t = tostring(t):lower()
            if #t < 3 then return false end
            local n, d = p.Name:lower(), p.DisplayName:lower()
            return t == n or t == d or t:find(n, 1, true) ~= nil or (#d >= 3 and t:find(d, 1, true) ~= nil)
        end

        -- "yes": the gate says it belongs to target; "no": it names another player; nil: no owner information at all
        local function gateOwner(gate, target)
            local claimsTarget, claimsOther = false, false
            local function check(v)
                if type(v) == "number" then
                    if v == target.UserId then
                        claimsTarget = true
                    elseif v > 1000 then
                        for _, p in ipairs(Players:GetPlayers()) do
                            if p.UserId == v then claimsOther = true end
                        end
                    end
                elseif type(v) == "string" then
                    if v == "" then return end
                    if textHasName(v, target) then
                        claimsTarget = true
                    else
                        local l = v:lower()
                        for _, p in ipairs(Players:GetPlayers()) do
                            if p ~= target and (l == p.Name:lower() or l == p.DisplayName:lower()) then claimsOther = true end
                        end
                    end
                elseif typeof(v) == "Instance" then
                    local pl = v:IsA("Player") and v or (v:IsA("Model") and Players:GetPlayerFromCharacter(v)) or nil
                    if pl then
                        if pl == target then claimsTarget = true else claimsOther = true end
                    end
                end
            end
            local function scan(inst)
                for _, v in pairs(inst:GetAttributes()) do check(v) end
                if inst:IsA("ValueBase") then pcall(function() check(inst.Value) end) end
                if inst:IsA("TextLabel") then check(clean(inst.Text)) end
            end
            scan(gate)
            local n = 0
            for _, d in ipairs(gate:GetDescendants()) do
                n += 1
                if n > 150 then break end
                scan(d)
            end
            if claimsTarget then return "yes" end
            if claimsOther then return "no" end
            return nil
        end

        local function followTarget()
            local name = Settings.follow.name
            if name == "" then return nil end
            for _, p in ipairs(Players:GetPlayers()) do
                if p.Name == name and p ~= player then return p end
            end
            return nil
        end

        -- same contract as pickGate, but only gates opened by the followed player
        local function followPick(ignoreAttempted)
            local target = followTarget()
            local gates = workspace:FindFirstChild("PortalModeGates")
            local root = getHRP()
            if not target or not gates or not root then return nil end
            local tChar = target.Character
            local tRoot = tChar and tChar:FindFirstChild("HumanoidRootPart")
            for _, gate in ipairs(gates:GetChildren()) do
                if ignoreAttempted or not attempted[gate] or os.clock() >= attempted[gate] then
                    local part = gate:IsA("BasePart") and gate
                        or (gate:IsA("Model") and gate.PrimaryPart)
                        or gate:FindFirstChildWhichIsA("BasePart", true)
                    if part then
                        local owner = gateOwner(gate, target)
                        local mine = owner == "yes"
                            or (owner == nil and tRoot ~= nil and (part.Position - tRoot.Position).Magnitude <= PCFG.FOLLOW_NEAR)
                        if mine then
                            return gate, part, (part.Position - root.Position).Magnitude
                        end
                    end
                end
            end
            return nil
        end

        -- a standing spot ~8 studs from the gate: floor underneath, nothing but the gate between the spot and the gate.
        -- Tries the four sides of the gate; returns a CFrame or nil.
        local function nearGateSpot(part, gate)
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = {player.Character}
            local base = part.Position
            local cf = part.CFrame
            for _, d in ipairs({cf.LookVector, -cf.LookVector, cf.RightVector, -cf.RightVector}) do
                d = Vector3.new(d.X, 0, d.Z)
                if d.Magnitude > 0.1 then
                    local spot = base + d.Unit * 8
                    local hit = workspace:Raycast(spot + Vector3.new(0, 25, 0), Vector3.new(0, -80, 0), params)
                    if hit and math.abs(hit.Position.Y - base.Y) <= 15 then
                        local from = Vector3.new(spot.X, hit.Position.Y + 3, spot.Z)
                        local to = Vector3.new(base.X, hit.Position.Y + 3, base.Z)
                        local block = workspace:Raycast(from, to - from, params)
                        if not block or block.Instance == part or block.Instance:IsDescendantOf(gate) then
                            return CFrame.new(hit.Position + Vector3.new(0, 3, 0))
                        end
                    end
                end
            end
            return nil
        end

        local function joinStep(chooser)
            chooser = chooser or pickGate
            if portalState().inside then return end
            -- forget gates that no longer exist (the tables would grow all night)
            for g in pairs(attempted) do if not g.Parent then attempted[g] = nil end end
            for g in pairs(failCount) do if not g.Parent then failCount[g] = nil end end
            local gate, part, dist = chooser(false)
            if not gate then return end

            busy = true
            Portal.active = true
            holdBoss()
            attempted[gate] = os.clock() + PCFG.JOIN_RETRY -- a failure never retries instantly
            local function joining() return followOn and not autoCreate and gui.Parent ~= nil end

            local reachable = true
            local didJoin = false
            local gateWorld = gate:GetAttribute("WorldId") or gate:GetAttribute("World")
                or part:GetAttribute("WorldId") or part:GetAttribute("World")
            if type(gateWorld) == "string" and gateWorld ~= "" then
                local cur = currentWorld()
                local nearby = not cur and dist <= 25
                if not nearby and not sameWorld(gateWorld, cur) then
                    reachable = enterWorld(worldFor(gateWorld), joining)
                    if reachable then
                        task.wait(followOn and 0.4 or 1.5)
                        gate, part = chooser(true) -- the gates of the new world
                        if gate then attempted[gate] = os.clock() + PCFG.JOIN_RETRY end
                    end
                end
            end

            -- Follow Join: the owner goes in first (he is teleported away from the gate), then we wait a moment
            if reachable and followOn and PCFG.FOLLOW_WAIT_OWNER and gate and part and joining() then
                local target = followTarget()
                local function ownerIn()
                    local ch = target and target.Character
                    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
                    if not hrp then return true end -- cannot see him (other world / loading): do not hold back
                    return (hrp.Position - part.Position).Magnitude >= PCFG.FOLLOW_OWNER_OUT
                end
                if target and not ownerIn() then
                    local t0 = os.clock()
                    while joining() and not ownerIn() and os.clock() - t0 < PCFG.FOLLOW_OWNER_MAX do
                        status.Text = ("Waiting for %s to go in... %ds"):format(target.Name, math.max(0, math.floor(PCFG.FOLLOW_OWNER_MAX - (os.clock() - t0))))
                        task.wait(0.1)
                    end
                end
                if joining() then task.wait(PCFG.FOLLOW_OWNER_DELAY) end
            end

            if reachable and gate and part and joining() and part:IsDescendantOf(workspace) then
                local joinedOk
                if followOn and PCFG.FOLLOW_TELEPORT then
                    -- two ways in, the one that worked for you goes first (FOLLOW_ON_GATE_FIRST):
                    --   A) stand right ON the gate (touching it triggers it)
                    --   B) appear on the ground next to it and walk in
                    local function stillGoing() return joining() and part:IsDescendantOf(workspace) end
                    local function tryOnGate(timeout)
                        local hrp = getHRP()
                        if not hrp then return false end
                        print("[PibbleHub] follow: stepping onto the gate")
                        status.Text = "Stepping onto the gate..."
                        hrp.CFrame = CFrame.new(part.Position + part.CFrame.RightVector * 4 + Vector3.new(0, 3, 0)) -- right beside the gate
                        task.wait(0.15)
                        -- stays beside the gate and jumps (no walking): jumping makes the character touch the gate
                        return joinPortal(part, joining, nil, false, timeout, PCFG.FOLLOW_POLL, true)
                    end
                    local function tryNear(timeout)
                        local hrp = getHRP()
                        local spot = hrp and nearGateSpot(part, gate)
                        if not (hrp and spot) then return false end
                        print("[PibbleHub] follow: teleported next to the gate, walking in")
                        hrp.CFrame = spot
                        task.wait(0.15)
                        return joinPortal(part, joining, 3, false, timeout, PCFG.FOLLOW_POLL)
                    end
                    -- try 1,3.. : teleport right beside the gate and step left/right across it; try 2,4..: appear next to the gate and walk in
                    local first, second = tryOnGate, tryNear
                    -- up to FOLLOW_TRIES tries (the two ways in alternate); a try that has not put the player in the portal after
                    -- FOLLOW_TRY_SECS seconds counts as failed (when everyone follows at once, the room may be taken / the gate not ready)
                    local methods = { first, second }
                    for attempt = 1, (PCFG.FOLLOW_TRIES or 3) do
                        if not stillGoing() then break end
                        joinedOk = methods[(attempt - 1) % 2 + 1](PCFG.FOLLOW_TRY_SECS or 5)
                        if joinedOk then break end
                        print(("[PibbleHub] follow: not in the portal after %ds (try %d/%d)"):format(
                            PCFG.FOLLOW_TRY_SECS or 5, attempt, PCFG.FOLLOW_TRIES or 3))
                        status.Text = ("Not in the portal yet, trying again (%d/%d)"):format(attempt, PCFG.FOLLOW_TRIES or 3)
                    end
                else
                    for attempt = 1, (PCFG.FOLLOW_TRIES or 3) do
                        if not (joining() and part:IsDescendantOf(workspace)) then break end
                        joinedOk = joinPortal(part, joining, 2, false, PCFG.FOLLOW_TRY_SECS or 5)
                        if joinedOk then break end
                    end
                end
                didJoin = joinedOk and true or false
                if joinedOk then
                    if waitForPortalResults(joining, true, followOn and ("Follow " .. Settings.follow.name) or "Follow Join") then
                        -- everybody goes back to the lobby when his portal is over (the owner then sees who has left)
                        local already = false -- always send him to the lobby once the results are closed (a death teleport may not have worked)
                        for try = 1, 3 do
                            if not joining() then break end
                            if enterWorld("Lobby", joining, not already) then break end
                        end
                        -- ... and stays there (no new gate, even if a portal is open) until the host is back in the lobby
                        if followOn then
                            local host = followTarget()
                            local t0 = os.clock()
                            local maxW = PCFG.FOLLOW_HOST_WAIT or 300
                            while joining() and host and host.Parent == Players and os.clock() - t0 < maxW do
                                local hh = host.Character and host.Character:FindFirstChild("HumanoidRootPart")
                                local me = getHRP()
                                local d = (hh and me) and (hh.Position - me.Position).Magnitude or nil
                                if d and d <= (PCFG.PARTY_BACK_RANGE or 300) then break end
                                -- the host may already have left the lobby again to open his next portal (a short window that polling can
                                -- miss): his new gate is on the map = he is back, go on at once
                                local okP, g2 = pcall(followPick, false)
                                if okP and g2 then break end
                                status.Text = ("In the lobby, waiting for %s to come back (%ds)"):format(host.Name, math.floor(os.clock() - t0))
                                task.wait(1)
                            end
                            task.wait(1)
                        end
                    end
                end
            end
            if gate then
                if didJoin or not followOn then
                    attempted[gate] = os.clock() + PCFG.JOIN_RETRY
                else
                    -- a failed round must not blind the follower for 45 s (the portal would be gone by then): the same gate is looked at again
                    -- after 3 s, FOLLOW_REPICKS rounds in a row; only then it is left alone for JOIN_RETRY seconds
                    failCount[gate] = (failCount[gate] or 0) + 1
                    local again = failCount[gate] <= (PCFG.FOLLOW_REPICKS or 3)
                    attempted[gate] = os.clock() + (again and 3 or PCFG.JOIN_RETRY)
                    print(("[PibbleHub] follow: round %d failed, %s"):format(failCount[gate], again and "looking at the gate again in 3 s" or "leaving this gate alone for a while"))
                end
            end
            Portal.active = false
            busy = false
        end

        -- Follow Join controls
        local function setFollow(on)
            if on then
                if Settings.follow.name == "" then
                    status.Text = "Pick a player first"
                    return
                end
                if autoCreate then
                    autoCreate = false
                    setCreateUI(false)
                end
            end
            followOn = on
            Settings.follow.on = on
            if not on and not autoCreate then releaseBoss("Follow stopped") end
            setFollowUI(on)
            Settings.save()
            status.Text = on and ("Following " .. Settings.follow.name) or "Follow stopped"
        end
        Portal.setFollow = setFollow
        -- used by the Guard: what is on, and turning it back on
        Portal.getAuto = function() return autoCreate, followOn end
        Portal.resumeAuto = function(create, follow)
            if create and not autoCreate and not followOn then
                pcall(function()
                    for _, c in ipairs(getconnections(useSelectedBtn.Activated)) do c:Fire() end
                end)
            elseif follow and not followOn and not autoCreate then
                setFollow(true)
            end
        end
        -- used by the Guard: Auto Create and Follow Join off
        Portal.stopAuto = function()
            if autoCreate then
                autoCreate = false
                setCreateUI(false)
                status.Text = "Stopped (Guard)"
            end
            if followOn then setFollow(false) end
        end

        followBtn.Activated:Connect(function() setFollow(not followOn) end)

        -- Host wait: Auto Create holds the Start button until the picked player is in the waiting room
        hostBtn.Activated:Connect(function()
            if not Settings.host.on and Settings.follow.name == "" and (Settings.host.names or "") == "" then
                status.Text = "Type names in the Wait box or pick a player"
                return
            end
            Settings.host.on = not Settings.host.on
            setHostUI()
            Settings.save()
            status.Text = Settings.host.on and "Start waits for the listed players" or "Start no longer waits"
        end)

        -- every click picks the next player of the server (after the last one: none)
        pickBtn.Activated:Connect(function()
            local list = {}
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= player then list[#list + 1] = p end
            end
            table.sort(list, function(x, y) return x.Name:lower() < y.Name:lower() end)
            local idx = 0
            for i, p in ipairs(list) do
                if p.Name == Settings.follow.name then idx = i end
            end
            idx += 1
            Settings.follow.name = list[idx] and list[idx].Name or ""
            if Settings.follow.name == "" and followOn then setFollow(false) end
            refreshPick()
            Settings.save()
            if #list == 0 then
                status.Text = "No other player in the server"
            elseif list[idx] then
                local p = list[idx]
                status.Text = (p.DisplayName ~= p.Name) and ("%s (@%s)"):format(p.DisplayName, p.Name) or p.Name
            else
                status.Text = "No player picked"
            end
        end)

        Portal.isOn = function() return (autoCreate or followOn) and true or false end -- used by the priority tab

        task.spawn(function()
            local handed = false
            -- a new gate wakes the loop at once instead of waiting for the next scan tick
            local wake = false
            task.spawn(function()
                local folder = workspace:WaitForChild("PortalModeGates", 60)
                if folder and gui.Parent then connect(folder.ChildAdded, function() wake = true end) end
            end)
            while gui.Parent do
                Portal.fast = (followOn and not autoCreate) or false
                if followOn then
                    local waited = 0
                    while waited < PCFG.FOLLOW_SCAN and not wake and gui.Parent do task.wait(0.03); waited += 0.03 end
                    if wake then task.wait(0.06) end -- the owner info of the gate is set a moment after it appears
                    wake = false
                else
                    task.wait(1)
                end
                if followOn and not autoCreate then
                    if not busy then
                        -- a gate that can be joined = a portal is available: it goes before the boss queue
                        -- (Follow Join: only a gate opened by the followed player counts)
                        local chooser = followOn and followPick or pickGate
                        local okG, gate = pcall(chooser, false)
                        Portal.ready = okG and gate ~= nil
                        if followOn and not Portal.ready and not othersBusy() then
                            status.Text = followTarget() and ("Following %s: waiting for a portal"):format(Settings.follow.name)
                                or ("%s is not in the server"):format(Settings.follow.name)
                        end
                        if not othersBusy() then
                            if Portal.ready then
                                handed = false
                                local okRun, err = pcall(joinStep, chooser)
                                if not okRun then
                                    busy = false
                                    Portal.active = false
                                    status.Text = "Join error (see F9)"
                                    warn("[PibbleHub] portal join error:", err)
                                end
                            elseif not handed then
                                handed = true
                                releaseBoss("no gate to join")
                                if Boss.resume then Boss.resume() end -- no gate: the boss queue takes over
                            end
                        end
                    end
                elseif not autoCreate and not busy then
                    Portal.ready = false -- all switches OFF: portals never hold the bosses back
                end
            end
        end)

        openBtn.Activated:Connect(function() menu.Visible = not menu.Visible end)
    end)


    -- =====================================================================
    -- == 8. FEATURE: AUTO MINE
    -- =====================================================================
    safeFeature("Auto Mine", function()
        featureTab("Auto Mine", 30)
        label("Mine Rocks", 30, ORANGE)
        local titaniumIds = {6, 83, 2, 68, 5, 73, 74, 3, 8, 54, 1, 45}
        local skyCrystalIds = {4, 61, 56, 72, 85, 87, 86, 47, 42, 66, 44, 78, 48}
        local titanium = false
        local skyCrystal = false
        local running = false
        local pending = false
        local titaniumBtn = button("☐ Titanium", 10, 54, 110, 26, DARK)
        local skyBtn = button("☐ Sky Crystal", 126, 54, 114, 26, DARK)
        local startBtn = button("Start Auto Mine", 10, 84, 230, 26, BLUE)
        local statusL = label("", 114, nil, 13)

        titaniumBtn.Activated:Connect(function()
            if running or pending then return end
            titanium = not titanium
            titaniumBtn.Text = titanium and "☑ Titanium" or "☐ Titanium"
        end)

        skyBtn.Activated:Connect(function()
            if running or pending then return end
            skyCrystal = not skyCrystal
            skyBtn.Text = skyCrystal and "☑ Sky Crystal" or "☐ Sky Crystal"
        end)

        local cavernEntry = CFrame.new(6820, 249.999939, -54000, 1, 0, 0, 0, 1, 0, 0, 0, 1)

        local function enterCavern(enableMine)
            local root = getHRP()
            if not root then return false, "Character unavailable" end
            local origin = root.Position
            local function shouldContinue() return running and gui.Parent ~= nil end

            statusL.Text = "Teleporting to Sky Quarry..."
            if not teleportToIsland("Sky Quarry", shouldContinue) then
                return false, "Open Islands and retry"
            end

            local deadline = os.clock() + 12
            repeat
                task.wait(0.15)
                if not shouldContinue() then return false end
                root = getHRP()
            until (root and (root.Position - origin).Magnitude >= 25) or os.clock() >= deadline
            if not root or (root.Position - origin).Magnitude < 25 then
                return false, "Sky Quarry arrival timed out"
            end

            task.wait(5)
            if not shouldContinue() then return false end
            root = getHRP()
            if not root then return false, "Character unavailable" end

            statusL.Text = "Teleporting to Crystal Cavern..."
            root.CFrame = cavernEntry
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            statusL.Text = "Entering Crystal Cavern..."
            deadline = os.clock() + 8
            local entryPrompt
            repeat
                if not shouldContinue() then return false end
                for _, instance in ipairs(workspace:GetDescendants()) do
                    if instance:IsA("ProximityPrompt") and instance.Enabled
                        and clean(instance.ObjectText):lower() == "crystal cavern"
                        and clean(instance.ActionText):lower() == "enter" then
                        entryPrompt = instance
                        break
                    end
                end
                if not entryPrompt then task.wait(0.4) end
            until entryPrompt or os.clock() >= deadline
            if not entryPrompt then return false, "Crystal Cavern prompt not found" end

            local activated = pcall(function()
                if typeof(fireproximityprompt) == "function" then
                    fireproximityprompt(entryPrompt)
                else
                    entryPrompt:InputHoldBegin()
                    task.wait(entryPrompt.HoldDuration)
                    entryPrompt:InputHoldEnd()
                end
            end)
            if not activated then return false, "Crystal Cavern prompt failed" end

            task.wait(1)
            if not enableMine then return shouldContinue() end
            deadline = os.clock() + 5
            repeat
                if not shouldContinue() then return false end
                local playerGui = player:FindFirstChildOfClass("PlayerGui")
                local miningGui = playerGui and playerGui:FindFirstChild("MiningGui", true)
                local autoButton = miningGui and miningGui:FindFirstChild("MineAuto", true)
                if autoButton and autoButton:IsA("GuiButton") and shown(autoButton) then
                    if activateButton(autoButton) then return true end
                    return false, "Could not click Mine Auto"
                end
                task.wait(0.2)
            until os.clock() >= deadline
            return false, "Mine Auto button not visible"
        end


        startBtn.Activated:Connect(function()
            if running then
                running = false
                startBtn.Text = "Stopping..."
                return
            end
            if pending then return end
            if not titanium and not skyCrystal then
                statusL.Text = "Select at least one ore"
                return
            end

            running, pending = true, true
            startBtn.Text = "Stop Auto Mine"

            local entered, message = enterCavern(true)
            if not entered then
                statusL.Text = running and (message or "Cavern entry failed") or "Auto Mine stopped"
                running, pending = false, false
                startBtn.Text = "Start Auto Mine"
                return
            end

            local vein
            local arrival
            local waitForOre
            local veinId
            local lastVeinId
            local wasPaused = false

            while running and gui.Parent do
                if Raid.running or Boss.active or Dungeon.active or WorldBoss.active then
                    statusL.Text = "Auto Mine paused during battle"
                    vein = nil
                    wasPaused = true
                elseif wasPaused then
                    statusL.Text = "Restarting mine teleport route..."
                    local reentered, retryMessage = enterCavern(false)
                    if reentered then
                        wasPaused = false
                        lastVeinId = nil
                    else
                        statusL.Text = retryMessage or "Retrying mine teleport route"
                        task.wait(1)
                    end
                elseif vein and os.clock() - arrival < waitForOre then
                    statusL.Text = "Mining vein " .. veinId
                else
                    vein = nil
                    local maps = workspace:FindFirstChild("Maps")
                    local cavern = maps and maps:FindFirstChild("CrystalCavern")
                    local nodes = cavern and cavern:FindFirstChild("MiningNodes")
                    local root = getHRP()
                    local humanoid = root and root.Parent:FindFirstChildOfClass("Humanoid")
                    if nodes and humanoid and humanoid.Health > 0 and not humanoid.SeatPart then
                        local bestRank = math.huge
                        local landing
                        for _, node in ipairs(nodes:GetChildren()) do
                            local id = node:GetAttribute("VeinId")
                            local ore = node:GetAttribute("Ore")
                            local isSky = skyCrystal and table.find(skyCrystalIds, id) and ore == "ore_sky_crystal"
                            local isTitanium = titanium and table.find(titaniumIds, id)
                                and (node.Name:lower() == "titanium" or ore == "ore_titanium")
                            if (isSky or isTitanium) and node:IsA("Model") and node:FindFirstChildWhichIsA("BasePart", true) then
                                local cf, size = node:GetBoundingBox()
                                local distance = (cf.Position - root.Position).Magnitude
                                -- After the first teleport, visit IDs in ascending order and wrap.
                                local rank = lastVeinId and (id - lastVeinId - 1) % 100 or distance
                                if rank < bestRank then
                                    bestRank = rank
                                    vein, veinId = node, id
                                    waitForOre = isSky and 3.8 or 2.7
                                    local top = (math.abs(cf.RightVector.Y) * size.X
                                        + math.abs(cf.UpVector.Y) * size.Y
                                        + math.abs(cf.LookVector.Y) * size.Z) / 2
                                    local clearance = humanoid.HipHeight + root.Size.Y / 2 + 0.25
                                    landing = cf.Position + Vector3.new(0, top + math.max(clearance, 3), 0)
                                end
                            end
                        end
                        if landing then
                            root.CFrame = root.CFrame + (landing - root.Position)
                            root.AssemblyLinearVelocity = Vector3.zero
                            root.AssemblyAngularVelocity = Vector3.zero
                            arrival = os.clock()
                            lastVeinId = veinId
                            statusL.Text = "At vein " .. veinId
                        else
                            statusL.Text = "Waiting for selected ore"
                        end
                    else
                        statusL.Text = "Waiting for the cavern and character"
                    end
                end
                task.wait(0.25)
            end

            if not running then statusL.Text = "Auto Mine stopped" end
            running, pending = false, false
            startBtn.Text = "Start Auto Mine"
        end)
    end)


    -- =====================================================================
    -- == 10. FEATURE: AUTO BOSS
    -- =====================================================================
    safeFeature("Auto Boss", function()
        featureTab("Auto Boss", 298)
        label("Auto Boss", 298, ORANGE)
        local statusL = label("Boss: idle", 318)
        local pickBtn = button("Boss: -", 10, 342, 230, 28, DARK)
        local diffBtn = button("Difficulty: Normal", 10, 376, 230, 28, DARK)
        local startBtn = button("Start", 10, 410, 105, 28, BLUE)
        local autoBtn = button("Auto: OFF", 125, 410, 115, 28, RED)

        -- ---- boss menu (multi-select, stays open) ----
        local bossMenu = sidePanel("ScrollingFrame", 270, 380)
        bossMenu.ScrollBarThickness = 6

        local bossBtns, bossLabels, y = {}, {}, 6

        local function refreshBossPick()
            local n, last = 0, nil
            for id, btn in pairs(bossBtns) do
                local on = Boss.selected[id] == true
                if on then n += 1; last = id end
                btn.BackgroundColor3 = on and GREEN or DARK
                btn.Text = (on and "[x] " or "[  ] ") .. bossLabels[id]
            end
            if n == 0 then
                pickBtn.Text = "Boss: none selected"
            elseif n == 1 then
                pickBtn.Text = "Boss: " .. niceName(last)
            else
                pickBtn.Text = ("Boss: %d selected"):format(n)
            end
        end

        for _, w in ipairs(BOSS_WORLDS) do
            local h = Instance.new("TextLabel")
            h.Size = UDim2.fromOffset(250, 22)
            h.Position = UDim2.fromOffset(10, y)
            h.BackgroundTransparency = 1
            h.Font = FONT
            h.TextSize = 16
            h.TextColor3 = ORANGE
            h.TextXAlignment = Enum.TextXAlignment.Left
            h.Text = w[1]
            h.ZIndex = 21
            h.Parent = bossMenu
            y += 25
            for i, id in ipairs(w[2]) do
                local txt = ("%s%s   %d/%d   (%s)"):format(niceName(id), i == #w[2] and " [BOSS]" or "",
                    i, #w[2], tostring(FIRST_CLEAR[id] or "?"))
                local btn = button(txt, 8, y, 254, 26, DARK, bossMenu, 21)
                btn.TextSize = 14
                btn.TextXAlignment = Enum.TextXAlignment.Left
                bossBtns[id] = btn
                bossLabels[id] = txt
                btn.MouseButton1Click:Connect(function()
                    if Boss.selected[id] then Boss.selected[id] = nil else Boss.selected[id] = true end
                    refreshBossPick() -- the menu stays open so several bosses can be picked
                    Settings.save()
                end)
                y += 29
            end
        end
        bossMenu.CanvasSize = UDim2.fromOffset(0, y + 6)
        refreshBossPick()

        -- ---- difficulty menu (multi-select) ----
        local diffMenu = sidePanel("Frame", 190, (#DIFFS + 1) * 32 + 4)
        local diffAllBtn = button("All difficulties", 8, 4, 174, 28, DARK, diffMenu, 21)
        local diffBtns = {}
        for i, d in ipairs(DIFFS) do
            diffBtns[d] = button(d, 8, 4 + i * 32, 174, 28, DARK, diffMenu, 21)
        end

        local function refreshDiffPick()
            local n, last = 0, nil
            for _, d in ipairs(DIFFS) do
                local on = Boss.diffs[d] == true
                if on then n += 1; last = d end
                diffBtns[d].BackgroundColor3 = on and GREEN or DARK
                diffBtns[d].Text = (on and "[x] " or "[  ] ") .. niceName(d)
            end
            diffAllBtn.BackgroundColor3 = (n == #DIFFS) and GREEN or DARK
            if n == 0 then
                diffBtn.Text = "Difficulty: Normal"
            elseif n == 1 then
                diffBtn.Text = "Difficulty: " .. niceName(last)
            elseif n == #DIFFS then
                diffBtn.Text = "Difficulty: All (rotating)"
            else
                diffBtn.Text = ("Difficulty: %d selected"):format(n)
            end
        end

        for _, d in ipairs(DIFFS) do
            diffBtns[d].MouseButton1Click:Connect(function()
                if Boss.diffs[d] then Boss.diffs[d] = nil else Boss.diffs[d] = true end
                refreshDiffPick()
                Settings.save()
            end)
        end
        diffAllBtn.MouseButton1Click:Connect(function()
            local all = true
            for _, d in ipairs(DIFFS) do
                if not Boss.diffs[d] then all = false end
            end
            Boss.diffs = {}
            if not all then
                for _, d in ipairs(DIFFS) do Boss.diffs[d] = true end
            end
            refreshDiffPick()
            Settings.save()
        end)
        refreshDiffPick()

        -- only one menu open at a time
        pickBtn.MouseButton1Click:Connect(function()
            bossMenu.Visible = not bossMenu.Visible
            if bossMenu.Visible then diffMenu.Visible = false end
        end)
        diffBtn.MouseButton1Click:Connect(function()
            diffMenu.Visible = not diffMenu.Visible
            if diffMenu.Visible then bossMenu.Visible = false end
        end)

        -- ---- fight queue ----
        -- For each selected boss (progression order), every selected difficulty (none = normal).
        -- peekFight returns the next {boss, difficulty} WITHOUT advancing: the queue only moves on
        -- (advance) when a fight is really over, so a fight that never started doesn't "consume" its slot.
        local function fightList()
            local diffs = {}
            for _, d in ipairs(DIFFS) do
                if Boss.diffs[d] then diffs[#diffs + 1] = d end
            end
            if #diffs == 0 then diffs = {"normal"} end
            local list = {}
            for _, w in ipairs(BOSS_WORLDS) do
                for _, id in ipairs(w[2]) do
                    if Boss.selected[id] then
                        for _, d in ipairs(diffs) do list[#list + 1] = {id, d} end
                    end
                end
            end
            return list
        end

        local function keyOf(f) return f[1] .. "|" .. f[2] end

        local function onCooldown(f)
            local r = Boss.cooldown[keyOf(f)]
            return r ~= nil and r > os.time()
        end

        -- how long a boss stays on cooldown after a win
        local function winCooldown(id)
            return CFG.COOLDOWN_BY_NPC[id] or CFG.WIN_COOLDOWN
        end

        -- next fight to run, skipping the ones that are on a cooldown timer (nil = nothing available now)
        local function peekFight()
            local list = fightList()
            if #list == 0 then return nil end
            -- a lost fight is retried: same boss, same difficulty
            if Boss.current and Boss.retries > 0 then
                for _, f in ipairs(list) do
                    if keyOf(f) == keyOf(Boss.current) and not onCooldown(f) then return f end
                end
            end
            -- otherwise: the first available fight after the last finished one
            -- (still correct if the selection was changed in the meantime)
            local idx = 0
            if Boss.lastDone then
                for i, f in ipairs(list) do
                    if keyOf(f) == Boss.lastDone then idx = i end
                end
            end
            for step = 1, #list do
                local f = list[(idx + step - 1) % #list + 1]
                if not onCooldown(f) then return f end
            end
            return nil
        end

        -- marks the current fight as finished: the queue resumes right after it
        local function advance()
            if Boss.current then Boss.lastDone = keyOf(Boss.current) end
            Boss.retries = 0
        end

        -- ---- NPC lookup & teleport ----
        -- Finds the NPC model in the workspace (by model name or by attribute)
        local npcCache = {} -- id -> model (a full workspace scan is slow, so a found NPC is remembered)
        local function findNPC(id)
            local c = npcCache[id]
            if c and c.Parent and c:IsDescendantOf(workspace) then return c end
            npcCache[id] = nil
            local want, wantNice = id:lower(), niceName(id):lower()
            for _, d in ipairs(workspace:GetDescendants()) do
                if d:IsA("Model") and not Players:GetPlayerFromCharacter(d) then
                    local n = d.Name:lower()
                    local a = d:GetAttribute("NPCId") or d:GetAttribute("NpcId") or d:GetAttribute("npcId")
                        or d:GetAttribute("Id") or d:GetAttribute("id")
                    if n == want or n == wantNice or (a and tostring(a):lower() == want) then
                        npcCache[id] = d
                        return d
                    end
                end
            end
        end

        -- Teleports in front of the NPC (retries for ~5 s in case it is streamed in)
        local function tpToNPC(id)
            for _ = 1, 50 do
                local hrp = getHRP()
                local m = findNPC(id)
                if hrp and m then
                    local okP, pivot = pcall(function() return m:GetPivot() end)
                    if okP then
                        -- already standing next to the NPC: stay where we are (the talk prompt is pressed from here), no re-teleport
                        if (hrp.Position - pivot.Position).Magnitude <= (CFG.BOSS_STAY_RANGE or 14) then return true end
                        hrp.CFrame = CFrame.new(pivot.Position + pivot.LookVector * 5 + Vector3.new(0, 2, 0))
                        return true
                    end
                end
                task.wait(0.1)
            end
            print("[PibbleHub] NPC not found in workspace:", id)
            return false
        end

        -- ---- cooldown timers ----
        -- A boss that was cleared recently shows a timer. It is looked for in two places:
        --   1) on the NPC itself (billboard / surface text), right after teleporting to it
        --   2) in a popup, a few seconds after StartNPCBattle was fired
        local UNITS = {
            h = 3600, hr = 3600, hrs = 3600, hour = 3600, hours = 3600,
            m = 60, min = 60, mins = 60, minute = 60, minutes = 60,
            s = 1, sec = 1, secs = 1, second = 1, seconds = 1,
        }
        local TIMER_WORDS = {"cooldown", "cool down", "available in", "ready in", "try again", "come back", "again in"}

        local function hasWord(t)
            for _, w in ipairs(TIMER_WORDS) do
                if t:find(w, 1, true) then return true end
            end
            return false
        end

        -- "4:32", "1:02:10", "5m 30s", "2 hours" ... -> seconds (nil when the text holds no time)
        local function parseTime(text)
            local h, m, s = text:match("(%d+):(%d+):(%d+)")
            if h then return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) end
            m, s = text:match("(%d+):(%d+)")
            if m then return tonumber(m) * 60 + tonumber(s) end
            local total, found = 0, false
            for n, u in text:gmatch("(%d+)%s*(%a+)") do
                local mult = UNITS[u]
                if mult then
                    total += tonumber(n) * mult
                    found = true
                end
            end
            return found and total or nil
        end

        local function isText(o) return o:IsA("TextLabel") or o:IsA("TextButton") end

        -- timer written on the NPC (any visible text under the model that reads as a time)
        local function npcTimer(model)
            if not model then return nil end
            for _, d in ipairs(model:GetDescendants()) do
                if isText(d) and shown(d) then
                    local t = clean(d.Text):lower()
                    if t ~= "" then
                        local secs = parseTime(t) or (hasWord(t) and tonumber(t:match("(%d+)")))
                        if secs and secs > 0 then return secs end
                    end
                end
            end
            return nil
        end

        -- timer in a popup: a visible text with a "cooldown"-like word and a time
        -- (the time may be in a sibling label: "Cooldown:" + "4:32")
        local function popupTimer()
            local pg = player:FindFirstChild("PlayerGui")
            if not pg then return nil end
            for _, d in ipairs(pg:GetDescendants()) do
                if isText(d) and not d:IsDescendantOf(gui) and shown(d) then
                    local t = clean(d.Text):lower()
                    if t ~= "" and hasWord(t) then
                        local secs = parseTime(t) or tonumber(t:match("(%d+)"))
                        if not secs and d.Parent then
                            for _, sib in ipairs(d.Parent:GetChildren()) do
                                if sib ~= d and isText(sib) then
                                    secs = parseTime(clean(sib.Text):lower())
                                    if secs then break end
                                end
                            end
                        end
                        if secs and secs > 0 then return secs end
                    end
                end
            end
            return nil
        end

        -- debug: prints every visible text found on the NPC, to see what the game shows there
        local function dumpTexts(id)
            if not CFG.DEBUG_TIMER then return end
            local m = findNPC(id)
            if not m then return end
            local out = {}
            for _, d in ipairs(m:GetDescendants()) do
                if isText(d) and shown(d) then
                    local t = clean(d.Text)
                    if t ~= "" then out[#out + 1] = d.Name .. "=" .. t end
                end
            end
            print("[PibbleHub] texts on " .. id .. ": " .. (#out > 0 and table.concat(out, " | ") or "(none)"))
        end

        -- ---- what the server answers to StartNPCBattle ----
        -- Every RemoteEvent the server fires at us is recorded. A refused fight (cooldown) comes back as a
        -- text with the time, or as nothing at all; an accepted fight triggers battle events.
        local Notice = { list = {} } -- {t = os.clock(), name = remote name, text = lowercase text}

        local function collectTexts(v, out, depth)
            if type(v) == "string" then
                out[#out + 1] = v
            elseif type(v) == "table" and depth < 3 then
                for _, x in pairs(v) do collectTexts(x, out, depth + 1) end
            end
        end

        for _, r in ipairs(R:GetDescendants()) do
            if r:IsA("RemoteEvent") and not CFG.IGNORE_REMOTES[r.Name] then
                connect(r.OnClientEvent, function(...)
                    if not gui.Parent or tooChatty(r) then return end
                    local args, texts = table.pack(...), {}
                    for i = 1, args.n do collectTexts(args[i], texts, 0) end
                    local text = clean(table.concat(texts, " ")):lower()
                    local list = Notice.list
                    list[#list + 1] = { t = os.clock(), name = r.Name, text = text }
                    if #list > 60 then table.remove(list, 1) end
                    if CFG.DEBUG_TIMER and Boss.started and os.clock() - Boss.startedAt < 15 then
                        print("[PibbleHub] server event after StartNPCBattle:", r.Name, text)
                    end
                end)
            end
        end

        -- how many server events arrived since `since`
        local function noticeCount(since)
            local n = 0
            for _, e in ipairs(Notice.list) do
                if e.t >= since then n += 1 end
            end
            return n
        end

        -- a server message about a cooldown, with its time (seconds)
        local function noticeTimer(since)
            for _, e in ipairs(Notice.list) do
                if e.t >= since and e.text ~= ""
                    and (hasWord(e.text) or e.text:find("wait", 1, true) or e.text:find("cool", 1, true)) then
                    local secs = parseTime(e.text)
                    if secs and secs > 0 then return secs end
                end
            end
            return nil
        end

        -- debug: visible texts of the interface that read as a time (to locate where the game shows timers)
        local function dumpGuiTimers()
            if not CFG.DEBUG_TIMER then return end
            local pg = player:FindFirstChild("PlayerGui")
            if not pg then return end
            local out = {}
            for _, d in ipairs(pg:GetDescendants()) do
                if #out >= 12 then break end
                if isText(d) and not d:IsDescendantOf(gui) and shown(d) then
                    local t = clean(d.Text)
                    if t ~= "" and parseTime(t:lower()) then out[#out + 1] = d.Name .. "=" .. t end
                end
            end
            print("[PibbleHub] visible timers in the interface: " .. (#out > 0 and table.concat(out, " | ") or "(none)"))
        end

        -- Was the fight refused? Looks at server messages, popups and the NPC billboard.
        -- Returns seconds, guessed(bool). A cooldown message without a readable time = UNKNOWN_COOLDOWN.
        local function refusedTimer(id, since)
            local secs = noticeTimer(since) or popupTimer()
            if not secs and CFG.TRUST_NPC_TIMER then secs = npcTimer(findNPC(id)) end
            if secs then return secs, false end
            for _, e in ipairs(Notice.list) do
                if e.t >= since and e.text ~= ""
                    and (hasWord(e.text) or e.text:find("wait", 1, true) or e.text:find("cool", 1, true)) then
                    return CFG.UNKNOWN_COOLDOWN, true
                end
            end
            return nil
        end

        -- ---- per-difficulty timers, read from the NPC dialog ----
        -- Talking to the NPC opens a dialog with one button per difficulty. A difficulty on cooldown shows
        -- its own timer instead of its name ("9m 47s" | Medium | Hard | Extreme | Impossible | ?).
        -- The script "talks" to the NPC, reads the 5 buttons, stores the cooldown of EVERY difficulty, then closes.
        local function promptPos(p)
            local par = p.Parent
            if par and par:IsA("BasePart") then return par.Position end
            if par and par:IsA("Attachment") then return par.WorldPosition end
        end

        -- the "Talk" prompt of the NPC (on its model, otherwise the closest prompt within 25 studs)
        local function findTalkPrompt(id)
            local model = findNPC(id)
            if model then
                for _, d in ipairs(model:GetDescendants()) do
                    if d:IsA("ProximityPrompt") then return d end
                end
            end
            local hrp = getHRP()
            if not hrp then return nil end
            local best, bd = nil, 25
            for _, d in ipairs(workspace:GetDescendants()) do
                if d:IsA("ProximityPrompt") then
                    local pos = promptPos(d)
                    if pos and (pos - hrp.Position).Magnitude < bd then
                        best, bd = d, (pos - hrp.Position).Magnitude
                    end
                end
            end
            return best
        end

        local function firePrompt(prompt)
            if typeof(fireproximityprompt) == "function" then
                return pcall(fireproximityprompt, prompt)
            end
            return pcall(function()
                prompt:InputHoldBegin()
                task.wait((prompt.HoldDuration or 0) + 0.1)
                prompt:InputHoldEnd()
            end)
        end

        -- the 5 difficulty buttons of the open dialog -> {normal = secs, medium = secs, ...} (0 = available)
        local isDiffName = toValidSet(DIFFS)
        local dialogGrp -- container of the 5 difficulty buttons found last time (checked first: no full scan)

        -- the 5 difficulty buttons of one container -> {normal = secs, medium = secs, ...} (0 = available), or nil
        local function readGroup(parent)
            local btns = {}
            for _, b in ipairs(parent:GetChildren()) do
                if b:IsA("TextButton") and shown(b) then btns[#btns + 1] = b end
            end
            if #btns < #DIFFS then return nil end
            table.sort(btns, function(x, y) return x.AbsolutePosition.X < y.AbsolutePosition.X end)
            local res = {}
            for i, d in ipairs(DIFFS) do
                local t = clean(btns[i].Text):lower():match("^%s*(.-)%s*$")
                if isDiffName[t] then
                    res[d] = 0
                elseif parseTime(t) then
                    res[d] = parseTime(t)
                else
                    return nil
                end
            end
            return res
        end

        -- returns the 5 difficulty timers of the open dialog and their container (nil when no dialog is open)
        local function readDialogDiffs()
            if dialogGrp and dialogGrp.Parent then
                local res = readGroup(dialogGrp)
                if res then return res, dialogGrp end
            end
            local pg = player:FindFirstChild("PlayerGui")
            if not pg then return nil end
            local parents = {}
            for _, b in ipairs(pg:GetDescendants()) do
                if b:IsA("TextButton") and b.Parent and not b:IsDescendantOf(gui) and shown(b) then
                    parents[b.Parent] = true
                end
            end
            for parent in pairs(parents) do
                local res = readGroup(parent)
                if res then
                    dialogGrp = parent
                    return res, parent
                end
            end
            return nil
        end

        -- is the dialog still open? (cheap when its container is known)
        local function dialogOpen()
            if dialogGrp and dialogGrp.Parent then return readGroup(dialogGrp) ~= nil end
            return readDialogDiffs() ~= nil
        end

        -- ---- closing the dialog ----
        -- Not every NPC has an "I'm not ready." button (e.g. Seras Integra), and an open dialog blocks the fight.
        -- 1) press a close-like button of the dialog's own gui  2) press any "not ready" button
        -- 3) last resort: hide the dialog frame (given back before the next talk)
        local CLOSE_WORDS = {"not ready", "not tonight", "goodbye", "bye", "leave", "later", "never mind", "nevermind", "no thanks"}
        local CLOSE_EXACT = {x = true, ["×"] = true, ["✕"] = true, close = true}
        local ACCEPT_WORDS = {"i'll go", "ill go", "let's go", "lets go", "fight", "start", "yes", "accept"} -- would START the fight: never pressed
        local hiddenDialog

        local function isAcceptText(t)
            for _, w in ipairs(ACCEPT_WORDS) do
                if t:find(w, 1, true) then return true end
            end
            return false
        end

        local function isCloseText(t)
            if CLOSE_EXACT[t] then return true end
            for _, w in ipairs(CLOSE_WORDS) do
                if t:find(w, 1, true) then return true end
            end
            return false
        end

        -- waits until the dialog is gone (checks every 0.15 s instead of a fixed pause)
        local function waitClosed(maxT)
            local t0 = os.clock()
            repeat
                if not dialogOpen() then return true end
                task.wait(0.15)
            until os.clock() - t0 > maxT
            return false
        end

        local function closeDialog(grp)
            local sg = grp and grp:FindFirstAncestorWhichIsA("ScreenGui")
            if sg and CFG.DEBUG_TIMER then
                local out = {}
                for _, b in ipairs(sg:GetDescendants()) do
                    if b:IsA("TextButton") and shown(b) and b.Parent ~= grp then
                        out[#out + 1] = b.Name .. "=" .. clean(b.Text)
                    end
                end
                print("[PibbleHub] dialog gui '" .. sg.Name .. "', other buttons: " .. (#out > 0 and table.concat(out, " | ") or "(none)"))
            end
            -- 1) close-like button inside the dialog's gui
            if sg then
                for _, b in ipairs(sg:GetDescendants()) do
                    if b:IsA("TextButton") and shown(b) and b.Parent ~= grp
                        and not isAcceptText(clean(b.Text):lower())
                        and isCloseText(clean(b.Text):lower():match("^%s*(.-)%s*$")) then
                        if activateButton(b) then break end
                    end
                end
                if waitClosed(0.8) then return true end
            end
            -- 1b) every NPC has its own decline text ("I'm not ready.", ...): press the choice button(s)
            -- shown just under the difficulty buttons, whatever they say
            do
                local pg = player:FindFirstChild("PlayerGui")
                local bottom, left, right = nil, math.huge, 0
                for _, b in ipairs(grp:GetChildren()) do
                    if b:IsA("TextButton") and shown(b) then
                        bottom = math.max(bottom or 0, b.AbsolutePosition.Y + b.AbsoluteSize.Y)
                        left = math.min(left, b.AbsolutePosition.X)
                        right = math.max(right, b.AbsolutePosition.X + b.AbsoluteSize.X)
                    end
                end
                if pg and bottom then
                    local midX, cands = (left + right) / 2, {}
                    for _, b in ipairs(pg:GetDescendants()) do
                        if b:IsA("TextButton") and shown(b) and b.Parent ~= grp and not b:IsDescendantOf(gui)
                            and clean(b.Text):match("%S") and not isAcceptText(clean(b.Text):lower()) then
                            local p, sz = b.AbsolutePosition, b.AbsoluteSize
                            if p.Y >= bottom - 4 and p.Y <= bottom + 120 and math.abs(p.X + sz.X / 2 - midX) <= 450 then
                                cands[#cands + 1] = b
                            end
                        end
                    end
                    table.sort(cands, function(a, b)
                        local ca, cb = isCloseText(clean(a.Text):lower()), isCloseText(clean(b.Text):lower())
                        if ca ~= cb then return ca end -- close-like buttons first
                        if a.AbsolutePosition.Y ~= b.AbsolutePosition.Y then return a.AbsolutePosition.Y < b.AbsolutePosition.Y end
                        return a.AbsolutePosition.X < b.AbsolutePosition.X
                    end)
                    for i = 1, math.min(2, #cands) do
                        if CFG.DEBUG_TIMER then print("[PibbleHub] dialog choice button: " .. clean(cands[i].Text)) end
                        if activateButton(cands[i]) then
                            if waitClosed(0.8) then return true end
                        end
                    end
                end
            end
            -- 2) any "not ready" button of the interface
            local nr = findButton(function(t)
                for _, w in ipairs(CLOSE_WORDS) do
                    if t:find(w, 1, true) then return true end
                end
                return false
            end)
            if nr and activateButton(nr) then
                if waitClosed(0.8) then return true end
            end
            -- 3) hide the dialog frame
            if sg then
                local top = grp
                while top.Parent and top.Parent ~= sg do top = top.Parent end
                if top:IsA("GuiObject") then
                    top.Visible = false
                    hiddenDialog = top
                else
                    sg.Enabled = false
                    hiddenDialog = sg
                end
                if waitClosed(0.8) then return true end
            end
            print("[PibbleHub] could not close the NPC dialog")
            return false
        end

        -- Opens the dialog, stores the cooldown of every difficulty of this NPC, closes the dialog.
        -- Returns true when the dialog could be read.
        local syncedAt = {} -- id -> os.time() of the last dialog read
        local setDiff = {}  -- id -> difficulty last sent with SetNPCDifficulty (no wait when it did not change)
        local function syncTimers(id)
            -- already read recently: the stored cooldowns (dialog + wins) are up to date, no need to talk again
            if syncedAt[id] and os.time() - syncedAt[id] < CFG.RESYNC_SECS then return true end
            for _ = 1, 2 do
                if hiddenDialog then -- give back a dialog we hid last time, so the game can open it again
                    pcall(function()
                        if hiddenDialog:IsA("ScreenGui") then hiddenDialog.Enabled = true else hiddenDialog.Visible = true end
                    end)
                    hiddenDialog = nil
                end
                local prompt = findTalkPrompt(id)
                if prompt and firePrompt(prompt) then
                    task.wait(0.05) -- let the dialog open and its buttons refresh (a stale one would show old timers)
                    local res, grp, t0 = nil, nil, os.clock()
                    while os.clock() - t0 < 3 do
                        res, grp = readDialogDiffs()
                        if res then break end
                        task.wait(0.08)
                    end
                    if res then
                        local now, out = os.time(), {}
                        for _, d in ipairs(DIFFS) do
                            local k = id .. "|" .. d
                            if res[d] > 0 then
                                Boss.cooldown[k] = now + res[d] + CFG.TIMER_MARGIN
                                out[#out + 1] = d .. "=" .. res[d] .. "s"
                            else
                                Boss.cooldown[k] = nil -- available (also corrects an old guess)
                                out[#out + 1] = d .. "=ready"
                            end
                        end
                        Settings.save()
                        if CFG.DEBUG_TIMER then
                            print("[PibbleHub] dialog timers " .. id .. ": " .. table.concat(out, " | "))
                        end
                        syncedAt[id] = os.time()
                        closeDialog(grp)
                        return true
                    end
                end
                task.wait(0.15)
            end
            print("[PibbleHub] could not read the dialog of " .. id)
            return false
        end

        -- ---- fight loop ----
        local nextBoss -- forward declaration (bossFight and nextBoss call each other)

        -- The boss is on a timer: remember when it is available again (saved), move the queue on.
        -- estimated = true: the timer is a guess (the server refused without telling it)
        local function skipOnTimer(id, diff, secs, estimated)
            Boss.cooldown[id .. "|" .. diff] = os.time() + secs + CFG.TIMER_MARGIN
            Settings.save()
            print(("[PibbleHub] %s on %s (%s): %ds"):format(estimated and "assumed cooldown" or "timer", id, diff, secs))
            Boss.active = false
            Boss.started = false
            advance()
            statusL.Text = ("Boss: %s %s %d:%02d"):format(niceName(id), estimated and "refused, retry in" or "on timer", secs // 60, secs % 60)
            if Boss.auto then
                task.delay(0.1, function()
                    if Boss.auto and gui.Parent and not Boss.active then nextBoss() end
                end)
            end
        end

        -- Every selected fight is on a timer: go to the lobby and wait for the first one to end
        local function waitForTimers()
            local function soonest()
                local best, now = nil, os.time()
                for _, f in ipairs(fightList()) do
                    local r = Boss.cooldown[keyOf(f)]
                    if not r or r <= now then return 0 end
                    best = best and math.min(best, r - now) or (r - now)
                end
                return best
            end

            if not Boss.auto then -- manual Start: just say so
                local s = math.ceil(soonest() or 0)
                statusL.Text = ("Boss: all on timer (%d:%02d)"):format(s // 60, s % 60)
                return
            end

            Boss.timerWait = true
            task.spawn(function()
                local wentLobby = false
                while Boss.auto and gui.Parent and not Boss.active do
                    local s = soonest()
                    if not s or s <= 0 then break end
                    s = math.ceil(s)
                    statusL.Text = ("Boss: all on timer, %d:%02d"):format(s // 60, s % 60)
                    if not wentLobby and not Raid.running and not WorldBoss.active and not Dungeon.active and not Portal.active and not Portal.ready then
                        wentLobby = Worlds.go("Lobby") ~= nil
                    end
                    task.wait(1)
                end
                Boss.timerWait = false
                if Boss.auto and gui.Parent and not Boss.active then nextBoss() end
            end)
        end

        -- npc id -> name of the world it lives in
        local worldOf = {}
        for _, w in ipairs(BOSS_WORLDS) do
            for _, id in ipairs(w[2]) do worldOf[id] = w[1] end
        end

        -- Every NPC lives in its own world: if it is not in the workspace, travel to its world first
        -- (1st attempt: the world's Enter button, 2nd attempt: the TeleportToWorld remote)
        local function ensureWorld(id)
            if findNPC(id) then return true end
            local world = worldOf[id]
            if not world then return true end
            for attempt = 1, 2 do
                statusL.Text = ("Boss: going to %s"):format(world)
                local method = Worlds.go(world, attempt == 2)
                if not method then
                    statusL.Text = "Boss: no teleport for " .. world
                    return false
                end
                -- wait (up to ~15 s) for the world to load and its NPC to appear
                for _ = 1, 60 do
                    task.wait(0.25)
                    if findNPC(id) then
                        task.wait(0.4)
                        return true
                    end
                end
            end
            return false
        end

        local function bossFight(manual)
            -- during a raid the boss queue is paused: Raid calls Boss.resume when it is over
            if Boss.active or Boss.waiting or Boss.timerWait or Raid.running or Dungeon.active or WorldBoss.active then return end
            -- priority: a portal that can be done (or is being done) goes first; the boss queue is restarted
            -- by the Portals feature (Boss.resume) as soon as there is none. The Start button always works.
            if not manual then
                local by = Prio.blockedBy("Boss")
                if by then
                    Boss.deferred = true -- the watchdog below restarts the queue once nothing is in front of it
                    statusL.Text = ("Boss: waiting (%s first)"):format(Prio.label(by))
                    return
                end
                if Portal.active then -- a portal that is being played is never interrupted
                    Boss.deferred = true
                    statusL.Text = "Boss: waiting (portal first)"
                    return
                end
            end
            if not Remotes.StartNPC then
                statusL.Text = "StartNPCBattle not found"
                return
            end
            local pick = peekFight()
            if not pick then
                if #fightList() == 0 then
                    statusL.Text = "Boss: select at least one"
                else
                    waitForTimers() -- everything selected is on a timer: lobby + wait
                end
                return
            end
            local id, diff = pick[1], pick[2]

            Boss.waiting = true
            Boss.waiting = false
            if Raid.running or WorldBoss.active then return end -- a raid / the world boss started while we were waiting
            Boss.active = true
            Boss.started = false -- BattleEnd events are ignored until StartNPCBattle is really fired
            Boss.current = pick
            Boss.run += 1
            local myRun = Boss.run

            statusL.Text = "Boss: going to " .. niceName(id)
            if not (ensureWorld(id) and tpToNPC(id)) then
                Boss.active = false
                advance() -- skip this NPC so the next selected boss can run
                statusL.Text = "Boss: NPC not found (" .. id .. ")"
                if Boss.auto then
                    task.delay(CFG.AUTO_DELAY * 2, function()
                        if Boss.auto and gui.Parent and not Boss.active then nextBoss() end
                    end)
                end
                return
            end
            task.wait(0.05)

            -- 1) talk to the NPC and read the timer of EVERY difficulty (each one has its own cooldown)
            local synced = syncTimers(id)
            if synced and onCooldown(pick) then
                local left = Boss.cooldown[keyOf(pick)] - os.time()
                skipOnTimer(id, diff, math.max(1, left - CFG.TIMER_MARGIN))
                return
            end

            -- 2) set the difficulty, like the game's own menu does
            if Remotes.SetNPCDiff then
                -- always sent (a remembered difficulty can be stale: the game may reset it between fights); the wait is only for a change
                local changed = setDiff[id] ~= diff
                Remotes.SetNPCDiff:FireServer(id, diff)
                setDiff[id] = diff
                -- the server needs a moment to apply a NEW difficulty, otherwise the fight starts on the old one
                task.wait(changed and CFG.DIFF_DELAY or 0.12) -- (an unchanged difficulty can still be stale, so there is always a short wait)
            end

            -- fallback when the dialog could not be read: the timer above the NPC (only if TRUST_NPC_TIMER)
            if not synced then
                dumpTexts(id)
                local pre = CFG.TRUST_NPC_TIMER and npcTimer(findNPC(id)) or nil
                if pre then
                    skipOnTimer(id, diff, pre)
                    return
                end
            end

            Boss.started = true
            Boss.startedAt = os.clock()
            Remotes.StartNPC:FireServer(id)
            statusL.Text = ("Boss: fighting %s (%s)"):format(id, diff)

            -- post-check: poll for a few seconds. A refused fight shows a timer (server message,
            -- popup or NPC billboard), or the server stays completely silent.
            local since = Boss.startedAt
            local deadline = os.clock() + CFG.TIMER_CHECK_DELAY
            while os.clock() < deadline do
                if not (Boss.active and Boss.run == myRun) then return end -- fight already ended/handled
                local secs, guessed = refusedTimer(id, since)
                if secs then
                    skipOnTimer(id, diff, secs, guessed)
                    return
                end
                task.wait(0.1)
            end
            if Boss.active and Boss.run == myRun
                and CFG.REFUSE_IF_SILENT and noticeCount(since) == 0 then
                dumpGuiTimers()
                skipOnTimer(id, diff, CFG.UNKNOWN_COOLDOWN, true) -- refused without a word: put it aside
                return
            end

            task.delay(CFG.BOSS_TIMEOUT, function()
                if Boss.active and Boss.run == myRun and gui.Parent then
                    Boss.active = false
                    advance()
                    statusL.Text = "Boss: no end event (timeout)"
                    if Boss.auto then nextBoss() end
                end
            end)
        end

        nextBoss = function()
            if Boss.auto and gui.Parent and not Boss.active then bossFight() end
        end

        -- called by Auto Raid once the raid is over: restarts the boss queue
        Boss.resume = function()
            if Boss.auto and gui.Parent and not Boss.active then nextBoss() end
        end

        -- used by the priority list: Auto Boss only claims its turn when something is selected
        Boss.hasWork = function() return #fightList() > 0 end

        -- the boss queue was held back by the priority list: start it again as soon as nothing is in front of it
        task.spawn(function()
            while gui.Parent do
                task.wait(2)
                if Boss.deferred then
                    if not Boss.auto then
                        Boss.deferred = false
                    elseif not Boss.active and not Boss.waiting and not Boss.timerWait
                        and not Portal.active and not Prio.blockedBy("Boss") then
                        Boss.deferred = false
                        nextBoss() -- (it sets the flag again if something else still has priority)
                    end
                end
            end
        end)

        startBtn.MouseButton1Click:Connect(function()
            if not Boss.active then bossFight(true) end
        end)

        local function setAuto(on)
            Boss.auto = on
            autoBtn.Text = on and "Auto: ON" or "Auto: OFF"
            autoBtn.BackgroundColor3 = on and GREEN or RED
            Settings.save()
            if on and not Boss.active then bossFight() end
        end
        Boss.setAuto = setAuto

        autoBtn.MouseButton1Click:Connect(function() setAuto(not Boss.auto) end)

        -- called by the BattleEnd router: returns true when the result belonged to a boss fight
        Boss.onBattleEnd = function(data)
            if not Boss.active then
                -- duplicate of a result we just handled: swallow it (it must not count as anything else)
                return os.clock() - Boss.lastEnd < 5
            end
            -- not started yet, or too early: stale result of the PREVIOUS fight, it is not ours
            if not Boss.started or os.clock() - Boss.startedAt < CFG.BOSS_MIN_FIGHT then
                logEnd("boss (ignored, stale)", data)
                return true
            end
            Boss.active = false
            Boss.lastEnd = os.clock()
            if LOSS[tostring(data.result):lower()] and Boss.retries < CFG.BOSS_RETRIES then
                -- lost: same boss, same difficulty again (the queue does not move)
                Boss.retries += 1
                statusL.Text = ("Boss: lost, retry %d/%d"):format(Boss.retries, CFG.BOSS_RETRIES)
            else
                -- a win starts the cooldown of that boss + difficulty: remember it, so the rotation
                -- does not come back to it before it is over (saved to the file)
                local cur = Boss.current
                if cur and not LOSS[tostring(data.result):lower()] then
                    Boss.cooldown[keyOf(cur)] = os.time() + winCooldown(cur[1])
                    Settings.save()
                end
                advance() -- move to the next fight only now that this one is really over
                statusL.Text = ("Boss: %s"):format(tostring(data.result))
            end
            logEnd("boss", data)
            if Boss.auto then
                task.delay(CFG.BOSS_DELAY, function()
                    if Boss.auto and gui.Parent and not Boss.active then nextBoss() end
                end)
            end
            return true
        end
    end)

    -- =====================================================================
    -- == 11. FEATURE: INFINITE TOWER (auto give up when a weather appears)
    -- =====================================================================
    safeFeature("Infinite Tower", function()
        featureTab("Infinite Tower", 450)
        label("Infinite Tower", 450, ORANGE)
        local statusL = label("Auto give up: idle", 470)
        local weatherBtn = button("Weather: Any", 10, 494, 230, 28, DARK)
        local popBtn = button("Pop: OFF", 10, 530, 105, 28, RED)
        local minBox = textbox("Min floor", 125, 530, 115, 28, tostring(Infinite.minFloor), 15)
        local untilBtn = button("Pop from: Off", 10, 566, 230, 28, DARK)
        local potionBtn = button("Potion: OFF", 10, 602, 105, 28, RED)
        local amountBtn = button("Use: 1", 125, 602, 115, 28, DARK)
        local potionBox = textbox("Custom amount", 10, 638, 230, 28, tostring(Infinite.potionCustom), 15)
        local scanGenBtn = button("Scan Generated (F9)", 10, 674, 230, 28, DARK)
        scanGenBtn.TextSize = 13

        -- ---- weather menu (multi-select) ----
        local ITEM_H, ITEM_GAP = 28, 4
        local weatherMenu = sidePanel("Frame", 190, (#WEATHERS + 1) * (ITEM_H + ITEM_GAP) + ITEM_GAP)
        local anyBtn = button("Any weather", 8, ITEM_GAP, 174, ITEM_H, DARK, weatherMenu, 21)
        local weatherBtns = {}
        for i, w in ipairs(WEATHERS) do
            weatherBtns[w] = button(w, 8, ITEM_GAP + i * (ITEM_H + ITEM_GAP), 174, ITEM_H, DARK, weatherMenu, 21)
        end

        local function refreshWeatherPick()
            local n, last = 0, nil
            for _, w in ipairs(WEATHERS) do
                local on = Infinite.weathers[w:lower()] == true
                if on then n += 1; last = w end
                weatherBtns[w].BackgroundColor3 = on and GREEN or DARK
                weatherBtns[w].Text = (on and "[x] " or "[  ] ") .. w
            end
            anyBtn.BackgroundColor3 = (n == 0) and GREEN or DARK
            if n == 0 then
                weatherBtn.Text = "Weather: Any"
            elseif n == 1 then
                weatherBtn.Text = "Weather: " .. last
            else
                weatherBtn.Text = ("Weather: %d selected"):format(n)
            end
        end

        for _, w in ipairs(WEATHERS) do
            weatherBtns[w].MouseButton1Click:Connect(function()
                local k = w:lower()
                if Infinite.weathers[k] then Infinite.weathers[k] = nil else Infinite.weathers[k] = true end
                refreshWeatherPick()
                Settings.save()
            end)
        end
        anyBtn.MouseButton1Click:Connect(function()
            Infinite.weathers = {}
            refreshWeatherPick()
            Settings.save()
        end)
        weatherBtn.MouseButton1Click:Connect(function()
            weatherMenu.Visible = not weatherMenu.Visible
        end)
        refreshWeatherPick()

        -- ---- "Pop from" menu: the chosen weather or a better one is popped (given up); lower ones are skipped ----
        local untilMenu = sidePanel("Frame", 190, (#WEATHER_ORDER + 1) * (ITEM_H + ITEM_GAP) + ITEM_GAP)
        local untilOff = button("Off (use Weather list)", 8, ITEM_GAP, 174, ITEM_H, DARK, untilMenu, 21)
        local untilBtns = {}
        for i, w in ipairs(WEATHER_ORDER) do
            untilBtns[w] = button(w .. " +", 8, ITEM_GAP + i * (ITEM_H + ITEM_GAP), 174, ITEM_H, DARK, untilMenu, 21)
        end

        local function weatherRank(name)
            local k = tostring(name or ""):lower()
            for i, w in ipairs(WEATHER_ORDER) do
                if w:lower() == k then return i end
            end
            return nil
        end

        local function refreshUntil()
            local want = Infinite.untilWeather
            untilOff.BackgroundColor3 = want == nil and GREEN or DARK
            for _, w in ipairs(WEATHER_ORDER) do
                untilBtns[w].BackgroundColor3 = (want == w:lower()) and GREEN or DARK
            end
            if want then
                local shownName = want
                for _, w in ipairs(WEATHER_ORDER) do
                    if w:lower() == want then shownName = w end
                end
                untilBtn.Text = "Pop from: " .. shownName .. " +"
                untilBtn.BackgroundColor3 = GREEN
            else
                untilBtn.Text = "Pop from: Off"
                untilBtn.BackgroundColor3 = DARK
            end
        end

        untilOff.MouseButton1Click:Connect(function()
            Infinite.untilWeather = nil
            refreshUntil()
            untilMenu.Visible = false
            Settings.save()
        end)
        for _, w in ipairs(WEATHER_ORDER) do
            untilBtns[w].MouseButton1Click:Connect(function()
                Infinite.untilWeather = w:lower()
                refreshUntil()
                untilMenu.Visible = false
                Settings.save()
            end)
        end
        untilBtn.MouseButton1Click:Connect(function()
            weatherMenu.Visible = false
            untilMenu.Visible = not untilMenu.Visible
        end)
        weatherBtn.MouseButton1Click:Connect(function() untilMenu.Visible = false end)
        refreshUntil()

        -- ---- weather detection ----
        -- Empty selection = any weather triggers the give up
        local function weatherAllowed(name)
            if next(Infinite.weathers) == nil then return true end
            return Infinite.weathers[tostring(name or ""):lower()] == true
        end

        -- Reads PlayerGui.WeatherGui.WeatherIndicator: WeatherName "[ Void ]" + TimerLabel "Time Remaining: 268".
        -- (EventIndicator is a different thing, e.g. "[ Release Event ]", and is ignored.)
        local function scanWeather()
            local pg = player:FindFirstChild("PlayerGui")
            local wg = pg and pg:FindFirstChild("WeatherGui")
            local ind = wg and wg:FindFirstChild("WeatherIndicator")
            if not ind then return nil end
            local nameL, timerL = ind:FindFirstChild("WeatherName"), ind:FindFirstChild("TimerLabel")
            if not (nameL and timerL and shown(nameL) and shown(timerL)) then return nil end
            local n = clean(nameL.Text):match("^%s*%[%s*(.-)%s*%]%s*$")
            local secs = tonumber(clean(timerL.Text):match("(%d+)"))
            if n and n ~= "" and secs and secs > 0 then return n, secs end
            return nil
        end

        -- ---- wiring ----
        local function setPop(on)
            Infinite.on = on
            popBtn.Text = on and "Pop: ON" or "Pop: OFF"
            popBtn.BackgroundColor3 = on and GREEN or RED
            Settings.save()
        end
        Infinite.setPop = setPop

        popBtn.MouseButton1Click:Connect(function() setPop(not Infinite.on) end)

        minBox.FocusLost:Connect(function()
            local n = tonumber(minBox.Text)
            if n then Infinite.minFloor = math.max(1, math.floor(n)) end -- no upper limit
            minBox.Text = tostring(Infinite.minFloor)
            Settings.save()
        end)

        -- ---- weather potions ----
        -- While no weather is active ("Pop from" is set, the floor is at least the Min floor) a weather potion is used
        -- from the inventory: PlayerGui.ItemGui.ItemFrame.ItemGrid.<item> is clicked, then the amount button that
        -- matches the "Use:" setting (1 / 10 / All / Custom). If the game's buttons are named differently, the visible
        -- buttons are printed to F9 so the words can be added below.
        local AMOUNT_KINDS = {"one", "ten", "all", "custom"}
        local AMOUNT_LABELS = { one = "1", ten = "10", all = "All", custom = "Custom" }

        local function refreshPotion()
            potionBtn.Text = Infinite.potion and "Potion: ON" or "Potion: OFF"
            potionBtn.BackgroundColor3 = Infinite.potion and GREEN or RED
            amountBtn.Text = "Use: " .. AMOUNT_LABELS[Infinite.potionAmount]
            potionBox.TextTransparency = Infinite.potionAmount == "custom" and 0 or 0.55
        end
        potionBtn.MouseButton1Click:Connect(function()
            Infinite.potion = not Infinite.potion
            refreshPotion()
            Settings.save()
        end)
        amountBtn.MouseButton1Click:Connect(function()
            local idx = 1
            for i, k in ipairs(AMOUNT_KINDS) do
                if k == Infinite.potionAmount then idx = i end
            end
            Infinite.potionAmount = AMOUNT_KINDS[idx % #AMOUNT_KINDS + 1]
            refreshPotion()
            Settings.save()
        end)
        potionBox.FocusLost:Connect(function()
            local n = tonumber(potionBox.Text)
            if n then Infinite.potionCustom = math.max(1, math.floor(n)) end
            potionBox.Text = tostring(Infinite.potionCustom)
            Settings.save()
        end)
        refreshPotion()

        local function normT(t)
            return (tostring(t):lower():gsub("[^%w ]", ""):gsub("%s+", " "):match("^%s*(.-)%s*$"))
        end
        local function amountMatch(kind, t)
            if kind == "one" then
                return t == "use" or t == "use 1" or t == "1" or t == "x1" or t == "use one" or t == "one"
            elseif kind == "ten" then
                return t == "10" or t == "x10" or t == "use 10" or t == "use 10x" or t == "use ten" or t == "ten"
            elseif kind == "all" then
                return t == "all" or t == "use all" or t == "x all" or t == "max" or t == "use max"
            end
            return t:find("custom", 1, true) ~= nil or t == "use amount" or t == "amount"
        end

        -- the game's own buttons of the item panel (PlayerGui.ItemGui.ItemFrame.ItemInfoPanel), found by NAME
        local AMOUNT_BUTTON = { one = "UseButton", ten = "UseButton10", all = "UseButtonAll", custom = "UseButtonAmount" }
        local function amountButtonByName(inv, kind)
            local panel = inv:FindFirstChild("ItemInfoPanel", true)
            local b = panel and panel:FindFirstChild(AMOUNT_BUTTON[kind])
            if b and b:IsA("GuiButton") and shown(b) then return b end
            return nil
        end

        -- a visible button of the inventory (outside the item grid) whose normalized text matches pred
        local function invButton(inv, grid, pred)
            for _, d in ipairs(inv:GetDescendants()) do
                if (d:IsA("TextButton") or d:IsA("TextLabel")) and not (grid and d:IsDescendantOf(grid)) then
                    if pred(normT(d.Text)) then
                        local b = d:IsA("GuiButton") and d or d:FindFirstAncestorWhichIsA("GuiButton")
                        if b and shown(b) then return b end
                    end
                end
            end
            return nil
        end

        local function dumpInv(inv, grid, what)
            local out = {}
            for _, d in ipairs(inv:GetDescendants()) do
                if #out >= 25 then break end
                if d:IsA("TextButton") and shown(d) and not (grid and d:IsDescendantOf(grid)) then
                    out[#out + 1] = '"' .. clean(d.Text) .. '"'
                end
            end
            print("[PibbleHub] potion: " .. what .. ". Visible buttons: " .. (#out > 0 and table.concat(out, ", ") or "(none)"))
        end

        -- the grid button of a weather potion (name or any text inside it contains one of CFG.POTION_WORDS)
        local function findPotionItem(grid)
            for _, item in ipairs(grid:GetChildren()) do
                local hay = item.Name:lower()
                for _, d in ipairs(item:GetDescendants()) do
                    if d:IsA("TextLabel") or d:IsA("TextButton") then hay = hay .. " " .. clean(d.Text):lower() end
                end
                for _, w in ipairs(CFG.POTION_WORDS) do
                    if hay:find(w:lower(), 1, true) then
                        local control = item:IsA("GuiButton") and item or item:FindFirstChildWhichIsA("GuiButton", true)
                        if not control and item:IsA("GuiObject") then control = item end -- a plain Frame: clicked with the mouse
                        if control and shown(control) then return control, item.Name end
                    end
                end
            end
            return nil
        end

        -- a real mouse click in the middle of the control (for items / buttons that ignore fired signals)
        local function mouseClick(obj)
            return pcall(function()
                local vim = game:GetService("VirtualInputManager")
                local sg = obj:FindFirstAncestorWhichIsA("ScreenGui")
                local inset = (sg and sg.IgnoreGuiInset) and Vector2.new(0, 0)
                    or game:GetService("GuiService"):GetGuiInset()
                local p = obj.AbsolutePosition + obj.AbsoluteSize / 2 + inset
                vim:SendMouseButtonEvent(p.X, p.Y, 0, true, game, 1)
                task.wait(0.05)
                vim:SendMouseButtonEvent(p.X, p.Y, 0, false, game, 1)
                releaseInput()
            end)
        end
        local function clickObj(obj)
            if obj:IsA("GuiButton") and activateButton(obj) then return true end
            return mouseClick(obj)
        end

        -- =================================================================
        -- WEATHER POTION ROUTINE
        -- Never forces a window open or shut: the item window is opened with the game's own item button and closed with
        -- its own close button. The first thing that is not as expected ends the routine cleanly and puts the potions
        -- on a back-off that grows with every failure (no tight retry loops). A new generation number (pop / potion
        -- switched off) makes a running routine stop at its next step.
        -- =================================================================
        local potionBusy, lastPotion, potionBackoff, potionNote, potionNoteAt = false, -1e9, 0, "", 0
        local potionFails, potionGen = 0, 0
        local potionWanted = false -- a roll is due right now (it counts as "the pop is busy": lower features wait)
        local function note(text) potionNote, potionNoteAt = text, os.clock() end
        local function failPotion(why, base)
            potionFails += 1
            potionBackoff = os.clock() + math.min(300, (base or 30) * potionFails)
            note(why)
            print("[PibbleHub] potion: " .. why .. " (back-off " .. math.floor(potionBackoff - os.clock()) .. "s)")
        end

        -- the game's own handler first, a real click as the backup
        local function press(obj)
            if not (obj and obj.Parent) then return false end
            if obj:IsA("GuiButton") and activateButton(obj) then return true end
            return clickObj(obj)
        end

        local function rollPotion()
            if potionBusy then return end
            potionBusy, lastPotion = true, os.clock()
            local myGen = potionGen
            local pg = player:FindFirstChildOfClass("PlayerGui")
            local inv = pg and pg:FindFirstChild("ItemGui")
            local frame = inv and inv:FindFirstChild("ItemFrame")
            local snap = snapButtons(inv)
            local wasOpen = frame and frame:IsA("GuiObject") and shown(frame) or false
            local opened = false
            local function alive() return gui.Parent ~= nil and Infinite.on and Infinite.potion and myGen == potionGen end

            local okRun, err = pcall(function()
                if not (frame and frame:IsA("GuiObject")) then return failPotion("no inventory", 30) end

                if not openInventoryNative(inv, frame) then return failPotion("could not open the item window", 30) end
                opened = true

                local grid
                local t0 = os.clock()
                repeat
                    task.wait(0.1)
                    grid = frame:FindFirstChild("ItemGrid")
                until (grid and #grid:GetChildren() > 0) or os.clock() - t0 > 3 or not alive()
                if not alive() then return end
                if not grid then return failPotion("no item grid", 30) end

                local startWeather = scanWeather()
                for attempt = 1, 4 do
                    if not alive() then return end
                    local item, itemName = findPotionItem(grid)
                    if not item then
                        local names = {}
                        for _, c in ipairs(grid:GetChildren()) do
                            if #names < 20 then names[#names + 1] = c.Name end
                        end
                        print("[PibbleHub] potion: no weather potion in the inventory (looked for: "
                            .. table.concat(CFG.POTION_WORDS, "/") .. "). Items: " .. table.concat(names, ", "))
                        return failPotion("no potion found", 60)
                    end
                    if not press(item) then return failPotion("item click failed", 30) end

                    local kind = Infinite.potionAmount
                    local btn
                    t0 = os.clock()
                    repeat
                        task.wait(0.1)
                        btn = amountButtonByName(inv, kind) or invButton(inv, grid, function(t) return amountMatch(kind, t) end)
                    until btn or os.clock() - t0 > 4 or not alive()
                    if not alive() then return end
                    if not btn then
                        dumpInv(inv, grid, "amount button '" .. AMOUNT_LABELS[kind] .. "' not found after clicking " .. tostring(itemName))
                        return failPotion("no '" .. AMOUNT_LABELS[kind] .. "' button", 30)
                    end

                    local function amountBox()
                        for _, d in ipairs(inv:GetDescendants()) do
                            if d:IsA("TextBox") and shown(d) and not d:IsDescendantOf(grid) then return d end
                        end
                        return nil
                    end
                    local function typeAmount(box)
                        box.Text = tostring(Infinite.potionCustom)
                        pcall(function() box:ReleaseFocus() end)
                        task.wait(0.2)
                    end
                    local prefilled = false
                    if kind == "custom" then
                        local box = amountBox()
                        if box then typeAmount(box); prefilled = true end
                    end
                    if not press(btn) then return failPotion("use click failed", 30) end
                    if kind == "custom" and not prefilled then
                        task.wait(0.4)
                        local box = amountBox()
                        if box then
                            typeAmount(box)
                            local confirm = invButton(inv, grid, function(t)
                                return t == "use" or t == "confirm" or t == "ok" or t == "apply" or t == "use custom" or t == "submit"
                            end)
                            if confirm then press(confirm) end
                        else
                            dumpInv(inv, grid, "custom amount box not found")
                        end
                    end

                    potionFails, potionBackoff = 0, 0
                    note("used " .. AMOUNT_LABELS[kind] .. (kind == "custom" and (" (" .. Infinite.potionCustom .. ")") or "")
                        .. (attempt > 1 and (" (try " .. attempt .. ")") or ""))
                    print("[PibbleHub] potion: used " .. tostring(itemName) .. " x " .. AMOUNT_LABELS[kind])

                    -- wait (window still open) for a weather that is different from the one before
                    local newWeather
                    local untilT = os.clock() + 7
                    repeat
                        task.wait(0.3)
                        newWeather = scanWeather()
                    until (newWeather and newWeather ~= startWeather) or os.clock() >= untilT or not alive()
                    if (newWeather and newWeather ~= startWeather) or not alive() then return end
                    note("no weather yet, using another")
                end
            end)
            if not okRun then
                warn("[PibbleHub] potion error:", err)
                failPotion("error (see F9)", 30)
            end
            if opened and not wasOpen then
                task.wait(CFG.POTION_CLOSE_DELAY or 1.2) -- not right after the last click
                if not closeInventoryNative(inv, frame) then
                    print("[PibbleHub] potion: the item window did not close by itself (left as the game has it)")
                end
            end
            fixButtons(snap, 2)
            potionBusy = false
        end

        -- One look at the potion rules: returns the status text and, when it is time, starts a roll.
        -- label = what the status line says about the weather ("no weather" / "below minimum")
        local function potionStep(wantRank, label, listMode)
            if not wantRank and not listMode then return label .. " (set Pop from to use potions)" end
            if Infinite.floor < Infinite.minFloor then return label .. " (floor<min, no potion)" end
            if potionBusy then potionWanted = true; return "using potion..." end
            if os.clock() < potionBackoff then
                return label .. " (potion on hold: " .. (potionNote ~= "" and potionNote or "failed, see F9") .. ")"
            end
            potionWanted = true
            -- only the activities that take over the screen hold a roll back (Boss / Dungeon fights never did)
            local busyWith = (Portal.active and "portal") or (Raid.running and "raid") or (WorldBoss.active and "world boss") or nil
            if busyWith then return label .. " (potion waits for the " .. busyWith .. ")" end
            if os.clock() - lastPotion >= math.max(CFG.POTION_COOLDOWN, 6) then
                task.spawn(rollPotion)
                return label .. ", using potion"
            end
            return label .. " (waiting for the roll)"
        end

        -- The floor is read from the game's own "CURRENT FLOOR: 4698" text, so the Min floor check is right from the
        -- first second (the floor from the battle results alone is only known after the first fight).
        local lastFloorScan, lastFullFloorScan, floorLabel = 0, -1e9, nil
        local function syncFloor()
            if os.clock() - lastFloorScan < 1 then return end
            lastFloorScan = os.clock()
            -- the label found last time is simply read again (a whole-interface scan every second is heavy on a small emulator)
            if floorLabel and floorLabel.Parent and shown(floorLabel) then
                local n = clean(floorLabel.Text):lower():match("current%s*floor%s*:?%s*(%d+)")
                if n then Infinite.floor = tonumber(n); return end
            end
            floorLabel = nil
            if os.clock() - lastFullFloorScan < 8 then return end -- a full scan at most every 8 seconds
            lastFullFloorScan = os.clock()
            local pg = player:FindFirstChild("PlayerGui")
            if not pg then return end
            for _, d in ipairs(pg:GetDescendants()) do
                if d:IsA("TextLabel") and not d:IsDescendantOf(gui) and shown(d) then
                    local n = clean(d.Text):lower():match("current%s*floor%s*:?%s*(%d+)")
                    if n then
                        Infinite.floor = tonumber(n)
                        floorLabel = d
                        return
                    end
                end
            end
        end

        -- =================================================================
        -- GIVE UP: tries every way there is, one after the other, and CHECKS that the run really ended (the
        -- "CURRENT FLOOR" text drops back). A pressed button only means "the click was sent", not that the game obeyed it.
        -- Order: the Give Up button's own handler -> the game's end-tower remote -> a real mouse click.
        -- =================================================================
        local giving = false
        local function floorNow()
            if floorLabel and floorLabel.Parent then
                local n = clean(floorLabel.Text):lower():match("current%s*floor%s*:?%s*(%d+)")
                if n then return tonumber(n) end
            end
            return nil
        end

        local function giveUp()
            if giving then return "in progress" end
            giving = true
            Infinite.lastGiveUp = os.clock() -- the cooldown starts now: no second attempt while this one runs
            task.spawn(function()
                local okAll, errAll = pcall(function()
                    local before = floorNow() or Infinite.floor
                    local canVerify = floorNow() ~= nil
                    local b = findButton(function(t) return t:find("give up", 1, true) ~= nil end)
                    local snap = snapButtons(b and b:FindFirstAncestorWhichIsA("ScreenGui"))
                    local methods = {
                        -- the way the pop always worked: the game's own Give Up button handler (even when the button itself
                        -- counts as "not shown": its handler still runs)
                        { "button", function() if b then return activateButton(b) end end },
                        { "remote", function()
                            if Remotes.EndTower then Remotes.EndTower:FireServer(CFG.END_ARG) return true end
                        end },
                        { "real click", function() if b and shown(b) then return realClick(b) end end },
                    }
                    local done = false
                    for _, m in ipairs(methods) do
                        local okM, did = pcall(m[2])
                        if okM and did then
                            print("[PibbleHub] pop: give up via " .. m[1])
                            task.delay(0.6, confirmDialog) -- the game may ask "are you sure?"
                            if not canVerify then done = true break end -- nothing to check it against
                            local t0 = os.clock()
                            repeat
                                task.wait(0.4)
                                local f = floorNow()
                                if f and f < before then done = true end
                            until done or os.clock() - t0 > 4
                            if done then break end
                            print("[PibbleHub] pop: " .. m[1] .. " did not end the run, trying the next way")
                        end
                    end
                    if done then
                        Infinite.floor = floorNow() or 1
                        fixButtons(snap, 3)
                    else
                        print("[PibbleHub] pop: could not give up, retrying shortly")
                        Infinite.lastGiveUp = os.clock() - 5 -- the next try comes in about 3 s
                    end
                end)
                if not okAll then
                    warn("[PibbleHub] give up error:", errAll)
                    Infinite.lastGiveUp = os.clock() - 5
                end
                giving = false
            end)
            return "started"
        end

        -- the first feature the user ranked ABOVE Auto Pop that is running right now (nil = the pop may go on).
        -- Features ranked below it never hold the pop back: they wait for it instead (Prio.blockedBy).
        local function popHeldBy()
            for i = 1, Prio.rank("Pop") - 1 do
                local n = Prio.order[i]
                if Prio.running(n) then return n end
            end
            return nil
        end

        -- when a pop is over, everything that was waiting for it gets its turn back
        local lastBusy = false
        local function setPopBusy(v)
            v = v and true or false
            Infinite.popBusy = v
            if lastBusy and not v then task.delay(1.5, function() pcall(Prio.resumeAll) end) end
            lastBusy = v
        end

        -- =================================================================
        -- POP LOOP: one look every 0.5 s. Each look is wrapped in pcall, so one error can never stop the loop.
        --   off / held by a higher feature -> nothing happens (a running potion routine is told to stop)
        --   weather present -> wanted? -> keep playing until POP_GIVEUP_LEFT seconds remain -> give up
        --   weather missing / too low   -> roll a potion (when switched on)
        -- While the pop wants the player (a wanted weather, a roll), everything ranked below it is stopped and waits.
        -- =================================================================
        local lastN, lastSecs, lastSeenAt
        local lastInterrupt = {}
        local function popTick()
            if not Infinite.on then
                potionGen += 1
                setPopBusy(potionBusy)
                return
            end
            local by = popHeldBy()
            if by then
                if potionBusy then potionGen += 1 end -- a higher feature has the player: the roll stops at its next step
                setPopBusy(potionBusy)
                statusL.Text = ("Pop paused: %s first"):format(Prio.label(by))
                return
            end
            if not Infinite.potion then potionGen += 1 end

            pcall(syncFloor)
            local n, secs = scanWeather()
            -- the weather label can vanish for a moment (world change, UI reload): that is not "no weather"
            if n then
                lastN, lastSecs, lastSeenAt = n, secs, os.clock()
            elseif lastN and os.clock() - lastSeenAt < 2.5 then
                n, secs = lastN, math.max(1, lastSecs - (os.clock() - lastSeenAt))
            end

            potionWanted = false
            local qualifying = false -- the weather fits at a floor where popping is allowed
            local why
            local wantRank = Infinite.untilWeather and weatherRank(Infinite.untilWeather)
            local gotRank = n and weatherRank(n)
            if not n then
                why = "no weather"
                if Infinite.potion then why = potionStep(wantRank, "no weather") end
            elseif wantRank and not gotRank then
                why = "unknown weather (skipped)"
            elseif wantRank and gotRank < wantRank then
                why = "below minimum weather (skipped)"
                if Infinite.potion and CFG.POTION_OVER_WEATHER then why = potionStep(wantRank, "below minimum") end
            elseif not wantRank and not weatherAllowed(n) then
                why = "not selected"
                if Infinite.potion and CFG.POTION_OVER_WEATHER then why = potionStep(nil, "not selected", true) end
            elseif Infinite.floor < Infinite.minFloor then
                why = "floor<min"
            elseif os.clock() - Infinite.lastGiveUp < 8 then
                why = "cooldown"
                qualifying = true
            elseif secs > CFG.POP_GIVEUP_LEFT then
                qualifying = true
                why = ("give up in %ds"):format(secs - CFG.POP_GIVEUP_LEFT)
            else
                qualifying = true
                why = giveUp() == "in progress" and "giving up..." or "GIVE UP"
            end
            if n and (qualifying or not Infinite.potion) then potionGen += 1 end -- a wanted weather is up: no more rolls

            statusL.Text = ("%s | F%d | %s"):format(n or "-", Infinite.floor, why)
                .. ((potionNote ~= "" and os.clock() - potionNoteAt < 15 and why:find("potion", 1, true) == nil) and (" | " .. potionNote) or "")

            local wants = qualifying or potionWanted or potionBusy
            if wants then
                -- everything ranked below the pop stops now and waits until the pop is finished
                for i = Prio.rank("Pop") + 1, #Prio.order do
                    local nm = Prio.order[i]
                    if Prio.running(nm) and os.clock() - (lastInterrupt[nm] or -1e9) > 4 then
                        lastInterrupt[nm] = os.clock()
                        print("[PibbleHub] pop: stopping " .. Prio.label(nm) .. " until the pop is finished")
                        pcall(Prio.interrupt, nm)
                    end
                end
            end
            setPopBusy(wants or (os.clock() - Infinite.lastGiveUp < 6))
        end

        task.spawn(function()
            local errs = 0
            while gui.Parent do
                task.wait(0.5)
                local okT, errT = pcall(popTick)
                if okT then
                    errs = 0
                else
                    errs += 1
                    if errs <= 3 or errs % 40 == 0 then warn("[PibbleHub] pop loop error:", errT) end
                    statusL.Text = "Pop: error (see F9), retrying"
                end
            end
        end)

        -- ---- Scan Generated: writes the structure of the "Generated" results window to F9 (and the clipboard) ----
        -- Open the window first (it shows "Generated", "Cards:", "Luck:", "Border:" and "Floor"). The first few children of
        -- every node are listed in full, the rest only counted, so a window with dozens of cards stays short.
        local function scanGenerated()
            local pg = player:FindFirstChildOfClass("PlayerGui")
            if not pg then return end
            local root
            for _, d in ipairs(pg:GetDescendants()) do
                if d:IsA("TextLabel") and not d:IsDescendantOf(gui) and shown(d) then
                    local t = clean(d.Text):lower():gsub("^%s+", ""):gsub("%s+$", "")
                    if t == "generated" then
                        root = d:FindFirstAncestorWhichIsA("ScreenGui")
                        break
                    end
                end
            end
            if not root then
                statusL.Text = "Scan: open the Generated window first"
                print("[PibbleHub] scan: no visible 'Generated' title found in PlayerGui")
                return
            end

            local lines = {}
            local function describe(d)
                local bits = { d.ClassName, d.Name }
                if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
                    bits[#bits + 1] = 'text="' .. clean(d.Text) .. '"'
                end
                if d:IsA("ImageLabel") or d:IsA("ImageButton") then
                    bits[#bits + 1] = 'image="' .. tostring(d.Image) .. '"'
                end
                for k, v in pairs(d:GetAttributes()) do bits[#bits + 1] = "@" .. k .. "=" .. tostring(v) end
                if d:IsA("GuiObject") and not d.Visible then bits[#bits + 1] = "(hidden)" end
                return table.concat(bits, " | ")
            end
            local function dump(node, depth)
                if #lines >= 220 or depth > 9 then return end
                lines[#lines + 1] = string.rep("  ", depth) .. describe(node)
                local kids = node:GetChildren()
                for i, c in ipairs(kids) do
                    local limit = (depth <= 1) and 16 or ((node.Parent and node.Parent.Name == "CardGrid") and 8 or 4)
                    if i > limit then
                        lines[#lines + 1] = string.rep("  ", depth + 1) .. ("... +%d more children (e.g. %s, %s)"):format(#kids - limit, kids[limit + 1].Name, kids[#kids].Name)
                        break
                    end
                    dump(c, depth + 1)
                end
            end
            lines[1] = "ScreenGui: " .. root:GetFullName()
            dump(root, 0)
            local text = table.concat(lines, "\n")
            local i = 1
            while i <= #lines do
                print("[PibbleHub] scan generated:\n" .. table.concat(lines, "\n", i, math.min(i + 24, #lines)))
                i += 25
            end
            local copied = false
            if typeof(setclipboard) == "function" then copied = pcall(setclipboard, text) end
            statusL.Text = "Scan done (" .. #lines .. " lines)" .. (copied and ", copied to clipboard" or ", see F9")
        end
        scanGenBtn.MouseButton1Click:Connect(function() task.spawn(scanGenerated) end)

        -- called by the BattleEnd router: returns true for every result that is NOT the Halloween Tower.
        -- Only tracks the current floor (needed for the "min floor" check).
        Infinite.onBattleEnd = function(data)
            if data.tower == "halloween" and data.mode == "infinite_room" then return false end
            local fl = tonumber(data.floor)
            if os.clock() - Infinite.lastGiveUp < 10 or LOSS[tostring(data.result):lower()] then
                Infinite.floor = 1 -- run ended (our give up or a loss): the next run starts at floor 1
            elseif fl then
                Infinite.floor = fl + 1
            end
            logEnd("infinite", data)
            return true
        end
    end)

    -- =====================================================================
    -- == 11b. FEATURE: AUTO RAID
    -- =====================================================================
    -- There are several raids (CFG.RAIDS: Soul King, Beerus, Reid), each with its own on/off switch. A raid slot starts
    -- at every xx:00 and xx:30 (real clock). The raids can be done during the first 15 minutes of the slot (the timer
    -- shown in the UI), one after the other. One raid = teleport to the raid world (skipped when we are already there),
    -- stand next to its boss (found by NPCId / name, entered through its portal in Workspace.Portals when it is not
    -- there), then StartRaidBattle fired 4 times (each fight waits for its BattleEnd, or RAID_FIGHT_TIMEOUT).
    -- Only the FIRST fight can mean "raid refused / on cooldown". Fights 2-4 are retried (a refusal text or a
    -- silence right after a fight is just the previous fight closing). The slot is marked as done only after the
    -- 4th fight; an interrupted raid is retried by Auto and continues from the next fight.
    -- While a raid runs, Boss / Pop are paused, and resumed right after.
    safeFeature("Auto Raid", function()
        featureTab("Auto Raid", 570)
        label("Auto Raid", 570, ORANGE)
        local statusL = label("Raid: idle", 590)
        local timerL = label("Next raid: -", 610)
        local startBtn = button("Start all", 10, 636, 105, 28, BLUE)
        local autoBtn = button("Auto: OFF", 125, 636, 115, 28, RED)

        -- one row per raid: [name: ON/OFF (state)] [Go]
        label("RAIDS", 668, MUTED, 11).Size = UDim2.fromOffset(160, 16)
        local raidRows = {}
        for i, r in ipairs(CFG.RAIDS) do
            local y = 688 + (i - 1) * 32
            raidRows[i] = {
                raid = r,
                toggle = button(r.label .. ": ON", 10, y, 196, 28, GREEN),
                go = button("Go", 212, y, 84, 28, BLUE),
            }
        end
        local scanBtn = button("Scan raids (F9)", 10, 688 + #CFG.RAIDS * 32 + 4, 196, 26, DARK)
        scanBtn.TextSize = 13

        -- schedule of a raid (every raid can have its own interval / window)
        local function intervalOf(r) return r.interval or CFG.RAID_INTERVAL end
        local function windowOf(r) return r.window or CFG.RAID_WINDOW end
        local function slotOf(r) return math.floor(os.time() / intervalOf(r)) end
        local function intoSlot(r) return os.time() % intervalOf(r) end
        local function inWindow(r) return intoSlot(r) < windowOf(r) end
        local function isDone(r) return Raid.slotsDone[r.id] == slotOf(r) end
        -- fights finished in the current slot of that raid
        local function countFor(r)
            local c = Raid.counts[r.id]
            if not c or c.slot ~= slotOf(r) then
                c = { slot = slotOf(r), n = 0 }
                Raid.counts[r.id] = c
            end
            return c
        end
        -- the raid is switched on, its window is open and its fights of this slot are not done yet
        local function isOpenRaid(r) return Raid.enabled[r.id] == true and inWindow(r) and not isDone(r) end

        local function mmss(s)
            s = math.max(0, math.floor(s))
            return ("%dm %02ds"):format(s // 60, s % 60)
        end

        -- ---- what the server sends back (to know whether StartRaidBattle was accepted) ----
        local Seen = { list = {} } -- {t = os.clock(), name = lowercase remote name, text = lowercase texts of the event}

        local function collectTexts(v, out, depth)
            if type(v) == "string" then
                out[#out + 1] = v
            elseif type(v) == "table" and depth < 3 then
                for _, x in pairs(v) do collectTexts(x, out, depth + 1) end
            end
        end

        local function isRefusal(text)
            if text == "" then return false end
            for _, w in ipairs(CFG.RAID_REFUSE_WORDS) do
                if text:find(w, 1, true) then return true end
            end
            return false
        end

        for _, r in ipairs(R:GetDescendants()) do
            if r:IsA("RemoteEvent") and not CFG.IGNORE_REMOTES[r.Name] then
                connect(r.OnClientEvent, function(...)
                    if not gui.Parent or tooChatty(r) then return end
                    local args, texts = table.pack(...), {}
                    for i = 1, args.n do collectTexts(args[i], texts, 0) end
                    local name = r.Name:lower()
                    local text = clean(table.concat(texts, " ")):lower()
                    local list = Seen.list
                    list[#list + 1] = { t = os.clock(), name = name, text = text }
                    if #list > 40 then table.remove(list, 1) end
                    if Raid.running and CFG.DEBUG_TIMER and os.clock() - Raid.startedAt < 15 then
                        local packed = {...}
                        local okJ, txt = pcall(function() return HttpService:JSONEncode(packed) end)
                        print("[PibbleHub] raid: server event", r.Name, okJ and txt or "(not serializable)")
                    end
                    -- fallback end of a raid fight, for when the result does not come through BattleEnd:
                    -- a remote with "raid" in its name and an end-like word (sync / state events never count)
                    if Raid.running and Raid.fightStarted and os.clock() - Raid.startedAt > CFG.RAID_MIN_FIGHT
                        and name:find("raid", 1, true) and not name:find("sync", 1, true) and not name:find("state", 1, true)
                        and not isRefusal(text) then
                        for _, w in ipairs(CFG.RAID_END_EVENTS) do
                            if name:find(w, 1, true) then
                                Raid.fightStarted = false
                                Raid.fightDone = true
                                Raid.fights += 1
                                Raid.lastEndAt = os.clock()
                                print("[PibbleHub] raid: fight end detected from remote " .. r.Name)
                                break
                            end
                        end
                    end
                end)
            end
        end

        -- a server text that refuses the raid (cooldown / already done...) since `since`
        local function refusedText(since)
            for _, e in ipairs(Seen.list) do
                if e.t >= since and isRefusal(e.text) then return e.text end
            end
        end

        -- the fight was accepted: a battle / raid / fight event, that is not a refusal text
        local function accepted(since)
            for _, e in ipairs(Seen.list) do
                if e.t >= since and not isRefusal(e.text) then
                    for _, w in ipairs(CFG.RAID_START_EVENTS) do
                        if e.name:find(w, 1, true) then return true end
                    end
                end
            end
            return false
        end

        -- the game's own start button of the raid (if the raid world shows one)
        local function pressRaidButton()
            local b = findButton(function(t)
                return t == "start" or t == "fight" or t == "begin"
                    or t:find("start raid", 1, true) ~= nil or t:find("start battle", 1, true) ~= nil
                    or t:find("start fight", 1, true) ~= nil
            end)
            if b and shown(b) and activateButton(b) then
                print("[PibbleHub] raid: pressed button", b:GetFullName())
                return true
            end
            return false
        end

        -- Teleports to the raid world and waits until the character has REALLY arrived (it moved), then lets the world settle
        local function goToRaidWorld(r)
            local hrp0 = getHRP()
            local before = hrp0 and hrp0.Position
            Remotes.Teleport:FireServer(r.world or CFG.RAID_WORLD)
            local t0, moved = os.clock(), false
            while os.clock() - t0 < CFG.RAID_TP_TIMEOUT do
                task.wait(0.25)
                local hrp = getHRP()
                if hrp and (not before or (hrp.Position - before).Magnitude > 100) then
                    moved = true
                    break
                end
            end
            if CFG.DEBUG_TIMER then
                print("[PibbleHub] raid " .. r.label .. ": teleport " .. (moved and "done" or "not detected (continuing anyway)")
                    .. " after " .. ("%.1f"):format(os.clock() - t0) .. "s")
            end
            task.wait(CFG.RAID_LOAD_DELAY)
        end

        -- ---- standing next to the raid boss (StartRaidBattle only works when we are close to it) ----
        local function posOf(o)
            if o:IsA("Model") then
                local okP, pv = pcall(function() return o:GetPivot() end)
                return okP and pv or nil
            elseif o:IsA("BasePart") then
                return o.CFrame
            elseif o:IsA("Attachment") then
                return CFrame.new(o.WorldPosition)
            end
        end

        -- A raid boss is an NPC (Humanoid model, e.g. Workspace.NPCs.Yhwach) with an NPCId attribute and a "Talk" prompt.
        -- It is found by its NPCId first, then by model name, then by the billboard text. Portals are never matched.
        -- The closest match wins. The boss found last time is reused (one cache entry per raid).
        local raidBossCache, raidLastScan = {}, {}
        local function normS(x) return (tostring(x):lower():gsub("[^%w]+", "")) end

        local function npcIdOf(m)
            return m:GetAttribute("NPCId") or m:GetAttribute("NpcId") or m:GetAttribute("npcId")
        end

        local function isRaidNPC(m, r)
            if not m:IsA("Model") or Players:GetPlayerFromCharacter(m) then return false end
            if not m:FindFirstChildOfClass("Humanoid") then return false end
            local a = npcIdOf(m)
            if a then
                local na = normS(a)
                if r.npcId and na == normS(r.npcId) then return true end
                if r.key and na:find(r.key, 1, true) then return true end
                if r.genericFallback and na:find("raid", 1, true) then
                    -- an NPC that clearly belongs to ANOTHER raid is never this one
                    local other = false
                    for _, o in ipairs(CFG.RAIDS) do
                        if o ~= r and o.key and na:find(o.key, 1, true) then other = true end
                    end
                    if not other then return true end
                end
            end
            local nn = normS(m.Name)
            for _, w in ipairs(r.names or {}) do
                local nw = normS(w)
                if nw ~= "" and nn == nw then return true end
            end
            return false
        end

        local function findRaidBoss(r)
            if r.pos then return CFrame.new(r.pos), "fixed position" end
            local cached = raidBossCache[r.id]
            if cached and cached.Parent and cached:IsDescendantOf(workspace) then
                local cf0 = posOf(cached)
                if cf0 then return cf0, cached:GetFullName() end
            end
            raidBossCache[r.id] = nil
            if os.clock() - (raidLastScan[r.id] or 0) < 0.5 then return nil end -- at most two full scans per second
            raidLastScan[r.id] = os.clock()

            local hrp = getHRP()
            local best, bestD, bestObj = nil, math.huge, nil
            local function consider(m)
                local cf = posOf(m)
                if not cf then return end
                local d = hrp and (cf.Position - hrp.Position).Magnitude or 0
                if d < bestD then best, bestD, bestObj = cf, d, m end
            end

            -- 1) Workspace.NPCs (fast)
            local npcs = workspace:FindFirstChild("NPCs")
            if npcs then
                for _, m in ipairs(npcs:GetChildren()) do
                    if isRaidNPC(m, r) then consider(m) end
                end
            end
            -- 2) the whole workspace
            if not bestObj then
                for _, d in ipairs(workspace:GetDescendants()) do
                    if d:IsA("Model") and isRaidNPC(d, r) then consider(d) end
                end
            end
            -- 3) billboard text (the boss's name) -> the NPC model that owns it (never a portal)
            if not bestObj then
                for _, d in ipairs(workspace:GetDescendants()) do
                    if d:IsA("TextLabel") then
                        local t = normS(clean(d.Text))
                        for _, w in ipairs(r.names or {}) do
                            if t == normS(w) then
                                local m = d:FindFirstAncestorWhichIsA("Model")
                                if m and m:FindFirstChildOfClass("Humanoid") and not m.Name:lower():find("portal", 1, true) then
                                    consider(m)
                                end
                            end
                        end
                    end
                end
            end

            if bestObj then raidBossCache[r.id] = bestObj end
            return best, bestObj and bestObj:GetFullName() or nil
        end

        -- debug: what is around the player in the raid world, to help find the boss
        local function dumpRaidSurroundings(r)
            local hrp = getHRP()
            if not hrp then return end
            local out = {}
            for _, d in ipairs(workspace:GetDescendants()) do
                if #out >= 20 then break end
                if d:IsA("ProximityPrompt") then
                    local cf = posOf(d.Parent)
                    if cf and (cf.Position - hrp.Position).Magnitude < 400 then
                        out[#out + 1] = "prompt " .. d.Parent:GetFullName() .. " [" .. tostring(d.ActionText) .. "/" .. tostring(d.ObjectText) .. "]"
                    end
                elseif d:IsA("Humanoid") and d.Parent and not Players:GetPlayerFromCharacter(d.Parent) then
                    local cf = posOf(d.Parent)
                    if cf and (cf.Position - hrp.Position).Magnitude < 400 then
                        out[#out + 1] = "npc " .. d.Parent:GetFullName() .. " (NPCId " .. tostring(npcIdOf(d.Parent)) .. ")"
                    end
                end
            end
            print("[PibbleHub] raid " .. r.label .. ": boss not found. Nearby (400 studs): " .. (#out > 0 and table.concat(out, " | ") or "(nothing)"))
            print("[PibbleHub] raid " .. r.label .. ": set npcId / key / names of this raid in CFG.RAIDS to the boss NPC, or pos to a position next to it.")
        end

        -- Teleports next to the raid boss (retries for tries * 0.25 s: the boss may still be streaming in)
        local function tpToRaidBoss(r, tries, dump)
            for _ = 1, tries do
                local hrp = getHRP()
                local cf, what = findRaidBoss(r)
                if hrp and cf then
                    if r.pos then
                        hrp.CFrame = cf
                    else
                        hrp.CFrame = CFrame.new(cf.Position + cf.LookVector * 5 + Vector3.new(0, 2, 0))
                    end
                    if CFG.DEBUG_TIMER and dump then print("[PibbleHub] raid " .. r.label .. ": teleported next to " .. tostring(what)) end
                    task.wait(0.5)
                    return true
                end
                task.wait(0.25)
            end
            if dump then dumpRaidSurroundings(r) end
            return false
        end

        -- presses a ProximityPrompt (fires it, or holds it when the executor has no fireproximityprompt)
        local function firePrompt(prompt)
            if typeof(fireproximityprompt) == "function" then
                pcall(fireproximityprompt, prompt)
            else
                pcall(function()
                    prompt:InputHoldBegin()
                    task.wait((prompt.HoldDuration or 0) + 0.1)
                    prompt:InputHoldEnd()
                end)
            end
        end

        -- Enters the raid through its portal (Workspace.Portals.<portal>): stand on it and press its prompt / touch it.
        -- The portals are in the lobby, so when the portal is not loaded the lobby is visited first.
        local function enterViaPortal(r)
            if not r.portal then return false end
            local function findPortal()
                local folder = workspace:FindFirstChild("Portals")
                return folder and folder:FindFirstChild(r.portal) or nil
            end
            local portal = findPortal()
            if not portal then
                print("[PibbleHub] raid " .. r.label .. ": portal " .. r.portal .. " not loaded, going to the lobby")
                pcall(function() Worlds.go("Lobby") end)
                for _ = 1, 20 do
                    portal = findPortal()
                    if portal then break end
                    task.wait(0.5)
                end
            end
            if not portal then
                print("[PibbleHub] raid " .. r.label .. ": portal " .. r.portal .. " not found in Workspace.Portals")
                return false
            end
            local part = portal:IsA("BasePart") and portal or portal:FindFirstChildWhichIsA("BasePart", true)
            local hrp = getHRP()
            if not (part and hrp) then return false end
            print("[PibbleHub] raid " .. r.label .. ": entering through " .. portal:GetFullName())
            hrp.CFrame = part.CFrame + Vector3.new(0, 3, 0)
            task.wait(0.4)
            local prompt = portal:FindFirstChildWhichIsA("ProximityPrompt", true)
            if prompt then
                firePrompt(prompt)
            elseif typeof(firetouchinterest) == "function" then
                pcall(firetouchinterest, hrp, part, 0)
                task.wait(0.1)
                pcall(firetouchinterest, hrp, part, 1)
            end
            -- wait for the teleport (the character moves away from the portal) and for the world to load
            local t0 = os.clock()
            while os.clock() - t0 < CFG.RAID_TP_TIMEOUT do
                task.wait(0.25)
                local h = getHRP()
                if h and (h.Position - part.Position).Magnitude > 100 then break end
            end
            task.wait(CFG.RAID_LOAD_DELAY)
            return true
        end

        -- debug button: prints what the game has for the raids (portals, boss NPCs) to the F9 console
        local function scanRaids()
            print("[PibbleHub] ---- raid scan ----")
            local portals = workspace:FindFirstChild("Portals")
            if portals then
                for _, p in ipairs(portals:GetChildren()) do
                    if p.Name:lower():find("raid", 1, true) then
                        local attrs = {}
                        for k, v in pairs(p:GetAttributes()) do attrs[#attrs + 1] = k .. "=" .. tostring(v) end
                        table.sort(attrs)
                        local pr = p:FindFirstChildWhichIsA("ProximityPrompt", true)
                        local td = p:FindFirstChildWhichIsA("TouchTransmitter", true)
                        print("[PibbleHub] portal " .. p:GetFullName() .. " | prompt: " .. (pr and (tostring(pr.ActionText) .. "/" .. tostring(pr.ObjectText)) or "none")
                            .. " | touch: " .. tostring(td ~= nil) .. " | " .. table.concat(attrs, ", "))
                    end
                end
            else
                print("[PibbleHub] no Workspace.Portals here (the raid portals are in the lobby)")
            end
            local count = 0
            for _, d in ipairs(workspace:GetDescendants()) do
                if count >= 30 then break end
                if d:IsA("Model") and d:FindFirstChildOfClass("Humanoid") and not Players:GetPlayerFromCharacter(d) then
                    local id = npcIdOf(d)
                    if (id and normS(id):find("raid", 1, true)) or normS(d.Name):find("raid", 1, true) then
                        count += 1
                        local pr = d:FindFirstChildWhichIsA("ProximityPrompt", true)
                        print("[PibbleHub] npc " .. d:GetFullName() .. " | NPCId " .. tostring(id)
                            .. " | prompt: " .. (pr and tostring(pr.ActionText) or "none"))
                    end
                end
            end
            for _, r in ipairs(CFG.RAIDS) do
                raidBossCache[r.id], raidLastScan[r.id] = nil, 0
                local _, what = findRaidBoss(r)
                print("[PibbleHub] raid " .. r.label .. " boss: " .. tostring(what or "NOT FOUND in this world"))
            end
            print("[PibbleHub] ---- end of scan (go to each raid world and press the button there too) ----")
        end

        -- the Fight button of the game's own RaidGui (not the one of the BattleDummyGui)
        local function pressRaidGuiFight()
            local pg = player:FindFirstChild("PlayerGui")
            local rg = pg and pg:FindFirstChild("RaidGui")
            local b = rg and rg:FindFirstChild("FightButton", true)
            if b and activateButton(b) then
                print("[PibbleHub] raid: pressed RaidGui fight button")
                return true
            end
            return false
        end

        -- talks to the raid boss (its "Talk" prompt) to open the RaidGui
        local function talkToRaidBoss(r)
            local m = raidBossCache[r.id]
            local prompt = m and m:FindFirstChildWhichIsA("ProximityPrompt", true)
            if not prompt then return false end
            firePrompt(prompt)
            task.wait(0.6)
            return true
        end

        -- Fires StartRaidBattle until the server reacts. Try 1: remote only. Try 2+: talk to the boss and press
        -- the RaidGui Fight button too. Try 3: also any generic start button.
        -- index = number of the fight (1-4). Only fight 1 can be "refused": for fights 2-4 a refusal text is
        -- a late message of the previous fight and is ignored, and more tries are made.
        -- Returns true when the server accepted the fight.
        -- Which arguments StartRaidBattle gets on a given try: the raid's own startArgs when set; otherwise nothing
        -- (how the first raid works) and, for the other raids, the raid id on the 2nd try.
        local function startArgs(r, attempt)
            if r.startArgs then return r.startArgs end
            if r.id ~= "soul_king" and attempt == 2 then return { r.id } end
            return {}
        end

        local function launchFight(r, index)
            local tries = (index == 1) and CFG.RAID_START_TRIES or (CFG.RAID_START_TRIES + 3)
            local loggedRefusal = false
            for attempt = 1, tries do
                tpToRaidBoss(r, 8, attempt == 1 and index == 1) -- stay next to the boss (it may have moved / we may have respawned)
                local t = os.clock()
                Raid.startedAt = t
                if attempt >= 2 then
                    talkToRaidBoss(r)
                    pressRaidGuiFight()
                end
                Remotes.StartRaid:FireServer(table.unpack(startArgs(r, attempt)))
                if attempt >= 3 then pressRaidButton() end
                while os.clock() - t < CFG.RAID_START_CHECK do
                    if Raid.fightDone then return true end
                    -- a "refusal" text never stops the raid: the fights are always attempted,
                    -- the cooldown timer is only read AFTER them
                    local why = refusedText(t)
                    if why and not loggedRefusal then
                        loggedRefusal = true
                        print("[PibbleHub] raid " .. r.label .. ": server text ignored (fight " .. index .. "): " .. why)
                    end
                    if accepted(t) then return true end
                    task.wait(0.2)
                end
                print(("[PibbleHub] raid %s: no server reaction (fight %d, try %d/%d)"):format(r.label, index, attempt, tries))
                if index > 1 then task.wait(2) end
            end
            return false, "silent"
        end

        -- "4:32", "1:02:10", "5m 30s" ... -> seconds (nil when the text holds no time)
        local TIME_UNITS = {
            h = 3600, hr = 3600, hrs = 3600, hour = 3600, hours = 3600,
            m = 60, min = 60, mins = 60, minute = 60, minutes = 60,
            s = 1, sec = 1, secs = 1, second = 1, seconds = 1,
        }
        local function parseSecs(text)
            local h, m, s = text:match("(%d+):(%d+):(%d+)")
            if h then return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) end
            m, s = text:match("(%d+):(%d+)")
            if m then return tonumber(m) * 60 + tonumber(s) end
            local total, found = 0, false
            for n, u in text:gmatch("(%d+)%s*(%a+)") do
                local mult = TIME_UNITS[u]
                if mult then
                    total += tonumber(n) * mult
                    found = true
                end
            end
            return found and total or nil
        end

        -- Reads the raid cooldown AFTER the fights: a server text (since `since`) or a visible text of the
        -- interface with a cooldown-like word and a time. Returns seconds, or nil when nothing is shown.
        local function readRaidCooldown(since)
            for _, e in ipairs(Seen.list) do
                if e.t >= since and e.text ~= "" and (isRefusal(e.text) or e.text:find("cool", 1, true)) then
                    local secs = parseSecs(e.text)
                    if secs and secs > 0 then return secs end
                end
            end
            local pg = player:FindFirstChild("PlayerGui")
            if pg then
                for _, d in ipairs(pg:GetDescendants()) do
                    if (d:IsA("TextLabel") or d:IsA("TextButton")) and not d:IsDescendantOf(gui) and shown(d) then
                        local t = clean(d.Text):lower()
                        if t ~= "" and (t:find("cooldown", 1, true) or t:find("cool down", 1, true)
                            or t:find("available in", 1, true) or t:find("come back", 1, true)) then
                            local secs = parseSecs(t)
                            if secs and secs > 0 then return secs end
                        end
                    end
                end
            end
            return nil
        end

        -- One raid: get to its boss and fight RAID_FIGHTS times. Returns the number of fights finished in this slot.
        local function doRaid(r, manual)
            Raid.current = r
            local tag = "Raid " .. r.label
            local function stopped() return not manual and (not Raid.auto or not Raid.enabled[r.id] or not inWindow(r)) end

            -- already next to the boss? then no teleport
            local cf0 = findRaidBoss(r)
            local hrpN = getHRP()
            if cf0 and hrpN and (cf0.Position - hrpN.Position).Magnitude < CFG.RAID_NEAR then
                statusL.Text = tag .. ": already there"
            else
                statusL.Text = tag .. ": teleporting"
                goToRaidWorld(r)
            end
            statusL.Text = tag .. ": going to boss"
            local bossFound = tpToRaidBoss(r, 40, false)
            if not bossFound then
                -- not in the world we landed in: enter through the raid's portal
                statusL.Text = tag .. ": entering through the portal"
                enterViaPortal(r)
                bossFound = tpToRaidBoss(r, 40, true)
            end
            if not bossFound then
                statusL.Text = tag .. ": boss not found (see F9)"
                if not r.fightAnyway then return countFor(r).n end -- tried again by Auto
            end

            local c = countFor(r)
            for i = c.n + 1, CFG.RAID_FIGHTS do
                if stopped() then break end
                Raid.fightDone = false
                Raid.fightStarted = true
                statusL.Text = ("%s: starting fight %d/%d"):format(tag, i, CFG.RAID_FIGHTS)
                local okFight = launchFight(r, i)
                if not okFight then
                    -- no recognised reaction from the server: the fight is assumed to have started anyway
                    -- (the game may answer with an event name we do not know). We wait for its end like any other.
                    print("[PibbleHub] raid " .. r.label .. ": fight " .. i .. " not confirmed by the server, assuming it started and waiting for its end."
                        .. " (If the game does answer, add a word of that remote's name to CFG.RAID_START_EVENTS.)")
                    Raid.fightStarted = true
                end
                statusL.Text = ("%s: fight %d/%d"):format(tag, i, CFG.RAID_FIGHTS)

                -- wait for the end of the fight (BattleEnd), or the timeout, or the end of the window
                local t = os.clock()
                local finished = false
                while os.clock() - t < CFG.RAID_FIGHT_TIMEOUT do
                    if Raid.fightDone then finished = true break end
                    if stopped() then break end
                    task.wait(0.25)
                end
                if not finished and os.clock() - t >= CFG.RAID_FIGHT_TIMEOUT then
                    finished = true -- timeout: the fight is considered over, go on
                    print("[PibbleHub] raid " .. r.label .. ": fight " .. i .. " timeout (no BattleEnd received)")
                end
                Raid.fightStarted = false
                if finished then
                    c.n = i
                    if i >= CFG.RAID_FIGHTS and Raid.slotsDone[r.id] ~= slotOf(r) then
                        Raid.slotsDone[r.id] = slotOf(r) -- all the fights are done: one raid per slot (saved)
                        Settings.save()
                    end
                end
                task.wait(CFG.RAID_FIGHT_DELAY)
            end
            return c.n
        end

        -- manual = true: "Start now" / "Go" button, ignores the window and the Auto switch.
        -- only = one raid of CFG.RAIDS (the "Go" button of its row); nil = every raid that is switched on, one after the other.
        local function run(manual, only)
            if Raid.running then return end
            local list = {}
            if only then
                list[1] = only
            else
                for _, r in ipairs(CFG.RAIDS) do
                    if Raid.enabled[r.id] and (manual or inWindow(r)) and not isDone(r) then list[#list + 1] = r end
                end
            end
            if #list == 0 then
                if manual then statusL.Text = "Raid: nothing to do (switched off or already done)" end
                return
            end
            if not manual then
                local by = Prio.blockedBy("Raid")
                if by then
                    statusL.Text = ("Raid: waiting (%s first)"):format(Prio.label(by))
                    return
                end
            end
            if not (Remotes.StartRaid and Remotes.Teleport) then
                statusL.Text = "Raid: remote not found"
                return
            end
            Raid.running = true -- from now on every other automation is paused
            -- (a raid's slot is only marked as done once all its fights are done: a failed attempt is retried by Auto)
            Raid.fights = 0
            Raid.fightStarted = false
            Raid.fightDone = false

            -- the world boss gives way to the raid (it comes back right after, see below)
            if WorldBoss.leave then pcall(WorldBoss.leave, { noTeleport = true, why = "raid" }) end

            -- a running dungeon is left first (the raid teleport below takes us out of it anyway)
            if Dungeon.afkOff then pcall(Dungeon.afkOff) end
            if Dungeon.leave then Dungeon.leave({ noTeleport = true, why = "raid" }) end

            -- let a running boss fight finish first (they are not started again meanwhile)
            local t0 = os.clock()
            while (Boss.active or WorldBoss.active) and os.clock() - t0 < CFG.RAID_WAIT_OTHERS do
                statusL.Text = "Raid: waiting for current action"
                task.wait(0.5)
            end

            local results = {}
            for _, r in ipairs(list) do
                if not manual and not Raid.auto then break end
                local n = doRaid(r, manual)
                results[#results + 1] = ("%s %d/%d"):format(r.label, n, CFG.RAID_FIGHTS)
            end

            Raid.fightStarted = false
            Raid.running = false
            Raid.current = nil
            -- the fights are over: NOW read the cooldown timer the game shows / sends
            local cd = readRaidCooldown(t0)
            statusL.Text = ("Raid: done (%s)%s"):format(table.concat(results, ", "),
                cd and (" | cooldown " .. mmss(cd)) or "")
            if cd then print("[PibbleHub] raid: cooldown after the fights: " .. cd .. "s") end

            -- resume what was paused: tower and boss queue restart by themselves,
            -- otherwise (no auto mode is active) go back to the lobby
            task.spawn(function()
                task.wait(1)
                -- everything that is switched on gets its turn back, in the user's priority order
                -- (nothing to resume: back to the lobby)
                if not Prio.resumeAll() then
                    Worlds.go("Lobby")
                end
            end)
        end

        local function setAuto(on)
            Raid.auto = on
            autoBtn.Text = on and "Auto: ON" or "Auto: OFF"
            autoBtn.BackgroundColor3 = on and GREEN or RED
            Settings.save()
        end
        Raid.setAuto = setAuto
        -- a raid is "open" while Auto Raid is ON and at least one raid that is switched on has its window open and is not done yet
        Raid.isOpen = function()
            if not Raid.auto then return false end
            for _, r in ipairs(CFG.RAIDS) do
                if isOpenRaid(r) then return true end
            end
            return false
        end

        startBtn.MouseButton1Click:Connect(function() task.spawn(run, true) end)
        autoBtn.MouseButton1Click:Connect(function() setAuto(not Raid.auto) end)
        scanBtn.MouseButton1Click:Connect(function() task.spawn(scanRaids) end)

        -- the rows: switch of each raid + "Go" (that raid only, right now)
        local function refreshRows()
            for _, row in ipairs(raidRows) do
                local r = row.raid
                local on = Raid.enabled[r.id] == true
                local state = isDone(r) and "done" or (inWindow(r) and "open" or "waiting")
                row.toggle.Text = ("%s: %s%s"):format(r.label, on and "ON" or "OFF", on and (" (" .. state .. ")") or "")
                row.toggle.BackgroundColor3 = on and GREEN or DARK
            end
        end
        for _, row in ipairs(raidRows) do
            local r = row.raid
            row.toggle.MouseButton1Click:Connect(function()
                Raid.enabled[r.id] = not Raid.enabled[r.id]
                Settings.save()
                refreshRows()
            end)
            row.go.MouseButton1Click:Connect(function() task.spawn(run, true, r) end)
        end
        refreshRows()

        -- called by the BattleEnd router, BEFORE the other handlers: returns true when the result is a raid fight
        Raid.onBattleEnd = function(data)
            -- duplicate of a fight end we just handled (e.g. through the remote fallback): swallow it
            if Raid.running and not Raid.fightStarted and os.clock() - (Raid.lastEndAt or 0) < 5 then return true end
            if not (Raid.running and Raid.fightStarted) then return false end
            -- a dungeon result is never a raid fight
            if (tostring(data.mode or "") .. " " .. tostring(data.tower or "")):lower():find("dungeon", 1, true) then return false end
            -- a result of the Halloween Tower is never a raid fight
            if data.tower == "halloween" and data.mode == "infinite_room" then return false end
            -- results of the Infinite Tower (mode "tower") are never raid fights either
            if data.mode == "tower" then return false end
            if os.clock() - Raid.startedAt < CFG.RAID_MIN_FIGHT then
                logEnd("raid (ignored, stale)", data)
                return true
            end
            Raid.fightStarted = false
            Raid.fightDone = true
            Raid.fights += 1
            Raid.lastEndAt = os.clock()
            logEnd("raid", data)
            return true
        end

        -- every second: timer + start of the raids at the beginning of each slot
        -- (if a raid could not start / was interrupted, Auto tries again every RAID_RETRY_EVERY seconds during the window)
        local lastTry = -1e9
        task.spawn(function()
            while gui.Parent do
                task.wait(1)
                refreshRows()

                -- timer: the open window that ends first, or else the next one that opens
                local openLeft, nextIn, anyOpen = nil, nil, false
                for _, r in ipairs(CFG.RAIDS) do
                    if Raid.enabled[r.id] then
                        if inWindow(r) then
                            local left = windowOf(r) - intoSlot(r)
                            if not isDone(r) then
                                anyOpen = true
                                openLeft = openLeft and math.min(openLeft, left) or left
                            end
                        else
                            local untilOpen = intervalOf(r) - intoSlot(r)
                            nextIn = nextIn and math.min(nextIn, untilOpen) or untilOpen
                        end
                    end
                end
                if openLeft then
                    timerL.Text = "Raid window: " .. mmss(openLeft) .. " left"
                elseif nextIn then
                    timerL.Text = "Next raid in: " .. mmss(nextIn)
                else
                    timerL.Text = "No raid switched on"
                end

                if Raid.auto and not Raid.running and anyOpen then
                    local by = Prio.blockedBy("Raid")
                    if by then
                        -- something the user ranked higher goes first: try again as soon as it is out of the way
                        statusL.Text = ("Raid: waiting (%s first)"):format(Prio.label(by))
                    elseif os.clock() - lastTry > CFG.RAID_RETRY_EVERY then
                        lastTry = os.clock()
                        task.spawn(run, false)
                    end
                end
            end
        end)
    end)

    -- =====================================================================
    -- == 11c. FEATURE: AUTO DUNGEON
    -- =====================================================================
    -- Enters the dungeon by talking to Workspace.NPCs.DungeonNPC ("Marine Dungeon") and pressing "CONTINUE LAST RUN"
    -- (a remote named *dungeon* + start/enter/join is tried first if one exists). It is left with Exit -> SAVE & LEAVE.
    -- While a dungeon is running, Boss are paused.
    --  * when the raid opens (Auto Raid ON, window open, raid not done yet) the dungeon is LEFT and not restarted
    --  * once the raid is over the dungeon starts again by itself
    -- The remotes of the game are not known: every server event of a *dungeon* remote is printed in F9
    -- ("dungeon: server event ...") so the CFG.DUNGEON_* settings can be adjusted if the auto-detection is wrong.
    safeFeature("Auto Dungeon", function()
        featureTab("Auto Dungeon", 676)
        label("Auto Dungeon", 676, ORANGE)
        local statusL = label("Dungeon: idle", 696)
        local startBtn = button("Start now", 10, 722, 105, 28, BLUE)
        local autoBtn = button("Auto: OFF", 125, 722, 115, 28, RED)

        -- ---- server events of the dungeon remotes ----
        local Seen = { list = {} } -- {t = os.clock(), name = lowercase remote name, text = lowercase json}
        local lastSeenExit = 0   -- os.clock() of the last sign that we are inside the dungeon (Exit button, dungeon event / fight)
        local leaving = false    -- the leave sequence is running (AFK must stay OFF)

        local function textOfBtn(b)
            if b:IsA("TextButton") then return clean(b.Text):lower() end
            for _, c in ipairs(b:GetDescendants()) do
                if c:IsA("TextLabel") and clean(c.Text):match("%S") then return clean(c.Text):lower() end
            end
            return ""
        end

        -- the AFK toggle of the dungeon ("AFK: ON" / "AFK: OFF"): returns the button and whether it is ON
        local function afkButton()
            local b = findButton(function(t) return t:find("^%s*afk%s*:") ~= nil end)
            if b and shown(b) then
                local t = textOfBtn(b)
                return b, (t:find("off", 1, true) == nil and t:find("on", 1, true) ~= nil)
            end
        end

        -- puts the AFK toggle in the wanted state (the dungeon cannot be left while AFK is ON)
        local function setAfk(want)
            for _ = 1, 3 do
                local b, on = afkButton()
                if not b then return false end
                if on == want then return true end
                activateButton(b)
                task.wait(0.5)
            end
            local b, on = afkButton()
            return b ~= nil and on == want
        end

        local function finish(why)
            if not Dungeon.active then return end
            Dungeon.active = false
            leaving = false
            Dungeon.lastEnd = os.clock()
            statusL.Text = "Dungeon: " .. why
            -- give the paused features their turn back (during a raid, the raid resumes everything itself)
            task.spawn(function()
                task.wait(1.5)
                if Raid.running or Dungeon.active or WorldBoss.active then return end
                if Boss.auto and Boss.resume then Boss.resume() end
            end)
        end

        local dungeonRemotes = {}
        for _, r in ipairs(R:GetDescendants()) do
            if r:IsA("RemoteEvent") and r.Name:lower():find("dungeon", 1, true) then
                dungeonRemotes[#dungeonRemotes + 1] = r.Name
                connect(r.OnClientEvent, function(...)
                    if not gui.Parent or tooChatty(r) then return end
                    local args = {...}
                    local okJ, txt = pcall(function() return HttpService:JSONEncode(args) end)
                    txt = (okJ and txt or "(not serializable)"):lower()
                    local name = r.Name:lower()
                    local list = Seen.list
                    list[#list + 1] = { t = os.clock(), name = name, text = txt }
                    if #list > 40 then table.remove(list, 1) end
                    if CFG.DEBUG_TIMER then print("[PibbleHub] dungeon: server event", r.Name, txt:sub(1, 300)) end
                    -- server events only prove we are still inside: they NEVER end the dungeon.
                    -- The only ways out are: manual leave (detected below), the raid, or the Stop of Auto.
                    if Dungeon.active then lastSeenExit = os.clock() end
                end)
            end
        end
        print("[PibbleHub] dungeon remotes found: " .. (#dungeonRemotes > 0 and table.concat(dungeonRemotes, ", ") or "(none)"))

        -- a remote called *dungeon* whose name contains one of the words (or the exact name from the CFG)
        local function pickRemote(exact, words)
            if exact ~= "" then
                local r = R:FindFirstChild(exact, true)
                if r then return r end
            end
            for _, r in ipairs(R:GetDescendants()) do
                if r:IsA("RemoteEvent") then
                    local n = r.Name:lower()
                    if n:find("dungeon", 1, true) then
                        for _, w in ipairs(words) do
                            if n:find(w, 1, true) then return r end
                        end
                    end
                end
            end
        end

        local function pivotOf(o)
            if o:IsA("Model") then
                local okP, pv = pcall(function() return o:GetPivot() end)
                return okP and pv or nil
            elseif o:IsA("BasePart") then
                return o.CFrame
            end
        end

        -- ---- the dungeon NPC (Workspace.NPCs.DungeonNPC) ----
        local lastNpcScan = -1e9
        local function dungeonNPC(cheap)
            local npcs = workspace:FindFirstChild("NPCs")
            local m = npcs and npcs:FindFirstChild(CFG.DUNGEON_NPC)
            if m then return m end
            if cheap and os.clock() - lastNpcScan < 20 then return nil end -- the periodic check scans the workspace at most every 20 s
            lastNpcScan = os.clock()
            for _, p in ipairs(workspace:GetDescendants()) do
                if p:IsA("ProximityPrompt") and tostring(p.ObjectText):lower():find("dungeon", 1, true) then
                    return p:FindFirstAncestorWhichIsA("Model") or p.Parent
                end
            end
        end

        -- teleports next to the NPC (goes to the lobby first when the NPC is not loaded)
        local function goToNPC()
            local askedLobby = false
            for i = 1, 60 do
                if Raid.running then return nil end
                local npc = dungeonNPC()
                local hrp = getHRP()
                local cf = npc and pivotOf(npc)
                if npc and hrp and cf then
                    hrp.CFrame = CFrame.new(cf.Position + cf.LookVector * 5 + Vector3.new(0, 2, 0))
                    task.wait(0.5)
                    return npc
                end
                if not npc and not askedLobby and i >= 4 and Remotes.Teleport then
                    askedLobby = true
                    statusL.Text = "Dungeon: going to lobby"
                    Remotes.Teleport:FireServer("lobby")
                end
                task.wait(0.25)
            end
            return nil
        end

        -- did the server react (a dungeon event) or did the character move (teleported inside)?
        local function waitAccepted(since, before)
            local t0 = os.clock()
            while os.clock() - t0 < CFG.DUNGEON_START_CHECK do
                if Raid.running then return false end
                for _, e in ipairs(Seen.list) do
                    if e.t >= since then return true end
                end
                local hrp = getHRP()
                if hrp and before and (hrp.Position - before).Magnitude > 100 then return true end
                task.wait(0.25)
            end
            return false
        end

        local function startViaRemote()
            local r = pickRemote(CFG.DUNGEON_START_REMOTE, {"start", "enter", "join", "begin", "queue"})
            if not r then return false end
            local hrp0 = getHRP()
            local since = os.clock()
            print("[PibbleHub] dungeon: firing remote " .. r.Name)
            r:FireServer(table.unpack(CFG.DUNGEON_ARGS))
            return waitAccepted(since, hrp0 and hrp0.Position)
        end

        -- ---- closing the Marine Dungeon window (red X) ----
        -- The window stays open when a run is already in progress ("Run in progress at stage 122. Exit it to start a new one")
        -- and blocks everything: it is closed with its red X, or hidden as a last resort.
        local hiddenDungeonGui

        local function dungeonDialogGui()
            local pg = player:FindFirstChild("PlayerGui")
            if not pg then return nil end
            for _, d in ipairs(pg:GetDescendants()) do
                if d:IsA("TextLabel") and not d:IsDescendantOf(gui) and shown(d) then
                    local t = clean(d.Text):lower()
                    if t:find("marine dungeon", 1, true) or t:find("run in progress", 1, true)
                        or t:find("dungeon berries", 1, true) then
                        return d:FindFirstAncestorWhichIsA("ScreenGui")
                    end
                end
            end
            return nil
        end

        local function waitDungeonDialogClosed(maxT)
            local t0 = os.clock()
            repeat
                if not dungeonDialogGui() then return true end
                task.wait(0.15)
            until os.clock() - t0 > maxT
            return false
        end

        local CLOSE_TEXTS = { x = true, ["×"] = true, ["✕"] = true, ["✖"] = true, close = true }
        local function closeDungeonDialog()
            local sg = dungeonDialogGui()
            if not sg then return true end
            -- 1) the red X of the window
            for _, b in ipairs(sg:GetDescendants()) do
                if (b:IsA("TextButton") or b:IsA("ImageButton")) and shown(b) then
                    local n = b.Name:lower()
                    local t = b:IsA("TextButton") and clean(b.Text):lower():match("^%s*(.-)%s*$") or ""
                    if CLOSE_TEXTS[t] or n == "x" or n:find("close", 1, true) then
                        print("[PibbleHub] dungeon: closing the window with " .. b:GetFullName())
                        activateButton(b)
                        if waitDungeonDialogClosed(1) then return true end
                    end
                end
            end
            -- 2) last resort: hide the window (given back before the next talk to the NPC)
            print("[PibbleHub] dungeon: X button not found, hiding the window (" .. sg.Name .. ")")
            sg.Enabled = false
            hiddenDungeonGui = sg
            return waitDungeonDialogClosed(1)
        end

        local function startViaNPC()
            if hiddenDungeonGui then -- give back a window we hid last time, so the game can open it again
                pcall(function() hiddenDungeonGui.Enabled = true end)
                hiddenDungeonGui = nil
            end
            local npc = goToNPC()
            if not npc then return false end
            local prompt = npc:FindFirstChildWhichIsA("ProximityPrompt", true)
            if not prompt then
                print("[PibbleHub] dungeon: no prompt on " .. npc:GetFullName())
                return false
            end
            local hrp0 = getHRP()
            local since = os.clock()
            if typeof(fireproximityprompt) == "function" then
                pcall(fireproximityprompt, prompt)
            else
                pcall(function()
                    prompt:InputHoldBegin()
                    task.wait((prompt.HoldDuration or 0) + 0.1)
                    prompt:InputHoldEnd()
                end)
            end
            task.wait(0.8)
            -- debug: what the dialog shows
            if CFG.DEBUG_TIMER then
                local pg = player:FindFirstChild("PlayerGui")
                local out = {}
                if pg then
                    for _, b in ipairs(pg:GetDescendants()) do
                        if #out >= 15 then break end
                        if b:IsA("TextButton") and not b:IsDescendantOf(gui) and shown(b) and clean(b.Text):match("%S") then
                            out[#out + 1] = clean(b.Text)
                        end
                    end
                end
                print("[PibbleHub] dungeon: buttons after talking: " .. (#out > 0 and table.concat(out, " | ") or "(none)"))
            end
            -- the dialog shows a blue button "CONTINUE LAST RUN - STAGE 34 (3 LIVES)" (stage / lives change): wait for it, press it
            local b
            local t1 = os.clock()
            while os.clock() - t1 < 4 and not b do
                b = findButton(function(t) return t:find("continue last run", 1, true) ~= nil end)
                if b and not shown(b) then b = nil end
                if not b then task.wait(0.25) end
            end
            if not b then -- fallback: a "new run" / start button
                b = findButton(function(t)
                    return t:find("new run", 1, true) ~= nil or t:find("start run", 1, true) ~= nil
                        or t:find("start dungeon", 1, true) ~= nil or t:find("enter dungeon", 1, true) ~= nil
                end)
                if b and not shown(b) then b = nil end
            end
            if b then
                print("[PibbleHub] dungeon: pressed " .. btnText(b) .. " (" .. b:GetFullName() .. ")")
                activateButton(b)
            else
                print("[PibbleHub] dungeon: no start button found after talking to the NPC (run already in progress?) -> closing the window")
                closeDungeonDialog()
            end
            local okAcc = waitAccepted(since, hrp0 and hrp0.Position)
            -- the window must never stay open: close it whatever happened
            task.wait(0.3)
            closeDungeonDialog()
            return okAcc
        end

        local function startDungeon()
            for round = 1, CFG.DUNGEON_START_TRIES do
                if Raid.running then return false end
                statusL.Text = ("Dungeon: starting (%d/%d)"):format(round, CFG.DUNGEON_START_TRIES)
                if startViaRemote() then return true end
                if Raid.running then return false end
                if startViaNPC() then return true end
            end
            return false
        end

        -- ---- leaving ----
        -- opts.noTeleport = true: the caller teleports somewhere else right after (the raid does)
        local function leave(opts)
            opts = opts or {}
            if not Dungeon.active then return end
            statusL.Text = "Dungeon: leaving"
            leaving = true
            local done = false
            -- 0) the dungeon cannot be left while AFK is ON: turn it OFF first
            if setAfk(false) then
                print("[PibbleHub] dungeon: AFK turned OFF")
            else
                print("[PibbleHub] dungeon: AFK button not found / still ON (continuing anyway)")
            end
            -- 1) the game's own way: the "Exit" button (X), then "SAVE & LEAVE"
            local ex = findButton(function(t) return t == "exit" end)
            if ex and shown(ex) and activateButton(ex) then
                print("[PibbleHub] dungeon: pressed Exit " .. ex:GetFullName())
                local sl
                local t1 = os.clock()
                while os.clock() - t1 < 3 and not sl do
                    task.wait(0.25)
                    sl = findButton(function(t) return t:find("save", 1, true) ~= nil and t:find("leave", 1, true) ~= nil end)
                    if sl and not shown(sl) then sl = nil end
                end
                if sl and activateButton(sl) then
                    print("[PibbleHub] dungeon: pressed Save & Leave " .. sl:GetFullName())
                    done = true
                    task.wait(0.8)
                else
                    print("[PibbleHub] dungeon: Save & Leave button not found after Exit")
                end
            else
                print("[PibbleHub] dungeon: Exit button not found")
            end
            -- 2) fallbacks: a leave remote, then the lobby teleport
            if not done then
                local r = pickRemote(CFG.DUNGEON_LEAVE_REMOTE, {"leave", "exit", "quit", "abandon", "forfeit", "giveup"})
                if r then
                    print("[PibbleHub] dungeon: firing remote " .. r.Name)
                    r:FireServer(table.unpack(CFG.DUNGEON_LEAVE_ARGS))
                    task.wait(0.5)
                end
                if not opts.noTeleport and Remotes.Teleport then
                    Remotes.Teleport:FireServer("lobby")
                end
            end
            finish(opts.why and ("left (" .. opts.why .. ")") or "left")
        end
        Dungeon.leave = leave
        -- used by Auto Raid: AFK OFF whatever the state of the script (the raid teleport / Exit need it OFF)
        Dungeon.afkOff = function() return setAfk(false) end

        -- ---- one dungeon run ----
        local function runOnce()
            if Dungeon.active or Raid.running or WorldBoss.active then return end
            Dungeon.active = true -- from now on Boss leave the player alone
            Dungeon.startedAt = os.clock()
            if Raid.running then
                Dungeon.active = false
                return
            end
            if startDungeon() then
                Dungeon.startedAt = os.clock()
                lastSeenExit = os.clock()
                leaving = false
                statusL.Text = "Dungeon: running"
                -- once inside, turn AFK ON (the button shows up after the teleport / loading)
                task.spawn(function()
                    for _ = 1, 15 do
                        if not Dungeon.active or leaving then return end
                        local b, on = afkButton()
                        if b then
                            if not on then
                                setAfk(true)
                                print("[PibbleHub] dungeon: AFK turned ON")
                            end
                            return
                        end
                        task.wait(1)
                    end
                end)
            else
                Dungeon.active = false
                Dungeon.lastEnd = os.clock()
                if not Raid.running then
                    statusL.Text = "Dungeon: could not start (see F9)"
                    closeDungeonDialog()
                    print("[PibbleHub] dungeon: could not start. Look at the 'dungeon: server event' / 'buttons after talking' lines,"
                        .. " then set CFG.DUNGEON_START_REMOTE / CFG.DUNGEON_ARGS.")
                    if Boss.auto and Boss.resume then Boss.resume() end
                end
            end
        end

        -- called by Auto Raid once the raid is over
        Dungeon.resume = function()
            Dungeon.lastEnd = -1e9 -- no cooldown: start again right away
        end

        local function setAuto(on)
            Dungeon.auto = on
            autoBtn.Text = on and "Auto: ON" or "Auto: OFF"
            autoBtn.BackgroundColor3 = on and GREEN or RED
            Settings.save()
        end
        Dungeon.setAuto = setAuto

        startBtn.MouseButton1Click:Connect(function() task.spawn(runOnce) end)
        autoBtn.MouseButton1Click:Connect(function()
            setAuto(not Dungeon.auto)
            -- turning Auto ON starts the dungeon right away, without any check (cooldown, boss, raid window).
            -- Only a raid in progress or a dungeon already running prevents it (runOnce checks that itself).
            if Dungeon.auto then
                Dungeon.lastEnd = -1e9
                task.spawn(runOnce)
            end
        end)

        -- called by the BattleEnd router: returns true for the results of a dungeon fight
        Dungeon.onBattleEnd = function(data)
            local m = (tostring(data.mode or "") .. " " .. tostring(data.tower or "")):lower()
            if not m:find("dungeon", 1, true) then return false end
            logEnd("dungeon", data)
            -- a dungeon fight result never ends the run (the dungeon goes on stage after stage)
            if Dungeon.active then lastSeenExit = os.clock() end
            return true
        end

        -- every 2 s: timeout of a running dungeon + automatic start
        local lastLeftCheck = -1e9
        task.spawn(function()
            while gui.Parent do
                task.wait(2)
                if Dungeon.active then
                    if CFG.DUNGEON_TIMEOUT > 0 and not Raid.running and os.clock() - Dungeon.startedAt > CFG.DUNGEON_TIMEOUT then
                        leave({ why = "timeout" })
                    elseif not leaving and not Raid.running and os.clock() - Dungeon.startedAt > 15
                        and os.clock() - lastLeftCheck >= 6 then
                        lastLeftCheck = os.clock() -- (the check scans the interface: every 6 s is enough)
                        -- did we leave the dungeon by hand? (no Exit button for a while, or back next to the dungeon NPC)
                        local ex = findButton(function(t) return t == "exit" end)
                        if ex and shown(ex) then lastSeenExit = os.clock() end
                        local npc = dungeonNPC(true)
                        local hrp, cf = getHRP(), nil
                        if npc then cf = pivotOf(npc) end
                        local nearNpc = hrp and cf and (cf.Position - hrp.Position).Magnitude < CFG.DUNGEON_NEAR_NPC
                        if nearNpc or os.clock() - lastSeenExit > CFG.DUNGEON_GONE_AFTER then
                            print("[PibbleHub] dungeon: left manually (" .. (nearNpc and "next to the NPC" or "no Exit button") .. ")")
                            finish("left manually")
                        else
                            -- still inside: keep AFK ON
                            local b, on = afkButton()
                            if b and not on then setAfk(true) end
                        end
                    end
                elseif Dungeon.auto and not Raid.running and not WorldBoss.active then
                    local by = Prio.blockedBy("Dungeon")
                    if by then
                        statusL.Text = ("Dungeon: waiting (%s first)"):format(Prio.label(by))
                    elseif Boss.active or Portal.active then
                        statusL.Text = "Dungeon: waiting (" .. (Boss.active and "boss" or "portal") .. ")"
                    elseif os.clock() - Dungeon.lastEnd >= CFG.DUNGEON_COOLDOWN then
                        task.spawn(runOnce)
                    end
                end
            end
        end)
    end)

    -- =====================================================================
    -- == 11d. FEATURE: AUTO WORLD BOSS
    -- =====================================================================
    -- The world boss (Berserk Creation = Workspace.WorldBossArena.CellMax) is up for 1 hour, then gone for 1 hour
    -- (real clock, even UTC hours: 22:00-23:00 UTC = 2-3pm PST). One run:
    --   1) stand at Workspace.WorldBossPortal and press its "Travel" prompt (E) -> we land in the arena
    --   2) stand in front of CellMax: its window (PlayerGui.WorldBossGui) opens
    --   3) switch "Repeat" ON (it always starts OFF), then press FIGHT! once -> the game repeats the fight by itself
    --   4) at the end of the window (or when the banner is gone): Repeat OFF, leave the arena
    -- Priority: Raid > World Boss > Dungeon / Boss / Pop. The raid takes the player out of the arena and the world
    -- boss comes back after it (if its window is still open).
    safeFeature("Auto World Boss", function()
        featureTab("World Boss", 782)
        label("World Boss", 782, ORANGE)
        local statusL = label("World Boss: idle", 802)
        local timerL = label("Next window: -", 822)
        local startBtn = button("Start now", 10, 848, 105, 28, BLUE)
        local autoBtn = button("Auto: OFF", 125, 848, 115, 28, RED)
        label("Up 1 h / gone 1 h (even UTC hours)", 884, MUTED, 12)

        local stopReq = false        -- set by leave() / Stop: the running attempt ends as soon as possible
        local leaveNoTeleport = false -- the caller (the raid) teleports somewhere else right after
        local lastActivity = 0       -- os.clock() of the last sign that the fight goes on

        -- ---- clock ----
        local function intoSlot() return (os.time() - CFG.WB_OFFSET) % CFG.WB_INTERVAL end
        local function inWindow() return intoSlot() < CFG.WB_WINDOW end
        local function windowOk() return intoSlot() < CFG.WB_WINDOW - CFG.WB_LEAVE_MARGIN end
        local function mmss(s)
            s = math.max(0, math.floor(s))
            if s >= 3600 then return ("%dh %02dm"):format(s // 3600, (s % 3600) // 60) end
            return ("%dm %02ds"):format(s // 60, s % 60)
        end

        -- ---- things in the game ----
        local function pgui() return player:FindFirstChild("PlayerGui") end
        local function guiOf(name)
            local pg = pgui()
            return pg and pg:FindFirstChild(name)
        end
        local function portalModel() return workspace:FindFirstChild(CFG.WB_PORTAL) end
        local function bossModel()
            local a = workspace:FindFirstChild(CFG.WB_ARENA)
            return a and a:FindFirstChild(CFG.WB_BOSS)
        end
        local function cfOf(m)
            if not m then return nil end
            if m:IsA("BasePart") then return m.CFrame end
            local ok, cf = pcall(function() return m:GetPivot() end)
            return ok and cf or nil
        end
        local function inArena()
            local hrp, cf = getHRP(), cfOf(bossModel())
            return hrp ~= nil and cf ~= nil and (cf.Position - hrp.Position).Magnitude < CFG.WB_ARENA_NEAR
        end

        -- "LEAVES xx:xx" is shown while the boss is up: on the top banner, or (while the World Boss window is open and
        -- the game hides the banner) on the window itself ("LEAVES IN"). Unknown guis = we trust the clock.
        local lastLive = os.clock()
        local function bannerLive()
            if not CFG.WB_NEED_BANNER then return true end
            local bg, wg = guiOf(CFG.WB_BANNER), guiOf(CFG.WB_GUI)
            if not bg and not wg then return true end
            for _, root in ipairs({bg or false, wg or false}) do
                if root then
                    for _, d in ipairs(root:GetDescendants()) do
                        if d:IsA("TextLabel") and shown(d) and clean(d.Text):lower():find("leaves", 1, true) then return true end
                    end
                end
            end
            return false
        end

        -- ---- server meter ("0 / 10M" on the banner and in the window) ----
        local function amountOf(num, suf)
            local n = tonumber((num:gsub(",", "")))
            if not n then return nil end
            local m = ({k = 1e3, m = 1e6, b = 1e9})[(suf or ""):lower()] or 1
            return n * m
        end
        -- the biggest "cur / max" found in the two guis (the medal labels "2M", "4M"... have no slash and are ignored)
        local function readMeter()
            local best
            for _, root in ipairs({guiOf(CFG.WB_BANNER) or false, guiOf(CFG.WB_GUI) or false}) do
                if root then
                    for _, d in ipairs(root:GetDescendants()) do
                        if d:IsA("TextLabel") and shown(d) then
                            local c, cs, m, ms = clean(d.Text):match("([%d%.,]+)%s*([KkMmBb]?)%s*/%s*([%d%.,]+)%s*([KkMmBb]?)")
                            if c then
                                local cur, max = amountOf(c, cs), amountOf(m, ms)
                                if cur and max and max >= 1e5 and (not best or max > best[2]) then best = {cur, max} end
                            end
                        end
                    end
                end
            end
            return best
        end
        local function slotNo() return math.floor((os.time() - CFG.WB_OFFSET) / CFG.WB_INTERVAL) end
        local meterSlot, lastMeterCheck, lastMeterLog = nil, 0, 0
        -- true once the meter of this boss is full (remembered until the next slot); read at most every 1.5 s
        local function checkMeter()
            if not CFG.WB_STOP_AT_FULL then return false end
            if meterSlot == slotNo() then return true end
            if os.clock() - lastMeterCheck >= 1.5 then
                lastMeterCheck = os.clock()
                local m = readMeter()
                if m and m[1] >= m[2] then
                    meterSlot = slotNo()
                    print(("[PibbleHub] world boss: server meter full (%s / %s)"):format(tostring(m[1]), tostring(m[2])))
                    return true
                end
            end
            return false
        end

        -- during a run the text may be missing for a moment (banner hidden, window closing): only a missing text for
        -- WB_BANNER_GRACE seconds in a row ends the run
        local function liveOk()
            if bannerLive() then
                lastLive = os.clock()
                return true
            end
            return WorldBoss.active and os.clock() - lastLive < CFG.WB_BANNER_GRACE
        end

        -- the first button of WorldBossGui (or of `root`) whose text matches pred
        local function wbButton(pred, root)
            root = root or guiOf(CFG.WB_GUI)
            if not root then return nil end
            local hidden
            for _, d in ipairs(root:GetDescendants()) do
                if pred(btnText(d)) then
                    local b = d
                    if not (b:IsA("TextButton") or b:IsA("ImageButton")) then
                        b = d:FindFirstAncestorWhichIsA("TextButton") or d:FindFirstAncestorWhichIsA("ImageButton")
                    end
                    if b then
                        if shown(b) then return b end
                        hidden = hidden or b
                    end
                end
            end
            return hidden
        end
        local function fightButton() return wbButton(function(t) return t == "fight!" end) end

        -- "Repeat: Off" / "Repeat: On": true / false (nil = the window is not there)
        local function repeatState()
            local wg = guiOf(CFG.WB_GUI)
            if not wg then return nil end
            for _, d in ipairs(wg:GetDescendants()) do
                if d:IsA("TextButton") or d:IsA("TextLabel") then
                    local s = clean(d.Text):lower():match("^repeat:%s*(%a+)")
                    if s then return s == "on" end
                end
            end
            return nil
        end

        -- anything visible in WorldBossStopRepeatGui = the game is repeating
        local function stopGuiShown()
            local sg = guiOf(CFG.WB_STOP_GUI)
            if not sg then return false end
            for _, d in ipairs(sg:GetDescendants()) do
                if (d:IsA("TextButton") or d:IsA("TextLabel")) and shown(d) and clean(d.Text) ~= "" then return true end
            end
            return false
        end

        -- ---- input helpers ----
        local function press(prompt)
            if not prompt then return false end
            if typeof(fireproximityprompt) == "function" then
                return pcall(fireproximityprompt, prompt)
            end
            return pcall(function()
                prompt:InputHoldBegin()
                task.wait((prompt.HoldDuration or 0) + 0.1)
                prompt:InputHoldEnd()
            end)
        end

        local function physicalClick(control)
            return pcall(function()
                local vim = game:GetService("VirtualInputManager")
                local sg = control:FindFirstAncestorWhichIsA("ScreenGui")
                local inset = (sg and sg.IgnoreGuiInset) and Vector2.new(0, 0) or game:GetService("GuiService"):GetGuiInset()
                local p = control.AbsolutePosition + control.AbsoluteSize / 2 + inset
                vim:SendMouseButtonEvent(p.X, p.Y, 0, true, game, 1)
                task.wait(0.05)
                vim:SendMouseButtonEvent(p.X, p.Y, 0, false, game, 1)
                releaseInput()
            end)
        end

        -- runs in its own thread (the game's handler may yield); never blocks for more than 0.5 s
        local function click(control)
            if not control then return false end
            local done, result = false, false
            task.spawn(function()
                local ok, r = pcall(function()
                    if typeof(getconnections) == "function" then
                        for _, signal in ipairs({control.Activated, control.MouseButton1Click}) do
                            local ok2, fired = pcall(function()
                                local cons = getconnections(signal)
                                for _, c in ipairs(cons) do c:Fire() end
                                return #cons > 0
                            end)
                            if ok2 and fired then return true end
                        end
                    end
                    return activateButton(control) or physicalClick(control)
                end)
                result = ok and r or false
                done = true
            end)
            local t = os.clock()
            while not done and os.clock() - t < 0.5 do task.wait(0.05) end
            if not done then return true end
            return result
        end

        -- ---- should the attempt go on? ----
        local function wanted(manual)
            if stopReq or not gui.Parent or Raid.running then return false end
            if checkMeter() then return false end
            if manual then return true end
            return WorldBoss.auto and windowOk() and liveOk()
        end

        -- ---- step 1: the portal ----
        local function enterArena(manual)
            if inArena() then return true end
            local function portalPos()
                local cf = cfOf(portalModel())
                return cf and cf.Position
            end
            -- coming from another world: the portal is in the lobby
            local hrp, pp = getHRP(), portalPos()
            if hrp and pp and (pp - hrp.Position).Magnitude > CFG.WB_PORTAL_NEAR then
                statusL.Text = "World Boss: going to the lobby"
                Worlds.go("Lobby")
                local t = os.clock()
                while wanted(manual) and os.clock() - t < 25 do
                    hrp, pp = getHRP(), portalPos()
                    if hrp and pp and (pp - hrp.Position).Magnitude <= CFG.WB_PORTAL_NEAR then break end
                    task.wait(0.5)
                end
                task.wait(CFG.WB_LOAD_DELAY)
            end
            for attempt = 1, CFG.WB_ENTER_TRIES do
                if not wanted(manual) then return false end
                local pm = portalModel()
                local prompt = pm and pm:FindFirstChildWhichIsA("ProximityPrompt", true)
                hrp = getHRP()
                if not (hrp and prompt) then
                    statusL.Text = "World Boss: portal not found"
                    print("[PibbleHub] world boss: Workspace." .. CFG.WB_PORTAL .. " or its prompt was not found")
                    task.wait(2)
                else
                    local part = prompt.Parent
                    local pos = (part and part:IsA("BasePart")) and part.Position or (cfOf(pm) and cfOf(pm).Position)
                    if pos then
                        hrp.CFrame = CFrame.new(pos + Vector3.new(0, 3, 5))
                        task.wait(0.4)
                    end
                    statusL.Text = ("World Boss: entering (%d/%d)"):format(attempt, CFG.WB_ENTER_TRIES)
                    press(prompt)
                    local t = os.clock()
                    while os.clock() - t < CFG.WB_ENTER_CHECK do
                        if inArena() then
                            task.wait(CFG.WB_LOAD_DELAY)
                            return true
                        end
                        if not wanted(manual) then return false end
                        task.wait(0.4)
                    end
                end
            end
            return false
        end

        -- ---- step 2: CellMax and its window ----
        local function standAtBoss()
            local cf, hrp = cfOf(bossModel()), getHRP()
            if not (cf and hrp) then return false end
            local pos = cf.Position + cf.LookVector * CFG.WB_STAND_DIST + Vector3.new(0, 2, 0)
            hrp.CFrame = CFrame.lookAt(pos, Vector3.new(cf.Position.X, pos.Y, cf.Position.Z))
            return true
        end

        local function openWindow(manual)
            for attempt = 1, 3 do
                if not wanted(manual) then return false end
                standAtBoss()
                local t = os.clock()
                while os.clock() - t < CFG.WB_UI_CHECK do
                    local b = fightButton()
                    if b and shown(b) then return true end
                    task.wait(0.25)
                end
                -- the window did not open by itself: talk to / click the boss
                local m = bossModel()
                local prompt = m and m:FindFirstChildWhichIsA("ProximityPrompt", true)
                if prompt then press(prompt) end
                local cd = m and m:FindFirstChildWhichIsA("ClickDetector", true)
                if cd and typeof(fireclickdetector) == "function" then pcall(fireclickdetector, cd) end
                task.wait(0.8)
            end
            local b = fightButton()
            return b ~= nil and shown(b)
        end

        -- ---- step 3: Repeat ON, FIGHT! once ----
        local function setRepeat(on)
            for _ = 1, 4 do
                if repeatState() == on then return true end
                local b = wbButton(function(t) return t:find("^repeat:") ~= nil end)
                if not b then return false end
                click(b)
                task.wait(0.5)
            end
            return repeatState() == on
        end

        local function startFight(manual)
            for attempt = 1, CFG.WB_START_TRIES do
                if not wanted(manual) then return false end
                local b = fightButton()
                if not (b and shown(b)) then
                    -- the window is gone: either the fight already started, or it closed
                    return true
                end
                statusL.Text = ("World Boss: FIGHT! (%d/%d)"):format(attempt, CFG.WB_START_TRIES)
                local t0 = os.clock()
                click(b)
                while os.clock() - t0 < CFG.WB_START_CHECK do
                    local fb = fightButton()
                    if stopGuiShown() or lastActivity >= t0 or not (fb and shown(fb)) then return true end
                    task.wait(0.3)
                end
            end
            print("[PibbleHub] world boss: no sign that the fight started after FIGHT! (see the BattleEnd lines in F9)")
            return true -- assume it did: the monitor restarts the steps if nothing happens
        end

        -- ---- step 4: leaving ----
        local function stopRepeatNow()
            pcall(function()
                local sg = guiOf(CFG.WB_STOP_GUI)
                local b = sg and wbButton(function(t) return t:find("stop", 1, true) ~= nil end, sg)
                if b and shown(b) then
                    click(b)
                    print("[PibbleHub] world boss: pressed the stop-repeat button")
                    task.wait(0.4)
                end
                if repeatState() == true then setRepeat(false) end
            end)
        end

        -- ---- one pass: enter, open, repeat ON, fight, then watch ----
        local function cycle(manual)
            statusL.Text = "World Boss: going to the portal"
            if not enterArena(manual) then return false end
            if not wanted(manual) then return true end
            statusL.Text = "World Boss: walking to CellMax"
            if not openWindow(manual) then
                print("[PibbleHub] world boss: the window of CellMax did not open (stand closer? check CFG.WB_STAND_DIST)")
                return false
            end
            if not setRepeat(true) then
                print("[PibbleHub] world boss: could not switch Repeat ON (continuing)")
            end
            if not startFight(manual) then return true end
            lastActivity = os.clock()
            -- watch
            while wanted(manual) do
                task.wait(1)
                if not inArena() then
                    print("[PibbleHub] world boss: we are not in the arena any more, entering again")
                    return true
                end
                if stopGuiShown() then lastActivity = os.clock() end
                statusL.Text = ("World Boss: fighting | %s left"):format(mmss(CFG.WB_WINDOW - intoSlot()))
                if os.clock() - lastActivity > CFG.WB_IDLE_RESTART then
                    print("[PibbleHub] world boss: no sign of fighting for " .. CFG.WB_IDLE_RESTART .. "s, redoing the steps")
                    return true
                end
            end
            return true
        end

        -- manual = true: "Start now" button, ignores the window and the Auto switch (the boss must really be up)
        local function run(manual)
            if WorldBoss.active or Raid.running then return end
            if not manual then
                local by = Prio.blockedBy("WorldBoss")
                if by then
                    statusL.Text = ("World Boss: waiting (%s first)"):format(Prio.label(by))
                    return
                end
            end
            WorldBoss.active = true -- from now on every other automation is paused
            lastLive = os.clock()
            WorldBoss.startedAt = os.clock()
            stopReq = false
            leaveNoTeleport = false
            startBtn.Text = "Stop"
            local okRun, err = pcall(function()
                if Dungeon.afkOff then pcall(Dungeon.afkOff) end
                if Dungeon.active and Dungeon.leave then pcall(Dungeon.leave, { why = "world boss" }) end
                local t0 = os.clock()
                while Boss.active and os.clock() - t0 < CFG.WB_WAIT_OTHERS and wanted(manual) do
                    statusL.Text = "World Boss: waiting for current action"
                    task.wait(0.5)
                end
                local fails = 0
                while wanted(manual) do
                    if cycle(manual) then fails = 0 else fails += 1 end
                    if fails >= CFG.WB_MAX_FAILS then
                        statusL.Text = "World Boss: could not start (see F9)"
                        break
                    end
                    if wanted(manual) then task.wait(CFG.WB_CYCLE_DELAY) end
                end
            end)
            if not okRun then warn("[PibbleHub] world boss error:", err) end

            local inside = inArena()
            if inside and not leaveNoTeleport then
                statusL.Text = "World Boss: stopping repeat"
                stopRepeatNow()
            end
            local why = leaveNoTeleport and "raid" or (checkMeter() and "server meter full") or (inWindow() and "stopped" or "window over")
            WorldBoss.active = false
            startBtn.Text = "Start now"
            statusL.Text = "World Boss: done (" .. why .. ")"
            lastActivity = 0

            -- the raid teleports by itself and calls WorldBoss.resume afterwards; otherwise go back to what was paused
            if not leaveNoTeleport and not Raid.running then
                task.spawn(function()
                    task.wait(1)
                    if Raid.running or WorldBoss.active then return end
                    if Boss.auto and Boss.resume then
                        Boss.resume()
                    elseif not Dungeon.auto or inside then
                        Worlds.go("Lobby")
                    end
                    if Dungeon.auto and Dungeon.resume then Dungeon.resume() end
                end)
            end
        end

        local function setAuto(on)
            WorldBoss.auto = on
            autoBtn.Text = on and "Auto: ON" or "Auto: OFF"
            autoBtn.BackgroundColor3 = on and GREEN or RED
            if not on then stopReq = true end
            Settings.save()
        end
        WorldBoss.setAuto = setAuto

        WorldBoss.wantsRun = function()
            return WorldBoss.auto and not WorldBoss.active and windowOk() and not checkMeter() and bannerLive()
        end

        -- used by Auto Raid: ends the attempt (noTeleport = the raid teleports right after)
        WorldBoss.leave = function(opts)
            opts = opts or {}
            if not WorldBoss.active then return end
            if opts.noTeleport then leaveNoTeleport = true end
            stopReq = true
        end

        -- used by Auto Raid once the raid is over
        WorldBoss.resume = function()
            if WorldBoss.wantsRun() then task.spawn(run, false) end
        end

        startBtn.MouseButton1Click:Connect(function()
            if WorldBoss.active then
                WorldBoss.leave({})
            else
                task.spawn(run, true)
            end
        end)
        autoBtn.MouseButton1Click:Connect(function()
            setAuto(not WorldBoss.auto)
            if WorldBoss.auto and WorldBoss.wantsRun() and not Prio.blockedBy("WorldBoss") then
                task.spawn(run, false)
            end
        end)

        -- called by the BattleEnd router: results of the fights inside the arena (the mode name is printed to F9)
        local seenEnds = 0
        WorldBoss.onBattleEnd = function(data)
            if not WorldBoss.active or data.mode == "tower" then return false end
            if (tostring(data.mode or "") .. " " .. tostring(data.tower or "")):lower():find("dungeon", 1, true) then return false end
            if not inArena() then return false end
            lastActivity = os.clock()
            seenEnds += 1
            if seenEnds <= 5 or seenEnds % 25 == 0 then logEnd("world boss #" .. seenEnds, data) end
            return true
        end

        -- every second: timer + automatic start at the beginning of each window
        local lastTry = -1e9
        task.spawn(function()
            while gui.Parent do
                task.wait(1)
                if inWindow() then
                    timerL.Text = "Boss window: " .. mmss(CFG.WB_WINDOW - intoSlot()) .. " left"
                else
                    timerL.Text = "Next window in: " .. mmss(CFG.WB_INTERVAL - intoSlot())
                end
                if WorldBoss.auto and not WorldBoss.active and not Raid.running then
                    if WorldBoss.wantsRun() then
                        local by = Prio.blockedBy("WorldBoss")
                        if by then
                            statusL.Text = ("World Boss: waiting (%s first)"):format(Prio.label(by))
                        elseif Portal.active then
                            statusL.Text = "World Boss: waiting (portal)"
                        elseif os.clock() - lastTry > CFG.WB_RETRY_EVERY then
                            lastTry = os.clock()
                            task.spawn(run, false)
                        end
                    elseif inWindow() and checkMeter() then
                        statusL.Text = "World Boss: server meter full, waiting for the next boss"
                    elseif not inWindow() then
                        statusL.Text = "World Boss: waiting for the next window"
                    elseif not bannerLive() then
                        statusL.Text = "World Boss: window open, boss banner not shown"
                    end
                end
            end
        end)
    end)

    -- =====================================================================
    -- == 11e. FEATURE: PRIORITY (the user sets the order of the automations)
    -- =====================================================================
    -- The list decides who gets the player first (rules: section 4b). Up / Dn move a feature, Reset restores the default order.
    safeFeature("Priority", function()
        local TOP = 900
        featureTab("Priority", TOP)
        label("Priority", TOP, ORANGE)

        local function note(text, y, h)
            local l = label(text, y, MUTED, 13)
            l.Size = UDim2.fromOffset(286, h)
            l.TextWrapped = true
            l.TextTruncate = Enum.TextTruncate.None
            l.TextYAlignment = Enum.TextYAlignment.Top
            return l
        end
        -- small text cell at an exact x position / width
        local function cell(x, y, w, color, size, align)
            local l = label("", y, color, size)
            l.Position = UDim2.fromOffset(x, y - featureOffset)
            l.Size = UDim2.fromOffset(w, 20)
            l.TextXAlignment = align or Enum.TextXAlignment.Left
            return l
        end

        note("Top of the list goes first. A feature waits while one ranked above it is running or ready.", TOP + 22, 42)

        local ROW_Y, ROW_H = TOP + 76, 40
        local rows = {}
        for i = 1, #Prio.DEFAULT do
            local y = ROW_Y + (i - 1) * ROW_H
            local row = {
                rank = cell(10, y + 8, 22, MUTED, 15),
                name = cell(34, y + 8, 114, TEXT, 16),
                state = cell(148, y + 8, 82, MUTED, 13, Enum.TextXAlignment.Right),
                up = button("Up", 236, y + 3, 30, 30, DARK),
                down = button("Dn", 270, y + 3, 30, 30, DARK),
            }
            row.up.TextSize, row.down.TextSize = 13, 13
            rows[i] = row
        end

        local function refresh()
            for i, row in ipairs(rows) do
                row.rank.Text = i .. "."
                row.name.Text = Prio.label(Prio.order[i])
                row.up.BackgroundColor3 = i == 1 and PANEL2 or DARK
                row.down.BackgroundColor3 = i == #rows and PANEL2 or DARK
            end
        end

        for i, row in ipairs(rows) do
            row.up.MouseButton1Click:Connect(function()
                if Prio.move(i, -1) then refresh() end
            end)
            row.down.MouseButton1Click:Connect(function()
                if Prio.move(i, 1) then refresh() end
            end)
        end

        local resetBtn = button("Reset to default", 10, ROW_Y + #rows * ROW_H + 8, 150, 28, RED)
        resetBtn.MouseButton1Click:Connect(function()
            Prio.reset()
            refresh()
        end)

        note("Raid and World Boss are timed: they interrupt a dungeon or world boss ranked below them, "
            .. "and wait for a boss fight or portal to finish. Anything ranked above them delays them while it is running or ready.",
            ROW_Y + #rows * ROW_H + 44, 84)

        refresh()

        -- live state of every feature (running / ready = waiting for its turn / armed = switched on / off)
        task.spawn(function()
            while gui.Parent do
                for i, row in ipairs(rows) do
                    local name = Prio.order[i]
                    local text, color = "off", OFFC
                    if Prio.running(name) then
                        text, color = "running", GREEN
                    else
                        local okW, w = pcall(Prio.wants, name)
                        if okW and w then
                            text, color = "ready", ORANGE
                        elseif Prio.enabled(name) then
                            text, color = "armed", BLUE
                        end
                    end
                    row.state.Text = text
                    row.state.TextColor3 = color
                end
                task.wait(0.5)
            end
        end)
    end)

    -- =====================================================================
    -- == 11f. FEATURE: SETTINGS TAB (UI scale)
    -- =====================================================================
    safeFeature("Settings", function()
        local TOP = 1100
        featureTab("Settings", TOP)
        label("Settings", TOP, ORANGE)

        local function sectionTitle(text, y)
            local l = label(text, y, MUTED, 11)
            l.Size = UDim2.fromOffset(200, 16)
            return l
        end

        sectionTitle("UI SCALE", TOP + 30)

        local minus = button("-", 10, TOP + 50, 44, 34, DARK)
        local plus = button("+", 252, TOP + 50, 44, 34, DARK)
        minus.TextSize, plus.TextSize = 22, 20
        local valueL = label("100%", TOP + 57, TEXT, 20)
        valueL.Position = UDim2.fromOffset(60, TOP + 57 - featureOffset)
        valueL.Size = UDim2.fromOffset(186, 24)
        valueL.TextXAlignment = Enum.TextXAlignment.Center

        -- quick presets
        local PRESETS = {0.75, 0.9, 1, 1.25, 1.5}
        local presetBtns = {}
        for i, v in ipairs(PRESETS) do
            local b = button(math.floor(v * 100 + 0.5) .. "%", 10 + (i - 1) * 58, TOP + 94, 54, 28, DARK)
            b.TextSize = 13
            presetBtns[i] = b
            b.Activated:Connect(function()
                if UI.apply then UI.apply(v) end
                -- refreshed below
            end)
        end

        local function refresh()
            valueL.Text = math.floor(UI.scale * 100 + 0.5) .. "%"
            for i, v in ipairs(PRESETS) do
                local on = math.abs(UI.scale - v) < 0.001
                presetBtns[i].BackgroundColor3 = on and BLUE or DARK
            end
            minus.BackgroundColor3 = UI.scale <= UI.MIN + 0.001 and PANEL2 or DARK
            plus.BackgroundColor3 = UI.scale >= UI.MAX - 0.001 and PANEL2 or DARK
        end

        minus.Activated:Connect(function() if UI.apply then UI.apply(UI.scale - 0.05) end end)
        plus.Activated:Connect(function() if UI.apply then UI.apply(UI.scale + 0.05) end end)
        -- every change (buttons, presets, a loaded setting) updates the display
        task.spawn(function()
            local last
            while gui.Parent do
                if UI.scale ~= last then
                    last = UI.scale
                    refresh()
                end
                task.wait(0.1)
            end
        end)
        refresh()

        local n = label("Scales the whole window (60% - 160%). The round P button keeps its size. The scale is saved.",
            TOP + 132, MUTED, 13)
        n.Size = UDim2.fromOffset(286, 54)
        n.TextWrapped = true
        n.TextTruncate = Enum.TextTruncate.None
        n.TextYAlignment = Enum.TextYAlignment.Top

        sectionTitle("WINDOW", TOP + 200)
        local centerBtn = button("Center window", 10, TOP + 220, 140, 30, DARK)
        centerBtn.Activated:Connect(function() win.Position = UDim2.fromScale(0.5, 0.5) end)
        local resetBtn = button("Reset scale", 156, TOP + 220, 140, 30, DARK)
        resetBtn.Activated:Connect(function() if UI.apply then UI.apply(1) end end)

        local themeNote
        -- if a game button (inventory, Use x10, Give Up, world menu) ever stops answering: switch the buttons of those windows back on
        local fixBtn = button("Fix game buttons", 10, TOP + 256, 286, 30, DARK)
        fixBtn.Activated:Connect(function()
            releaseInput() -- also lets go of a mouse button / key that may be stuck "held"
            local pg = player:FindFirstChildOfClass("PlayerGui")
            if not pg then return end
            local roots = {}
            local itemGui = pg:FindFirstChild("ItemGui")
            if itemGui then roots[#roots + 1] = itemGui end
            for _, word in ipairs({"give up", "worlds", "world", "islands"}) do
                local b = findButton(function(t) return t == word or t:find(word, 1, true) == 1 end)
                local sg = b and b:FindFirstAncestorWhichIsA("ScreenGui")
                if sg then roots[#roots + 1] = sg end
            end
            local n = 0
            for _, r in ipairs(roots) do
                for _, d in ipairs(r:GetDescendants()) do
                    if d:IsA("GuiButton") and not d:IsDescendantOf(gui) then
                        pcall(function()
                            if not d.Active or d.Interactable == false then n += 1 end
                            d.Active = true
                            d.Interactable = true
                        end)
                    end
                end
            end
            fixBtn.Text = ("Fixed %d buttons"):format(n)
            task.delay(2, function() fixBtn.Text = "Fix game buttons" end)
        end)

        -- writes the structure of the inventory window + the HUD buttons to F9, the clipboard and a file
        local scanInvBtn = button("Scan inventory UI (copy)", 10, TOP + 290, 286, 30, DARK)
        scanInvBtn.TextSize = 13
        scanInvBtn.Activated:Connect(function()
            local out = {}
            local pg = player:FindFirstChildOfClass("PlayerGui")
            local function line(t) out[#out + 1] = t end
            local function info(d, depth)
                local extra = ""
                if d:IsA("GuiObject") then
                    extra = (" vis=%s pos=(%d,%d) size=(%d,%d)"):format(tostring(d.Visible), d.AbsolutePosition.X, d.AbsolutePosition.Y, d.AbsoluteSize.X, d.AbsoluteSize.Y)
                    if d:IsA("GuiButton") then extra = extra .. " active=" .. tostring(d.Active) .. " inter=" .. tostring(d.Interactable) end
                    if d:IsA("TextButton") or d:IsA("TextLabel") then extra = extra .. ' text="' .. clean(d.Text) .. '"' end
                elseif d:IsA("ScreenGui") then
                    extra = " enabled=" .. tostring(d.Enabled)
                end
                line(string.rep("  ", depth) .. d.ClassName .. " " .. d.Name .. extra)
            end
            local item = pg and pg:FindFirstChild("ItemGui")
            line("== ItemGui ==")
            if item then
                local n = 0
                local function walk(d, depth)
                    if n > 140 or depth > 5 then return end
                    n += 1
                    info(d, depth)
                    for _, c in ipairs(d:GetChildren()) do
                        if not (d.Name == "ItemGrid" and depth >= 3) then walk(c, depth + 1) end
                    end
                end
                walk(item, 0)
            else
                line("(no ItemGui)")
            end
            line("== buttons that could open the inventory (outside ItemGui) ==")
            if pg then
                for _, d in ipairs(pg:GetDescendants()) do
                    if d:IsA("GuiButton") and not d:IsDescendantOf(gui) and not (item and d:IsDescendantOf(item)) and shown(d) then
                        local n = d.Name:lower()
                        if n:find("inv") or n:find("item") or n:find("bag") or n:find("menu") or d.AbsolutePosition.Y < 90 then info(d, 0) end
                    end
                end
            end
            local txt = table.concat(out, "\n")
            print("[PibbleHub] inventory scan:\n" .. txt)
            pcall(function() if setclipboard then setclipboard(txt) end end)
            pcall(function() if writefile then writefile("PibbleHub_inventory_scan.txt", txt) end end)
            scanInvBtn.Text = "Copied (" .. #out .. " lines)"
            task.delay(2.5, function() scanInvBtn.Text = "Scan inventory UI (copy)" end)
        end)

        sectionTitle("THEME", TOP + 340)
        local themeBtns = {}
        local function refreshThemes()
            for i, b in ipairs(themeBtns) do
                local on = THEMES[i].name == Settings.theme
                b.Text = (on and "● " or "") .. THEMES[i].name
            end
        end
        for i, t in ipairs(THEMES) do
            local b = button(t.name, 10 + ((i - 1) % 3) * 98, TOP + 360 + ((i - 1) // 3) * 34, 94, 30, t.PANEL2)
            b.TextSize = 13
            b.TextColor3 = t.ACCENT
            themeBtns[i] = b
            b.Activated:Connect(function()
                Settings.theme = t.name
                Settings.save()
                refreshThemes()
                themeNote.Text = t.name .. " saved. Re-run the script to apply it."
            end)
        end
        themeNote = label("", TOP + 432, MUTED, 13)
        themeNote.Size = UDim2.fromOffset(286, 34)
        themeNote.TextWrapped = true
        themeNote.TextTruncate = Enum.TextTruncate.None
        themeNote.TextYAlignment = Enum.TextYAlignment.Top
        refreshThemes()
    end)

    -- =====================================================================
    -- == 11g. FEATURE: GENERATIONS WEBHOOK (Infinite Tower results window -> Discord)
    -- =====================================================================
    -- Every time the Infinite Tower results window (PlayerGui.TowerResultGui.ResultFrame, "Generated") shows a new
    -- set of cards, one Discord message is posted to its OWN webhook: floor / weather / luck / border / cards total,
    -- the best cards with their pictures, and a ping when a card reaches the "good" value the user typed.
    -- Cards are read from ResultFrame.CardGrid: every visible Frame with an ImageLabel is a card, its "x2" label is
    -- the count and its "85B" label the value (found by the text pattern, not by name). Only the page on screen is read.
    safeFeature("Generations", function()
        local TOP = 1300
        featureTab("Generations", TOP)
        label("Generations", TOP, ORANGE)
        local statusL = label("Idle", TOP + 22, MUTED, 13)
        local G = Settings.gen

        -- ---- amounts like 1b, 2.5t, 1qa ----
        local SUFFIX = {}
        for i, sfx in ipairs(CFG.GEN_SUFFIXES) do SUFFIX[sfx:lower()] = 1000 ^ i end

        local function parseAbbrev(text)
            local s = (tostring(text or ""):lower():gsub(",", ""):gsub("%s+", ""))
            if s == "" or s:match("^x%d+$") then return nil end
            local num, suf = s:match("([%d%.]+)(%a*)$")
            num = tonumber(num)
            if not num then return nil end
            if suf == "" then return num end
            local mult = SUFFIX[suf]
            return mult and num * mult or nil
        end

        local function validHook(u)
            u = tostring(u or "")
            return u:match("^https://discord%.com/api/webhooks/%d+/[%w_%-]+") ~= nil
                or u:match("^https://discordapp%.com/api/webhooks/%d+/[%w_%-]+") ~= nil
                or u:match("^https://canary%.discord%.com/api/webhooks/%d+/[%w_%-]+") ~= nil
        end

        local function requestFn()
            return (syn and syn.request) or (http and http.request) or http_request or request or (fluxus and fluxus.request)
        end

        -- ---- the results window ----
        local function findWindow()
            local pg = player:FindFirstChildOfClass("PlayerGui")
            local g = pg and pg:FindFirstChild("TowerResultGui")
            local frame = g and g:FindFirstChild("ResultFrame")
            local grid = frame and frame:FindFirstChild("CardGrid")
            local generating = g and g:FindFirstChild("GeneratingFrame")
            return frame, grid, generating
        end

        local function windowUp()
            local frame, grid, generating = findWindow()
            if not (frame and grid) or not shown(frame) or not shown(grid) then return false end
            if generating and shown(generating) then return false end -- still generating the cards
            return true
        end

        -- the card outline colour -> border name. Gold and Normal are confirmed; add the others here as "RRGGBB"
        -- once you know them (the post shows the hex of an unknown one in brackets).
        local BORDER_COLORS = { FFFFFF = "Normal", F6C90E = "Gold", ["60A5FA"] = "Universal" }
        -- any other colour is sorted by its hue: blue = Universal, red = Infernal
        local function nameByColor(c)
            local hex = ("%02X%02X%02X"):format(math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
            if BORDER_COLORS[hex] then return BORDER_COLORS[hex] end
            local h, sat = Color3.toHSV(c)
            if sat > 0.35 then
                if h < 0.05 or h > 0.93 then return "Infernal" end
                if h > 0.5 and h < 0.72 then return "Universal" end
            end
            return "(" .. hex .. ")"
        end
        local function borderName(f)
            for _, d in ipairs(f:GetDescendants()) do
                if d:IsA("UIStroke") and d.Enabled then
                    local grad = d:FindFirstChildOfClass("UIGradient")
                    if grad then
                        -- a gradient outline: a wide hue spread = Rainbow, anything else is shown by its first colour
                        local hmin, hmax = 1, 0
                        for _, k in ipairs(grad.Color.Keypoints) do
                            local h = Color3.toHSV(k.Value)
                            hmin, hmax = math.min(hmin, h), math.max(hmax, h)
                        end
                        if hmax - hmin > 0.5 then return "Rainbow" end
                        return nameByColor(grad.Color.Keypoints[1].Value)
                    end
                    return nameByColor(d.Color)
                end
            end
            return nil
        end

        local function readCards(grid)
            local cards = {}
            for _, f in ipairs(grid:GetChildren()) do
                if f:IsA("Frame") and shown(f) then
                    local img = f:FindFirstChildWhichIsA("ImageLabel")
                    if img and tostring(img.Image) ~= "" then
                        local card = { image = tostring(img.Image), count = 1, value = 0, valueText = "?" }
                        for _, t in ipairs(f:GetDescendants()) do
                            if t:IsA("TextLabel") then
                                local tx = (clean(t.Text):gsub("^%s+", ""):gsub("%s+$", ""))
                                local c = tx:lower():match("^[x\195\151](%d+)$") or tx:lower():match("^x(%d+)$")
                                if c then
                                    card.count = tonumber(c)
                                else
                                    local v = parseAbbrev(tx)
                                    if v and v > card.value then card.value, card.valueText = v, tx
                                    end
                                end
                            end
                        end
                        card.border = borderName(f)
                        cards[#cards + 1] = card
                    end
                end
            end
            table.sort(cards, function(a, b) return a.value > b.value end)
            return cards
        end

        local function canonWeather(name)
            local k = tostring(name or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
            for _, w in ipairs(WEATHER_ORDER) do
                if w:lower() == k then return w end
            end
            return nil
        end

        -- floor / weather / luck / border / cards total: found by the text of the visible labels (outside the card grid)
        local function readHeader(frame, grid)
            local info = {}
            for _, d in ipairs(frame:GetDescendants()) do
                if (d:IsA("TextLabel") or d:IsA("TextButton")) and shown(d) and not d:IsDescendantOf(grid) then
                    local tx = clean(d.Text)
                    local low = tx:lower()
                    info.cards = info.cards or low:match("cards:%s*([%w%.,]+)")
                    info.luck = info.luck or low:match("luck:%s*([%w%.,]+)")
                    info.border = info.border or low:match("border[^%d%+%-\n]*([%+%-]?[%d%.]+%%)")
                    if not low:find("lost on floor", 1, true) then
                        info.floor = info.floor or low:match("floor%s*(%d+)")
                    end
                    local w = low:match("weather:%s*([%a ]+)") or low
                    info.weather = info.weather or canonWeather(w)
                end
            end
            return info
        end

        -- ---- Discord ----
        local function post(payload)
            local req = requestFn()
            if not req then return false, "this executor has no request function" end
            local okR, res = pcall(req, {
                Url = G.url, Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = HttpService:JSONEncode(payload),
            })
            if not okR then return false, tostring(res):sub(1, 80) end
            local code = res and (res.StatusCode or res.status_code)
            if res and (res.Success or (type(code) == "number" and code >= 200 and code < 300)) then return true end
            return false, "HTTP " .. tostring(code)
        end

        -- picture links for the card images (Roblox thumbnail service; the raw asset link is the fallback)
        local function pictureUrls(ids)
            local out = {}
            local req = requestFn()
            if req and #ids > 0 then
                local okR, res = pcall(req, {
                    Url = "https://thumbnails.roblox.com/v1/assets?assetIds=" .. table.concat(ids, ",")
                        .. "&returnPolicy=PlaceHolder&size=512x512&format=Png&isCircular=false",
                    Method = "GET",
                })
                if okR and res and res.Body then
                    local okJ, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
                    if okJ and type(data) == "table" and type(data.data) == "table" then
                        for _, e in ipairs(data.data) do
                            if e.state == "Completed" and e.imageUrl then out[tostring(e.targetId)] = e.imageUrl end
                        end
                    end
                end
            end
            for _, id in ipairs(ids) do
                out[id] = out[id] or ("https://assetdelivery.roblox.com/v1/asset/?id=" .. id)
            end
            return out
        end

        -- ---- the card index database: scanned once, kept in a file (PibbleHub_cardindex.json), loaded on every start ----
        local DB_FILE = "PibbleHub_cardindex.json"
        local CardDB = {} -- [image id] = { name = "Shadow Monarch", odds = "1 in 1,000,000,000,000,000", texts = {...} }
        local function dbCount() local n = 0 for _ in pairs(CardDB) do n += 1 end return n end
        local function dbSave()
            if not writefile then return false end
            return pcall(writefile, DB_FILE, HttpService:JSONEncode(CardDB))
        end
        do
            if isfile and readfile and isfile(DB_FILE) then
                local okR, raw = pcall(readfile, DB_FILE)
                if okR then
                    local okJ, data = pcall(function() return HttpService:JSONDecode(raw) end)
                    if okJ and type(data) == "table" then CardDB = data end
                end
            end
        end

        local function fmtBig(v)
            if type(v) ~= "number" then return tostring(v) end
            for i = #CFG.GEN_SUFFIXES, 1, -1 do
                local m = 1000 ^ i
                if v >= m then
                    return (("%.2f"):format(v / m):gsub("%.?0+$", "")) .. CFG.GEN_SUFFIXES[i]:upper()
                end
            end
            return tostring(v)
        end

        -- the game keeps every card in ReplicatedStorage.ModuleScripts.CardData (name, anime, picture ids, base rarity):
        -- read it, key it by BOTH picture ids (large + small) and save it to the file
        local function buildFromData()
            local mods = game:GetService("ReplicatedStorage"):FindFirstChild("ModuleScripts")
            local m = mods and mods:FindFirstChild("CardData")
            if not m then return 0 end
            local okR, data = pcall(require, m)
            if not okR or type(data) ~= "table" or type(data.Cards) ~= "table" then return 0 end
            local fresh, n = {}, 0
            for _, c in pairs(data.Cards) do
                if type(c) == "table" and c.name then
                    local ab = type(c.ability) == "table" and c.ability or {}
                    local entry = { name = c.name, anime = c.anime, cid = c.id, base = tonumber(c.baseRarity),
                        large = c.imageLarge and tostring(c.imageLarge):match("(%d+)"),
                        pack = c.pack, limit = c.maxPerTeam, lastSlot = c.lastSlotOnly or nil,
                        abilityName = type(ab.name) == "string" and ab.name or nil,
                        abilityDesc = type(ab.description) == "string" and ab.description or nil,
                        trigger = type(ab.trigger) == "string" and ab.trigger or nil }
                    for _, key in ipairs({ "imageLarge", "imageSmall" }) do
                        local id = c[key] and tostring(c[key]):match("(%d+)")
                        if id then fresh[id] = entry end
                    end
                    n += 1
                end
            end
            if n > 0 then CardDB = fresh; dbSave() end
            return n
        end
        pcall(buildFromData) -- refresh on every start (the file is the fallback)

        -- ---- card index scan: dumps the game's card data so card names can be added to the posts ----
        local function scanCards()
            local out = {}
            local function add(s) if #out < 600 then out[#out + 1] = s end end
            local function ser(v, depth)
                local t = typeof(v)
                if t == "string" then return '"' .. v:sub(1, 60) .. '"' end
                if t ~= "table" then return tostring(v) end
                if depth >= 3 then return "{...}" end
                local parts, n = {}, 0
                for k, x in pairs(v) do
                    n += 1
                    if n <= 10 then parts[#parts + 1] = tostring(k) .. "=" .. ser(x, depth + 1) end
                end
                return "{" .. table.concat(parts, ", ") .. (n > 10 and (", ... " .. n .. " entries") or "") .. "}"
            end
            local RS = game:GetService("ReplicatedStorage")
            -- 1) modules with card data
            for _, d in ipairs(RS:GetDescendants()) do
                if d:IsA("ModuleScript") and (d.Name:lower():find("card") or (d.Parent and d.Parent.Name:lower():find("card"))) then
                    add("MODULE " .. d:GetFullName())
                    local ok, res = pcall(require, d)
                    if ok and type(res) == "table" then
                        local n = 0
                        for k, v in pairs(res) do
                            n += 1
                            if n <= 25 then add("  " .. tostring(k) .. " = " .. ser(v, 1)) end
                        end
                        add("  (" .. n .. " entries)")
                    else
                        add("  could not read: " .. tostring(res):sub(1, 80))
                    end
                end
            end
            -- 2) folders / values named like cards
            for _, d in ipairs(RS:GetDescendants()) do
                if (d:IsA("Folder") or d:IsA("Configuration")) and d.Name:lower():find("card") then
                    local kids = d:GetChildren()
                    add("FOLDER " .. d:GetFullName() .. " (" .. #kids .. " children)")
                    for i = 1, math.min(#kids, 12) do
                        local bits = { kids[i].ClassName, kids[i].Name }
                        for k, v in pairs(kids[i]:GetAttributes()) do bits[#bits + 1] = "@" .. k .. "=" .. tostring(v) end
                        if kids[i]:IsA("ValueBase") then bits[#bits + 1] = "value=" .. tostring(kids[i].Value) end
                        add("  " .. table.concat(bits, " | "))
                    end
                end
            end
            -- 3) index / collection windows in the interface
            local pg = player:FindFirstChildOfClass("PlayerGui")
            if pg then
                for _, d in ipairs(pg:GetDescendants()) do
                    local nm = d.Name:lower()
                    if d:IsA("GuiObject") and (nm:find("index") or nm:find("collection") or nm:find("cardlist")) then
                        add("GUI " .. d:GetFullName() .. " (" .. #d:GetChildren() .. " children)")
                    end
                end
            end
            -- 3b) two complete cards, so the stat fields can be seen
            do
                local mods = RS:FindFirstChild("ModuleScripts")
                local m = mods and mods:FindFirstChild("CardData")
                local okR, data = pcall(function() return m and require(m) end)
                if okR and type(data) == "table" and type(data.Cards) == "table" then
                    local function deep(v, depth, ind)
                        if type(v) ~= "table" then return tostring(v) end
                        if depth >= 4 then return "{...}" end
                        local parts = {}
                        for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. deep(x, depth + 1) end
                        return "{" .. table.concat(parts, ", ") .. "}"
                    end
                    local shownN = 0
                    for _, c in pairs(data.Cards) do
                        if type(c) == "table" and c.baseRarity and c.baseRarity >= 1000000 and type(c.ability) == "table" then
                            add("CARD SAMPLE " .. tostring(c.name) .. ": " .. deep(c, 0))
                            shownN += 1
                            if shownN >= 2 then break end
                        end
                    end
                end
            end

            -- 4) the "Card Index" NPC in the world: read its sign, press Talk, dump the window that opens
            local function describe(d)
                local bits = { d.ClassName, d.Name }
                if d:IsA("TextLabel") or d:IsA("TextButton") then bits[#bits + 1] = 'text="' .. clean(d.Text) .. '"' end
                if d:IsA("ImageLabel") or d:IsA("ImageButton") then bits[#bits + 1] = 'image="' .. tostring(d.Image) .. '"' end
                for k, v in pairs(d:GetAttributes()) do bits[#bits + 1] = "@" .. k .. "=" .. tostring(v) end
                if d:IsA("GuiObject") and not d.Visible then bits[#bits + 1] = "(hidden)" end
                return table.concat(bits, " | ")
            end
            local function dumpTree(node, depth, budget)
                if budget.n <= 0 or depth > 8 then return end
                budget.n -= 1
                add(string.rep("  ", depth + 1) .. describe(node))
                local kids = node:GetChildren()
                for i, c in ipairs(kids) do
                    if i > ((depth <= 2) and 14 or 6) then
                        add(string.rep("  ", depth + 2) .. ("... +%d more children"):format(#kids - i + 1))
                        break
                    end
                    dumpTree(c, depth + 1, budget)
                end
            end
            local bb
            for _, d in ipairs(workspace:GetDescendants()) do
                if d:IsA("TextLabel") and clean(d.Text):lower():find("card index", 1, true) and d:FindFirstAncestorWhichIsA("BillboardGui") then
                    bb = d:FindFirstAncestorWhichIsA("BillboardGui")
                    break
                end
            end
            if bb then
                add("CARD INDEX SIGN " .. bb:GetFullName())
                for _, d in ipairs(bb:GetDescendants()) do
                    if d:IsA("TextLabel") then add("  " .. d.Name .. ' = "' .. clean(d.Text) .. '"') end
                end
                local part = bb.Adornee or bb.Parent
                local pos
                if part and part:IsA("BasePart") then pos = part.Position
                else
                    local m = bb:FindFirstAncestorWhichIsA("Model")
                    if m then pos = m:GetPivot().Position end
                end
                local best, bestD
                if pos then
                    for _, d in ipairs(workspace:GetDescendants()) do
                        if d:IsA("ProximityPrompt") then
                            local pp = d.Parent
                            local pv = pp and (pp:IsA("BasePart") and pp.Position or (pp:IsA("Attachment") and pp.WorldPosition))
                            if pv then
                                local dist = (pv - pos).Magnitude
                                if dist < 40 and (not bestD or dist < bestD) then best, bestD = d, dist end
                            end
                        end
                    end
                end
                if best then
                    add(("TALK PROMPT %s | action=%s | object=%s"):format(best:GetFullName(), tostring(best.ActionText), tostring(best.ObjectText)))
                    local pg2 = player:FindFirstChildOfClass("PlayerGui")
                    local before = {}
                    if pg2 then
                        for _, g in ipairs(pg2:GetChildren()) do
                            if g:IsA("ScreenGui") then before[g] = g.Enabled end
                        end
                    end
                    if typeof(fireproximityprompt) == "function" then
                        pcall(fireproximityprompt, best)
                        task.wait(2)
                        local dumped = false
                        if pg2 then
                            for _, g in ipairs(pg2:GetChildren()) do
                                if g:IsA("ScreenGui") and g.Enabled and (before[g] == nil or before[g] == false) then
                                    add("OPENED WINDOW " .. g:GetFullName())
                                    dumpTree(g, 0, { n = 160 })
                                    dumped = true
                                end
                            end
                            if not dumped then
                                for _, g in ipairs(pg2:GetDescendants()) do
                                    local nm = g.Name:lower()
                                    if g:IsA("GuiObject") and g.Visible and (nm:find("cardindex") or nm:find("card_index") or nm == "index" or nm:find("indexframe")) then
                                        add("VISIBLE " .. g:GetFullName())
                                        dumpTree(g, 0, { n = 120 })
                                        dumped = true
                                        break
                                    end
                                end
                            end
                        end
                        if not dumped then add("pressed Talk but no new window was found (stand next to the NPC and try again)") end
                    else
                        add("this executor has no fireproximityprompt: press E at the NPC yourself, then press Scan card index again")
                    end
                else
                    add("no Talk prompt found next to the sign")
                end
            else
                add("no 'Card Index' sign found in the world (walk up to the NPC and press again)")
            end

            local newCards = buildFromData()
            add(("INDEX DATABASE: %d cards read from CardData, %d picture ids saved in %s"):format(newCards, dbCount(), DB_FILE))
            local text = table.concat(out, "\n")
            local copied = false
            if typeof(setclipboard) == "function" then copied = pcall(setclipboard, text) end
            if writefile then pcall(writefile, "PibbleHub_cards.txt", text) end
            local i = 1
            while i <= #out do
                print("[PibbleHub] card scan:\n" .. table.concat(out, "\n", i, math.min(i + 24, #out)))
                i += 25
            end
            statusL.Text = ("Card index: %d cards loaded, %d lines%s"):format(newCards, #out, copied and ", copied" or "")
        end

        local busy = false
        local lastSig, lastPostAt = nil, 0
        local function makeSig(info, cards)
            return table.concat({tostring(info.floor), tostring(info.luck), tostring(info.cards), tostring(#cards),
                cards[1] and cards[1].image or "", cards[2] and cards[2].image or "", cards[3] and cards[3].image or ""}, "|")
        end
        local function postGeneration(manual)
            if busy then return end
            busy = true
            local okRun, err = pcall(function()
                if not validHook(G.url) then statusL.Text = "Paste a webhook URL first"; return end
                local frame, grid = findWindow()
                if not (frame and grid and shown(frame) and shown(grid)) then
                    statusL.Text = "Open the Generated window first"
                    return
                end
                local info = readHeader(frame, grid)
                local cards = readCards(grid)
                if #cards == 0 then statusL.Text = "No cards found in the window"; return end

                -- the same set of cards is never posted twice (the auto-poster and the button share this check);
                -- the button may repeat it after 15 seconds
                local sig = makeSig(info, cards)
                if sig == lastSig and (not manual or os.clock() - lastPostAt < 15) then
                    statusL.Text = "Already posted this one"
                    return
                end

                local want = parseAbbrev(G.good)
                local good = want ~= nil and cards[1].value >= want
                local best = cards[1]
                local ICON = { Normal = "\u{2B1C}", Gold = "\u{1F7E8}", Rainbow = "\u{1F308}", Universal = "\u{1F7E6}", Infernal = "\u{1F7E5}" }
                local COLOR = { Normal = 0x9AA0B4, Gold = 0xF5B642, Rainbow = 0xB66CFF, Universal = 0x3B82F6, Infernal = 0xE5484D }
                local function tag(c) return (c.border and ICON[c.border]) or "\u{25AB}" end
                local function info2(c)
                    c.id = c.id or c.image:match("(%d+)")
                    return c.id and CardDB[c.id] or nil
                end
                local bd = info2(best)

                -- the big picture: the large card art from the index, else the picture from the results window
                local artId = (bd and bd.large) or best.id
                local urls = pictureUrls(artId and { artId } or {})
                local art = artId and urls[artId] or nil

                -- big value, then a small line under it
                local sub = {}
                if bd and bd.anime then sub[#sub + 1] = bd.anime end
                if best.border then sub[#sub + 1] = best.border .. " border" end
                if bd and bd.base then sub[#sub + 1] = "base " .. fmtBig(bd.base) end
                local desc = {}
                desc[#desc + 1] = "# " .. tag(best) .. " " .. best.valueText .. (best.count > 1 and ("  x" .. best.count) or "")
                if #sub > 0 then desc[#desc + 1] = "-# " .. table.concat(sub, "  \u{00B7}  ") end
                desc[#desc + 1] = ""
                local st = {}
                st[#st + 1] = "\u{26C8}\u{FE0F} **" .. (info.weather or "No weather") .. "**"
                if info.luck then st[#st + 1] = "\u{1F340} **" .. info.luck .. "**" end
                if info.border then st[#st + 1] = "\u{1F4A0} **" .. info.border .. "**" end
                if info.cards then st[#st + 1] = "\u{1F0CF} **" .. info.cards .. "**" end
                desc[#desc + 1] = table.concat(st, "     ")

                -- the rest of the best cards, one short line
                local chips = {}
                for i = 2, math.min(#cards, 7) do
                    local c = cards[i]
                    chips[#chips + 1] = tag(c) .. " `" .. c.valueText .. (c.count > 1 and (" x" .. c.count) or "") .. "`"
                end
                if #chips > 0 then
                    desc[#desc + 1] = ""
                    desc[#desc + 1] = "**Also pulled**"
                    desc[#desc + 1] = table.concat(chips, "  ") .. (#cards > 7 and ("  *+" .. (#cards - 7) .. " more*") or "")
                end

                local embeds = {{
                    author = { name = (good and "\u{2B50}  GOOD GENERATION" or "Generation") .. "   \u{00B7}   " .. player.Name
                        .. (info.floor and ("   \u{00B7}   Floor " .. info.floor) or "") },
                    title = (bd and bd.name) or "Best card",
                    description = table.concat(desc, "\n"),
                    color = good and 0xF5B642 or (COLOR[best.border or ""] or 0x5865F2),
                    image = art and { url = art } or nil,
                    footer = { text = "PibbleHub" },
                    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                }}

                local payload = { username = "PibbleHub", embeds = embeds }
                local pingId = tostring(G.ping or ""):match("^%s*(%d+)%s*$")
                if good and pingId then
                    payload.content = ("<@%s> **Good generation!** %s%s  -  %s%s"):format(pingId,
                        (bd and bd.name) and (bd.name .. "  ") or "", cards[1].valueText,
                        cards[1].border or "", cards[1].count > 1 and ("  x" .. cards[1].count) or "")
                    payload.allowed_mentions = { parse = {}, users = { pingId } }
                end

                local sent, why = post(payload)
                if sent then
                    lastSig, lastPostAt = sig, os.clock()
                    G.sent = (G.sent or 0) + 1
                    statusL.Text = ("Posted #%d: %d cards, best %s%s"):format(G.sent, #cards, cards[1].valueText,
                        good and " (GOOD" .. (pingId and ", pinged)" or ", no ping id)") or "")
                else
                    statusL.Text = "Post failed: " .. tostring(why)
                    print("[PibbleHub] generations webhook failed:", why)
                end
            end)
            if not okRun then
                statusL.Text = "Error (see F9)"
                warn("[PibbleHub] generations error:", err)
            end
            busy = false
        end

        -- ---- controls ----
        local hookBox = textbox("Discord webhook URL", 10, TOP + 48, 190, 28, G.url ~= "" and "Webhook saved" or "", 13)
        local hookBtn = button("Hook: OFF", 206, TOP + 48, 90, 28, RED)
        label("GOOD CARD (value at least)", TOP + 84, MUTED, 11).Size = UDim2.fromOffset(286, 16)
        local goodBox = textbox("e.g. 10b, 1t, 1qa", 10, TOP + 102, 286, 28, G.good, 15)
        label("PING (your Discord user ID)", TOP + 138, MUTED, 11).Size = UDim2.fromOffset(286, 16)
        local pingBox = textbox("Your Discord user ID (numbers)", 10, TOP + 156, 286, 28, G.ping, 14)
        goodBox.ClearTextOnFocus = false
        pingBox.ClearTextOnFocus = false
        local testBtn = button("Send test", 10, TOP + 196, 140, 28, DARK)
        local postBtn = button("Post open window", 156, TOP + 196, 140, 28, BLUE)
        postBtn.TextSize = 14
        local cardLoadBtn = button("Load card index", 10, TOP + 232, 140, 28, BLUE)
        cardLoadBtn.TextSize = 14
        cardLoadBtn.MouseButton1Click:Connect(function()
            local n = buildFromData()
            statusL.Text = n > 0 and ("Card index: %d cards loaded and saved"):format(n) or "CardData not found (see F9 after a debug scan)"
        end)
        local cardScanBtn = button("Debug scan", 156, TOP + 232, 140, 28, DARK)
        cardScanBtn.TextSize = 14
        cardScanBtn.MouseButton1Click:Connect(function() task.spawn(scanCards) end)
        statusL.Text = dbCount() > 0 and ("Card index: " .. dbCount() .. " picture ids loaded") or "Idle"
        local n = label("One message per pop. The page of cards on screen is read, the best card is shown with its picture. "
            .. "Open the Generated window and press 'Post open window' to try it.", TOP + 270, MUTED, 13)
        n.Size = UDim2.fromOffset(286, 70)
        n.TextWrapped = true
        n.TextTruncate = Enum.TextTruncate.None
        n.TextYAlignment = Enum.TextYAlignment.Top

        local function refreshHook()
            hookBtn.Text = G.on and "Hook: ON" or "Hook: OFF"
            hookBtn.BackgroundColor3 = G.on and GREEN or RED
        end
        refreshHook()

        hookBox.FocusLost:Connect(function()
            local txt = hookBox.Text:match("^%s*(.-)%s*$")
            if txt == "clear" then
                G.url, G.on = "", false
                refreshHook()
                Settings.save()
                statusL.Text = "Webhook removed"
            elseif validHook(txt) then
                G.url = txt
                Settings.save()
                statusL.Text = "Webhook saved"
            elseif txt ~= "" and txt ~= "Webhook saved" then
                statusL.Text = "Invalid webhook URL (type clear to remove it)"
            end
            hookBox.Text = G.url ~= "" and "Webhook saved" or ""
        end)
        hookBtn.MouseButton1Click:Connect(function()
            if not G.on and not validHook(G.url) then
                statusL.Text = "Paste a Discord webhook URL first"
                return
            end
            G.on = not G.on
            refreshHook()
            Settings.save()
            statusL.Text = G.on and "Posting every generation" or "Posting off"
        end)
        goodBox.FocusLost:Connect(function()
            local txt = goodBox.Text:match("^%s*(.-)%s*$")
            if txt == "" or parseAbbrev(txt) then
                G.good = txt
                Settings.save()
                statusL.Text = txt == "" and "No good-card ping" or ("Good card: " .. txt)
            else
                statusL.Text = "Cannot read '" .. txt .. "' (try 10b, 1t, 1qa)"
            end
            goodBox.Text = G.good
        end)
        pingBox.FocusLost:Connect(function()
            local txt = pingBox.Text:match("^%s*(.-)%s*$")
            if txt == "" or txt:match("^%d+$") then
                G.ping = txt
                Settings.save()
            else
                statusL.Text = "The ID is only numbers"
            end
            pingBox.Text = G.ping
        end)
        testBtn.MouseButton1Click:Connect(function()
            if not validHook(G.url) then statusL.Text = "Paste a webhook URL first"; return end
            task.spawn(function()
                local pingId = tostring(G.ping or ""):match("^%s*(%d+)%s*$")
                local payload = { username = "PibbleHub", embeds = {{
                    title = "PibbleHub connected",
                    description = "Generations will be posted in this channel.",
                    color = 0x4276EB,
                    footer = { text = "PibbleHub  -  " .. player.Name },
                    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                }}}
                if pingId then
                    payload.content = ("<@%s> test ping"):format(pingId)
                    payload.allowed_mentions = { parse = {}, users = { pingId } }
                end
                local sent, why = post(payload)
                statusL.Text = sent and "Test sent" or ("Test failed: " .. tostring(why))
            end)
        end)
        postBtn.MouseButton1Click:Connect(function() task.spawn(postGeneration, true) end)

        -- ---- automatic: every second look at the results window; a new set of cards = one message ----
        task.spawn(function()
            while gui.Parent do
                task.wait(1)
                if G.on and windowUp() then
                    -- wait until the cards stopped changing (the grid fills up for a moment)
                    local _, grid = findWindow()
                    local prev = -1
                    for _ = 1, 6 do
                        local count = 0
                        for _, f in ipairs(grid:GetChildren()) do
                            if f:IsA("Frame") and shown(f) then count += 1 end
                        end
                        if count > 0 and count == prev then break end
                        prev = count
                        task.wait(0.5)
                    end
                    local frame, grid2 = findWindow()
                    if frame and grid2 and windowUp() then
                        local info = readHeader(frame, grid2)
                        local cards = readCards(grid2)
                        if #cards > 0 and makeSig(info, cards) ~= lastSig then
                            postGeneration(false)
                        end
                    end
                elseif not windowUp() then
                    lastSig = nil -- the window closed: the next one counts as new
                end
            end
        end)
    end)

    -- =====================================================================
    -- == 11h. FEATURE: EXPEDITIONS (auto claim + redeploy + deploy the free tiers)
    -- =====================================================================
    -- The game's window (PlayerGui.ExpeditionGui.ExpeditionFrame) is driven like a player would:
    --   open the window (NPC prompt) -> "Redeploy All" when a row is finished (it claims and re-sends) ->
    --   every free tier (button "Start"): pick 4 cards in the picker, press "Deploy" -> close the window.
    -- The end time of every expedition is remembered (saved); the window is opened only when one is due, and only while
    -- no fight / raid / dungeon / portal / pop is using the player.
    safeFeature("Expeditions", function()
        local TOP = 1600
        featureTab("Expeditions", TOP)
        label("Expeditions", TOP, ORANGE)
        local statusL = label("Expeditions: idle", TOP + 22, MUTED, 13)
        statusL.Size = UDim2.fromOffset(286, 34)
        statusL.TextWrapped = true
        statusL.TextTruncate = Enum.TextTruncate.None
        statusL.TextYAlignment = Enum.TextYAlignment.Top

        local S = Settings.exp
        local TIER_ORDER = { "oblivion", "abyss", "nightmare", "insane", "medium", "easy" } -- best first
        local TIER_NAME = { easy = "Easy", medium = "Medium", insane = "Insane", nightmare = "Nightmare", abyss = "Abyss", oblivion = "Oblivion" }
        local running = false
        local function say(t) statusL.Text = t end

        -- ---- clicking ----
        local function mouseClick(obj)
            return pcall(function()
                local vim = game:GetService("VirtualInputManager")
                local sg = obj:FindFirstAncestorWhichIsA("ScreenGui")
                local inset = (sg and sg.IgnoreGuiInset) and Vector2.new(0, 0) or game:GetService("GuiService"):GetGuiInset()
                local p = obj.AbsolutePosition + obj.AbsoluteSize / 2 + inset
                vim:SendMouseButtonEvent(p.X, p.Y, 0, true, game, 1)
                task.wait(0.05)
                vim:SendMouseButtonEvent(p.X, p.Y, 0, false, game, 1)
                releaseInput()
            end)
        end
        local function click(obj)
            if not obj then return false end
            if obj:IsA("GuiButton") and activateButton(obj) then return true end
            return mouseClick(obj)
        end
        local function waitFor(cond, secs)
            local t = os.clock()
            while os.clock() - t < secs do
                local okC, v = pcall(cond)
                if okC and v then return true end
                task.wait(0.1)
            end
            return false
        end

        -- ---- the window ----
        local function parts()
            local pg = player:FindFirstChildOfClass("PlayerGui")
            local g = pg and pg:FindFirstChild("ExpeditionGui")
            local f = g and g:FindFirstChild("ExpeditionFrame")
            return g, f
        end
        local function isOpen()
            local g, f = parts()
            return g ~= nil and f ~= nil and shown(f)
        end
        local function openWindow()
            if isOpen() then return true end
            local g, f = parts()
            if not (g and f) then return false end
            local npcs = workspace:FindFirstChild("NPCs")
            local npc = npcs and npcs:FindFirstChild("ExpeditionNPC")
            local prompt = npc and npc:FindFirstChildWhichIsA("ProximityPrompt", true)
            if prompt and typeof(fireproximityprompt) == "function" then pcall(fireproximityprompt, prompt) end
            if waitFor(isOpen, 2) then return true end
            pcall(function() g.Enabled = true; f.Visible = true end) -- fallback: show it directly
            return waitFor(isOpen, 1)
        end
        local function closeWindow()
            local g, f = parts()
            if not (g and f) then return end
            local cb = f:FindFirstChild("CloseButton")
            if cb then click(cb) end
            if not waitFor(function() return not shown(f) end, 1.5) then pcall(function() f.Visible = false end) end
        end

        -- state of every row: "available" (button Start) / "running" ("Returns in ...") / "ready" (anything else = finished)
        local function readRows()
            local g, f = parts()
            local list = f and f:FindFirstChild("ExpeditionList")
            local out = {}
            if not list then return out end
            for _, id in ipairs(TIER_ORDER) do
                local row = list:FindFirstChild("Expedition_" .. id)
                if row then
                    local st = row:FindFirstChild("StatusLabel")
                    local act = row:FindFirstChild("ActionButton")
                    local lab = act and act:FindFirstChild("Label")
                    local status = st and clean(st.Text) or ""
                    local btn = lab and clean(lab.Text) or ""
                    local state
                    if btn:lower() == "start" or status:lower():find("^available") then state = "available"
                    elseif status:lower():find("^returns in") then state = "running"
                    else state = "ready" end
                    out[id] = { row = row, status = status, btn = act, btnText = btn, state = state }
                end
            end
            return out
        end

        -- the "Rewards" popup after claiming
        local function dismissPopup()
            local g = parts()
            local pop = g and g:FindFirstChild("ClaimPopup")
            if pop and shown(pop) then
                click(pop:FindFirstChild("OkButton"))
                waitFor(function() return not shown(pop) end, 1.5)
                return true
            end
            return false
        end

        local function parseNum(text)
            local s = tostring(text or ""):lower():gsub(",", ""):gsub("%s+", "")
            local num, suf = s:match("^([%d%.]+)(%a*)$")
            num = tonumber(num)
            if not num then return nil end
            if suf == "" then return num end
            for i, sfx in ipairs(CFG.GEN_SUFFIXES) do
                if sfx == suf then return num * 1000 ^ i end
            end
            return nil
        end

        -- picks the 4 cards of one tier and presses Deploy. Returns true or false, reason
        local function deployTier(id, r)
            local g, f = parts()
            local detail = g and g:FindFirstChild("DetailFrame")
            if not detail then return false, "no detail window" end
            if not click(r.btn) then return false, "Start not clickable" end
            if not waitFor(function() return shown(detail) end, 2.5) then return false, "detail did not open" end
            local slots = detail:FindFirstChild("Slots")
            local picker = detail:FindFirstChild("PickerFrame")
            local function closeDetail()
                if picker and shown(picker) then click(picker:FindFirstChild("CloseButton")); task.wait(0.3) end
                click(detail:FindFirstChild("CloseButton"))
                waitFor(function() return not shown(detail) end, 1.5)
            end
            if not (slots and picker) then closeDetail(); return false, "no slots" end

            for i = 1, 4 do
                local slot = slots:FindFirstChild("Slot" .. i)
                local art = slot and slot:FindFirstChild("CardArt")
                if not slot then closeDetail(); return false, "slot " .. i .. " missing" end
                if not (art and shown(art) and tostring(art.Image) ~= "") then -- empty slot: fill it
                    click(slot)
                    if not waitFor(function() return shown(picker) end, 2) then closeDetail(); return false, "picker did not open" end
                    task.wait(0.25)
                    local best, bestV
                    local listF = picker:FindFirstChild("CardList")
                    for _, c in ipairs(listF and listF:GetChildren() or {}) do
                        if c:IsA("GuiButton") and shown(c) then -- the hidden template is skipped by shown()
                            local rl = c:FindFirstChild("RarityLabel")
                            local v = rl and parseNum(clean(rl.Text)) or 0
                            if not best or (S.pick == "high" and v > bestV) or (S.pick ~= "high" and v < bestV) then best, bestV = c, v end
                        end
                    end
                    if not best then closeDetail(); return false, "no card for slot " .. i end
                    click(best)
                    if not waitFor(function() return not shown(picker) end, 2) then
                        click(picker:FindFirstChild("CloseButton"))
                        closeDetail()
                        return false, "card not accepted (slot " .. i .. ")"
                    end
                    task.wait(0.2)
                end
            end
            click(detail:FindFirstChild("DeployButton"))
            if not waitFor(function() return not shown(detail) end, 3) then closeDetail(); return false, "Deploy did not go through" end
            return true
        end

        local DURATION = { easy = 21600, medium = 32400, insane = 54000, nightmare = 86400, abyss = 129600, oblivion = 172800 }
        -- "Returns in 5h 59m" / "58m 51s" / "1d 2h" -> seconds
        local function remainingSecs(text)
            local low = tostring(text):lower()
            if not low:find("^returns in") then return nil end
            local total, any = 0, false
            for num, unit in low:gmatch("(%d+)%s*([dhms])") do
                any = true
                total += tonumber(num) * ((unit == "d" and 86400) or (unit == "h" and 3600) or (unit == "m" and 60) or 1)
            end
            return any and total or nil
        end
        -- remembers when every running expedition ends (saved, so a rejoin does not lose the timers)
        local function learn(rows)
            for id, r in pairs(rows) do
                if r.state == "running" then
                    local secs = remainingSecs(r.status)
                    if secs then S.ends[id] = os.time() + secs + 2 end
                else
                    S.ends[id] = nil
                end
            end
            Settings.save()
        end
        local needScan, retryAt = true, nil -- needScan: read the real timers once at the start

        local function cycle(manual)
            if running then return end
            running = true
            S.busy = true
            local okRun, err = pcall(function()
                say("Expeditions: opening the window...")
                if not openWindow() then say("Expeditions: could not open the window"); retryAt = os.clock() + 120; return end
                task.wait(0.6)
                local report, retry = {}, false

                local rows = readRows()
                learn(rows)
                local ready = 0
                for _, r in pairs(rows) do if r.state == "ready" then ready += 1 end end
                local g, f = parts()
                if ready > 0 then
                    -- Redeploy All claims the finished expeditions and sends them out again
                    click(f:FindFirstChild("RedeployAllButton"))
                    task.wait(1)
                    dismissPopup()
                    report[#report + 1] = ready .. " finished, redeployed"
                    task.wait(0.8)
                    rows = readRows()
                    learn(rows)
                end

                -- free tiers that are switched on get their 4 cards
                local sent = false
                for _, id in ipairs(TIER_ORDER) do
                    local r = rows[id]
                    if r and r.state == "available" and S.tiers[id] then
                        say("Expeditions: deploying " .. TIER_NAME[id] .. "...")
                        local okD, why = deployTier(id, r)
                        if okD then
                            S.ends[id] = os.time() + DURATION[id]
                            sent = true
                            report[#report + 1] = TIER_NAME[id] .. " sent"
                        else
                            retry = true
                            report[#report + 1] = TIER_NAME[id] .. " skipped (" .. tostring(why) .. ")"
                        end
                        task.wait(0.6)
                    end
                end
                if sent then
                    task.wait(0.8)
                    rows = readRows()
                    learn(rows) -- replaces the estimates by the game's real timers
                end
                for id, r in pairs(rows) do
                    if r.state == "ready" then
                        retry = true
                        report[#report + 1] = TIER_NAME[id] .. " still ready: '" .. r.status .. "'" -- tells me the real text if it did not claim
                    end
                end
                Settings.save()
                closeWindow()
                retryAt = retry and (os.clock() + 600) or nil
                needScan = false
                say("Expeditions: " .. (#report > 0 and table.concat(report, ", ") or "timers updated") .. "  (" .. os.date("%H:%M") .. ")")
            end)
            if not okRun then
                say("Expeditions: error (see F9)")
                warn("[PibbleHub] expeditions error:", err)
                pcall(closeWindow)
                retryAt = os.clock() + 120
            end
            running = false
            S.busy = false
        end

        -- ---- is anything else using the player? ----
        local function othersBusy()
            for _, n in ipairs(Prio.order) do
                if Prio.running(n) then return true end
            end
            return Infinite.popBusy == true
        end

        -- ---- controls ----
        local autoBtn = button("Auto: OFF", 10, TOP + 64, 140, 28, RED)
        local runBtn = button("Check now", 156, TOP + 64, 140, 28, BLUE)
        local function refreshAuto()
            autoBtn.Text = S.on and "Auto: ON" or "Auto: OFF"
            autoBtn.BackgroundColor3 = S.on and GREEN or RED
        end
        refreshAuto()
        autoBtn.MouseButton1Click:Connect(function()
            S.on = not S.on
            refreshAuto()
            Settings.save()
            if S.on then needScan = true end
            say(S.on and "Expeditions: auto on" or "Expeditions: auto off")
        end)
        runBtn.MouseButton1Click:Connect(function() task.spawn(cycle, true) end)

        local tl = label("TIERS TO SEND (best first)", TOP + 102, MUTED, 11)
        tl.Size = UDim2.fromOffset(286, 16)
        local tierBtns = {}
        local layout = { { "easy", 10, TOP + 120 }, { "medium", 107, TOP + 120 }, { "insane", 204, TOP + 120 },
                         { "nightmare", 10, TOP + 152 }, { "abyss", 107, TOP + 152 }, { "oblivion", 204, TOP + 152 } }
        local function refreshTier(id)
            local b = tierBtns[id]
            b.Text = TIER_NAME[id]
            b.BackgroundColor3 = S.tiers[id] and GREEN or DARK
        end
        for _, e in ipairs(layout) do
            local id = e[1]
            local b = button(TIER_NAME[id], e[2], e[3], 92, 28, DARK)
            b.TextSize = 13
            tierBtns[id] = b
            refreshTier(id)
            b.MouseButton1Click:Connect(function()
                S.tiers[id] = not S.tiers[id] or nil
                refreshTier(id)
                Settings.save()
            end)
        end

        local pickBtn = button("Cards: Lowest", 10, TOP + 192, 286, 28, DARK)
        local function refreshOpts()
            pickBtn.Text = S.pick == "high" and "Cards: Highest" or "Cards: Lowest (keeps your best home)"
        end
        refreshOpts()
        pickBtn.MouseButton1Click:Connect(function()
            S.pick = (S.pick == "high") and "low" or "high"
            refreshOpts()
            Settings.save()
        end)

        -- ---- the timer of every expedition (counts down live) ----
        local tt = label("TIME LEFT", TOP + 232, MUTED, 11)
        tt.Size = UDim2.fromOffset(286, 16)
        local timersL = label("", TOP + 250, TEXT or MUTED, 14)
        timersL.Size = UDim2.fromOffset(286, 110)
        timersL.TextWrapped = true
        timersL.TextTruncate = Enum.TextTruncate.None
        timersL.TextYAlignment = Enum.TextYAlignment.Top
        local function fmt(secs)
            if secs <= 0 then return "ready" end
            if secs >= 3600 then return ("%dh %02dm"):format(secs // 3600, (secs % 3600) // 60) end
            return ("%dm %02ds"):format(secs // 60, secs % 60)
        end
        local function renderTimers()
            local lines, now = {}, os.time()
            for i = #TIER_ORDER, 1, -1 do
                local id = TIER_ORDER[i]
                local e = S.ends[id]
                lines[#lines + 1] = ("%-10s %s"):format(TIER_NAME[id], e and fmt(e - now) or "-")
            end
            timersL.Text = table.concat(lines, "\\n")
        end
        renderTimers()

        local n = label("The window is opened only when an expedition is due (the end times are remembered and saved). "
            .. "Redeploy All claims and re-sends the finished ones. 'Check now' reads the real timers.", TOP + 366, MUTED, 13)
        n.Size = UDim2.fromOffset(286, 70)
        n.TextWrapped = true
        n.TextTruncate = Enum.TextTruncate.None
        n.TextYAlignment = Enum.TextYAlignment.Top

        task.spawn(function()
            while gui.Parent do
                task.wait(1)
                renderTimers()
            end
        end)
        task.spawn(function()
            task.wait(20)
            while gui.Parent do
                task.wait(2)
                local waiting = retryAt ~= nil and os.clock() < retryAt -- a failed / unfinished check waits before trying again
                if S.on and not running and not waiting then
                    local now = os.time()
                    local due = false
                    for _, e in pairs(S.ends) do
                        if now >= e then due = true break end
                    end
                    if needScan or due or retryAt ~= nil then
                        if othersBusy() then
                            task.wait(18)
                        else
                            cycle(false)
                        end
                    end
                end
            end
        end)
    end)

    -- =====================================================================
    -- == 11i. FEATURE: WATCHDOG (resets a stuck automation, anti-AFK, Discord alert)
    -- =====================================================================
    -- Every few seconds: how long has each automation been holding the player? Past its limit (the "stuck after" minutes
    -- times a factor per feature) the automation is reset (its flags cleared, an open dungeon / world boss left) and the
    -- others get their turn back. The limits are deliberately long: this is a last resort, the features have their own timeouts.
    safeFeature("Watchdog", function()
        local TOP = 2000
        featureTab("Watchdog", TOP)
        label("Watchdog", TOP, ORANGE)
        local statusL = label("Watchdog: watching", TOP + 22, MUTED, 13)
        statusL.Size = UDim2.fromOffset(286, 34)
        statusL.TextWrapped = true
        statusL.TextTruncate = Enum.TextTruncate.None
        statusL.TextYAlignment = Enum.TextYAlignment.Top

        local W = Settings.wd
        local FACTOR = { Boss = 0.5, Portal = 2, Raid = 1, WorldBoss = 1, Dungeon = 1.5 } -- a portal run (several portals in a row) can legitimately last a long time
        local NAMES = { "Boss", "Raid", "Dungeon", "WorldBoss", "Portal" }
        local since = {}

        local function limitSecs(name) return W.minutes * 60 * (FACTOR[name] or 1) end

        local function alert(text)
            local url = Settings.gen.url
            if not (W.alert and type(url) == "string"
                and (url:find("discord.com/api/webhooks", 1, true) or url:find("discordapp.com/api/webhooks", 1, true))) then return end
            local req = (syn and syn.request) or (http and http.request) or http_request or request or (fluxus and fluxus.request)
            if not req then return end
            local pingId = tostring(Settings.gen.ping or ""):match("^%s*(%d+)%s*$")
            local payload = { username = "PibbleHub", embeds = {{
                title = "Watchdog", description = text, color = 0xE5484D,
                footer = { text = player.Name }, timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            }}}
            if pingId then
                payload.content = "<@" .. pingId .. ">"
                payload.allowed_mentions = { parse = {}, users = { pingId } }
            end
            pcall(req, { Url = url, Method = "POST", Headers = { ["Content-Type"] = "application/json" },
                Body = HttpService:JSONEncode(payload) })
        end

        local function recover(name)
            if name == "Boss" then
                Boss.run = Boss.run + 1 -- cancels the pending timeout of the fight
                Boss.active, Boss.started, Boss.timerWait = false, false, false
            elseif name == "Raid" then
                Raid.running, Raid.fightStarted = false, false
            elseif name == "Dungeon" then
                if Dungeon.leave then task.spawn(function() pcall(Dungeon.leave) end) end
                Dungeon.active = false
                Dungeon.lastEnd = os.clock()
            elseif name == "WorldBoss" then
                if WorldBoss.leave then task.spawn(function() pcall(WorldBoss.leave) end) end
                WorldBoss.active = false
            elseif name == "Portal" then
                Portal.active = false
            end
            task.delay(2, function() pcall(Prio.resumeAll) end) -- everything that is switched on gets its turn back
        end

        task.spawn(function()
            while gui.Parent do
                task.wait(5)
                if W.on then
                    for _, name in ipairs(NAMES) do
                        local okR, run = pcall(Prio.running, name)
                        if okR and run then
                            since[name] = since[name] or os.clock()
                            if os.clock() - since[name] > limitSecs(name) then
                                local mins = math.floor((os.clock() - since[name]) / 60)
                                since[name] = nil
                                recover(name)
                                W.resets = (W.resets or 0) + 1
                                local msg = ("%s was stuck for %d min and was reset"):format(Prio.label(name), mins)
                                statusL.Text = "Watchdog: " .. msg .. "  (" .. os.date("%H:%M") .. ")"
                                print("[PibbleHub] watchdog: " .. msg)
                                pcall(function() -- kept in a file, so it can be read after an AFK night
                                    local line = os.date("%Y-%m-%d %H:%M:%S") .. "  " .. msg .. "\n"
                                    if typeof(appendfile) == "function" then appendfile("PibbleHub_watchdog.log", line)
                                    elseif writefile then writefile("PibbleHub_watchdog.log", line) end
                                end)
                                task.spawn(alert, msg)
                            end
                        else
                            since[name] = nil
                        end
                    end
                else
                    since = {}
                end
            end
        end)

        -- ---- controls ----
        local onBtn = button("Watchdog: ON", 10, TOP + 64, 286, 28, GREEN)
        local alertBtn = button("Discord alert", 156, TOP + 148, 140, 28, DARK)
        local logBtn = button("Show log", 10, TOP + 148, 140, 28, BLUE)
        local function refresh()
            onBtn.Text = W.on and "Watchdog: ON" or "Watchdog: OFF"
            onBtn.BackgroundColor3 = W.on and GREEN or RED
            alertBtn.Text = W.alert and "Discord alert: ON" or "Discord alert: OFF"
            alertBtn.BackgroundColor3 = W.alert and GREEN or DARK
        end
        refresh()
        onBtn.MouseButton1Click:Connect(function() W.on = not W.on; refresh(); Settings.save() end)
        alertBtn.MouseButton1Click:Connect(function() W.alert = not W.alert; refresh(); Settings.save() end)

        local ml = label("STUCK AFTER (minutes)", TOP + 106, MUTED, 11)
        ml.Size = UDim2.fromOffset(286, 16)
        local minBox = textbox("minutes", 10, TOP + 124, 140, 28, tostring(W.minutes), 15)
        minBox.ClearTextOnFocus = false
        minBox.FocusLost:Connect(function()
            local v = tonumber(minBox.Text)
            if v and v >= 5 and v <= 240 then
                W.minutes = math.floor(v)
                Settings.save()
            end
            minBox.Text = tostring(W.minutes)
        end)

        -- how long every automation has held the player, against its limit
        local infoL = label("", TOP + 188, TEXT, 14)
        infoL.Size = UDim2.fromOffset(286, 100)
        infoL.TextWrapped = true
        infoL.TextTruncate = Enum.TextTruncate.None
        infoL.TextYAlignment = Enum.TextYAlignment.Top
        task.spawn(function()
            while gui.Parent do
                local lines = {}
                for _, name in ipairs(NAMES) do
                    local t = since[name]
                    local held = t and math.floor((os.clock() - t) / 60) or nil
                    lines[#lines + 1] = ("%-12s %s / %d min"):format(Prio.label(name), held and (held .. " min") or "-", math.floor(limitSecs(name) / 60))
                end
                infoL.Text = table.concat(lines, "\n")
                task.wait(2)
            end
        end)

        local n = label("Resets an automation that has held the player too long (the limit is longer for a dungeon, shorter for a boss). "
            .. "The hub's own anti-AFK (always on) stops the idle kick. The alert uses the Generations webhook.", TOP + 296, MUTED, 13)
        n.Size = UDim2.fromOffset(286, 80)
        n.TextWrapped = true
        n.TextTruncate = Enum.TextTruncate.None
        n.TextYAlignment = Enum.TextYAlignment.Top

        -- the reset log (kept in PibbleHub_watchdog.log): shown here and copied to the clipboard
        local logL = label("", TOP + 384, TEXT, 12)
        logL.Size = UDim2.fromOffset(286, 120)
        logL.TextWrapped = true
        logL.TextTruncate = Enum.TextTruncate.None
        logL.TextYAlignment = Enum.TextYAlignment.Top
        logBtn.MouseButton1Click:Connect(function()
            local okR, raw = false, nil
            if typeof(isfile) == "function" and typeof(readfile) == "function" and isfile("PibbleHub_watchdog.log") then
                okR, raw = pcall(readfile, "PibbleHub_watchdog.log")
            end
            if not (okR and raw and raw ~= "") then
                logL.Text = "No resets logged yet (the file is only created when the watchdog resets something)."
                return
            end
            local lines = {}
            for line in raw:gmatch("[^\n]+") do lines[#lines + 1] = line end
            local first = math.max(1, #lines - 7)
            logL.Text = table.concat(lines, "\n", first, #lines)
            local copied = typeof(setclipboard) == "function" and pcall(setclipboard, raw)
            statusL.Text = ("Watchdog log: %d resets%s"):format(#lines, copied and ", copied to clipboard" or "")
        end)

        -- ---- GUARD: stop everything when somebody who is not in the whitelist is in the server ----
        local G = Settings.guard
        local guardHead = label("GUARD (whitelist)", TOP + 520, ORANGE, 13)
        local guardBtn = button("Guard: OFF", 10, TOP + 544, 286, 28, RED)
        local tripped = false
        local gOff = featureOffset
        local guardL = label("", TOP + 612, MUTED, 12)
        guardL.Size = UDim2.fromOffset(286, 50)
        guardL.TextWrapped = true
        guardL.TextTruncate = Enum.TextTruncate.None
        guardL.TextYAlignment = Enum.TextYAlignment.Top
        local guardList = nameList(nil, 10, TOP + 578, 286, function() return G.names end,
            function(v) G.names = v; Settings.save() end, "Allowed players: type a name, press Enter",
            function(h) guardL.Position = UDim2.fromOffset(10, TOP + 578 + h + 6 - gOff) end)
        local function guardUI()
            guardBtn.Text = G.on and "Guard: ON" or "Guard: OFF"
            guardBtn.BackgroundColor3 = G.on and GREEN or RED
        end
        guardUI()
        local function allowed(p)
            if p == player then return true end
            local un, dn = p.Name:lower(), p.DisplayName:lower()
            for w in tostring(G.names or ""):gmatch("[^,;%s]+") do
                w = w:lower()
                if un == w or dn == w then return true end
            end
            return false
        end
        -- what was running when the Guard tripped (nil = nothing is waiting to be resumed)
        local snap = nil
        local function takeSnapshot()
            local pc, pf = false, false
            if Portal.getAuto then local a, b = Portal.getAuto(); pc, pf = a == true, b == true end
            local dOn, fOn = false, false
            if Dagon.getAuto then local a, b = Dagon.getAuto(); dOn, fOn = a == true, b == true end
            snap = {
                boss = Boss.auto == true, raid = Raid.auto == true, dungeon = Dungeon.auto == true,
                wboss = WorldBoss.auto == true, pop = Infinite.on == true,
                create = pc, follow = pf, dagon = dOn, fish = fOn,
                exp = Settings.exp and Settings.exp.on == true,
            }
        end
        local function resumeEverything(why)
            local sn = snap
            snap = nil
            if not sn then return end
            pcall(function() if sn.boss and Boss.setAuto then Boss.setAuto(true) end end)
            pcall(function() if sn.raid and Raid.setAuto then Raid.setAuto(true) end end)
            pcall(function() if sn.dungeon and Dungeon.setAuto then Dungeon.setAuto(true) end end)
            pcall(function() if sn.wboss and WorldBoss.setAuto then WorldBoss.setAuto(true) end end)
            pcall(function() if sn.pop and Infinite.setPop then Infinite.setPop(true) end end)
            pcall(function() if (sn.dagon or sn.fish) and Dagon.resumeAuto then Dagon.resumeAuto(sn.dagon, sn.fish) end end)
            pcall(function() if sn.exp and Settings.exp then Settings.exp.on = true end end)
            pcall(function() if (sn.create or sn.follow) and Portal.resumeAuto then Portal.resumeAuto(sn.create, sn.follow) end end)
            pcall(Settings.save)
            guardL.Text = why .. "  (" .. os.date("%H:%M:%S") .. ")"
            statusL.Text = "Guard: " .. why
            print("[PibbleHub] GUARD: " .. why)
            task.spawn(alert, "Guard: " .. why)
        end
        local function stopEverything(why)
            if not snap then pcall(takeSnapshot) end -- (a second stranger must not overwrite what was running)
            pcall(stopAll)
            pcall(function() if Portal.stopAuto then Portal.stopAuto() end end)
            pcall(function() if Dagon.stopAuto then Dagon.stopAuto() end end)
            pcall(function() if Settings.exp then Settings.exp.on = false end end)
            pcall(Settings.save)
            guardL.Text = why .. "  (" .. os.date("%H:%M:%S") .. ")"
            statusL.Text = "Guard: " .. why
            print("[PibbleHub] GUARD: " .. why)
            task.spawn(alert, "Guard: " .. why .. " (everything was stopped)")
        end
        local function checkGuard()
            if not G.on then
                tripped = false
                if snap then resumeEverything("Guard switched off, resuming what was running") end
                return
            end
            local strangers = {}
            for _, p in ipairs(Players:GetPlayers()) do
                if not allowed(p) then strangers[#strangers + 1] = p.Name end
            end
            if #strangers > 0 then
                if not tripped then
                    tripped = true
                    stopEverything("not on the whitelist: " .. table.concat(strangers, ", "))
                end
            else
                tripped = false
                if snap then resumeEverything("everyone is allowed again, resuming") end
            end
        end
        connect(Players.PlayerAdded, function() task.wait(0.5); checkGuard() end)
        connect(Players.PlayerRemoving, function() task.delay(1, function() pcall(checkGuard) end) end)
        task.spawn(function() -- (also catches a player who was already there when the Guard is switched on)
            while gui.Parent do task.wait(3); pcall(checkGuard) end
        end)
        guardBtn.Activated:Connect(function()
            G.on = not G.on
            tripped = false
            guardUI()
            Settings.save()
            if G.on then
                guardL.Text = (G.names or "") == "" and "Guard ON: nobody is allowed except you" or "Guard ON"
                pcall(checkGuard)
            else
                guardL.Text = "Guard off"
            end
        end)
    end)

    -- =====================================================================
    -- == 11j. FEATURE: PERFORMANCE MODE (black screen, low graphics, no effects, mute, FPS cap)
    -- =====================================================================
    -- One switch for long AFK runs. Everything it changes is remembered and put back when the switch goes OFF and when the
    -- hub is unloaded (so the screen never stays black). The hub itself and its clicks keep working: only the 3D scene is not drawn.
    safeFeature("Performance", function()
        local TOP = 2300
        featureTab("Performance", TOP)
        label("Performance", TOP, ORANGE)
        local statusL = label("Performance mode: off", TOP + 22, MUTED, 13)
        statusL.Size = UDim2.fromOffset(286, 34)
        statusL.TextWrapped = true
        statusL.TextTruncate = Enum.TextTruncate.None
        statusL.TextYAlignment = Enum.TextYAlignment.Top

        local S = Settings.perf
        local RunService = game:GetService("RunService")
        local Lighting = game:GetService("Lighting")
        local FPS_STEPS = { 15, 20, 30, 60 }

        local applied, applying = false, false
        local orig = {}
        local touched = setmetatable({}, { __mode = "k" }) -- [instance] = true: effects this mode switched off (switched back on at restore)
        local function weak() return setmetatable({}, { __mode = "k" }) end -- weak keys: a part that the game removes can be freed
        local mats, trans = weak(), weak() -- originals of the parts / decals that "Low graphics" flattened
        local conn, cover

        local function killable(i)
            return i:IsA("ParticleEmitter") or i:IsA("Trail") or i:IsA("Beam") or i:IsA("Fire")
                or i:IsA("Smoke") or i:IsA("Sparkles") or i:IsA("PostEffect")
        end
        local function strip(i)
            if killable(i) then
                local okE, en = pcall(function() return i.Enabled end)
                if okE and en then
                    touched[i] = true
                    pcall(function() i.Enabled = false end)
                end
            end
        end

        -- Low graphics on top of the quality level: flat plastic, no shadows, no reflections, no decals
        local function process(i)
            if S.strip then strip(i) end
            if S.low then
                pcall(function()
                    if i:IsA("BasePart") and not i:IsA("Terrain") then
                        if not mats[i] then mats[i] = { i.Material, i.CastShadow, i.Reflectance } end
                        i.Material = Enum.Material.SmoothPlastic
                        i.CastShadow = false
                        i.Reflectance = 0
                    elseif i:IsA("Decal") or i:IsA("Texture") then
                        if not trans[i] then trans[i] = i.Transparency end
                        i.Transparency = 1
                    end
                end)
            end
        end

        -- the 3D world is drawn white when it is switched off, so a black cover sits under every window of the game
        local function showCover()
            local pg = player:FindFirstChildOfClass("PlayerGui")
            if not pg then return end
            local g = Instance.new("ScreenGui")
            g.Name = "PibbleBlackScreen"
            g.DisplayOrder = -1000
            g.IgnoreGuiInset = true
            g.ResetOnSpawn = false
            local f = Instance.new("Frame")
            f.Size = UDim2.fromScale(1, 1)
            f.BackgroundColor3 = Color3.new(0, 0, 0)
            f.BorderSizePixel = 0
            f.Active = false
            f.Parent = g
            g.Parent = pg
            cover = g
        end

        local function restore()
            if not applied then return end
            applied = false
            pcall(function() RunService:Set3dRenderingEnabled(true) end) -- first: never leave the screen black
            if cover then pcall(function() cover:Destroy() end); cover = nil end
            for p, v in pairs(mats) do pcall(function() p.Material, p.CastShadow, p.Reflectance = v[1], v[2], v[3] end) end
            for d, v in pairs(trans) do pcall(function() d.Transparency = v end) end
            mats, trans = weak(), weak()
            if orig.saved then pcall(function() UserSettings():GetService("UserGameSettings").SavedQualityLevel = orig.saved end) end
            if orig.tech then pcall(function() sethiddenproperty(Lighting, "Technology", orig.tech) end) end
            if orig.water then pcall(function() workspace.Terrain.WaterWaveSize, workspace.Terrain.WaterReflectance = orig.water[1], orig.water[2] end) end
            if orig.decor ~= nil then pcall(function() sethiddenproperty(workspace.Terrain, "Decoration", orig.decor) end) end
            if conn then conn:Disconnect(); conn = nil end
            for i in pairs(touched) do pcall(function() i.Enabled = true end) end
            touched = setmetatable({}, { __mode = "k" })
            if orig.quality then pcall(function() settings().Rendering.QualityLevel = orig.quality end) end
            if orig.shadows ~= nil then pcall(function() Lighting.GlobalShadows = orig.shadows end) end
            if orig.volume then pcall(function() UserSettings():GetService("UserGameSettings").MasterVolume = orig.volume end) end
            if orig.fps and typeof(setfpscap) == "function" then pcall(setfpscap, orig.fps) end
            orig = {}
        end

        local function apply()
            if applied or applying then return end
            applying = true
            applied = true
            if S.low then
                pcall(function()
                    orig.quality = settings().Rendering.QualityLevel
                    settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
                end)
                pcall(function() orig.shadows = Lighting.GlobalShadows; Lighting.GlobalShadows = false end)
                pcall(function()
                    local ugs = UserSettings():GetService("UserGameSettings")
                    orig.saved = ugs.SavedQualityLevel
                    ugs.SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1
                end)
                if typeof(sethiddenproperty) == "function" and typeof(gethiddenproperty) == "function" then
                    pcall(function()
                        orig.tech = gethiddenproperty(Lighting, "Technology")
                        sethiddenproperty(Lighting, "Technology", Enum.Technology.Compatibility)
                    end)
                    pcall(function()
                        orig.decor = gethiddenproperty(workspace.Terrain, "Decoration")
                        sethiddenproperty(workspace.Terrain, "Decoration", false)
                    end)
                end
                pcall(function()
                    local t = workspace.Terrain
                    orig.water = { t.WaterWaveSize, t.WaterReflectance }
                    t.WaterWaveSize, t.WaterReflectance = 0, 0
                end)
            end
            if S.mute then
                pcall(function()
                    local ugs = UserSettings():GetService("UserGameSettings")
                    orig.volume = ugs.MasterVolume
                    ugs.MasterVolume = 0
                end)
            end
            if typeof(setfpscap) == "function" then
                pcall(function()
                    orig.fps = (typeof(getfpscap) == "function" and tonumber(getfpscap())) or 60
                    if orig.fps <= 0 then orig.fps = 60 end
                    setfpscap(S.fps)
                end)
            end
            if S.strip or S.low then
                for _, i in ipairs(Lighting:GetChildren()) do if S.strip then strip(i) end end
                conn = workspace.DescendantAdded:Connect(process)
                local n = 0
                for _, d in ipairs(workspace:GetDescendants()) do
                    if not applied then break end
                    process(d)
                    n += 1
                    if n % 300 == 0 then task.wait() end
                end
            end
            if S.black and applied then
                showCover()
                pcall(function() RunService:Set3dRenderingEnabled(false) end)
            end
            applying = false
        end

        -- the screen must never stay black after the hub is gone
        gui.Destroying:Connect(restore)

        local function setOn(v)
            S.on = v
            Settings.save()
            if v then
                task.spawn(apply)
                statusL.Text = "Performance mode: ON"
            else
                restore()
                statusL.Text = "Performance mode: off"
            end
        end
        local function reapply() -- an option changed while the mode is ON
            if S.on then
                restore()
                task.spawn(function() task.wait(0.3); apply() end)
            end
        end

        -- ---- controls ----
        local onBtn = button("Performance: OFF", 10, TOP + 64, 286, 32, RED)
        local blackBtn = button("Black screen", 10, TOP + 106, 140, 28, DARK)
        local lowBtn = button("Low graphics", 156, TOP + 106, 140, 28, DARK)
        local stripBtn = button("No effects", 10, TOP + 140, 140, 28, DARK)
        local muteBtn = button("Mute sound", 156, TOP + 140, 140, 28, DARK)
        local fpsBtn = button("FPS cap", 10, TOP + 176, 286, 28, DARK)
        local function refresh()
            onBtn.Text = S.on and "Performance: ON" or "Performance: OFF"
            onBtn.BackgroundColor3 = S.on and GREEN or RED
            for _, e in ipairs({ { blackBtn, "black" }, { lowBtn, "low" }, { stripBtn, "strip" }, { muteBtn, "mute" } }) do
                e[1].BackgroundColor3 = S[e[2]] and GREEN or DARK
            end
            fpsBtn.Text = typeof(setfpscap) == "function" and ("FPS cap: " .. S.fps) or "FPS cap: not supported here"
        end
        refresh()
        onBtn.MouseButton1Click:Connect(function() setOn(not S.on); refresh() end)
        for _, e in ipairs({ { blackBtn, "black" }, { lowBtn, "low" }, { stripBtn, "strip" }, { muteBtn, "mute" } }) do
            e[1].MouseButton1Click:Connect(function()
                S[e[2]] = not S[e[2]]
                refresh()
                Settings.save()
                reapply()
            end)
        end
        fpsBtn.MouseButton1Click:Connect(function()
            local idx = 1
            for i, v in ipairs(FPS_STEPS) do if v == S.fps then idx = i end end
            S.fps = FPS_STEPS[idx % #FPS_STEPS + 1]
            refresh()
            Settings.save()
            if S.on and typeof(setfpscap) == "function" then pcall(setfpscap, S.fps) end
        end)

        -- live FPS (shows the effect of the cap)
        local fpsL = label("FPS: -", TOP + 214, TEXT, 15)
        local frames, lastT = 0, os.clock()
        connect(RunService.Heartbeat, function()
            frames += 1
            local now = os.clock()
            if now - lastT >= 1 then
                fpsL.Text = "FPS: " .. math.floor(frames / (now - lastT) + 0.5)
                frames, lastT = 0, now
            end
        end)

        local n = label("Black screen = the 3D world is not drawn (a black cover replaces it, the game's windows and your hub stay visible). Everything is put back when you switch "
            .. "it off or unload the hub. A low FPS cap makes the script's own waits a little coarser, 15 to 20 is fine.", TOP + 244, MUTED, 13)
        n.Size = UDim2.fromOffset(286, 100)
        n.TextWrapped = true
        n.TextTruncate = Enum.TextTruncate.None
        n.TextYAlignment = Enum.TextYAlignment.Top

        -- restored with the other saved switches: applied a few seconds after launch
        if S.on then
            task.delay(6, function()
                if gui.Parent and S.on then
                    task.spawn(apply)
                    statusL.Text = "Performance mode: ON"
                end
            end)
        end
    end)

    -- =====================================================================
    -- == 11d. FISHING / DAGON SETUP: records what the game does while fishing and fighting Dagon, so the automation can
    -- ==      be built on the real remotes and window names (nothing is automated here yet)
    -- =====================================================================
    safeFeature("Fishing", function()
        local TOP = 2600
        featureTab("Fishing", TOP)
        label("Fishing / Dagon setup", TOP, ORANGE)
        local statusL = label("Nothing recorded yet", TOP + 22, MUTED, 13)
        statusL.Size = UDim2.fromOffset(286, 34)
        statusL.TextWrapped = true
        statusL.TextTruncate = Enum.TextTruncate.None
        statusL.TextYAlignment = Enum.TextYAlignment.Top

        -- ---- AUTO FISH: keeps the game's own "Auto: Off / On" button of the fishing bar switched ON ----
        -- (equip the rod yourself; the bar with Unequip / Roll / Auto only exists while a rod is equipped)
        local F = Settings.fish
        local fishBtn = button("Auto Fish: OFF", 10, TOP + 64, 286, 32, RED)
        local function autoButton()
            return findButton(function(t) return t:match("^auto%s*:%s*%a+$") ~= nil end)
        end
        local function autoState(b)
            local st = btnText(b):match("^auto%s*:%s*(%a+)$")
            if st then return st end
            for _, d in ipairs(b:GetDescendants()) do -- an image button with the text in a label inside it
                if d:IsA("TextLabel") or d:IsA("TextButton") then
                    st = clean(d.Text):lower():match("^auto%s*:%s*(%a+)$")
                    if st then return st end
                end
            end
            return nil
        end
        local function setFishUI()
            fishBtn.Text = F.on and "Auto Fish: ON" or "Auto Fish: OFF"
            fishBtn.BackgroundColor3 = F.on and GREEN or RED
        end
        fishBtn.Activated:Connect(function()
            F.on = not F.on
            setFishUI()
            Settings.save()
            statusL.Text = F.on and "Auto Fish: ON" or "Auto Fish: off"
        end)
        setFishUI()
        -- the rod button of the fishing bar says "Unequip" while the rod is in the hand and "Equip" when it is not;
        -- without the bar, the rod tool of the backpack is put in the hand
        local lastEquip = -1e9
        local function ensureRod()
            local pg = player:FindFirstChildOfClass("PlayerGui")
            local hud = pg and pg:FindFirstChild("FishingHud")
            local rb = hud and hud:FindFirstChild("RodButton", true)
            if rb and shown(rb) then
                local txt = ""
                for _, d in ipairs(rb:GetDescendants()) do
                    if d:IsA("TextLabel") then txt = clean(d.Text):lower() break end
                end
                if rb:IsA("TextButton") then txt = clean(rb.Text):lower() end
                if txt:find("equip", 1, true) and not txt:find("unequip", 1, true) then
                    print("[PibbleHub] auto fish: pressing the rod button ('" .. txt .. "')")
                    if not activateButton(rb) then realClick(rb) end
                    return true
                end
                return false -- already in the hand
            end
            local char = player.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local bp = player:FindFirstChildOfClass("Backpack")
            if not (hum and bp and hum.Health > 0) then return false end
            if char:FindFirstChildWhichIsA("Tool") then return false end
            for _, tool in ipairs(bp:GetChildren()) do
                if tool:IsA("Tool") and tool.Name:lower():find("rod", 1, true) then
                    print("[PibbleHub] auto fish: equipping " .. tool.Name)
                    pcall(function() hum:EquipTool(tool) end)
                    return true
                end
            end
            return false
        end

        task.spawn(function()
            local fails = 0
            while gui.Parent do
                task.wait(2)
                if F.on then
                    local okF, errF = pcall(function()
                        local b = autoButton()
                        -- combo test: inside a portal the game hides the fishing bar; at the island the hidden button is
                        -- still pressed through its own handler (never with a real click, it is invisible)
                        local usable = b and (shown(b) or (Dagon.on and Dagon.atZone))
                        if not usable then
                            fails = 0
                            -- after a death the rod is gone from the hand: equip it again (at most every 5 s)
                            if os.clock() - lastEquip > 5 then
                                lastEquip = os.clock()
                                if ensureRod() then statusL.Text = "Auto Fish: equipped the rod"; return end
                            end
                            statusL.Text = "Auto Fish: waiting for the fishing bar (equip your rod)"
                            return
                        end
                        local st = autoState(b)
                        if Dagon.on and not Dagon.atZone then
                            -- Auto Dagon: the game's Auto stays off in the lobby / on the way; it goes on at the island
                            if st == "on" then
                                activateButton(b)
                                task.wait(0.6)
                            end
                            statusL.Text = "Auto Fish: off until you are at the island (Auto Dagon). Turn Auto Dagon OFF to fish anywhere"
                            return
                        end
                        if st == "on" then
                            fails = 0
                            statusL.Text = "Auto Fish: running (game Auto is ON)"
                            return
                        end
                        -- at the island with Auto off: the game may have stopped it with "face the water": turn first
                        if Dagon.on and Dagon.atZone and Dagon.faceWater then pcall(Dagon.faceWater, "Auto was off at the island") end
                        -- switched off: press it, then look whether it really turned on
                        if fails < 3 or not shown(b) then
                            activateButton(b)
                        else
                            realClick(b) -- the button's own handler did not answer: a real click
                        end
                        task.wait(1.2)
                        if autoState(b) == "on" then
                            fails = 0
                            statusL.Text = "Auto Fish: turned the game Auto ON"
                        else
                            fails += 1
                            statusL.Text = ("Auto Fish: pressed, still off (try %d)"):format(fails)
                        end
                    end)
                    if not okF then warn("[PibbleHub] auto fish error:", errF) end
                end
            end
        end)

        local howto = label("1. Press Record remotes.\n2. Fish, catch things, then fight Dagon (press Auto Fight too).\n3. Press Stop, then Copy and paste it to me.\n4. During the Dagon fight press Scan fishing UI.", TOP + 106, MUTED, 12)
        howto.Size = UDim2.fromOffset(286, 76)
        howto.TextWrapped = true
        howto.TextTruncate = Enum.TextTruncate.None
        howto.TextYAlignment = Enum.TextYAlignment.Top

        local genv = (getgenv and getgenv()) or _G
        local Rec = genv.PibbleRec
        if type(Rec) ~= "table" then
            Rec = { on = false, list = {}, index = {}, t0 = 0 }
            genv.PibbleRec = Rec
        end
        Rec.on = false

        local function brief(v, depth)
            local t = typeof(v)
            if t == "string" then return '"' .. v:sub(1, 60) .. '"' end
            if t == "number" or t == "boolean" or t == "nil" then return tostring(v) end
            if t == "Instance" then return v:GetFullName():sub(-70) end
            if t == "table" and (depth or 0) < 2 then
                local parts, n = {}, 0
                for k, x in pairs(v) do
                    n += 1
                    if n > 6 then parts[#parts + 1] = "..." break end
                    parts[#parts + 1] = tostring(k) .. "=" .. brief(x, (depth or 0) + 1)
                end
                return "{" .. table.concat(parts, ", ") .. "}"
            end
            return "<" .. t .. ">"
        end

        -- one hook on game:__namecall for the whole session of the executor; it only records while Rec.on is true
        local hooked = genv.PibbleRecHooked == true
        local function installHook()
            if hooked then return true end
            if typeof(hookmetamethod) ~= "function" or typeof(getnamecallmethod) ~= "function" then return false end
            local old
            local function handler(self, ...)
                local m = getnamecallmethod()
                local R = genv.PibbleRec
                if R and R.on and (m == "FireServer" or m == "InvokeServer") then
                    local args = table.pack(...)
                    pcall(function()
                        local parts = {}
                        for i = 1, math.min(args.n, 6) do parts[i] = brief(args[i]) end
                        local key = self.Name .. "(" .. table.concat(parts, ", ") .. ")"
                        local e = R.index[key]
                        if e then
                            e.n += 1
                        elseif #R.list < 200 then
                            e = { key = key, n = 1, t = os.clock() - R.t0, kind = m }
                            R.index[key] = e
                            R.list[#R.list + 1] = e
                        end
                    end)
                end
                return old(self, ...)
            end
            local wrapped = (typeof(newcclosure) == "function") and newcclosure(handler) or handler
            local okH, res = pcall(hookmetamethod, game, "__namecall", wrapped)
            if not okH then return false end
            old = res
            genv.PibbleRecHooked = true
            hooked = true
            return true
        end

        local function output(text, what)
            print("[PibbleHub] " .. what .. ":\n" .. text)
            pcall(function() if setclipboard then setclipboard(text) end end)
            pcall(function() if writefile then writefile("PibbleHub_fishing.txt", text) end end)
        end

        local recBtn = button("Record remotes: OFF", 10, TOP + 188, 286, 32, RED)
        local function setRecUI()
            recBtn.Text = Rec.on and "Stop recording" or "Record remotes: OFF"
            recBtn.BackgroundColor3 = Rec.on and GREEN or RED
        end
        local function renderRec()
            local lines = { "== remotes fired by the game (" .. #Rec.list .. ") ==" }
            for _, e in ipairs(Rec.list) do
                lines[#lines + 1] = ("+%5.1fs x%d  %s  %s"):format(e.t, e.n, e.kind == "InvokeServer" and "INVOKE" or "FIRE", e.key)
            end
            return table.concat(lines, "\n")
        end
        recBtn.Activated:Connect(function()
            if not Rec.on then
                if not installHook() then
                    statusL.Text = "This executor has no hookmetamethod: use Dump remote names below"
                    return
                end
                Rec.list, Rec.index, Rec.t0 = {}, {}, os.clock()
                Rec.on = true
                statusL.Text = "Recording... fish, then fight Dagon"
            else
                Rec.on = false
                local text = renderRec()
                output(text, "fishing remotes")
                statusL.Text = ("Stopped. %d different calls copied to the clipboard"):format(#Rec.list)
            end
            setRecUI()
        end)
        gui.Destroying:Connect(function() Rec.on = false end)

        local scanBtn = button("Scan fishing UI (copy)", 10, TOP + 228, 286, 30, DARK)
        scanBtn.TextSize = 13
        scanBtn.Activated:Connect(function()
            local out = {}
            local function line(t) out[#out + 1] = t end
            local pg = player:FindFirstChildOfClass("PlayerGui")
            local words = { "fish", "dagon", "cast", "reel", "auto", "fight", "form", "boss", "health", "hp", "rod", "bait", "zone", "catch", "compass", "sea" }
            local function hit(str)
                str = tostring(str or ""):lower()
                for _, w in ipairs(words) do if str:find(w, 1, true) then return true end end
                return false
            end
            line("== visible windows ==")
            if pg then
                for _, sg in ipairs(pg:GetChildren()) do
                    if sg:IsA("ScreenGui") and sg ~= gui then
                        line(("%s enabled=%s children=%d"):format(sg.Name, tostring(sg.Enabled), #sg:GetDescendants()))
                    end
                end
                line("== objects that look related (name or text matches) ==")
                local n = 0
                for _, d in ipairs(pg:GetDescendants()) do
                    if n >= 160 then break end
                    if not d:IsDescendantOf(gui) and d:IsA("GuiObject") and shown(d) then
                        local txt = (d:IsA("TextButton") or d:IsA("TextLabel")) and clean(d.Text) or ""
                        if hit(d.Name) or hit(txt) then
                            n += 1
                            local extra = d:IsA("GuiButton") and (" BUTTON active=" .. tostring(d.Active)) or ""
                            line(("%s %s  path=%s%s%s"):format(d.ClassName, d.Name, d:GetFullName():gsub("^.-PlayerGui%.", ""),
                                txt ~= "" and (' text="' .. txt .. '"') or "", extra))
                        end
                    end
                end
            end
            -- the fishing / sea boss zone: the folder, what is inside it, where it is, and how far from the player
            line("== SeaBossGui (the sea boss window: open / fight it first) ==")
            local sbg = pg and pg:FindFirstChild("SeaBossGui")
            if sbg then
                local cnt = 0
                for _, d in ipairs(sbg:GetDescendants()) do
                    if cnt >= 120 then break end
                    if d:IsA("GuiObject") then
                        cnt += 1
                        local txt = (d:IsA("TextButton") or d:IsA("TextLabel")) and clean(d.Text) or ""
                        local extra = d:IsA("GuiButton") and (" BUTTON active=" .. tostring(d.Active)) or ""
                        line(("%s %s vis=%s path=%s%s%s"):format(d.ClassName, d.Name, tostring(shown(d)),
                            d:GetFullName():gsub("^.-SeaBossGui%.", ""), txt ~= "" and (' text="' .. txt .. '"') or "", extra))
                    end
                end
            else
                line("(no SeaBossGui)")
            end
            line("== zones in the workspace ==")
            local char = player.Character
            local myPos = char and char:FindFirstChild("HumanoidRootPart") and char.HumanoidRootPart.Position
            line("player position: " .. (myPos and ("%d, %d, %d"):format(myPos.X, myPos.Y, myPos.Z) or "unknown"))
            local function posOf(d)
                if d:IsA("BasePart") then return d.Position end
                if d:IsA("Model") then
                    local okP, cf = pcall(function() return d:GetPivot() end)
                    if okP then return cf.Position end
                end
                return nil
            end
            local function walk(d, depth, budget)
                if budget.n <= 0 or depth > 4 then return end
                budget.n -= 1
                local pv = posOf(d)
                local extra = ""
                if pv then
                    extra = (" pos=(%d,%d,%d)"):format(pv.X, pv.Y, pv.Z)
                    if myPos then extra = extra .. (" dist=%dm"):format((pv - myPos).Magnitude) end
                end
                if d:IsA("BasePart") then extra = extra .. (" size=(%d,%d,%d) canCollide=%s"):format(d.Size.X, d.Size.Y, d.Size.Z, tostring(d.CanCollide)) end
                for k, v in pairs(d:GetAttributes()) do extra = extra .. (" @%s=%s"):format(k, tostring(v)) end
                line(string.rep("  ", depth) .. d.ClassName .. " " .. d.Name .. extra)
                for _, c in ipairs(d:GetChildren()) do walk(c, depth + 1, budget) end
            end
            for _, d in ipairs(workspace:GetChildren()) do
                local nm = d.Name:lower()
                if nm:find("zone", 1, true) or nm:find("seaboss", 1, true) or nm:find("fishing", 1, true) then
                    walk(d, 0, { n = 60 })
                end
            end
            -- any other part called zone, with the distance from the player (the compass shows one of these)
            local zc = 0
            for _, d in ipairs(workspace:GetDescendants()) do
                if zc >= 25 then break end
                if d.Name:lower():find("zone", 1, true) and (d:IsA("BasePart") or d:IsA("Model")) and not d:IsDescendantOf(player.Character or workspace) then
                    local pv = posOf(d)
                    if pv then
                        zc += 1
                        line(("%s %s  pos=(%d,%d,%d)%s"):format(d.ClassName, d:GetFullName():gsub("^Workspace%.", ""), pv.X, pv.Y, pv.Z,
                            myPos and (" dist=" .. math.floor((pv - myPos).Magnitude) .. "m") or ""))
                    end
                end
            end
            line("== workspace objects that look related ==")
            local m = 0
            for _, d in ipairs(workspace:GetDescendants()) do
                if m >= 40 then break end
                if (d:IsA("Model") or d:IsA("Folder") or d:IsA("BasePart") or d:IsA("ProximityPrompt")) and hit(d.Name) then
                    m += 1
                    line(d.ClassName .. " " .. d:GetFullName():gsub("^Workspace%.", ""))
                end
            end
            output(table.concat(out, "\n"), "fishing UI scan")
            scanBtn.Text = "Copied (" .. #out .. " lines)"
            task.delay(2.5, function() scanBtn.Text = "Scan fishing UI (copy)" end)
        end)

        local dumpBtn = button("Dump remote names (copy)", 10, TOP + 264, 286, 30, DARK)
        dumpBtn.TextSize = 13
        dumpBtn.Activated:Connect(function()
            local out = {}
            local words = { "fish", "dagon", "cast", "reel", "boss", "zone", "rod", "bait", "fight", "auto" }
            for _, d in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
                if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
                    local nm = d.Name:lower()
                    for _, w in ipairs(words) do
                        if nm:find(w, 1, true) then
                            out[#out + 1] = d.ClassName .. " " .. d:GetFullName():gsub("^ReplicatedStorage%.", "")
                            break
                        end
                    end
                end
            end
            table.sort(out)
            output("== remotes with a related name (" .. #out .. ") ==\n" .. table.concat(out, "\n"), "fishing remote names")
            dumpBtn.Text = "Copied (" .. #out .. " remotes)"
            task.delay(2.5, function() dumpBtn.Text = "Dump remote names (copy)" end)
        end)

        local note = label("Also saved to PibbleHub_fishing.txt", TOP + 300, MUTED, 12)
        note.Size = UDim2.fromOffset(286, 20)

        -- =====================================================================================================================
        -- == SEA BOSS ZONE + AUTO DAGON  (v143 rewrite)
        -- ==   Geo    : island geometry (rim / center / ground), cached while the island stands
        -- ==   Hover  : the ONLY owner of the anchored / ghosted character (hold, release, per-frame upkeep)
        -- ==   Sense  : ONE screen scan per tick (Dagon bar, "too far", "face the water") + position / compass / waypoint
        -- ==   flyTo  : the flight (up, across, down to the rim) with ejection detection
        -- ==   tick   : the ONE controller, every 0.5 s, in a fixed order; every mode change is written to the debug log
        -- =====================================================================================================================
        local function logf(fmt, ...)
            local okF, s = pcall(string.format, fmt, ...)
            print("[PibbleHub] " .. (okF and s or tostring(fmt)))
        end

        label("Sea boss zone", TOP + 330, ORANGE)
        local zoneL = label("Looking for the zone...", TOP + 352, MUTED, 13)
        zoneL.Size = UDim2.fromOffset(286, 34)
        zoneL.TextWrapped = true
        zoneL.TextTruncate = Enum.TextTruncate.None
        zoneL.TextYAlignment = Enum.TextYAlignment.Top

        local function modelPos(d)
            if d:IsA("BasePart") then return d.Position end
            if d:IsA("Model") then
                local okP, cf = pcall(function() return d:GetPivot() end)
                if okP then return cf.Position end
            end
            return nil
        end
        -- the middle of the island (average of the models of Workspace.SeaBossZone), a little above its lowest object
        local function zoneSpot()
            local folder = workspace:FindFirstChild("SeaBossZone")
            if not folder then return nil end
            local sx, sz, n, minY = 0, 0, 0, math.huge
            for _, d in ipairs(folder:GetChildren()) do
                local pv = modelPos(d)
                if pv then
                    sx += pv.X; sz += pv.Z; n += 1
                    if pv.Y < minY then minY = pv.Y end
                end
            end
            if n == 0 then return nil end
            return Vector3.new(sx / n, minY + 8, sz / n), n
        end
        local function compassText()
            local pg = player:FindFirstChildOfClass("PlayerGui")
            local sbg = pg and pg:FindFirstChild("SeaBossGui")
            local c = sbg and sbg:FindFirstChild("Compass")
            if c and c:IsA("TextLabel") and shown(c) then return clean(c.Text) end
            return nil
        end
        local function compassMeters()
            local ct = compassText()
            local num = ct and ct:match("([%d%.,]+)%s*m")
            if not num then return nil end
            return tonumber((num:gsub(",", "")))
        end

        local LOBBY = CFG.LOBBY_POS or Vector3.new(-477, 13, -40237) -- the dock of the lobby (the Dagon island is reached from there)
        local CLEAR = CFG.HOVER_CLEAR or 0.15                        -- studs between the soles and the ground while hovering

        -- ================================= Geo: the island =================================
        local Geo = { rimCache = nil, waterLevel = nil, raftCache = nil }
        function Geo.isRed(inst)
            if not (inst and inst:IsA("BasePart")) then return false end
            local c = inst.Color
            if c.R > 0.6 and c.G < 0.35 and c.B < 0.35 then return true end
            if inst.Material == Enum.Material.Neon and c.R > c.G + 0.2 and c.R > c.B + 0.2 then return true end
            local nm = inst.Name:lower()
            return (nm:find("red", 1, true) or nm:find("hunt", 1, true) or nm:find("ring", 1, true)) ~= nil and c.R > c.G
        end
        -- while a portal runs the hover is lifted by CFG.PORTAL_LIFT (default 0)
        function Geo.lift()
            if Dagon.combo and (Portal.fighting or Portal.active) then return CFG.PORTAL_LIFT or 0 end
            return 0
        end
        -- how far the root part is above the soles of the character (= the height it has when standing)
        function Geo.standOffset(char)
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if hrp then
                local okB, cf, size = pcall(function() return char:GetBoundingBox() end)
                if okB and cf then
                    local off = hrp.Position.Y - (cf.Position.Y - size.Y / 2)
                    if off > 1 and off < 8 then return off end
                end
            end
            return 3
        end
        -- ground height at (x, z): the LOWEST hit above the water (trees / umbrellas are hit first from above); nil = no island there
        function Geo.surfaceAt(x, z, char, oy, waterY)
            local prm = RaycastParams.new()
            prm.FilterType = Enum.RaycastFilterType.Exclude
            local filt = {char}
            prm.FilterDescendantsInstances = filt
            local lowest
            for _ = 1, 12 do
                local hit = workspace:Raycast(Vector3.new(x, oy, z), Vector3.new(0, -500, 0), prm)
                if not hit then break end
                if hit.Material == Enum.Material.Water or Geo.isRed(hit.Instance) then break end
                local y = hit.Position.Y
                if y <= waterY + 0.3 then break end
                lowest = y
                filt[#filt + 1] = hit.Instance
                prm.FilterDescendantsInstances = filt
            end
            return lowest
        end
        function Geo.waterY(center, char)
            local prm = RaycastParams.new()
            prm.FilterType = Enum.RaycastFilterType.Exclude
            prm.FilterDescendantsInstances = {char}
            for _, r in ipairs({160, 220, 300}) do
                for i = 0, 7 do
                    local a = i * math.pi / 4
                    local hit = workspace:Raycast(Vector3.new(center.X + math.cos(a) * r, center.Y + 80, center.Z + math.sin(a) * r),
                        Vector3.new(0, -500, 0), prm)
                    if hit and hit.Material == Enum.Material.Water then Geo.waterLevel = hit.Position.Y; return hit.Position.Y end
                end
            end
            return nil
        end
        function Geo.ground(center, char)
            local waterY = Geo.waterY(center, char) or (center.Y - 14)
            return Geo.surfaceAt(center.X, center.Z, char, center.Y + 80, waterY), waterY
        end
        -- the dead center of the island at hovering height (where the Dagon bar shows up)
        function Geo.center(zs, char)
            local gy = Geo.ground(zs, char)
            if gy then return Vector3.new(zs.X, gy + Geo.standOffset(char) + CLEAR + Geo.lift(), zs.Z) end
            return zs + Vector3.new(0, CFG.HOVER_HEIGHT or -7, 0)
        end
        -- The rim: from the center every direction is followed in 3-stud steps until there is no island ground. The hover spot is
        -- just beyond the edge (over the red zone) at the height of the rim ground. The edge is measured once per island (cached);
        -- `prefDir` (the side the flight came from) is tried first. Returns the spot and the outward direction.
        function Geo.rim(center, char, prefDir)
            local key = ("%d,%d"):format(math.floor(center.X / 10), math.floor(center.Z / 10))
            local c = Geo.rimCache
            if not (c and c.key == key and os.clock() - c.t < 180) then
                c = nil
                local waterY = Geo.waterY(center, char) or (center.Y - 14)
                if not Geo.surfaceAt(center.X, center.Z, char, center.Y + 80, waterY) then return nil end
                local function edgeIn(dir)
                    local last, lastY
                    for r = 3, 180, 3 do
                        local y = Geo.surfaceAt(center.X + dir.X * r, center.Z + dir.Z * r, char, center.Y + 80, waterY)
                        if y then last, lastY = r, y else return last, lastY end
                    end
                    return nil
                end
                local dirs = {}
                if prefDir and prefDir.Magnitude > 0.1 then dirs[1] = Vector3.new(prefDir.X, 0, prefDir.Z).Unit end
                for i = 0, 23 do
                    local a = i * math.pi / 12
                    dirs[#dirs + 1] = Vector3.new(math.cos(a), 0, math.sin(a))
                end
                for _, dir in ipairs(dirs) do
                    local er, ey = edgeIn(dir)
                    if er then
                        c = { key = key, t = os.clock(), dir = dir, er = er, ey = ey }
                        break
                    end
                end
                if not c then return nil end
                Geo.rimCache = c
                logf("rim measured: edge %d studs from the marker, ground y=%.1f, water y=%.1f", c.er, c.ey, waterY)
            end
            local out = c.er + 2 + (Dagon.standoff or 0)
            local pos = Vector3.new(center.X + c.dir.X * out, c.ey + Geo.standOffset(char) + CLEAR + Geo.lift(), center.Z + c.dir.Z * out)
            return pos, c.dir
        end
        -- The Dagon fight needs the player ON the island ("GET ON THE RAFT FIRST": contact with the ground / the raft). The raft is a part or
        -- model with "raft" in its name near the island (cached 30 s); the spot is on top of it, else the ground at the island center.
        function Geo.landing(center, char)
            local c = Geo.raftCache
            if not (c and os.clock() - c.t < 30) then
                c = { t = os.clock(), obj = nil, dist = 1e9 }
                for _, d in ipairs(workspace:GetDescendants()) do
                    if (d:IsA("BasePart") or d:IsA("Model")) and d.Name:lower():find("raft", 1, true)
                        and not (char and d:IsDescendantOf(char)) and not d:IsDescendantOf(gui) then
                        local pv = modelPos(d)
                        if pv then
                            local dd = (pv - center).Magnitude
                            if dd < 500 and dd < c.dist then c.obj, c.dist = d, dd end
                        end
                    end
                end
                Geo.raftCache = c
                if c.obj then logf("raft found: %s, %d studs from the island marker", c.obj:GetFullName():sub(-50), c.dist)
                else logf("no raft object found near the island, landing on the ground at the center") end
            end
            local off = Geo.standOffset(char) + 0.6
            if c.obj and c.obj.Parent then
                local top
                if c.obj:IsA("BasePart") then
                    top = Vector3.new(c.obj.Position.X, c.obj.Position.Y + c.obj.Size.Y / 2, c.obj.Position.Z)
                else
                    local okB, cf, size = pcall(function() return c.obj:GetBoundingBox() end)
                    if okB and cf then top = Vector3.new(cf.Position.X, cf.Position.Y + size.Y / 2, cf.Position.Z) end
                end
                if top then return top + Vector3.new(0, off, 0), "raft" end
            end
            local gy = Geo.ground(center, char)
            if gy then return Vector3.new(center.X, gy + off, center.Z), "ground" end
            return center + Vector3.new(0, CFG.HOVER_HEIGHT or -7, 0), "marker"
        end
        -- "Submerged": the dead center of the island with the character sunk into the ground (the root part below the standing height by
        -- CFG.SUBMERGE_DEPTH studs). Used anchored + ghost: the ground is "touched" for a check that looks at where the character is, while
        -- ghost mode (no touch / collision) keeps a running portal from kicking him out.
        function Geo.submerged(center, char)
            local gy = Geo.ground(center, char)
            local depth = CFG.SUBMERGE_DEPTH or 2.5
            if gy then return Vector3.new(center.X, gy + Geo.standOffset(char) - depth, center.Z), "submerged in the ground" end
            return center + Vector3.new(0, CFG.HOVER_HEIGHT or -7, 0), "marker"
        end
        -- THE default place (no rim any more): the dead center of the island, ghosted. Submerged in the ground (Dagon stand: SUBMERGE) or,
        -- in LAND mode, hovering a hair above it. Fishing, waiting and fighting all happen here.
        function Geo.middle(center, char)
            if (F.stand or "land") == "submerge" then return (Geo.submerged(center, char)) end
            return Geo.center(center, char)
        end
        -- fallback when no island ground is found: the red part nearest to the marker
        function Geo.redSpot(center, char)
            local params = OverlapParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = {char}
            local okQ, parts = pcall(function() return workspace:GetPartBoundsInRadius(center, 200, params) end)
            if not okQ or not parts then return nil end
            local best, bestD
            for _, p in ipairs(parts) do
                if Geo.isRed(p) then
                    local rel = p.CFrame:PointToObjectSpace(center)
                    local hs = p.Size / 2
                    local cl = Vector3.new(math.clamp(rel.X, -hs.X, hs.X), math.clamp(rel.Y, -hs.Y, hs.Y), math.clamp(rel.Z, -hs.Z, hs.Z))
                    local w = p.CFrame:PointToWorldSpace(cl)
                    local d = (w - center).Magnitude
                    if not bestD or d < bestD then
                        bestD = d
                        best = Vector3.new(w.X, p.Position.Y + p.Size.Y / 2 + (CFG.RED_HOVER or 3.5), w.Z)
                    end
                end
            end
            return best
        end

        -- ================================= Hover: the one owner of the anchored character =================================
        local Hover = { ghosted = {}, lastGhost = -1e9, lastHold = -1e9 }
        -- a portal is being created / joined / set up (and no Dagon is up): the character must be free to walk and teleport
        function Hover.blocked()
            return Portal.active and not Portal.fighting and not Dagon.barUp
        end
        -- near the Dagon island or the lobby (the places where falling means drowning); portal maps are far from both
        function Hover.nearIsland(hr)
            if not hr then return false end
            local z = zoneSpot()
            if z and (z - hr.Position).Magnitude < 900 then return true end
            return (hr.Position - LOBBY).Magnitude < 4500
        end
        -- ghost: no touch / query / collision on the character and no floor detection, so a "touched the ground" check sees nothing
        function Hover.ghost(on)
            local ch = player.Character
            if on then
                if not ch or Hover.blocked() then return end
                for _, d in ipairs(ch:GetDescendants()) do
                    if d:IsA("BasePart") and Hover.ghosted[d] == nil then
                        Hover.ghosted[d] = {d.CanTouch, d.CanQuery, d.CanCollide}
                        pcall(function() d.CanTouch = false; d.CanQuery = false; d.CanCollide = false end)
                    end
                end
                local hum = ch:FindFirstChildOfClass("Humanoid")
                if hum then pcall(function() hum.PlatformStand = true end) end
                if not Dagon.ghostOn then
                    local n = 0
                    for _ in pairs(Hover.ghosted) do n += 1 end
                    logf("ghost mode ON (%d parts)", n)
                end
                Dagon.ghostOn = true
            else
                for d, v in pairs(Hover.ghosted) do
                    pcall(function() d.CanTouch, d.CanQuery, d.CanCollide = v[1], v[2], v[3] end)
                end
                Hover.ghosted = {}
                if Dagon.ghostOn then logf("ghost mode OFF") end
                Dagon.ghostOn = false
                local hum = ch and ch:FindFirstChildOfClass("Humanoid")
                if hum then pcall(function() hum.PlatformStand = false end) end
            end
        end
        Dagon.ghost = Hover.ghost
        -- put the character at `pos` (looking along `look` when given), anchored and ghosted
        function Hover.hold(pos, look, why)
            local char = player.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if not hrp then return false end
            if Hover.blocked() then
                logf("hover refused (%s): a portal is being created / joined, the character must stay free", tostring(why))
                return false
            end
            logf("hover: %s -> (%.0f, %.0f, %.0f)", tostring(why), pos.X, pos.Y, pos.Z)
            pcall(function()
                hrp.Anchored = false
                hrp.AssemblyLinearVelocity = Vector3.zero
                if look and look.Magnitude > 0.1 then
                    hrp.CFrame = CFrame.lookAt(pos, pos + Vector3.new(look.X, 0, look.Z))
                else
                    hrp.CFrame = CFrame.new(pos) * (hrp.CFrame - hrp.CFrame.Position)
                end
                hrp.Anchored = true
            end)
            Dagon.hoverRoot, Dagon.hoverSpot = hrp, hrp.Position
            Dagon.edgeDir = look
            Hover.ghost(true)
            Dagon.holdUntil = os.clock() + 8 -- put here on purpose: counts as "at the island" for a while
            return true
        end
        function Hover.release(reason)
            if Dagon.hoverRoot then
                local ph = Dagon.hoverRoot.Position
                logf("hover released: %s (at %.0f, %.0f, %.0f)", tostring(reason or "?"), ph.X, ph.Y, ph.Z)
                pcall(function() Dagon.hoverRoot.Anchored = false end)
            end
            Dagon.hoverRoot, Dagon.hoverSpot = nil, nil
            Hover.ghost(false)
            local ch = player.Character
            local hr = ch and ch:FindFirstChild("HumanoidRootPart")
            if hr and hr.Anchored then pcall(function() hr.Anchored = false end) end
        end
        -- Stand on the island / raft: no anchor, no ghost, the character touches the ground (needed to fight the Dagon)
        function Hover.land(pos, why)
            local ch = player.Character
            local hr = ch and ch:FindFirstChild("HumanoidRootPart")
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            if not (hr and hum) then return false end
            if Hover.blocked() then return false end
            logf("landing: %s -> (%.0f, %.0f, %.0f)", tostring(why), pos.X, pos.Y, pos.Z)
            Hover.release("landing")
            pcall(function()
                hum.PlatformStand = false
                hr.AssemblyLinearVelocity = Vector3.zero
                hr.CFrame = CFrame.new(pos) * (hr.CFrame - hr.CFrame.Position)
            end)
            Dagon.holdUntil = os.clock() + 8
            return true
        end
        -- move to `pos` looking along `look`: in LAND mode the character stands there (free, no hover), else the old anchored hover
        function Hover.place(pos, look, why)
            if (F.stand or "land") ~= "land" then return Hover.hold(pos, look, why) end
            local ok = Hover.land(pos, why)
            if ok and look then
                local hr = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
                if hr then pcall(function() hr.CFrame = CFrame.lookAt(hr.Position, hr.Position + Vector3.new(look.X, 0, look.Z)) end) end
            end
            return ok
        end
        -- Leaving the hover: while still held (anchored) the character is first put on the lobby dock, THEN let go, so he can never
        -- fall into the sea. Without a hover / outside the island area it is a plain release.
        function Hover.leave(why)
            local ch = player.Character
            local hr = ch and ch:FindFirstChild("HumanoidRootPart")
            local held = Dagon.hoverRoot ~= nil or Dagon.ghostOn or (hr ~= nil and hr.Anchored)
            if hr and held and Hover.nearIsland(hr) then
                local dest = Dagon.home or (LOBBY + Vector3.new(0, 5, 0))
                logf("leaving the island (%s): hop to the dock first so the character cannot fall", tostring(why))
                pcall(function()
                    hr.Anchored = true
                    hr.AssemblyLinearVelocity = Vector3.zero
                    hr.CFrame = CFrame.new(dest)
                end)
                Hover.release(why)
                return true
            end
            Hover.release(why)
            return false
        end
        Dagon.release = Hover.release
        -- used by the Portal code before it teleports / walks: no hover, no ghost, no anchor, no PlatformStand; waits a moment when
        -- something had to be undone (the physics settle on the ground)
        Dagon.free = function(why)
            local did = Hover.leave(why or "free")
            local ch = player.Character
            local hr = ch and ch:FindFirstChild("HumanoidRootPart")
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            local fixed = false
            if hr and hr.Anchored then pcall(function() hr.Anchored = false end); fixed = true end
            if hum and hum.PlatformStand then pcall(function() hum.PlatformStand = false end); fixed = true end
            if did or fixed then task.wait(0.5) end
        end
        -- per-frame upkeep: stays anchored (the game may un-anchor), ghost stays on, small drift is pulled back.
        -- A big jump (> 60 studs) is NOT corrected: that is the game moving the player (ejected), the controller handles it.
        connect(game:GetService("RunService").Heartbeat, function()
            local hr = Dagon.hoverRoot
            if not hr then return end
            if not hr.Parent then Dagon.hoverRoot = nil; return end
            local now = os.clock()
            if now - Hover.lastGhost > 1 then
                Hover.lastGhost = now
                pcall(Hover.ghost, true)
            end
            pcall(function()
                if not hr.Anchored then
                    hr.Anchored = true
                    if now - Hover.lastHold > 3 then
                        Hover.lastHold = now
                        logf("hover: the game un-anchored the character, anchored again")
                    end
                end
                local spot = Dagon.hoverSpot
                if spot then
                    local d = (hr.Position - spot).Magnitude
                    if d > 2 and d < 60 then
                        hr.CFrame = CFrame.new(spot) * (hr.CFrame - hr.CFrame.Position)
                        hr.AssemblyLinearVelocity = Vector3.zero
                    end
                end
            end)
        end)
        gui.Destroying:Connect(function()
            pcall(function() if Dagon.hoverRoot then Dagon.hoverRoot.Anchored = false end; Hover.ghost(false) end)
        end)

        -- ================================= Sense: what is on the screen =================================
        -- One pass over the visible labels: the blue Dagon bar (by its own texts only: "BABY DAGON", "DAGON VS TOJI", "SEA BOSS | DAGON"...;
        -- the World Boss bar / "DAGON HUNT" title / waypoint gui never count), a "too far" message, a "face the water" message.
        local Scr = { t = -1e9, bar = false, barText = nil, far = false, face = false, raft = false, throw = false, lastFarText = nil }
        local function scanScreen()
            local now = os.clock()
            if now - Scr.t < 0.2 then return Scr end
            Scr.t = now
            local bar, barText, far, face, raft, throw = false, nil, false, false, false, false
            local pg = player:FindFirstChildOfClass("PlayerGui")
            if pg then
                for _, g in ipairs(pg:GetChildren()) do
                    if g:IsA("ScreenGui") and g ~= gui and g.Enabled then
                        local noBar = g.Name == "FishingBar" or g.Name == "DagonWaypoint"
                        for _, d in ipairs(g:GetDescendants()) do
                            if d:IsA("TextLabel") and shown(d) then
                                local t = clean(d.Text):lower()
                                if t ~= "" then
                                    if t:find("face the water", 1, true) or t:find("auto fishing stopped", 1, true) then face = true end
                                    if #t <= 40 and t:find("click to throw", 1, true) then throw = true end -- the idle cast prompt
                                    if #t <= 60 and t:find("raft", 1, true) then raft = true end -- "GET ON THE RAFT FIRST."
                                    if #t <= 80 and (t:find("%f[%a]far%f[%A]") or t:find("closer", 1, true) or t:find("%f[%a]range%f[%A]")
                                        or t:find("distance", 1, true)) then
                                        far = true
                                        if t ~= Scr.lastFarText then Scr.lastFarText = t; logf("distance message on screen: '%s'", t) end
                                    end
                                    if not bar and not noBar then
                                        if t:find("world boss", 1, true) or t:find("server meter", 1, true) or t:find("berserk", 1, true) then
                                            -- the World Boss bar: never the Dagon
                                        elseif t:find("sea boss", 1, true) or (t:find("dagon", 1, true) and not t:find("hunt", 1, true)) then
                                            bar, barText = true, t
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            Scr.bar, Scr.barText, Scr.far, Scr.face, Scr.raft, Scr.throw = bar, barText, far, face, raft, throw
            return Scr
        end
        local function fightUp()
            local s = scanScreen()
            return s.bar, s.barText
        end
        -- the game's waypoint to a far Dagon (the blue bar only shows when in front of it)
        local function waypointShown()
            local pg = player:FindFirstChildOfClass("PlayerGui")
            local wp = pg and pg:FindFirstChild("DagonWaypoint")
            if not wp then return false end
            if wp:IsA("ScreenGui") and not wp.Enabled then return false end
            local holder = wp:FindFirstChild("Holder", true) or wp
            local okS, r = pcall(shown, holder)
            return okS and r == true
        end
        -- in the lobby = inside the LobbyZone of the lobby map (else: close to a spawn point)
        local lobbyPart
        local function inLobby(hrp)
            if not hrp then return false end
            if not (lobbyPart and lobbyPart.Parent) then
                lobbyPart = nil
                pcall(function()
                    local maps = workspace:FindFirstChild("Maps")
                    local lob = maps and maps:FindFirstChild("CoastalLobby")
                    lobbyPart = lob and lob:FindFirstChild("LobbyZone", true) or nil
                end)
            end
            if lobbyPart then
                local cf, size
                if lobbyPart:IsA("BasePart") then cf, size = lobbyPart.CFrame, lobbyPart.Size
                else
                    local ok, c, sz = pcall(function() return lobbyPart:GetBoundingBox() end)
                    if ok then cf, size = c, sz end
                end
                if cf and size then
                    local rel = cf:PointToObjectSpace(hrp.Position)
                    return math.abs(rel.X) <= size.X / 2 + 12 and math.abs(rel.Z) <= size.Z / 2 + 12 and math.abs(rel.Y) <= size.Y / 2 + 60
                end
            end
            local sp = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
            if sp then
                local d = hrp.Position - sp.Position
                return Vector3.new(d.X, 0, d.Z).Magnitude < 250
            end
            return false
        end

        -- ================================= flyTo =================================
        local traveling = false
        local travelToken = 0
        local stopStamp = -1e9 -- os.clock() of the last Dagon.stop (a flight cut short by the Priority system)
        local TRAVEL_SPEED = CFG.ZONE_SPEED or 300 -- studs per second
        -- Flies up, across and down in small steps (the game never sees one huge jump). When the target is the island and Auto Dagon is
        -- on, it ends in a hover over the rim, looking outward. Returns true when the flight completed.
        local function flyTo(target)
            local char = player.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if not hrp then return false end
            traveling = true
            travelToken += 1
            local token = travelToken
            local startedAt = os.clock()
            local zz = zoneSpot()
            local toZone = zz ~= nil and (zz - target).Magnitude < 25 -- (the marker is an average and can move a little)
            local hover = Dagon.on and toZone
            if Dagon.hoverRoot then Hover.release("a new flight starts") end
            if Dagon.combo then
                if toZone and (hrp.Position - LOBBY).Magnitude > 1500 then
                    -- the portal world is far away: first a hop to the lobby coordinates, the flight starts there
                    logf("combo: teleporting to the lobby coordinates first")
                    pcall(function()
                        hrp.AssemblyLinearVelocity = Vector3.zero
                        hrp.CFrame = CFrame.new(LOBBY + Vector3.new(0, 5, 0))
                    end)
                    task.wait(1.0) -- (let the game register the new place before the flight starts)
                    hrp = (player.Character and player.Character:FindFirstChild("HumanoidRootPart")) or hrp
                end
                Dagon.home = LOBBY + Vector3.new(0, 5, 0) -- the way back is the lobby, not the portal world
            elseif zz and (zz - hrp.Position).Magnitude > 500 then
                Dagon.home = hrp.Position + Vector3.new(0, 4, 0)
            end
            local startPos = hrp.Position
            local alt = math.max(startPos.Y, target.Y) + 40
            local rimPos, rimDir
            local ejected, timedOut = false, false
            local t0 = os.clock()
            local path = {
                Vector3.new(startPos.X, alt, startPos.Z),
                Vector3.new(target.X, alt, target.Z),
                function()
                    if not hover then return target end
                    -- above the island now (its parts are loaded): where to hover
                    rimPos, rimDir = Geo.middle(target, char), nil
                    if not Geo.ground(target, char) then
                        rimPos = target + Vector3.new(0, CFG.HOVER_HEIGHT or -7, 0)
                        logf("flight: island ground not found, hovering at the marker")
                    end
                    pcall(Hover.ghost, true) -- the last part of the way goes through trees / rocks: no collision
                    return rimPos
                end,
            }
            local okFly, errFly = pcall(function()
                local lastSet
                for _, wp0 in ipairs(path) do
                    local wp = type(wp0) == "function" and wp0() or wp0
                    while gui.Parent and token == travelToken do
                        if not hrp.Parent then return end
                        if os.clock() - t0 > 150 then timedOut = true; return end
                        local cur = hrp.Position
                        if lastSet and (cur - lastSet).Magnitude > 120 then ejected = true; return end -- the game moved the player
                        local delta = wp - cur
                        if delta.Magnitude < 6 then break end
                        local dt = task.wait()
                        local step = math.min(delta.Magnitude, TRAVEL_SPEED * dt)
                        hrp.AssemblyLinearVelocity = Vector3.zero
                        lastSet = cur + delta.Unit * step
                        hrp.CFrame = CFrame.new(lastSet) * (hrp.CFrame - hrp.CFrame.Position)
                    end
                end
            end)
            traveling = false
            logf("flight ended: ok=%s cancelled=%s ejected=%s timedOut=%s hover=%s pos=%s", tostring(okFly), tostring(token ~= travelToken),
                tostring(ejected), tostring(timedOut), tostring(hover), hrp.Parent and ("%d,%d,%d"):format(hrp.Position.X, hrp.Position.Y, hrp.Position.Z) or "-")
            if not okFly then logf("flight error: %s", tostring(errFly)) end
            if timedOut then logf("flight timed out after 150 s") end
            local function hopHome(why)
                -- left in the air near the island without a hover: straight to the dock, never into the sea
                local hr2 = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
                if Dagon.on and hr2 and not Dagon.hoverRoot and Hover.nearIsland(hr2) then
                    logf("flight ended early (%s): hop to the dock", why)
                    pcall(function()
                        hr2.Anchored = false
                        hr2.AssemblyLinearVelocity = Vector3.zero
                        hr2.CFrame = CFrame.new(Dagon.home or (LOBBY + Vector3.new(0, 5, 0)))
                    end)
                end
            end
            if ejected then
                Dagon.standoff = math.min((Dagon.standoff or 0) + 15, 90)
                Dagon.tpBlockUntil = os.clock() + 20
                logf("flight: ejected, next time %d studs beyond the rim", Dagon.standoff)
                return false
            end
            if token ~= travelToken and stopStamp >= startedAt then hopHome("cut short by the Priority system")
            elseif timedOut then hopHome("timed out")
            elseif not okFly then hopHome("error") end
            -- ghost mode must never stay on without a hover (a ghost character falls through the ground)
            if not Dagon.hoverRoot and not (hover and okFly and token == travelToken) and Dagon.ghostOn then Hover.ghost(false) end
            if hover and okFly and token == travelToken and hrp.Parent then
                pcall(function() hrp.AssemblyLinearVelocity = Vector3.zero end)
                local arrive = rimPos or hrp.Position
                if (F.stand or "land") == "land" then
                    local lp = Geo.landing(target, char)
                    if lp then arrive = lp end
                end
                if not Hover.place(arrive, rimDir, "arrived at the island") then
                    hopHome("the hover was refused") -- (a portal started meanwhile): never stay unanchored over the sea
                end
                if not rimDir and Dagon.faceWater then task.delay(0.4, function() pcall(Dagon.faceWater, "arrived at the island") end) end
            end
            return okFly and not timedOut
        end

        local goBtn = button("Go to the zone now", 10, TOP + 392, 286, 30, BLUE)
        goBtn.TextSize = 13
        goBtn.Activated:Connect(function()
            if traveling then travelToken += 1; goBtn.Text = "Go to the zone now"; return end
            local spot = zoneSpot()
            if not spot then goBtn.Text = "No zone right now"; task.delay(2, function() goBtn.Text = "Go to the zone now" end); return end
            goBtn.Text = "Flying... (tap to stop)"
            task.spawn(function()
                flyTo(spot)
                goBtn.Text = "Go to the zone now"
            end)
        end)

        local travelBtn = button("Auto travel to zone: OFF", 10, TOP + 428, 286, 30, RED)
        travelBtn.TextSize = 13
        local function setTravelUI()
            travelBtn.Text = F.travel and "Auto travel to zone: ON" or "Auto travel to zone: OFF"
            travelBtn.BackgroundColor3 = F.travel and GREEN or RED
        end
        travelBtn.Activated:Connect(function()
            F.travel = not F.travel
            setTravelUI()
            Settings.save()
        end)
        setTravelUI()

        task.spawn(function()
            local lastTravel = -1e9
            while gui.Parent do
                task.wait(2)
                local okZ, errZ = pcall(function()
                    local spot = zoneSpot()
                    local compass = compassText()
                    local char = player.Character
                    local hrp = char and char:FindFirstChild("HumanoidRootPart")
                    if spot and hrp then
                        local d = (spot - hrp.Position).Magnitude
                        zoneL.Text = ("Zone found, %dm away%s"):format(d, compass and (" | " .. compass) or "")
                        if F.travel and not Dagon.on and not traveling and d > 80 and os.clock() - lastTravel > 30
                            and not (Raid.running or WorldBoss.active or Portal.active or Infinite.popBusy) then
                            lastTravel = os.clock()
                            task.spawn(flyTo, spot)
                        end
                    else
                        zoneL.Text = compass and ("Compass: " .. compass .. " (zone folder is empty)") or "No zone right now"
                    end
                end)
                if not okZ then warn("[PibbleHub] zone watcher error:", errZ) end
            end
        end)

        -- ================================= Auto Dagon: switches =================================
        label("Auto Dagon", TOP + 466, ORANGE)
        local dagonBtn = button("Auto Dagon: OFF", 10, TOP + 488, 286, 32, RED)
        local dagonL = label("", TOP + 524, MUTED, 13)
        dagonL.Size = UDim2.fromOffset(286, 48)
        dagonL.TextWrapped = true
        dagonL.TextTruncate = Enum.TextTruncate.None
        dagonL.TextYAlignment = Enum.TextYAlignment.Top
        local function setDagonUI()
            dagonBtn.Text = Dagon.on and "Auto Dagon: ON" or "Auto Dagon: OFF"
            dagonBtn.BackgroundColor3 = Dagon.on and GREEN or RED
        end
        Dagon.on = F.dagon == true
        setDagonUI()
        dagonBtn.Activated:Connect(function()
            Dagon.on = not Dagon.on
            F.dagon = Dagon.on
            if Dagon.on and not F.on then F.on = true; setFishUI() end
            setDagonUI()
            Settings.save()
            if not Dagon.on then
                Dagon.busy = false
                travelToken += 1
            end
        end)
        -- used by the Guard: what is on, and turning it back on
        Dagon.getAuto = function() return Dagon.on, F.on end
        Dagon.resumeAuto = function(dagonOn, fishOn)
            if dagonOn then Dagon.on = true; F.dagon = true end
            if fishOn or dagonOn then F.on = true end
            setDagonUI()
            setFishUI()
            Settings.save()
        end
        -- used by the Guard: Auto Dagon (and the fishing it drives) off
        Dagon.stopAuto = function()
            Dagon.on = false
            F.dagon = false
            F.on = false
            setDagonUI()
            setFishUI()
            Dagon.busy = false
            travelToken += 1
            Settings.save()
        end
        -- the Portal + Dagon combo was removed (the two fight over where the character stands): always off
        Dagon.combo = false
        F.combo = false
        Dagon.wantsFn = function() return Dagon.on and zoneSpot() ~= nil end
        Dagon.stop = function() travelToken += 1; stopStamp = os.clock() end

        -- the Dagon fight's own AUTO ("AUTO: OFF" next to the blue bar; not the fishing bar's "Auto: Off"). It disappears every time
        -- the "CURRENT FLOOR" label shows up, so it is checked every 0.25 s and pressed through its own handler (works hidden too).
        local function bossAuto()
            local pg = player:FindFirstChildOfClass("PlayerGui")
            if not pg then return nil end
            local best, bestShown
            local function consider(d, inSea)
                if not (d:IsA("TextButton") or d:IsA("TextLabel")) then return end
                local t = clean(d.Text):lower():match("^%s*(.-)%s*$")
                local st = t:match("^auto%s*:%s*(%a+)$")
                if not st then return end
                local b = d:IsA("GuiButton") and d or d:FindFirstAncestorWhichIsA("GuiButton") or d
                local sh = shown(d)
                if not inSea then -- outside the sea boss gui only the upper part of the screen counts (the fishing bar's Auto is at the bottom)
                    local cam = workspace.CurrentCamera
                    local h = cam and cam.ViewportSize.Y or 800
                    if not sh or d.AbsolutePosition.Y > h * 0.55 then return end
                end
                if sh and not bestShown then bestShown = {b, st} end
                if not best then best = {b, st} end
            end
            local sbg = pg:FindFirstChild("SeaBossGui")
            if sbg then for _, d in ipairs(sbg:GetDescendants()) do consider(d, true) end end
            if not best then
                for _, g in ipairs(pg:GetChildren()) do
                    if g:IsA("ScreenGui") and g ~= gui and g.Enabled and g.Name ~= "FishingHud" and g.Name ~= "FishingBar" then
                        for _, d in ipairs(g:GetDescendants()) do consider(d, false) end
                    end
                end
            end
            local r = bestShown or best
            if r then return r[1], r[2] end
            return nil
        end
        task.spawn(function()
            local lastPress, tries = -1e9, 0
            while gui.Parent do
                task.wait(0.25)
                if Dagon.on then
                    pcall(function()
                        if not fightUp() then tries = 0; return end
                        local b, st = bossAuto()
                        if not b then return end
                        if st == "on" then tries = 0; return end
                        if os.clock() - lastPress < 1.2 then return end
                        lastPress = os.clock()
                        tries += 1
                        logf("boss Auto is '%s', pressing (%d)", tostring(st), tries)
                        activateButton(b)
                        if tries >= 4 and shown(b) then realClick(b) end -- the handler did not answer: a real click (only when visible)
                    end)
                end
            end
        end)

        -- ================================= facing / rim =================================
        -- "AUTO FISHING STOPPED: FACE THE WATER TO CAST": to the rim (over the red zone, facing outward). Ignored while a Dagon is up.
        -- With no rim found the player is only turned toward the water (24 directions, red zone counts double).
        local lastFace, lastRim = -1e9, -1e9
        -- the best direction toward the water from `origin`: 24 directions, rays down at several distances; the red Dagon zone counts 2,
        -- plain water 1, the island itself 0. Ties go to the direction pointing away from the island center.
        local function waterDir(origin, char, zs, radii)
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = {char}
            local outward = zs and Vector3.new(origin.X - zs.X, 0, origin.Z - zs.Z) or Vector3.zero
            if outward.Magnitude > 0.1 then outward = outward.Unit end
            local bestDir, bestScore, bestDot = nil, -1, -2
            for i = 0, 23 do
                local ang = i * math.pi / 12
                local dir = Vector3.new(math.cos(ang), 0, math.sin(ang))
                local score = 0
                for _, r in ipairs(radii) do
                    local p = origin + dir * r
                    local hit = workspace:Raycast(Vector3.new(p.X, origin.Y + 30, p.Z), Vector3.new(0, -200, 0), params)
                    if hit and Geo.isRed(hit.Instance) then score += 2
                    elseif (not hit) or hit.Material == Enum.Material.Water then score += 1 end
                end
                local dot = dir:Dot(outward)
                if score > bestScore or (score == bestScore and dot > bestDot) then bestDir, bestScore, bestDot = dir, score, dot end
            end
            return bestDir, bestScore
        end
        local function faceWaterTurn(why)
            if os.clock() - lastFace < 2 then return end
            lastFace = os.clock()
            local char = player.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if not hrp then return end
            local origin = hrp.Position
            local dir, score = waterDir(origin, char, zoneSpot(), {15, 30, 50})
            if dir then
                logf("%s -> turning toward the water (score %d/6)", tostring(why), score)
                pcall(function() hrp.CFrame = CFrame.lookAt(origin, origin + dir) end)
            end
        end
        -- (kept under its old name) go to THE place: the middle of the island, ghosted
        local function goRim(why, skipIfNear)
            local char = player.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            local zs = zoneSpot()
            if not (hrp and zs and (zs - hrp.Position).Magnitude < 600) then return false end
            local pos = Geo.middle(zs, char)
            if (F.stand or "land") == "land" then
                local lp = Geo.landing(zs, char)
                if lp then pos = lp end
                if skipIfNear and (hrp.Position - pos).Magnitude < 6 then return true end
            elseif skipIfNear and Dagon.hoverRoot and (hrp.Position - pos).Magnitude < 6 then return true end -- already there
            C.landed = false
            return Hover.place(pos, nil, tostring(why) .. ": to the middle")
        end
        -- a spot `r` studs from the island center toward `dir` (stepping back until there is ground), at hovering / submerged height
        local function spotToward(zs, char, dir, r)
            local waterY = Geo.waterLevel or Geo.waterY(zs, char) or (zs.Y - 14)
            local rr = r
            while rr >= 0 do
                local y = Geo.surfaceAt(zs.X + dir.X * rr, zs.Z + dir.Z * rr, char, zs.Y + 80, waterY)
                if y then
                    local sub = (F.stand or "land") == "submerge"
                    local off = Geo.standOffset(char) + (sub and -(CFG.SUBMERGE_DEPTH or 2.5) or CLEAR)
                    return Vector3.new(zs.X + dir.X * rr, y + off, zs.Z + dir.Z * rr), rr
                end
                rr -= 3
            end
            return nil
        end
        -- FORCED REPOSITION: the game says "face the water" / "auto fishing stopped", or the character is not fishing (Auto off, or the idle
        -- "Click to Throw" prompt for 10 s). Each request goes one step further: 1) turn toward the water, 2-4) move toward the water
        -- (12 / 24 / 40 studs from the center, facing it), 5) back to the middle; then it starts again. Steps restart after 60 s without a request.
        local REPO = { "turn", 12, 24, 40, "middle" }
        local function reposition(why)
            local now = os.clock()
            if now - C.lastRepo > 60 then C.repoStage = 0 end
            C.lastRepo = now
            C.repoStage = (C.repoStage % #REPO) + 1
            local st = REPO[C.repoStage]
            local char = player.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            local zs = zoneSpot()
            if not (hrp and zs) then return end
            logf("REPOSITION (%s): step %d/%d = %s", tostring(why), C.repoStage, #REPO, tostring(st))
            if st == "turn" then
                lastFace = -1e9
                faceWaterTurn(why)
            elseif st == "middle" then
                goRim(why)
                lastFace = -1e9
                faceWaterTurn(why)
            else
                local dir = waterDir(zs, char, zs, {20, 40, 60, 80})
                if not dir then faceWaterTurn(why); return end
                local pos = spotToward(zs, char, dir, st)
                if pos then Hover.place(pos, dir, ("%s: %d studs toward the water"):format(tostring(why), st)) else faceWaterTurn(why) end
            end
        end
        Dagon.faceWater = function(why)
            if os.clock() - lastRim < 3 then return end
            lastRim = os.clock()
            if Dagon.barUp then return end
            if not Dagon.hoverRoot then
                goRim(why) -- (not hovering yet: to the middle first, then turn)
                lastFace = -1e9
                faceWaterTurn(why)
                return
            end
            reposition(why)
        end
        -- the same system message arrives in the chat: TextChatService, and the chat window labels as a second source
        local function onFaceMessage(src)
            if Dagon.on and Dagon.faceWater then task.defer(Dagon.faceWater, src) end
        end
        pcall(function()
            local TCS = game:GetService("TextChatService")
            connect(TCS.MessageReceived, function(m)
                local tx = m and m.Text
                if type(tx) == "string" and tx:lower():find("face the water", 1, true) then onFaceMessage("chat message") end
            end)
        end)
        task.spawn(function()
            local seen = setmetatable({}, {__mode = "k"})
            local first = true
            while gui.Parent do
                pcall(function()
                    local cg = game:GetService("CoreGui")
                    local root = cg:FindFirstChild("ExperienceChat") or cg:FindFirstChild("Chat")
                    if not root then return end
                    for _, d in ipairs(root:GetDescendants()) do
                        if (d:IsA("TextLabel") or d:IsA("TextButton")) and not seen[d] then
                            if clean(d.Text):lower():find("face the water", 1, true) then
                                seen[d] = true
                                if not first then onFaceMessage("chat window label") end
                            end
                        end
                    end
                end)
                first = false
                task.wait(1)
            end
        end)

        -- ================================= debug dump of the bar UI (first time a bar is seen) =================================
        local function dumpDagonUI()
            local pg = player:FindFirstChildOfClass("PlayerGui")
            local sbg = pg and pg:FindFirstChild("SeaBossGui")
            if not sbg then return end
            local out, n = {}, 0
            for _, d in ipairs(sbg:GetDescendants()) do
                if n >= 60 then break end
                if d:IsA("GuiObject") and shown(d) then
                    n += 1
                    local txt = (d:IsA("TextButton") or d:IsA("TextLabel")) and clean(d.Text) or ""
                    out[#out + 1] = ("%s %s%s%s"):format(d.ClassName, d:GetFullName():gsub("^.-SeaBossGui%.", ""),
                        txt ~= "" and (' text="' .. txt .. '"') or "", d:IsA("GuiButton") and " BUTTON" or "")
                end
            end
            logf("SeaBossGui visible objects:\n%s", table.concat(out, "\n"))
        end

        -- ================================= the controller =================================
        -- One tick every 0.5 s. Fixed order: sense -> housekeeping -> fight tracking -> rescue -> at the island (rim / center) ->
        -- far from the island (gate / priority / flight). Nothing else moves the character.
        C = {
            mode = "off", fighting = false, lastFightSeen = 0, dumped = false,
            upSince = nil, downSince = nil, centered = false, movedFromRim = false,
            lastMsgTp = -1e9, lastFarRim = -1e9, lastFlight = -1e9, hoverMiss = 0,
            goneSince = nil, wpSince = nil, lastState = -1e9, step = nil, pfSince = nil,
            repoStage = 0, lastRepo = -1e9, notFishSince = nil,
            landed = false, landSpot = nil, lastRaft = -1e9, lastPrompt = -1e9, promptTries = 0, holding = false, promptCache = nil, promptAt = -1e9,
        }
        -- The "E - Dagon Fight" proximity prompt is a HOLD prompt. Odd tries hold it for real (InputHoldBegin, wait HoldDuration, InputHoldEnd),
        -- even tries use fireproximityprompt with the hold time set to 0 (client side). The activation distance / line of sight are relaxed.
        -- Runs in its own thread (C.holding) so the controller keeps ticking; it is called again and again while the Dagon is up but its
        -- bar is not.
        local function firePrompt(try)
            if os.clock() - C.promptAt > 30 or (C.promptCache and not C.promptCache.Parent) then
                C.promptAt, C.promptCache = os.clock(), nil
                for _, d in ipairs(workspace:GetDescendants()) do
                    if d:IsA("ProximityPrompt") then
                        local txt = (tostring(d.ActionText) .. " " .. tostring(d.ObjectText)):lower()
                        if txt:find("dagon", 1, true) then C.promptCache = d; break end
                    end
                end
                local pr0 = C.promptCache
                logf("Dagon prompt: %s%s", pr0 and pr0:GetFullName():sub(-50) or "none found",
                    pr0 and (" (hold %.1fs, distance %d, action '%s')"):format(pr0.HoldDuration, pr0.MaxActivationDistance, tostring(pr0.ActionText)) or "")
            end
            local pr = C.promptCache
            if not pr then return false end
            C.holding = true
            task.spawn(function()
                local hold = pr.HoldDuration
                pcall(function()
                    pr.RequiresLineOfSight = false
                    pr.MaxActivationDistance = math.max(pr.MaxActivationDistance, 60)
                end)
                if try % 2 == 0 and typeof(fireproximityprompt) == "function" then
                    pcall(function() pr.HoldDuration = 0 end)
                    pcall(fireproximityprompt, pr)
                    task.wait(0.3)
                    pcall(function() pr.HoldDuration = hold end)
                else
                    pcall(function() pr:InputHoldBegin() end)
                    task.wait(math.max(hold, 0.3) + 0.4)
                    pcall(function() pr:InputHoldEnd() end)
                end
                C.holding = false
            end)
            return true
        end
        -- the routine, as it is logged: every step is written once when it starts (so the log shows where a cycle stopped)
        local function routine(step, text)
            if C.step ~= step then
                C.step = step
                logf("ROUTINE %s", text)
            end
        end
        local function setMode(m, why)
            if C.mode ~= m then
                logf("mode %s -> %s (%s)", C.mode, m, tostring(why or ""))
                C.mode = m
                Dagon.mode = m
            end
        end

        local function sense()
            local S = { now = os.clock() }
            S.char = player.Character
            S.hrp = S.char and S.char:FindFirstChild("HumanoidRootPart")
            S.hum = S.char and S.char:FindFirstChildOfClass("Humanoid")
            local sc = scanScreen()
            S.bar, S.barText, S.far, S.face, S.raft, S.throw = sc.bar, sc.barText, sc.far, sc.face, sc.raft, sc.throw
            S.zone = zoneSpot()
            S.zoneDist = (S.zone and S.hrp) and (S.zone - S.hrp.Position).Magnitude or nil
            S.compass = compassMeters()
            -- at the island: the compass ("COMPASS 32m") decides when it can be read, else the distance to the marker
            local near = S.zoneDist ~= nil and S.zoneDist <= 250
            if S.compass then near = S.compass <= 200 end
            S.atZone = near or S.now < (Dagon.holdUntil or 0)
            -- the island is gone for good after 6 s: forget what was measured on it
            if S.zone then C.goneSince = nil else C.goneSince = C.goneSince or S.now end
            if C.goneSince and S.now - C.goneSince > 6 and Geo.rimCache then
                Geo.rimCache = nil
                logf("the island is gone, measurements cleared")
            end
            -- the waypoint counts as "a Dagon is up" only after it was seen OFF while the island stood (an always-on waypoint must not
            -- block the portals), and not when it has been shown for more than 12 minutes
            S.wp = waypointShown()
            if S.wp then C.wpSince = C.wpSince or S.now else C.wpSince = nil end
            if not S.wp and S.zone then Dagon.wpTrusted = true end
            local wpCounts = S.wp and Dagon.wpTrusted == true and C.wpSince ~= nil and S.now - C.wpSince < 720
            S.dagonUp = (S.bar or wpCounts) and true or false
            S.swimming = S.hum ~= nil and S.hum.Health > 0 and S.hum:GetState() == Enum.HumanoidStateType.Swimming
            return S
        end

        local function tick()
            local S = sense()
            local now = S.now
            if not S.hrp then return end

            -- ---- housekeeping ----
            if not F.on then F.on = true; setFishUI() end -- the Dagon comes from fishing: the game's Auto fish stays on
            Dagon.atZone = S.atZone
            Dagon.barUp = S.dagonUp
            -- ejected back into the portal: the anchored player is suddenly far from where he was put
            if Dagon.hoverRoot and Dagon.hoverSpot and Dagon.hoverRoot.Parent and (Dagon.hoverRoot.Position - Dagon.hoverSpot).Magnitude > 60 then
                Hover.release("ejected (moved >60 studs by the game)")
                Dagon.standoff = math.min((Dagon.standoff or 0) + 15, 90)
                Dagon.tpBlockUntil = now + 20
                C.lastFlight = now - 22 -- the next try in about 8 s
                logf("ejected back to the portal, next time %d studs beyond the rim", Dagon.standoff)
            end
            if C.landed and C.landSpot and S.hrp and (S.hrp.Position - C.landSpot).Magnitude > 120 then
                C.landed = false
                Dagon.standoff = math.min((Dagon.standoff or 0) + 15, 90)
                Dagon.tpBlockUntil = now + 20
                C.lastFlight = now - 22
                logf("ejected while standing on the island (now %d studs from the landing spot): next try in ~8 s", (S.hrp.Position - C.landSpot).Magnitude)
            end
            if Dagon.ghostOn and not Dagon.hoverRoot and not traveling then Hover.ghost(false) end -- (ghost without a hover would sink through the ground)
            if not Portal.active and not Portal.fighting then Dagon.standoff = 0 end
            -- a portal is being created: the anchor must not hold the player (teleports need him free)
            if Hover.blocked() and Dagon.hoverRoot then
                routine("9", "9: the portal fight is over -> back to the lobby dock; a new portal starts only when no Dagon is up")
                Hover.leave("a portal is being created / joined")
            end
            -- the portal fight just started: the combo waits a few seconds (Auto Fight / Stop Auto On Loss settle) before leaving the map
            if Portal.fighting then C.pfSince = C.pfSince or now else C.pfSince = nil end
            -- hovering, but the island is not near any more (3 s of grace): hop to the dock, then let go
            if Dagon.hoverRoot then
                if S.atZone then
                    C.hoverMiss = 0
                else
                    C.hoverMiss += 1
                    if C.hoverMiss >= 6 then
                        Hover.leave("not at the island any more (checked 6 times)")
                        C.hoverMiss = 0
                    end
                end
            else
                C.hoverMiss = 0
            end

            -- ---- fight tracking (the blue bar, any form) ----
            if S.bar then
                if not C.fighting then
                    C.fighting, C.dumped = true, false
                    logf("Dagon bar is up: %s", tostring(S.barText))
                end
                C.lastFightSeen = now
                if not C.dumped then C.dumped = true; dumpDagonUI() end
            elseif C.fighting and now - C.lastFightSeen > 12 then
                C.fighting = false
                logf("Dagon bar is gone")
            end
            -- the bar is a server-wide event bar (also shown in the lobby / in a portal): it only means "fighting" at the island
            Dagon.busy = (C.fighting and S.atZone) or traveling

            -- (falling / swimming near the island is handled by the drown guard loop below, independent of this controller)

            -- ---- messages from the game ----
            if S.face then Dagon.faceWater("label on screen") end

            -- ---- at the island ----
            local atIsland = S.atZone or (S.zoneDist ~= nil and S.zoneDist < 600)
            if atIsland and not traveling then
                if S.dagonUp then
                    C.repoStage = 0
                    C.upSince = C.upSince or now
                    C.downSince = nil
                else
                    C.downSince = C.downSince or now
                    C.upSince = nil
                end
                -- A Dagon is up. The fight needs contact with the ground ("GET ON THE RAFT FIRST"): the character LANDS on the raft / the
                -- island center (no anchor, no ghost). While a portal fight still runs, touching the ground would send him back into the
                -- portal, so he waits hovering at the center and lands the moment the portal fight is over.
                if S.dagonUp and S.zone and now > (Dagon.tpBlockUntil or 0) then
                    if (F.stand or "land") == "submerge" then
                        -- anchored + ghost, sunk into the ground at the center: no wait for the portal (ghost = no touch, no kick)
                        if S.raft and C.landed and now - C.lastRaft > 4 then
                            -- the game still asks for the raft: the submerged trick does not work, use the real landing from now on
                            F.stand = "land"
                            Settings.save()
                            C.landed = false
                            logf("'get on the raft' while submerged -> switching to the real landing (Dagon stand: LAND)")
                        elseif not C.landed then
                            C.lastRaft = now
                            local pos, kind = Geo.submerged(S.zone, S.char)
                            if Hover.hold(pos, nil, "Dagon is up: " .. kind .. " at the center") then
                                C.landed, C.landSpot, C.centered, C.movedFromRim = true, pos, true, true
                                C.promptTries = 0
                                setMode("center", kind)
                                routine("7", "7: Dagon is up -> " .. kind .. " (anchored + ghost), boss Auto on")
                            end
                        end
                    elseif Portal.fighting then
                        if not C.centered then
                            C.centered, C.movedFromRim = true, true
                            setMode("center", "Dagon is up, portal still fighting")
                            routine("7a", "7a: Dagon is up but the portal fight still runs -> hover at the center, landing when the portal is over")
                            Hover.hold(Geo.center(S.zone, S.char), nil, "Dagon is up: center (waiting for the portal)")
                        end
                    elseif not C.landed or (S.raft and now - C.lastRaft > 4) then
                        C.lastRaft = now
                        local pos, kind = Geo.landing(S.zone, S.char)
                        if Hover.land(pos, "Dagon is up, standing on the " .. kind) then
                            C.landed, C.landSpot, C.centered, C.movedFromRim = true, pos, true, true
                            C.promptTries = 0
                            setMode("center", "landed on the " .. kind)
                            routine("7", "7: Dagon is up -> landed on the " .. kind .. " (contact with the ground), boss Auto on")
                        end
                    end
                    if C.landed and not S.bar and not C.holding and now - C.lastPrompt > 2.5 then
                        -- standing on it, the Dagon is up but its bar is not: hold its "E - Dagon Fight" prompt, again and again
                        C.lastPrompt = now
                        C.promptTries += 1
                        if C.promptTries <= 3 or C.promptTries % 10 == 0 then
                            logf("holding the Dagon Fight prompt (try %d)", C.promptTries)
                        end
                        firePrompt(C.promptTries)
                    end
                -- over (no bar for 4 s): back to the rim, the place for fishing
                elseif not S.dagonUp and C.movedFromRim and C.downSince and now - C.downSince > 4 then
                    C.movedFromRim, C.centered, C.landed = false, false, false
                    routine("8", "8: Dagon is over -> back to the middle (ghost), fishing")
                    if goRim("no Dagon up") then setMode("rim", "Dagon over") end
                -- a "too far" message while fishing: as close to the land as possible (the rim), at most every 8 s
                elseif not S.dagonUp and S.far and S.zone and Dagon.hoverRoot and now - C.lastFarRim > 8 then
                    C.lastFarRim = now
                    goRim("'too far' message", true)
                end
                if C.centered and not S.dagonUp and C.downSince and now - C.downSince > 4 then C.centered, C.landed = false, false end
                if C.landed then Dagon.holdUntil = math.max(Dagon.holdUntil or 0, now + 3) end
            end

            -- ---- fishing watchdog: at the middle, no Dagon, and not fishing (game Auto off, or the idle "Click to Throw" prompt) for 10 s -> reposition ----
            if Dagon.hoverRoot and not S.dagonUp and not traveling and now > (Dagon.holdUntil or 0) + 2 then
                local ab = autoButton()
                local off = ab ~= nil and autoState(ab) ~= "on"
                if off or S.throw then
                    C.notFishSince = C.notFishSince or now
                    if now - C.notFishSince > 10 then
                        C.notFishSince = now
                        Dagon.faceWater(S.throw and "idle 'Click to Throw' for 10 s" or "game Auto is off for 10 s")
                    end
                else
                    C.notFishSince = nil
                end
            else
                C.notFishSince = nil
            end

            -- ---- status text + far from the island ----
            if C.fighting and S.atZone then
                dagonL.Text = "Dagon: Auto fighting (" .. tostring(S.barText):sub(1, 24) .. ")"
                return
            end
            if not S.zone then
                local lobby = inLobby(S.hrp)
                if C.mode ~= "rescue" then setMode("wait", lobby and "lobby, no island" or "no island") end
                dagonL.Text = lobby and "In the lobby: Auto off, waiting for the island" or "Fishing, waiting for the sea boss zone"
                return
            end
            if C.landed then
                dagonL.Text = ((F.stand or "land") == "submerge") and "Dagon is up: submerged at the center, boss Auto on"
                    or "Dagon is up: standing on the island, boss Auto on"
                return
            end
            if Dagon.hoverRoot then
                setMode(S.dagonUp and "center" or "rim", S.dagonUp and "Dagon is up" or "hovering at the island")
                if not S.dagonUp then routine("6", "6: at the middle of the island (ghost), facing the water, game Auto cast on, waiting for the Dagon") end
                dagonL.Text = S.dagonUp and "Dagon is up: at the center" or "At the island: Auto fish on"
                return
            end
            if S.zoneDist and S.zoneDist <= 80 then
                dagonL.Text = S.swimming and "In the water" or "At the island: Auto fish on"
                return
            end
            if traveling then
                dagonL.Text = ("Flying to the zone (%dm)"):format(S.zoneDist or 0)
                return
            end
            local by = Prio.blockedBy("Dagon")
            -- combo: the island only after the portal has started its fight (or when there is no portal to do)
            local gate = Dagon.combo and ((Portal.active and not Portal.fighting) or (Portal.ready and not Portal.active and not S.dagonUp))
            local settling = Dagon.combo and Portal.fighting and C.pfSince ~= nil and now - C.pfSince < (CFG.COMBO_SETTLE or 4)
            if gate or settling then
                if gate then
                    routine("1", "1-3: a portal is being created / joined / set up (Auto Fight ON, Stop Auto On Loss OFF) - the island waits")
                else
                    routine("3", "3: portal fight started - settling a few seconds before leaving the map")
                end
                setMode("gated", gate and "combo: waiting for the portal fight" or "combo: portal fight settling")
                dagonL.Text = gate and "Combo: waiting until the portal fight runs" or "Combo: portal fight started, settling..."
            elseif by then
                setMode("gated", "priority: " .. tostring(by))
                dagonL.Text = ("Zone is up, %s goes first"):format(Prio.label(by))
            elseif now - C.lastFlight > 30 then
                C.lastFlight = now
                setMode("flying", "island is up")
                routine("4", "4-5: hop to the lobby coordinates, fly to the island and down to the rim")
                dagonL.Text = "Zone is up, flying there"
                Dagon.busy = true
                task.spawn(function()
                    local okF = flyTo(S.zone)
                    if okF and C.mode == "flying" then setMode("rim", "arrived") end
                end)
            end
        end

        task.spawn(function()
            while gui.Parent do
                task.wait(0.5)
                if Dagon.on then
                    local okD, errD = xpcall(tick, debug.traceback)
                    if not okD then
                        warn("[PibbleHub] auto dagon error:", errD)
                        pcall(logf, "TICK ERROR: %s", tostring(errD):sub(1, 400))
                        task.wait(2) -- (do not spam the same error 2 times a second)
                    end
                else
                    if C.mode ~= "off" then setMode("off", "Auto Dagon is off") end
                    Dagon.busy, Dagon.atZone, Dagon.barUp = false, false, false
                    if Dagon.hoverRoot then Hover.leave("Auto Dagon is off") end
                    C.fighting = false
                    dagonL.Text = ""
                end
            end
        end)

        -- ================================= drown guard =================================
        -- Independent of the controller, 5 times a second: a character near the island / lobby that is swimming (or far below the sea
        -- level) and is not flying or hovering is put on the lobby dock at once. Still swimming after 10 s: respawn (the respawn is the
        -- lobby). The island vanishes when the fight is over, so this is the safety net for every way of falling in.
        task.spawn(function()
            local swimSince, lastHop, hops = nil, -1e9, 0
            while gui.Parent do
                task.wait(0.2)
                if Dagon.on then
                    pcall(function()
                        local ch = player.Character
                        local hr = ch and ch:FindFirstChild("HumanoidRootPart")
                        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
                        if not (hr and hum) or hum.Health <= 0 or traveling or Dagon.hoverRoot then swimSince = nil; return end
                        if not Hover.nearIsland(hr) then swimSince = nil; return end
                        local z = zoneSpot()
                        local inWater = hum:GetState() == Enum.HumanoidStateType.Swimming
                            or (z ~= nil and Geo.waterLevel ~= nil and hr.Position.Y < Geo.waterLevel - 2.5)
                        if not inWater then
                            if swimSince and os.clock() - swimSince > 1.5 then hops = 0 end
                            swimSince = nil
                            return
                        end
                        local now = os.clock()
                        swimSince = swimSince or now
                        if now - swimSince >= 0.6 and now - lastHop > 3 then
                            lastHop = now
                            hops += 1
                            logf("DROWN GUARD: in the water -> hop to the dock (#%d)", hops)
                            dagonL.Text = "In the water: back to the dock"
                            pcall(function()
                                hr.Anchored = false
                                hr.AssemblyLinearVelocity = Vector3.zero
                                hr.CFrame = CFrame.new(Dagon.home or (LOBBY + Vector3.new(0, 5, 0)))
                            end)
                        end
                        if now - swimSince >= 10 then
                            logf("DROWN GUARD: still in the water after 10 s -> respawn")
                            swimSince = nil
                            hum.Health = 0
                        end
                    end)
                end
            end
        end)

        -- ================================= debug log: state line every 4 s + copy / clear =================================
        task.spawn(function()
            while gui.Parent do
                task.wait(4)
                if Dagon.on then
                    pcall(function()
                        local ch = player.Character
                        local hr = ch and ch:FindFirstChild("HumanoidRootPart")
                        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
                        local zs = zoneSpot()
                        local up = fightUp()
                        local ab = autoButton()
                        local bb, bst = bossAuto()
                        local an = workspace:FindFirstChild("DagonWaypointAnchor")
                        local ap = an and modelPos(an)
                        ComboLog.push(("STATE mode=%s combo=%s atZone=%s busy=%s trav=%s hover=%s standoff=%s | portal act=%s fight=%s ready=%s | pos=%s zoneDist=%s compass=%s bar=%s/wp=%s/anchor=%s fishAuto=%s bossAuto=%s swim=%s"):format(
                            tostring(C.mode), tostring(Dagon.combo), tostring(Dagon.atZone), tostring(Dagon.busy), tostring(traveling),
                            tostring(Dagon.hoverRoot ~= nil) .. (Dagon.ghostOn and "(ghost)" or ""), tostring(Dagon.standoff),
                            tostring(Portal.active), tostring(Portal.fighting), tostring(Portal.ready),
                            hr and ("%d,%d,%d"):format(hr.Position.X, hr.Position.Y, hr.Position.Z) or "-",
                            (zs and hr) and tostring(math.floor((zs - hr.Position).Magnitude)) or "-",
                            tostring(compassText()), tostring(up), tostring(waypointShown()),
                            ap and ("%d,%d,%d"):format(ap.X, ap.Y, ap.Z) or "none",
                            ab and tostring(autoState(ab)) .. (shown(ab) and "" or "(hidden)") or "none",
                            bb and tostring(bst) or "none",
                            hum and tostring(hum:GetState()) or "-"))
                    end)
                end
            end
        end)
        local standBtn = button("Dagon stand: SUBMERGE", 10, TOP + 680, 286, 30, BLUE)
        standBtn.TextSize = 13
        local function setStandUI()
            local sub = (F.stand or "land") == "submerge"
            standBtn.Text = sub and "Dagon stand: SUBMERGE (ghost in ground)" or "Dagon stand: LAND (raft / ground)"
        end
        setStandUI()
        standBtn.Activated:Connect(function()
            F.stand = ((F.stand or "land") == "submerge") and "land" or "submerge"
            Settings.save()
            setStandUI()
        end)
        task.spawn(function() -- (the fight code can switch it by itself)
            while gui.Parent do task.wait(1); pcall(setStandUI) end
        end)
        local logCountL = label("", TOP + 650, MUTED, 12)
        local copyLogBtn = button("Copy debug log", 10, TOP + 616, 140, 30, BLUE)
        copyLogBtn.TextSize = 13
        copyLogBtn.Activated:Connect(function()
            local n = #ComboLog.lines
            local from = math.max(1, n - 449)
            local text = "PibbleHub log (" .. (n - from + 1) .. " lines)\n" .. table.concat(ComboLog.lines, "\n", from, n)
            local okC = typeof(setclipboard) == "function" and pcall(setclipboard, text)
            if typeof(writefile) == "function" then pcall(writefile, "PibbleHub_combo.txt", table.concat(ComboLog.lines, "\n")) end
            copyLogBtn.Text = okC and "Copied!" or "Saved to file"
            task.delay(2, function() copyLogBtn.Text = "Copy debug log" end)
        end)
        local clearLogBtn = button("Clear log", 156, TOP + 616, 140, 30, DARK)
        clearLogBtn.TextSize = 13
        clearLogBtn.Activated:Connect(function()
            ComboLog.lines = {}
            ComboLog.push("log cleared")
        end)
        -- on-screen live log (for testing where the panel can't be scrolled): last lines, always visible, click it to
        -- switch between 14 / 30 lines or hide it
        pcall(function()
            local old = gui.Parent:FindFirstChild("PibbleLogOverlay"); if old then old:Destroy() end
            local ov = Instance.new("ScreenGui")
            ov.Name = "PibbleLogOverlay"; ov.ResetOnSpawn = false; ov.DisplayOrder = 999; ov.IgnoreGuiInset = true
            ov.Parent = gui.Parent
            local box = Instance.new("TextButton")
            box.AutoButtonColor = false
            box.Size = UDim2.new(0, 560, 0, 190); box.Position = UDim2.new(1, -566, 1, -196)
            box.BackgroundColor3 = Color3.new(0, 0, 0); box.BackgroundTransparency = 0.35; box.BorderSizePixel = 0
            box.TextColor3 = Color3.fromRGB(190, 255, 190); box.Font = Enum.Font.Code; box.TextSize = 10
            box.TextXAlignment = Enum.TextXAlignment.Left; box.TextYAlignment = Enum.TextYAlignment.Bottom
            box.TextWrapped = true; box.Text = ""; box.Parent = ov
            local nLines, hidden = 14, false
            box.Activated:Connect(function()
                if nLines == 14 then nLines = 30 elseif nLines == 30 then nLines = 0; hidden = true else nLines = 14; hidden = false end
                box.Visible = not hidden
            end)
            task.spawn(function()
                while gui.Parent do
                    task.wait(1)
                    if not hidden then
                        local L, n = ComboLog.lines, #ComboLog.lines
                        local from = math.max(1, n - nLines + 1)
                        local out = {}
                        for i = from, n do out[#out + 1] = (L[i]:gsub("^%d+:%d+:%d+ %+", "+")):sub(1, 150) end
                        box.Text = table.concat(out, "\n")
                    end
                end
                ov:Destroy()
            end)
        end)
        task.spawn(function()
            while gui.Parent do
                task.wait(2)
                logCountL.Text = ("%d log lines (also saved to PibbleHub_combo.txt)"):format(#ComboLog.lines)
            end
        end)
    end)

    pcall(layoutTabs)

    -- =====================================================================
    -- == 12. BATTLEEND ROUTER + RESTORE OF THE SAVED SWITCHES
    -- =====================================================================
    -- 1) a raid fight  2) a world boss fight  3) a boss fight started by Auto Boss  4) a dungeon fight  5) the Infinite Tower
    -- Every handler runs in a pcall: an error in one feature can never block the others.
    -- A feature whose block failed to load has no handler and is simply skipped.
    connect(Remotes.BattleEnd.OnClientEvent, function(data)
        if not gui.Parent or type(data) ~= "table" then return end
        for _, owner in ipairs({Raid, WorldBoss, Boss, Dungeon, Infinite}) do
            local handler = owner.onBattleEnd
            if handler then
                local okH, handled = pcall(handler, data)
                if not okH then
                    warn("[PibbleHub] BattleEnd handler error:", handled)
                elseif handled then
                    return
                end
            end
        end
    end)

    -- Restore the Auto / Pop switches a few seconds after launch (the game needs to be loaded),
    -- then start saving. Saving only starts after the restore, so a click made during
    -- the delay cannot overwrite the saved state.
    task.delay(CFG.RESTORE_DELAY, function()
        if not gui.Parent then return end
        local d = Settings.data
        if d.autoBoss == true and not Boss.auto and Boss.setAuto then pcall(Boss.setAuto, true) end
        if d.autoRaid == true and not Raid.auto and Raid.setAuto then pcall(Raid.setAuto, true) end
        if d.autoDungeon == true and not Dungeon.auto and Dungeon.setAuto then pcall(Dungeon.setAuto, true) end
        if d.autoWorldBoss == true and not WorldBoss.auto and WorldBoss.setAuto then pcall(WorldBoss.setAuto, true) end
        if d.pop == true and not Infinite.on and Infinite.setPop then pcall(Infinite.setPop, true) end
        if d.followOn == true and not Settings.follow.on and Portal.setFollow then pcall(Portal.setFollow, true) end
        Settings.armed = true
        Settings.save()
        print("[PibbleHub] loaded")
    end)
end

-- =========================================================================
-- == 13. START-UP
-- =========================================================================
-- No embedded icon: the toggle button shows a "P". (To add one again, assign a base64 JPEG string to ICON_B64 here,
-- or set CFG.ICON_ID to an "rbxassetid://..." image.)
ICON_B64 = ""

local ok, err = xpcall(runHub, debug.traceback)

if not ok then
    warn("PibbleHub error:", err)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "PibbleHub error",
            Text = tostring(err):sub(1, 150),
            Duration = 10,
        })
    end)
end