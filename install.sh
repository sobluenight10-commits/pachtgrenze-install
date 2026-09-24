#!/bin/bash
# One shot. Resume is the stamp files under /var/lib/pachtgrenze.
# Never stops a container outside project pachtgrenze. Never binds host port 8080.
set -euo pipefail
START=$(date +%s)
ROOT=/opt/pachtgrenze
STATE=/var/lib/pachtgrenze
mkdir -p "$ROOT/app" "$STATE"
finish() {
  local code=$?
  echo "ELAPSED $(( $(date +%s) - START ))s"
  if [[ $code -eq 0 ]]; then echo PASS; else echo FAIL; fi
}
trap finish EXIT
if [[ "$(id -u)" -ne 0 ]]; then
  echo "need root"
  exit 1
fi
cat > $ROOT/docker-compose.yml << 'PACH_COMPOSE'
name: pachtgrenze
services:
  db:
    image: postgis/postgis:16-3.4
    container_name: pachtgrenze-db
    environment:
      POSTGRES_USER: pacht
      POSTGRES_PASSWORD: pacht
      POSTGRES_DB: pacht
    volumes:
      - pacht-db:/var/lib/postgresql/data
      - ./init.sql:/docker-entrypoint-initdb.d/01-init.sql:ro
    ports:
      - "127.0.0.1:5433:5432"
  app:
    build: ./app
    container_name: pachtgrenze-app
    volumes:
      - /var/lib/pachtgrenze:/status:ro
    depends_on:
      - db
  caddy:
    image: caddy:2-alpine
    container_name: pachtgrenze-caddy
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
    ports:
      - "127.0.0.1:9080:80"
    depends_on:
      - app
volumes:
  pacht-db:
PACH_COMPOSE
cat > $ROOT/Caddyfile << 'PACH_CADDY'
:80 {
	reverse_proxy app:8090
}
PACH_CADDY
cat > $ROOT/init.sql << 'PACH_INIT'
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE TABLE IF NOT EXISTS address (
  label text NOT NULL,
  geom geometry(Point, 4326) NOT NULL
);
CREATE INDEX IF NOT EXISTS address_gix ON address USING gist (geom);
CREATE TABLE IF NOT EXISTS food (
  kind text NOT NULL,
  geom geometry(Point, 4326) NOT NULL
);
CREATE INDEX IF NOT EXISTS food_gix ON food USING gist (geom);
CREATE TABLE IF NOT EXISTS shop (
  geom geometry(Point, 4326) NOT NULL
);
CREATE INDEX IF NOT EXISTS shop_gix ON shop USING gist (geom);
CREATE TABLE IF NOT EXISTS office (
  floor_m2 double precision,
  geom geometry(Polygon, 4326) NOT NULL
);
CREATE INDEX IF NOT EXISTS office_gix ON office USING gist (geom);
CREATE TABLE IF NOT EXISTS zensus (
  residents integer NOT NULL,
  geom geometry(Polygon, 4326) NOT NULL
);
CREATE INDEX IF NOT EXISTS zensus_gix ON zensus USING gist (geom);
CREATE TABLE IF NOT EXISTS operator_history (
  label text NOT NULL,
  name text NOT NULL,
  seen date NOT NULL
);
CREATE TABLE IF NOT EXISTS zensus_raw (
  gitter text,
  x integer,
  y integer,
  einwohner integer
);
CREATE TABLE IF NOT EXISTS level_default (
  scope text PRIMARY KEY,
  median_levels double precision NOT NULL,
  tagged integer NOT NULL
);
ALTER TABLE food ADD COLUMN IF NOT EXISTS in_frankfurt boolean;
ALTER TABLE shop ADD COLUMN IF NOT EXISTS in_frankfurt boolean;
ALTER TABLE office ADD COLUMN IF NOT EXISTS in_frankfurt boolean;
ALTER TABLE office ADD COLUMN IF NOT EXISTS levels_defaulted boolean;
PACH_INIT
cat > $ROOT/refresh.sql << 'PACH_REFRESH'
-- One transaction so a bad rerun does not leave empty tables.
-- Stadtteil = OSM admin_level 10 (Frankfurt: 46 Stadtteile). Median is percentile_disc, an observed level.
BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM planet_osm_polygon
    WHERE boundary = 'administrative' AND admin_level = '6' AND name = 'Frankfurt am Main'
  ) THEN
    RAISE EXCEPTION 'Frankfurt boundary missing';
  END IF;
