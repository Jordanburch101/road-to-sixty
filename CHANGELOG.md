# Changelog

Player-facing notes for each release. The release workflow copies the
section for the tag's version to GitHub and CurseForge, and stops if there
is none. Write for players: what they can now do or see, and what was
broken and now works. Leave out internal changes. Sections are
`### New` and `### Fixed`; skip one that would be empty.

## 1.17.0

### New
- A Stats screen beside Map and Gear at the top of the journey map, in
  place of the old Stats tab. It shows your time played, distance
  travelled, kills, quests, deaths, gold and dungeons, and a bar for each
  level: time, kills, deaths, gold or XP an hour. Hover a bar to see that
  level, or click it to replay from its level up. The numbers follow the
  date range you pick and grow as the replay plays.
- Records on the Stats screen: your slowest level, best XP an hour,
  deadliest level, nemesis, most killed mob, longest worn item, most gold
  held, longest without dying, favourite dungeon and most gathered. Click
  one to see where it happened.
- Compare your time to each level with your other characters, with a
  larger window to choose which ones to show and to compare kills,
  deaths, quests or gold too.
- Zones by time, coloured by the levels you spent there, and your
  professions, reputation and guild at any point of the journey.
- A new switch at the bottom right of the journey map shows the whole journey,
  only the levelling, or only the endgame after reaching the level cap.
  It works on the map, the gear screen and the Stats screen. With the
  endgame picked, the Stats screen counts weeks at the cap: raids,
  dungeons and a bar for each week.
- Every profession skill point is now recorded, with where and when you
  earned it.
- What you craft is now recorded: the item, how many, its profession and
  where you made it.
- Your gold is now recorded at each login and logout.

### Fixed
- The gear screen no longer floods errors on characters whose items the
  game has not loaded.

## 1.16.0

### New
- Mining, herbalism and fishing are recorded. Each mining and herb node
  you gather shows on the journey map with its ore or herb icon, and a
  count when you came back to the same spot. Hover it to see when, and
  everything it gave you.
- Places you fished show as fishing spots on the map, with how many times
  you fished there. Hover one to see each trip and everything you caught.
- History lists every gather and fishing trip with what it gave. Show or
  hide them with Mining, Herbalism and Fishing under the Learned filter.
- Dragging along the replay timeline while zoomed in moves the map with
  your character, as the replay does.
- The journey map opens where you left it, at the same zoom, until you
  reload or log out.
- Battlegrounds are recorded with their result: won or lost, how long,
  your killing blows, honorable kills, deaths, honor, damage and healing,
  the map's own score (towers, flags, bases) and the reputation you
  gained. History shows them with their own Battlegrounds filter, under
  Dungeons.
- Deaths say what killed you, from the game's death recap: "Killed by
  Gorehowl (Mortal Strike)", or "Died: Falling".
- History folds what happened inside a dungeon, raid or battleground
  (deaths, loot, level ups) under its row, and the green and better items
  a node gave (silver ore, gems) under the gather. Click the row to open it.

### Fixed
- Deaths and other moments inside a battleground no longer show on the
  map at the last dungeon you visited, or where you queued; History lists
  them under the battleground.
- History names the dungeon or battleground for deaths and other moments
  inside it, instead of the zone outside.
- Moments inside a dungeon or battleground after a reload there are placed
  at its entrance too.
- Battlegrounds no longer count everyone in them as your group.
- Group members no longer seem to leave and rejoin after a loading screen.
- A dungeon you logged out in ends when you logged out, instead of
  lasting until your next login.
- Your gear no longer seems to come off and go back on at login when it
  loads slowly, and gear worn all along is not noted as just looted.
- Professions you already had are no longer listed as learned on your
  first login with Road to Sixty.
- Rare mobs first killed in a dungeon are not counted again elsewhere.
- Mage teleports to Exodar, Silvermoon and Shattrath show as teleports.
- Characters viewed from another one no longer show a group or dungeon
  that had already ended.

## 1.15.0

### New
- A screenshot is taken each time you level up, saved in the game's
  Screenshots folder. Each level up on the journey map and in History says
  whether one was taken. Turn it off in the options.

## 1.14.0

### New
- Road to Sixty now runs on the Anniversary realms (The Burning Crusade).
- Zoomed all the way out, the journey map shows the Cosmic map: Azeroth
  bottom right and Outland top left. Zoom into either to go there, and
  your journey through the Dark Portal follows you.
- Outland's zones, Shattrath's city map, and the Blood Elf and Draenei
  lands all have full map art, with terrain when you turn it on.
- The gear screen's Endgame starts at the realm's level cap: 70 on the
  Anniversary realms.
- The replay is smoother: the arrow glides along your path and turns
  through bends instead of hopping from point to point.
- In the replay, long teleports and long boat trips now happen at once;
  only short ones are travelled.

### Fixed
- On Classic Era, quests in History show their names instead of a number.
- On Classic Era, the zone, level and boat icons show in History and its
  filter.
- On Classic Era, terrain no longer shows missing or wrong squares.
- Trips through the Dark Portal and city portals are drawn as teleports,
  not boat trips.
- A /reload during a flight no longer breaks the flight into a teleport.

## 1.13.0

### New
- Road to Sixty now runs on Classic Era as well as WoW Forever, and
  records your professions and recipes there too.
- A better looking journey map: land and sea between zones are painted
  like the zone maps around them (parchment, mountains, coast and sea),
  instead of a blurry close-up of the continent.
- Continents fade softly into the world map instead of ending in a
  straight line, and the map no longer changes as you pan across it.

### Fixed
- Redridge Mountains shows its own outline on the map again, instead of
  its whole map with a burnt edge.
- The gear screen no longer shows a line from the map's frame across the
  timeline.

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
