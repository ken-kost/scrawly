/* Home / lobby screen + create-room modal + animated demo canvas */

function DemoCanvas() {
  // Cycle through a small set of pre-baked drawings.
  // Each "drawing" is a list of stroke definitions; we reveal the strokes
  // progressively and along each stroke we mask the path so it appears to
  // draw in real time. This keeps the "demo is running" behavior intact
  // while sitting inside the new chrome.
  const DRAWINGS = React.useMemo(() => ([
    {
      word: 'cactus',
      strokes: [
        { d: 'M 200 230 C 200 130 240 80 240 230', color: '#2b8c3a', w: 4 },
        { d: 'M 230 180 C 200 180 180 150 170 130 C 165 120 170 110 180 115 C 195 120 220 140 230 170', color: '#2b8c3a', w: 4 },
        { d: 'M 250 200 C 280 200 290 170 295 145 C 297 135 290 130 285 138 C 275 152 260 175 250 195', color: '#2b8c3a', w: 4 },
        { d: 'M 175 230 L 270 230 L 270 252 L 175 252 Z', color: '#8a5a2b', w: 3 },
        { d: 'M 195 75 Q 220 65 240 70', color: '#ef5bff', w: 3 },
      ],
      guesses: [
        { who: 'koen', body: 'tree?' },
        { who: 'noor', body: 'aloe' },
        { who: 'yves', body: 'cactus', correct: true },
      ],
    },
    {
      word: 'bicycle',
      strokes: [
        { d: 'M 130 230 m -45 0 a 45 45 0 1 0 90 0 a 45 45 0 1 0 -90 0', color: '#111', w: 3 },
        { d: 'M 280 230 m -45 0 a 45 45 0 1 0 90 0 a 45 45 0 1 0 -90 0', color: '#111', w: 3 },
        { d: 'M 130 230 L 200 160 L 280 230 M 200 160 L 220 230 M 200 160 L 190 130 L 215 128', color: '#111', w: 3 },
      ],
      guesses: [
        { who: 'astra', body: 'wheels?' },
        { who: 'mira', body: 'bicycle', correct: true },
      ],
    },
    {
      word: 'lighthouse',
      strokes: [
        { d: 'M 180 80 L 240 80 L 250 240 L 170 240 Z', color: '#111', w: 3 },
        { d: 'M 170 240 L 260 240', color: '#111', w: 4 },
        { d: 'M 195 80 L 195 240 M 225 80 L 225 240', color: '#d63838', w: 3 },
        { d: 'M 170 75 L 250 75 L 260 60 L 160 60 Z', color: '#111', w: 3 },
        { d: 'M 170 60 L 175 30 L 245 30 L 250 60', color: '#111', w: 3 },
        { d: 'M 200 30 L 220 30 L 220 8 L 200 8 Z', color: '#111', w: 3 },
        { d: 'M 90 200 Q 130 195 170 205 M 250 205 Q 290 195 330 200', color: '#7ad6ff', w: 3 },
      ],
      guesses: [
        { who: 'lin', body: 'a tower?' },
        { who: 'koen', body: 'lighthouse', correct: true },
      ],
    },
  ]), []);

  const [drawIdx, setDrawIdx] = React.useState(0);
  const [strokeIdx, setStrokeIdx] = React.useState(0); // # of fully drawn strokes
  const [progress, setProgress] = React.useState(0); // 0..1 for current stroke
  const [phase, setPhase] = React.useState('draw'); // 'draw' | 'reveal'
  const [visibleGuesses, setVisibleGuesses] = React.useState([]);

  const cur = DRAWINGS[drawIdx];

  React.useEffect(() => {
    if (phase !== 'draw') return;
    if (strokeIdx >= cur.strokes.length) {
      // reveal phase: show correct answer briefly
      setVisibleGuesses(cur.guesses);
      setPhase('reveal');
      const t = setTimeout(() => {
        setDrawIdx((i) => (i + 1) % DRAWINGS.length);
        setStrokeIdx(0);
        setProgress(0);
        setVisibleGuesses([]);
        setPhase('draw');
      }, 2800);
      return () => clearTimeout(t);
    }
    // Draw current stroke
    const speed = 0.03; // per tick
    const tick = setInterval(() => {
      setProgress((p) => {
        if (p >= 1) {
          // schedule next stroke
          return 1;
        }
        return Math.min(1, p + speed);
      });
    }, 30);
    return () => clearInterval(tick);
  }, [phase, strokeIdx, drawIdx]);

  React.useEffect(() => {
    if (progress >= 1 && phase === 'draw') {
      // Add a guess as we move along, if available
      const idx = strokeIdx;
      // Reveal a non-correct guess after specific strokes
      const wrongGuesses = cur.guesses.filter((g) => !g.correct);
      const showAt = Math.max(1, Math.floor(cur.strokes.length / (wrongGuesses.length + 1)));
      if (idx > 0 && idx % showAt === 0 && visibleGuesses.length < wrongGuesses.length) {
        setVisibleGuesses((vg) => {
          const next = wrongGuesses[vg.length];
          return next ? [...vg, next] : vg;
        });
      }
      const t = setTimeout(() => {
        setStrokeIdx((i) => i + 1);
        setProgress(0);
      }, 250);
      return () => clearTimeout(t);
    }
  }, [progress]);

  const wordMask = cur.word.split('').map((ch) => (ch === ' ' ? '\u00A0\u00A0' : '_')).join(' ');

  return (
    <div className="surface" style={{ overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
      <div className="between" style={{ padding: '12px 14px', borderBottom: '1px solid var(--hairline)' }}>
        <div className="row" style={{ gap: 10 }}>
          <span className="chip chip-live">live demo</span>
          <span className="section-label">drawer · mira</span>
        </div>
        <div className="word-letters" style={{ fontSize: 14, letterSpacing: '0.3em' }}>
          {phase === 'reveal' ? cur.word.toUpperCase() : wordMask}
        </div>
        <span className="mono" style={{ fontSize: 12, color: 'var(--muted)' }}>{cur.word.length} letters</span>
      </div>
      <div className="demo-canvas" style={{ aspectRatio: '16/9' }}>
        <svg viewBox="0 0 420 260" preserveAspectRatio="xMidYMid meet">
          <defs>
            <pattern id="dotgrid" x="0" y="0" width="14" height="14" patternUnits="userSpaceOnUse">
              <circle cx="1" cy="1" r="0.6" fill="rgba(0,0,0,0.06)" />
            </pattern>
          </defs>
          <rect width="420" height="260" fill="url(#dotgrid)" />
          {cur.strokes.map((s, i) => {
            if (i > strokeIdx) return null;
            if (i < strokeIdx) {
              return <path key={i} d={s.d} stroke={s.color} strokeWidth={s.w} fill="none" strokeLinecap="round" strokeLinejoin="round" />;
            }
            // current stroke — animate with strokeDasharray trick
            return (
              <path key={i} d={s.d} stroke={s.color} strokeWidth={s.w} fill="none" strokeLinecap="round" strokeLinejoin="round"
                    pathLength="1" strokeDasharray="1 1" strokeDashoffset={1 - progress} />
            );
          })}
        </svg>
        <div className="demo-overlay">
          <div className="col" style={{ gap: 6, alignItems: 'flex-start' }}>
            {visibleGuesses.map((g, i) => (
              <span key={i} className={"demo-tag " + (g.correct ? 'right' : '')}>
                {g.who}: {g.body} {g.correct ? '✓' : ''}
              </span>
            ))}
          </div>
        </div>
      </div>
      <div className="between" style={{ padding: '10px 14px' }}>
        <span className="section-label">try it — drag on the canvas above</span>
        <span className="mono" style={{ fontSize: 12, color: 'var(--muted)' }}>
          {phase === 'reveal' ? 'next round in 3s' : 'drawing...'}
        </span>
      </div>
    </div>
  );
}

/* ─── Room row ─────────────────────────────────────────────────── */
function RoomRow({ room, idx, onJoin }) {
  return (
    <div className="room-row" onClick={onJoin}>
      <span className="room-num mono">{String(idx + 1).padStart(2, '0')}</span>
      <div className="room-title">
        <span className="name">{room.name}</span>
        <span className="meta">
          <span>[{room.code}]</span>
          <span>{room.source === 'ai' ? '[ai]' : '[local]'}</span>
          <span>{room.round_duration}s × {room.rounds}r</span>
        </span>
      </div>
      <div className="avatar-stack">
        {Array.from({ length: Math.min(room.players, 4) }).map((_, i) => (
          <span key={i} className={"avatar " + (i === 0 ? 'accent' : '')}>{String.fromCharCode(65 + ((i + idx * 3) % 26))}</span>
        ))}
        {room.players > 4 && <span className="avatar" style={{ background: 'transparent', color: 'var(--muted)' }}>+{room.players - 4}</span>}
      </div>
      <span className="mono" style={{ fontSize: 12, color: 'var(--muted)', minWidth: 60, textAlign: 'right' }}>
        {room.players}/{room.max}
      </span>
      <span className={"chip " + (room.status === 'live' ? 'chip-live' : 'chip-strong')}>
        {room.status === 'live' ? 'live' : 'lobby'}
      </span>
    </div>
  );
}

function CreateRoomModal({ onClose, onCreate }) {
  const [name, setName] = React.useState('');
  const [maxP, setMaxP] = React.useState(8);
  const [src, setSrc] = React.useState('local');
  const [prompt, setPrompt] = React.useState('');
  const [wc, setWc] = React.useState(1);
  const [rounds, setRounds] = React.useState(2);
  const [dur, setDur] = React.useState(60);
  const [tone, setTone] = React.useState('fun');

  return (
    <div className="scrim" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <div>
            <h3>New room</h3>
            <div className="sub">configure how the round runs.</div>
          </div>
          <button className="icon-btn" onClick={onClose}><IconClose /></button>
        </div>
        <div className="modal-body">
          <div>
            <label className="field-label">name</label>
            <input className="input" placeholder="e.g. late night doodles"
                   value={name} onChange={(e) => setName(e.target.value)} />
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            <div>
              <label className="field-label">max players</label>
              <input className="input mono" type="number" min="2" max="12"
                     value={maxP} onChange={(e) => setMaxP(+e.target.value)} />
            </div>
            <div>
              <label className="field-label">words / round</label>
              <div className="seg">
                {[1, 2, 3].map(n => (
                  <button key={n} className={wc === n ? 'active' : ''} onClick={() => setWc(n)}>{n}</button>
                ))}
              </div>
            </div>
          </div>

          <div>
            <label className="field-label">word source</label>
            <div className="seg">
              <button className={src === 'local' ? 'active' : ''} onClick={() => setSrc('local')}>local list</button>
              <button className={src === 'ai' ? 'active' : ''} onClick={() => setSrc('ai')}>ai generated</button>
            </div>
          </div>

          {src === 'ai' && (
            <React.Fragment>
              <div>
                <label className="field-label">theme prompt</label>
                <input className="input" placeholder="ocean animals, things in a kitchen..."
                       value={prompt} onChange={(e) => setPrompt(e.target.value)} />
              </div>
              <div>
                <label className="field-label">tone</label>
                <div className="seg">
                  {['fun', 'creative', 'weird'].map(t => (
                    <button key={t} className={tone === t ? 'active' : ''} onClick={() => setTone(t)}>{t}</button>
                  ))}
                </div>
              </div>
            </React.Fragment>
          )}

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            <div>
              <label className="field-label">rounds / player</label>
              <div className="seg">
                {[1, 2, 3, 5].map(r => (
                  <button key={r} className={rounds === r ? 'active' : ''} onClick={() => setRounds(r)}>{r}×</button>
                ))}
              </div>
            </div>
            <div>
              <label className="field-label">duration</label>
              <div className="seg">
                {[{ v: 60, l: '60s' }, { v: 120, l: '2m' }, { v: 300, l: '5m' }].map(d => (
                  <button key={d.v} className={dur === d.v ? 'active' : ''} onClick={() => setDur(d.v)}>{d.l}</button>
                ))}
              </div>
            </div>
          </div>
        </div>
        <div className="modal-foot">
          <button className="btn btn-ghost" onClick={onClose}>cancel</button>
          <button className="btn btn-primary" onClick={onCreate}>create room <IconArrow /></button>
        </div>
      </div>
    </div>
  );
}

function HomePage({ navigate, user, setShowAuth }) {
  const [showCreate, setShowCreate] = React.useState(false);
  const liveCount = SAMPLE_ROOMS.filter(r => r.status === 'live').length;
  const lobbyCount = SAMPLE_ROOMS.filter(r => r.status === 'lobby').length;

  return (
    <div className="page">
      <section className="hero">
        <div>
          <h1>draw.<span className="slash">/</span>guess.<br/>quietly.</h1>
          <p className="sub" style={{ marginTop: 16 }}>
            a pen, a word, sixty seconds. scrawly is a small online game
            where one person draws and everyone else races to name it.
          </p>
          <div className="row" style={{ gap: 8, marginTop: 24 }}>
            <button className="btn btn-primary btn-lg"
                    onClick={() => user ? setShowCreate(true) : setShowAuth(true)}>
              <IconPlus /> create a room
            </button>
            <button className="btn btn-lg" onClick={() => navigate('game-lobby')}>
              join the demo
            </button>
            <span className="mono" style={{ fontSize: 12, color: 'var(--muted)', marginLeft: 8 }}>
              press <span className="kbd">N</span> for new
            </span>
          </div>
        </div>
        <div className="meta">
          <div className="section-label">today</div>
          <div className="big">{liveCount + lobbyCount} <span style={{ color: 'var(--muted)', fontSize: 12 }}>rooms</span></div>
          <div className="v" style={{ marginTop: 6 }}>{liveCount} live · {lobbyCount} lobby</div>
        </div>
      </section>

      <div style={{ display: 'grid', gridTemplateColumns: '1.1fr 1fr', gap: 32, marginTop: 8 }}>
        <div>
          <div className="section-header">
            <h2>open rooms</h2>
            <div className="row" style={{ gap: 6 }}>
              <span className="mono" style={{ fontSize: 11, color: 'var(--muted)' }}>updated 2s ago</span>
              <button className="btn btn-ghost btn-sm">refresh</button>
            </div>
          </div>
          <div className="room-list">
            {SAMPLE_ROOMS.map((r, i) => (
              <RoomRow key={r.id} room={r} idx={i}
                       onJoin={() => navigate(r.status === 'live' ? 'game' : 'game-lobby')} />
            ))}
            <div style={{ padding: '16px 8px', color: 'var(--muted)', fontSize: 12 }} className="mono">
              showing {SAMPLE_ROOMS.length} of {SAMPLE_ROOMS.length} · <a href="#" style={{ color: 'var(--ink)' }}>filter →</a>
            </div>
          </div>
        </div>
        <div>
          <div className="section-header">
            <h2>demo</h2>
            <span className="mono" style={{ fontSize: 11, color: 'var(--muted)' }}>auto-playing recent rounds</span>
          </div>
          <DemoCanvas />
          <div style={{ marginTop: 16, padding: 16, border: '1px solid var(--hairline)', borderRadius: 8 }}>
            <div className="section-label">how it works</div>
            <ol style={{ margin: '12px 0 0', paddingLeft: 18, color: 'var(--muted)', fontSize: 13, lineHeight: 1.65 }}>
              <li>one player draws the word, no typing allowed.</li>
              <li>everyone else guesses in chat. fastest correct gets the most points.</li>
              <li>after 60s, roles rotate. play three rounds, see who comes out on top.</li>
            </ol>
          </div>
        </div>
      </div>

      {showCreate && <CreateRoomModal onClose={() => setShowCreate(false)}
                                      onCreate={() => { setShowCreate(false); navigate('game-lobby'); }} />}
    </div>
  );
}

window.HomePage = HomePage;
window.DemoCanvas = DemoCanvas;
