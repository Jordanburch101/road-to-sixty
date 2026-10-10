# Changelog

Player-facing notes for each release. The release workflow copies the
section for the tag's version to GitHub and CurseForge, and stops if there
is none. Write for players: what they can now do or see, and what was
broken and now works. Leave out internal changes. Sections are
`### New` and `### Fixed`; skip one that would be empty.

## 1.7.0

### New
- Reputation: each time you reach a new standing with a faction (Friendly,
  Honored, Revered, Exalted, or a drop), it is recorded where you were. It
  shows in History in the standing's colour, as a marker on the map, and
  in Stats, where hovering Reputation lists every faction and when you
  reached its standing. Turn it on or off under Social in the History
  filter.
- Riding and mounts: learning to ride and each new mount are recorded
  where they happened. They show in History, on the map
  (even zoomed out, like dungeons), and in Stats, where Riding tells the
  level you learned it at. Turn them on or off under Travel in the History
  filter.

## 1.6.0

### New
- Hearthstones and teleports are now portals on the map: a swirling
  portal where you left and a bright one where you arrived, green for
  hearthstones and blue for teleports. In the replay you dive into the
  first, a comet flies across, and you spin out of the second. Hover a
  portal to see a comet fly to where it leads. Portals show once you zoom
  in a little.
- Leaving a group inside a dungeon, which sends you to a graveyard, shows
  as a grey portal instead of a walk out of the dungeon.
- Dying inside a dungeon now shows as a ghostly line to the graveyard,
  like your corpse run back.
- Markers that would sit on top of each other, such as several groups
  formed at a dungeon's door or a guild joined and left by the bank, now
  show as one with a count. Hover it and they fan out so you can see each
  one. Markers of different kinds move apart a little so all stay
  readable.
- The replay celebrates each level you reach: your level badge pops up
  and flips to the new level with a golden flash.
- Your path is drawn in smooth curves when you zoom in.

### Fixed
- Levels reached and deaths inside a dungeon now show on the map, at the
  dungeon's entrance.
- Tooltips and History named "Eastern Kingdoms" instead of the zone in a
  few spots, such as the Deadmines' mine. Those are corrected, and the
  continent no longer counts as a discovered zone.
- A death could be counted twice. Deaths counted twice before are
  corrected.

## 1.5.0

### New
- Guilds: your journey records when you join or leave a guild and when
  your rank changes. They show in History and on the map with your
  guild's own banner, in its colours and with its emblem, and the replay
  celebrates joining a guild: the banner drops in to a burst of confetti,
  then stays on the map where it landed. A guild without a tabard gets a
  grey banner, filled in with its colours once it has one while you are
  still a member. Stats lists each guild you have been in and for how
  long, and the Characters tab shows each character's guild.
- Groups: your journey records every party and raid you join and who was
  in it. On the map, the members' portraits sit where the group formed
  and spread out when you hover them, with a card of who they were, how
  often you have grouped with each, when they came and went, and what
  you did together. Raids sum up their classes and pick out the players
  you know. Stats shows how many players you have met and who you group
  with most, and the History filter has a Social button for groups and
  guilds.
- Hovering a dungeon or raid run in History shows a card with everyone
  who was in it with you, what you did there and the loot.
- The minimap button has a new icon.
- Zephras Isle shows its terrain when you zoom in with terrain on, like
  the rest of the world.
- The replay no longer travels along the line between where you logged
  out and where you logged in next; it goes straight on from there.

### Fixed
- Dying in a dungeon and running back in no longer splits the run in
  two. Runs split this way before are joined.

## 1.4.0

### New
- Characters: click one of your characters on the Characters tab to see
  their whole journey on the map, with their history, stats, gear and
  replay. A label in the map's corner shows whose journey it is; click its
  X to go back to your own. Each character needs to log in once with this
  version to share their journey.
- Other characters' paths now keep their real shape and show their
  flights and travel, instead of rough straight lines.
- Boat and zeppelin trips are drawn like an adventure map: a dotted red
  line from a target ring where you set sail to an X where you landed.
  Boats sail round the coasts instead of over land, and a route you took
  more than once shows once, with the number of trips and the first and
  last in its tooltip. Forever's new boats and zeppelins are named, such
  as Powderfuse Port, Southshore and Valanaar.
- Hearthstones and teleports have their own look: a green ribbon of
  twining vines for hearthstones and a blue ribbon of arcane light for
  teleports. Between Kalimdor and the Eastern Kingdoms they gather into
  one lane each across the sea, so the middle of the map stays tidy.
- The replay follows you along boat trips, hearthstones and teleports,
  taking longer for longer journeys, instead of jumping straight to where
  you arrived.
- Capital cities: zooming in close with terrain off shows each city's own
  street plan, set into the land around it. Can be turned off in the
  options.

### Fixed
- Land that no zone map covers, such as the mountains around Stormwind,
  no longer turns into large blocks when zoomed in. It now looks like the
  parchment of the zone maps around it.
- The map around Stormwind no longer shows hard edges and burnt map
  borders.
- Zephras Isle now shows on the map, out at sea north of the Maelstrom,
  with your path, events and zeppelin trips there. Before, nothing you
  did on the island appeared. Zoomed out it looks like an unexplored map;
  zoom in to see it in full.

## 1.3.0

### New
- Professions: learning a profession or training to a new rank now shows
  up in your History and on the map, with a professions row in Stats.
- Recipes: every recipe you learn is recorded, from a trainer or a
  recipe item, and can be shown in History and on the map (hidden by
  default).
- Kill marks: a faint red stain on the map where you fought, building up
  in the areas you grinded. Can be turned off in the options.
- History filters are now grouped under eight icons. Left-click a group to
  toggle it, right-click to pick what it shows.

## 1.2.1

### New
- With terrain turned off, zooming in now fades into the game's own zone
  maps, fully revealed, for every zone at once.

## 1.2.0

### New
- Every kill is recorded. During the replay, kills pop up on the map with
  the creature's name and the experience gained, counting up for kills in
  a row. Can be turned off in the options.

## 1.1.0

### New
- Quest turn-ins pop up during the replay with the quest's name and
  experience. Can be turned off in the options.
- A "Quests turned in" filter in History, with map markers at each quest
  giver you visited.

## 1.0.0

### New
- First full release.
