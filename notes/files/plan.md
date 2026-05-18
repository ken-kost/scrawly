# Scrawly - Multiplayer Drawing & Guessing Game Plan

## Phase 1: MVP - Core Game Foundation

This phase establishes the fundamental game mechanics including basic room management, real-time drawing synchronization, simple chat functionality, and essential gameplay flow. The goal is to create a playable game where users can join rooms, take turns drawing and guessing, with basic scoring mechanisms in place.

### 1. Backend Infrastructure Setup

- [x] Initialize Ash application structure
  - [x] Create domain contexts for Game, Room, and Player
  - [x] Configure Ash resources with proper attributes and actions
  - [x] Set up PostgreSQL data layer with ash_postgres
  - [x] Configure Ash authentication for player sessions

- [x] Unit Tests:
  - [x] Test Ash resource creation and validation
  - [x] Test domain context boundaries
  - [x] Test database migrations and schema
  - [x] Test authentication token generation

### 2. Room Management System

- [x] Implement Room resource with Ash
  - [x] Create room with unique code generation
  - [x] Join room functionality (max 12 players)
  - [x] Auto-start when minimum 2 players present
  - [x] Handle player disconnection/reconnection
  - [x] Room state management (lobby, playing, ended)

- [x] Implement Player resource
  - [x] Player creation with username
  - [x] Player state tracking (connected, drawing, guessing)
  - [x] Score tracking per player
  - [x] Current room association

- [x] Unit Tests:
  - [x] Test room creation and code uniqueness
  - [x] Test player joining with capacity limits
  - [x] Test auto-start logic with player count
  - [x] Test player state transitions
  - [x] Test disconnection handling

### 3. Real-time Communication Infrastructure

- [x] Set up Phoenix channels for WebSocket communication
  - [x] Create GameChannel for room-specific communication
  - [x] Implement presence tracking for players
  - [x] Handle connection lifecycle events
  - [x] Set up message broadcasting patterns

- [x] Create channel event handlers
  - [x] Drawing events (start, move, stop)
  - [x] Chat message events
  - [x] Game state update events
  - [x] Player action events

- [x] Unit Tests:
  - [x] Test channel join/leave behavior
  - [x] Test presence tracking accuracy
  - [x] Test message broadcasting
  - [x] Test event handler responses
  - [x] Test connection error handling

### 4. Frontend Foundation with Hologram

- [x] Set up Hologram pages structure
  - [x] Create HomePage for room selection
  - [x] Create GamePage for main gameplay
  - [x] Set up routing between pages
  - [x] Configure layouts for consistent UI

- [x] Implement basic UI components
  - [x] RoomList component for available rooms
  - [x] PlayerList component showing connected players
  - [x] ChatBox component for messages
  - [x] ScoreBoard component for current standings

- [x] Unit Tests:
  - [x] Test page routing and navigation
  - [x] Test component state management
  - [x] Test component event handling
  - [x] Test UI state synchronization

### 5. Drawing System Implementation

- [x] Create DrawingCanvas component
  - [x] Implement SVG-based drawing (referencing draw.md)
  - [x] Handle pointer events (down, move, up, cancel)
  - [x] Track drawing state and path data
  - [x] Implement clear canvas functionality

- [x] Synchronize drawing across clients
  - [x] Batch drawing coordinates for efficiency
  - [x] Broadcast drawing updates via WebSocket
  - [x] Handle drawing playback for late joiners
  - [x] Optimize for performance with throttling

- [x] Unit Tests:
  - [x] Test drawing event capture
  - [x] Test path data generation
  - [x] Test drawing state management
  - [x] Test canvas clearing
  - [x] Test coordinate batching logic

### 6. Basic Game Flow

- [x] Implement round-based gameplay
  - [x] Round initialization with drawer selection
  - [x] 80-second timer per round
  - [x] Word selection from basic word list
  - [x] Turn rotation logic
  - [x] Round completion handling

