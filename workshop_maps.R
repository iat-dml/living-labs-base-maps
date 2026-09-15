# workshop_maps.R
#
# A3 print sheets for Living Lab workshops: one map per Living Lab, drawn to a padded extent
# around its boundary, with a smoothed halo around the boundary, a veil over the ring between
# boundary and halo edge, and the boundary outline on top. (The extent, halo and veil match the
# cover-page locator of the LL-Explorer PDF reports.)
#
#  * Basemap. An OpenStreetMap basemap drawn here from vector data -- landuse, water, railways
#    and the road network down to a scale-dependent class -- so it prints crisply at A3 instead
#    of as enlarged screen tiles. The data is a regional extract of the daily Protomaps OSM
#    planet build (`pmtiles extract`), cached under cache/osm/.
#    Raster tiles were ruled out: OSM's own tiles bake every label into the image, so a sheet
#    built from them cannot choose which places are named, and CARTO's label-free tiles are
#    now watermarked without an API key.
#  * Labels. A deliberately sparse, scale-aware selection from the same extract: cities and
#    towns, villages only on larger-scale sheets and only above a known population, motorway
#    and federal-road numbers, major rivers, large lakes and the few highest peaks as
#    orientation landmarks. Candidates are placed in priority order and any label whose box
#    would touch an already-placed one is dropped, so the sheet stays legible.
#
# Each sheet picks landscape or portrait A3 by whichever orientation draws the Living Lab's
# padded extent at the larger scale (near-ties go to the orientation that wastes less paper).
#
# Inputs (next to this script):
#
#   data/ll_boundaries.geojson   Living Lab boundaries (EPSG:4326, one `ll_slug` per feature)
#   data/living_labs.json        per Living Lab: number, name and region (de/en), brand colours
#
# Output is a self-contained folder meant to be zipped and handed to whoever prints:
#
#   <out>/print/            the A3 PDFs (print at 100 % / actual size)
#   <out>/data/<slug>/      boundary, the OSM extract the sheet was drawn from, placed labels,
#                           sheet facts (orientation, scale)
#   <out>/README.txt        print instructions, per-sheet orientation and scale, attribution
#
# Usage (run from this directory so renv activates; needs the `pmtiles` CLI on PATH or
# PMTILES_BIN, and network access the first time each Living Lab is drawn):
#
#   Rscript workshop_maps.R                                  # all Living Labs, German sheets
#   Rscript workshop_maps.R --slug=rheingau,havelland --lang=en
#   Rscript workshop_maps.R --out=C:/tmp/workshop-a3 --refresh-osm --preview

# --- Own-file resolution -------------------------------------------------------------------
# Captured at source time: sys.frames() only exposes the in-progress source() call's ofile
# while that call is still on the stack. Never uses the working directory.
.wm_this_file <- function() {
  frame_files <- Filter(Negate(is.null), lapply(sys.frames(), function(fr) fr$ofile))
  if (length(frame_files) > 0) {
    return(frame_files[[length(frame_files)]])
  }
  cmd_args <- commandArgs(trailingOnly = FALSE)
  hit <- grep("--file=", cmd_args, fixed = TRUE)
  if (length(hit) > 0) {
    return(sub("--file=", "", cmd_args[hit[1]], fixed = TRUE))
  }
  NULL
}
.wm_source_file <- .wm_this_file()
if (is.null(.wm_source_file) || !nzchar(.wm_source_file)) {
  stop("workshop_maps.R: could not determine this file's own source location.")
}
.wm_dir <- dirname(normalizePath(.wm_source_file, winslash = "/", mustWork = TRUE))

# --- Constants -----------------------------------------------------------------------------

WM_BOUNDARIES_PATH <- file.path(.wm_dir, "data", "ll_boundaries.geojson")
WM_LABS_PATH <- file.path(.wm_dir, "data", "living_labs.json")
WM_CACHE_DIR <- file.path(.wm_dir, "cache", "osm")
WM_DEFAULT_OUT <- file.path(.wm_dir, "workshop_maps_a3")

WM_PROTOMAPS_BUILDS <- "https://build-metadata.protomaps.dev/builds.json"
WM_PROTOMAPS_BASE <- "https://build.protomaps.com/"
WM_EXTRACT_MAXZOOM <- 13 # peaks only appear in the Protomaps `pois` layer from zoom 13

WM_PAPER <- list(landscape = c(420, 297), portrait = c(297, 420)) # A3, mm (width, height)
WM_MARGIN_MM <- 10 # clear of most printers' non-printable edge
WM_HEADER_MM <- 22
WM_FOOTER_MM <- 22
WM_GAP_MM <- 4
# Orientations whose scales are within this fraction of each other count as a tie.
WM_ORIENTATION_TIE <- 0.04

WM_EARTH_R <- 6378137

# Extent and halo around the Living Lab (metres, EPSG:3857). The basemap is not shown as a
# full rectangle: it is trimmed to a smoothed "halo" -- the boundary buffered outwards and
# simplified -- and the ring between boundary and halo edge is veiled, so the map fades into
# the page. WM_HALO_M stays below WM_PAD_M so the halo never touches the drawn extent's edge.
WM_PAD_M <- 5200
WM_HALO_M <- 3800
# Large enough that the halo reads as one smooth blob rather than a fattened copy of the
# administrative outline.
WM_HALO_SIMPLIFY_M <- 1400
WM_RING_VEIL_ALPHA <- 0.55

# Page and label colours (LL-Explorer design tokens).
WM_THEME <- list(
  black = "#022322",
  white = "#ffffff",
  green = "#225e43",
  greenMid = "#359269"
)
# First choice for all text; falls back to "sans" when not installed.
WM_FONT <- "Satoshi"

# Basemap colours: a quiet print palette, so the Living Lab outline and labels carry the sheet.
WM_COLOURS <- list(
  land = "#fbfaf4",
  forest = "#d3e5c3",
  builtup = "#e6dfd8",
  water = "#88BFD9",
  water_line = "#4F89A3",
  rail = "#707070",
  road_casing = "#9c9c9c",
  road = "#ffffff",
  primary = "#f7dc8a",
  primary_casing = "#b39a4c",
  motorway = "#f0a868",
  motorway_casing = "#a4602a",
  motorway_shield = "#1f4e9c", # German motorway-sign blue
  federal_shield = "#f5d130" # German Bundesstrasse-sign yellow
)
WM_FOREST_KINDS <- c("forest", "wood")
WM_BUILTUP_KINDS <- c("residential", "commercial", "industrial", "retail")

