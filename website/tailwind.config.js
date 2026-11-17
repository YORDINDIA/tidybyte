/** @type {import('tailwindcss').Config} */
//
// Theme tokens live as CSS variables in src/input.css (`:root` for light,
// `.dark` for dark). Colors here are bound to those variables with
// `<alpha-value>`, so `bg-canvas/80`, `border-hairline`, `text-ink` etc.
// flip automatically when the theme class changes — no per-element
// `dark:` variants needed.
module.exports = {
  content: ['./src/**/*.{astro,html,js,ts}', './public/assets/js/*.js'],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        // Semantic, theme-flipping tokens.
        canvas: 'rgb(var(--c-canvas) / <alpha-value>)',
        'surface-soft': 'rgb(var(--c-surface-soft) / <alpha-value>)',
        'surface-card': 'rgb(var(--c-surface-card) / <alpha-value>)',
        'surface-dark': 'rgb(var(--c-surface-dark) / <alpha-value>)',
        hairline: 'rgb(var(--c-hairline) / <alpha-value>)',
        'hairline-strong': 'rgb(var(--c-hairline-strong) / <alpha-value>)',
        ink: 'rgb(var(--c-ink) / <alpha-value>)',
        body: 'rgb(var(--c-body) / <alpha-value>)',
        muted: 'rgb(var(--c-muted) / <alpha-value>)',
        'muted-soft': 'rgb(var(--c-muted-soft) / <alpha-value>)',
        // Primary CTA: near-black in light, cream in dark (see input.css).
        primary: 'rgb(var(--c-primary) / <alpha-value>)',
        'on-primary': 'rgb(var(--c-on-primary) / <alpha-value>)',
        // Status text (table verdicts, tips): readable in both themes.
        success: 'rgb(var(--c-success) / <alpha-value>)',
        destructive: 'rgb(var(--c-destructive) / <alpha-value>)',
        // Saturated feature-card palette (identical in both themes) plus
        // on-colour text tokens for text set directly on those cards.
        clay: {
          pink: '#ff4d8b',
          rose: '#ff7aa2',
          teal: '#1a3a3a',
          lav: '#b8a4ed',
          peach: '#ffb084',
          ochre: '#e8b94a',
          mint: '#a4d4c5',
          cream: '#fffaf0',
          'pink-ink': '#2b0a16',
          'pink-soft': '#4a1425',
          'lav-ink': '#241a3d',
          'lav-soft': '#3a2c5c',
          'peach-ink': '#4a2508',
          'peach-soft': '#6b3a12',
          'ochre-ink': '#3d2f05',
          'ochre-soft': '#57430a',
          'rose-ink': '#3d0a20',
          'rose-soft': '#5c122f',
          'mint-ink': '#123326',
          'mint-soft': '#1e4d3a',
        },
        // App category colors (storage legend, smart categories).
        brand: {
          photo: '#0A84FF',
          video: '#AF52DE',
          screenshot: '#FFCC00',
          live: '#30B0C7',
          other: '#8E8E93',
        },
      },
      fontFamily: {
        sans: [
          '-apple-system',
          'BlinkMacSystemFont',
          '"SF Pro Display"',
          '"SF Pro Text"',
          'Inter',
          'system-ui',
          'sans-serif',
        ],
        display: [
          'Fredoka',
          '-apple-system',
          'BlinkMacSystemFont',
          '"SF Pro Display"',
          'Inter',
          'system-ui',
          'sans-serif',
        ],
        mono: ['ui-monospace', 'SFMono-Regular', 'Menlo', 'monospace'],
      },
      maxWidth: {
        prose: '70ch',
        content: '1120px',
      },
      boxShadow: {
        // Soft, low shadows only — depth comes from card-vs-canvas contrast.
        card: '0 1px 2px rgba(38, 34, 24, 0.05), 0 12px 30px -16px rgba(38, 34, 24, 0.14)',
        pop: '0 22px 50px -18px rgba(24, 22, 18, 0.28), 0 4px 14px -6px rgba(24, 22, 18, 0.12)',
      },
      backgroundImage: {
        'hero-glow':
        'radial-gradient(ellipse 75% 55% at 50% -15%, rgba(255, 77, 139, 0.15), transparent 68%), radial-gradient(ellipse 45% 45% at 78% 12%, rgba(10, 132, 255, 0.09), transparent 70%)',
      },
    },
  },
  plugins: [],
}
