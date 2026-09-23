# Music for YouTube

A native macOS player for YouTube Music, designed like Apple Music on macOS 26.
Playback runs through YouTube Music's own web player, so Premium, your library, history and
recommendations work just as they do on the web.

- Home, Explore, Charts (by country), moods & genres, search and your library
- Synced lyrics, queue, full-screen and mini players, menu bar controls, media keys
- Sign in with the browser you already use (Safari), or listen as a guest
- Keeps itself up to date

## Install

Open **Terminal** and paste:

```sh
curl -fsSL https://raw.githubusercontent.com/emonsaqibh/music-for-youtube-releases/main/install.sh | bash
```

This downloads the latest version, puts it in Applications and opens it. Later versions
install themselves from inside the app: an **Update Available** card appears in the
sidebar, or choose **Music for YouTube › Check for Updates…**.

**Requirements:** macOS 26 or later on an Apple silicon Mac.

### Why a Terminal command?

The app isn't notarized by Apple, and macOS refuses to open an un-notarized app that was
downloaded in a browser ("Apple could not verify … is free of malware"). Downloads made
from Terminal aren't flagged that way, so the app opens normally. The script is short.
[Read it first](install.sh) if you like.

If you'd rather download the zip from [Releases](../../releases) yourself: unzip it, move
the app to Applications, try to open it once, then go to **System Settings › Privacy &
Security**, scroll down and click **Open Anyway**.

## Signing in

**Sign In** opens Google's sign-in in your default browser. Once you're signed in there,
the app picks the session up. Only Google and YouTube sign-in cookies are copied, and your
browser isn't changed. For Safari, macOS asks you to allow **Full Disk Access** once; the
app walks you through it. Other browsers use a sign-in window inside the app.

---

Music for YouTube is an independent, personal project. It is not affiliated with,
endorsed by or sponsored by YouTube or Google. YouTube and YouTube Music are trademarks
of Google LLC.