END $$;

CREATE TEMP TABLE ffm AS
SELECT way AS geom
FROM planet_osm_polygon
WHERE boundary = 'administrative' AND admin_level = '6' AND name = 'Frankfurt am Main'
ORDER BY ST_Area(way::geography) DESC
LIMIT 1;

CREATE TEMP TABLE stadtteil AS
SELECT row_number() OVER () AS id, name, way AS geom
FROM planet_osm_polygon
WHERE boundary = 'administrative'
  AND admin_level = '10'
  AND name IS NOT NULL
  AND ST_Covers((SELECT geom FROM ffm), ST_Centroid(way));

TRUNCATE address, food, shop, office, level_default;

INSERT INTO address (label, geom)
SELECT trim(concat_ws(', ',
         "addr:housenumber" || ' ' || (tags->'addr:street'),
         NULLIF(tags->'addr:postcode', ''),
         NULLIF(tags->'addr:city', ''))),
       ST_Centroid(way)
FROM planet_osm_point
WHERE NULLIF(tags->'addr:street', '') IS NOT NULL
  AND "addr:housenumber" IS NOT NULL
UNION ALL
SELECT trim(concat_ws(', ',
         "addr:housenumber" || ' ' || (tags->'addr:street'),
         NULLIF(tags->'addr:postcode', ''),
         NULLIF(tags->'addr:city', ''))),
       ST_Centroid(way)
FROM planet_osm_polygon
WHERE NULLIF(tags->'addr:street', '') IS NOT NULL
  AND "addr:housenumber" IS NOT NULL;

INSERT INTO food (kind, geom, in_frankfurt)
SELECT amenity, way, ST_Covers((SELECT geom FROM ffm), way)
FROM planet_osm_point
WHERE amenity = 'fast_food'
UNION ALL
SELECT amenity, ST_Centroid(way), ST_Covers((SELECT geom FROM ffm), ST_Centroid(way))
FROM planet_osm_polygon
WHERE amenity = 'fast_food';

INSERT INTO shop (geom, in_frankfurt)
SELECT way, ST_Covers((SELECT geom FROM ffm), way)
FROM planet_osm_point
WHERE shop IS NOT NULL
UNION ALL
SELECT ST_Centroid(way), ST_Covers((SELECT geom FROM ffm), ST_Centroid(way))
FROM planet_osm_polygon
WHERE shop IS NOT NULL;

CREATE TEMP TABLE office_raw AS
SELECT
  way AS geom,
  ST_Covers((SELECT geom FROM ffm), ST_Centroid(way)) AS in_frankfurt,
  CASE
    WHEN tags->'building:levels' ~ '^[0-9]+(\.[0-9]+)?$'
      THEN (tags->'building:levels')::double precision
    ELSE NULL
  END AS levels
FROM planet_osm_polygon
WHERE building = 'office';

CREATE TEMP TABLE city_median AS
SELECT percentile_disc(0.5) WITHIN GROUP (ORDER BY levels) AS median_levels,
       COUNT(*)::int AS tagged
FROM office_raw
WHERE in_frankfurt AND levels IS NOT NULL;

CREATE TEMP TABLE stadtteil_median AS
SELECT s.id,
       s.name,
       percentile_disc(0.5) WITHIN GROUP (ORDER BY o.levels) AS median_levels,
       COUNT(*)::int AS tagged
FROM office_raw o
JOIN stadtteil s ON ST_Covers(s.geom, ST_Centroid(o.geom))
WHERE o.in_frankfurt AND o.levels IS NOT NULL
GROUP BY s.id, s.name;

INSERT INTO level_default (scope, median_levels, tagged)
SELECT 'Frankfurt', median_levels, tagged FROM city_median WHERE median_levels IS NOT NULL
UNION ALL
SELECT 'Stadtteil ' || name, median_levels, tagged FROM stadtteil_median;

INSERT INTO office (floor_m2, levels_defaulted, in_frankfurt, geom)
SELECT
  CASE WHEN chosen.levels IS NULL THEN NULL
       ELSE ST_Area(o.geom::geography) * chosen.levels
  END,
  (o.levels IS NULL AND chosen.levels IS NOT NULL),
  o.in_frankfurt,
  o.geom
