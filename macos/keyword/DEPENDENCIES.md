# Wake-word dependencies

Dottie Forever builds its keyword worker locally. The build downloads pinned upstream dependencies over HTTPS and verifies SHA-256 for the three archives, the Sherpa header and license, and every extracted file used in the app. The repository contains the original worker and tokenizer source. The model runs locally on the Mac and accepts English phrases only.

| Dependency | Exact source and license |
| --- | --- |
| Sherpa ONNX 2.0.1 | [macOS arm64 shared no-TTS release](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v2.0.1) and [Apache-2.0 license](https://github.com/k2-fsa/sherpa-onnx/blob/v2.0.1/LICENSE) |
| ONNX Runtime 1.28.2 | The Mach-O dylib comes from the Sherpa release. The MIT license and third-party notices come from the [exact macOS arm64 dependency archive](https://github.com/csukuangfj/onnxruntime-libs/releases/tag/v1.28.2) pinned by [Sherpa’s build recipe](https://github.com/k2-fsa/sherpa-onnx/blob/v2.0.1/cmake/onnxruntime-osx-arm64.cmake). The Sherpa dylib and the dependency archive’s dylib differ in bytes. |
| English GigaSpeech Zipformer KWS model, 3.3M, 2024-01-01 | [Sherpa’s official model archive](https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2), with an Apache-2.0 declaration in the model card and [maintainer confirmation](https://github.com/k2-fsa/sherpa-onnx/issues/3802). The payload uses the FP32 encoder, decoder and joiner, `bpe.model`, and `tokens.txt`. Model training used GigaSpeech XL. The build selects model artifacts and preserves their notices. |
| SentencePiece model format | The original tokenizer uses the published [v0.2.1 protobuf specification](https://github.com/google/sentencepiece/blob/v0.2.1/src/sentencepiece_model.proto) as a wire-format reference. No SentencePiece dependency is linked. |

The worker uses one CPU inference thread at 16 kHz and eight active paths. It starts with an internal silent context, reads normalized little-endian mono float32 PCM on stdin, and emits newline-delimited JSON. The app handles microphone and Discord capture separately. Wake and standby phrases are distinct, with 1–64 English ASCII characters using letters, spaces, and apostrophes.

The standalone build command is `sh macos/keyword/package.sh` from the repository root. It produces `macos/keyword/build/package/` and checks that the exact pinned runtime and model initialize. To rebuild the standalone package, move the previous output aside first. A worker startup check covers process and model initialization. Live wake and standby behavior depend on the configured audio devices, speakers, and Discord audio path.