# Road classes drawn, bottom to top, with casing and fill widths (ggplot linewidth).
# `min_zoom` hides a class on smaller-scale sheets.
WM_ROADS <- list(
  tertiary  = list(details = "tertiary", casing = 0.45, fill = 0.25, colour = "road", casing_colour = "road_casing", min_zoom = 12),
  secondary = list(details = "secondary", casing = 0.65, fill = 0.4, colour = "road", casing_colour = "road_casing", min_zoom = 10),
  primary   = list(details = c("primary", "trunk"), casing = 0.95, fill = 0.6, colour = "primary", casing_colour = "primary_casing", min_zoom = 0),
  motorway  = list(details = "motorway", casing = 1.35, fill = 0.9, colour = "motorway", casing_colour = "motorway_casing", min_zoom = 0)
)

WM_BOUNDARY_LW <- 1.6
WM_BOUNDARY_CASING_LW <- 3.2
WM_TEXT_HALO_MM <- 0.45

# Label classes, in placement priority order (`rank`). Sizes are ggplot text sizes in mm;
# `spacing` is the clear distance (mm) a label of that class needs from every label already
# placed -- wide for villages, so they thin out evenly instead of packing every gap.
WM_STYLE <- list(
  city       = list(rank = 1, size = 5.2, face = "bold",   marker = "dot",    marker_size = 2.6, spacing = 2),
  town_major = list(rank = 2, size = 3.9, face = "bold",   marker = "dot",    marker_size = 1.9, spacing = 2),
  town       = list(rank = 3, size = 3.3, face = "plain",  marker = "dot",    marker_size = 1.5, spacing = 3),
  motorway   = list(rank = 4, size = 2.5, face = "bold",   marker = "shield", marker_size = 0,   spacing = 2),
  river      = list(rank = 5, size = 3.4, face = "italic", marker = "none",   marker_size = 0,   spacing = 2),
  lake       = list(rank = 6, size = 3.0, face = "italic", marker = "none",   marker_size = 0,   spacing = 2),
  federal    = list(rank = 7, size = 2.2, face = "bold",   marker = "shield", marker_size = 0,   spacing = 12),
  peak       = list(rank = 8, size = 2.7, face = "plain",  marker = "peak",   marker_size = 2.0, spacing = 6),
  village    = list(rank = 9, size = 2.7, face = "plain",  marker = "dot",    marker_size = 1.1, spacing = 18)
)
WM_TOWN_MAJOR_POP <- 10000
# Protomaps fills a missing population with a per-class default; those values say nothing.
WM_DEFAULT_POP <- c(town = 10000, village = 2000)
# Villages compete for space only on larger-scale sheets (most carry no population in OSM, so
# a population threshold alone would drop nearly all of them); on smaller-scale sheets only
# villages known to be large are eligible.
WM_VILLAGES_ALL_MAX_DENOM <- 350000
WM_VILLAGE_MIN_POP_SMALL_SCALE <- 3000
WM_RIVER_MIN_MM <- 80 # on-paper length inside the halo before a river is named
WM_MOTORWAY_MIN_MM <- 60
WM_FEDERAL_MIN_MM <- 90
WM_LAKE_MIN_MM <- 10 # on-paper size (square root of area)
WM_PEAK_MAX <- 5

WM_STRINGS <- list(
  de = list(
    subtitle = "Living Lab {num} \u00b7 {region}",
    sheet = "Arbeitskarte Workshop",
    scale = "Ma\u00dfstab ca. 1:{denom} \u2013 gilt nur bei Druck auf A3 in Originalgr\u00f6\u00dfe (100 %)",
    boundary = "Living-Lab-Grenze",
    credit1 = "Kartendaten: \u00a9 OpenStreetMap-Mitwirkende (ODbL) \u00b7 Aufbereitung: Protomaps",
    credit2 = "Living-Lab-Grenze: LL-Explorer (ZALF)"
  ),
  en = list(
    subtitle = "Living Lab {num} \u00b7 {region}",
    sheet = "Workshop map",
    scale = "Scale approx. 1:{denom} \u2013 valid only when printed on A3 at actual size (100 %)",
    boundary = "Living Lab boundary",
    credit1 = "Map data: \u00a9 OpenStreetMap contributors (ODbL) \u00b7 Processing: Protomaps",
    credit2 = "Living Lab boundary: LL-Explorer (ZALF)"
  )
)

.wm_fill <- function(template, vars) {
  for (name in names(vars)) {
    template <- gsub(paste0("{", name, "}"), as.character(vars[[name]]), template, fixed = TRUE)
  }
  template
}

# --- Living Lab inputs ---------------------------------------------------------------------

.wm_cache <- new.env(parent = emptyenv())

#' data/living_labs.json, keyed by slug.
wm_labs <- function() {
  if (is.null(.wm_cache$labs)) {
    .wm_cache$labs <- jsonlite::fromJSON(WM_LABS_PATH, simplifyVector = TRUE)
  }
  .wm_cache$labs
}

wm_lab <- function(slug) {
  labs <- wm_labs()
  if (!slug %in% names(labs)) {
    stop("wm_lab(): unknown Living Lab slug '", slug, "'. Known slugs: ",
      paste(names(labs), collapse = ", "), call. = FALSE)
  }
  labs[[slug]]
}

#' One Living Lab's boundary feature(s) from data/ll_boundaries.geojson.
wm_boundary <- function(slug) {
  boundaries <- sf::st_read(WM_BOUNDARIES_PATH, quiet = TRUE)
  result <- boundaries[boundaries$ll_slug == slug, ]
  if (nrow(result) == 0) {
    stop("wm_boundary(): no features with ll_slug == '", slug, "' in ", WM_BOUNDARIES_PATH, call. = FALSE)
  }
  result
}

#' Group thousands and pick the decimal mark by language ("de": 1.234,5; "en": 1,234.5);
#' at most 3 fraction digits, trailing zeros trimmed.
wm_format_number <- function(x, lang) {
  big_mark <- if (identical(lang, "de")) "." else ","
  decimal_mark <- if (identical(lang, "de")) "," else "."
  parts <- strsplit(formatC(abs(round(x, 3)), format = "f", digits = 3), ".", fixed = TRUE)[[1]]
  int_part <- formatC(as.numeric(parts[1]), format = "d", big.mark = big_mark, decimal.mark = decimal_mark)
  frac_part <- sub("0+$", "", parts[2])
  paste0(if (x < 0) "-", int_part, if (nzchar(frac_part)) paste0(decimal_mark, frac_part))
}

#' WM_FONT when it is installed on this machine, else "sans".
wm_font_family <- function() {
  path <- tryCatch(suppressWarnings(systemfonts::match_fonts(WM_FONT)$path[[1]]), error = function(e) NULL)
  if (!is.null(path) && nzchar(path) && file.exists(path) &&
    grepl(WM_FONT, basename(path), ignore.case = TRUE)) {
    return(WM_FONT)
  }
  message("  font '", WM_FONT, "' not found, using 'sans'")
  "sans"
}

