# Handoff — Music for YouTube

Context for a fresh session. Read `README.md` first for the architecture; this file covers
**where the project stands** and **what comes next**.

Project: `~/Documents/Development-Projects/ytm` · ~4,700 lines of Swift · no dependencies
· Xcode 26 / macOS 26 SDK / Swift 6.3 (language mode 5) · not a git repo yet.

---

## 1. Where it stands

Built over one session. A native macOS YouTube Music client: SwiftUI + Liquid Glass,
laid out like Music.app on macOS 26. Audio plays through a hidden 1×1pt `WKWebView` on
music.youtube.com; the InnerTube API is called via JavaScript injected into that same
authenticated page, so cookies and the `SAPISIDHASH` signature are handled by the browser.

**Verified working** (`--selftest`, run it after any engine or player change):

```
play=ok seek=ok pause=ok radio=ok nowPlaying=ok queue=50
```

Built: home / new feeds, search with filters, library tabs, album / playlist / artist
pages, native queue with reorder, floating player pill, full-screen player, mini player,
menu bar extra, media keys (two routes), global hotkeys ⌃⌥⌘Space/←/→.

### The one thing not done

**Nobody has signed in yet.** Everything above was verified signed-out. Sign-in is the
account row at the bottom of the sidebar; cookies then persist in the app's
`WKWebsiteDataStore`. Until that happens there is no library, no personalised home, and —
importantly for task 2 below — the `guide` endpoint returns only three entries.

**Re-run `--probe-nav` once signed in.** Several of the shapes recorded below will grow.

### Dev build vs. beta

There are two builds with different bundle IDs, so their sign-in, settings and logs are
kept apart and both can run at once:

| | Dev | Beta |
|---|---|---|
| Built by | `./build.sh` / `./run.sh` | `./release.sh <version>` |
| Bundle | `build/Music for YouTube Dev.app` | `/Applications/Music for YouTube.app` (+ `releases/<version>/`) |
| Bundle ID | `dev.fringecore.ytmusic.dev` | `dev.fringecore.ytmusic` |
| Logs | `~/Library/Logs/MusicForYouTube-Dev/` | `~/Library/Logs/MusicForYouTube/` |
| Looks | blue icon (recoloured copy made by `build.sh`), **DEV** badge on Home | red icon, no badge |

All development and testing uses the **dev** build. A release is frozen: `release.sh`
builds in release config, saves the app and a `source.tar.gz` snapshot under
`releases/<version>/`, installs it to `/Applications`, and refuses to reuse a version.
Current beta: **0.1.0-beta.1** (2026-09-23).

### Launch flags

```sh
./build.sh      # → build/Music for YouTube Dev.app
./run.sh        # build + launch

"build/Music for YouTube Dev.app/Contents/MacOS/YouTubeMusic" --selftest    # engine PASS/FAIL
"build/Music for YouTube Dev.app/Contents/MacOS/YouTubeMusic" --probe       # playback strategies
"build/Music for YouTube Dev.app/Contents/MacOS/YouTubeMusic" --probe-nav   # dumps nav + lyrics JSON
"build/Music for YouTube Dev.app/Contents/MacOS/YouTubeMusic" --demo        # launches with a track playing
```

`--probe-nav` writes raw responses to `~/Library/Logs/MusicForYouTube-Dev/*.json`. That is the
tool for both tasks below — use it rather than guessing at renderer shapes.

### Load-bearing quirks (documented at length in README)

1. `loadVideoById` does not start audio — WebKit leaves it cued; the player nudges
   `playVideo()` until state 1.
2. `next` needs `playlistId: "RDAMVM" + videoId` or it returns one track, not 50.
3. InnerTube `fetch()` throws `TypeError: Load failed` when it races the player's own
   media request — hence the retry and the staggered radio fetch.
4. A scrub whose gesture-end never arrives would pin the position display; `scrubTarget`
   expires on a timer.

---

## 2. Done (session 2, 2026-09-23): lyrics, guide-driven sidebar, responsive UI, icon

