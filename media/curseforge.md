# FojjiCore: Poker

**Heads-up poker against a friend, right inside the FojjiCore games menu.**

Challenge someone from your group or guild to a one-on-one match of **No-Limit Hold'em** or **Pot-Limit Omaha**. Everything happens in game, over whispers, with a proper poker table. It's play chips only. No gold changes hands.

## Features

- **Two games.**
  - *No-Limit Hold'em*: two hole cards, bet anything up to your stack.
  - *Pot-Limit Omaha*: four hole cards, use exactly two plus three from the board, and the biggest bet is the size of the pot.
- **Your rules.** Pick the starting stack (50, 100 or 200 big blinds) and the blinds: fixed, or rising every 20 or 10 hands.
- **A real table.** Card art, chip stacks, a dealer button, bet sizing with a slider and quick presets, and the winning five cards glow at showdown.
- **Cinematic all-ins.** When someone is all-in before the river, the board isn't dumped all at once. Both hands flip over, the flop lands card by card, and the turn and river each come in face down and then flip. The river gets the longest pause. Each player's hand so far shows as it goes.
- **Fair shuffles.** Every deck is shuffled from a secret of each player's: one player commits to a hash, the other answers, then the secret is revealed. Neither player can stack the deck.
- **Survives /reload.** A match comes back after `/reload` or logging out, for up to 30 minutes. Lost whispers are recovered automatically.
- **Never miss your turn.** If the window is closed, a line in chat tells you it's your move, and the games menu tile shows "Your turn".
- **Rematch** with one click when the match is over. Your win/loss record is kept.

## How to play

1. Open the FojjiCore games menu and pick **Heads-Up Poker**, or type `/fc poker` (also `/fc holdem` or `/fc plo`).
2. Choose the game, stack and blinds, then enter a name (or use `/fc poker <name>`).
3. Your opponent gets a challenge toast. Once they accept, the cards are dealt.

## Requirements

- **FojjiCore** and **FojjiCore Games 4.0.52 or newer**. With an older FojjiCore Games, the addon prints one line at login and switches itself off.
- **Both players need this addon.**

## Good to know

Both clients run the same rules engine on the same moves, so they always agree on every card and chip. The shuffle is fair but not secret: once a hand's secret is revealed, a modified client could work out the cards. That's why it's play chips only.