FROM office_raw o
LEFT JOIN LATERAL (
  SELECT sm.median_levels
  FROM stadtteil s
  JOIN stadtteil_median sm ON sm.id = s.id
  WHERE o.in_frankfurt
    AND ST_Covers(s.geom, ST_Centroid(o.geom))
  ORDER BY ST_Area(s.geom::geography)
  LIMIT 1
) sm ON true
CROSS JOIN LATERAL (
  SELECT COALESCE(o.levels, sm.median_levels, (SELECT median_levels FROM city_median)) AS levels
) chosen;

CREATE INDEX IF NOT EXISTS address_geog ON address USING gist ((geom::geography));
CREATE INDEX IF NOT EXISTS address_label ON address (label text_pattern_ops);
CREATE INDEX IF NOT EXISTS food_geog ON food USING gist ((geom::geography));
CREATE INDEX IF NOT EXISTS shop_geog ON shop USING gist ((geom::geography));
CREATE INDEX IF NOT EXISTS office_geog ON office USING gist ((geom::geography));
CREATE INDEX IF NOT EXISTS zensus_geog ON zensus USING gist ((geom::geography));
ANALYZE address, food, shop, office, zensus, level_default;

COMMIT;
PACH_REFRESH
cat > $ROOT/model.py << 'PACH_MODEL'
"""Same rules as src/lib/pacht-model.ts. Imbiss turnover only. No colour if workplaces are missing."""

SHOP_OUT = 40
SHOP_RADIUS_M = 150
RADIUS_M = 400
INDEX_MIN = 0.5
INDEX_MAX = 2.0
RENT_SHARE = 0.1
OPEN_DAYS = 26
M2_DENSE = 8.68
M2_SPARSE = 12.18
IMBISS_TAXPAYERS = 50_021
IMBISS_TURNOVER_TSD = 7_694_250
IMBISS_MONTH = (IMBISS_TURNOVER_TSD * 1000) / IMBISS_TAXPAYERS / 12

def workplaces(floor_m2, skipped):
    if skipped:
        return None, None
    return floor_m2 / M2_SPARSE, floor_m2 / M2_DENSE

def judge(residents, workplaces_low, workplaces_high, outlets, city_residents, city_work_low, city_work_high, city_outlets, rent_month, plate, m2):
    missing = []
    if residents is None:
        missing.append("residents")
    if workplaces_low is None or workplaces_high is None:
        missing.append("workplaces")
    if outlets is None:
        missing.append("outlets")
    if None in (city_residents, city_work_low, city_work_high, city_outlets) or not city_outlets:
        missing.append("citywide")
    if missing:
        return {"status": "nicht gemessen", "missing": missing}

    def index_for(work, city_work):
        local = (residents + work) / max(outlets, 1)
        city = (city_residents + city_work) / city_outlets
        raw = local / city
        return min(INDEX_MAX, max(INDEX_MIN, raw))

    index_low = index_for(workplaces_low, city_work_low)
    index_high = index_for(workplaces_high, city_work_high)
    lo, hi = sorted((index_low, index_high))
    sales_low = IMBISS_MONTH * lo
    sales_high = IMBISS_MONTH * hi
    plates_needed = rent_month / RENT_SHARE / plate / OPEN_DAYS
    plates_low = sales_low / plate / OPEN_DAYS
    plates_high = sales_high / plate / OPEN_DAYS
    cov_low = plates_low / plates_needed
    cov_high = plates_high / plates_needed
    if cov_high < 1:
        tone = "bad"
    elif cov_low >= 1:
        tone = "ok"
    else:
        tone = "warn"
    return {
        "status": "colour",
        "concept": "imbiss",
        "wz": "56.10.3",
        "radiusM": RADIUS_M,
        "locationIndex": {"low": lo, "high": hi},
        "salesMonthEur": {"low": sales_low, "high": sales_high},
        "plates": {"low": plates_low, "high": plates_high},
        "platesNeeded": plates_needed,
        "coverage": {"low": cov_low, "high": cov_high},
        "tone": tone,
    }
PACH_MODEL
cat > $ROOT/selftest.py << 'PACH_SELFTEST'
"""Berger 148 or Waldschul 8 must return a colour or a named out-of-scope reason. nicht gemessen is not a pass."""

