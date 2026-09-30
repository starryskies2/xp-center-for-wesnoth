-- XP Control Center
-- Target: Battle for Wesnoth 1.18.x
--
-- Performance design:
--   * XP caps are written directly to unit.max_experience.
--   * The natural (uncapped) max_experience is stored on the unit so a cap can
--     be raised/disabled later from the in-game settings window.
--   * Normal gameplay never scans the map/recall list for XP caps.
--   * Caps are initialized once and refreshed only after advancement/AMLA.
--   * A full unit scan happens only when the player manually changes a cap
--     setting in the XP Control Center window.
--   * Combat XP processes only attacker and defender.
--   * Healers are cached by unit ID; healing turns iterate cached healers only.
--   * The healer cache is rebuilt only when healing XP is manually enabled.

local opts = nil
local attack_stack = {}
local healing_snapshots = {}
local healer_cache = {}
local healer_side = {}
local dialog_cfg = nil

local function as_bool(value, default)
    if value == nil then return default == true end
    return value == true or value == "yes" or value == 1 or value == "1"
end

local function clamp_int(value, default, minimum, maximum)
    value = tonumber(value) or default
    value = math.floor(value)
    if minimum ~= nil and value < minimum then value = minimum end
    if maximum ~= nil and value > maximum then value = maximum end
    return value
end

local function copy_runtime_value(runtime_name, option_name, default, is_boolean)
    if wml.variables[runtime_name] ~= nil then return end

    local source = wml.variables[option_name]
    if is_boolean then
        wml.variables[runtime_name] = as_bool(source, default)
    else
        wml.variables[runtime_name] = tonumber(source) or default
    end
end

local function ensure_runtime_settings()
    -- These variables are ordinary campaign variables, so changes made from the
    -- in-game dialog survive saves and scenario transitions. The original
    -- modification option variables remain the initial defaults only.
    copy_runtime_value("xcc_runtime_player_cap_enabled", "xcc_player_cap_enabled", true, true)
    copy_runtime_value("xcc_runtime_player_cap", "xcc_player_cap", 500, false)
    copy_runtime_value("xcc_runtime_player_rate", "xcc_player_rate", 100, false)

    copy_runtime_value("xcc_runtime_separate_leaders", "xcc_separate_leaders", true, true)
    copy_runtime_value("xcc_runtime_leader_cap_enabled", "xcc_leader_cap_enabled", true, true)
    copy_runtime_value("xcc_runtime_leader_cap", "xcc_leader_cap", 500, false)
    copy_runtime_value("xcc_runtime_leader_rate", "xcc_leader_rate", 100, false)

    copy_runtime_value("xcc_runtime_healing_xp_enabled", "xcc_healing_xp_enabled", true, true)
    copy_runtime_value("xcc_runtime_healing_xp_per_unit", "xcc_healing_xp_per_unit", 1, false)

    copy_runtime_value("xcc_runtime_enemies_enabled", "xcc_enemies_enabled", false, true)
    copy_runtime_value("xcc_runtime_enemy_cap_enabled", "xcc_enemy_cap_enabled", true, true)
    copy_runtime_value("xcc_runtime_enemy_cap", "xcc_enemy_cap", 500, false)
    copy_runtime_value("xcc_runtime_enemy_rate", "xcc_enemy_rate", 100, false)

end

local function read_options()
    ensure_runtime_settings()

    opts = {
        player_cap_enabled = as_bool(wml.variables.xcc_runtime_player_cap_enabled, true),
        player_cap = clamp_int(wml.variables.xcc_runtime_player_cap, 500, 25, 5000),
        player_rate = clamp_int(wml.variables.xcc_runtime_player_rate, 100, 100, 500),

        separate_leaders = as_bool(wml.variables.xcc_runtime_separate_leaders, true),
        leader_cap_enabled = as_bool(wml.variables.xcc_runtime_leader_cap_enabled, true),
        leader_cap = clamp_int(wml.variables.xcc_runtime_leader_cap, 500, 25, 5000),
        leader_rate = clamp_int(wml.variables.xcc_runtime_leader_rate, 100, 100, 500),

        healing_xp_enabled = as_bool(wml.variables.xcc_runtime_healing_xp_enabled, true),
        healing_xp_per_unit = clamp_int(wml.variables.xcc_runtime_healing_xp_per_unit, 1, 1, 25),

        enemies_enabled = as_bool(wml.variables.xcc_runtime_enemies_enabled, false),
        enemy_cap_enabled = as_bool(wml.variables.xcc_runtime_enemy_cap_enabled, true),
        enemy_cap = clamp_int(wml.variables.xcc_runtime_enemy_cap, 500, 25, 5000),
        enemy_rate = clamp_int(wml.variables.xcc_runtime_enemy_rate, 100, 100, 500),
    }
