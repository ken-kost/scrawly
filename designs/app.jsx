/* App shell: routing, theme, tweaks, auth modal */

function AuthModal({ onClose, onAuth }) {
  const [mode, setMode] = React.useState('login');
  const [email, setEmail] = React.useState('');
  const [password, setPassword] = React.useState('');
  return (
    <div className="scrim" onClick={onClose}>
      <div className="modal" style={{ maxWidth: 400 }} onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <div>
            <h3>{mode === 'login' ? 'log in' : 'register'}</h3>
            <div className="sub">{mode === 'login' ? 'welcome back.' : "let's get you a handle."}</div>
          </div>
          <button className="icon-btn" onClick={onClose}><IconClose /></button>
        </div>
        <div className="modal-body">
          <div>
            <label className="field-label">email</label>
            <input className="input" type="email" value={email}
                   onChange={(e) => setEmail(e.target.value)}
                   placeholder="you@example.com" />
          </div>
          <div>
            <label className="field-label">password</label>
            <input className="input" type="password" value={password}
                   onChange={(e) => setPassword(e.target.value)}
                   placeholder="••••••••" />
          </div>
        </div>
        <div className="modal-foot" style={{ flexDirection: 'column', alignItems: 'stretch' }}>
          <button className="btn btn-primary" style={{ width: '100%' }}
                  onClick={() => onAuth({ username: (email.split('@')[0] || 'you'), email })}>
            {mode === 'login' ? 'log in' : 'create account'} <IconArrow />
          </button>
          <div className="mono" style={{ fontSize: 11, color: 'var(--muted)', textAlign: 'center' }}>
            {mode === 'login'
              ? <span>no account? <a href="#" onClick={(e) => { e.preventDefault(); setMode('register'); }} style={{ color: 'var(--ink)' }}>register</a></span>
              : <span>have an account? <a href="#" onClick={(e) => { e.preventDefault(); setMode('login'); }} style={{ color: 'var(--ink)' }}>log in</a></span>}
          </div>
        </div>
      </div>
    </div>
  );
}

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "theme": "light",
  "accent": "#c5f03a",
  "screen": "home",
  "role": "drawer"
}/*EDITMODE-END*/;

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const [route, setRoute] = React.useState(t.screen || 'home');
  const [user, setUser] = React.useState({ username: 'you' });
  const [showAuth, setShowAuth] = React.useState(false);

  // Sync screen tweak → route
  React.useEffect(() => {
    if (t.screen && t.screen !== route) setRoute(t.screen);
  }, [t.screen]);

  const navigate = (r) => {
    setRoute(r);
    setTweak('screen', r);
  };

  let body;
  if (route === 'home') body = <HomePage navigate={navigate} user={user} setShowAuth={setShowAuth} />;
  else if (route === 'game-lobby') body = <GameLobbyPage navigate={navigate} user={user} />;
  else if (route === 'game') body = <GamePage navigate={navigate} user={user} asDrawer={t.role === 'drawer'} />;
  else if (route === 'score') body = <ScorePage navigate={navigate} user={user} />;
  else if (route === 'past') body = <PastGamesPage navigate={navigate} user={user} />;
  else body = <HomePage navigate={navigate} user={user} setShowAuth={setShowAuth} />;

  return (
    <ThemeProvider theme={t.theme} accent={t.accent} setTheme={(v) => setTweak('theme', v)}>
      <Header route={route} navigate={navigate} user={user} />
      {body}
      {showAuth && <AuthModal onClose={() => setShowAuth(false)}
                              onAuth={(u) => { setUser(u); setShowAuth(false); }} />}

      <TweaksPanel title="Tweaks">
        <TweakSection label="appearance">
          <TweakRadio
            label="theme"
            value={t.theme} onChange={(v) => setTweak('theme', v)}
            options={[{ value: 'light', label: 'light' }, { value: 'dark', label: 'dark' }]} />
          <TweakColor
            label="accent"
            value={t.accent} onChange={(v) => setTweak('accent', v)}
            options={['#c5f03a', '#ff5c2b', '#2a6df4', '#ef5bff']} />
        </TweakSection>
        <TweakSection label="navigate">
          <TweakSelect
            label="screen"
            value={t.screen} onChange={(v) => setTweak('screen', v)}
            options={[
              { value: 'home', label: 'home / lobby' },
              { value: 'game-lobby', label: 'waiting room' },
              { value: 'game', label: 'active game' },
              { value: 'score', label: 'score / results' },
              { value: 'past', label: 'past games' },
            ]} />
          {route === 'game' && (
            <TweakRadio
              label="role"
              value={t.role} onChange={(v) => setTweak('role', v)}
              options={[{ value: 'drawer', label: 'drawing' }, { value: 'guesser', label: 'guessing' }]} />
          )}
        </TweakSection>
      </TweaksPanel>
    </ThemeProvider>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