import json
import subprocess
import sys
import time

from model import RADIUS_M, SHOP_OUT, SHOP_RADIUS_M, judge, workplaces

FIXED = [
    ("zeil-22", "22 Zeil", "60313"),
    ("berger-148", "148 Berger", "60385"),
    ("waldschul-8", "8 Waldschul", "65933"),
]
GATES = {"berger-148", "waldschul-8"}
# IHK low band, Gewerbemarktbericht 2025, times the labelled 80 m² assumption. Not a listing.
PROBE_RENT = 800
PROBE_M2 = 80
PROBE_PLATE = 7.5

def psql(sql):
    out = subprocess.check_output(
        [
            "docker", "exec", "-e", "PGPASSWORD=pacht",
            "-e", "PGOPTIONS=-c statement_timeout=2500", "pachtgrenze-db",
            "psql", "-U", "pacht", "-d", "pacht", "-v", "ON_ERROR_STOP=1", "-tA", "-c", sql,
        ],
        text=True,
    )
    return out.strip()

def share(defaulted, count):
    if count == 0:
        return None
    return round(defaulted / count, 4)

def workplace_block(where):
    skipped, defaulted, count, floor = psql(
        "SELECT COUNT(*) FILTER (WHERE floor_m2 IS NULL) || '|' || "
        "COUNT(*) FILTER (WHERE levels_defaulted) || '|' || "
        "COUNT(*) || '|' || COALESCE(SUM(floor_m2), 0) "
        f"FROM office WHERE {where}"
    ).split("|")
    skipped_n = int(skipped)
    defaulted_n = int(defaulted)
    count_n = int(count)
    low, high = workplaces(float(floor), skipped_n)
    label = "Schätzung" if defaulted_n > 0 else ("gemessen" if skipped_n == 0 else None)
    return low, high, {
        "defaulted_share": share(defaulted_n, count_n),
        "defaulted": defaulted_n,
        "offices": count_n,
        "workplace_label": label,
    }

def one(number_street, postcode):
    label = psql(
        "SELECT label || '|' || ST_Y(geom)::text || '|' || ST_X(geom)::text FROM address "
        f"WHERE (split_part(label, ',', 1) = '{number_street}' "
        f"OR split_part(label, ',', 1) LIKE '{number_street} %') "
        f"AND label LIKE '%{postcode}%' "
        "ORDER BY char_length(label) LIMIT 1"
    )
    if not label:
        return {"status": "fail", "error": "geocode"}
    name, lat, lon = label.split("|")
    point = f"SRID=4326;POINT({lon} {lat})"
    near = f"ST_DWithin(geom::geography, ST_GeogFromText('{point}'), {{radius}})"
    shops = int(psql(f"SELECT COUNT(*) FROM shop WHERE {near.format(radius=SHOP_RADIUS_M)}"))
    low, high, meta = workplace_block(near.format(radius=RADIUS_M))
    city_low, city_high, city_meta = workplace_block("in_frankfurt")
    if shops >= SHOP_OUT:
        return {
            "status": "out",
            "label": name,
            "shops150": shops,
            "reason": f"Check gilt hier nicht (Einkaufsstraße). {shops} shop=* innerhalb von {SHOP_RADIUS_M} m. Grenze {SHOP_OUT}.",
            **meta,
            "city_defaulted_share": city_meta["defaulted_share"],
        }
    residents_raw = psql(
        "SELECT SUM(residents) FROM zensus WHERE "
        f"ST_DWithin(geom::geography, ST_GeogFromText('{point}'), {RADIUS_M})"
    )
    residents = None if residents_raw == "" else float(residents_raw)
    outlets = int(psql(
        "SELECT COUNT(*) FROM food WHERE kind = 'fast_food' AND "
        f"ST_DWithin(geom::geography, ST_GeogFromText('{point}'), {RADIUS_M})"
    ))
    city_people_raw = psql("SELECT SUM(residents) FROM zensus")
    city_people = None if city_people_raw == "" else float(city_people_raw)
    city_food = int(psql("SELECT COUNT(*) FROM food WHERE kind = 'fast_food' AND in_frankfurt"))
    judged = judge(
        residents, low, high, outlets, city_people, city_low, city_high, city_food,
        PROBE_RENT, PROBE_PLATE, PROBE_M2,
    )
    judged["label"] = name
    judged["shops150"] = shops
    judged.update(meta)
    judged["city_defaulted_share"] = city_meta["defaulted_share"]
    judged["rent_note"] = "IHK 10 EUR/m2 x assumed 80 m2"
    return judged