- [x] Create GameController for state management
  - [x] Track current round number
  - [x] Manage drawer queue
  - [x] Handle round transitions
  - [x] Calculate and update scores

- [x] Unit Tests:
  - [x] Test round initialization
  - [x] Test timer countdown accuracy
  - [x] Test drawer rotation fairness
  - [x] Test score calculation logic
  - [x] Test game end conditions

### 6.5 Integrate FE Hologram with BE Ash for home page and related game page
- [x] Investigate how to integrate Ash Authentication with Hologram
- [x] Use ash_authentication_live_session :authenticated_routes in router.ex to enable auth for home and game page, requring user to register in order to able to play
  - [x] Use :request_magic_link in user.ex action to enable registration with email
  - [x] Integrate game page with home page and integrate anything else necessary

- [x] Unit Tests:
  - [x] Test users in a room

### 7. Word and Guessing System

- [x] Implement Word resource
  - [x] Create basic word database
  - [x] Word difficulty categorization
  - [x] Random word selection algorithm
  - [x] Word hint generation (underscores)

- [x] Create guessing mechanics
  - [x] Chat message parsing for guesses
  - [x] Exact match validation
  - [x] Correct guess handling
  - [x] Points calculation based on speed

- [x] Unit Tests:
  - [x] Test word selection randomness
  - [x] Test hint generation accuracy
  - [x] Test guess validation logic
  - [x] Test points calculation formula
  - [x] Test multiple correct guesses handling

### 8. Chat System

- [x] Implement ChatMessage component
  - [x] Message input and submission
  - [x] Message display with usernames
  - [x] Color-coded system messages
  - [x] Auto-scroll to latest message

- [x] Add chat features
  - [x] Spam protection with rate limiting
  - [x] System messages for game events
  - [x] Guess obfuscation for drawer
  - [x] Message history limit

- [x] Unit Tests:
  - [x] Test message submission flow
  - [x] Test spam protection triggers
  - [x] Test system message generation
  - [x] Test guess obfuscation logic
  - [x] Test message history management

### Phase 1 Integration Tests:
- [x] Test complete game flow from room creation to game end
- [x] Test multiple players joining and playing simultaneously
- [x] Test drawing synchronization across multiple clients
- [x] Test reconnection handling during active game
- [x] Test score persistence and leaderboard accuracy
- [x] Test performance with maximum player capacity

## Phase 2: Enhanced Features

This phase adds depth to the game experience with private rooms, customization options, improved drawing tools, and quality-of-life features. The focus is on giving players more control over their game experience while maintaining smooth gameplay.

### 9. Private Room System

- [ ] Extend Room resource for privacy settings
  - [ ] Private room creation with custom codes
  - [ ] Shareable room links generation
  - [ ] Room settings configuration
  - [ ] Host privileges implementation

- [ ] Create RoomSettings component
  - [ ] Round count selector (1-10)
  - [ ] Timer adjustment (30-180 seconds)
  - [ ] Language selection interface
  - [ ] Custom word list toggle

- [ ] Unit Tests:
  - [ ] Test private room code generation
  - [ ] Test room link sharing mechanism
  - [ ] Test host privilege enforcement
  - [ ] Test settings persistence
  - [ ] Test settings validation ranges

### 10. Custom Word Management

- [ ] Implement CustomWordList resource
  - [ ] Word list creation and storage
  - [ ] Validation (min 10 words, max length)
  - [ ] Word list sharing between rooms
  - [ ] Default list fallback mechanism

- [ ] Create WordListEditor component
  - [ ] Add/remove word interface
  - [ ] Bulk word import
  - [ ] Word validation feedback
  - [ ] Save and load word lists

- [ ] Unit Tests:
  - [ ] Test word list CRUD operations
  - [ ] Test word validation rules
  - [ ] Test character limit enforcement
  - [ ] Test word list association with rooms
  - [ ] Test fallback to default words

### 11. Avatar System

- [ ] Create Avatar resource
  - [ ] Predefined avatar collection
  - [ ] Avatar selection storage
  - [ ] Avatar display in player list
  - [ ] Default avatar assignment

