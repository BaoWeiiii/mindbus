# MindBus Menu Bar Icon Design

## Status

Approved visual direction: **Optical Reverse Fold**, with the real-menu-bar optical sizing correction approved on 2026-08-11.

This design replaces only the macOS menu bar image. The existing full-color MindBus logo remains the app icon and the primary brand artwork everywhere else.

## Problem

`StatusBarController` currently loads the full-color `logo.png` and displays it at 18×18 pt. The source artwork contains generous transparent margins and depends on gradients, highlights, and three-dimensional shading. At menu bar scale, the visible mark becomes too small, loses contrast against colored wallpaper, and no longer reads like a native macOS status item.

## Goals

- Preserve immediate family resemblance to the full-color MindBus logo.
- Match the restrained, single-color language of Apple menu bar symbols.
- Remain clear on light, dark, and wallpaper-tinted menu bars.
- Increase the visible optical size without making the status item feel heavy.
- Preserve the soft, organic character of the original mark.

## Final Symbol

### Outer silhouette

- Use the tightly cropped alpha silhouette of the existing MindBus logo.
- Preserve its asymmetric double-wing form; the right side remains slightly larger.
- Do not redraw it as a geometric infinity symbol, a mask-like pair of holes, or a letter M.

### Internal fold

- Add one soft fold that rises from lower-left toward upper-right.
- Do not use a literal horizontal mirror of the earlier fold. That pushes too much visual weight into the already-heavy upper-right lobe.
- Apply optical compensation:
  - shorten the fold by 15% relative to the literal mirrored curve;
  - move its visual center 1 pt toward the lower-left;
  - keep the lower-left segment darker and slightly wider;
  - make the upper-right segment thinner and more transparent;
  - stop the upper endpoint inside the silhouette instead of touching the outer edge.
- The fold must not create two enclosed holes, a face, or a hard slash.

The approved fold uses a normalized 28×28 coordinate system:

- full curve: `M 9.8,17.6 C 11.8,16.6 12.8,14.9 13.3,13.1 C 13.9,11.2 15.0,9.8 17.0,9.0`;
- full-curve width: 1.12 units;
- emphasized lower segment: the first cubic segment ending at `13.3,13.1`, width 1.38 units.

### Template behavior

- The delivered resource is black plus transparency and is marked as an AppKit template image.
- The outer silhouette uses full alpha.
- The full fold reduces local alpha to 52%; the stronger lower-left segment reduces the combined local alpha to 12.5%.
- macOS supplies the final foreground color for normal, highlighted, light, dark, and wallpaper-tinted menu bars.

## Size and Placement

- Source asset: deterministic 80×64 px transparent PNG generated from the existing logo.
- Logical `NSImage` size: **20×16 pt**.
- The first installed build used a 76×52 px visible silhouette (**19×13 pt**). In a 2× real-menu-bar screenshot it occupied 38×26 px and carried substantially more filled area than the adjacent outline symbols. Its vertical centroid was already correct, so this is a size and aspect-ratio correction, not an alignment correction.
- Revised visible silhouette bounds: **70×51 px** at `x: 5, y: 6` inside the 80×64 px canvas, yielding approximately **17.5×12.75 pt**. This is the closest deterministic integer-pixel form of the approved approximately 17.5×12.5 pt target while returning the silhouette to the original logo's proportions.
- Apply the same affine transform from the former `x: 2, y: 6, width: 76, height: 52` silhouette bounds to the revised bounds: point coordinates use `scaleX = 70/76` and `scaleY = 51/52`, while fold stroke widths use the geometric-mean scale `sqrt(scaleX × scaleY) ≈ 0.951`. Do not redraw, mirror, simplify, or otherwise reinterpret the fold.
- Keep the 20×16 pt logical image size so the status-item layout and click target remain unchanged; only the transparent padding and visible optical mass change.
- Status item remains variable-length and retains the current click targets and interactions.
- The image is optically centered; no additional title or badge is shown.

## Implementation

1. Add `MindBus/Resources/menubar-logo.png`.
2. Add a deterministic Swift/CoreGraphics rendering script under `scripts/` that:
   - extracts and tightly crops the alpha silhouette from `MindBus/Resources/logo.png`;
   - maps the silhouette into the revised 70×51 px visible bounds and fills it with black;
   - applies the two-stage alpha fold using the approved optically compensated curve transformed with those same bounds;
   - writes the final high-resolution transparent PNG.
3. Add the new resource to `Package.swift`.
4. Update `StatusBarController.setupStatusItem()` to load `menubar-logo.png`, set its logical size to 20×16 pt, and set `isTemplate = true` before assigning it to `button.image`.
5. Keep the existing SF Symbol fallback and set the status bar button accessibility label to `MindBus` for both the custom image and fallback paths.
6. Do not modify or replace the existing full-color `logo.png`.

## Verification

- Run the rendering script twice and confirm the output checksum is stable.
- Confirm the generated PNG has transparent padding only where intended and contains no colored pixels.
- Confirm its nontransparent bounding box is `x: 5, y: 6, width: 70, height: 51` and the fold remains proportional to the approved version.
- Run `swift build` and `swift test`.
- Confirm the resource is present in the built SwiftPM resource bundle.
- Launch the app and inspect the real menu bar result on both light and dark menu bar backgrounds.
- On a 2× menu bar capture, expect a visible footprint of approximately 35×25–26 px with the same vertical centroid as neighboring native symbols and clearly less optical dominance than the 38×26 px first build.
- Verify left-click popover and right-click context menu behavior remain unchanged.

## Out of Scope

- Redesigning the full-color app icon.
- Adding animation, activity colors, badges, or status-dependent variants.
- Changing the status item interaction model or popover behavior.