end

local function ensure_options()
    if opts == nil then read_options() end
end

local function copy_options(source)
    local result = {}
    for key, value in pairs(source) do result[key] = value end
    return result
end

local function is_human_side(side_number)
    local side = wesnoth.sides[side_number]
    return side ~= nil and side.controller == "human"
end

local function is_enemy_of_any_human(side_number)
    local side = wesnoth.sides[side_number]
    if side == nil or side.controller == "human" then return false end

    for _, human_side in ipairs(wesnoth.sides) do
        if human_side.controller == "human" and human_side:is_enemy(side_number) then
            return true
        end
    end
    return false
end

-- Returns cap_enabled, cap_value, combat_rate.
local function settings_for_unit(unit)
    ensure_options()
    if unit == nil then return false, nil, 100 end

    if is_human_side(unit.side) then
        if opts.separate_leaders and unit.canrecruit then
            return opts.leader_cap_enabled, opts.leader_cap, opts.leader_rate
        end
        return opts.player_cap_enabled, opts.player_cap, opts.player_rate
    end

    if opts.enemies_enabled and is_enemy_of_any_human(unit.side) then
        return opts.enemy_cap_enabled, opts.enemy_cap, opts.enemy_rate
    end

    return false, nil, 100
end

local function is_persistent_unit(unit)
    return unit ~= nil and (unit.valid == "map" or unit.valid == "recall")
end

local function remember_natural_max(unit)
    if not is_persistent_unit(unit) then return nil end

    local natural = tonumber(unit.variables.xcc_natural_max_experience)
    if natural == nil or natural < 1 then
        natural = math.max(1, math.floor(tonumber(unit.max_experience) or 1))
        unit.variables.xcc_natural_max_experience = natural
    else
        natural = math.max(1, math.floor(natural))
    end
    return natural
end

local function apply_selected_cap(unit)
    if not is_persistent_unit(unit) then return end

    local natural = remember_natural_max(unit)
    if natural == nil then return end

    local cap_enabled, cap = settings_for_unit(unit)
    local desired = natural
    if cap_enabled then
        cap = math.max(1, math.floor(tonumber(cap) or natural))
        if cap < desired then desired = cap end
    end

    if unit.max_experience ~= desired then
        unit.max_experience = desired
    end
    unit.variables.xcc_cap_initialized = true
end

local function initialize_unit(unit)
    if unit == nil or unit.valid ~= "map" then return end
    remember_natural_max(unit)
    apply_selected_cap(unit)
end

local function effective_cap_settings(value)
    local player = value.player_cap_enabled and value.player_cap or false

    local leader = player
    if value.separate_leaders then
        leader = value.leader_cap_enabled and value.leader_cap or false
    end

    local enemy = false
    if value.enemies_enabled and value.enemy_cap_enabled then
        enemy = value.enemy_cap
    end

    return player, leader, enemy
end

local function cap_settings_changed(old, new)
    local old_player, old_leader, old_enemy = effective_cap_settings(old)
    local new_player, new_leader, new_enemy = effective_cap_settings(new)
    return old_player ~= new_player
        or old_leader ~= new_leader
        or old_enemy ~= new_enemy
end

local function reapply_caps_after_manual_change()
    -- Deliberately the only full map+recall cap scan in the mod. It runs only
    -- after the player presses Save with a changed cap setting.
    for _, unit in ipairs(wesnoth.units.find {}) do
        local cap_enabled = settings_for_unit(unit)
        if cap_enabled or unit.variables.xcc_cap_initialized then
            apply_selected_cap(unit)
        end
    end
