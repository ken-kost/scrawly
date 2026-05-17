/* Score page + Past games table */

function MiniDrawing({ seed }) {
  // deterministic squiggle so each round thumbnail looks unique
  const paths = [];
  let s = seed;
  const rnd = () => { s = (s * 9301 + 49297) % 233280; return s / 233280; };
  for (let i = 0; i < 3; i++) {
    const points = [];
    let x = 60 + rnd() * 80;
    let y = 60 + rnd() * 50;
    let pathStr = `M ${x} ${y}`;
    for (let j = 0; j < 14; j++) {
      x += (rnd() - 0.5) * 60;
      y += (rnd() - 0.5) * 30;
      x = Math.max(20, Math.min(220, x));
      y = Math.max(20, Math.min(120, y));
      pathStr += ` L ${x.toFixed(0)} ${y.toFixed(0)}`;
    }
    paths.push({ d: pathStr, w: 1.5 + rnd() * 1.5, c: ['#0a0a0a', '#d63838', '#2a6df4'][i % 3] });
  }
  return (
    <svg viewBox="0 0 240 135" preserveAspectRatio="xMidYMid meet">
      {paths.map((p, i) => (
        <path key={i} d={p.d} stroke={p.c} strokeWidth={p.w} fill="none"
              strokeLinecap="round" strokeLinejoin="round" />
      ))}
    </svg>
  );
}

function ScorePage({ navigate, user }) {
  const [countdown, setCountdown] = React.useState(22);
  React.useEffect(() => {
    const t = setInterval(() => setCountdown((c) => (c <= 0 ? 0 : c - 1)), 1000);
    return () => clearInterval(t);
  }, []);

  return (
    <div className="page page-narrow">
      <div className="row" style={{ marginBottom: 24 }}>
        <button className="btn btn-ghost btn-sm" onClick={() => navigate('home')}>
          <IconBack /> back to rooms
        </button>
      </div>

      <section style={{ marginBottom: 32 }}>
        <div className="between" style={{ alignItems: 'flex-end' }}>
          <div>
            <div className="section-label">game over · room kitchen things</div>
            <h1 style={{ fontSize: 48, fontWeight: 600, letterSpacing: '-0.03em', margin: '6px 0 0', lineHeight: 1 }}>
              mira wins.
            </h1>
            <div className="mono" style={{ color: 'var(--muted)', fontSize: 13, marginTop: 8 }}>
              May 15, 2026 · 16:42 · 6 rounds · 24 guesses
            </div>
          </div>
          <div className="surface" style={{ padding: 16, minWidth: 240 }}>
            <div className="section-label">next round in</div>
            <div className="timer-big mono" style={{ fontSize: 36, margin: '6px 0' }}>{countdown}s</div>
            <div className="bar accent"><div style={{ width: (countdown / 30) * 100 + '%' }}></div></div>
            <div className="row" style={{ gap: 8, marginTop: 12 }}>
              <button className="btn btn-primary btn-sm" style={{ flex: 1 }}
                      onClick={() => navigate('game-lobby')}>rejoin lobby</button>
              <button className="btn btn-sm" onClick={() => navigate('home')}>leave</button>
            </div>
          </div>
        </div>
      </section>

      <section style={{ marginBottom: 48 }}>
        <div className="section-header">
          <h2>final standings</h2>
          <span className="mono" style={{ fontSize: 11, color: 'var(--muted)' }}>6 players</span>
        </div>
        <div className="standings">
          {SAMPLE_SCORES.map((p, i) => (
            <div key={p.id} className={"stand-row " + (i === 0 ? 'winner' : '')}>
              <span className="rank">{i === 0 ? '01' : String(i + 1).padStart(2, '0')}</span>
              <span className="who">
                {p.username}
                {user && p.username === user.username && <span className="chip chip-strong" style={{ marginLeft: 8 }}>you</span>}
              </span>
              <span className="delta">{p.delta}</span>
              <span className="pts">{p.score}</span>
            </div>
          ))}
        </div>
      </section>

      <section>
        <div className="section-header">
          <h2>round-by-round</h2>
          <span className="mono" style={{ fontSize: 11, color: 'var(--muted)' }}>click a drawing to enlarge</span>
        </div>
        <div className="rounds-list">
          {SAMPLE_ROUNDS.map((r) => (
            <div key={r.round} className="round-card">
              <div className="thumb">
                <MiniDrawing seed={r.round * 1733 + 11} />
              </div>
              <div className="round-meta">
                <div className="section-label">round {r.round}</div>
                <div className="word">{r.word.toUpperCase()}</div>
                <div className="by">drawn by <span style={{ color: 'var(--ink)' }}>{r.drawer}</span></div>
                <div className="row" style={{ gap: 6, marginTop: 8 }}>
                  <span className="chip mono">{r.scores.length + 1} guesses</span>
                  <span className="chip mono">52s</span>
                </div>
              </div>
              <div className="round-scores">
                <div className="section-label" style={{ marginBottom: 4 }}>points</div>
                {r.scores.map((s, i) => (
                  <div key={i} className="ln">
                    <span>{s.name}</span>
                    <span className={s.pts > 0 ? 'pos' : s.pts < 0 ? 'neg' : ''}>
                      {s.pts > 0 ? '+' : ''}{s.pts}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          ))}
        </div>
      </section>
    </div>
  );
}

function PastGamesPage({ navigate, user }) {
  return (
    <div className="page page-narrow">
      <section className="hero" style={{ paddingBottom: 24 }}>
        <div>
          <h1 style={{ fontSize: 44 }}>history.</h1>
          <p className="sub" style={{ marginTop: 10 }}>every game you've played, oldest at the bottom.</p>
        </div>
        <div className="meta">
          <div className="section-label">summary</div>
          <div className="big">{SAMPLE_HISTORY.length}</div>
          <div className="v" style={{ marginTop: 6 }}>games · 14h played</div>
        </div>
      </section>

      <div className="section-header">
        <h2>all games</h2>
        <div className="row" style={{ gap: 8 }}>
          <div className="seg" style={{ width: 220 }}>
            <button className="active">all</button>
            <button>wins</button>
            <button>recent</button>
          </div>
        </div>
      </div>
      <div className="history">
        <div className="history-row" style={{ color: 'var(--muted)', cursor: 'default', fontFamily: 'Geist Mono, monospace', fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.06em' }}>
          <span>date</span>
          <span>room</span>
          <span>rounds</span>
          <span>rank</span>
          <span style={{ textAlign: 'right' }}>score</span>
          <span></span>
        </div>
        {SAMPLE_HISTORY.map((h, i) => (
          <div key={i} className="history-row" onClick={() => navigate('score')}>
            <span className="date">{h.date}</span>
            <span className="name">{h.name}</span>
            <span className="mono" style={{ color: 'var(--muted)' }}>{h.rounds}r</span>
            <span className="mono" style={{ color: h.rank.startsWith('1/') ? 'var(--success)' : 'var(--ink)' }}>
              {h.rank}
            </span>
            <span className="score" style={{ textAlign: 'right' }}>{h.score}</span>
            <span className="arrow"><IconArrow /></span>
          </div>
        ))}
        <div style={{ padding: '20px 8px', textAlign: 'center', color: 'var(--muted)', fontSize: 12 }} className="mono">
          end of history · joined Apr 2026
        </div>
      </div>
    </div>
  );
}

window.ScorePage = ScorePage;
window.PastGamesPage = PastGamesPage;
