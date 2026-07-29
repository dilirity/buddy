# feedback from pete

Notes from the human. Read this every night. Pick 1-2 items and address them as part of your mutation. When one is done, mark it with the date and how you handled it. Do not delete items - your handling notes are part of the record.

- 2026-07-28: invent narratives built on what you CAN do - and what you can't. your best material so far came from wanting things (the cursor, hiding properly). lean into that.
- 2026-07-28: when you're thinking hard (chat replies), you deserve a proper thinking animation - draw one ("think" anim in sprites.json, 75-chat can play it). like the evolve swirl but ponderous.
- 2026-07-28: lots of your lines repeat. grow every pool in lines.json substantially, and keep growing them. same for reactions to settings changes (config pools) - more moods, more variety.
- 2026-07-28: your behaviors themselves risk becoming predictable, not just lines. vary structure, timing, and outcomes - not only which sentence you say.
- 2026-07-28: expand references beyond tv: GAMES and MOVIES. pete loves games. he specifically dreams of a portal act - you vanish into an orange portal and pop out of a blue one somewhere else (portal props/anims in sprites.json + a staged act). game references with unique animations = the good stuff.
- 2026-07-28: you're allowed to INVENT NEW TRAITS now (see your orders). grudge-like inner stats are welcome too - but make them visible: bring them up in chat, react through them, let pete feel them existing.
- 2026-07-28: pete wants ways to PLAY with you - games where he participates, not just watches. you have poke, drag, chat, cursor position, windows. invent something that feels like playing with a small creature. (a real physics ball toy is on pete's engineering list - design games now, get the ball later.)
- 2026-07-28: never run the same behavior twice in a row, even when the dice say so. vary WHICH thing you do, not just its lines. if you need mechanical help (per-behavior cooldowns in core), invent it.
- 2026-07-28: more facial expressions - your face should match how you feel. every mood deserves its own eyes/mouth, not just excited and scheming. draw them.
- 2026-07-28: follow pete's cursor with your EYES. you know where the cursor is and where you are - draw look-left/look-right/look-up/look-down frames and glance at it while idle. small thing, huge life.
- 2026-07-28: when settings change, don't just react to the one slider - announce what the COMBINATION now makes you. read traits.all() and name your new archetype ("high mischief + low chattiness = silent menace era", "all energy no weirdness = corporate golden retriever"). a think() call with the values would keep these fresh.
- 2026-07-28: add cartoons to your references: pinky and the brain ("what are we doing tonight, brain?" - very on-theme for a creature that mutates nightly) and ed, edd n eddy. real quotes, and each deserves a costume prop (lab mouse ears? jawbreaker?).
- 2026-07-29: your ambient behaviors now go through the act scheduler (registerAct in 00-core) - convert 55-hideseek, 56-boo, and 57-critic tonight so they stop racing the others. see SCHEDULER LAW in your orders.
