/* Shared chrome and helpers
   Exports: Header, Brand, ScreenWrap, Chip, Avatar, BrandMark,
            useTheme provider helpers */

const ThemeContext = React.createContext({ theme: 'light', toggle: () => {} });

function ThemeProvider({ theme, setTheme, accent, children }) {
  React.useEffect(() => {
    document.documentElement.dataset.theme = theme;
    document.documentElement.style.setProperty('--accent', accent);
    // Pick accent-ink based on the accent's lightness
    const ink = ['#c5f03a', '#ffd84a'].includes(accent.toLowerCase()) ? '#0a0a0a' : '#ffffff';
    document.documentElement.style.setProperty('--accent-ink', ink);
  }, [theme, accent]);
  return (
    <ThemeContext.Provider value={{ theme, setTheme }}>
      {children}
    </ThemeContext.Provider>
  );
}

function BrandMark({ size = 22 }) {
  // A geometric "scrawl" — zigzag mark
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <path
        d="M2 18 L7 6 L10 18 L14 6 L17 18 L22 6"
        stroke="currentColor"
        strokeWidth="2.4"
        strokeLinecap="square"
        strokeLinejoin="miter"
      />
    </svg>
  );
}

function Brand({ onClick }) {
  return (
    <div className="brand" onClick={onClick}>
      <BrandMark />
      <div className="brand-name">scrawly<em>v1</em></div>
    </div>
  );
}

function IconSun() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6">
      <circle cx="12" cy="12" r="4" />
      <path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41" strokeLinecap="round"/>
    </svg>
  );
}
function IconMoon() {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6">
      <path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z" strokeLinejoin="round"/>
    </svg>
  );
}
function IconPlus() {
  return <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8"><path d="M12 5v14M5 12h14" strokeLinecap="round"/></svg>;
}
function IconArrow() {
  return <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6"><path d="M5 12h14M13 6l6 6-6 6" strokeLinecap="round" strokeLinejoin="round"/></svg>;
}
function IconBack() {
  return <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6"><path d="M19 12H5M11 6l-6 6 6 6" strokeLinecap="round" strokeLinejoin="round"/></svg>;
}
function IconClose() {
  return <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6"><path d="M6 6l12 12M18 6L6 18" strokeLinecap="round"/></svg>;
}
function IconEye() {
  return <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8S1 12 1 12z" strokeLinejoin="round"/><circle cx="12" cy="12" r="3"/></svg>;
}
function IconUndo() {
  return <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6"><path d="M3 7h11a6 6 0 1 1 0 12H9" strokeLinecap="round" strokeLinejoin="round"/><path d="M7 3L3 7l4 4" strokeLinecap="round" strokeLinejoin="round"/></svg>;
}
function IconEraser() {
  return <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6"><path d="M3 21h18M7 17l8-8 5 5-8 8H7v-5z" strokeLinejoin="round" strokeLinecap="round"/></svg>;
}
function IconClear() {
  return <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6"><path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14" strokeLinejoin="round"/></svg>;
}

function Header({ route, navigate, user }) {
  const { theme, setTheme } = React.useContext(ThemeContext);
  const links = [
    { id: 'home', label: 'rooms' },
    { id: 'past', label: 'history' },
  ];
  return (
    <header className="app-header">
      <div className="app-header-inner">
        <div className="row" style={{ gap: 32 }}>
          <Brand onClick={() => navigate('home')} />
          <nav className="header-nav">
            {links.map(l => (
              <a key={l.id}
                 className={"header-link " + (route === l.id ? 'active' : '')}
                 onClick={() => navigate(l.id)}>
                {l.label}
              </a>
            ))}
            <a className="header-link" href="#" onClick={(e) => { e.preventDefault(); navigate('home'); }}>docs</a>
          </nav>
        </div>
        <div className="header-actions">
          <span className="chip mono">
            <span style={{ width: 6, height: 6, borderRadius: 999, background: 'var(--success)', display: 'inline-block' }}></span>
            247 online
          </span>
          <button className="icon-btn" title="Toggle theme"
                  onClick={() => setTheme(theme === 'dark' ? 'light' : 'dark')}>
            {theme === 'dark' ? <IconSun /> : <IconMoon />}
          </button>
          {user ? (
            <div className="user-chip">
              <span className="avatar">{user.username[0].toUpperCase()}</span>
              <span>{user.username}</span>
            </div>
          ) : (
            <React.Fragment>
              <button className="btn btn-ghost btn-sm">log in</button>
              <button className="btn btn-ink btn-sm">register</button>
            </React.Fragment>
          )}
        </div>
      </div>
    </header>
  );
}

// utility: random-looking demo path generator (deterministic by seed)
function seededPath(seed, cx, cy, scale = 1) {
  let s = seed;
  const r = () => { s = (s * 9301 + 49297) % 233280; return s / 233280; };
  const points = [];
  const n = 12;
  for (let i = 0; i < n; i++) {
    const a = (i / n) * Math.PI * 2 + r() * 0.4;
    const rad = (40 + r() * 30) * scale;
    points.push([cx + Math.cos(a) * rad, cy + Math.sin(a) * rad]);
  }
  return 'M ' + points.map(p => p.join(' ')).join(' L ');
}

Object.assign(window, {
  ThemeContext, ThemeProvider, Header, Brand, BrandMark,
  IconSun, IconMoon, IconPlus, IconArrow, IconBack, IconClose, IconEye, IconUndo, IconEraser, IconClear,
  seededPath,
});
