/* Game lobby (waiting room) + Active game (canvas, tools, chat) */

function GameLobbyPage({ navigate, user }) {
  const players = SAMPLE_PLAYERS.slice(0, 5);
  const watchers = [{ username: 'tom' }, { username: 'sasha' }];

  return (
    <div className="page page-mid">
      <div className="row" style={{ marginBottom: 24 }}>
        <button className="btn btn-ghost btn-sm" onClick={() => navigate('home')}>
          <IconBack /> back to rooms
        </button>
        <span className="mono" style={{ fontSize: 11, color: 'var(--muted)', marginLeft: 8 }}>
          room · kitchen things
        </span>
      </div>

      <div className="lobby-grid">
        <div className="surface lobby-panel">
          <div className="between" style={{ alignItems: 'flex-start', marginBottom: 16 }}>
            <div>
              <h1 className="lobby-title">kitchen things</h1>
              <div className="lobby-sub">waiting for the host to start the game</div>
            </div>
            <span className="chip chip-strong">lobby</span>
          </div>

          <div className="lobby-code" style={{ marginBottom: 24 }}>
            <span className="label">code</span>
            <span className="code">K7P2</span>
            <button className="btn btn-ghost btn-sm" style={{ marginLeft: 'auto' }}>copy</button>
          </div>

          <div className="section-label" style={{ marginBottom: 10 }}>players · {players.length}/8</div>
          <div className="player-list">
            {players.map((p, i) => (
              <div key={p.id} className="player-row">
                <span className="av" style={{ background: p.color, color: '#0a0a0a' }}>
                  {p.username[0].toUpperCase()}
                </span>
                <span className="name">{p.username}</span>
                {i === 0 && <span className="chip chip-accent">host</span>}
                {p.username === (user && user.username) && <span className="chip chip-strong">you</span>}
                <span className="tag">{i === 0 ? 'ready' : 'ready'}</span>
              </div>
            ))}
            {Array.from({ length: 3 }).map((_, i) => (
              <div key={i} className="player-row" style={{ opacity: 0.5 }}>
                <span className="av" style={{ background: 'transparent', border: '1px dashed var(--hairline-2)', color: 'var(--muted)' }}>·</span>
                <span className="name" style={{ color: 'var(--muted)' }}>open slot</span>
                <span className="tag">empty</span>
              </div>
            ))}
          </div>

          <div className="row" style={{ marginTop: 24, gap: 8 }}>
            <button className="btn btn-primary btn-lg" style={{ flex: 1 }}
                    onClick={() => navigate('game')}>
              start game <IconArrow />
            </button>
            <button className="btn btn-lg" onClick={() => navigate('home')}>leave</button>
          </div>
          <div className="mono" style={{ fontSize: 11, color: 'var(--muted)', marginTop: 10, textAlign: 'center' }}>
            need at least 2 players · share the code to invite friends
          </div>
        </div>

        <div>
          <div className="surface" style={{ overflow: 'hidden' }}>
            <div className="panel-head">settings</div>
            <div className="spec-grid">
              <div className="spec"><div className="k">word source</div><div className="v">[ai]</div></div>
              <div className="spec"><div className="k">words / round</div><div className="v">1</div></div>
              <div className="spec"><div className="k">duration</div><div className="v">60s</div></div>
              <div className="spec"><div className="k">rounds / player</div><div className="v">3×</div></div>
              <div className="spec" style={{ gridColumn: '1 / -1', borderRight: 0 }}>
                <div className="k">prompt</div>
                <div className="v" style={{ fontSize: 14, color: 'var(--ink-2)' }}>things in a kitchen</div>
              </div>
            </div>
          </div>

          {watchers.length > 0 && (
            <div className="surface" style={{ marginTop: 16, padding: 16 }}>
              <div className="row" style={{ marginBottom: 10 }}>
                <span className="section-label">watching · {watchers.length}</span>
                <span className="mono" style={{ fontSize: 11, color: 'var(--muted)', marginLeft: 'auto' }}>
                  spectators don't score
                </span>
              </div>
              <div className="row" style={{ flexWrap: 'wrap', gap: 6 }}>
                {watchers.map((w, i) => (
                  <span key={i} className="chip"><IconEye /> {w.username}</span>
                ))}
              </div>
            </div>
          )}

          <div style={{ marginTop: 16, padding: 16, border: '1px dashed var(--hairline-2)', borderRadius: 8 }}>
            <div className="section-label" style={{ marginBottom: 8 }}>last round here</div>
            <div className="mono" style={{ fontSize: 12, color: 'var(--muted)', lineHeight: 1.7 }}>
              May 14, 2026 · 14:08 · 3 rounds<br />
              winner: <span style={{ color: 'var(--ink)' }}>mira</span> with 412 pts<br />
              <a href="#" onClick={(e) => { e.preventDefault(); navigate('score'); }} style={{ color: 'var(--ink)', textDecoration: 'underline' }}>view results →</a>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

/* ─── Active game ────────────────────────────────────────────────── */

function CanvasArea({ isDrawer, color, width }) {
  // Static showcase strokes so the canvas looks live and the drawing surface
  // is visible. The actual drawing logic in the production app uses SVG
  // strokes — we mirror that shape here.
  const STROKES = [
    { d: 'M 200 240 L 200 130 C 200 80 280 60 320 100 C 360 140 360 200 340 230', color: '#0a0a0a', w: 3 },
    { d: 'M 340 230 L 460 230', color: '#0a0a0a', w: 3 },
    { d: 'M 460 230 L 460 130 C 460 80 540 60 580 100', color: '#0a0a0a', w: 3 },
    { d: 'M 280 160 Q 320 145 360 165', color: '#0a0a0a', w: 2 },
    { d: 'M 290 175 Q 315 170 335 180', color: '#0a0a0a', w: 2 },
    { d: 'M 100 280 L 700 280', color: '#0a0a0a', w: 4 },
    { d: 'M 540 110 C 560 90 600 90 620 110 C 640 130 640 170 620 190', color: '#d63838', w: 3 },
  ];

  const [activePath, setActivePath] = React.useState('');
  const [drawing, setDrawing] = React.useState(false);
  const [userStrokes, setUserStrokes] = React.useState([]);

  const ref = React.useRef(null);

  const point = (e) => {
    const r = ref.current.getBoundingClientRect();
    const x = ((e.clientX - r.left) / r.width) * 800;
    const y = ((e.clientY - r.top) / r.height) * 450;
    return [x.toFixed(1), y.toFixed(1)];
  };

  const down = (e) => {
    if (!isDrawer) return;
    const [x, y] = point(e);
    setDrawing(true);
    setActivePath(`M ${x} ${y}`);
  };
  const move = (e) => {
    if (!drawing) return;
    const [x, y] = point(e);
    setActivePath((p) => `${p} L ${x} ${y}`);
  };
  const up = () => {
    if (!drawing) return;
    setDrawing(false);
    if (activePath.length > 10) {
      setUserStrokes((s) => [...s, { d: activePath, color, w: width }]);
    }
    setActivePath('');
  };

  return (
    <div className="canvas-frame" ref={ref}
         onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerLeave={up}
         style={{ cursor: isDrawer ? 'crosshair' : 'default' }}>
      <svg viewBox="0 0 800 450" preserveAspectRatio="xMidYMid meet">
        <defs>
          <pattern id="cv-grid" x="0" y="0" width="20" height="20" patternUnits="userSpaceOnUse">
            <circle cx="1" cy="1" r="0.5" fill="rgba(0,0,0,0.05)" />
          </pattern>
        </defs>
        <rect width="800" height="450" fill="url(#cv-grid)" />
        {STROKES.map((s, i) => (
          <path key={i} d={s.d} stroke={s.color} strokeWidth={s.w} fill="none"
                strokeLinecap="round" strokeLinejoin="round" />
        ))}
        {userStrokes.map((s, i) => (
          <path key={'u' + i} d={s.d} stroke={s.color} strokeWidth={s.w} fill="none"
                strokeLinecap="round" strokeLinejoin="round" />
        ))}
        {activePath && (
          <path d={activePath} stroke={color} strokeWidth={width} fill="none"
                strokeLinecap="round" strokeLinejoin="round" />
        )}
      </svg>
    </div>
  );
}

function Scoreboard({ players, drawerId }) {
  return (
    <div className="scoreboard">
      {players.map((p, i) => (
        <div key={p.id} className={"item " + (p.id === drawerId ? 'drawing' : '')}>
          <span className="rank">{String(i + 1).padStart(2, '0')}</span>
          <span className="nm">
            <span style={{ width: 8, height: 8, borderRadius: 999, background: p.color, display: 'inline-block' }}></span>
            {p.username}
            {p.id === drawerId && <span className="chip chip-strong" style={{ marginLeft: 4 }}>drawing</span>}
            {p.guessed && p.id !== drawerId && <span className="guessed mono" style={{ fontSize: 11 }}>✓</span>}
          </span>
          <span className="pts">{p.score}</span>
        </div>
      ))}
    </div>
  );
}

function ChatPanel({ user, isDrawer }) {
  const [draft, setDraft] = React.useState('');
  const [messages, setMessages] = React.useState(SAMPLE_CHAT);
  const endRef = React.useRef(null);
  React.useEffect(() => {
    if (endRef.current) endRef.current.scrollTop = endRef.current.scrollHeight;
  }, [messages]);

  const submit = (e) => {
    e.preventDefault();
    if (!draft.trim()) return;
    setMessages((m) => [...m, { type: 'chat', who: user ? user.username : 'you', body: draft.trim() }]);
    setDraft('');
  };

  return (
    <div className="panel chat">
      <div className="panel-head">
        <span>chat · {messages.length} messages</span>
        <span className="mono" style={{ color: 'var(--muted)' }}>type to guess</span>
      </div>
      <div className="panel-body" ref={endRef}>
        {messages.map((m, i) => {
          if (m.type === 'system') {
            return <div key={i} className="msg system">→ {m.body}</div>;
          }
          if (m.type === 'correct') {
            return (
              <div key={i} className="msg correct">
                <span className="who">{m.who}</span>
                <span>guessed it</span>
              </div>
            );
          }
          if (m.type === 'close') {
            return (
              <div key={i} className="msg close">
                <span className="who">{m.who}</span>
                <span>{m.body}</span>
                <span className="mono" style={{ marginLeft: 'auto', fontSize: 11, color: 'var(--muted)' }}>close</span>
              </div>
            );
          }
          return (
            <div key={i} className="msg">
              <span className={"who " + (user && m.who === user.username ? 'me' : '')}>{m.who}</span>
              <span>{m.body}</span>
            </div>
          );
        })}
      </div>
      <form className="chat-input" onSubmit={submit}>
        <input placeholder={isDrawer ? 'you are drawing — chat disabled' : 'type a guess...'}
               value={draft} disabled={isDrawer}
               onChange={(e) => setDraft(e.target.value)} />
        <button className="btn btn-sm" type="submit" disabled={isDrawer || !draft.trim()}>send</button>
      </form>
    </div>
  );
}

function Timer({ value, total }) {
  const pct = Math.max(0, value / total) * 100;
  return (
    <div className="col" style={{ alignItems: 'center', gap: 4 }}>
      <div className="timer timer-big mono">{value}s</div>
      <div className="bar accent" style={{ width: 80 }}><div style={{ width: pct + '%' }}></div></div>
    </div>
  );
}

function GamePage({ navigate, user, asDrawer }) {
  const totalRounds = 6;
  const round = 3;
  const [timeLeft, setTimeLeft] = React.useState(42);
  React.useEffect(() => {
    const t = setInterval(() => setTimeLeft((v) => (v <= 0 ? 60 : v - 1)), 1000);
    return () => clearInterval(t);
  }, []);

  const drawerId = 'u1';
  const isDrawer = asDrawer;

  const [color, setColor] = React.useState('#0a0a0a');
  const [width, setWidth] = React.useState(3);
  const [eraser, setEraser] = React.useState(false);

  const word = 'helicopter';
  const reveal = ['h','_','_','i','_','_','_','_','e','_']; // partial mask

  return (
    <div>
      <div className="game-bar">
        <div className="game-bar-inner">
          <div className="left">
            <button className="btn btn-ghost btn-sm" onClick={() => navigate('home')}>
              <IconBack /> leave
            </button>
            <span className="section-label">kitchen things · K7P2</span>
            <span className="chip chip-live">live</span>
          </div>
          <div className="word-display">
            <div className="word-letters">
              {(isDrawer ? word.split('') : reveal).join(' ').toUpperCase()}
            </div>
            <div className="word-meta">
              {isDrawer ? `your word · ${word.length} letters` : `round ${round} of ${totalRounds} · ${word.length} letters`}
            </div>
          </div>
          <div className="right">
            <div>
              {Array.from({ length: totalRounds }).map((_, i) => (
                <span key={i} className={"round-pip " + (i < round - 1 ? 'on' : i === round - 1 ? 'now' : '')}></span>
              ))}
            </div>
            <Timer value={timeLeft} total={60} />
          </div>
        </div>
      </div>

      <div className="game-layout">
        <div className="panel">
          <div className="panel-head">
            <span>scores</span>
            <span className="mono">round {round}/{totalRounds}</span>
          </div>
          <div className="panel-body" style={{ padding: 0 }}>
            <Scoreboard players={SAMPLE_SCORES} drawerId={drawerId} />
          </div>
        </div>

        <div className="canvas-shell">
          <div className="between" style={{ padding: '10px 14px', borderBottom: '1px solid var(--hairline)' }}>
            <div className="row" style={{ gap: 8 }}>
              <span className="avatar" style={{ width: 22, height: 22, borderRadius: 999, background: '#c5f03a', color: '#0a0a0a', display: 'grid', placeItems: 'center', fontSize: 11, fontWeight: 600 }}>M</span>
              <span style={{ fontSize: 13, fontWeight: 500 }}>mira</span>
              <span className="mono" style={{ fontSize: 11, color: 'var(--muted)' }}>is drawing</span>
            </div>
            <span className="mono" style={{ fontSize: 11, color: 'var(--muted)' }}>
              {isDrawer ? 'your turn — draw the word above' : 'guess in chat → →'}
            </span>
          </div>

          <CanvasArea isDrawer={isDrawer} color={eraser ? '#ffffff' : color} width={eraser ? 18 : width} />

          {isDrawer && (
            <div className="toolbar">
              <div className="swatches">
                {['#0a0a0a', '#d63838', '#2a6df4', '#1f9a4a', '#eab308', '#f97316', '#a855f7', '#ec4899'].map(c => (
                  <button key={c} className={"swatch " + (color === c && !eraser ? 'active' : '')}
                          style={{ background: c }} onClick={() => { setColor(c); setEraser(false); }}></button>
                ))}
              </div>
              <div className="tool-group">
                {[{ v: 2, s: 4 }, { v: 4, s: 6 }, { v: 8, s: 10 }, { v: 14, s: 14 }].map(t => (
                  <button key={t.v} className={"tool-btn " + (width === t.v && !eraser ? 'active' : '')}
                          onClick={() => { setWidth(t.v); setEraser(false); }}>
                    <span className="size-dot" style={{ width: t.s, height: t.s }}></span>
                  </button>
                ))}
              </div>
              <div className="tool-group">
                <button className={"tool-btn " + (eraser ? 'active' : '')} onClick={() => setEraser(e => !e)}>
                  <IconEraser /> erase
                </button>
                <button className="tool-btn"><IconUndo /> undo</button>
                <button className="tool-btn"><IconClear /> clear</button>
              </div>
              <span className="mono" style={{ fontSize: 11, color: 'var(--muted)', marginLeft: 'auto' }}>
                shortcut: <span className="kbd">[</span><span className="kbd">]</span> size · <span className="kbd">⌘Z</span> undo
              </span>
            </div>
          )}

          {!isDrawer && (
            <div className="toolbar" style={{ justifyContent: 'space-between' }}>
              <div className="row" style={{ gap: 8 }}>
                <span className="chip">spectator tools are disabled</span>
              </div>
              <span className="mono" style={{ fontSize: 11, color: 'var(--muted)' }}>
                fastest correct guess = +60 · hint reveals every 20s
              </span>
            </div>
          )}
        </div>

        <ChatPanel user={user} isDrawer={isDrawer} />
      </div>
    </div>
  );
}

window.GameLobbyPage = GameLobbyPage;
window.GamePage = GamePage;