#' The Living Lab's boundary in EPSG:3857 and the padded extent the map is drawn around.
wm_extent <- function(slug) {
  boundary_3857 <- sf::st_transform(wm_boundary(slug), 3857)
  buffered <- sf::st_buffer(sf::st_union(boundary_3857), WM_PAD_M)
  list(boundary = boundary_3857, bbox = sf::st_bbox(buffered))
}

#' The basemap-clipping halo and the veiled ring between it and the boundary.
#'
#' `halo` is the dissolved boundary buffered by WM_HALO_M, simplified, then unioned back with
#' the boundary itself (simplification could otherwise expose a sliver of the Living Lab
#' outside its own halo). Holes are filled: a Living Lab can surround a city it excludes
#' (north-hessian-loess around Kassel), and on a workshop map that city is the landmark people
#' orient by, so it gets the veiled basemap like the rest of the surroundings.
#'
#' @return list(halo = sfc, ring = sfc), both EPSG:3857.
wm_halo <- function(core) {
  halo <- sf::st_buffer(core, WM_HALO_M)
  halo <- sf::st_simplify(halo, dTolerance = WM_HALO_SIMPLIFY_M, preserveTopology = TRUE)
  halo <- sf::st_make_valid(sf::st_union(halo, core))
  if (length(halo) == 0 || all(sf::st_is_empty(halo))) {
    stop("wm_halo(): buffering and simplifying the boundary produced an empty halo.", call. = FALSE)
  }
  halo <- .wm_fill_holes(halo)
  list(halo = halo, ring = sf::st_make_valid(sf::st_difference(halo, core)))
}

#' The polygon(s) with every interior ring dropped.
.wm_fill_holes <- function(geom) {
  polygons <- sf::st_cast(suppressWarnings(sf::st_collection_extract(geom, "POLYGON")), "POLYGON")
  outers <- lapply(polygons, function(p) sf::st_polygon(p[1]))
  sf::st_union(sf::st_sfc(outers, crs = sf::st_crs(geom)))
}

# --- Page geometry -------------------------------------------------------------------------

#' Pick the A3 orientation that draws `bbox` (EPSG:3857) at the larger scale, and widen the
#' drawn extent so it fills that orientation's map frame exactly.
#'
#' @return list with orientation, page and map-frame dimensions (mm), `s` (paper mm per
#'   EPSG:3857 unit), the drawn `xlim`/`ylim`, the ground scale at the extent's centre, and
#'   the vector-tile zoom the basemap is read at.
wm_sheet_layout <- function(bbox) {
  bw <- as.numeric(bbox[["xmax"]] - bbox[["xmin"]])
  bh <- as.numeric(bbox[["ymax"]] - bbox[["ymin"]])
  options <- lapply(names(WM_PAPER), function(orientation) {
    page <- WM_PAPER[[orientation]]
    map_w <- page[1] - 2 * WM_MARGIN_MM
    map_h <- page[2] - 2 * WM_MARGIN_MM - WM_HEADER_MM - WM_FOOTER_MM - 2 * WM_GAP_MM
    list(
      orientation = orientation, page_w = page[1], page_h = page[2],
      map_w = map_w, map_h = map_h, s = min(map_w / bw, map_h / bh),
      aspect_miss = abs(log((map_w / map_h) / (bw / bh)))
    )
  })
  scales <- vapply(options, function(o) o$s, numeric(1))
  if (min(scales) / max(scales) >= 1 - WM_ORIENTATION_TIE) {
    layout <- options[[which.min(vapply(options, function(o) o$aspect_miss, numeric(1)))]]
  } else {
    layout <- options[[which.max(scales)]]
  }

  cx <- as.numeric(bbox[["xmin"]] + bbox[["xmax"]]) / 2
  cy <- as.numeric(bbox[["ymin"]] + bbox[["ymax"]]) / 2
  layout$xlim <- cx + c(-1, 1) * layout$map_w / layout$s / 2
  layout$ylim <- cy + c(-1, 1) * layout$map_h / layout$s / 2
  layout$map_x <- WM_MARGIN_MM
  layout$map_y <- WM_MARGIN_MM + WM_FOOTER_MM + WM_GAP_MM

  # Web Mercator stretches distances by 1/cos(latitude); the printed scale is the ground
  # scale at the sheet's centre (it drifts by about 1 % across the tallest Living Lab).
  lat <- atan(sinh(cy / WM_EARTH_R))
  layout$ground_m_per_mm <- cos(lat) / layout$s
  layout$scale_denominator <- round(layout$ground_m_per_mm) * 1000

  # The zoom a screen map at this scale would use (0.28 mm pixels), plus one: paper is read
  # closer and sharper than a screen, so it can carry one level more detail.
  screen_zoom <- log2(2 * pi * WM_EARTH_R * cos(lat) / 256 / (layout$scale_denominator * 0.00028))
  layout$zoom <- as.integer(min(max(round(screen_zoom) + 1, 8), WM_EXTRACT_MAXZOOM - 1))
  layout
}

# --- OpenStreetMap data (Protomaps extract) ------------------------------------------------

.wm_pmtiles_bin <- function() {
  bin <- Sys.getenv("PMTILES_BIN", unset = "")
  if (!nzchar(bin)) bin <- Sys.which("pmtiles")
  if (!nzchar(bin)) {
    stop(
      "workshop_maps.R: could not find the PMTiles CLI. Install it from ",
      "https://github.com/protomaps/go-pmtiles/releases or set PMTILES_BIN.",
      call. = FALSE
    )
  }
  unname(bin)
}

#' The regional OSM extract for one Living Lab, fetched once and cached.
#'
#' @param bbox_ll the extent to cover, EPSG:4326 bbox.
#' @return list(path=, build=) -- the cached .pmtiles file and the planet build it came from.
wm_osm_extract <- function(slug, bbox_ll, refresh = FALSE) {
  dir.create(WM_CACHE_DIR, recursive = TRUE, showWarnings = FALSE)
  path <- file.path(WM_CACHE_DIR, paste0(slug, ".pmtiles"))
  build_note <- paste0(path, ".build")
  if (!refresh && file.exists(path) && file.exists(build_note)) {
    return(list(path = path, build = readLines(build_note, warn = FALSE)[1]))
  }

  builds <- tryCatch(jsonlite::fromJSON(WM_PROTOMAPS_BUILDS), error = function(e) {
    stop("wm_osm_extract(): could not list Protomaps builds (", WM_PROTOMAPS_BUILDS, "): ",
      conditionMessage(e), call. = FALSE)
  })
  build <- utils::tail(sort(builds$key[grepl("^[0-9]{8}\\.pmtiles$", builds$key)]), 1)
  if (length(build) == 0) {
    stop("wm_osm_extract(): no Protomaps planet build listed at ", WM_PROTOMAPS_BUILDS, call. = FALSE)
  }

  tmp <- paste0(path, ".part")
  unlink(tmp)
  bbox_arg <- sprintf(
    "--bbox=%.5f,%.5f,%.5f,%.5f",
    bbox_ll[["xmin"]], bbox_ll[["ymin"]], bbox_ll[["xmax"]], bbox_ll[["ymax"]]
  )
  message("  fetching OSM extract for ", slug, " from Protomaps build ", build, " ...")
  log <- suppressWarnings(system2(
    .wm_pmtiles_bin(),
    c("extract", paste0(WM_PROTOMAPS_BASE, build), shQuote(tmp), bbox_arg, paste0("--maxzoom=", WM_EXTRACT_MAXZOOM)),
    stdout = TRUE, stderr = TRUE
  ))
  status <- attr(log, "status")
  if ((!is.null(status) && status != 0) || !file.exists(tmp) || file.size(tmp) == 0) {
    stop(
      "wm_osm_extract(): `pmtiles extract` failed for slug '", slug, "':\n",
      paste(utils::tail(log, 5), collapse = "\n"),
      call. = FALSE
    )
  }
  file.rename(tmp, path)
  writeLines(build, build_note)
  list(path = path, build = build)
}

