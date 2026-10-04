#!/usr/bin/env python3
"""
Build out/data.json for the kdash-koreader plugin, plus out/photo.png (the
photo page, dithered). Screen size and grey levels come from `screen:` in
config.yaml (default 758x1024, 16 greys: Kindle Paperwhite 2).

  python render.py          real data (needs network; calendar from ICS_URLS)
  python render.py --demo   sample data, no secrets needed

Env vars:
  ICS_URLS        secret calendar (.ics) links, comma/newline separated

Pages are listed in config.yaml (`pages:`); each name maps to a builder in
PAGES below.
"""
import datetime as dt
import json
import math
import os
import sys
import traceback
from zoneinfo import ZoneInfo

import yaml
from PIL import Image, ImageOps

import sources

ROOT = os.path.dirname(os.path.abspath(__file__))
W, H = 758, 1024                  # set from config.yaml `screen:` in main()
GREYS = 16                        # grey levels the panel shows (PW2: 16)


def safe(label, fn, *args, default=None):
    """Run a data source; on failure return (default, short error text)."""
    try:
        return fn(*args), None
    except Exception as e:
        traceback.print_exc()
        return default, "%s unavailable: %s" % (label, e if isinstance(e, RuntimeError) else type(e).__name__)


class Data:
    """Lazy, cached access to data sources so each is fetched at most once."""
    def __init__(self, c):
        self.c, self.cache = c, {}

    def get(self, key):
        if key not in self.cache:
            c = self.c
            self.cache[key] = {
                "weather": lambda: safe("Weather", sources.weather, c),
                "events": lambda: safe("Calendar", sources.events, c,
                                       max(c.cfg.get("agenda_days", 7),
                                           c.cfg.get("countdown_calendar_days", 60)), default=[]),
                "reading": lambda: safe("Feeds", sources.reading, c, default=[]),
                "habits": lambda: safe("Habits", sources.habits, c),
            }[key]()
        return self.cache[key]

    def prefetch(self, keys):
        """Fetch the network sources in parallel before rendering starts."""
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(len(keys)) as pool:
            for key, result in zip(keys, pool.map(self.get, keys)):
                self.cache[key] = result


# ------------------------------------------------------------ page builders -
def page_today(c, d):
    w, w_err = d.get("weather")
    evs, e_err = d.get("events")
    todo = [t for t in sources.todos(c) if not t["done"]]
    return {"weather": w, "weather_error": w_err, "events_error": e_err,
            "has_calendar": sources.has_calendar(c),
            "upcoming": [e for e in evs if e["end"] > c.now][:3], "open_todos": todo}


def page_agenda(c, d):
    evs, e_err = d.get("events")
    days = []
    for i in range(c.cfg.get("agenda_days", 7)):
        day = c.today + dt.timedelta(days=i)
        days.append({"date": day, "today": i == 0,
                     "events": [e for e in evs if e["start"].date() == day][:4]})
    return {"agenda": days, "events_error": e_err}


def page_weather(c, d):
    w, err = d.get("weather")
    return {"weather": w, "weather_error": err}


def page_todos(c, d):
    return {"todos": sources.todos(c)}


def page_countdowns(c, d):
    evs, err = d.get("events")
    return {"countdowns": sources.countdowns(c, evs), "events_error": err}


def page_dots(c, d):
    """Dot grid, one dot per day from dots.start to dots.end (like a countdown wallpaper)."""
    cfg = c.cfg.get("dots") or {}
    start, end = cfg.get("start", c.today), cfg["end"]
    total = max((end - start).days, 1)
    gone = min(max((c.today - start).days, 0), total)
    # Pick a column count that fills the grid area (662 x 600 px on a 758x1024 screen) evenly
    area_w, area_h = W - 96, H * 600 // 1024
    cols = max(1, math.ceil(math.sqrt(total * area_w / area_h)))
    rows = math.ceil(total / cols)
    cell = min(area_w / cols, area_h / rows)
    return {"name": cfg.get("name", ""), "end": end, "left": (end - c.today).days,
            "total": total, "gone": gone, "cols": cols, "cell": int(cell),
            "dot": max(4, int(cell * 0.62))}


def page_reading(c, d):
    secs, err = d.get("reading")
    return {"sections": secs, "reading_error": err}


def page_habits(c, d):
    h, err = d.get("habits")
    return {"habits": h, "habits_error": err}


def page_quote(c, d):
    return {"quote": sources.quote(c), "word": sources.word(c)}


# Is a page set up? Pages that aren't are left out, so nothing half-empty shows.
READY = {
    "agenda": lambda c: sources.has_calendar(c),
    "weather": lambda c: sources.has_location(c),
    # todos always shows, even empty: its + button is how you add the first one
    "countdowns": lambda c: bool(c.cfg.get("countdowns")) or sources.has_calendar(c),
    "dots": lambda c: bool((c.cfg.get("dots") or {}).get("end")),
    "reading": lambda c: c.demo or bool(c.cfg.get("feeds") or c.cfg.get("arxiv")),
    "habits": lambda c: bool(sources.habits(c)["rows"]),
    "quote": lambda c: bool(sources.quote(c) or sources.word(c)),
    "photo": lambda c: c.demo or bool(sources.photo_path(c)),
}


