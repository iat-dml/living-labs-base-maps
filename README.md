# Living Labs base maps

Print-ready A3 workshop maps for the five Living Lab regions in Germany covered by
[LL-Explorer](https://github.com/iat-dml/living-lab-explorer). There is one map per
Living Lab, in German or English.

![Example sheet: Rheingau, A3 landscape](docs/example-rheingau.png)

Each sheet shows:

- **An OpenStreetMap basemap drawn from vector data.** It includes land use, water, railways
  and roads, so it stays sharp at A3.
- **The Living Lab boundary.** The map is shown in full strength inside the boundary and fades
  out in a veiled ring around it.
- **A small set of labels chosen by map scale.** These are cities and towns, larger villages,
  motorway and federal road numbers, major rivers, large lakes and the highest peaks. Labels
  that would crowd each other are left out, so there is room to write on the map.
- **A header, scale bar, scale statement, north arrow and attribution.**

Each map is printed landscape or portrait, whichever shows the region at the larger scale.

## Requirements

- **R 4.5 or later.** Package versions are pinned with [renv](https://rstudio.github.io/renv/).
- **The [PMTiles CLI](https://github.com/protomaps/go-pmtiles/releases).** Put it on `PATH`, or
  set `PMTILES_BIN` to the executable.
- **Network access** the first time you draw each Living Lab.
- **Optional: the [Satoshi](https://www.fontshare.com/fonts/satoshi) font.** Without it, the
  maps use the system sans-serif font.

## Setup

```sh
git clone https://github.com/iat-dml/living-labs-base-maps.git
cd living-labs-base-maps
Rscript -e "renv::restore()"
```

Run R from the repository root, so that `.Rprofile` activates renv.

## Usage

```sh
Rscript workshop_maps.R                                    # all Living Labs, German sheets
Rscript workshop_maps.R --slug=rheingau,havelland --lang=en
Rscript workshop_maps.R --out=C:/tmp/workshop-a3 --refresh-osm --preview
```

| Option | Default | Meaning |
|---|---|---|
| `--slug=a,b` | all | Living Labs to draw: `east-brandenburg`, `havelland`, `north-hessian-loess`, `hessian-low-mountain`, `rheingau` |
| `--lang=de\|en` | `de` | Language of the sheet text |
| `--out=DIR` | `workshop_maps_a3/` | Output folder |
| `--refresh-osm` | off | Download a fresh OSM extract instead of using the cached one |
| `--preview` | off | Also write a 100 dpi PNG of each sheet to `<out>/preview/` |

A full run of all five Living Labs takes about three minutes when the OSM extracts are
already cached.

## How it works

1. **Extent.** The script reads the boundary from `data/ll_boundaries.geojson`, pads it by
   5.2 km, and chooses the A3 orientation that shows it at the larger scale.
2. **Basemap data.** For each Living Lab, `pmtiles extract` downloads a regional extract from
   the latest daily [Protomaps](https://protomaps.com) OpenStreetMap planet build. The extract
   is saved under `cache/osm/<slug>.pmtiles` and reused on later runs.
3. **Drawing.** It reads the layers at a zoom level matched to the print scale and draws them
   with `ggplot2`/`sf`. Outside a smoothed ring around the boundary, the map is left blank.
4. **Labels.** Candidate labels are placed in priority order. Any label whose box would come
   too close to one already placed is dropped.
5. **Output.** Each sheet is written as a vector PDF with `cairo_pdf`.

## Output

The output folder is meant to be zipped and sent to whoever does the printing:

```
workshop_maps_a3/
├── print/                   A3 PDFs: <num>_<slug>_A3-<orientation>_<lang>.pdf
├── data/<slug>/
│   ├── boundary.geojson     Living Lab boundary (EPSG:4326)
│   ├── osm_extract.pmtiles  the OSM vector tiles the basemap was drawn from (opens in QGIS)
│   ├── labels_<lang>.geojson  the labels placed on the sheet
│   └── sheet_<lang>.json    orientation, scale, basemap zoom, data source
└── README.txt               printing instructions and a list of sheets
```

**Print at 100 % ("actual size") on A3.** The printed scale and scale bar are only correct at
that size.

## Repository layout

| Path | Contents |
|---|---|
| `workshop_maps.R` | The whole tool: one script, no other R files needed |
| `data/ll_boundaries.geojson` | Living Lab boundaries (one feature per `ll_slug`) |
| `data/living_labs.json` | Number, name and region (de/en) and brand colours for each Living Lab |
| `renv.lock`, `renv/`, `.Rprofile` | Pinned R environment |
| `docs/` | Images for this README |
| `cache/`, `workshop_maps_a3/` | Downloaded extracts and generated output (both gitignored) |

The files in `data/` are copies from
[LL-Explorer](https://github.com/iat-dml/living-lab-explorer) (`data/ll_boundaries.geojson` and
`app/public/data/ll_metadata.json`). If the boundaries change there, copy them over by hand.

## Attribution

- Map data © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright), available
  under the ODbL.
- Vector tiles: [Protomaps](https://protomaps.com).
- Living Lab boundaries: LL-Explorer, Leibniz Centre for Agricultural Landscape Research
  (ZALF).

This attribution is printed on every sheet. Keep it on any reproduction.