#' One Protomaps layer at one zoom, restricted to the sheet's extent.
.wm_read_layer <- function(path, layer, zoom, extent_wkt) {
  x <- suppressWarnings(sf::st_read(
    path, layer = layer, options = paste0("ZOOM_LEVEL=", zoom),
    wkt_filter = extent_wkt, quiet = TRUE
  ))
  if (nrow(x) > 0) sf::st_crs(x) <- 3857
  x
}

.wm_col <- function(x, name, default = NA) {
  if (name %in% names(x)) x[[name]] else rep(default, nrow(x))
}

.wm_is_polygon <- function(x) sf::st_geometry_type(x) %in% c("POLYGON", "MULTIPOLYGON")
.wm_is_line <- function(x) sf::st_geometry_type(x) %in% c("LINESTRING", "MULTILINESTRING")

#' The basemap layers for one sheet, as drawn.
wm_basemap_layers <- function(extract_path, layout) {
  extent <- sf::st_as_sfc(sf::st_bbox(
    c(xmin = layout$xlim[1], ymin = layout$ylim[1], xmax = layout$xlim[2], ymax = layout$ylim[2]),
    crs = sf::st_crs(3857)
  ))
  wkt <- sf::st_as_text(extent)
  z <- layout$zoom

  landuse <- .wm_read_layer(extract_path, "landuse", z, wkt)
  water <- .wm_read_layer(extract_path, "water", z, wkt)
  roads <- .wm_read_layer(extract_path, "roads", z, wkt)
  if (nrow(landuse) == 0 || nrow(roads) == 0) {
    stop("wm_basemap_layers(): the OSM extract '", extract_path, "' has no landuse or roads at zoom ", z,
      " for this extent -- is the cached extract for a different area? Re-run with --refresh-osm.", call. = FALSE)
  }

  not_tunnel <- !(.wm_col(roads, "is_tunnel", FALSE) %in% TRUE)
  not_link <- !(.wm_col(roads, "is_link", FALSE) %in% TRUE)
  road_layers <- lapply(WM_ROADS, function(cls) {
    if (z < cls$min_zoom) return(NULL)
    keep <- .wm_is_line(roads) & roads$kind_detail %in% cls$details & not_link
    roads[keep, ]
  })

  list(
    extent = extent,
    forest = landuse[.wm_is_polygon(landuse) & landuse$kind %in% WM_FOREST_KINDS, "kind"],
    builtup = landuse[.wm_is_polygon(landuse) & landuse$kind %in% WM_BUILTUP_KINDS, "kind"],
    water_area = water[.wm_is_polygon(water) & water$kind %in% c("water", "lake", "river", "basin", "canal"), ],
    water_line = water[.wm_is_line(water) & water$kind %in% c("river", "canal", if (z >= 12) "stream") &
      !(.wm_col(water, "tunnel", FALSE) %in% TRUE), ],
    rail = roads[.wm_is_line(roads) & roads$kind %in% "rail" & roads$kind_detail %in% "rail" & not_tunnel, ],
    roads = road_layers,
    roads_all = roads,
    # Places from zoom 12 whatever the sheet's zoom: Protomaps drops most villages below it,
    # and label spacing (not the tile zoom) decides how many are shown.
    places = .wm_read_layer(extract_path, "places", max(z, 12), wkt),
    pois = .wm_read_layer(extract_path, "pois", WM_EXTRACT_MAXZOOM, wkt)
  )
}

# --- Labels --------------------------------------------------------------------------------

.wm_candidates <- function(label, kind, x, y, weight) {
  if (length(label) == 0) {
    return(NULL)
  }
  data.frame(label = label, kind = kind, x = x, y = y, weight = weight, stringsAsFactors = FALSE)
}

#' Anchor points for each named line inside `area`: the middle of its longest stretch, plus
#' the middle of its second-longest when the whole line is long on paper. Qualification uses
#' the total printed length, because vector tiles cut lines at tile edges and the cut pieces
#' do not reliably merge back into one.
.wm_line_anchors <- function(lines_sfc, names, area, s, min_mm, kind) {
  keep <- !is.na(names) & nzchar(names)
  lines_sfc <- lines_sfc[keep]
  names <- names[keep]
  out <- list()
  for (name in unique(names)) {
    clipped <- suppressWarnings(sf::st_intersection(sf::st_union(lines_sfc[names == name]), area))
    if (length(clipped) == 0 || all(sf::st_is_empty(clipped))) next
    if (!all(sf::st_geometry_type(clipped) %in% c("LINESTRING", "MULTILINESTRING"))) {
      clipped <- sf::st_collection_extract(clipped, "LINESTRING")
    }
    if (length(clipped) == 0) next
    merged <- sf::st_cast(sf::st_union(clipped), "MULTILINESTRING")
    parts <- sf::st_cast(sf::st_line_merge(merged), "LINESTRING")
    lengths_mm <- as.numeric(sf::st_length(parts)) * s
    total_mm <- sum(lengths_mm)
    if (total_mm < min_mm) next
    picks <- utils::head(order(-lengths_mm), if (total_mm >= 250) 2 else 1)
    picks <- picks[lengths_mm[picks] >= min(30, min_mm)]
    if (length(picks) == 0) next
    pts <- sf::st_coordinates(sf::st_cast(sf::st_line_sample(parts[picks], sample = 0.5), "POINT"))
    out[[length(out) + 1]] <- .wm_candidates(
      rep(name, nrow(pts)), kind, pts[, "X"], pts[, "Y"], rep(total_mm, nrow(pts))
    )
  }
  do.call(rbind, out)
}

