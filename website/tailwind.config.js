/** @type {import('tailwindcss').Config} */
//
// Theme tokens live as CSS variables in src/input.css (`:root` for light,
// `.dark` for dark). Colors here are bound to those variables with
// `<alpha-value>`, so `bg-canvas/80`, `border-hairline`, `text-ink` etc.
// flip automatically when the theme class changes.
module.exports = {
  content: ['./src/**/*.{astro,html,js,ts}', './public/assets/js/*.js'],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        // Semantic, theme-flipping paper & ink tokens.
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
        primary: 'rgb(var(--c-primary) / <alpha-value>)',
        'on-primary': 'rgb(var(--c-on-primary) / <alpha-value>)',
        success: 'rgb(var(--c-success) / <alpha-value>)',
        destructive: 'rgb(var(--c-destructive) / <alpha-value>)',
        // Snaptitle crayon-and-paper palette.
        cp: {
          paper: 'rgb(var(--c-canvas) / <alpha-value>)',
          ink: 'rgb(var(--c-ink) / <alpha-value>)',
          'ink-2': 'rgb(var(--c-body) / <alpha-value>)',
          'ink-3': 'rgb(var(--c-muted) / <alpha-value>)',
          'ink-4': 'rgb(var(--c-muted-soft) / <alpha-value>)',
          orange: 'rgb(var(--c-orange) / <alpha-value>)',
          'orange-deep': 'rgb(var(--c-orange-deep) / <alpha-value>)',
          yellow: 'rgb(var(--c-yellow) / <alpha-value>)',
          'yellow-soft': 'rgb(var(--c-yellow-soft) / <alpha-value>)',
          navy: 'rgb(var(--c-navy) / <alpha-value>)',
          'navy-deep': 'rgb(var(--c-navy-deep) / <alpha-value>)',
          sky: '#bfe0ff',
          mint: '#c9efa9',
          peach: '#ffe1bf',
          'peach-deep': '#ffb27e',
          lilac: '#e0d4ff',
          pink: '#ffb3a7',
          green: '#a6e27a',
          blue: '#9fcfff',
          finder: '#1f7ae0',
          keycap: '#d9dae0',
        },
        // Retained pastel/clay aliases for backwards compatibility across subpages.
        clay: {
          pink: '#ff5a14',
          rose: '#ffb3a7',
          teal: '#2b2f6b',
          lav: '#e0d4ff',
          peach: '#ffe1bf',
          ochre: '#ffe27a',
          mint: '#c9efa9',
          cream: '#fffdf8',
          'pink-ink': '#121214',
          'pink-soft': '#3d3d44',
          'lav-ink': '#121214',
          'lav-soft': '#3d3d44',
          'peach-ink': '#121214',
          'peach-soft': '#3d3d44',
          'ochre-ink': '#121214',
          'ochre-soft': '#3d3d44',
          'rose-ink': '#121214',
          'rose-soft': '#3d3d44',
          'mint-ink': '#121214',
          'mint-soft': '#3d3d44',
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
          'Inter',
          '-apple-system',
          'BlinkMacSystemFont',
          '"SF Pro Text"',
          'system-ui',
          'sans-serif',
        ],
        display: [
          'Gaegu',
          'Fredoka',
          '-apple-system',
          'BlinkMacSystemFont',
          'system-ui',
          'sans-serif',
        ],
        hand: [
          'Gaegu',
          'Fredoka',
          '"Comic Sans MS"',
          'cursive',
          'sans-serif',
        ],
        mono: [
          '"JetBrains Mono"',
          'ui-monospace',
          'SFMono-Regular',
          'Menlo',
          'monospace',
        ],
      },
      maxWidth: {
        prose: '70ch',
        content: '1136px',
      },
      boxShadow: {
        card: '0 0 0 2.5px rgb(var(--c-ink)), 4px 5px 0 rgb(var(--c-shadow))',
        pop: '0 0 0 3px rgb(var(--c-ink)), 5px 6px 0 rgb(var(--c-shadow))',
        paper: '0 0 0 2.5px rgb(var(--c-ink)), 4px 5px 0 rgb(var(--c-shadow))',
        'paper-lg': '0 0 0 3px rgb(var(--c-ink)), 6px 7px 0 rgb(var(--c-shadow))',
      },
      backgroundImage: {
        'hero-glow':
          'radial-gradient(ellipse 75% 55% at 50% -15%, rgba(255, 90, 20, 0.08), transparent 68%), radial-gradient(ellipse 45% 45% at 78% 12%, rgba(255, 210, 63, 0.09), transparent 70%)',
      },
    },
  },
  plugins: [],
};
