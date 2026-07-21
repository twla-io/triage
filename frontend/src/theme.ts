import { createTheme, defaultVariantColorsResolver, type CSSVariablesResolver, type MantineColorsTuple } from '@mantine/core'

// Palette ported verbatim from the standalone HTML mockup. Only index 1 (bg)
// and index 9 (text) of each semantic tuple are literal mockup values --
// the rest are hand-interpolated stops so Mantine's non-light/filled
// variants (outline/subtle/etc, and any hover state) still have something
// coherent to draw on.
const danger: MantineColorsTuple = [
  '#fef5f5', '#fcebeb', '#f7d4d4', '#f09595', '#e57373',
  '#d94f4f', '#c23636', '#a32b2b', '#8a2424', '#791f1f',
]
const success: MantineColorsTuple = [
  '#f5f9ef', '#eaf3de', '#d4e7bd', '#b9d896', '#9bc76e',
  '#7fb64c', '#63a032', '#4c8323', '#396318', '#27500a',
]
const accent: MantineColorsTuple = [
  '#f1f7fd', '#e6f1fb', '#c9e0f6', '#a4cbef', '#78b1e6',
  '#4f96da', '#2f7ac8', '#1c62ac', '#134b88', '#0c447c',
]
const warning: MantineColorsTuple = [
  '#fdf8f1', '#faeeda', '#f2dcb0', '#e7c581', '#d9aa54',
  '#c88f34', '#ac7424', '#8c5c1a', '#714910', '#633806',
]

// Mantine's internals (Paper/AppShell borders, Input's default border,
// --mantine-color-dimmed) all key off the built-in `gray` scale rather than
// a bespoke set of variables, so the neutral tokens are ported by
// redefining `gray` itself instead of chasing every individual CSS
// variable. surface-0/1/2 sit at 2/1/0 (lightest first, Mantine
// convention); border/border-strong at 3-4/5; text-muted/secondary/primary
// at 6/8/9 -- gray-6 lines up with Mantine's own default
// `--mantine-color-dimmed: var(--mantine-color-gray-6)`, so text-muted
// becomes the dimmed color for free.
const gray: MantineColorsTuple = [
  '#f8f7f4', // 0
  '#f5f4f0', // 1  surface-1
  '#ececea', // 2  surface-0
  '#d3d1c7', // 3  border (Paper/AppShell/Divider default border)
  '#d3d1c7', // 4  border (Input default border)
  '#b4b2a9', // 5  border-strong
  '#888780', // 6  text-muted (-> --mantine-color-dimmed)
  '#726f68', // 7
  '#5f5e5a', // 8  text-secondary
  '#1a1a18', // 9  text-primary
]

// bg/text pairs exactly as given by the mockup, for the light/filled
// variant resolver below -- kept separate from the interpolated tuples
// above so "light" Alerts/Buttons/Badges render the *exact* mockup
// color, not an approximation of it.
const SEMANTIC_TINTS: Record<string, { bg: string; text: string; border?: string; hover: string }> = {
  red: { bg: '#fcebeb', text: '#791f1f', border: '#f09595', hover: danger[2] },
  green: { bg: '#eaf3de', text: '#27500a', hover: success[2] },
  blue: { bg: '#e6f1fb', text: '#0c447c', hover: accent[2] },
  orange: { bg: '#faeeda', text: '#633806', hover: warning[2] },
  // The mockup only defines one warning color; "yellow" is used
  // interchangeably with "orange" for cautionary states in this app, so it
  // aliases to the same tint rather than inventing an unspecified fifth color.
  yellow: { bg: '#faeeda', text: '#633806', hover: warning[2] },
}

const FILLED_BACKGROUND: Record<string, string> = {
  red: danger[6],
  green: success[6],
  blue: accent[6],
  orange: warning[6],
  yellow: warning[6],
}

export const theme = createTheme({
  black: '#1a1a18', // text-primary -- flows into --mantine-color-text
  primaryColor: 'blue', // redefined to the accent family below
  primaryShade: 6,
  defaultRadius: '8px',
  colors: { red: danger, green: success, blue: accent, orange: warning, yellow: warning, gray },
  variantColorResolver: (input) => {
    const tint = typeof input.color === 'string' ? SEMANTIC_TINTS[input.color] : undefined
    if (tint) {
      if (input.variant === 'light') {
        return {
          background: tint.bg,
          hover: tint.hover,
          color: tint.text,
          border: tint.border ? `1px solid ${tint.border}` : '1px solid transparent',
        }
      }
      if (input.variant === 'filled') {
        const filledColor = typeof input.color === 'string' ? FILLED_BACKGROUND[input.color] : undefined
        if (filledColor) {
          return {
            background: filledColor,
            hover: filledColor,
            color: 'var(--mantine-color-white)',
            border: '1px solid transparent',
          }
        }
      }
    }
    return defaultVariantColorsResolver(input)
  },
})

// The one CSS variable with no theme-level field of its own: Paper/AppShell
// both read --mantine-color-body directly, but the mockup wants them at
// different surface levels (AppShell = surface-1, Paper = surface-2) -- see
// theme.css's .mantine-Paper-root override for the other half of this.
export const cssVariablesResolver: CSSVariablesResolver = () => ({
  variables: {},
  light: {
    '--mantine-color-body': '#f5f4f0', // surface-1
  },
  dark: {},
})
