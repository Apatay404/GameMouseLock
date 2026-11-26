# GameMouseLock

Keep your gaming mouse on the display where your game is running. GameMouseLock detects the game window, confines the selected mouse to that display, and releases it when you Command-Tab away. The built-in game profile targets League of Legends matches, including PBE. Use **Choose game** for other games.

## Build and run

1. On a Mac with Xcode installed, clone or download this repository and open **GameMouseLock.xcodeproj**.
2. Select the **GameMouseLock** scheme and **My Mac**, then press **⌘R**. The project uses local signing and has no external dependencies. Its deployment target is macOS 13.
3. For regular use, stop the debug session. Under **Products** in Xcode, right-click **GameMouseLock.app**, choose **Show in Finder**, copy the app into Applications, and open that copy.
4. Grant the app **Accessibility** and **Input Monitoring** under **System Settings → Privacy & Security**. Quit and reopen the installed app after granting access.

## Use it

Select your gaming mouse in the window. Wireless mice can appear under the receiver’s name. Start a match and bring the game to the front to activate the lock. If the device entry changes after reconnecting it, select it again. **Pause** temporarily disables capture.

**Scroll wheel speed** sets the distance sent for each wheel step during capture. Choose 1×, 2×, 3×, 4×, 8×, or 16×. The default is 8×, and the app remembers your selection.

**Start at login** is optional. Enable it from your installed copy to launch the app when you sign in. If macOS requests approval, click **Approve in System Settings**. Clear the checkbox to remove the login item.

GameMouseLock reads relative movement from the selected external mouse and posts bounded cursor movement at a target of 240 updates per second. Buttons and wheel input flush pending movement immediately. Other pointing devices remain available. Games that require direct hardware input can behave differently. The timing readout measures the interval from the latest movement sample to posting the event. Game rendering adds its own latency.

## Build from Terminal

Run these commands from the repository root with Xcode selected as the developer directory.

```sh
xcodebuild -project GameMouseLock.xcodeproj -scheme GameMouseLock -configuration Release -derivedDataPath build build
build/Build/Products/Release/GameMouseLock.app/Contents/MacOS/GameMouseLock --test
```

The self-test checks display boundaries and lists attached mouse interfaces without taking control of a device.

## Credits and license

GameMouseLock uses the MIT license. The pink icon adapts the original mouse design from mxrlkn’s mouselock project. Its license is included in THIRD-PARTY-NOTICES. [Original project](https://github.com/mxrlkn/mouselock)
