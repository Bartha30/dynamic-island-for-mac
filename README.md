# Dynamic Island for Mac

An iPhone-style Dynamic Island for your MacBook's notch. It shows what's playing in **Spotify** or **Apple Music**, and you can control playback without leaving what you're doing.

## Features

- **Collapsed pill** around the notch with the album cover and a live "playing" indicator tinted to the cover's colour
- **Click to expand** for a full player:
  - Large album artwork with a soft glow in its colour
  - Song, artist and album
  - Draggable progress bar: drag or click anywhere to jump in the song
  - Back / play-pause / next buttons (Liquid Glass on macOS 26)
  - System volume bar
- Click the artwork or song title to open Spotify / Music
- Click anywhere outside the island to collapse it
- Clicks around the island pass straight through to whatever is underneath
- Menu bar icon and right-click menu: **Now Playing Screen**, **Show/Hide Island**, **Launch at Login**, **Settings…**, **Quit**
- No Dock icon, stays out of your way

### Now Playing Screen (new in 1.1)

A full-screen view inspired by the iPhone lock screen, for when you're listening rather than working:

- **Player on the left:** large album cover, song and artist, draggable progress bar, playback controls and volume, on a blurred backdrop of the cover
- **Live lyrics on the right:** the line being sung lights up and the list glides along with the song, Apple Music-style. Click any line to jump to it
- **Opens automatically** after your Mac has been idle for the time you choose (only while music is playing), or anytime with **⌥⌘L**, the **⤢** button on the expanded island, or the right-click menu
- **Enter** or **Esc** closes it; **Space** plays or pauses
- While music plays, the display stays awake. When music stops, your Mac sleeps on its normal schedule again
- Lyrics a little early or late on a particular song? Press **[** (earlier) or **]** (later) while it plays. The fix is remembered for that song

## Requirements

- macOS 13.5 or later (Liquid Glass buttons need macOS 26; older versions get plain buttons)
- A MacBook with a notch looks best. On other Macs it floats as a pill at the top of the screen
- Spotify or Apple Music

## Install

1. Go to the [Releases](../../releases) page and download the latest `.zip`.
2. Unzip it and drag **Dynamic Island for MAC.app** into your **Applications** folder.
3. Open it. The first time, macOS will block it with a message that it "can't be opened" or "can't verify the developer". This is normal for apps that aren't from the App Store and haven't been through Apple's paid notarization.
4. To allow it: open **System Settings › Privacy & Security**, scroll down to the message about *Dynamic Island for MAC*, and click **Open Anyway**. Confirm, and it will open. You only need to do this once.

   *(On macOS 14 and earlier you can instead right-click the app › **Open** › **Open**.)*

## Permissions

The first time a song plays, macOS will ask:

> "Dynamic Island for MAC" wants access to control "Spotify" (or "Music").

Click **OK**. The app needs this to read the current song and to send play, pause, skip and seek commands. It does nothing else with this access.

If you clicked **Don't Allow**, the island shows a warning. Fix it in **System Settings › Privacy & Security › Automation** by turning on Spotify and Music under *Dynamic Island for MAC*.

## How to use

| Action | What it does |
| --- | --- |
| Click the island | Expand / collapse |
| Click outside the island | Collapse |
| Drag or click the progress bar | Jump to that point in the song |
| Click the artwork or title (expanded) | Open Spotify / Music |
| Right-click the island, or the menu bar icon | Now Playing Screen, Hide, Launch at Login, Settings, Quit |
| **⌥⌘L** (from any app) | Open / close the Now Playing Screen |
| Click **⤢** on the expanded island | Open the Now Playing Screen |
| **Enter** / **Esc** on the Now Playing Screen | Close it |
| **Space** on the Now Playing Screen | Play / pause |
| Click a lyric line | Jump to that line |
| **[** / **]** on the Now Playing Screen | Show this song's lyrics earlier / later |

## Settings

Right-click the island › **Settings…** (or ⌘, while its menu is open):

- **Show after idle:** Off, 1, 2, 5, 10, 15, 30, 45 minutes or 1 hour (default 5 minutes). Set it to Off if you only want to open the screen yourself, and the Mac's sleep behaviour is left completely alone
- **Lyrics timing:** moves the lyrics earlier or later for every song, in case your Mac or speakers run differently (default +0.25 s)
- **Launch at Login**

## Lyrics

Spotify and Apple Music don't share their lyrics with other apps, so lyrics come from [LRCLIB](https://lrclib.net), a free, community-made lyrics database.

- To look lyrics up, the app sends the **song title, artist, album and length** to lrclib.net. Nothing else is sent, and only while the Now Playing Screen is open
- Coverage is best for popular English songs. When a song isn't there you'll see "No lyrics found"; when only untimed lyrics exist, they're shown without syncing
- Lines are synced one at a time (not word by word)
- Needs an internet connection. In some regions lrclib.net may need a VPN

## Supported players

- Spotify (desktop app)
- Apple Music

Browsers (YouTube, etc.), Podcasts and other apps aren't supported yet. Since macOS 15.4, Apple no longer lets third-party apps read "now playing" info system-wide, so this app asks Spotify and Music directly.

## Build from source

1. Install **Xcode** from the App Store.
2. Clone the repo:
   ```sh
   git clone https://github.com/Bartha30/dynamic-island-for-mac.git
   ```
3. Open `Dynamic Island for MAC.xcodeproj` in Xcode.
4. Under **Signing & Capabilities**, pick your own team (a free Apple ID works).
5. Press **Run ▶**.

## Known limitations

- The Now Playing Screen is a regular window, **not a lock**: pressing Enter closes it without a password, and while music plays the Mac won't lock itself on its idle timer. Lock your Mac yourself (⌃⌘Q) when you step away somewhere public
- If macOS's own screen saver is set to start sooner than your idle time, it may cover the Now Playing Screen

- Only Spotify and Apple Music (see above).
- The song info refreshes once a second, so there can be a tiny delay after changes.
- If Spotify changes its AppleScript support, the Spotify side may break until the app is updated.
