"""
Data sources for the dashboard pages. Every function takes the shared Ctx and
returns plain dicts/lists for the templates. Each has a demo branch so
`python render.py --demo` works without network access or secrets.
"""
import calendar
import datetime as dt
import json
import math
import os
import re

import yaml

WMO = {0: "Clear", 1: "Mostly clear", 2: "Partly cloudy", 3: "Overcast",
       45: "Fog", 48: "Freezing fog", 51: "Light drizzle", 53: "Drizzle",
       55: "Heavy drizzle", 56: "Freezing drizzle", 57: "Freezing drizzle",
       61: "Light rain", 63: "Rain", 65: "Heavy rain", 66: "Freezing rain",
       67: "Freezing rain", 71: "Light snow", 73: "Snow", 75: "Heavy snow",
       77: "Snow grains", 80: "Light showers", 81: "Showers",
       82: "Heavy showers", 85: "Snow showers", 86: "Snow showers",
       95: "Thunderstorm", 96: "Thunderstorm, hail", 99: "Thunderstorm, hail"}


class Ctx:
    """Shared settings for one render run."""
    def __init__(self, root, cfg, tz, now, demo):
        self.root, self.cfg, self.tz, self.now, self.demo = root, cfg, tz, now, demo
        self.today = now.date()

    def path(self, *parts):
        return os.path.join(self.root, *parts)


def _get(url, **kw):
    import requests
    r = requests.get(url, timeout=20, headers={"User-Agent": "kdash"}, **kw)
    r.raise_for_status()
    return r


def _lines(c, *parts):
    """Lines of a data file, or none if it doesn't exist (feature not set up)."""
    try:
        with open(c.path(*parts)) as f:
            return f.readlines()
    except FileNotFoundError:
        return []


def calendar_urls():
    return [u.strip() for u in re.split(r"[\n,]", os.environ.get("ICS_URLS", "")) if u.strip()]


def has_calendar(c):
    return c.demo or bool(calendar_urls())


def has_location(c):
    loc = c.cfg.get("location") or {}
    return c.demo or (loc.get("lat") is not None and loc.get("lon") is not None)


# ----------------------------------------------------------------- weather ---
def weather(c):
    if not has_location(c):
        return None                      # no location set: weather is left out
    if c.demo:
        days = []
        for i in range(7):
            d = c.today + dt.timedelta(days=i)
            days.append({"date": d, "desc": ["Partly cloudy", "Light showers", "Clear", "Overcast",
                                             "Thunderstorm", "Mostly clear", "Clear"][i],
                         "hi": 27 - i // 2, "lo": 20 - i // 3, "rain": [10, 60, 0, 20, 80, 5, 0][i],
                         "wind": [18, 32, 12, 15, 40, 20, 10][i], "uv": [6, 3, 7, 4, 2, 6, 7][i],
                         "sunrise": "06:48", "sunset": "19:02"})
        hours = [{"time": "%02d:00" % ((c.now.hour + 2 * k) % 24), "temp": 26 - k,
                  "rain": [0, 5, 20, 40, 10][k - 1]} for k in range(1, 6)]
        return {"temp": 24, "feels": 26, "desc": "Partly cloudy", "wind": 18, "uv": 5,
                "hours": hours, "days": days}

    loc = c.cfg["location"]
    d = _get("https://api.open-meteo.com/v1/forecast", params={
        "latitude": loc["lat"], "longitude": loc["lon"], "timezone": c.cfg["timezone"],
        "current": "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,uv_index",
        "hourly": "temperature_2m,precipitation_probability",
        "daily": "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,"
                 "precipitation_probability_max,wind_speed_10m_max,uv_index_max",
        "forecast_days": 7}).json()
    cur, h, dy = d["current"], d["hourly"], d["daily"]
    key = c.now.strftime("%Y-%m-%dT%H:00")
    i = h["time"].index(key) if key in h["time"] else 0
    hours = [{"time": h["time"][j][11:16], "temp": round(h["temperature_2m"][j]),
              "rain": h["precipitation_probability"][j] or 0}
             for j in range(i + 2, min(i + 12, len(h["time"])), 2)][:5]
    days = []
    for j, date in enumerate(dy["time"]):
        days.append({"date": dt.date.fromisoformat(date),
                     "desc": WMO.get(dy["weather_code"][j], "Unknown"),
                     "hi": round(dy["temperature_2m_max"][j]), "lo": round(dy["temperature_2m_min"][j]),
                     "rain": dy["precipitation_probability_max"][j] or 0,
                     "wind": round(dy["wind_speed_10m_max"][j]),
                     "uv": round(dy["uv_index_max"][j] or 0),
                     "sunrise": dy["sunrise"][j][11:16], "sunset": dy["sunset"][j][11:16]})
    return {"temp": round(cur["temperature_2m"]), "feels": round(cur["apparent_temperature"]),
            "desc": WMO.get(cur["weather_code"], "Unknown"), "wind": round(cur["wind_speed_10m"]),
            "uv": round(cur.get("uv_index") or 0), "hours": hours, "days": days}