.wm_road_numbers <- function(roads) {
  shield <- .wm_col(roads, "shield_text", NA_character_)
  ref <- .wm_col(roads, "ref", NA_character_)
  from_ref <- gsub(" ", "", trimws(sub(";.*$", "", ref)))
  ifelse(!is.na(shield) & nzchar(shield), shield, from_ref)
}

#' Every label candidate for one sheet, in EPSG:3857, before decluttering.
wm_label_candidates <- function(layers, core, halo, layout) {
  s <- layout$s
  cands <- list()

  # Settlements.
  places <- layers$places
  places <- places[places$kind_detail %in% c("city", "town", "village") & !is.na(places$name), ]
  if (nrow(places) > 0) {
    detail <- places$kind_detail
    pop <- suppressWarnings(as.numeric(.wm_col(places, "population", NA)))
    is_default <- (detail == "town" & pop %in% WM_DEFAULT_POP[["town"]]) |
      (detail == "village" & pop %in% WM_DEFAULT_POP[["village"]])
    pop[is.na(pop) | is_default] <- 0
    kind <- ifelse(detail == "town" & pop >= WM_TOWN_MAJOR_POP, "town_major", detail)
    keep <- detail != "village" | layout$scale_denominator <= WM_VILLAGES_ALL_MAX_DENOM |
      pop >= WM_VILLAGE_MIN_POP_SMALL_SCALE
    xy <- sf::st_coordinates(places)
    cands$places <- .wm_candidates(places$name[keep], kind[keep], xy[keep, 1], xy[keep, 2], pop[keep])
  }

  # Lakes: the largest named water body per name.
  waters <- layers$water_area
  waters <- waters[!is.na(waters$name) & waters$kind %in% c("lake", "water"), ]
  if (nrow(waters) > 0) {
    waters$size_mm <- sqrt(as.numeric(sf::st_area(waters))) * s
    waters <- waters[waters$size_mm >= WM_LAKE_MIN_MM, ]
    waters <- waters[order(-waters$size_mm), ]
    waters <- waters[!duplicated(waters$name), ]
    if (nrow(waters) > 0) {
      xy <- sf::st_coordinates(suppressWarnings(sf::st_point_on_surface(sf::st_geometry(waters))))
      cands$lakes <- .wm_candidates(waters$name, "lake", xy[, 1], xy[, 2], waters$size_mm)
    }
  }

  # Rivers, motorways and federal roads, anchored on their longest stretches within the halo
  # (a river is often the boundary itself -- the Rhine along the Rheingau -- so clipping to the
  # Living Lab alone would leave the most recognisable one unnamed).
  rivers <- layers$water_line[layers$water_line$kind %in% "river", ]
  if (nrow(rivers) > 0) {
    cands$rivers <- .wm_line_anchors(sf::st_geometry(rivers), rivers$name, halo, s, WM_RIVER_MIN_MM, "river")
  }
  roads <- layers$roads_all
  roads <- roads[.wm_is_line(roads) & !(.wm_col(roads, "is_link", FALSE) %in% TRUE), ]
  numbers <- .wm_road_numbers(roads)
  motorway <- roads$kind_detail %in% "motorway" & grepl("^A[0-9]", numbers)
  if (any(motorway)) {
    cands$motorways <- .wm_line_anchors(
      sf::st_geometry(roads)[motorway], numbers[motorway], halo, s, WM_MOTORWAY_MIN_MM, "motorway"
    )
  }
  federal <- roads$kind_detail %in% c("trunk", "primary") & grepl("^B[0-9]", numbers)
  if (any(federal)) {
    cands$federal <- .wm_line_anchors(
      sf::st_geometry(roads)[federal], numbers[federal], halo, s, WM_FEDERAL_MIN_MM, "federal"
    )
  }

  # The highest few named peaks inside the Living Lab.
  peaks <- layers$pois
  peaks <- peaks[peaks$kind %in% "peak" & !is.na(peaks$name), ]
  if (nrow(peaks) > 0) {
    peaks$ele <- suppressWarnings(as.numeric(.wm_col(peaks, "elevation", NA)))
    peaks <- peaks[!is.na(peaks$ele) & lengths(sf::st_intersects(peaks, core)) > 0, ]
    peaks <- utils::head(peaks[order(-peaks$ele), ], WM_PEAK_MAX)
    if (nrow(peaks) > 0) {
      xy <- sf::st_coordinates(peaks)
      cands$peaks <- .wm_candidates(
        paste0(peaks$name, " ", round(peaks$ele), " m"), "peak", xy[, 1], xy[, 2], peaks$ele
      )
    }
  }

  all <- do.call(rbind, Filter(Negate(is.null), cands))
  if (is.null(all) || nrow(all) == 0) {
    stop("wm_label_candidates(): the OSM extract produced no label candidates at all.")
  }
  # Only features within the halo: outside it the basemap is masked, and a label would float
  # on blank paper.
  points <- sf::st_as_sf(all, coords = c("x", "y"), crs = 3857, remove = FALSE)
  in_halo <- lengths(sf::st_intersects(points, halo)) > 0
  # Within a class, features inside the Living Lab are placed before those in the surrounding
  # ring -- otherwise villages, which mostly tie on population, fill the edges first.
  all$inside <- lengths(sf::st_intersects(points, core)) > 0
  all[in_halo & nzchar(all$label), ]
}

#' Greedy label placement: highest-priority labels first, each kept only if its box (label
#' plus marker) fits inside the frame and stays its class's `spacing` clear of every box
#' already kept.
wm_declutter <- function(cands, layout) {
  style <- WM_STYLE[cands$kind]
  cands$rank <- vapply(style, function(st) st$rank, numeric(1))
  cands$size <- vapply(style, function(st) st$size, numeric(1))
  cands$face <- vapply(style, function(st) st$face, character(1))
  cands$marker <- vapply(style, function(st) st$marker, character(1))
  cands$marker_size <- vapply(style, function(st) st$marker_size, numeric(1))
  cands$spacing <- vapply(style, function(st) st$spacing, numeric(1))
  cands <- cands[order(cands$rank, !cands$inside, -cands$weight), ]

  char_w <- ifelse(cands$face == "bold", 0.62, 0.56)
  w <- nchar(cands$label) * cands$size * char_w
  h <- cands$size * 1.2
  shield <- cands$marker == "shield"
  w[shield] <- w[shield] + 2
  h[shield] <- h[shield] + 1.6
  has_marker <- cands$marker %in% c("dot", "peak")
  cands$dy_mm <- ifelse(has_marker, cands$marker_size / 2 + 0.7 + h / 2, 0)

  px <- (cands$x - layout$xlim[1]) * layout$s
  py <- (cands$y - layout$ylim[1]) * layout$s
  box <- cbind(
    pmin(px - w / 2, px - cands$marker_size / 2),
    pmin(py + cands$dy_mm - h / 2, py - cands$marker_size / 2),
    pmax(px + w / 2, px + cands$marker_size / 2),
    pmax(py + cands$dy_mm + h / 2, py + cands$marker_size / 2)
  )

  kept <- logical(nrow(cands))
  placed <- matrix(numeric(0), ncol = 4)
  for (i in seq_len(nrow(cands))) {
    b <- box[i, ]
    if (b[1] < 1 || b[2] < 1 || b[3] > layout$map_w - 1 || b[4] > layout$map_h - 1) next
    if (nrow(placed) > 0) {
      pad <- cands$spacing[i]
      overlap <- b[1] < placed[, 3] + pad & b[3] > placed[, 1] - pad &
        b[2] < placed[, 4] + pad & b[4] > placed[, 2] - pad
      if (any(overlap)) next
    }
    kept[i] <- TRUE
    placed <- rbind(placed, b)
  }
  out <- cands[kept, ]
  out$tx <- out$x
  out$ty <- out$y + out$dy_mm / layout$s
  out
}

