# Dottie Forever

![Dottie Forever](docs/dottie-wordmark.svg)

**Talk to your Dot without taking over guild voice.**

Dottie Forever is a Mac voice-routing project built for playing World of Warcraft: Forever with friends. The assistant feed has its own wake and standby control, so you can ask a ChatGPT Dot a question and then go back to talking to your party. Discord is optional. Game audio stays on your normal output.

**This repository is a source preview, not an installer.** You can try the routing canvas with simulated audio. This checkout cannot start live routing, listen to your mic, or open a Dot call for you.

## Watch the demo

![Dottie Forever demo, coming soon on X](docs/dottie-demo-placeholder.svg)

The X video link will go here when it’s posted.

<!-- Replace the image line with [![Watch the Dottie Forever demo](docs/dottie-demo-thumbnail.svg)](FINAL_X_POST_URL) after adding the approved final thumbnail and confirming the exact post URL. Then remove the coming-soon sentence. -->

## Try it with your Dot

If your Dot can run commands in a connected Work environment, open a fresh checkout of this repository and give it this prompt:

> In this fresh checkout of `teereximus1337/dottie-forever`, read the README and check that Node 24 is available. Run the documented frontend dependency install and tests, then start the preview server on loopback and give me the printed URL with `?preview=1` appended. Show me how the mic, ChatGPT and optional Discord connect on the simulated canvas. Do not install an app or audio driver, modify live audio settings, open a call, or fetch another copy of the project. If the environment can’t run the preview, tell me exactly what is missing. If I ask for a WoW lookup, use the public Polestar guide linked in the README and cite the specific step.

### Try it manually

From a fresh checkout with Node 24:

```sh
npm --prefix frontend ci
npm --prefix frontend test
npm --prefix frontend run dev
```

Open the local URL printed by Vite with `?preview=1` appended. The preview uses fixtures; it requests no mic access and does not connect to ChatGPT or Discord.

## Use Polestar for WoW Forever

Dottie handles audio, not quest answers. Use [Polestar’s public guides](https://polestar.guide/guides) in the Dot conversation you use for voice. For example, give your Dot the [Alliance Riverglades guide](https://polestar.guide/guides/alliance/40-50/01b-riverglades) and ask, “Who starts The Lost Scout, and who do I turn it in to? Cite the guide step.”

For a separate offline lookup, see [Polestar reference setup](docs/POLESTAR.md). The guide explains how to download and verify a pinned upstream database yourself. Nothing here changes your Dot’s tools, bundles game data, or configures a private service. The Polestar card on the canvas is a reference credit, not a live connection indicator.

Thanks to [Samir from Dots](https://x.com/_samirism) and [Fitz from Polestar](https://x.com/0xFitz). The [Polestar project and its contributors](https://github.com/fitzforge/polestar) publish the guides and data.

## What’s in this checkout

The repository includes the routing interface, native controller sources, and core mixer source. Live routing additionally needs the native capture host, compatible Core Audio driver and helper, deployment scripts, and locally configured speech recognition for wake words. Those pieces are not distributed here. There is no downloadable app or public license grant in this snapshot.
