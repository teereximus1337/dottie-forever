# Wake-word dependencies

Dottie Forever builds its keyword worker locally. The build downloads pinned upstream dependencies over HTTPS and verifies SHA-256 for the three archives, the Sherpa header and license, and every extracted file used in the app. The repository contains the original worker and tokenizer source. The model runs locally on the Mac and accepts English phrases only.

| Dependency | Exact source and license |
| --- | --- |
| Sherpa ONNX 2.0.1 | [macOS arm64 shared no-TTS release](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v2.0.1) and [Apache-2.0 license](https://github.com/k2-fsa/sherpa-onnx/blob/v2.0.1/LICENSE) |
| ONNX Runtime 1.28.2 | The Mach-O dylib comes from the Sherpa release. The MIT license and third-party notices come from the [exact macOS arm64 dependency archive](https://github.com/csukuangfj/onnxruntime-libs/releases/tag/v1.28.2) pinned by [Sherpa’s build recipe](https://github.com/k2-fsa/sherpa-onnx/blob/v2.0.1/cmake/onnxruntime-osx-arm64.cmake). The Sherpa dylib and the dependency archive’s dylib differ in bytes. |
| English GigaSpeech Zipformer KWS model, 3.3M, 2024-01-01 | [Sherpa’s official model archive](https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2), with an Apache-2.0 declaration in the model card and [maintainer confirmation](https://github.com/k2-fsa/sherpa-onnx/issues/3802). The payload uses the FP32 encoder, decoder and joiner, `bpe.model`, and `tokens.txt`. Model training used GigaSpeech XL. The build selects model artifacts and preserves their notices. |
| SentencePiece model format | The original tokenizer uses the published [v0.2.1 protobuf specification](https://github.com/google/sentencepiece/blob/v0.2.1/src/sentencepiece_model.proto) as a wire-format reference. The worker does not link the SentencePiece library. Sherpa embeds the separately listed Simple SentencePiece library. |

## Libraries embedded in Sherpa ONNX

The compact Sherpa runtime archive includes these libraries in its C API dylib. [The notice manifest](SHERPA-DEPENDENCY-NOTICES.tsv) pins their upstream notice files. The build also extracts the Darts-clone copyright and BSD-2-Clause terms directly from the pinned Simple SentencePiece header.

| Component | Version and source |
| --- | --- |
| Kaldi Native Fbank | [1.22.4](https://github.com/csukuangfj/kaldi-native-fbank/tree/v1.22.4) |
| KISS FFT | [`febd4caeed32e33ad8b2e0bb5ea77542c40f18ec`](https://github.com/mborgerding/kissfft/tree/febd4caeed32e33ad8b2e0bb5ea77542c40f18ec) |
| utf8proc | [2.12.0](https://github.com/JuliaStrings/utf8proc/tree/v2.12.0) |
| Kaldi Decoder and kaldi-fst | [0.3.0](https://github.com/k2-fsa/kaldi-decoder/tree/v0.3.0) and [1.8.0](https://github.com/k2-fsa/kaldifst/tree/v1.8.0) |
| OpenFst | [1.8.5, 2026-07-09](https://github.com/csukuangfj/openfst/tree/v1.8.5-2026-07-09) |
| Simple SentencePiece and its Darts-clone code | [0.7 and vendored Darts-clone 0.32](https://github.com/pkufool/simple-sentencepiece/blob/v0.7/ssentencepiece/csrc/darts.h) |
| JSON for Modern C++ and its Hedley header | [3.12.0](https://github.com/nlohmann/json/tree/v3.12.0). The Hedley header is MIT-licensed and credits Evan Nemerson (2016–2021). |
| hclust-cpp | [2026-02-25](https://github.com/csukuangfj/hclust-cpp/tree/2026-02-25) |
| Eigen | [5.0.1 source archive](https://gitlab.com/libeigen/eigen/-/archive/5.0.1/eigen-5.0.1.tar.gz), SHA-256 `e9c326dc8c05cd1e044c71f30f1b2e34a6161a3b6ecf445d56b53ff1669e3dec`. This is the MPL-covered source used by the [Sherpa build recipe](https://github.com/k2-fsa/sherpa-onnx/blob/v2.0.1/cmake/eigen.cmake). |

## Local worker

The worker uses one CPU inference thread at 16 kHz and eight active paths. It starts with an internal silent context, reads normalized little-endian mono float32 PCM on stdin, and emits newline-delimited JSON. The app handles microphone and Discord capture separately. Wake and standby phrases are distinct, with 1–64 English ASCII characters using letters, spaces, and apostrophes.

The standalone build command is `sh macos/keyword/package.sh` from the repository root. It produces `macos/keyword/build/package/` and checks that the exact pinned runtime and model initialize. To rebuild the standalone package, move the previous output aside first. A worker startup check covers process and model initialization. Live wake and standby behavior depend on the configured audio devices, speakers, and Discord audio path.