def counts(row):
    if row.get("seconds", 99) >= 3:
        return False
    if row.get("status") == "colour":
        return True
    if row.get("status") == "out" and row.get("reason"):
        return True
    return False

def main():
    print("LEVEL_DEFAULT", psql(
        "SELECT COALESCE(scope || ' median ' || median_levels || ' tagged ' || tagged, 'none') "
        "FROM level_default WHERE scope = 'Frankfurt'"
    ))
    print("STADTTEIL_MEDIANS", psql("SELECT COUNT(*) FROM level_default WHERE scope LIKE 'Stadtteil %'"))
    gate = False
    for key, street, postcode in FIXED:
        started = time.perf_counter()
        try:
            row = one(street, postcode)
        except subprocess.CalledProcessError as exc:
            row = {"status": "fail", "error": "psql"}
        elapsed = time.perf_counter() - started
        row["id"] = key
        row["seconds"] = round(elapsed, 3)
        if key in GATES and counts(row):
            gate = True
        print(json.dumps(row, ensure_ascii=False))
    if gate:
        print("SELFTEST PASS")
        return 0
    print("SELFTEST FAIL")
    print("need Berger 148 or Waldschul 8 colour or named out-of-scope. nicht gemessen is not a pass")
    return 1

if __name__ == "__main__":
    sys.exit(main())
PACH_SELFTEST
cat > $ROOT/backtest.py << 'PACH_BACKTEST'
"""20 fast_food nodes present in OSM at both dates, via ohsome. PASS only if at least 15 of 20 get a colour."""

import json
import subprocess
import sys
import urllib.parse
import urllib.request

from model import RADIUS_M, SHOP_OUT, SHOP_RADIUS_M, judge, workplaces

# IHK Frankfurt, Gewerbemarktbericht Ausgabe 2025, Einzelhandel 1-b und Nebenlage.
# Bornheim, Berger Straße: von 10,00 bis 21,50 EUR/m²/Monat. Schwerpunkt dort nicht angegeben.
# https://www.frankfurt-main.ihk.de/blueprint/servlet/resource/blob/6750400/e6f23a9813c1ecaf6f27022e61e9b789/gewerbemarktbericht-2025-data.pdf
RENT_SOURCE = "IHK Frankfurt Gewerbemarktbericht 2025, Berger Straße, 1-b und Nebenlage, von 10,00 bis 21,50 EUR/m2/Monat"
RENTS = (10.0, 21.5)
ASSUMED_M2 = 80
PLATE = 7.5
EARLY = "2021-09-24"
LATE = "2026-09-24"
NEED_COLOUR = 15

def psql(sql):
    out = subprocess.check_output(
        [
            "docker", "exec", "-e", "PGPASSWORD=pacht",
            "-e", "PGOPTIONS=-c statement_timeout=2500", "pachtgrenze-db",
            "psql", "-U", "pacht", "-d", "pacht", "-v", "ON_ERROR_STOP=1", "-tA", "-c", sql,
        ],
        text=True,
    )
    return out.strip()