end

local function combat_xp(level)
    local multiplier = tonumber(wesnoth.game_config.combat_experience) or 1
    return math.floor(multiplier * math.max(0, tonumber(level) or 0))
end

local function kill_xp(level)
    local multiplier = tonumber(wesnoth.game_config.kill_experience) or 8
    level = math.max(0, tonumber(level) or 0)
    if level == 0 then return math.floor(multiplier / 2) end
    return math.floor(multiplier * level)
end

local function add_combat_bonus(unit, base_xp, rate)
    if unit == nil or unit.valid ~= "map" or unit.hitpoints <= 0 then return end

    base_xp = math.max(0, math.floor(tonumber(base_xp) or 0))
    rate = math.max(100, math.floor(tonumber(rate) or 100))
    if base_xp <= 0 or rate <= 100 then return end

    -- Keep large-XP handling simple: add only the requested bonus. Core Wesnoth
    -- adds the normal award and performs its normal advancement/AMLA handling.
    local total = math.floor((base_xp * rate) / 100)
    local bonus = total - base_xp
    if bonus > 0 then
        unit.experience = math.max(0, math.floor(tonumber(unit.experience) or 0)) + bonus
    end
end

local function remove_healer_id(unit_id)
    if unit_id == nil or unit_id == "" then return end

    local old_side = healer_side[unit_id]
    if old_side ~= nil then
        local side_cache = healer_cache[old_side]
        if side_cache ~= nil then
            side_cache[unit_id] = nil
            if next(side_cache) == nil then healer_cache[old_side] = nil end
        end
        healer_side[unit_id] = nil
    end
end

local function refresh_healer(unit)
    ensure_options()
    if unit == nil then return end

    local id = unit.id
    if id == nil or id == "" then return end

    remove_healer_id(id)

    if not opts.healing_xp_enabled
        or unit.valid ~= "map"
        or unit.hitpoints <= 0
        or not is_human_side(unit.side)
        or not unit:matches { ability_type = "heals" }
    then
        return
    end

    local side_cache = healer_cache[unit.side]
    if side_cache == nil then
        side_cache = {}
        healer_cache[unit.side] = side_cache
    end

    side_cache[id] = true
    healer_side[id] = unit.side
end

local function rebuild_healer_cache()
    healer_cache = {}
    healer_side = {}
    healing_snapshots = {}

    ensure_options()
    if not opts.healing_xp_enabled then return end

    -- This scan is only used when healing XP is manually switched from off to
    -- on during a scenario. Normal turns never scan the map for healers.
    for _, unit in ipairs(wesnoth.units.find_on_map { ability_type = "heals" }) do
        refresh_healer(unit)
    end
end

