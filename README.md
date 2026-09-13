# AutoMarker 1.23.0 (octo-addons fork)

Automatic raid marking for the 1.12 client. This fork of
[MarcelineVQ/AutoMarker](https://github.com/MarcelineVQ/AutoMarker) adds a
**name-based auto mode** that works on any server, an info panel with a minimap
button, and fixes for clients that are not Turtle WoW.

Requires [SuperWoW](https://github.com/balakethelock/SuperWoW/) or
[nampower](https://gitea.com/avitasia/nampower) 2.39+. Both together is best.

## Why the original does nothing on OctoWoW

The original addon marks predefined "packs". Every pack entry is a **spawn
GUID** such as `0xF13000C55326FDD0`, which identifies one creature spawn row in
the Turtle WoW database. Other servers have different spawn IDs, so on OctoWoW
(and anywhere else) none of the 1,839 shipped entries ever match. The keybind,
`/am mark`, `/am next` and Shift+Ctrl mouseover all depend on that lookup, so
they look broken even though the addon loads fine.

Auto mode fixes this by marking mobs by **name** instead of by spawn ID.

## Auto mode

- When you enter combat, and about once a second while in combat, unmarked
  hostile mobs that are fighting within 40 yards of you get free marks.
- Hold Shift and Ctrl (or Alt) and mouse over a mob, or press the mark keybind,
  and the mob plus every hostile within 30 yards of it is marked before the
  pull.
- Marks are handed out Skull first. Mobs whose name matches the **priority
  list** come first, in list order. The rest are ordered by max health (or by
  classification with `/am autosort class`).
- A mark that sits on a living mob is never moved, so marks you set by hand are
  respected. When a marked mob dies its mark is reused within a second.
- Pack data still wins: a mob that is in a pack gets its pack mark.
- Mobs on the **never mark** list, critters, totems, pets and players are
  skipped. Mobs tapped by another group are skipped by default.

Default priority list: priest, shaman, healer, mystic, acolyte, witch doctor,
mender, cleric, mage, warlock, sorcer, conjurer, caster, geomancer, summoner,
necromancer, wizard, oracle, seer, shadowcaster, spellbinder.
Default never-mark list: totem.

### Who can mark

Only a party leader or raid assistant can place marks that others see. Auto
mode stays idle on other group members and prints a one-time notice, so it is
safe to leave it on for every character. When you are not in a group, marks are
placed locally through SuperWoW so you can test alone.

**Multiboxing:** keep the leader on the client that should mark. Followers do
nothing unless they are promoted to assistant. If two assistants both run auto
mode they usually agree, since the ordering is deterministic, but turning it
off on one of them with `/am auto off` avoids any flicker.

## Info panel and minimap button

A skull icon on the minimap ring:

- Left-click opens the panel, right-click toggles auto mode (the icon dims when
  off), drag moves it.

The panel has four tabs:

- **Status**: what is on, whether this character can mark and why, the zone
  and whether it has pack data, free marks, cached mobs, detected client mods,
  plus all auto mode settings as checkboxes and sliders.
- **Priority**: edit the priority list and the never-mark list. Add a pattern,
  remove one, or move one to the top.
- **Macros & Keys**: ready-made macro text for every action. Click a box and
  press Ctrl+C to copy, or press **Create** to add the macro to this
  character's macro book (18 per character in 1.12). Shows the current
  keybindings and opens the key binding window.
- **Help**: the command list.

`/am ui` opens the panel too.

## Installation

In the launcher, choose **Add Addon from Git** and use:

```text
https://github.com/octo-addons/AutoMarker.git
```

The addon should be installed as:

```text
Interface/AddOns/AutoMarker
```

A newly added addon is only detected when the client starts, so restart the
game rather than using `/reload` the first time.

## Commands

Auto mode:

- `/am auto [on|off|status]` - toggle auto mode, or print a full status report
- `/am autoscan` - mark nearby hostiles now, even out of combat
- `/am radius <5-100>` - combat scan radius around you (default 40)
- `/am pullradius <5-100>` - pre-mark radius around the moused-over mob (default 30)
- `/am prio [add|remove|top|reset] <pattern>` - manage the priority list; no argument lists it
- `/am ignore [add|remove|reset] <pattern>` - manage the never-mark list
- `/am autosort health|class` - how unmatched mobs are ordered
- `/am autocombat`, `/am autolos`, `/am autotapped`, `/am autoinstance` - toggles for
  "only mobs already in combat", line of sight (needs UnitXP), skip tapped mobs,
  and instance-only
- `/am ui` - open the info panel

Packs (from the original addon; record your own on any server):

- `/am set <packname>` - set the current pack name (`/am s`)
- `/am get` - current pack name and pack info for your target (`/am g`)
- `/am add [packname]` - add your target with its current mark (`/am a`)
- `/am sweep [packname]` - mouse over mobs to add them; any command ends sweep mode
- `/am remove` - remove your target from its pack (`/am r`)
- `/am clear` - clear the current pack (`/am c`)
- `/am mark` - mark the pack of your target or mouseover, or auto-mark around it
- `/am next` - mark the next pack in the zone's default order
- `/am clearmarks` - remove all marks
- `/am markname <name>` - mark every nearby mob with that name
- `/am debug` - toggle debug output

Patterns are lowercase Lua patterns matched against the mob name; plain words
work as substrings.

## Keybindings

Under the **AutoMark** header in the key binding window:

- Mark mouseover or target (same as `/am mark`)
- Mark next group based on default order (same as `/am next`)
- Clear all current marks (same as `/am clearmarks`)
- Auto-mark nearby hostiles now (same as `/am autoscan`)

## Client mods

- **SuperWoW**: required for local marks and for using GUIDs as unit ids.
- **Nampower**: recommended. Provides the `UNIT_DIED` event (instant mark reuse)
  and real max-health values for ordering. Without it, ordering falls back to
  classification and level.
- **UnitXP_SP3** or **ClassicAPI**: recommended for exact yard distances. Without
  either, "in range" means within interact distance (about 28 yards).

## Known limits

- Marks on units outside the client's view range look free to the addon.
- The shipped packs and boss-add mechanisms are Turtle WoW data; on other
  servers they are inert. Recording your own packs with `/am set` and
  `/am sweep` works everywhere.

## Fixes over upstream

- Solo and non-leader marking works when nampower is loaded (upstream disabled
  the SuperWoW local-mark path whenever nampower was present).
- The unit popup hook no longer errors on clients whose FrameXML uses the
  standard one-level `UnitPopupShown` table.
- Saved `false` settings survive `/reload`.
- The undefined `sync_prefix` used in Molten Core is defined.
- Missing locale strings fall back to English instead of erroring.

## Credits

Original addon by Weird Vibes of Turtle WoW, maintained at
[MarcelineVQ/AutoMarker](https://github.com/MarcelineVQ/AutoMarker). This fork
keeps their history and pack data and adds the auto mode, panel and fixes.
