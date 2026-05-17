/* Mock data shared across screens. */
const SAMPLE_PLAYERS = [
  { id: 'u1', username: 'mira', color: '#c5f03a' },
  { id: 'u2', username: 'koen', color: '#7ad6ff' },
  { id: 'u3', username: 'astra', color: '#ff8a4d' },
  { id: 'u4', username: 'noor', color: '#ef5bff' },
  { id: 'u5', username: 'yves', color: '#9ee37d' },
  { id: 'u6', username: 'lin', color: '#ffd84a' },
];

const SAMPLE_ROOMS = [
  { id: 'r1', name: 'Kitchen things', code: 'K7P2', players: 5, max: 8, source: 'ai', round_duration: 60, rounds: 3, status: 'lobby', activity: '2 min ago' },
  { id: 'r2', name: 'Weekly office game', code: 'M2NX', players: 8, max: 8, source: 'local', round_duration: 60, rounds: 2, status: 'live', activity: 'now' },
  { id: 'r3', name: 'late night doodles', code: 'B14V', players: 3, max: 6, source: 'local', round_duration: 120, rounds: 5, status: 'lobby', activity: '12 sec ago' },
  { id: 'r4', name: 'Ocean animals only', code: '9QQR', players: 4, max: 12, source: 'ai', round_duration: 60, rounds: 3, status: 'lobby', activity: '1 min ago' },
  { id: 'r5', name: 'Speed round (60s)', code: 'TT08', players: 7, max: 8, source: 'local', round_duration: 60, rounds: 1, status: 'live', activity: 'now' },
];

const SAMPLE_CHAT = [
  { type: 'system', body: 'mira is drawing' },
  { type: 'chat', who: 'koen', body: 'a dog?' },
  { type: 'chat', who: 'astra', body: 'wait' },
  { type: 'chat', who: 'noor', body: 'an elephant' },
  { type: 'close', who: 'yves', body: 'helicopter' },
  { type: 'chat', who: 'koen', body: 'helmet??' },
  { type: 'correct', who: 'yves', body: 'helicopter' },
  { type: 'system', body: 'yves guessed correctly (+72)' },
  { type: 'chat', who: 'noor', body: 'gg' },
  { type: 'chat', who: 'lin', body: 'so close...' },
];

const SAMPLE_SCORES = [
  { id: 'u1', username: 'mira', score: 412, delta: '+72', drawing: true, guessed: true, rank: 1 },
  { id: 'u5', username: 'yves', score: 388, delta: '+68', guessed: true, rank: 2 },
  { id: 'u4', username: 'noor', score: 310, delta: '+45', guessed: true, rank: 3 },
  { id: 'u2', username: 'koen', score: 244, delta: '+12', guessed: false, rank: 4 },
  { id: 'u3', username: 'astra', score: 198, delta: '0', guessed: false, rank: 5 },
  { id: 'u6', username: 'lin', score: 102, delta: '-10', guessed: false, rank: 6 },
];

const SAMPLE_ROUNDS = [
  { round: 1, word: 'helicopter', drawer: 'mira', scores: [
    { name: 'yves', pts: 72 }, { name: 'noor', pts: 45 }, { name: 'koen', pts: 0 }, { name: 'lin', pts: -10 } ] },
  { round: 2, word: 'bicycle', drawer: 'koen', scores: [
    { name: 'mira', pts: 88 }, { name: 'astra', pts: 60 }, { name: 'noor', pts: 22 } ] },
  { round: 3, word: 'mountain', drawer: 'astra', scores: [
    { name: 'yves', pts: 70 }, { name: 'mira', pts: 64 }, { name: 'lin', pts: 30 } ] },
  { round: 4, word: 'pineapple', drawer: 'noor', scores: [
    { name: 'mira', pts: 92 }, { name: 'yves', pts: 80 }, { name: 'koen', pts: 14 } ] },
];

const SAMPLE_HISTORY = [
  { date: 'May 14', name: 'Kitchen things', rounds: 3, score: 412, rank: '1/5' },
  { date: 'May 13', name: 'Weekly office', rounds: 5, score: 288, rank: '3/8' },
  { date: 'May 11', name: 'Ocean animals', rounds: 3, score: 354, rank: '2/6' },
  { date: 'May 09', name: 'late night doodles', rounds: 2, score: 198, rank: '4/4' },
  { date: 'May 06', name: 'Speed round 60s', rounds: 1, score: 120, rank: '2/8' },
  { date: 'Apr 28', name: 'Tropical fruits', rounds: 3, score: 466, rank: '1/7' },
];

window.SAMPLE_PLAYERS = SAMPLE_PLAYERS;
window.SAMPLE_ROOMS = SAMPLE_ROOMS;
window.SAMPLE_CHAT = SAMPLE_CHAT;
window.SAMPLE_SCORES = SAMPLE_SCORES;
window.SAMPLE_ROUNDS = SAMPLE_ROUNDS;
window.SAMPLE_HISTORY = SAMPLE_HISTORY;
