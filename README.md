# Skatepark City: deploy kit

The game runs in three ways from the same code:

| Where | What you get |
|---|---|
| Opened as a plain file, or with `config.js` left blank | Fully offline. Coins, items, scores and progress stay in that browser. |
| The claude.ai artifact | Shared market and online play through claude.ai. |
| Hosted with Supabase keys in `config.js` | The real thing. Username and password accounts, server-held coins and items, a live market, world high scores, crews, the online lobby and wagers paid out by the server. |

## What's in here

- `index.html` is the whole game, built from `skatepark-city.html` by `build.py`.
- `config.js` holds your Supabase URL, anon key and the account domain. It's the only file you edit.
- `supabase/schema.sql` contains every table and rule. Players can only read; all coin and item changes go through server functions with caps.
- `audio/` holds the music (`title.mp3` on the title screen, `city.mp3` in the city, shops and menus). Keep it next to `index.html`.
- `build.py` rebuilds `index.html` after a new game version: `python3 build.py path/to/skatepark-city.html`.

## Setup (about 20 minutes)

### 1. Supabase (the server)

1. Create a free project at supabase.com. Pick a region near your players.
2. Open **SQL Editor**, then **New query**. Paste all of `supabase/schema.sql` and click **Run**. Running it again later is safe.
3. Go to **Project Settings**, then **API**. Copy the **Project URL** and the **anon public** key into `config.js`. Never use the `service_role` key here.
4. Go to **Authentication**, then **Sign In / Providers**, then **Email**:
   - Keep **Email** on and turn **Confirm email** OFF. This matters: players sign up with a username and password, and the game turns the username into a made-up address (`matt@riders.skatepark-city.app`) that never receives mail. With confirmation on, nobody could finish signing up.
   - Set the minimum password length to 8 to match the game.
   - Leave **Web3 Wallet** off for now. Wallet sign-in comes later and the game hides the button until then.
   - The account domain is `authDomain` in `config.js`. Set it once, before the first player signs up, and never change it: changing it locks everyone out of their accounts. If Supabase ever rejects sign-ups with "Email address is invalid", set it to a domain you own (no mail needs to go there) before launch.
5. Go to **Authentication**, then **URL Configuration** (used later for wallet sign-in):
   - Set **Site URL** to your live address, for example `https://skateparkcity.pages.dev`.
   - Add the same address, plus `http://localhost:8788` for testing, under **Redirect URLs**.
6. Recommended before launch: under **Authentication**, then **Attack Protection**, keep the default rate limits. Username accounts have no email to recover a lost password, so tell players to keep theirs safe. You can reset one by hand under **Authentication**, then **Users**.

### 2. GitHub (where the code lives)

1. Create a new repository, for example `skatepark-city`. It can be private.
2. Upload everything in this folder: `index.html`, `config.js`, `_headers`, `README.md`, `build.py` and the `supabase` folder.

### 3. Cloudflare Pages (the website)

1. In the Cloudflare dashboard, go to **Workers & Pages**, then **Create**, then **Pages**, then **Connect to Git**, and pick the repository.
2. Set **Framework preset** to None. Leave **Build command** empty. Set **Build output directory** to `/`.
3. Deploy. You get a `*.pages.dev` address. Add your own domain under **Custom domains** if you have one.
4. Put the final address into Supabase **URL Configuration** (step 1.5).

From then on, every push to GitHub redeploys the site automatically.

### 4. Check it works (5 minutes)

1. Open the site. Tap **Account**, type a username and a password, and tap **Create account**. The screen should say you're signed in.
2. In Supabase, open **Table Editor**, then `profiles`. Your new row should show the username.
3. Open the site in a second browser (or a private window) and make a second account.
4. In both, open the online lobby and start a H.O.R.S.E. match with the code from the first one. If both riders show up, multiplayer is live.
5. In the city, go to the paint shop and start a crew on one account, then join it with the code on the other.

## Full screen on phones

- iPhone Safari won't let any web page go full screen. The fix is **Add to Home Screen**: open the site in Safari, tap Share, then Add to Home Screen. The game then opens from its own icon with no browser bars, in landscape. This kit already has the app icon and settings for it (`manifest.webmanifest`, `icon-*.png`).
- Android phones and iPads go full screen when a pass-and-play or online match starts. There's also a Full screen button in the phone menu.

## How the money rules work

- **Coins earned from play** are awarded by the server. Each award is capped by reason: level 400, game over 200, mode 300, arcade 400, online 25 and pass-and-play 5. There is also a cap of 3000 per player per day. A hacked client can't award itself more than that.
- **Market**: the server sets prices from recent trades. Prices rise 4% for each recent buy and the effect fades with a 6-hour half-life. Selling pays 90%. Player listings pay the seller the moment they sell.
- **Wagers**:
  1. Both players stake into the match on the server.
  2. At the end, each player reports the winner. If the reports agree, the winner gets the pot. If they disagree, both are refunded.
  3. If one player vanishes, the other can claim the pot 2 minutes after reporting. The game does this automatically.
- **Shared items**: extra lives (`core:life`) and level skips (`core:skip`) belong to the player's account, not to this game. Point every one of your games at the **same Supabase project** and a player who signs in with the same wallet (or the same email) has the same coins, lives and skips in all of them. A game-only item would use that game's prefix, for example `spc:`.
- **Limited rides**: 12 models (3 per ride type) with a fixed supply each: Common 500 at 300 coins, Rare 150 at 900, Legendary 25 at 2,500. The `buy_ride` server function checks supply, takes the coins and mints the next numbered edition (for example `spc:ride:bmx-r#17`). Editions can only change hands through player listings, never the market maker. Supply and prices live in the `ride_models` table.
- **Accounts**: a username (unique, 3 to 12 letters, numbers or _) and a password of 8 or more characters. The username is set when the account is made and every world high score is stored under it, whatever the client sends.
- **Crews**: online only. A writer starts one at the paint shop (2 to 5 letter name, a colour) and shares the 6 character join code. Up to 12 writers, one crew each. Crew pieces carry the crew name and colour, crewmates can't go over each other, and crew walls pay into one pot. Each writer's cut follows their rank, worked out on the hour from the last 7 days of painting: KING (top painter) 4 shares, WRITER (15% or more) 2, TOY (painted, under 15%) 1, INACTIVE 0. The founder can rename and recolour the crew. The tables are `crews`, `crew_members` and `crew_paints`; join codes are only visible to members.
- **Multiplayer**: the online lobby, H.O.R.S.E. and races run over Supabase Realtime. Nothing to set up beyond the schema: Realtime is on by default in new projects.
- **Signed-out players** still play, earn and spend, but their coins stay on that device. Wagers, listings and world scores need an account.
- **Wallets**: a wallet is only linked when someone signs in with it, so the address is proven by signature. No tokens move yet. On-chain coins and rider NFTs on Robinhood Chain come later and plug into the same profile records.

## Changing things later

- Item prices and caps live in `supabase/schema.sql`: the `items` table and the `award_coins` function. Edit them and re-run the file.
- New game version: run `python3 build.py new-skatepark-city.html`, then commit `index.html`.
- Going to Robinhood Chain mainnet means one line in the game, `ACTIVE_CHAIN = CHAINS.robinhood`, plus a rebuild.
