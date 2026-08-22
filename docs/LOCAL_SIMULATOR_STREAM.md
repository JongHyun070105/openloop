# Local iPhone 16 simulator preview

This is a development-only preview. It captures the booted macOS iOS Simulator
with `xcrun simctl` and serves a localhost MJPEG stream; it is not part of the
Netlify build and cannot be used after deployment.

## Run

1. Boot the iPhone 16 simulator and install/launch the Flutter app.
2. From `apps/demo`, start the bridge:

   ```sh
   npm run dev:sim -- --udid 82E1F0A9-181D-40BB-82B4-5443B951AE3A --fps 5
   ```

   `--udid booted` is the default. `SIMULATOR_UDID` and `SIM_STREAM_FPS`
   environment variables can be used instead.

3. Start Vite in another terminal and open:

   ```text
   http://127.0.0.1:5173/?simulator=1
   ```

The website proxies `/__simulator/stream` to the bridge and places the live
screen directly on the page without a mock phone frame. Taps and swipe gestures
on the stream are forwarded to the Simulator through the macOS Accessibility
and CoreGraphics input bridge. This is intentionally localhost-only and should
never be exposed to an untrusted network.

Health, one-frame, and input endpoints are available at `/health`,
`/snapshot.jpg`, and `POST /input` on port `4174`.
