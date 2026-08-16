# Brand assets

The mark is the app's own `DishArcGlyph` — a filled dot under two concentric
semicircles, the outer one at 45% and clipped flat where it overruns the glyph
frame. Everything here is derived from that one shape so the icon, the menu bar
and GitHub cannot drift apart.

| File | Use |
|---|---|
| `avatar.svg` | Source for the GitHub org avatar. Full-bleed dark field, no inner tile. |
| `avatar-1024.png` | What you actually upload to GitHub, and what the org profile README embeds. |
| `mark.svg` | The glyph alone, `currentColor`, transparent. For READMEs and docs on either theme. |

## Why these differ from the app icon

`app/Resources/AppIcon.icns` is not reusable here. macOS icons sit in a rounded
square inset from their canvas (`renderAppIcon` in `app/Sources/DishWatch/Render.swift`
uses `inset: 100` of 1024, glyph at 62% of the remaining tile), which is correct
in the Dock and wrong on GitHub: GitHub rounds the avatar itself, so the inner
tile reads as a second frame and the glyph lands at ~27% of the visible area.
At the 20 px GitHub uses in most lists that is a smudge.

`avatar.svg` therefore drops the inset and the inner rounded rect and scales the
glyph to 80% of the canvas. The gradient (`#101725` → `#05080F`), the cyan
(`#37D7FF`), the stroke ratio (0.045 × glyph) and the arc radii are unchanged.

## Regenerating

`avatar-1024.png` is rendered from the SVG, not exported by hand:

```sh
rsvg-convert -w 1024 -h 1024 brand/avatar.svg -o brand/avatar-1024.png
```

If the glyph in `MenuBarIcon.swift` changes, the ratios in `avatar.svg` have to
be edited to match — nothing enforces it automatically.

## Palette

| Token | Hex | Where |
|---|---|---|
| Cyan (ink) | `#37D7FF` | glyph, ping trace, primary accent |
| Field top | `#101725` | avatar and app-icon gradient start |
| Field bottom | `#05080F` | avatar and app-icon gradient end |
| Blue | `#4B8DF8` | throughput trace |
| Amber | `#FFB340` | power trace, signal gauge |
| Green | `#30D158` | connected state |
| Red | `#FF453A` | outage, fault |

## Constraint

**No Starlink or SpaceX mark, wordmark, or dish silhouette traced from their
hardware.** A dish arc is a dish arc. See the note on App Store guideline 5.2 in
`renderAppIcon`.
