#!/usr/bin/env node
// @ts-nocheck

// Codex Cast app icon — same visual family as codexReader's marks (radial
// violet ground, mirrored waveform ramp, #6f58c4 accent) with headphones as
// the subject: an ink band arcing over the wave, cups seated at its ends.
//
// Outputs (1024×1024, written to ../App/Assets.xcassets/AppIcon.appiconset/):
//   icon-light.png   opaque — the "any/light" slot
//   icon-dark.png    opaque ink ground — the "dark" slot
//   icon-tinted.png  grayscale on transparent — the "tinted" slot
// Plus SVG references beside this script for design edits.
//
// Run: node Spike/generate-icon.mjs
// (sharp is borrowed from the codexReader workspace's node_modules.)

import fs from "node:fs"
import { createRequire } from "node:module"
import path from "node:path"
import { fileURLToPath } from "node:url"

const require = createRequire(
  "/Users/cgreen15/Nextcloud/codeProjects/codexReader/package.json",
)
const sharp = require("sharp")

const HERE = path.dirname(fileURLToPath(import.meta.url))
const OUT = path.join(HERE, "..", "App", "Assets.xcassets", "AppIcon.appiconset")
fs.mkdirSync(OUT, { recursive: true })

// ---------------------------------------------------------------------------
// Palettes — the codexReader accent family, #6f58c4 as the anchor.
// ---------------------------------------------------------------------------

const PALETTES = {
  light: {
    bgA: "#ece5fa",
    bgB: "#cfbef0",
    ramp: ["#5f4ab8", "#6f58c4", "#8068d0", "#9179dc", "#a189e6"],
    band: "#1a1a3e",
    bandInner: "#23234f",
    cup: "#1a1a3e",
    cupPad: "#6f58c4",
    opaque: true,
  },
  dark: {
    bgA: "#1d1d44",
    bgB: "#0b0b1d",
    ramp: ["#c3b6f8", "#b2a2f0", "#a08ee4", "#8d7ad6", "#7c68c6"],
    band: "#e1dac7",
    bandInner: "#d6cfbd",
    cup: "#e1dac7",
    cupPad: "#907ee0",
    opaque: true,
  },
  tinted: {
    bgA: null,
    bgB: null,
    ramp: ["#cccccc", "#b8b8b8", "#a3a3a3", "#8f8f8f", "#7d7d7d"],
    band: "#e6e6e6",
    bandInner: "#d6d6d6",
    cup: "#e6e6e6",
    cupPad: "#949494",
    opaque: false,
  },
}

// ---------------------------------------------------------------------------
// Geometry: headphone band arcing over a centered waveform, cups at the ends.
// Same mirrored-bar system as the reader marks.
// ---------------------------------------------------------------------------

const BAND = {
  // Arc through the cup tops (236,540)/(788,540) with apex at (512,285):
  // center (512, 562), r 277 — the band lands ON the cups instead of
  // floating above them.
  cx: 512,
  cy: 562,
  r: 277,
  width: 58,
  startDeg: 184.5,
  endDeg: -4.5,
}

const CUPS = {
  // Ear cups: rounded-rect shells with a violet pad inset, hanging from the
  // band ends.
  w: 128,
  h: 172,
  rx: 56,
  y: 508,
  leftX: 172,
  rightX: 724, // mirrored: 1024 - 172 - 128
  padInset: 26,
}

// Waveform between the cups (bar system lifted from the reader marks).
const BAR_W = 33
function mirroredBars({ offs, heights, anchor }) {
  const bars = []
  offs.forEach((off, i) => {
    const h = heights[i]
    bars.push({ cx: 512 - off, top: anchor - h / 2, bottom: anchor + h / 2, tone: Math.min(i + 1, 4) })
    if (off > 0) {
      bars.push({ cx: 512 + off, top: anchor - h / 2, bottom: anchor + h / 2, tone: Math.min(i + 1, 4) })
    }
  })
  // Center bar, tallest, tone 0.
  bars.push({ cx: 512, top: anchor - 139, bottom: anchor + 139, tone: 0 })
  return bars
}
const BARS = mirroredBars({
  offs: [56, 112, 168, 224],
  heights: [206, 118, 168, 84],
  anchor: 606,
})

function polar(cx, cy, r, deg) {
  const rad = (deg * Math.PI) / 180
  return [cx + r * Math.cos(rad), cy + r * Math.sin(rad)]
}