# ---------------------------------------------------------------- calendar ---
def _local(c, v):
    if not isinstance(v, dt.datetime):
        return dt.datetime.combine(v, dt.time(), c.tz)
    return v.astimezone(c.tz) if v.tzinfo else v.replace(tzinfo=c.tz)


def events(c, days):
    """Events from now's midnight for `days` days, sorted, with a deadline flag."""
    kws = [k.lower() for k in c.cfg.get("deadline_keywords") or []]
    start = dt.datetime.combine(c.today, dt.time(), c.tz)
    out = []
    if c.demo:
        sample = [(0, 16, "Kindle dashboard build", "Desk"), (0, 19, "Dinner with friends", "Downtown"),
                  (1, None, "Public holiday", ""), (1, 10, "Team meeting", "Room 3"),
                  (2, 14, "Gym", ""), (4, 9, "Project deadline", ""),
                  (5, 11, "Coffee with Sam", "Cafe"), (21, None, "Report due", "")]
        for d, h, title, loc in sample:
            s = start + dt.timedelta(days=d, hours=h or 0)
            out.append({"title": title, "location": loc, "allday": h is None, "start": s,
                        "end": s + dt.timedelta(hours=24 if h is None else 1)})
    else:
        import icalendar
        import recurring_ical_events
        for url in calendar_urls():      # none set: no events, no error
            cal = icalendar.Calendar.from_ical(_get(url).content)
            for ev in recurring_ical_events.of(cal).between(start, start + dt.timedelta(days=days)):
                s = ev.get("DTSTART").dt
                e = ev.get("DTEND").dt if ev.get("DTEND") else s
                allday = not isinstance(s, dt.datetime)
                s, e = _local(c, s), _local(c, e)
                if e <= s:
                    e = s + dt.timedelta(days=1 if allday else 0, hours=0 if allday else 1)
                out.append({"title": str(ev.get("SUMMARY", "(no title)")),
                            "location": str(ev.get("LOCATION", "") or ""),
                            "allday": allday, "start": s, "end": e})
    out = [e for e in out if e["start"] < start + dt.timedelta(days=days)]
    for e in out:
        e["deadline"] = any(k in e["title"].lower() for k in kws)
    return sorted(out, key=lambda e: (e["start"].date(), not e["allday"], e["start"]))


# ------------------------------------------------------ todos, countdowns ---
def todos(c):
    items = []
    for line in _lines(c, "data", "todos.md"):
        m = re.match(r"\s*[-*]\s*\[([ xX])\]\s*(.+)", line)
        if m:
            items.append({"text": m.group(2).strip(), "done": m.group(1) != " "})
    return [t for t in items if not t["done"]] + [t for t in items if t["done"]]


def countdowns(c, evs):
    out = []
    for item in c.cfg.get("countdowns") or []:
        out.append({"name": item["name"], "date": item["date"]})
    seen = {(o["name"].lower(), o["date"]) for o in out}
    for e in evs or []:
        key = (e["title"].lower(), e["start"].date())
        if e["deadline"] and key not in seen:
            out.append({"name": e["title"], "date": e["start"].date()})
            seen.add(key)
    for o in out:
        o["days"] = (o["date"] - c.today).days
    return sorted([o for o in out if o["days"] >= 0], key=lambda o: o["days"])


# ----------------------------------------------------------------- reading ---
def _clean(s):
    return re.sub(r"\s+", " ", s or "").strip()


