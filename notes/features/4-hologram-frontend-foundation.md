# Feature: Hologram Frontend Foundation

## Summary
Set up Hologram pages structure and basic UI components to provide the frontend foundation for the Scrawly multiplayer drawing game, including HomePage for room selection and GamePage for main gameplay with essential UI components.

## Requirements
- [ ] Create HomePage for room selection with routing
- [ ] Create GamePage for main gameplay with routing
- [ ] Set up routing between pages using Hologram's navigation system
- [ ] Configure layouts for consistent UI across pages
- [ ] Implement RoomList component for displaying available rooms
- [ ] Implement PlayerList component showing connected players
- [ ] Implement ChatBox component for game messages
- [ ] Implement ScoreBoard component for current standings
- [ ] Write unit tests for page routing and navigation
- [ ] Write unit tests for component state management
- [ ] Write unit tests for component event handling
- [ ] Write unit tests for UI state synchronization

## Research Summary

### Existing Usage Rules Checked
- **Hologram**: Framework is already configured in mix.exs (v0.5.1), endpoint includes Hologram.Router plug, and static files include "hologram" path
- **Phoenix**: Current project uses Phoenix controllers and templates, but Hologram will replace this frontend approach
- **Ash**: Backend domain logic already established with Games context (Game, Room resources) and Accounts context

### Documentation Reviewed
- **Hologram Architecture**: Pages and Components are fundamental building blocks, with automatic code distribution between client/server, WebSocket communication, and client-side state management
- **Hologram Framework**: Uses declarative component system, intelligent Elixir-to-JavaScript transpilation, Actions (client-side) and Commands (server-side) for operations

### Existing Patterns Found
- **Backend Domain**: `/lib/scrawly/games.ex` - Games context with Game and Room resources
- **Phoenix Structure**: Current PageController at `/lib/scrawly_web/controllers/page_controller.ex` with home.html.heex template
- **WebSocket Setup**: GameChannel already exists at `/lib/scrawly_web/channels/game_channel.ex` for real-time communication
- **Routing**: Current Phoenix router at `/lib/scrawly_web/router.ex` with browser pipeline and authentication

### Technical Approach
1. **Create Hologram Pages**: Replace Phoenix controller-based approach with Hologram pages that handle client-side state and server communication
2. **Page Structure**: HomePage will handle room browsing/joining, GamePage will handle active gameplay
3. **Component Architecture**: Build reusable components (RoomList, PlayerList, ChatBox, ScoreBoard) that can manage their own state and communicate with backend
4. **Routing Setup**: Use Hologram's navigation system to handle page transitions
5. **Layout Configuration**: Create consistent layouts that work with Hologram's client-side rendering
6. **Integration**: Connect to existing GameChannel for real-time communication and Ash resources for data

## Risks & Mitigations
| Risk | Impact | Mitigation |
|------|--------|------------|
| Hologram learning curve | High | Follow Hologram docs closely, start with simple pages, reference architecture docs |
| Integration with existing Phoenix/Ash setup | Medium | Keep existing backend intact, only replace frontend layer |
| WebSocket integration complexity | Medium | Use existing GameChannel, follow Hologram's WebSocket patterns |
| Testing Hologram components | Medium | Research Hologram testing patterns, start with simple unit tests |
| Client-side state management | Medium | Follow Hologram's state management patterns, keep state simple initially |

## Implementation Checklist
- [ ] Create `lib/scrawly_web/pages/home_page.ex` - Hologram page for room selection
- [ ] Create `lib/scrawly_web/pages/game_page.ex` - Hologram page for gameplay
- [ ] Set up Hologram routing configuration
- [ ] Create layout templates for consistent UI
- [ ] Implement `lib/scrawly_web/components/room_list.ex` component
- [ ] Implement `lib/scrawly_web/components/player_list.ex` component  
- [ ] Implement `lib/scrawly_web/components/chat_box.ex` component
- [ ] Implement `lib/scrawly_web/components/score_board.ex` component
- [ ] Write tests for page navigation and routing
- [ ] Write tests for component state management
- [ ] Write tests for component event handling
- [ ] Write tests for UI state synchronization
- [ ] Update router to integrate Hologram pages
- [ ] Verify no regressions with existing backend functionality

## Questions for Zach - ANSWERED
1. Should we completely replace the Phoenix controller/template approach, or maintain both during transition? **ANSWER: Maintain both during transition**
2. Are there specific design requirements for the UI components (styling, layout preferences)? **ANSWER: Make it simple and elegant**
3. Should the HomePage show public rooms, private rooms, or both? **ANSWER: Both**
4. What level of real-time updates should the HomePage have (live room counts, player counts)? **ANSWER: High**
5. Are there any specific testing patterns you prefer for Hologram components? **ANSWER: No, just minimize testing**

## Log
- **2025-01-27 19:45**: Created feature branch `feature/1.4-hologram-frontend-foundation`
- **2025-01-27 19:45**: Starting implementation with approved requirements
- **2025-01-27 19:46**: Fixed approach to use proper Hologram patterns instead of LiveView
- **2025-01-27 19:47**: Created HomePage and GamePage with proper Hologram structure (init, action, template)
- **2025-01-27 19:48**: Created AppLayout for consistent page structure
- **2025-01-27 19:48**: Working on fixing template loop syntax issues
- **2025-01-27 19:49**: Successfully implemented basic Hologram pages with proper structure
- **2025-01-27 19:50**: All compilation successful, tests passing, basic functionality working