function buildSvg(pal) {
  const bg = pal.bgA
    ? `<defs><radialGradient id="bg" cx="50%" cy="30%" r="90%">` +
      `<stop offset="0%" stop-color="${pal.bgA}"/><stop offset="100%" stop-color="${pal.bgB}"/>` +
      `</radialGradient></defs><rect width="1024" height="1024" fill="url(#bg)"/>`
    : ""

  const [sx, sy] = polar(BAND.cx, BAND.cy, BAND.r, BAND.startDeg)
  const [ex, ey] = polar(BAND.cx, BAND.cy, BAND.r, BAND.endDeg)
  const band =
    `<path d="M${sx.toFixed(1)},${sy.toFixed(1)} A${BAND.r},${BAND.r} 0 0 1 ${ex.toFixed(1)},${ey.toFixed(1)}"` +
    ` fill="none" stroke="${pal.band}" stroke-width="${BAND.width}" stroke-linecap="round"/>` +
    // A thin inner highlight line gives the band the two-tone read the book
    // pages have.
    `<path d="M${sx.toFixed(1)},${sy.toFixed(1)} A${BAND.r},${BAND.r} 0 0 1 ${ex.toFixed(1)},${ey.toFixed(1)}"` +
    ` fill="none" stroke="${pal.bandInner}" stroke-width="${BAND.width - 34}" stroke-linecap="round"/>`

  const cup = (x) =>
    `<rect x="${x}" y="${CUPS.y}" width="${CUPS.w}" height="${CUPS.h}" rx="${CUPS.rx}" fill="${pal.cup}"/>` +
    `<rect x="${x + CUPS.padInset}" y="${CUPS.y + CUPS.padInset}" width="${CUPS.w - CUPS.padInset * 2}"` +
    ` height="${CUPS.h - CUPS.padInset * 2}" rx="${CUPS.rx - CUPS.padInset}" fill="${pal.cupPad}"/>`

  const bars = BARS.map(
    ({ cx, top, bottom, tone }) =>
      `<rect x="${cx - BAR_W / 2}" y="${top}" width="${BAR_W}" height="${bottom - top}" rx="${BAR_W / 2}" fill="${pal.ramp[tone]}"/>`,
  ).join("")

  return `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
${bg}${bars}${band}${cup(CUPS.leftX)}${cup(CUPS.rightX)}
</svg>`
}

for (const [slot, pal] of Object.entries(PALETTES)) {
  const svg = buildSvg(pal)
  fs.writeFileSync(path.join(HERE, `icon-${slot}.svg`), svg)
  let img = sharp(Buffer.from(svg))
  if (pal.opaque) img = img.flatten({ background: pal.bgB ?? "#000000" })
  await img.png().toFile(path.join(OUT, `icon-${slot}.png`))
  console.log(`wrote AppIcon.appiconset/icon-${slot}.png`)
}

// Contents.json for the single-size appearance-aware icon set.
fs.writeFileSync(
  path.join(OUT, "Contents.json"),
  JSON.stringify(
    {
      images: [
        { filename: "icon-light.png", idiom: "universal", platform: "ios", size: "1024x1024" },
        {
          appearances: [{ appearance: "luminosity", value: "dark" }],
          filename: "icon-dark.png", idiom: "universal", platform: "ios", size: "1024x1024",
        },
        {
          appearances: [{ appearance: "luminosity", value: "tinted" }],
          filename: "icon-tinted.png", idiom: "universal", platform: "ios", size: "1024x1024",
        },
      ],
      info: { author: "xcode", version: 1 },
    },
    null,
    2,
  ),
)
console.log("wrote AppIcon.appiconset/Contents.json")


// ---------------------------------------------------------------------------
// Alternate home-screen icons (user-selectable in Settings > App Icon).
// Loose PNGs, NOT in the asset catalog: iOS alternate icons are looked up by
// filename via CFBundleAlternateIcons. 120px (@2x) and 180px (@3x).
// ---------------------------------------------------------------------------

const ALT_DIR = path.join(HERE, "..", "App", "AlternateIcons")
fs.mkdirSync(ALT_DIR, { recursive: true })

const ALTERNATES = {
  // The dark mark as an always-on choice.
  IconInk: PALETTES.dark,
  // Violet ground flipped to a deep accent field with cream band.
  IconViolet: {
    bgA: "#6f58c4",
    bgB: "#4b3a90",
    ramp: ["#efe9ff", "#e3dafd", "#d4c8f7", "#c4b5f0", "#b5a4e9"],
    band: "#1a1a3e",
    bandInner: "#23234f",
    cup: "#1a1a3e",
    cupPad: "#e1dac7",
    opaque: true,
  },
}

for (const [name, pal] of Object.entries(ALTERNATES)) {
  const svg = buildSvg(pal)
  for (const [suffix, size] of [["@2x", 120], ["@3x", 180]]) {
    let img = sharp(Buffer.from(svg)).resize(size, size)
    if (pal.opaque) img = img.flatten({ background: pal.bgB ?? "#000000" })
    await img.png().toFile(path.join(ALT_DIR, `${name}${suffix}.png`))
    console.log(`wrote AlternateIcons/${name}${suffix}.png`)
  }
}