def reading(c):
    sections = []
    if c.demo:
        return [{"name": "BBC World", "entries": [{"title": "Sample headline about world events number %d" % i,
                                                 "meta": "", "link": "https://www.bbc.com/news/world"} for i in range(1, 4)]},
                {"name": "Machine learning", "entries": [
                    {"title": "A sample paper title about learning from small data", "meta": "A. Author et al.", "link": "https://arxiv.org/"},
                    {"title": "A survey of sample methods for sample problems", "meta": "B. Author et al.", "link": "https://arxiv.org/"}]}]
    import feedparser
    errors = []
    srcs = [(f["name"], f["url"], f.get("max", 4), False) for f in c.cfg.get("feeds") or []]
    for a in c.cfg.get("arxiv") or []:
        import urllib.parse
        q = urllib.parse.urlencode({"search_query": a["query"], "sortBy": "submittedDate",
                                    "sortOrder": "descending", "max_results": a.get("max", 3)})
        srcs.append((a["name"], "https://export.arxiv.org/api/query?" + q, a.get("max", 3), True))
    # Download news feeds at once (slow one by one); arXiv asks for one request
    # at a time, so its queries run in order in a single worker. Parse in order.
    from concurrent.futures import ThreadPoolExecutor

    def fetch(urls):
        out = []
        for url in urls:
            try:
                out.append(_get(url).content)
            except Exception as ex:
                out.append(ex)
        return out
    groups = [[s[1]] for s in srcs if not s[3]] + [[s[1] for s in srcs if s[3]]]
    with ThreadPoolExecutor(8) as pool:
        got = dict(zip(sum(groups, []), sum(pool.map(fetch, groups), [])))
    bodies = [got[s[1]] for s in srcs]
    for (name, url, mx, is_arxiv), body in zip(srcs, bodies):
        try:
            if isinstance(body, Exception):
                raise body
            feed = feedparser.parse(body)
            items = []
            for e in feed.entries[:mx]:
                meta = ""
                if is_arxiv and e.get("authors"):
                    names = [a.get("name", "") for a in e.authors]
                    meta = names[0] + (" et al." if len(names) > 1 else "")
                items.append({"title": _clean(e.get("title")), "meta": meta,
                              "link": e.get("link", "")})
            if items:
                sections.append({"name": name, "entries": items})
        except Exception as ex:
            errors.append("%s (%s)" % (name, type(ex).__name__))
    if not sections and errors:
        raise RuntimeError(", ".join(errors))
    return sections


# ------------------------------------------------------------------ habits ---
def habits(c):
    """Parse data/habits.md into this month's grid."""
    months, cur = {}, None
    for line in _lines(c, "data", "habits.md"):
        line = line.strip()
        m = re.match(r"##\s*(\d{4})-(\d{2})", line)
        if m:
            cur = (int(m.group(1)), int(m.group(2)))
            months[cur] = []
        elif cur and ":" in line and not line.startswith("#"):
            name, nums = line.split(":", 1)
            days = {int(n) for n in re.findall(r"\d+", nums)}
            months[cur].append((name.strip(), days))
    this = (c.today.year, c.today.month)
    if this in months:
        rows = months[this]
    elif months:
        rows = [(n, set()) for n, _ in months[max(months)]]
    else:
        rows = []
    ndays = calendar.monthrange(*this)[1]
    out = []
    for name, days in rows:
        d = c.today.day if c.today.day in days else c.today.day - 1
        streak = 0
        while d >= 1 and d in days:
            streak, d = streak + 1, d - 1
        out.append({"name": name, "days": days, "streak": streak,
                    "count": len([x for x in days if x <= c.today.day])})
    return {"month": c.today.strftime("%B"), "ndays": ndays, "day": c.today.day, "rows": out}


# -------------------------------------------------------- quote, word, photo -
def _pick(c, filename):
    items = yaml.safe_load("".join(_lines(c, "data", filename))) or []
    return items[c.today.toordinal() % len(items)] if items else None


def quote(c):
    return _pick(c, "quotes.yaml")


def word(c):
    return _pick(c, "words.yaml")


def photo_path(c):
    folder = c.path("photos")
    if not os.path.isdir(folder):
        return None
    files = sorted(f for f in os.listdir(folder) if f.lower().endswith((".jpg", ".jpeg", ".png")))
    return os.path.join(folder, files[c.today.toordinal() % len(files)]) if files else None


def demo_photo(w, h):
    """Procedural test image so the dither can be checked without real photos."""
    from PIL import Image, ImageDraw
    img = Image.new("L", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            r = math.hypot(x - w * 0.35, y - h * 0.3)
            px[x, y] = max(0, min(255, int(235 - r * 0.35 + 25 * math.sin(x / 40))))
    d = ImageDraw.Draw(img)
    d.polygon([(0, h), (w * 0.45, h * 0.55), (w * 0.7, h * 0.75), (w, h * 0.5), (w, h)], fill=70)
    d.polygon([(0, h), (w * 0.3, h * 0.72), (w * 0.8, h), ], fill=35)
    return img
