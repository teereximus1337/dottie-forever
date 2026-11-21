// Original offline keyword worker. Audio is read only from stdin; no capture APIs.
#include "c-api-reference.h"
#include "tokenizer.hpp"
#include <array>
#include <cerrno>
#include <csignal>
#include <iostream>
#include <memory>
#include <unistd.h>

namespace {
constexpr const char* kModelName = "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01";
constexpr const char* kModelPrecision = "fp32";
constexpr int kMaxActivePaths = 8;
std::string quote(const std::string& input) {
  std::string out = "\"";
  for (const unsigned char c : input) {
    if (c == '"' || c == '\\') { out += '\\'; out += static_cast<char>(c); }
    else if (c == '\n') out += "\\n";
    else if (c >= 32) out += static_cast<char>(c);
  }
  return out + '"';
}
void emit(const std::string& line) { std::cout << line << '\n' << std::flush; if (!std::cout) throw std::runtime_error("Event consumer disconnected"); }
void error(const std::string& code, const std::string& message) { std::cout << "{\"event\":\"error\",\"code\":" << quote(code) << ",\"message\":" << quote(message) << "}\n" << std::flush; }
struct Options {
  std::string model, wake="Hey Dot", standby="Dot standby";
  bool validate=false;
  float score=1.5f,threshold=.25f,wake_score=2.0f,wake_threshold=.20f;
};
Options options(int argc, char** argv) {
  Options out;
  bool global_score=false,global_threshold=false,explicit_wake_score=false,explicit_wake_threshold=false;
  for (int i=1;i<argc;++i) {
    const std::string key=argv[i];
    if (key=="--validate-only") { out.validate=true; continue; }
    if (key=="--help") { std::cerr << "router_keyword_worker --model-dir DIR [--wake PHRASE] [--standby PHRASE] [--validate-only]\n"
      "Defaults: wake score2.0/threshold0.20; standby score1.5/threshold0.25.\n"
      "--keyword-score N / --keyword-threshold N override both phrases.\n"
      "--wake-score N / --wake-threshold N override wake only, regardless of option order.\n"
      "stdin: 16000 Hz mono little-endian float32; stdout: NDJSON\n"; std::exit(0); }
    if (i+1==argc) throw std::runtime_error("Missing option value");
    if (key=="--model-dir") out.model=argv[++i];
    else if (key=="--wake") out.wake=argv[++i];
    else if (key=="--standby") out.standby=argv[++i];
    else if (key=="--keyword-score"||key=="--keyword-threshold"||key=="--wake-score"||key=="--wake-threshold") {
      const std::string value=argv[++i]; std::size_t consumed=0; const float number=std::stof(value,&consumed);
      if (consumed!=value.size()||!std::isfinite(number)) throw std::runtime_error("Invalid keyword numeric setting");
      const bool score = key=="--keyword-score" || key=="--wake-score";
      if ((score && (number<=0||number>5)) || (!score && (number<.05f||number>.95f)))
        throw std::runtime_error("Keyword score must be (0,5], threshold [0.05,0.95]");
      if (key=="--keyword-score") { out.score=number; global_score=true; }
      else if (key=="--keyword-threshold") { out.threshold=number; global_threshold=true; }
      else if (key=="--wake-score") { out.wake_score=number; explicit_wake_score=true; }
      else { out.wake_threshold=number; explicit_wake_threshold=true; }
    }
    else throw std::runtime_error("Unknown option: "+key);
  }
  if (out.model.empty()) throw std::runtime_error("--model-dir is required");
  if (global_score&&!explicit_wake_score) out.wake_score=out.score;
  if (global_threshold&&!explicit_wake_threshold) out.wake_threshold=out.threshold;
  if (out.score<=0||out.score>5||out.threshold<.05f||out.threshold>.95f) throw std::runtime_error("Keyword score must be (0,5], threshold [0.05,0.95]");
  if (router_keyword::normalize_phrase(out.wake)==router_keyword::normalize_phrase(out.standby)) throw std::runtime_error("Wake and standby phrases must differ");
  return out;
}
}

