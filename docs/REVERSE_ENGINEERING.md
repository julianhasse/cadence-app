# Silicio 3.7.3 — reverse-engineering notes

Target: `Silicio.app` (`de.janbolz.silicio`, build 2260, Mac App Store, universal x86_64/arm64).
Main binary SHA-256 `9cc1b84053b6512bdf955024819d610d156253794f228c11a51986e8538c7365`.

These notes describe **behaviour** only. Cadence is a from-scratch reimplementation: it copies no
code, storyboards, images or other assets from Silicio.

## Method and limits

- REA `open_binary` + `decode_interface_builder` decoded 45 compiled storyboard/nib archives
  (Evidence `ev_1d8d3945696287dbd53cfd6846393af5110837868b9ea84056da8bf71e28d344`):
  12 view controllers, 150 IB actions, 361 outlets.
- `otool -ov`, `otool -L` and `strings` on the thinned arm64 slice gave the Swift/ObjC class list,
  selectors, UserDefaults keys and URLs.
- **No decompilation was done.** Ghidra, Hopper, IDA and Kuna are not installed or configured, so REA
  had no native provider. Function bodies are unknown. Everything below comes from metadata, strings
  and the interface files, not from observed execution.

## Architecture (observed)

| Area | Silicio classes / frameworks | Evidence |
|---|---|---|
| Player bridge | `TunesSense.framework` (Pods): `MusicApplication`, `SpotifyApplication` via ScriptingBridge, `findActivePlayer`, `forcedPlayer`, `heardBeatWithPlayerPolling`, listens to `com.apple.Music.playerInfo`, `com.spotify.client.PlaybackStateChanged`, Vox/Doppler/Deezer notifications | strings |
| Artwork fallback | iTunes Search API `itunes.apple.com/search?entity=album&media=music&limit=1&term=` | TunesSense strings |
| Mini player | `PlayerViewController`, `PlayerView`, `PlayerRootView`, `ProgressBarView`, `PlayerImageView`, three themes *Targa*, *Grande* (`PlayerGrandeBlockView/EffectView`), *Superleggera* (`PlayerSuperleggeraEffectView`) | classes, IB outlets |
| Menu bar | `MenuController`, `PopoverManager`, `PopoverVolumeViewController` | classes, Popover.storyboard |
| Context menu | `contextGoToGenius/Discogs/Wikipedia/Bandcamp/Songkick/Pitchfork/Metacritic/NME/Amazon/eBay/Merchbar/Patreon/Steady/Lastfm`, `contextLoveTrack`, `contextDislikeTrack`, `contextSize`, `contextMenuSelectSource`, `contextMenuShare*` | IB actions + URL strings |
| Last.fm | `LastFm.framework`, `LastfmController/Listener/Cache/Stats`; `sendNowPlayingTrack`, `sendScrobbledTrack`, `loveTrack`, offline cache ("Songs will be cached and scrobbled later…") | selectors/strings |
| Spotify Web API | `SpotifyController`, `SpotifyAccount`, OAuth `accounts.spotify.com/authorize` + `/api/token`, `api.spotify.com/v1/me/tracks` (save/like) | strings |
| Sharing | `ShareController`, `ShareCanvas` (renders a shareable image), `STTwitter` | classes |
| Notifications | `NotificationsController`, UserNotifications | classes |
| Shortcuts | `MASShortcut`; keys `playPauseKey nextKey previousKey showHideKey showPlayerKey showSongKey loveSongKey dislikeSongKey` | strings |
| Preferences | General, Appearance, Notifications, Last.fm, Shortcuts tabs (`Preferences*` controllers) | IB |
| Other | Touch Bar controller, Today widget + WidgetKit extension, URL scheme `silicioapp://`, rate-app prompt, crash handler | bundle layout, Info.plist |

Notable settings keys: `alwaysOnTop`, `hideWhenNoPlayerFound`, `menuBarShowsMiniPlayer`,
`lengthDisplayMode`, `timestampDisplayMode`, `playerColor`, `progressBarColor`,
`progressBarUsesSameColor`, `scrobblingEnabled`, `windowSize`, `isPlayerControlsVisibleOnMouseOver`.

## What Cadence covers

| Silicio feature | Cadence |
|---|---|
| Music + Spotify detection and control | ✅ AppleScript (`PlayerManager`, `ScriptablePlayer`) |
| Floating mini player, 3 themes, 3 sizes | ✅ Cover / Card / Strip (original designs) |
| Always on top, all Spaces, lock position, hide when idle | ✅ |
| Hover-only controls, elapsed/remaining time, custom or artwork-derived colour | ✅ |
| Menu bar item + context menu, player selection | ✅ |
| Look-up links | ✅ data-driven `LookupProvider.all` |
| Love track | ✅ Music favourite + Last.fm love |
| Last.fm now playing, scrobbling, offline queue | ✅ |
| Song-change notifications | ✅ |
| Global shortcuts | ✅ Carbon hotkeys, no third-party dependency |
| URL scheme | ✅ `cadence://playpause|next|previous|love|toggle|show|hide|settings` |
| Share | ✅ copy text + system share sheet (no Twitter API) |
| Spotify Web API (save to library) | ❌ needs your own Spotify client ID |
| Share canvas image | ❌ |
| Widgets, Touch Bar | ❌ widgets need an Xcode project with an extension target |
| Volume popover, dislike | ❌ |
