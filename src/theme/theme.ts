import { createTheme } from '@mui/material/styles';

const brand = {
  primary: '#176B5B',
  primaryDark: '#105246',
  accent: '#3978D4',
  ink: '#172B35',
  muted: '#5F7078',
  canvas: '#F4F7F8',
  line: '#E3EAEC',
};

export const theme = createTheme({
  palette: {
    mode: 'light',
    primary: { main: brand.primary, light: '#DCEFEA', dark: brand.primaryDark, contrastText: '#FFFFFF' },
    secondary: { main: brand.accent, light: '#E5EEFB', dark: '#245DAE', contrastText: '#FFFFFF' },
    success: { main: '#237A50', light: '#E3F3E9', dark: '#195E3C' },
    warning: { main: '#A65C0A', light: '#FFF1D7', dark: '#804605' },
    error: { main: '#B5433F', light: '#FCE8E6', dark: '#91332F' },
    background: { default: brand.canvas, paper: '#FFFFFF' },
    text: { primary: brand.ink, secondary: brand.muted },
    divider: brand.line,
  },
  typography: {
    fontFamily: ['Inter', 'Padauk', '-apple-system', 'BlinkMacSystemFont', 'Segoe UI', 'Roboto', 'sans-serif'].join(', '),
    fontSize: 14,
    h1: { fontWeight: 750, letterSpacing: '-0.035em', lineHeight: 1.15 },
    h2: { fontWeight: 750, letterSpacing: '-0.03em', lineHeight: 1.2 },
    h3: { fontWeight: 700, letterSpacing: '-0.025em', lineHeight: 1.25 },
    h4: { fontWeight: 700, letterSpacing: '-0.02em', lineHeight: 1.3 },
    h5: { fontWeight: 700, letterSpacing: '-0.015em' },
    h6: { fontWeight: 650, letterSpacing: '-0.01em' },
    subtitle1: { fontWeight: 600 },
    subtitle2: { fontWeight: 600 },
    body1: { lineHeight: 1.55 },
    body2: { lineHeight: 1.55 },
    button: { textTransform: 'none', fontWeight: 650, letterSpacing: 0 },
    caption: { lineHeight: 1.45 },
  },
  shape: { borderRadius: 12 },
  components: {
    MuiCssBaseline: {
      styleOverrides: {
        body: { backgroundColor: brand.canvas, color: brand.ink },
        '::selection': { backgroundColor: '#DCEFEA', color: brand.ink },
        ':focus-visible': { outline: `3px solid ${brand.accent}`, outlineOffset: 2 },
      },
    },
    MuiButton: {
      defaultProps: { disableElevation: true },
      styleOverrides: {
        root: { minHeight: 44, borderRadius: 10, paddingInline: 16, whiteSpace: 'nowrap' },
        sizeSmall: { minHeight: 38, paddingInline: 12 },
        containedPrimary: { '&:hover': { backgroundColor: brand.primaryDark } },
        outlined: { borderColor: '#CCD8DB', '&:hover': { borderColor: brand.primary, backgroundColor: '#F4FAF8' } },
      },
    },
    MuiIconButton: {
      styleOverrides: {
        root: { borderRadius: 10, '&:hover': { backgroundColor: '#EDF3F4' } },
      },
    },
    MuiCard: {
      styleOverrides: {
        root: { borderRadius: 16, border: `1px solid ${brand.line}`, boxShadow: '0 2px 8px rgba(23, 43, 53, 0.035)' },
      },
    },
    MuiCardContent: { styleOverrides: { root: { '&:last-child': { paddingBottom: 22 } } } },
    MuiPaper: {
      styleOverrides: {
        rounded: { borderRadius: 14 },
        elevation1: { boxShadow: '0 2px 8px rgba(23, 43, 53, 0.035)' },
      },
    },
    MuiTableContainer: {
      styleOverrides: {
        root: { width: '100%', maxWidth: '100%', overflowX: 'auto', overscrollBehaviorX: 'contain', WebkitOverflowScrolling: 'touch', borderRadius: 12 },
      },
    },
    MuiTableCell: {
      styleOverrides: {
        root: { borderColor: '#EAF0F1', padding: '13px 16px' },
        head: { fontWeight: 650, backgroundColor: '#F7F9FA', color: '#53666E', whiteSpace: 'nowrap' },
      },
    },
    MuiTableRow: { styleOverrides: { root: { '&:last-child td, &:last-child th': { borderBottom: 0 } } } },
    MuiTextField: { defaultProps: { size: 'medium', variant: 'outlined' } },
    MuiOutlinedInput: {
      styleOverrides: {
        root: { borderRadius: 10, backgroundColor: '#FFFFFF', '& .MuiOutlinedInput-notchedOutline': { borderColor: '#D8E1E3' }, '&:hover .MuiOutlinedInput-notchedOutline': { borderColor: '#9EAFB4' }, '&.Mui-focused .MuiOutlinedInput-notchedOutline': { borderWidth: 2 } },
        input: { minHeight: '1.35em' },
      },
    },
    MuiFormLabel: { styleOverrides: { root: { color: '#53666E', '&.Mui-focused': { color: brand.primary } } } },
    MuiSelect: { styleOverrides: { select: { minHeight: '1.35em', display: 'flex', alignItems: 'center' } } },
    MuiChip: { styleOverrides: { root: { fontWeight: 600, borderRadius: 8 }, sizeSmall: { height: 26 } } },
    MuiAlert: { styleOverrides: { root: { borderRadius: 12, alignItems: 'center' } } },
    MuiDialog: { styleOverrides: { paper: { borderRadius: 16, backgroundImage: 'none' } } },
    MuiMenu: { styleOverrides: { paper: { border: `1px solid ${brand.line}`, boxShadow: '0 12px 32px rgba(23, 43, 53, 0.12)' } } },
    MuiTabs: { styleOverrides: { indicator: { height: 3, borderRadius: 3 } } },
    MuiTab: { styleOverrides: { root: { minHeight: 48, textTransform: 'none', fontWeight: 600 } } },
    MuiTooltip: { styleOverrides: { tooltip: { borderRadius: 8, fontSize: 12, padding: '7px 10px' } } },
  },
});
