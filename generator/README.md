# kdash data generator

Builds the `data.json` that the kdash KOReader plugin draws. It runs on GitHub
Actions in your own private repo, in about 20 seconds, whenever the Kindle asks
for a refresh or you push a change. It needs no server and no API keys.

| Page | Comes from |
|---|---|
| today, weather | Open-Meteo, from `location` in `config.yaml` |
| agenda, countdowns | your calendar's `.ics` link(s), in the `ICS_URLS` secret |
| todos | `data/todos.md` |
| habits | `data/habits.md` |
| countdowns, dots | `countdowns` and `dots` in `config.yaml` |
| reading | the `feeds` (RSS/Atom) and `arxiv` searches in `config.yaml` |
| quote | `data/quotes.yaml` and `data/words.yaml`, one a day |
| photo | a picture from `photos/`, one a day |

A page with nothing set up (no calendar, no photos...) hides itself.

## Set up
1. Create a new **private** repo on GitHub. It will hold your to-dos, habits,
   photos and settings.
2. Copy everything in this folder, including `.github/`, to the root of that repo
   and push it to `main`.
3. Edit `config.yaml` (your `timezone` and `location`: name, lat, lon) and
   `data/settings.json` (pages, countdowns, dots, feeds, arXiv), or use the
   companion page for the second.
4. Add your calendar: in the repo, Settings > Secrets and variables > Actions >
   **New repository secret**, name `ICS_URLS`, value your calendar's secret iCal
   link (Google Calendar: Settings > your calendar > "Secret address in iCal
   format"). Several links go on separate lines. Use a repository secret, not a
   variable or an environment.
5. Actions tab > Render dashboard > **Run workflow**. When it's done, the repo has
   an `out` branch with `data.json`.
6. Make a fine-grained token (github.com/settings/personal-access-tokens/new):
   Repository access "Only select repositories" > this repo; permissions
   **Contents** and **Actions**, read and write.
7. On the Kindle, set the repo (`owner/name`) and the token in Tools > Dashboard
   (kdash), or put them in `koreader/kdash/repo.txt` and `koreader/kdash/token.txt`.

## Everyday use
- The companion page, https://hadihassan04.github.io/kdash-koreader/, edits
  to-dos and `data/settings.json` (page order, countdowns, dots, feeds, arXiv)
  from any browser. Sign in with this repo's name and the same token.
- Tick, add and delete to-dos and habits on the Kindle; it commits the files here.
  You can also edit them in the GitHub app: every push rebuilds `data.json`.
- To test changes on a computer: `pip install -r requirements.txt`, then
  `python render.py` (real data; set `ICS_URLS` in the environment for the
  calendar) or `python render.py --demo` (sample data, no network). The output
  is in `out/`.
- `pages`, `countdowns`, `dots`, `feeds` and `arxiv` can also go in
  `config.yaml`; `data/settings.json` wins where both have a key.
