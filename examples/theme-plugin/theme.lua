-- Atelier token tables.
--
-- Only geometry, typography and lyric motion are themed. Lazer's theme
-- contract has no colour tokens: colours and surfaces stay with the host so a
-- skin cannot break contrast, accessibility or platform conventions.
--
-- Ranges enforced by the host (values outside them fall back or clamp):
--   groupedCardRadius          0–40
--   listTileMinHeight          0–160
--   listTileVerticalPadding    0–48
--   pageTitleCompactSize       0–72
--   pageTitleRegularSize       0–72
--   sectionHeaderSize          0–48
--   *Weight                    100–900
--   lyricFontScale             0.5–2
--   lyricTranslationScale      0.4–1.5
--   lyricLineHeight            0.8–3
--   lyricTranslationLineHeight 0.8–3
--   lyricTranslationGap        0–48
--   lyricDimAlpha              0–1
--   lyricTranslationAlpha      0–1
--   lyricSpringMassScale       0.25–4
--   lyricSpringStiffnessScale  0.25–4
--   lyricSpringDampingScale    0.25–4
--   lyricStaggerDelay          bounded by the host
--   lyricStaggerDecay          bounded by the host
--   lyricFocusScaleDelta       bounded by the host
--   controlRadius              0–200
--   glassBlurSigma             0–48
--
-- Layout tokens: compactInset 0–80, regularInset 0–120, tvInsetFactor 0–0.25,
-- maxContentWidth 0–3000, tvMaxContentWidth 0–4000, tabletBreakpoint 320–1600.

local M = {}

local theme = {
  id = "example.theme-atelier",
  name = "Atelier",
  version = 1,
  elements = {
    -- Surfaces and lists: slightly rounder cards, a little more air per row.
    groupedCardRadius = 22,
    listTileMinHeight = 56,
    listTileVerticalPadding = 10,
    controlRadius = 16,
    glassBlurSigma = 22,

    -- Display type: a wider masthead without turning every title into a poster.
    pageTitleCompactSize = 40,
    pageTitleRegularSize = 38,
    sectionHeaderSize = 22,
    displayWeight = 800,
    headingWeight = 700,
    titleWeight = 700,
    bodyWeight = 400,
    labelWeight = 600,

    -- Lyrics: calmer spring, a touch more line height, centred text.
    lyricWeight = 600,
    lyricTranslationWeight = 400,
    lyricFontScale = 1.05,
    lyricTranslationScale = 0.78,
    lyricLineHeight = 1.6,
    lyricTranslationLineHeight = 1.5,
    lyricTranslationGap = 8,
    lyricDimAlpha = 0.42,
    lyricTranslationAlpha = 0.62,
    lyricTextAlign = "center",
    lyricSpringMassScale = 0.9,
    lyricSpringStiffnessScale = 1.15,
    lyricSpringDampingScale = 0.92,
    lyricStaggerDelay = 0.06,
    lyricStaggerDecay = 1.04,
    lyricFocusScaleDelta = 4,
  },
}

local layout = {
  id = "example.layout.atelier",
  name = "Atelier Airy",
  compactInset = 20,
  regularInset = 32,
  tvInsetFactor = 0.05,
  maxContentWidth = 1240,
  tvMaxContentWidth = 1680,
  tabletBreakpoint = 760,
}

function M.bundle()
  return { theme = theme, layout = layout }
end

function M.summary()
  return {
    id = theme.id,
    name = theme.name,
    tokens = #theme.elements,
    layout = layout.id,
  }
end

return M