# --- The map panel ---------------------------------------------------------------------------

wm_map_plot <- function(slug, layers, halo, boundary_3857, labels, layout, font_family) {
  tk <- WM_THEME
  lab <- wm_lab(slug)
  col <- WM_COLOURS

  labels$colour <- ifelse(labels$kind %in% c("river", "lake"), col$water_line, tk$black)
  text_df <- labels[labels$marker != "shield", ]
  shield_df <- labels[labels$marker == "shield", ]
  shield_df$fill <- ifelse(shield_df$kind == "motorway", col$motorway_shield, col$federal_shield)
  shield_df$colour <- ifelse(shield_df$kind == "motorway", tk$white, tk$black)
  shield_df$size <- ifelse(shield_df$kind == "motorway", WM_STYLE$motorway$size, WM_STYLE$federal$size)
  dots <- labels[labels$marker == "dot", ]
  peaks <- labels[labels$marker == "peak", ]

  radius <- WM_TEXT_HALO_MM / layout$s
  angles <- seq(0, 2 * pi, length.out = 17)[-17]
  halo_df <- do.call(rbind, lapply(angles, function(a) {
    shifted <- text_df
    shifted$tx <- shifted$tx + cos(a) * radius
    shifted$ty <- shifted$ty + sin(a) * radius
    shifted
  }))

  # Everything outside the halo is painted out, which clips the basemap to the halo without
  # clipping every basemap feature individually.
  outside_halo <- sf::st_difference(layers$extent, halo$halo)

  road_layers <- Filter(function(x) !is.null(x) && nrow(x) > 0, layers$roads)
  road_geoms <- unlist(lapply(names(road_layers), function(name) {
    cls <- WM_ROADS[[name]]
    list(
      ggplot2::geom_sf(data = road_layers[[name]], colour = col[[cls$casing_colour]],
        linewidth = cls$casing, lineend = "round"),
      ggplot2::geom_sf(data = road_layers[[name]], colour = col[[cls$colour]],
        linewidth = cls$fill, lineend = "round")
    )
  }), recursive = FALSE)

  ggplot2::ggplot() +
    ggplot2::geom_sf(data = sf::st_as_sf(halo$halo), fill = col$land, colour = NA) +
    # Polygons are stroked in their own fill colour: vector tiles are cut at tile edges, and
    # an unstroked fill would show those cuts as hairlines in the PDF.
    ggplot2::geom_sf(data = layers$builtup, fill = col$builtup, colour = col$builtup, linewidth = 0.1) +
    ggplot2::geom_sf(data = layers$forest, fill = col$forest, colour = col$forest, linewidth = 0.1) +
    ggplot2::geom_sf(data = layers$water_area, fill = col$water, colour = col$water, linewidth = 0.1) +
    ggplot2::geom_sf(
      data = layers$water_line, colour = col$water,
      ggplot2::aes(linewidth = ifelse(.data$kind == "river", 0.55, ifelse(.data$kind == "canal", 0.35, 0.18)))
    ) +
    ggplot2::geom_sf(data = layers$rail, colour = col$rail, linewidth = 0.3, linetype = "22") +
    road_geoms +
    ggplot2::geom_sf(data = sf::st_as_sf(outside_halo), fill = tk$white, colour = NA) +
    ggplot2::geom_sf(
      data = sf::st_as_sf(halo$ring), fill = tk$white,
      colour = NA, alpha = WM_RING_VEIL_ALPHA
    ) +
    # A white casing keeps the boundary distinct from roads drawn in similar hues.
    ggplot2::geom_sf(
      data = boundary_3857, fill = NA, colour = tk$white,
      linewidth = WM_BOUNDARY_CASING_LW, alpha = 0.8
    ) +
    ggplot2::geom_sf(data = boundary_3857, fill = NA, colour = lab$outlineColor, linewidth = WM_BOUNDARY_LW) +
    ggplot2::geom_point(
      data = dots, ggplot2::aes(x = .data$x, y = .data$y, size = .data$marker_size),
      shape = 21, fill = tk$black, colour = tk$white, stroke = 0.5
    ) +
    ggplot2::geom_point(
      data = peaks, ggplot2::aes(x = .data$x, y = .data$y, size = .data$marker_size),
      shape = 24, fill = tk$black, colour = tk$white, stroke = 0.4
    ) +
    ggplot2::geom_text(
      data = halo_df,
      ggplot2::aes(x = .data$tx, y = .data$ty, label = .data$label, size = .data$size, fontface = .data$face),
      colour = tk$white, family = font_family
    ) +
    ggplot2::geom_text(
      data = text_df,
      ggplot2::aes(
        x = .data$tx, y = .data$ty, label = .data$label, size = .data$size,
        fontface = .data$face, colour = .data$colour
      ),
      family = font_family
    ) +
    ggplot2::geom_label(
      data = shield_df,
      ggplot2::aes(
        x = .data$tx, y = .data$ty, label = .data$label, size = .data$size,
        fill = .data$fill, colour = .data$colour
      ),
      fontface = "bold", family = font_family, linewidth = 0.2,
      label.padding = grid::unit(0.6, "mm"), label.r = grid::unit(0.6, "mm")
    ) +
    ggplot2::scale_size_identity() +
    ggplot2::scale_linewidth_identity() +
    ggplot2::scale_colour_identity() +
    ggplot2::scale_fill_identity() +
    ggplot2::coord_sf(
      crs = 3857, default_crs = 3857, xlim = layout$xlim, ylim = layout$ylim,
      expand = FALSE, datum = NA
    ) +
    ggplot2::theme_void() +
    ggplot2::theme(
      legend.position = "none",
      plot.margin = ggplot2::margin(0, 0, 0, 0),
      plot.background = ggplot2::element_rect(fill = NA, colour = NA),
      panel.background = ggplot2::element_rect(fill = NA, colour = NA)
    )
}

