# Changelog

Player-facing notes for each release. The release workflow copies the
section for the tag's version to GitHub and CurseForge, and stops if there
is none. Write for players: what they can now do or see, and what was
broken and now works. Leave out internal changes. Sections are
`### New` and `### Fixed`; skip one that would be empty.

## 1.13.0

### New
- Road to Sixty now runs on Classic Era as well as WoW Forever, and
  records your professions and recipes there too.

## 1.12.0

### New
- A Gear screen: switch the journey map to Gear to see every piece of gear
  you wore, slot by slot, from your first level to 60 and your weeks of
  raiding after. Hover an item for its tooltip, where it came from, who
  enchanted it and how long you wore it. Move along the timeline and your
  character is shown in the gear of that moment. The mouse wheel zooms,
  dragging moves along, and the replay carries the view with it.
- Under the gear, your average item level over the journey, with a mark
  wherever a blue or epic went on.
- A date range for the journey map: see just today, yesterday, the last
  7 or 30 days, or all time. The path, the replay, the markers, the
  pop-ups and History all follow it.
- The Terrain and Gear card buttons now sit on the map itself, in its
  bottom left corner, as they only change the map. The Fit button is
  gone: the map fits your journey each time it opens.

### Fixed
- The replay played too fast to follow; it now plays at half the speed.
- Once a character had an enchant recorded, the journey map's History,
  Stats and Characters tabs could stay empty. They now fill in, and
  enchants show in History with their own icon.
- In the options, the Erase section no longer runs into the line below
  it on smaller windows; the options scroll instead.

## 1.11.0

### New
- Enchants on your gear are now part of your journey. History lists each
  one with the enchant, where it happened and who did it: you, or the
  enchanter you traded with.
- Gear you changed while the addon was turned off, or on a PC without it,
  now shows in your journey from your next login.

### Fixed
- The gear card for the level you start recording at (level 1 for a new
  character) now shows the gear you were wearing, instead of an empty
  card. Journeys recorded before show the gear from later in that level,
  marked as such.

## 1.10.2

### New
- Your path now keeps its real shape: circling a tree, turning a fence
  corner or doubling back shows on the map as you walked it, instead of
  being cut short with a straight line. Other characters' journeys on the
  map keep that detail too, from their next login.

## 1.10.1

### Fixed
- Two characters with the same name now each show in the map's character
  list, with their own journey, instead of only the one you logged in to
  last. A character that was missing shows again once you next log in to
  it.

## 1.10.0

### New
- Deleted a character and made a new one with the same name? The new
  character now starts a journey of its own, instead of carrying on the
  old one's.

### Fixed
- Erasing a character's journey now sticks with the Road to Sixty app:
  before, the app brought the old journey back at the next login. The
  backup keeps the old journey as an earlier one, which you can remove in
  the app.

## 1.9.0

### New
- Play one character on more than one computer? The free Road to Sixty
  app (Mac and Windows, from roadtosixty.online) now backs your journeys
  up and joins them together. When you log in, the addon brings in the
  journey the app put together from your other PCs, so each one shows the
  whole road. Without the app, nothing changes: the addon keeps working
  on its own.
- `/rts check` shows whether the journey from the app came in at login,
  and if it couldn't, why.

### Fixed
- Times are now taken from the realm's clock instead of your computer's,
  so a PC whose clock is off no longer puts your sessions out of order.
- Teleports the addon couldn't name, such as one from a quest or an NPC,
  are now drawn as portals and listed under Teleports, instead of a plain
  dotted line.
- The map opens faster when nothing new has been recorded, terrain comes
  in without a pause, starting from the middle, and long journeys with
  many kills replay more smoothly.

This version moves your saved journey to a new layout the first time you
log in. Going back to 1.8.0 afterwards isn't supported.

## 1.8.0

### New
- Rare mobs: the first time you kill each rare (the silver dragons), it is
  recorded where it fell, even a rare too low to give you experience, as
  long as you loot it or click its corpse. It shows in History and on the
  map with a silver dragon; hover it for a card with the rare's portrait,
  its level, where and when you killed it, your level then, and how often
  you have killed it. Stats counts your rares, and the History filter has
  a Rare mobs button. Inside dungeons, a rare that gives no experience is
  recorded as "a rare" or "a rare elite", as the game hides its name there.

### Fixed
- Your path and kills are now stored every minute while you play, not
  only when you log out, so a logout that goes wrong no longer loses the
  session or puts the wrong times on later kills.
- The journey map's replay and zooming run more smoothly on long
  journeys.
- Gaining weapon skill points and crafting no longer make the addon redo
  work it had already done.

## 1.7.0

### New
- Reputation: each time you reach a new standing with a faction (Friendly,
  Honored, Revered, Exalted, or a drop), it is recorded where you were. It
  shows in History in the standing's colour, as a marker on the map, and
  in Stats, where hovering Reputation lists every faction and when you
  reached its standing. Turn it on or off under Learned in the History
  filter.
- Riding and mounts: learning to ride and each new mount are recorded
  where they happened. They show in History, on the map (even zoomed
  out, like dungeons), and in Stats, where Riding tells the level you
  learned it at. Turn them on or off under Learned in the History filter.
- The History filter's Crafting button is now called Learned: it holds
  professions and recipes as before, and now reputation and riding too.
- Hovering the replay bar under the map now also shows your time played
  at that point of the journey, in total and in that level.
- Each level up now prints a short summary in chat: where you reached
  it, how long the last level took compared with the one before, and its
  kills, quests, deaths, distance walked and money. Click Open map in it
  to see the moment on the journey map. It can be turned off in the
  options.
- The game's "Total time played" lines no longer appear in chat at every
  level up; the summary above tells the time instead. Typing /played
  still shows them.

### Fixed
- The gear card's model now holds your main hand weapon. It showed the
  ranged weapon in hand instead, whatever your class; hunters still hold
  their bow.

## 1.6.1

### Fixed
- German clients no longer get a Lua error with every kill. Kills, loot,
  recipes and guild changes are now recorded there too, and on other
  clients whose messages number their parts.

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