def ready(c, name):
    try:
        return READY.get(name, lambda c: True)(c)
    except Exception:
        return True                      # broken data: render it so the error shows


PAGES = {"today": page_today, "agenda": page_agenda, "weather": page_weather,
         "todos": page_todos, "countdowns": page_countdowns, "dots": page_dots, "reading": page_reading,
         "habits": page_habits, "quote": page_quote, "photo": None}


# ---------------------------------------------------------------- imaging ---
def dither(img):
    """Floyd-Steinberg dither to 16 greys, for photos."""
    pal = Image.new("P", (1, 1))
    step = 255 / (GREYS - 1)
    pal.putpalette([int(round(i * step)) for i in range(GREYS) for _ in range(3)] + [0] * (768 - GREYS * 3))
    return img.convert("RGB").quantize(palette=pal, dither=Image.Dither.FLOYDSTEINBERG).convert("L")


def render_photo(c, out_path):
    src = sources.photo_path(c)
    if src:
        img = ImageOps.exif_transpose(Image.open(src)).convert("L")
    elif c.demo:
        img = sources.demo_photo(W, H)
    else:
        return False                     # caller renders the empty-state template
    img = ImageOps.fit(img, (W, H), Image.LANCZOS)
    img = ImageOps.autocontrast(img, cutoff=1)
    dither(img).save(out_path, optimize=True)
    return True


def jsonable(v):
    """Page data as plain JSON for data.json: dates as ISO text, sets as sorted
    lists, and None left out (Lua would read null as a true value, not nil)."""
    if isinstance(v, dict):
        return {k: jsonable(x) for k, x in v.items() if x is not None}
    if isinstance(v, (list, tuple, set, frozenset)):
        return [jsonable(x) for x in (sorted(v) if isinstance(v, (set, frozenset)) else v)]
    if isinstance(v, (dt.date, dt.datetime)):
        return v.isoformat()
    return v


# ------------------------------------------------------------------- main ---
# Keys data/settings.json (edited by the companion page) can set over config.yaml
SETTINGS_KEYS = ("pages", "countdowns", "dots", "feeds", "arxiv", "location", "timezone",
                 "agenda_days", "deadline_keywords", "countdown_calendar_days")


def load_config():
    """config.yaml, overlaid with data/settings.json if there is one."""
    cfg = yaml.safe_load(open(os.path.join(ROOT, "config.yaml")))
    path = os.path.join(ROOT, "data", "settings.json")
    if os.path.exists(path):
        with open(path) as f:
            s = json.load(f)
        for k in SETTINGS_KEYS:
            if k in s:
                cfg[k] = s[k]

    def day(v):                   # JSON has "2027-02-15" strings, YAML has dates
        return dt.date.fromisoformat(v) if isinstance(v, str) else v
    for item in cfg.get("countdowns") or []:
        item["date"] = day(item["date"])
    dots = cfg.get("dots") or {}
    for k in ("start", "end"):
        if dots.get(k):
            dots[k] = day(dots[k])
    return cfg


def main():
    global W, H, GREYS
    demo = "--demo" in sys.argv
    cfg = load_config()
    screen = cfg.get("screen") or {}
    W, H = int(screen.get("width", W)), int(screen.get("height", H))
    GREYS = int(screen.get("greys", GREYS))
    tz = ZoneInfo(cfg.get("timezone") or "UTC")
    c = sources.Ctx(ROOT, cfg, tz, dt.datetime.now(tz), demo)
    data = Data(c)

    names = [p for p in cfg.get("pages", list(PAGES)) if p in PAGES]
    skipped = [p for p in names if not ready(c, p)]
    names = [p for p in names if p not in skipped] or ["today"]
    if skipped:
        print("not set up, left out:", ", ".join(skipped))
    data.prefetch(["weather", "events", "reading"])
    out = os.path.join(ROOT, "out")
    os.makedirs(out, exist_ok=True)

    pages = []
    for name in names:
        if name == "photo":
            if render_photo(c, os.path.join(out, "photo.png")):
                pages.append({"name": name, "png": "photo.png", "data": {}})
                print("photo.png written")
            continue
        pages.append({"name": name, "data": PAGES[name](c, data) if PAGES[name] else {}})
        print("page", name)

    # Everything the KOReader plugin (github.com/hadihassan04/kdash-koreader)
    # draws, as data
    loc = (cfg.get("location") or {}).get("name", "")
    with open(os.path.join(out, "data.json"), "w") as f:
        json.dump(jsonable({"updated": c.now.isoformat(timespec="minutes"), "today": c.today,
                            "location": loc, "pages": pages}), f, ensure_ascii=False)
    print("wrote data.json with %d pages" % len(pages))

if __name__ == "__main__":
    main()