# --- Page furniture ------------------------------------------------------------------------

.wm_nice_scale_km <- function(ground_m_per_mm, max_mm = 90) {
  steps <- c(0.5, 1, 2, 5, 10, 20, 25, 50)
  fits <- steps[steps * 1000 / ground_m_per_mm <= max_mm]
  if (length(fits) == 0) steps[1] else max(fits)
}

#' Draw one complete sheet on the current device.
wm_draw_sheet <- function(sheet) {
  L <- sheet$layout
  tk <- WM_THEME
  fam <- sheet$font_family
  strings <- WM_STRINGS[[sheet$lang]]
  mm <- function(v) grid::unit(v, "mm")
  gp <- function(...) grid::gpar(fontfamily = fam, ...)
  left <- L$map_x
  right <- L$map_x + L$map_w
  top <- L$page_h - WM_MARGIN_MM
  base <- WM_MARGIN_MM

  grid::grid.newpage()
  grid::grid.rect(gp = grid::gpar(fill = tk$white, col = NA))

  # Header: brand bar, Living Lab name, region, sheet label.
  grid::grid.rect(mm(left), mm(top), mm(3.2), mm(WM_HEADER_MM), just = c("left", "top"),
    gp = grid::gpar(fill = sheet$brand$color, col = NA))
  grid::grid.text(sheet$title, mm(left + 7), mm(top - 8), just = c("left", "center"),
    gp = gp(fontsize = 26, fontface = "bold", col = tk$green))
  grid::grid.text(sheet$subtitle, mm(left + 7), mm(top - 17.5), just = c("left", "center"),
    gp = gp(fontsize = 12, col = tk$black))
  grid::grid.text(strings$sheet, mm(right), mm(top - 8), just = c("right", "center"),
    gp = gp(fontsize = 12, col = tk$greenMid))

  # Map.
  map_vp <- grid::viewport(mm(left), mm(L$map_y), mm(L$map_w), mm(L$map_h), just = c("left", "bottom"))
  print(sheet$plot, vp = map_vp, newpage = FALSE)
  grid::grid.rect(mm(left), mm(L$map_y), mm(L$map_w), mm(L$map_h), just = c("left", "bottom"),
    gp = grid::gpar(fill = NA, col = tk$green, lwd = 0.8))

  # Footer, left: scale bar and the scale statement.
  km <- .wm_nice_scale_km(L$ground_m_per_mm)
  bar_mm <- km * 1000 / L$ground_m_per_mm
  bar_y <- base + 10
  for (k in 0:3) {
    grid::grid.rect(mm(left + k * bar_mm / 4), mm(bar_y), mm(bar_mm / 4), mm(2), just = c("left", "bottom"),
      gp = grid::gpar(fill = if (k %% 2 == 0) tk$black else tk$white, col = tk$black, lwd = 0.6))
  }
  km_label <- function(v) wm_format_number(v, sheet$lang)
  grid::grid.text(c("0", km_label(km / 2), paste(km_label(km), "km")),
    mm(left + c(0, bar_mm / 2, bar_mm)), mm(bar_y + 4.5), just = c("centre", "center"),
    gp = gp(fontsize = 8, col = tk$black))
  grid::grid.text(.wm_fill(strings$scale, list(denom = sheet$scale_label)),
    mm(left), mm(base + 4), just = c("left", "center"), gp = gp(fontsize = 8.5, col = tk$black))

  # Footer, right: north arrow, boundary key, attribution.
  arrow_x <- right - 4
  grid::grid.polygon(mm(arrow_x + c(-2.6, 0, 2.6, 0)), mm(base + c(9.5, 18.5, 9.5, 12)),
    gp = grid::gpar(fill = tk$black, col = NA))
  grid::grid.text("N", mm(arrow_x), mm(base + 7), gp = gp(fontsize = 8, fontface = "bold", col = tk$black))
  key <- grid::textGrob(strings$boundary, mm(right - 13), mm(base + 14), just = c("right", "center"),
    gp = gp(fontsize = 9, col = tk$black))
  grid::grid.draw(key)
  key_end <- mm(right - 15) - grid::grobWidth(key)
  grid::grid.segments(key_end - mm(12), mm(base + 14), key_end, mm(base + 14),
    gp = grid::gpar(col = sheet$brand$outlineColor, lwd = WM_BOUNDARY_LW * ggplot2::.pt, lineend = "butt"))
  grid::grid.text(
    c(strings$credit1, paste0(strings$credit2, " \u00b7 OSM ", sheet$osm_build_date)),
    mm(right - 13), mm(base + c(4.6, 1)), just = c("right", "center"),
    gp = gp(fontsize = 7, col = tk$black)
  )
}

# --- One Living Lab ------------------------------------------------------------------------

wm_build_sheet <- function(slug, lang, refresh_osm) {
  lab <- wm_lab(slug)

  extent <- wm_extent(slug)
  boundary_3857 <- extent$boundary
  core <- sf::st_make_valid(sf::st_union(boundary_3857))
  halo <- wm_halo(core)
  layout <- wm_sheet_layout(extent$bbox)

  drawn <- sf::st_as_sfc(sf::st_bbox(
    c(xmin = layout$xlim[1], ymin = layout$ylim[1], xmax = layout$xlim[2], ymax = layout$ylim[2]),
    crs = sf::st_crs(3857)
  ))
  osm <- wm_osm_extract(slug, sf::st_bbox(sf::st_transform(drawn, 4326)), refresh = refresh_osm)
  layers <- wm_basemap_layers(osm$path, layout)
  labels <- wm_declutter(wm_label_candidates(layers, core, halo$halo, layout), layout)

  font_family <- wm_font_family()
  strings <- WM_STRINGS[[lang]]
  build_date <- as.Date(sub("\\.pmtiles$", "", osm$build), format = "%Y%m%d")
  list(
    slug = slug, lang = lang, layout = layout, osm = osm,
    osm_build_date = if (identical(lang, "de")) format(build_date, "%d.%m.%Y") else format(build_date, "%Y-%m-%d"),
    title = lab$name[[lang]],
    subtitle = .wm_fill(strings$subtitle, list(num = lab$num, region = lab$region[[lang]])),
    brand = list(color = lab$color, outlineColor = lab$outlineColor),
    scale_label = wm_format_number(layout$scale_denominator, lang),
    font_family = font_family,
    boundary = wm_boundary(slug),
    labels = labels,
    plot = wm_map_plot(slug, layers, halo, boundary_3857, labels, layout, font_family)
  )
}