- [ ] Implement AvatarSelector component
  - [ ] Avatar gallery display
  - [ ] Selection persistence
  - [ ] Preview functionality
  - [ ] Avatar change during game

- [ ] Unit Tests:
  - [ ] Test avatar selection flow
  - [ ] Test avatar persistence
  - [ ] Test default avatar logic
  - [ ] Test avatar display rendering
  - [ ] Test concurrent avatar changes

### 12. Advanced Drawing Tools

- [x] Enhance DrawingCanvas with tools
  - [x] Color palette implementation (8 preset colors)
  - [x] Brush size adjustment (3 sizes: 2px, 5px, 10px)
  - [x] Eraser tool functionality (white strokes, 20px width)
  - [x] Undo capability (stroke-level, synced via channel)

- [x] Create DrawingToolbar component
  - [x] Tool selection interface (inline toolbar above canvas)
  - [x] Color picker with presets (8 color buttons)
  - [x] Size selector (3 size buttons)
  - [x] Tool state persistence (draw_color, draw_width, draw_eraser in page state)

- [x] Unit Tests:
  - [x] Test color selection and application
  - [x] Test brush size rendering
  - [x] Test eraser functionality
  - [x] Test undo stack management
  - [x] Test tool switching behavior

### 13. Progressive Hint System

- [x] Implement hint generation logic
  - [x] Time-based letter reveals
  - [x] Strategic letter selection (vowel priority)
  - [x] Hint timing configuration (custom schedules)
  - [x] Multiple hint stages (5 stages: 0-4)

- [x] Update UI for hint display
  - [ ] Animated letter reveals
  - [x] Hint progress indicator (progress bar with stage label)
  - [x] Remaining letters counter
  - [ ] Visual hint emphasis

- [x] Unit Tests:
  - [x] Test hint timing accuracy
  - [x] Test letter selection algorithm (vowel priority, determinism)
  - [x] Test hint progression stages (monotonically increasing reveals)
  - [x] Test hint display updates (hint_info metadata)
  - [x] Test hint impact on scoring (via Scoring module integration)

### 14. Enhanced Scoring System

- [x] Implement detailed scoring algorithm
  - [x] Time-based point calculation (50-500 curve)
  - [x] Drawer points for successful guesses (+50 per guesser, +100 all-guessed bonus)
  - [x] Bonus points for speed (speed_bonus = time_left/duration * 450)
  - [x] Penalty for no guesses (-25 drawer timeout penalty)

- [ ] Create ScoreAnimation component
  - [ ] Point gain animations
  - [ ] Leaderboard position changes
  - [x] Round score summary (via round_results in RoomServer)
  - [ ] Final score celebration

- [x] Unit Tests:
  - [x] Test point calculation accuracy
  - [x] Test drawer point allocation
  - [x] Test speed bonus formula
  - [ ] Test score animation triggers
  - [x] Test leaderboard sorting

### Phase 2 Integration Tests:
- [ ] Test private room creation and joining via link
- [ ] Test custom word list in complete game
- [ ] Test all drawing tools in multiplayer setting
- [ ] Test hint system timing and reveals
- [ ] Test avatar persistence across sessions
- [ ] Test enhanced scoring with multiple players

## Phase 3: Polish and Optimization

This phase focuses on user experience improvements, internationalization, social features, and performance optimization. The goal is to create a polished, scalable game that provides an excellent experience across different devices and languages.

### 15. Internationalization System

- [ ] Implement i18n infrastructure
  - [ ] Language detection and selection
  - [ ] Translation file structure
  - [ ] Dynamic language switching
  - [ ] RTL language support

- [ ] Translate game content
  - [ ] UI text translations
  - [ ] System message translations
  - [ ] Word lists per language
  - [ ] Language-specific categories

- [ ] Unit Tests:
  - [ ] Test language detection
  - [ ] Test translation loading
  - [ ] Test language switching
  - [ ] Test RTL rendering
  - [ ] Test fallback language

