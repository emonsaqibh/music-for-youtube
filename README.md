# Music for YouTube

A native macOS client for YouTube Music, built with SwiftUI and macOS 26's Liquid Glass
components, laid out like Apple Music.

## How it works

YouTube Music has no public playback API, and extracting stream URLs breaks every time
YouTube rotates its player code. So this app doesn't do that. Instead:

```
┌──────────────────────────────────┐
│  SwiftUI UI (Apple Music layout) │   sidebar · shelves · queue · full-screen player
└────────────────┬─────────────────┘
                 │ JS bridge (callAsyncJavaScript)
┌────────────────▼─────────────────┐
│  Hidden WKWebView                │   music.youtube.com, 1×1pt, never shown
│  #movie_player  ← audio          │
└────────────────┬─────────────────┘
                 │ fetch() from inside the authenticated page
┌────────────────▼─────────────────┐
│  InnerTube API                   │   browse · search · next · get_search_suggestions
└──────────────────────────────────┘
```

The web player is the audio engine; everything you see is native. Because playback runs
through the real player with the real session, Premium, listening history, radio and
recommendations all keep working, and there is no stream extraction to break.

API calls are issued **from inside the page** via injected JavaScript, so cookies and the
`SAPISIDHASH` request signature are handled by the browser — the session never has to be
lifted out of WebKit.

### Source map

| Path | What lives there |
|---|---|
| `Engine/BridgeScript.swift` | The injected JavaScript: InnerTube proxy, player wrapper, Media Session capture |
| `Engine/WebEngine.swift` | Owns the hidden `WKWebView`, marshals calls and events |
| `Engine/AuthWindow.swift` | Google sign-in window (shares the account cookie store) |
| `Engine/Session.swift` | Account / guest profiles, each with its own cookie store |
| `Support/AppSettings.swift` | User preferences (Settings window) |
| `UI/MenuBarPlayer.swift` | The menu bar Now Playing panel |
| `API/Parse.swift` | InnerTube renderer trees → models, written to fail soft |
| `API/Catalog.swift` | `home`, `search`, `album`, `playlist`, `artist`, `upNext` |
| `Player/PlayerController.swift` | The queue, shuffle/repeat, and the load/nudge state machine |
| `Player/NowPlaying.swift` | Control Center, Now Playing widget, media keys |
| `Player/GlobalHotkeys.swift` | ⌃⌥⌘Space / ← / → |
| `UI/RootView.swift` | Split view, sidebar, routing |
| `UI/PlayerPill.swift` | The floating player capsule |
| `UI/LyricsView.swift` | Synced / plain lyrics, shared by the side panel and full-screen player |
| `UI/Components/PagedShelf.swift` | Shelves that fit a whole number of items and page by them |
| `Resources/AppIcon.icon` | Icon Composer (Liquid Glass) icon; `build.sh` compiles it with `actool` |
| `UI/` | Everything else visible |

### UI layout

Modelled on Music.app on macOS 26 rather than on an older Apple Music:

- **No top bar.** The window has no titlebar content; the sidebar runs full height with
  the traffic lights over it.
- **The player is a floating glass capsule** at the bottom, centred over the *content*
  column so it stays put when the queue panel opens. Content scrolls underneath it, which
  is why every page carries `Theme.playerClearance` of bottom padding.
- **Sidebar rows draw their own background** — a neutral grey capsule with the icon still
  tinted red. Using the List's own selection would paint the whole row in the system
  accent colour, which Music.app does not do.
- **Song shelves are a horizontally-paging four-row grid**, not a tall column. That is the
  layout that makes the home page feel browsable.

## Build and run

```sh
./build.sh          # → build/Music for YouTube Dev.app
./run.sh            # build, then launch (dev build)
./release.sh 0.1.0-beta.2   # freeze a beta → releases/ + /Applications
```

Requires Xcode 26 and macOS 26+. The app is ad-hoc signed and unsandboxed, so it runs
locally without a developer account.

## First run

Click the account row at the bottom of the sidebar and choose **Sign In**, then complete
the normal Google login. You can switch to **Guest** mode (⇧⌘G) and back at any time —
the two profiles keep separate cookies, history and recommendations, and switching
never signs you out. Cookies persist in the app's `WKWebsiteDataStore`, so this is a one-time
step. Signed out, you still get public search and trending shelves but no library or
personalised recommendations.

## Keyboard

| | |
|---|---|
| Space | Play / pause |
| ⌘← / ⌘→ | Previous / next |
| ⇧⌘S / ⇧⌘R | Shuffle / repeat |
| ⌘↑ / ⌘↓ / ⇧⌘M | Volume up / down / mute |
| ⌥⌘M | Mini player |
| ⇧⌘G | Switch account ⇄ guest |
| ⌘, | Settings |
| ⌃⌥⌘Space / ← / → | Global (work from any app) |

Hardware media keys work too, by two routes: `MPRemoteCommandCenter`, and — for the case
where WebKit claims the system Now Playing session because it owns the audio — the
injected bridge forwards the page's Media Session actions back to the native player.

## Debugging

The app logs to `~/Library/Logs/MusicForYouTube-Dev/app.log`, and **Help → Engine
Diagnostics…** shows live bridge state.

Two headless checks:

```sh
"build/Music for YouTube Dev.app/Contents/MacOS/YouTubeMusic" --selftest
# search → play → seek → pause → radio queue → Now Playing, then PASS/FAIL

"build/Music for YouTube Dev.app/Contents/MacOS/YouTubeMusic" --probe
# compares the three ways of starting a track, when playback misbehaves

"build/Music for YouTube Dev.app/Contents/MacOS/YouTubeMusic" --demo
# launches normally but with a real track playing and the queue open, so the
# playing-state UI can be inspected without clicking through to it
#   --no-queue           leave the queue panel closed
#   --demo-fullscreen    open the full-screen player too
#   --demo-lyrics        open the lyrics panel instead of the queue
```

### Things that were load-bearing to get right

- **`loadVideoById` alone does not start audio.** WebKit's autoplay policy leaves the
  track merely cued, so `PlayerController` nudges with `playVideo()` until the player
  reports state 1, then falls back to a full `/watch?v=…` navigation if it never does.
- **`next` needs a radio playlist id.** Called with just a `videoId` it returns that one
  track; seeded with `RDAMVM<videoId>` it returns the ~50-track autoplay queue.
- **InnerTube fetches can fail transiently** with `TypeError: Load failed` when they race
  the player's own media request, so `innertube()` retries once and the radio fetch is
  staggered behind playback start.
- **Google rejects embedded web views at sign-in**, so both web views report a genuine
  Safari user agent.
- **A scrub whose gesture end never arrives** (released outside the window, or
  interrupted) would pin the position display forever, so `scrubTarget` expires on a
  timer rather than relying solely on the gesture's end.

## Not built yet

Offline downloads (not feasible on this architecture — the audio never leaves WebKit),
library mutation (like/unlike, add to playlist), and search continuations.