def ohsome(when):
    query = urllib.parse.urlencode(
        {
            "bboxes": "8.472,50.015,8.800,50.227",
            "filter": "amenity=fast_food",
            "time": when,
            "properties": "tags",
        }
    )
    request = urllib.request.Request(
        "https://api.ohsome.org/v1/elements/centroid?" + query,
        headers={"User-Agent": "pachtgrenze-check/0.1 (https://pachtgrenze.de)"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.load(response)

def features(body):
    found = {}
    for feature in body.get("features", []):
        props = feature.get("properties") or {}
        osm_id = str(props.get("@osmId") or feature.get("id") or "")
        if not osm_id:
            continue
        coords = (feature.get("geometry") or {}).get("coordinates") or [None, None]
        found[osm_id] = {"lon": coords[0], "lat": coords[1], "name": (props.get("name") or "")}
    return found

def levels_at(where):
    skipped, defaulted, count, floor = psql(
        "SELECT COUNT(*) FILTER (WHERE floor_m2 IS NULL) || '|' || "
        "COUNT(*) FILTER (WHERE levels_defaulted) || '|' || "
        "COUNT(*) || '|' || COALESCE(SUM(floor_m2), 0) "
        f"FROM office WHERE {where}"
    ).split("|")
    low, high = workplaces(float(floor), int(skipped))
    count_n = int(count)
    defaulted_n = int(defaulted)
    share = None if count_n == 0 else round(defaulted_n / count_n, 4)
    label = "Schätzung" if defaulted_n > 0 else ("gemessen" if int(skipped) == 0 else None)
    return low, high, share, label

def colour_at(lat, lon, rent_m2):
    point = f"SRID=4326;POINT({lon} {lat})"
    near = f"ST_DWithin(geom::geography, ST_GeogFromText('{point}'), {{radius}})"
    shops = int(psql(f"SELECT COUNT(*) FROM shop WHERE {near.format(radius=SHOP_RADIUS_M)}"))
    low, high, share, label = levels_at(near.format(radius=RADIUS_M))
    city_low, city_high, city_share, _ = levels_at("in_frankfurt")
    meta = {"defaulted_share": share, "city_defaulted_share": city_share, "workplace_label": label}
    if shops >= SHOP_OUT:
        return "out", {**meta, "reason": "Einkaufsstraße"}
    residents_raw = psql(
        "SELECT SUM(residents) FROM zensus WHERE "
        f"ST_DWithin(geom::geography, ST_GeogFromText('{point}'), {RADIUS_M})"
    )
    outlets = int(psql(
        "SELECT COUNT(*) FROM food WHERE kind = 'fast_food' AND "
        f"ST_DWithin(geom::geography, ST_GeogFromText('{point}'), {RADIUS_M})"
    ))
    city_people_raw = psql("SELECT SUM(residents) FROM zensus")
    city_food = int(psql("SELECT COUNT(*) FROM food WHERE kind = 'fast_food' AND in_frankfurt"))
    row = judge(
        None if residents_raw == "" else float(residents_raw),
        low,
        high,
        outlets,
        None if city_people_raw == "" else float(city_people_raw),
        city_low,
        city_high,
        city_food,
        rent_m2 * ASSUMED_M2,
        PLATE,
        ASSUMED_M2,
    )
    row.update(meta)
    if row["status"] != "colour":
        return "nicht gemessen", row
    tone = {"bad": "red", "warn": "amber", "ok": "green"}[row["tone"]]
    row["tone_word"] = tone
    return tone, row

def main():
    print("RENT", RENT_SOURCE)
    print(f"ASSUMED_M2 {ASSUMED_M2}")
    print(f"PLATE_EUR {PLATE} not from a menu")
    try:
        early = features(ohsome(EARLY))
        late = features(ohsome(LATE))
    except Exception as exc:
        print("BACKTEST FAIL")
        print("history nicht gemessen")
        print(type(exc).__name__)
        return 1
    both = sorted(set(early) & set(late))
    print(f"HISTORY_BOTH {len(both)} {EARLY} {LATE}")
    if len(both) < 20:
        print("BACKTEST FAIL")
        print(f"need 20 have {len(both)}")
        return 1
    chosen = []
    for key in both[:20]:
        row = dict(late[key])
        row["id"] = key
        chosen.append(row)
    best = None
    coloured_ok = True
    for rent in RENTS:
        counts = {"green": 0, "amber": 0, "red": 0, "out": 0, "nicht gemessen": 0}
        for shop in chosen:
            if shop["lat"] is None:
                counts["nicht gemessen"] += 1
                continue
            tone, detail = colour_at(shop["lat"], shop["lon"], rent)
            counts[tone] += 1
            if tone == "green" and best is None and detail is not None and detail.get("status") == "colour":
                best = {"id": shop["id"], "rent_m2": rent, "detail": detail}
        coloured = counts["green"] + counts["amber"] + counts["red"]
        print(
            f"RENT_EUR_M2 {rent} green {counts['green']} amber {counts['amber']} "
            f"red {counts['red']} out {counts['out']} nicht_gemessen {counts['nicht gemessen']}"
        )
        if coloured and counts["red"] > counts["green"] + counts["amber"]:
            print("MODEL FAIL parameter RENT_SHARE 0.10 times national Imbiss month, index capped at 2")
        if coloured < NEED_COLOUR:
            coloured_ok = False
            print(f"coloured {coloured} need {NEED_COLOUR}")
    if best is not None and coloured_ok:
        path = "/var/lib/pachtgrenze/sample-report.txt"
        detail = best["detail"]
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(
                "\n".join(
                    [
                        f"id {best['id']}",
                        f"tone {detail['tone_word']}",
                        f"concept {detail['concept']}",
                        f"wz {detail['wz']}",
                        f"radius_m {detail['radiusM']}",
                        f"rent_eur_m2 {best['rent_m2']}",
                        f"index {detail['locationIndex']['low']:.4f} {detail['locationIndex']['high']:.4f}",
                        f"plates {detail['plates']['low']:.2f} {detail['plates']['high']:.2f}",
                        f"plates_needed {detail['platesNeeded']:.2f}",
                        f"coverage {detail['coverage']['low']:.4f} {detail['coverage']['high']:.4f}",
                        f"workplace_label {detail.get('workplace_label')}",
                        f"defaulted_share {detail.get('defaulted_share')}",
                        RENT_SOURCE,
                        f"assumed_m2 {ASSUMED_M2}",
                        f"plate_eur {PLATE}",
                    ]
                )
                + "\n"
            )
        print("SAMPLE", path)
    else:
        print("SAMPLE not published")
    if not coloured_ok:
        print("BACKTEST FAIL")
        return 1
    print("BACKTEST PASS")
    return 0

if __name__ == "__main__":
    sys.exit(main())
PACH_BACKTEST
cat > $ROOT/app/Dockerfile << 'PACH_DOCKERFILE'
FROM python:3.12-slim
WORKDIR /app
COPY app.py /app/app.py
EXPOSE 8090
CMD ["python", "-u", "/app/app.py"]
PACH_DOCKERFILE
cat > $ROOT/app/app.py << 'PACH_APP'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATUS = "/status/status.txt"
SAMPLE = "/status/sample-report.txt"

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/sample":
            path = STATUS
        else:
            path = SAMPLE
        try:
            body = open(path, "rb").read()
            code = 200
        except FileNotFoundError:
            body = b"not published\n"
            code = 404 if self.path == "/sample" else 200
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return

if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8090), Handler).serve_forever()
PACH_APP

