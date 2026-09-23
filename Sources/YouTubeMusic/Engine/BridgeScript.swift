import Foundation

/// JavaScript injected into every music.youtube.com document.
///
/// It does three jobs:
///   1. exposes `window.__ytm.innertube()` so native code can call YouTube's private
///      API *from inside the authenticated page* — cookies and the SAPISIDHASH
///      signature come for free, so we never have to lift the session out of WebKit;
///   2. wraps the `#movie_player` object with a small command/snapshot surface;
///   3. re-claims the page's Media Session handlers so hardware media keys that WebKit
///      routes to the page end up back in our native player controller.
enum BridgeScript {
    static let handlerName = "ytm"

    static let source = #"""
(() => {
  'use strict';
  if (window.__ytm) { return; }

  const ORIGIN  = 'https://music.youtube.com';
  const POLL_MS = 500;

  const send = (type, payload) => {
    try {
      window.webkit.messageHandlers.ytm.postMessage({
        type: type,
        payload: (payload === undefined) ? null : payload
      });
    } catch (e) { /* host handler not attached */ }
  };

  const cfg = (key) => {
    try { return (window.ytcfg && window.ytcfg.get) ? window.ytcfg.get(key) : undefined; }
    catch (e) { return undefined; }
  };

  const cookie = (name) => {
    const m = new RegExp('(?:^|;\\s*)' + name + '=([^;]*)').exec(document.cookie);
    return m ? m[1] : null;
  };

  // Authenticated InnerTube calls are signed with SHA1("<unix ts> <SAPISID> <origin>").
  async function authorization() {
    const sapisid = cookie('SAPISID') || cookie('__Secure-3PAPISID') || cookie('__Secure-1PAPISID');
    if (!sapisid) { return null; }
    const ts     = Math.floor(Date.now() / 1000);
    const digest = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(ts + ' ' + sapisid + ' ' + ORIGIN));
    const hex    = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
    return 'SAPISIDHASH ' + ts + '_' + hex;
  }

  const player = () => {
    const p = document.getElementById('movie_player');
    return (p && typeof p.playVideo === 'function') ? p : null;
  };

  const guard = (fn, dflt) => { try { const v = fn(); return (v === undefined || v === null) ? dflt : v; } catch (e) { return dflt; } };
  const guardNum = (fn, dflt) => { const v = guard(fn, dflt); return (typeof v === 'number' && isFinite(v)) ? v : dflt; };

  const snapshot = () => {
    const p = player();
    if (!p) {
      return { ok: false, videoId: '', title: '', author: '', state: -1,
               time: 0, duration: 0, loaded: 0, volume: 100, muted: false, ad: false };
    }
    const d = guard(() => p.getVideoData(), {}) || {};
    return {
      ok:       true,
      videoId:  d.video_id || '',
      title:    d.title || '',
      author:   d.author || '',
      state:    guardNum(() => p.getPlayerState(), -1),
      time:     guardNum(() => p.getCurrentTime(), 0),
      duration: guardNum(() => p.getDuration(), 0),
      loaded:   guardNum(() => p.getVideoLoadedFraction(), 0),
      volume:   guardNum(() => p.getVolume(), 100),
      muted:    guard(() => !!p.isMuted(), false),
      ad:       guard(() => p.getAdState() === 1, false)
    };
  };

  const api = {
    signedIn: () => !!cfg('LOGGED_IN') || !!cookie('SAPISID'),
    snapshot: snapshot,
    diagnostics: () => ({
      href:          location.href,
      signedIn:      api.signedIn(),
      hasPlayer:     !!player(),
      clientVersion: cfg('INNERTUBE_CLIENT_VERSION') || null,
      visitorData:   cfg('VISITOR_DATA') ? 'present' : null,
      sessionIndex:  cfg('SESSION_INDEX') || 0
    }),

    // Returns the raw response body; parsing happens natively.
    //
    // `client` overrides the InnerTube client the request presents as. Some data is only
    // served to other clients (timed lyrics go to ANDROID_MUSIC), and those requests
    // must not carry the web client's headers or YouTube rejects the mismatch.
    //
    // These client-spoofed requests fetch only public data (lyrics), so they go out with
    // `credentials: 'omit'` — anonymous. Attaching the account cookies would mean your
    // signed-in identity making requests that claim to be YouTube's Android app, which is
    // the oddest-looking traffic the app could produce; omitting them removes that signal.
    async innertube(endpoint, body, client) {
      if (client) {
        const ctx = { client: Object.assign({ hl: (cfg('INNERTUBE_CONTEXT') || {}).client?.hl || 'en',
                                              gl: (cfg('INNERTUBE_CONTEXT') || {}).client?.gl || 'US' }, client) };
        const r = await fetch(ORIGIN + '/youtubei/v1/' + endpoint + '?prettyPrint=false', {
          method: 'POST', credentials: 'omit',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(Object.assign({ context: ctx }, body || {}))
        });
        if (!r.ok) { throw new Error('innertube/' + endpoint + ' (' + client.clientName + ') HTTP ' + r.status); }
        return await r.text();
      }
      const context = cfg('INNERTUBE_CONTEXT') || {
        client: { clientName: 'WEB_REMIX', clientVersion: '1.20250310.01.00', hl: 'en', gl: 'US' }
      };
      const headers = {
        'Content-Type':            'application/json',
        'X-Goog-Visitor-Id':       cfg('VISITOR_DATA') || '',
        'X-Youtube-Client-Name':   String(cfg('INNERTUBE_CONTEXT_CLIENT_NAME') || 67),
        'X-Youtube-Client-Version': String(cfg('INNERTUBE_CLIENT_VERSION') || context.client.clientVersion),
        'X-Goog-AuthUser':         String(cfg('SESSION_INDEX') || 0),
        'X-Origin':                ORIGIN
      };
      const auth = await authorization();
      if (auth) { headers['Authorization'] = auth; }

      const res = await fetch(ORIGIN + '/youtubei/v1/' + endpoint + '?prettyPrint=false', {
        method:      'POST',
        credentials: 'include',
        headers:     headers,
        body:        JSON.stringify(Object.assign({ context: context }, body || {}))
      });
      if (!res.ok) { throw new Error('innertube/' + endpoint + ' HTTP ' + res.status); }
      return await res.text();
    },

    command(name, arg) {
      const p = player();
      if (!p) { return false; }
      try {
        switch (name) {
          case 'play':   p.playVideo();  return true;
          case 'pause':  p.pauseVideo(); return true;
          case 'seek':   p.seekTo(Number(arg), true); return true;
          case 'volume': p.setVolume(Math.max(0, Math.min(100, Math.round(Number(arg))))); return true;
          case 'mute':   if (arg) { p.mute(); } else { p.unMute(); } return true;
          case 'load':   p.loadVideoById({ videoId: String(arg) }); return true;
          case 'cue':    p.cueVideoById({ videoId: String(arg) });  return true;
          case 'stop':   p.stopVideo(); return true;
        }
      } catch (e) {
        send('log', { text: 'command ' + name + ' failed: ' + e.message });
      }
      return false;
    },

    // Mirrors our native metadata onto the page so Control Center shows the right
    // track even while WebKit owns the system Now Playing session.
    setMetadata(meta) {
      try {
        if (!navigator.mediaSession || !window.MediaMetadata) { return false; }
        navigator.mediaSession.metadata = new MediaMetadata({
          title:  meta.title  || '',
          artist: meta.artist || '',
          album:  meta.album  || '',
          artwork: meta.artwork ? [{ src: meta.artwork, sizes: '512x512', type: 'image/jpeg' }] : []
        });
        return true;
      } catch (e) { return false; }
    },

    // Why a track will not play: YouTube reports its verdict here.
    playability() {
      const p = player();
      if (!p) { return { ok: false }; }
      const r = guard(() => p.getPlayerResponse(), {}) || {};
      const ps = r.playabilityStatus || {};
      return {
        ok: true,
        status: ps.status || '',
        reason: ps.reason || (ps.errorScreen ? JSON.stringify(ps.errorScreen).slice(0, 220) : ''),
        state: guardNum(() => p.getPlayerState(), -1),
        muted: guard(() => !!p.isMuted(), false),
        volume: guardNum(() => p.getVolume(), -1),
        hasApp: !!document.querySelector('ytmusic-app'),
        url: location.href
      };
    },

    navigate(url) { window.location.href = url; }
  };

  window.__ytm = api;

  window.__ytmOnState = function () { send('state', snapshot()); };
  window.__ytmOnError = function (code) { send('error', { code: Number(code) || 0 }); };

  // YouTube Music reinstalls its own Media Session handlers as it navigates, so we
  // re-claim them on every tick rather than once at startup.
  function claimMediaKeys() {
    const ms = navigator.mediaSession;
    if (!ms || !ms.setActionHandler) { return; }
    const bind = (action, fn) => { try { ms.setActionHandler(action, fn); } catch (e) {} };
    bind('play',          () => send('remote', { action: 'play' }));
    bind('pause',         () => send('remote', { action: 'pause' }));
    bind('previoustrack', () => send('remote', { action: 'previous' }));
    bind('nexttrack',     () => send('remote', { action: 'next' }));
    bind('stop',          () => send('remote', { action: 'stop' }));
    bind('seekto',        (d) => send('remote', { action: 'seek', time: (d && d.seekTime) || 0 }));
  }

  let bound = null;
  function attach() {
    const p = player();
    if (p && bound !== p) {
      bound = p;
      // Functions, not global-name strings: newer player builds dispatch with
      // listener.apply(), and a string listener throws inside loadVideoById —
      // "this.U[x+1].apply is not a function" — so nothing would ever start.
      try { p.addEventListener('onStateChange', window.__ytmOnState); } catch (e) {}
      try { p.addEventListener('onError',       window.__ytmOnError); } catch (e) {}
      // Our native queue is authoritative — stop YouTube from auto-advancing.
      try { p.setAutonavState(1); } catch (e) {}
      send('ready', { signedIn: api.signedIn(), snapshot: snapshot() });
    }
    claimMediaKeys();
  }

  setInterval(attach, 400);
  setInterval(() => { const s = snapshot(); if (s.ok) { send('tick', s); } }, POLL_MS);
  attach();
  send('injected', { href: location.href, signedIn: api.signedIn() });
})();
"""#
}