**Lyrics** — `Catalog.lyrics(videoId:)` → `next` → the tab whose browse endpoint has
`pageType == MUSIC_PAGE_TYPE_TRACK_LYRICS` (not the localised title) → timed lyrics as
`ANDROID_MUSIC`, falling back to plain WEB_REMIX text. Cached per videoId. The bridge's
`__ytm.innertube(endpoint, body, client)` takes an optional client override
(`InnerTubeClient.androidMusic`). `LyricsStore` + `LyricsView` (`UI/LyricsView.swift`) drive
both the side panel (pill's quote button) and the full-screen player. Highlighting runs off
`PlayerController.livePosition()`, which extrapolates between the 500ms bridge polls.
Verified signed-out on Get Lucky (synced). Still unverified: Premium / age-restricted
tracks through the Android request (it sends no Authorization header).

**Sidebar** — `Catalog.guide()` parses `guideEntryRenderer`s (routing on browseId: `FE…` →
top section, `VL…` → playlists, `SP…` upsells dropped) and the library landing page's
`chipCloudChipRenderer`s as library sections. `SidebarItem` is now `.search | .feed(NavItem)
| .library(NavItem) | .playlist`. The guide is cached in UserDefaults
(`navigation.guide.v1`), with `Guide.fallback` when it fails; re-fetched on
`WebEngine.sessionDidChange` (sign-in / sign-out). iconType → SF Symbol is `NavItem.symbol`.
**Signed-in shapes are still assumptions** — the chip parsing and the guide's playlist
entries were written blind. Sign in, `--probe-nav`, and check `library_landing.json` has
`chipCloudChipRenderer`s with `browseEndpoint`s; if it does not, the sidebar silently keeps
the fallback library sections.

**Responsiveness** — `PagedShelf` sizes tiles / song columns so a whole number fit and
pages by them (hover arrows, faded edges). The pill sheds shuffle/repeat below 580pt and
volume below 470pt. Collection hero stacks below 560pt; album column hides below 620pt.
The full-screen player is an in-window overlay (not a sheet) and reflows with the window;
Esc closes it.

**Engine** — `isBound` now drops on every main-frame navigation, and InnerTube calls retry
when the bridge is missing mid-navigation (was surfacing as "window.__ytm undefined").

**Icon** — `Resources/AppIcon.icon` (Icon Composer format; generator script lived in the
session scratchpad — edit the SVGs in `Assets/` directly). `build.sh` runs `actool` →
`Assets.car` + `AppIcon.icns`; Info.plist has `CFBundleIconName`. Preview any variant with
`Icon Composer.app/Contents/Executables/ictool <icon> --export-image … --rendition Dark`.

**Selftest note** — it can fail ("never reached a playing state") when launched within ~1s
of killing a previous instance. Wait a few seconds between runs.

`--demo-lyrics` opens the lyrics panel for screenshots.

---

## 3. Done (session 3, 2026-09-23): profiles, settings, menu bar, mini player

**Signed in now** (account "Musictube"). Signed-in shapes verified by `--probe-nav`, which
now also dumps `FEmusic_liked_playlists/videos/albums.json`:
- Library chips each carry *two* browse endpoints — the section and a deselect command
  back to `FEmusic_library_landing`. Take the one that is not the landing page
  (`Catalog.librarySections`); picking the first was randomly dropping sections.
- The guide adds `SPunlimited` (dropped) and auto playlists like `VLSE` "Episodes for Later".
- Empty library pages carry a localised `messageRenderer`; `Parse.emptyMessage` shows it.

**Account ⇄ guest** — `Engine/Session.swift`. Two cookie stores: account = WebKit's default
store (where sign-in lands), guest = `WKWebsiteDataStore(forIdentifier:)` with a fixed UUID.
A web view's store is fixed at creation, so `WebEngine.switchProfile` builds a new web view
and tears down the old one. Always go through `PlayerController.switchProfile`, which
records the position and resumes there (≈4s) once the new page binds. Sign-out clears only
the account store; "Clear Guest Data" only the guest store. `Session.generation` keys
`ContentRoot`'s identity so pages reload per profile; the guide cache is per profile.
⇧⌘G toggles. The account's name/handle/photo come from `account/account_menu`
(`activeAccountHeaderRenderer`) and are remembered for display while in guest mode.

**Engine host window** — the web view no longer lives in the main window: `WebEngine` owns a
2×2, transparent, click-through `NSPanel` (all Spaces, not in the Window menu). Music keeps
playing with the main window closed, and the self-test no longer depends on the UI having
opened a window (that was the "stuck at state 3" failure). The main scene is now a single
`Window(id: "main")`, reopened from the menu bar.

**Player** — the load watchdog now falls back to the watch page after ~6s of a stuck
*unstarted* (-1) state instead of ~15s. Self-test went from ~70% to 8/8 passes since.

**Settings** (⌘,) — `Support/AppSettings.swift` (UserDefaults, applies live) +
`UI/SettingsView.swift`: General (open at login via `SMAppService`, menu bar item/title,
sidebar playlists, restore defaults), Appearance (system/light/dark, 9 accents — `Theme.accent`
is now dynamic —, full-screen background moving/still/solid, open with lyrics, lyrics
size), Playback (radio autoplay, global shortcuts on/off), Account (profile switcher, clear
guest data), About. Remembers the last pane (`settings.tab`), which is also how to
screenshot a given pane: `defaults write dev.fringecore.ytmusic.dev settings.tab appearance`.

**Menu bar panel** — `UI/MenuBarPlayer.swift`: Control Center-style card over blurred
artwork, scrubber, transport, volume, 3-row Up Next, footer with profile menu / open app /
mini player / settings / quit. **Mini player** — `.windowStyle(.plain)`, rounded, dragged via `WindowDragGesture` (AppKit's movable-by-background never fires: the SwiftUI hosting view claims every mouse-down),
hover close/expand.

---

## 3b. Done (session 4, 2026-09-23): full Home feed, single-click play, a playback bug

**Home shows everything.** Feeds are paged: the first `browse` returns ~3 sections plus
`sectionListRenderer.continuations[].nextContinuationData`; later pages come back as
`continuationContents.sectionListContinuation` (which `Parse.shelves` now reads). Signed
in, Home was 2 shelves on screen of 10 in total. `FeedView` (Home, Explore, See All) now
takes a browseId, fetches the next page when a sentinel at the end appears, and prefixes
shelf ids per page (they restart at 0 each page). Home's mood chips
(`chipCloudChipRenderer`: select = `navigationEndpoint`, deselect = `onDeselectedCommand`,
both on `FEmusic_home` with different params) render under the title. Music-video shelves
(`musicTwoRowItemRenderer.aspectRatio` = `…_RECTANGLE_16_9`) get 16:9 tiles.
`--probe-nav` walks and logs every home page (`home_N.json`).

**Single click plays** — track rows, shelf cells and queue rows.

**Playback bug found on the signed-in session:** the bridge registered player listeners as
global-name *strings* (`addEventListener('onStateChange', '__ytmOnState')`). The newer
player build served to this account dispatches with `listener.apply()`, so
`loadVideoById` threw `this.U[x+1].apply is not a function` and no track could start
(signed out — and so in the ephemeral `--selftest` — the older build still accepted
strings, which is why the self-test kept passing). Listeners are now functions. Bridge
`log` events are now written to app.log, and the watch-page fallback both starts the track
itself on `ready` (it used to trust autoplay and sit paused) and is capped at one retry.

---

## 3c. Done (session 5, 2026-09-23): Explore and Charts

Explore is built from `musicNavigationButtonRenderer`s, which were being dropped. They
parse into `NavButton` (`Shelf.buttons`) and render in `UI/Components/NavButtons.swift`:
the icon buttons (New releases / Charts / Moods & genres) as a row of destination tiles,
and moods and genres as Apple Music-style category tiles — a `MeshGradient` built from
YouTube's `leftStripeColor`, pushed to full saturation and dark enough for white text
(greys become graphite, yellows lean amber, warm shades darken towards red rather than
brown). Two rows paging sideways on Explore, a wrapping grid on the Moods & genres page.
Every button opens its browseId (+ params) as a `seeAll` feed. `gridRenderer` shelves are
`isGrid` and wrap instead of paging.

**Charts country picker** — `FeedPage.filter` (`Parse.feedFilter`) reads the
`musicSortFilterButtonRenderer` menu; `FeedView` shows it as a glass pull-down under the
title and re-requests the page with `formData: {selectedValues: [<code>]}` (what the web
app's form binder sends). The choice persists in `feed.filter.<browseId>`. The country code
is inside each option's `formItemEntityKey` (base64 protobuf, field 2:
`explore_charts_country_menu_<digits><CC>`) — **in the app the string also carries the
referring page after the code** (`…567ZZFEmusic_explore`), so take exactly two capitals.
The dump from `--probe-nav` doesn't show that suffix.

**Ranked rows** — `customIndexColumn` → `ChartRank` (position + up/down/same) on `Card`
and `Track`. A shelf whose cards are all ranked (Top artists, Weekly top podcast shows)
renders as `RankedShelfGrid` (`UI/Components/RankedShelf.swift`): numbered rows in
columns of five with a trend arrow, paging sideways.

**Player pill on pushed pages** — it was an overlay on the `NavigationStack`, and on
macOS each pushed page (album, artist, playlist, See All) is hosted in its own AppKit
view that draws above such an overlay, so the pill vanished off the root page. It is now
attached to every page (`withPlayerPill()` in `RootView.swift`). Don't move it back.

**Sidebar, Music.app proportions** — `SidebarView` is now a hand-laid `ScrollView`, not a
`List`, so it can match Music.app on macOS 26: 32pt rows, 15pt titles, outlined accent
SF Symbols (`NavItem.symbol`; Explore is a compass, `safari`), a filled accent capsule
with white text for the selection, 13pt grey section headers. Charts is added after
Explore (`Router.primaryItems`, `Guide.charts`). The Library section only appears when
there is one: signed out it is replaced by a sign-in prompt, and in guest mode it is gone.

**Sign-in happens in the default browser** (user's choice) — every Sign In calls
`SignIn.start()` (`UI/BrowserSignIn.swift`). If the default browser is supported (Safari
today), a small window watches the browser: it needs Full Disk Access to read Safari's
`Cookies.binarycookies` (the window walks the user through granting it and carries on by
itself); if Safari is signed out it opens Google's sign-in there and polls every 2s; once
`SAPISID` appears it copies only the Google/YouTube cookies into the account store
(`BrowserImport.install`, which first clears old Google cookies) and reloads. Chromium
browsers aren't read yet (Keychain-encrypted SQLite) and fall back to the in-app
`AuthWindow`, which also stays reachable from the window. Dev builds are ad-hoc signed, so
Full Disk Access must be re-granted after each rebuild (only needed while signing in).

## 4. Next

- Advanced features: library mutation (like / add to playlist), search continuations,
  search suggestions in the field.
- Not yet checked in light mode.

---

Not started at all: library mutation (like / add-to-playlist), search continuations, and
offline downloads (infeasible on this architecture — the audio never leaves WebKit).