local function snapshot_healing(side_number)
    ensure_options()
    healing_snapshots[side_number] = nil

    if not opts.healing_xp_enabled or not is_human_side(side_number) then return end

    local side_cache = healer_cache[side_number]
    if side_cache == nil then return end

    local targets = {}
    local stale = nil

    for healer_id in pairs(side_cache) do
        local healer = wesnoth.units.get(healer_id)
        if healer == nil
            or healer.valid ~= "map"
            or healer.hitpoints <= 0
            or healer.side ~= side_number
            or not healer:matches { ability_type = "heals" }
        then
            if stale == nil then stale = {} end
            stale[#stale + 1] = healer_id
        else
            for x, y in wesnoth.current.map:iter_adjacent(healer) do
                local target = wesnoth.units.get(x, y)
                if target ~= nil
                    and target.valid == "map"
                    and target.hitpoints > 0
                    and target.id ~= healer_id
                    and target.side == side_number
                then
                    local entry = targets[target.id]
                    if entry == nil then
                        entry = { hp = target.hitpoints, healers = {} }
                        targets[target.id] = entry
                    end
                    entry.healers[healer_id] = true
                end
            end
        end
    end

    if stale ~= nil then
        for _, healer_id in ipairs(stale) do remove_healer_id(healer_id) end
    end

    if next(targets) ~= nil then healing_snapshots[side_number] = targets end
end

local function award_healing(side_number)
    ensure_options()

    local targets = healing_snapshots[side_number]
    healing_snapshots[side_number] = nil
    if not opts.healing_xp_enabled or targets == nil then return end

    local awards = {}

    for target_id, entry in pairs(targets) do
        local target = wesnoth.units.get(target_id)
        if target ~= nil and target.valid == "map" and target.hitpoints > entry.hp then
            for healer_id in pairs(entry.healers) do
                awards[healer_id] = (awards[healer_id] or 0) + opts.healing_xp_per_unit
            end
        end
    end

    for healer_id, amount in pairs(awards) do
        local healer = wesnoth.units.get(healer_id)
        if healer ~= nil
            and healer.valid == "map"
            and healer.hitpoints > 0
            and is_human_side(healer.side)
            and amount > 0
        then
            healer.experience = math.max(0, math.floor(tonumber(healer.experience) or 0)) + amount

            if healer.experience >= healer.max_experience then
                healer:advance(false, true)
            end
        end
    end
end

local function get_dialog_cfg()
    if dialog_cfg == nil then
        local loaded = wml.load(
            "~add-ons/XP_Control_Center/gui/settings_dialog.cfg",
            true,
            "schema/gui_window.cfg"
        )
        dialog_cfg = wml.get_child(loaded, "resolution")
    end
    return dialog_cfg
end

local function write_dialog_settings(result)
    wml.variables.xcc_runtime_player_cap_enabled = as_bool(result.player_cap_enabled, true)
    wml.variables.xcc_runtime_player_cap = clamp_int(result.player_cap, 500, 25, 5000)
    wml.variables.xcc_runtime_player_rate = clamp_int(result.player_rate, 100, 100, 500)

    wml.variables.xcc_runtime_separate_leaders = as_bool(result.separate_leaders, true)
    wml.variables.xcc_runtime_leader_cap_enabled = as_bool(result.leader_cap_enabled, true)
    wml.variables.xcc_runtime_leader_cap = clamp_int(result.leader_cap, 500, 25, 5000)
    wml.variables.xcc_runtime_leader_rate = clamp_int(result.leader_rate, 100, 100, 500)

    wml.variables.xcc_runtime_healing_xp_enabled = as_bool(result.healing_xp_enabled, true)
    wml.variables.xcc_runtime_healing_xp_per_unit = clamp_int(result.healing_xp_per_unit, 1, 1, 25)

    wml.variables.xcc_runtime_enemies_enabled = as_bool(result.enemies_enabled, false)
    wml.variables.xcc_runtime_enemy_cap_enabled = as_bool(result.enemy_cap_enabled, true)
    wml.variables.xcc_runtime_enemy_cap = clamp_int(result.enemy_cap, 500, 25, 5000)
    wml.variables.xcc_runtime_enemy_rate = clamp_int(result.enemy_rate, 100, 100, 500)
end

local function show_settings_dialog()
    ensure_options()
    local current = copy_options(opts)

    local result = wesnoth.sync.evaluate_single(function()
        local values = {}

        local function pre_show(window)
            local function widget(id)
                return window:find(id)
            end

            widget("xcc_gui_player_cap_enabled").selected = current.player_cap_enabled
            widget("xcc_gui_player_cap").value = current.player_cap
            widget("xcc_gui_player_rate").value = current.player_rate

            widget("xcc_gui_separate_leaders").selected = current.separate_leaders
            widget("xcc_gui_leader_cap_enabled").selected = current.leader_cap_enabled
            widget("xcc_gui_leader_cap").value = current.leader_cap
            widget("xcc_gui_leader_rate").value = current.leader_rate

            widget("xcc_gui_healing_xp_enabled").selected = current.healing_xp_enabled
            widget("xcc_gui_healing_xp_per_unit").value = current.healing_xp_per_unit

            widget("xcc_gui_enemies_enabled").selected = current.enemies_enabled
            widget("xcc_gui_enemy_cap_enabled").selected = current.enemy_cap_enabled
            widget("xcc_gui_enemy_cap").value = current.enemy_cap
            widget("xcc_gui_enemy_rate").value = current.enemy_rate

            local function update_enabled()
                widget("xcc_gui_player_cap").enabled = widget("xcc_gui_player_cap_enabled").selected

                local leaders = widget("xcc_gui_separate_leaders").selected
                widget("xcc_gui_leader_cap_enabled").enabled = leaders
                widget("xcc_gui_leader_cap").enabled = leaders and widget("xcc_gui_leader_cap_enabled").selected
                widget("xcc_gui_leader_rate").enabled = leaders

                local healing = widget("xcc_gui_healing_xp_enabled").selected
                widget("xcc_gui_healing_xp_per_unit").enabled = healing

                local enemies = widget("xcc_gui_enemies_enabled").selected
                widget("xcc_gui_enemy_cap_enabled").enabled = enemies
                widget("xcc_gui_enemy_cap").enabled = enemies and widget("xcc_gui_enemy_cap_enabled").selected
                widget("xcc_gui_enemy_rate").enabled = enemies
            end

            widget("xcc_gui_player_cap_enabled").on_modified = update_enabled
            widget("xcc_gui_separate_leaders").on_modified = update_enabled
            widget("xcc_gui_leader_cap_enabled").on_modified = update_enabled
            widget("xcc_gui_healing_xp_enabled").on_modified = update_enabled
            widget("xcc_gui_enemies_enabled").on_modified = update_enabled
            widget("xcc_gui_enemy_cap_enabled").on_modified = update_enabled
            update_enabled()
        end

        local function post_show(window)
            local function widget(id)
                return window:find(id)
            end

            values.player_cap_enabled = widget("xcc_gui_player_cap_enabled").selected
            values.player_cap = widget("xcc_gui_player_cap").value
            values.player_rate = widget("xcc_gui_player_rate").value

            values.separate_leaders = widget("xcc_gui_separate_leaders").selected
            values.leader_cap_enabled = widget("xcc_gui_leader_cap_enabled").selected
            values.leader_cap = widget("xcc_gui_leader_cap").value
            values.leader_rate = widget("xcc_gui_leader_rate").value

            values.healing_xp_enabled = widget("xcc_gui_healing_xp_enabled").selected
            values.healing_xp_per_unit = widget("xcc_gui_healing_xp_per_unit").value

            values.enemies_enabled = widget("xcc_gui_enemies_enabled").selected
            values.enemy_cap_enabled = widget("xcc_gui_enemy_cap_enabled").selected
            values.enemy_cap = widget("xcc_gui_enemy_cap").value
            values.enemy_rate = widget("xcc_gui_enemy_rate").value
        end

        local retval = gui.show_dialog(get_dialog_cfg(), pre_show, post_show)
        if retval ~= -1 then return { saved = false } end

        return {
            saved = true,
            player_cap_enabled = values.player_cap_enabled,
            player_cap = values.player_cap,
            player_rate = values.player_rate,
            separate_leaders = values.separate_leaders,
            leader_cap_enabled = values.leader_cap_enabled,
            leader_cap = values.leader_cap,
            leader_rate = values.leader_rate,
            healing_xp_enabled = values.healing_xp_enabled,
            healing_xp_per_unit = values.healing_xp_per_unit,
            enemies_enabled = values.enemies_enabled,
            enemy_cap_enabled = values.enemy_cap_enabled,
            enemy_cap = values.enemy_cap,
            enemy_rate = values.enemy_rate,
        }
    end)

    if not as_bool(result.saved, false) then return end

    local old = copy_options(opts)
    write_dialog_settings(result)
    opts = nil
    ensure_options()
    local new = copy_options(opts)

    if cap_settings_changed(old, new) then
        reapply_caps_after_manual_change()
    end

    if old.healing_xp_enabled ~= new.healing_xp_enabled then
        rebuild_healer_cache()
    end
end

local function event_unit()
    local ev = wesnoth.current.event_context
    return wesnoth.units.get(ev.x1, ev.y1)
end

function wesnoth.wml_actions.xcc_initialize_unit()
    initialize_unit(event_unit())
end

function wesnoth.wml_actions.xcc_track_healer()
    refresh_healer(event_unit())
end

function wesnoth.wml_actions.xcc_remove_healer()
    local unit = event_unit()
    if unit ~= nil then remove_healer_id(unit.id) end
end

function wesnoth.wml_actions.xcc_after_advance()
    local unit = event_unit()
    if unit == nil then return end

    -- post advance is the point where Wesnoth has produced the unit's new
    -- uncapped XP requirement. Save it, then apply the selected cap.
    unit.variables.xcc_natural_max_experience = math.max(
        1,
        math.floor(tonumber(unit.max_experience) or 1)
    )
    unit.variables.xcc_cap_initialized = true
    apply_selected_cap(unit)
    refresh_healer(unit)
end

function wesnoth.wml_actions.xcc_attack_begin()
    local ev = wesnoth.current.event_context
    local attacker = wesnoth.units.get(ev.x1, ev.y1)
    local defender = wesnoth.units.get(ev.x2, ev.y2)

    if attacker == nil or defender == nil then
        attack_stack[#attack_stack + 1] = false
        return
    end

    local _, _, attacker_rate = settings_for_unit(attacker)
    local _, _, defender_rate = settings_for_unit(defender)

    if attacker_rate <= 100 and defender_rate <= 100 then
        attack_stack[#attack_stack + 1] = false
        return
    end

    attack_stack[#attack_stack + 1] = {
        attacker_id = attacker.id,
        defender_id = defender.id,
        attacker_level = math.max(0, math.floor(tonumber(attacker.level) or 0)),
        defender_level = math.max(0, math.floor(tonumber(defender.level) or 0)),
        attacker_rate = attacker_rate,
        defender_rate = defender_rate,
    }
end

function wesnoth.wml_actions.xcc_attack_end()
    local snapshot = attack_stack[#attack_stack]
    attack_stack[#attack_stack] = nil
    if snapshot == nil or snapshot == false then return end

    local attacker = wesnoth.units.get(snapshot.attacker_id)
    local defender = wesnoth.units.get(snapshot.defender_id)
    if attacker == nil or defender == nil
        or attacker.valid ~= "map" or defender.valid ~= "map"
    then
        return
    end

    local attacker_alive = attacker.hitpoints > 0
    local defender_alive = defender.hitpoints > 0

    if attacker_alive and defender_alive then
        add_combat_bonus(attacker, combat_xp(snapshot.defender_level), snapshot.attacker_rate)
        add_combat_bonus(defender, combat_xp(snapshot.attacker_level), snapshot.defender_rate)
    elseif attacker_alive and not defender_alive then
        add_combat_bonus(attacker, kill_xp(snapshot.defender_level), snapshot.attacker_rate)
    elseif defender_alive and not attacker_alive then
        add_combat_bonus(defender, kill_xp(snapshot.attacker_level), snapshot.defender_rate)
    end
end

function wesnoth.wml_actions.xcc_healing_snapshot()
    local side_number = tonumber(wml.variables.side_number)
    if side_number ~= nil then snapshot_healing(side_number) end
end

function wesnoth.wml_actions.xcc_healing_award()
    local side_number = tonumber(wml.variables.side_number)
    if side_number ~= nil then award_healing(side_number) end
end

function wesnoth.wml_actions.xcc_open_settings()
    show_settings_dialog()
end

function wesnoth.wml_actions.xcc_preload()
    -- Lua tables are transient and are not saved in a Wesnoth savegame. Rebuild
    -- only the healer cache when a save/scenario is loaded; no unit XP state is
    -- changed here. unit placed will incrementally fill any units not present yet.
    opts = nil
    attack_stack = {}
    rebuild_healer_cache()
end

function wesnoth.wml_actions.xcc_scenario_end()
    opts = nil
    attack_stack = {}
    healing_snapshots = {}
    healer_cache = {}
    healer_side = {}
end

-- Make runtime variables available immediately to WML filter_conditions in the
-- same scenario, including after changing settings in an earlier scenario.
ensure_runtime_settings()
