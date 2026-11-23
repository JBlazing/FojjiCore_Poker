# FojjiCore: Poker

Poker for 2 to 9 friends, inside the FojjiCore games menu.

- **No-Limit Hold'em**: two hole cards, bet anything up to your stack.
- **Pot-Limit Omaha**: four hole cards, use exactly two plus three from the board, and the biggest bet is the size of the pot.

The host opens a table and chooses the variant, the starting stack (50, 100 or 200 big blinds) and the blinds (fixed, or rising every 20 or 10 hands). Then they invite people from their group or guild, and start the game once 2 to 9 players are sitting. It's play chips only.

## Requirements

- **FojjiCore** and **FojjiCore Games 4.0.52 or newer**. That version added `Games.Register`. If an older FojjiCore Games is installed, the addon prints one line at login and switches itself off.
- Everyone at the table needs this addon.

## Playing

- Open the games menu and pick **Poker**, or type `/fc poker` (also `/fc holdem` or `/fc plo`). `/fc poker <name>` opens a table and invites them.
- **The lobby.** Click **Open a table**, then invite people by name, from the Party / Raid / Guild / Recent lists, or everyone in your group at once with **Invite group**. Each invited player gets a toast and a line in chat, and can join from the toast or from the Poker window. Everyone at the table sees who is sitting. The host can still change the game while waiting. **Start** lights up once a second player sits down, and seats are drawn at random when the host starts.
- **At the table.** The button moves round the table each hand. The two players after it post the blinds, and the player after the big blind acts first. Heads-up, the button posts the small blind. Side pots are split properly when players are all-in for different amounts.
- **The clock.** Each decision has a 24-second shot clock, shown as a bar and a countdown on the plate of whoever is to act. Everyone also has a 2-minute time bank for the whole game. With **Auto time bank** on (the default, in the action bar), the bank starts by itself when the 24 seconds run out. With it off, the bank only starts if you click **Use time bank**. Run out of time and you check, or fold if there's a bet to call. If a player runs out of time twice in a row, the host gets a **Remove** button for them.
- **Going out.** Lose every chip and you finish in your place (5th of 6, say), and can keep watching. The last player with chips wins the table. **Leave** walks out mid-game: your hand is folded and your chips leave with you. If the host leaves, the table closes for everyone. If a player stops answering, the host gets a **Remove** button after a minute.
- A game survives `/reload` and logging out for up to 30 minutes.
- If the window is closed when it's your turn, a line in chat tells you, and the menu tile shows "Your turn".
- When the betting stops early because players are all-in, the board is played out slowly. Every hand still in turns over, the flop lands one card at a time, and the turn and river each come in face down and then flip, with the longest pause before the river. Each player's hand so far shows on their plate. The pot is pushed, and the next hand dealt, only after that.
- After a game, **New table** opens a new lobby with the same people invited.

## How it works

| File | What it does |
|---|---|
| `Eval.lua` | Hand values: best five of seven for Hold'em, and exactly 2 + 3 for Omaha. Also hand names ("Full house, Kings over Sevens"). |
| `Engine.lua` | The rules as a pure state machine for 2 to 9 seats: blinds and the moving button, betting (no-limit and pot-limit, minimum raises, short all-ins that don't reopen the betting, refunds), side pots, players leaving, the deal handshake, showdowns, finishing places, and snapshots for resuming. |
| `Table.lua` | The lobby and the messages: invites, joining, starting, the host putting every move in order, catching up after a lost message, resuming after a reload, leaving. |
| `Poker.lua` | The glue to FojjiCore: `Games.Register` (the menu tile), the deal handshake, and the window (the lobby and the table). |

Every client runs the same engine on the same moves, so they all agree. The host keeps the one true order. A player sends their move to the host (`A`), and the host checks it, numbers it and sends it to the table (`M`). When everyone at the table is in the host's group, that's one group addon message. Otherwise the host whispers each player.

- `K` / `S` / `R`: the deal handshake. The big blind commits to a hash of a secret. The button answers with a number of its own. The big blind reveals the secret, and the deck is shuffled from both. Neither of them can steer the shuffle. If one of them leaves mid-deal, the next players along take over.
- `F` `X` `C` `B<to>`: fold, check, call, and bet or raise to an amount.
- `O<seat>`: sent only by the host, when a player leaves or is removed.
- `W`: the player to act starts their time bank. `U<seat><secs>` and `T<seat>` are sent only by the host, which keeps the one clock: the seconds of bank a player used (sent just before their move), and a player running out of time.

Fair, but not secret: once the secret is revealed, every client could work out every card. The addon only ever shows your own cards, plus those still in at a showdown. Someone with a modified client could peek, which is why it's play chips only.

Lost messages are recovered. A player who has heard nothing for 20 seconds asks the host how far the game has got (`P`), and the host sends the whole position back (`T`) if they're behind. A move the host hasn't confirmed is sent again after 8 seconds.

## Development

```sh
lua tests/test_engine.lua    # hand values, betting rules, side pots, leaving, 1,000 random games of 2-9 players
lua tests/test_table.lua     # several clients play through FojjiCore's real Comm code (needs FojjiCore Games installed)
scripts/install-local.sh     # copy into the _forever_ client (or: anniversary, all, ...)
```

`tests/test_table.lua` loads FojjiCore Games from `FOJJI_ADDONS`, which defaults to `D:/Games/World of Warcraft/_forever_/Interface/AddOns`. It plays whole games between simulated clients. It covers heads-up, six players in one group with 10% of messages dropped, nine players who only share a guild (all whispers), five players with `/reload`s of a guest and the host, a player walking out and another being removed, the host closing the table, and the lobby on its own (declines, leaving, changing the game, nine seats). Set `POKER_SEED` to vary the run.