int main(int argc, char** argv) {
  std::signal(SIGPIPE,SIG_IGN);
  try {
    const auto opt=options(argc,argv); const router_keyword::Tokenizer tokenizer(opt.model);
    const auto wake=tokenizer.encode(opt.wake), standby=tokenizer.encode(opt.standby);
    const std::string keywords=router_keyword::token_line(wake,"WAKE",opt.wake_score,opt.wake_threshold)+router_keyword::token_line(standby,"STANDBY",opt.score,opt.threshold);
    if (opt.validate) { emit("{\"event\":\"validated\",\"protocol\":1,\"wake\":"+quote(opt.wake)+",\"standby\":"+quote(opt.standby)+",\"compiled_keywords\":"+quote(keywords)+"}"); return 0; }
    const std::string encoder=opt.model+"/encoder-epoch-12-avg-2-chunk-16-left-64.onnx";
    const std::string decoder=opt.model+"/decoder-epoch-12-avg-2-chunk-16-left-64.onnx";
    const std::string joiner=opt.model+"/joiner-epoch-12-avg-2-chunk-16-left-64.onnx";
    const std::string tokens=opt.model+"/tokens.txt";
    SherpaOnnxKeywordSpotterConfig config{};
    config.feat_config.sample_rate=16000; config.feat_config.feature_dim=80;
    config.model_config.transducer.encoder=encoder.c_str(); config.model_config.transducer.decoder=decoder.c_str(); config.model_config.transducer.joiner=joiner.c_str();
    config.model_config.tokens=tokens.c_str(); config.model_config.provider="cpu"; config.model_config.num_threads=1;
    config.max_active_paths=kMaxActivePaths; config.num_trailing_blanks=1; config.keywords_score=opt.score; config.keywords_threshold=opt.threshold;
    config.keywords_buf=keywords.c_str(); config.keywords_buf_size=static_cast<std::int32_t>(keywords.size());
    using Spotter=std::unique_ptr<const SherpaOnnxKeywordSpotter,decltype(&SherpaOnnxDestroyKeywordSpotter)>;
    Spotter kws(SherpaOnnxCreateKeywordSpotter(&config),SherpaOnnxDestroyKeywordSpotter);
    if (!kws) throw std::runtime_error("Keyword runtime/model initialization failed");
    using Stream=std::unique_ptr<const SherpaOnnxOnlineStream,decltype(&SherpaOnnxDestroyOnlineStream)>;
    Stream stream(SherpaOnnxCreateKeywordStream(kws.get()),SherpaOnnxDestroyOnlineStream);
    if (!stream) throw std::runtime_error("Compiled keyword stream creation failed");
    // Prime the streaming model's left context before ready. These internal
    // zeros are never counted as producer progress and cannot open the gate.
    const std::array<float,16000> initial_silence{};
    SherpaOnnxOnlineStreamAcceptWaveform(stream.get(),16000,initial_silence.data(),static_cast<int>(initial_silence.size()));
    unsigned warmup_steps=0;
    while (SherpaOnnxIsKeywordStreamReady(kws.get(),stream.get())) {
      if (++warmup_steps>1000) throw std::runtime_error("Decoder failed bounded startup progress");
      SherpaOnnxDecodeKeywordStream(kws.get(),stream.get());
    }
    const auto* primed=SherpaOnnxGetKeywordResult(kws.get(),stream.get());
    const bool unexpected=primed&&primed->keyword&&primed->keyword[0];
    SherpaOnnxDestroyKeywordResult(primed);
    if (unexpected) throw std::runtime_error("Keyword detector triggered during startup silence");
    const std::string profile=std::string("gigaspeech3.3m-")+kModelPrecision+"-paths"+std::to_string(kMaxActivePaths)+"-v1";
    emit("{\"event\":\"ready\",\"protocol\":1,\"sample_rate\":16000,\"wake\":"+quote(opt.wake)+",\"standby\":"+quote(opt.standby)+",\"runtime\":"+quote(SherpaOnnxGetVersionStr())+",\"onnxruntime\":"+quote(SherpaOnnxGetOnnxruntimeVersionStr())+",\"model_profile\":"+quote(profile)+",\"model_name\":"+quote(kModelName)+",\"precision\":"+quote(kModelPrecision)+",\"max_active_paths\":"+std::to_string(kMaxActivePaths)+"}");
    std::uint64_t total=0, sequence=0; std::array<unsigned char,6403> bytes{}; std::size_t remainder=0; std::array<float,1600> pcm{};
    auto decode=[&](const float* samples,int count) {
      SherpaOnnxOnlineStreamAcceptWaveform(stream.get(),16000,samples,count); total+=static_cast<std::uint64_t>(count);
      bool woke=false,closed=false; unsigned iterations=0;
      while (SherpaOnnxIsKeywordStreamReady(kws.get(),stream.get())) {
        if (++iterations>1000) throw std::runtime_error("Decoder failed bounded progress");
        SherpaOnnxDecodeKeywordStream(kws.get(),stream.get());
        const auto* result=SherpaOnnxGetKeywordResult(kws.get(),stream.get());
        if (result && result->keyword && result->keyword[0]) {
          const std::string detected=result->keyword;
          woke=woke||detected=="WAKE"; closed=closed||detected=="STANDBY";
          SherpaOnnxResetKeywordStream(kws.get(),stream.get());
        }
        SherpaOnnxDestroyKeywordResult(result);
      }
      // Merely buffering input does not prove model progress. Refresh health
      // only after at least one actual acoustic decode step completed.
      if (iterations) emit("{\"event\":\"progress\",\"frames\":"+std::to_string(total)+",\"sequence\":"+std::to_string(++sequence)+"}");
      if (closed||woke) emit("{\"event\":"+quote(closed?"standby":"wake")+",\"frames\":"+std::to_string(total)+",\"sequence\":"+std::to_string(++sequence)+",\"phrase\":"+quote(closed?opt.standby:opt.wake)+"}");
    };
    for (;;) {
      const ssize_t got=::read(STDIN_FILENO,bytes.data()+remainder,6400-remainder);
      if (got<0) { if (errno==EINTR) continue; throw std::runtime_error("PCM pipe read failed"); }
      if (got==0) { if (remainder) throw std::runtime_error("PCM stream ended mid-sample"); break; }
      const auto available=remainder+static_cast<std::size_t>(got); const auto count=available/4;
      for (std::size_t i=0;i<count;++i) {
        const auto* p=bytes.data()+4*i;
        const std::uint32_t bits=static_cast<std::uint32_t>(p[0])|(static_cast<std::uint32_t>(p[1])<<8)|(static_cast<std::uint32_t>(p[2])<<16)|(static_cast<std::uint32_t>(p[3])<<24);
        std::memcpy(&pcm[i],&bits,4);
        if (!std::isfinite(pcm[i])||pcm[i]<-1||pcm[i]>1) throw std::runtime_error("PCM samples must be finite and normalized to [-1,1]");
      }
      remainder=available%4; if (remainder) std::memmove(bytes.data(),bytes.data()+count*4,remainder);
      if (count) decode(pcm.data(),static_cast<int>(count));
    }
    // EOF means producer stopped. Do not invent progress or decode padding that
    // could emit a delayed wake after capture loss. Fixture callers append PCM
    // silence explicitly while the producer is still considered healthy.
    emit("{\"event\":\"eof\",\"frames\":"+std::to_string(total)+",\"sequence\":"+std::to_string(++sequence)+"}");
    return 0;
  } catch (const std::exception& exception) { error("keyword_worker_error",exception.what()); return 1; }
}
