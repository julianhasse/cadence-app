# Cadence

A macOS menu-bar mini player for Apple Music and Spotify, with Last.fm scrobbling. It is a clean-room
rebuild of the feature set of Silicio. See [docs/REVERSE_ENGINEERING.md](docs/REVERSE_ENGINEERING.md).

Requirements: macOS 13+, Swift 5.9+ (Xcode 15+).

## Build and run

```bash
Scripts/build_app.sh          # release, universal → build/Cadence.app
open build/Cadence.app
```

Run it from the bundled `.app`, not with `swift run`. Notifications, the Automation prompt and
launch at login all need a bundle identifier. To work in Xcode, run `open Package.swift`.

On first use, macOS asks for permission to control Music or Spotify. If you deny it, re-enable it in
System Settings › Privacy & Security › Automation.

For Last.fm, create an API account at <https://www.last.fm/api/account/create>, then enter the key and
secret in Settings › Last.fm and sign in.

## Layout

```
Sources/Cadence/
  App/            main.swift, AppDelegate (wiring, URL scheme, hotkey dispatch)
  Players/        Models, ScriptablePlayer (AppleScript per player), PlayerManager (polling, active-player choice, commands)
  Services/       LastFMClient, Scrobbler + ScrobbleQueue, SongNotifier, HotKeys, ArtworkFetcher
  Support/        AppSettings (UserDefaults), Keychain
  UI/             MiniPlayerWindowController + MiniPlayerView (themes), StatusBarController, MenuBuilder
  UI/Preferences/ Settings window (General, Appearance, Notifications, Last.fm, Shortcuts)
```

## Extending

- **New player** (Vox, Doppler, etc.): add a case to `PlayerKind` and give it a snapshot script in `ScriptablePlayer`.
- **New theme**: add a case to `PlayerTheme`, its size to `MiniPlayerWindowController.contentSize` and a view to `MiniPlayerView.content`.
- **New look-up link**: append to `LookupProvider.all`.
- **New shortcut**: add a case to `ShortcutAction` and handle it in `AppDelegate.perform`.
- **New setting**: add a property to `AppSettings`. Views bind with `$settings.prop`, and other code listens for `.settingsChanged`.
