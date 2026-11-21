# FojjiCore: Poker

**Poker for 2 to 9 friends, right inside the FojjiCore games menu.**

Open a table, invite people from your group or guild, and play **No-Limit Hold'em** or **Pot-Limit Omaha** with up to nine players. Everything happens in game, with a proper poker table. It's play chips only. No gold changes hands.

## Features

- **Two games.**
  - *No-Limit Hold'em*: two hole cards, bet anything up to your stack.
  - *Pot-Limit Omaha*: four hole cards, use exactly two plus three from the board, and the biggest bet is the size of the pot.
- **A lobby for your table.** Invite by name, from your party, raid, guild or recent players, or invite your whole group at once. Everyone sees who is sitting, and the host starts with 2 to 9 players.
- **Your rules.** Pick the starting stack (50, 100 or 200 big blinds) and the blinds: fixed, or rising every 20 or 10 hands.
- **A real table.** Up to nine seats round the felt, card art, chip stacks, a moving dealer button, bet sizing with a slider and quick presets, side pots, and the winning five cards glow at showdown.
- **Cinematic all-ins.** When someone is all-in before the river, the board isn't dumped all at once. Every hand still in flips over, the flop lands card by card, and the turn and river each come in face down and then flip. The river gets the longest pause. Each player's hand so far shows as it goes.
- **Fair shuffles.** Every deck is shuffled from secrets of two players: the big blind commits to a hash, the button answers, then the secret is revealed. Neither can stack the deck.
- **Survives /reload.** A game comes back after `/reload` or logging out, for up to 30 minutes. Lost messages are recovered automatically.
- **Never miss your turn.** If the window is closed, a line in chat tells you it's your move, and the games menu tile shows "Your turn".
- **Play to the last chip.** Bust out and you see where you finished, and can keep watching. **New table** re-invites everyone when it's over. Your win/loss record is kept.

## How to play

1. Open the FojjiCore games menu and pick **Poker**, or type `/fc poker` (also `/fc holdem` or `/fc plo`).
2. Choose the game, stack and blinds, and click **Open a table**.
3. Invite your friends (or use `/fc poker <name>`). They get a toast to join.
4. Once 2 to 9 players are sitting, click **Start**.

## Requirements

- **FojjiCore** and **FojjiCore Games 4.0.52 or newer**. With an older FojjiCore Games, the addon prints one line at login and switches itself off.
- **Everyone at the table needs this addon.**

## Good to know

Every client runs the same rules engine on the same moves, put in order by the host, so they always agree on every card and chip. The shuffle is fair but not secret: once a hand's secret is revealed, a modified client could work out the cards. That's why it's play chips only.