### 16. Advanced Room Configuration

- [ ] Extend room settings
  - [ ] Word categories selection
  - [ ] Difficulty levels
  - [ ] Custom round timing
  - [ ] Spectator mode toggle

- [ ] Create AdvancedSettings component
  - [ ] Category multi-select
  - [ ] Difficulty slider
  - [ ] Advanced timing options
  - [ ] Game mode variants

- [ ] Unit Tests:
  - [ ] Test category filtering
  - [ ] Test difficulty application
  - [ ] Test custom timing validation
  - [ ] Test setting combinations
  - [ ] Test mode switching

### 17. Voting and Feedback System

- [ ] Implement Voting resource
  - [ ] Like/dislike drawings
  - [ ] Vote storage and aggregation
  - [ ] Spam protection for votes
  - [ ] Vote display logic

- [ ] Create VotingInterface component
  - [ ] Thumb up/down buttons
  - [ ] Vote count display
  - [ ] Vote animation feedback
  - [ ] Post-game vote summary

- [ ] Unit Tests:
  - [ ] Test vote recording
  - [ ] Test vote aggregation
  - [ ] Test spam protection
  - [ ] Test vote UI updates
  - [ ] Test vote persistence

### 18. Mobile Optimization

- [ ] Responsive design implementation
  - [ ] Touch-optimized drawing
  - [ ] Mobile-friendly layouts
  - [ ] Gesture support
  - [ ] Screen orientation handling

- [ ] Create mobile-specific components
  - [ ] TouchDrawingCanvas
  - [ ] MobileToolbar
  - [ ] CompactPlayerList
  - [ ] MobileChatInterface

- [ ] Unit Tests:
  - [ ] Test touch event handling
  - [ ] Test responsive breakpoints
  - [ ] Test gesture recognition
  - [ ] Test orientation changes
  - [ ] Test mobile performance

### 19. Performance Optimization

- [ ] Backend optimization
  - [ ] Database query optimization
  - [ ] Channel message batching
  - [ ] Caching implementation
  - [ ] Load balancing preparation

- [ ] Frontend optimization
  - [ ] Drawing data compression
  - [ ] Lazy component loading
  - [ ] Asset optimization
  - [ ] Memory leak prevention

- [ ] Unit Tests:
  - [ ] Test query performance
  - [ ] Test message throughput
  - [ ] Test cache hit rates
  - [ ] Test memory usage
  - [ ] Test load distribution

### 20. Analytics and Monitoring

- [ ] Implement analytics tracking
  - [ ] Game metrics collection
  - [ ] Player behavior tracking
  - [ ] Performance monitoring
  - [ ] Error tracking

- [ ] Create admin dashboard
  - [ ] Real-time game statistics
  - [ ] Player activity graphs
  - [ ] System health metrics
  - [ ] Error log viewer

- [ ] Unit Tests:
  - [ ] Test metric collection
  - [ ] Test data aggregation
  - [ ] Test dashboard queries
  - [ ] Test alert triggers
  - [ ] Test data retention

### 21. Social Features

- [ ] Implement social elements
  - [ ] Player profiles
  - [ ] Friend system
  - [ ] Game history
  - [ ] Achievement system

- [ ] Create social UI components
  - [ ] ProfileCard component
  - [ ] FriendsList component
  - [ ] GameHistory component
  - [ ] AchievementBadges component

- [ ] Unit Tests:
  - [ ] Test profile creation
  - [ ] Test friend requests
  - [ ] Test history recording
  - [ ] Test achievement triggers
  - [ ] Test privacy settings

### Phase 3 Integration Tests:
- [ ] Test full internationalization with language switching
- [ ] Test mobile gameplay experience end-to-end
- [ ] Test performance under load (50+ concurrent games)
- [ ] Test voting system during active games
- [ ] Test social features integration
- [ ] Test analytics data accuracy
- [ ] Test system stability over extended periods