wm_write_sheet <- function(sheet, out_dir, preview = FALSE) {
  L <- sheet$layout
  lab <- wm_lab(sheet$slug)
  stem <- sprintf("%s_%s_A3-%s_%s", lab$num, sheet$slug, L$orientation, sheet$lang)

  print_dir <- file.path(out_dir, "print")
  data_dir <- file.path(out_dir, "data", sheet$slug)
  dir.create(print_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(data_dir, recursive = TRUE, showWarnings = FALSE)
  # A sheet whose orientation changed since the last run must not leave its old PDF behind.
  unlink(Sys.glob(file.path(print_dir, sprintf("%s_%s_A3-*_%s.pdf", lab$num, sheet$slug, sheet$lang))))

  pdf_path <- file.path(print_dir, paste0(stem, ".pdf"))
  grDevices::cairo_pdf(pdf_path, width = L$page_w / 25.4, height = L$page_h / 25.4, family = sheet$font_family)
  tryCatch(wm_draw_sheet(sheet), finally = grDevices::dev.off())

  if (preview) {
    preview_dir <- file.path(out_dir, "preview")
    dir.create(preview_dir, recursive = TRUE, showWarnings = FALSE)
    grDevices::png(
      file.path(preview_dir, paste0(stem, ".png")),
      width = L$page_w / 25.4, height = L$page_h / 25.4, units = "in", res = 100, type = "cairo"
    )
    tryCatch(wm_draw_sheet(sheet), finally = grDevices::dev.off())
  }

  # The data behind the sheet, so it can be checked or re-styled in a GIS (QGIS opens
  # .pmtiles directly as a vector tile layer).
  sf::st_write(sheet$boundary, file.path(data_dir, "boundary.geojson"), delete_dsn = TRUE, quiet = TRUE)
  file.copy(sheet$osm$path, file.path(data_dir, "osm_extract.pmtiles"), overwrite = TRUE)
  labels_sf <- sf::st_transform(
    sf::st_as_sf(sheet$labels[, c("label", "kind", "x", "y")], coords = c("x", "y"), crs = 3857), 4326
  )
  sf::st_write(labels_sf, file.path(data_dir, paste0("labels_", sheet$lang, ".geojson")), delete_dsn = TRUE, quiet = TRUE)

  facts <- list(
    slug = sheet$slug, name = sheet$title, lang = sheet$lang,
    file = file.path("print", basename(pdf_path)),
    paper = "A3", orientation = L$orientation, page_mm = c(L$page_w, L$page_h),
    scale_denominator = L$scale_denominator, basemap_zoom = L$zoom,
    osm_source = paste0(WM_PROTOMAPS_BASE, sheet$osm$build),
    label_counts = as.list(table(sheet$labels$kind)),
    generated = format(Sys.Date())
  )
  jsonlite::write_json(facts, file.path(data_dir, paste0("sheet_", sheet$lang, ".json")), auto_unbox = TRUE, pretty = TRUE)
  message(sprintf(
    "  %s: %s, 1:%s, basemap zoom %d, %d labels -> %s",
    sheet$slug, L$orientation, format(L$scale_denominator, big.mark = ","), L$zoom,
    nrow(sheet$labels), pdf_path
  ))
  invisible(pdf_path)
}

#' README.txt for the package, rebuilt from every sheet_*.json present (so a partial re-run
#' still lists the sheets made earlier).
wm_write_readme <- function(out_dir) {
  fact_files <- sort(Sys.glob(file.path(out_dir, "data", "*", "sheet_*.json")))
  facts <- lapply(fact_files, jsonlite::fromJSON)
  facts <- facts[order(vapply(facts, function(f) f$file, character(1)))]
  rows <- vapply(facts, function(f) {
    sprintf("  %-46s  %-9s  approx. 1:%s", basename(f$file), f$orientation, format(f$scale_denominator, big.mark = ","))
  }, character(1))
  lines <- c(
    "Living Lab workshop maps -- A3 print sheets",
    "===========================================",
    "",
    "PRINTING",
    "  * Paper: A3. Each PDF is already set to its own orientation (see below).",
    "  * Print at 100 % / 'actual size'. Do NOT use 'fit to page' or 'shrink oversized pages':",
    "    the printed scale statement and scale bar are only correct at actual size.",
    "  * All content sits at least 10 mm inside the paper edge, so borderless printing is not needed.",
    "  * Colour printing recommended; matte paper is easier to write on.",
    "",
    "SHEETS",
    sprintf("  %-46s  %-9s  %s", "File (print/)", "Paper", "Scale at A3"),
    rows,
    "",
    "CONTENTS",
    "  print/                                  the files to print",
    "  data/<region>/boundary.geojson          Living Lab boundary (EPSG:4326)",
    "  data/<region>/osm_extract.pmtiles       OpenStreetMap vector tiles the basemap was drawn from",
    "  data/<region>/labels_<lang>.geojson     the place, river, lake, road and peak labels placed",
    "  data/<region>/sheet_<lang>.json         orientation, scale and data source of each sheet",
    "",
    "ATTRIBUTION (must stay on any reproduction)",
    "  Map data: (c) OpenStreetMap contributors, ODbL -- https://www.openstreetmap.org/copyright",
    "  Vector tiles: Protomaps (https://protomaps.com)",
    "  Living Lab boundaries: LL-Explorer (ZALF)",
    ""
  )
  writeLines(enc2utf8(lines), file.path(out_dir, "README.txt"), useBytes = TRUE)
}

# --- Command line --------------------------------------------------------------------------

wm_main <- function(args = commandArgs(trailingOnly = TRUE)) {
  opt <- function(name, default) {
    hit <- grep(paste0("^--", name, "="), args, value = TRUE)
    if (length(hit) > 0) sub(paste0("^--", name, "="), "", hit[1]) else default
  }
  slugs <- names(wm_labs())
  slug_arg <- opt("slug", NULL)
  if (!is.null(slug_arg)) {
    slugs <- trimws(strsplit(slug_arg, ",", fixed = TRUE)[[1]])
  }
  lang <- opt("lang", "de")
  if (!lang %in% names(WM_STRINGS)) {
    stop("--lang must be one of: ", paste(names(WM_STRINGS), collapse = ", "), call. = FALSE)
  }
  out_dir <- opt("out", WM_DEFAULT_OUT)
  refresh_osm <- "--refresh-osm" %in% args
  preview <- "--preview" %in% args

  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  message("Writing A3 workshop maps to ", normalizePath(out_dir, winslash = "/"))
  for (slug in slugs) {
    wm_lab(slug) # fails fast with the list of known slugs
    wm_write_sheet(wm_build_sheet(slug, lang, refresh_osm), out_dir, preview = preview)
  }
  wm_write_readme(out_dir)
  message("Done. Zip '", normalizePath(out_dir, winslash = "/"), "' to send it on.")
}

if (sys.nframe() == 0L) {
  wm_main()
}
