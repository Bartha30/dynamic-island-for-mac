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
- Menu bar icon and right-click menu: **Show/Hide Island**, **Launch at Login**, **Quit**
- No Dock icon, stays out of your way

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
| Right-click the island, or the menu bar icon | Hide, Launch at Login, Quit |

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

- Only Spotify and Apple Music (see above).
- The song info refreshes once a second, so there can be a tiny delay after changes.
- If Spotify changes its AppleScript support, the Spotify side may break until the app is updated.
