# Dottie Forever

An Apple Silicon macOS project for routing a microphone, ChatGPT voice and optional Discord voice, with a wake/standby gate on the feed to the assistant.

This is a **source review snapshot**, not an installer or release. It includes the current routing interface, native controller sources and core mixer source. The interface can run as a browser preview with simulated audio. The snapshot does not contain the privileged loader, HAL package, capture host, speech weights/fixtures, development machine configuration, or installation automation. It cannot install a driver or start routing by itself. ChatGPT calls are started separately in ChatGPT.

## Interface preview

With Node 24, from this directory:

```sh
npm --prefix frontend ci
npm --prefix frontend test
npm --prefix frontend run dev
```

Open the local URL printed by Vite with `?preview=1`. The preview neither records nor routes audio.

## WoW knowledge is separate

The Polestar card identifies a separate reference for WoW Forever and does not claim that a reference is active or connected. Thanks to [fitzforge and the Polestar contributors](https://github.com/fitzforge/polestar). See [Polestar reference setup](docs/POLESTAR.md) for public upstream options. No game data or hosted service connection is bundled.

## Distribution status

No license grant or public distribution commitment is made in this snapshot. Use generic symbols while reviewing the rights to the intended branding, speech dependencies and native components. Neither this snapshot nor its preview is a claim that live routing or a production installer has been verified.
