XP Control Center
=================
Target: Battle for Wesnoth 1.18.x

INSTALL
-------
Replace your existing XP_Control_Center folder with this one in:

    Documents\My Games\Wesnoth1.18\data\add-ons\

Fully restart Wesnoth. Start a campaign, enable "XP Control Center" under
Modifications, choose the initial settings, and start the campaign.

IN-GAME SETTINGS
----------------
Right-click a human-controlled leader and choose the single menu entry:

    XP Control Center

It opens one settings window organized as:

    ALLIES
    LEADER
    HEALERS
    ENEMY

Press Save to apply changes. Cancel leaves the current settings untouched.
The in-game values are stored as campaign variables, so they persist through
saves and later scenarios.

XP CAP DESIGN
-------------
The selected cap is written directly into the unit's real max_experience.
The unit also stores its uncapped value in:

    xcc_natural_max_experience

and stores:

    xcc_cap_initialized=yes

Normal gameplay does not rescan units for XP caps. A unit is initialized once,
then its cap is refreshed only after normal advancement or AMLA, when Wesnoth
can give it a new max_experience value. Recalled veterans keep their already
edited max_experience value.

If you manually change an effective cap setting in the in-game window, the mod
performs one map + recall-list pass at that moment so already existing units
immediately get the new cap (or have their stored natural requirement restored
if a cap is raised/disabled). Rate-only changes do not trigger this pass. No
repeated scan follows afterward.

COMBAT XP
---------
Combat XP rates are 100%-500%. The mod adds only the requested bonus portion;
core Wesnoth still handles the normal combat XP and its normal advancement/AMLA
processing.

HEALER XP CACHE
---------------
Healing XP does not search the whole map every turn. Healers are kept in a
transient per-side ID cache and normal healing checks only those cached healer
IDs plus their adjacent hexes.

The cache is updated on placement, advancement/AMLA, and death. Because Lua
cache tables are not stored in save files, one healer-only map query rebuilds
the cache when a save/scenario is loaded. A healer-only query is also performed
when healing XP is manually switched from Off to On. There is no recurring
whole-map healer scan during normal turns.

OPTIONS
-------
ALLIES
- XP cap on/off
- Maximum XP required
- Combat XP gain rate

LEADER
- Separate leader settings on/off
- XP cap on/off
- Maximum XP required
- Combat XP gain rate

HEALERS
- Healing gives XP on/off
- XP per healed ally

ENEMY
- Enemy XP modification on/off
- XP cap on/off
- Maximum XP required
- Combat XP gain rate

PERFORMANCE SUMMARY
-------------------
- XP cap: one-time initialization + post-advance/AMLA only
- Recall: no normal cap recalculation
- Combat XP: attacker + defender only
- Healing XP: cached healer IDs + adjacent hexes only
- Full map+recall cap query: only when you manually change a cap setting
- Healer-only map query: only on load/reload or when healing XP is enabled