chmod 644 "$ROOT/docker-compose.yml" "$ROOT/Caddyfile" "$ROOT/init.sql" "$ROOT/refresh.sql" "$ROOT/model.py" "$ROOT/selftest.py" "$ROOT/backtest.py" "$ROOT/app/Dockerfile" "$ROOT/app/app.py"
if grep -E '0\.0\.0\.0:8080|- ["'\'']*8080:' "$ROOT/docker-compose.yml"; then
  echo "refusing host port 8080"
  exit 1
fi
pacht() {
  if [[ "${1:-}" == "down" || " $* " == *" -v "* ]]; then
    echo "refusing compose down or volume wipe"
    exit 1
  fi
  docker compose -p pachtgrenze -f "$ROOT/docker-compose.yml" "$@"
}
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | bash
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose missing"
  exit 1
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq osm2pgsql wget unzip python3 ca-certificates
docker stop pachtgrenze-nominatim >/dev/null 2>&1 || true
docker rm pachtgrenze-nominatim >/dev/null 2>&1 || true
echo "NOMINATIM not used"
pacht up -d db
ready=0
for _ in $(seq 1 60); do
  if docker exec pachtgrenze-db pg_isready -U pacht >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if [[ "$ready" -ne 1 ]]; then
  echo "database did not start"
  exit 1
fi
docker exec -i -e PGPASSWORD=pacht pachtgrenze-db psql -U pacht -d pacht -v ON_ERROR_STOP=1 < "$ROOT/init.sql"
PBF="$STATE/hessen-latest.osm.pbf"
if [[ -f "$STATE/osm.sha" && -f "$PBF" ]] && sha256sum -c "$STATE/osm.sha" >/dev/null; then
  echo "OSM import already matches this PBF"
