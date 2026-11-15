# FojjiCore: Poker

Heads-up poker against a friend, inside the FojjiCore games menu.

- **No-Limit Hold'em**: two hole cards, bet anything up to your stack.
- **Pot-Limit Omaha**: four hole cards, use exactly two plus three from the board, and the biggest bet is the size of the pot.

You choose the variant, the starting stack (50, 100 or 200 big blinds) and the blinds (fixed, or rising every 20 or 10 hands). Then you challenge someone from your group or guild. It's play chips only.

## Requirements

- **FojjiCore** and **FojjiCore Games 4.0.52 or newer**. That version added `Games.Register` and `Games.Duel`. If an older FojjiCore Games is installed, the addon prints one line at login and switches itself off.
- Both players need this addon.

## Playing

- Open the games menu and pick **Heads-Up Poker**, or type `/fc poker` (also `/fc holdem` or `/fc plo`). `/fc poker <name>` fills in the name to challenge.
- The other player gets FojjiCore's usual challenge toast. A match survives `/reload` and logging out for up to 30 minutes, the same as the other FojjiCore duel games.
- If the window is closed when it's your turn, a line in chat tells you, and the menu tile shows "Your turn".
- When someone is all-in before the river, the board is played out slowly. Both hands turn over, the flop lands one card at a time, and the turn and river each come in face down and then flip, with the longest pause before the river. Each player's hand so far shows under their name. The pot is pushed, and the next hand dealt, only after that.

## How it works

| File | What it does |
|---|---|
| `Eval.lua` | Hand values: best five of seven for Hold'em, and exactly 2 + 3 for Omaha. Also hand names ("Full house, Kings over Sevens"). |
| `Engine.lua` | The rules as a pure state machine: blinds, betting (no-limit and pot-limit, minimum raises, all-ins and refunds), the deal handshake, showdowns, and snapshots for resuming. |
| `Poker.lua` | The glue to FojjiCore: `Games.Duel` (challenges, numbered moves, resume, rematch), `Games.Register` (the menu tile), and the table window. |

Both clients run the same engine on the same messages, so they always agree. Each message is one duel move.

- `K` / `S` / `R`: the deal handshake. The big blind commits to a hash of a secret. The button answers with a number of its own. The big blind reveals the secret, and the deck is shuffled from both. Neither player can steer the shuffle.
- `F` `X` `C` `B<to>`: fold, check, call, and bet or raise to an amount.

Fair, but not secret: once the secret is revealed, both clients could work out every card. The addon only ever shows your own cards, plus the other player's at a showdown. Someone with a modified client could peek, which is why it's play chips only.

Lost whispers are recovered. While a client waits on the other player, it asks every 20 seconds how far they've got (`P`), and whoever is ahead sends the whole position back (`T`).

## Development

```sh
lua tests/test_engine.lua    # hand values, betting rules, 1,000 random matches on two engines
lua tests/test_duel.lua      # two clients play through FojjiCore's real Duel/Comm code (needs FojjiCore Games installed)
scripts/install-local.sh     # copy into the _forever_ client (or: anniversary, all, ...)
```

`tests/test_duel.lua` loads FojjiCore Games from `FOJJI_ADDONS`, which defaults to `D:/Games/World of Warcraft/_forever_/Interface/AddOns`. It plays full matches between two simulated clients: a normal match, a match with 10% of whispers dropped, a match with two `/reload`s in the middle, and a give-up followed by a rematch. Set `POKER_SEED` to vary the run.