else
  wget -c -O "$PBF" https://download.geofabrik.de/europe/germany/hessen-latest.osm.pbf
  sha256sum "$PBF" > "$STATE/osm.sha.new"
  if [[ -f "$STATE/osm.sha" ]] && cmp -s "$STATE/osm.sha" "$STATE/osm.sha.new"; then
    echo "OSM import already matches this PBF"
    rm -f "$STATE/osm.sha.new"
  else
    mem_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    cache=400
    procs=1
    if [[ "${mem_mb:-0}" -ge 8000 ]]; then
      cache=1500
      procs=2
    fi
    echo "OSM2PGSQL cache ${cache}MB processes ${procs} mem_available ${mem_mb:-0}MB"
    PGPASSWORD=pacht osm2pgsql --create --slim --hstore --latlong --output=pgsql \
      --number-processes "$procs" --cache "$cache" \
      -d pacht -U pacht -H 127.0.0.1 -P 5433 \
      "$PBF"
    mv "$STATE/osm.sha.new" "$STATE/osm.sha"
  fi
fi
found=$(docker exec -e PGPASSWORD=pacht pachtgrenze-db psql -U pacht -d pacht -tA -c "SELECT COUNT(*) FROM planet_osm_polygon WHERE boundary = 'administrative' AND admin_level = '6' AND name = 'Frankfurt am Main'")
if [[ "${found// /}" == "0" ]]; then
  echo "Frankfurt boundary missing"
  exit 1
fi
docker exec -i -e PGPASSWORD=pacht pachtgrenze-db psql -U pacht -d pacht -v ON_ERROR_STOP=1 < "$ROOT/refresh.sql"
ZIP="$STATE/Zensus2022_Bevoelkerungszahl.zip"
wget -c -O "$ZIP" https://www.destatis.de/static/DE/zensus/gitterdaten/Zensus2022_Bevoelkerungszahl.zip
sha256sum "$ZIP" > "$STATE/zensus.sha.new"
if [[ -f "$STATE/zensus.sha" ]] && cmp -s "$STATE/zensus.sha" "$STATE/zensus.sha.new"; then
  echo "Zensus import already matches this ZIP"
else
  docker exec -e PGPASSWORD=pacht pachtgrenze-db psql -U pacht -d pacht -v ON_ERROR_STOP=1 -c "TRUNCATE zensus_raw"
  unzip -p "$ZIP" Zensus2022_Bevoelkerungszahl_100m-Gitter.csv | docker exec -i -e PGPASSWORD=pacht pachtgrenze-db \
    psql -U pacht -d pacht -v ON_ERROR_STOP=1 -c "\\copy zensus_raw (gitter, x, y, einwohner) FROM STDIN WITH (FORMAT csv, HEADER true, DELIMITER ';')"
  docker exec -e PGPASSWORD=pacht pachtgrenze-db psql -U pacht -d pacht -v ON_ERROR_STOP=1 -c "
TRUNCATE zensus;
INSERT INTO zensus (residents, geom)
SELECT r.einwohner,
       ST_Transform(ST_MakeEnvelope(r.x - 50, r.y - 50, r.x + 50, r.y + 50, 3035), 4326)
FROM zensus_raw r
JOIN (
  SELECT way FROM planet_osm_polygon
  WHERE boundary = 'administrative' AND admin_level = '6' AND name = 'Frankfurt am Main'
  ORDER BY ST_Area(way::geography) DESC
  LIMIT 1
) city ON ST_Intersects(
  ST_Transform(ST_SetSRID(ST_MakePoint(r.x, r.y), 3035), 4326),
  city.way
);"
  rows=$(docker exec -e PGPASSWORD=pacht pachtgrenze-db psql -U pacht -d pacht -tA -c "SELECT COUNT(*) FROM zensus")
  if [[ "${rows// /}" == "0" ]]; then
    echo "Zensus clip is empty"
    exit 1
  fi
  mv "$STATE/zensus.sha.new" "$STATE/zensus.sha"
fi
cd "$ROOT"
set +e
python3 "$ROOT/selftest.py"
self_code=$?
python3 "$ROOT/backtest.py"
back_code=$?
set -e
echo "pachtgrenze $(date -Is)" > "$STATE/status.txt"
pacht up -d --build app caddy
if [[ "$self_code" -ne 0 || "$back_code" -ne 0 ]]; then
  exit 1
fi
exit 0
