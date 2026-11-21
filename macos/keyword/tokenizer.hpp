#pragma once
// Original bounded English SentencePiece tokenizer for the pinned GigaSpeech model.
// Reads SentencePiece ModelProto's published wire format; no SentencePiece code.
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iterator>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace router_keyword {
struct WireField { std::uint32_t number{}, wire{}; std::uint64_t scalar{}; std::string bytes; };
inline std::uint64_t varint(const std::string& s, std::size_t& i) {
  std::uint64_t result = 0;
  for (unsigned shift = 0; shift < 64; shift += 7) {
    if (i >= s.size()) throw std::runtime_error("Truncated tokenizer model");
    const auto b = static_cast<unsigned char>(s[i++]);
    if (shift == 63 && b > 1) throw std::runtime_error("Oversized tokenizer integer");
    result |= static_cast<std::uint64_t>(b & 127) << shift;
    if (!(b & 128)) return result;
  }
  throw std::runtime_error("Invalid tokenizer integer");
}
inline std::vector<WireField> fields(const std::string& s) {
  std::vector<WireField> out;
  std::size_t i = 0;
  while (i < s.size()) {
    const auto tag = varint(s, i);
    WireField f; f.number = static_cast<std::uint32_t>(tag >> 3); f.wire = tag & 7;
    if (!f.number) throw std::runtime_error("Invalid tokenizer field");
    if (f.wire == 0) f.scalar = varint(s, i);
    else {
      const auto n = f.wire == 2 ? varint(s, i) : f.wire == 5 ? 4 : f.wire == 1 ? 8 : 0;
      if (!n && f.wire != 2) throw std::runtime_error("Unsupported tokenizer wire type");
      if (n > s.size() - i) throw std::runtime_error("Truncated tokenizer field");
      f.bytes = s.substr(i, static_cast<std::size_t>(n)); i += n;
    }
    out.push_back(std::move(f));
  }
  return out;
}
inline std::string read_file(const std::string& path, std::size_t maximum) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw std::runtime_error("Missing model file: " + path);
  in.seekg(0, std::ios::end); const auto length = in.tellg();
  if (length < 0 || static_cast<std::uint64_t>(length) > maximum) throw std::runtime_error("Model metadata too large");
  in.seekg(0); return std::string(std::istreambuf_iterator<char>(in), {});
}
inline std::string normalize_phrase(const std::string& input) {
  if (input.empty() || input.size() > 64) throw std::runtime_error("Phrase must contain 1-64 English ASCII characters");
  std::string out; bool space = false;
  for (const unsigned char c : input) {
    if (c == ' ') { space = !out.empty(); continue; }
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '\''))
      throw std::runtime_error("Unsupported phrase: use English letters, spaces and apostrophes");
    if (space) { out += ' '; space = false; }
    out += static_cast<char>(std::toupper(c));
  }
  if (out.empty() || out.front() == '\'' || out.back() == '\'') throw std::runtime_error("Phrase must contain English words");
  return out;
}
class Tokenizer {
  std::unordered_map<std::string, float> scores_;
  std::unordered_set<std::string> tokens_;
  int model_type_ = 1;
 public:
  explicit Tokenizer(const std::string& directory) {
    int model_type = 1;
    for (const auto& f : fields(read_file(directory + "/bpe.model", 4 * 1024 * 1024))) {
      if (f.number == 2 && f.wire == 2) {
        for (const auto& t : fields(f.bytes)) if (t.number == 3 && t.wire == 0) model_type = static_cast<int>(t.scalar);
      }
      if (f.number != 1 || f.wire != 2) continue;
      std::string piece; float score = 0; int type = 1;
      for (const auto& p : fields(f.bytes)) {
        if (p.number == 1 && p.wire == 2) piece = p.bytes;
        else if (p.number == 2 && p.wire == 5) std::memcpy(&score, p.bytes.data(), 4);
        else if (p.number == 3 && p.wire == 0) type = static_cast<int>(p.scalar);
      }
      if (type == 1 && !piece.empty() && std::isfinite(score)) scores_.emplace(piece, score);
    }
    model_type_ = model_type;
    if ((model_type != 1 && model_type != 2) || scores_.empty()) throw std::runtime_error("Unsupported SentencePiece model type");
    std::istringstream vocabulary(read_file(directory + "/tokens.txt", 1024 * 1024));
    std::string token; int id;
    while (vocabulary >> token >> id) if (id >= 0) tokens_.insert(token);
  }
  std::vector<std::string> encode(const std::string& phrase) const {
    const auto normalized = normalize_phrase(phrase);
    if (model_type_ == 1) {
      // The pinned file is a SentencePiece UNIGRAM model even though the
      // distribution calls its units BPE. Use maximum-score segmentation.
      std::string text="▁";
      for (char c:normalized) text += c==' '?"▁":std::string(1,c);
      const auto n=text.size();
      std::vector<double> best(n+1,-std::numeric_limits<double>::infinity());
      std::vector<std::size_t> previous(n+1,n+1); best[0]=0;
      for (std::size_t i=0;i<n;++i) {
        if (!std::isfinite(best[i])) continue;
        for (const auto& item:scores_) {
          const auto length=item.first.size();
          if (length>n-i||text.compare(i,length,item.first)!=0||!tokens_.count(item.first)) continue;
          const double candidate=best[i]+item.second;
          if (candidate>best[i+length]) { best[i+length]=candidate; previous[i+length]=i; }
        }
      }
      if (!std::isfinite(best[n])) throw std::runtime_error("Phrase contains unsupported model tokens");
      std::vector<std::string> out;
      for (std::size_t at=n;at;) { const auto begin=previous[at]; if (begin>=at) throw std::runtime_error("Invalid tokenizer path"); out.push_back(text.substr(begin,at-begin)); at=begin; }
      std::reverse(out.begin(),out.end()); return out;
    }
    std::vector<std::string> pieces{"▁"};
    for (const char c : normalized) pieces.push_back(c == ' ' ? "▁" : std::string(1, c));
    // SentencePiece BPE repeatedly merges the available highest-score adjacent
    // pair. Leftmost wins score ties. English ASCII avoids Unicode normalizer
    // ambiguity; unsupported characters are rejected before tokenization.
    for (;;) {
      std::size_t best = pieces.size(); float best_score = -std::numeric_limits<float>::infinity();
      for (std::size_t i = 0; i + 1 < pieces.size(); ++i) {
        const auto merged = pieces[i] + pieces[i + 1]; const auto score = scores_.find(merged);
        if (score != scores_.end() && score->second > best_score) { best = i; best_score = score->second; }
      }
      if (best == pieces.size()) break;
      pieces[best] += pieces[best + 1]; pieces.erase(pieces.begin() + static_cast<std::ptrdiff_t>(best + 1));
    }
    for (const auto& piece : pieces) if (!tokens_.count(piece) || piece == "<unk>") throw std::runtime_error("Phrase contains unsupported model tokens");
    return pieces;
  }
};
inline std::string token_line(const std::vector<std::string>& tokens, const std::string& label, float score=1.5f, float threshold=.25f) {
  std::string result; for (const auto& token : tokens) { if (!result.empty()) result += ' '; result += token; }
  std::ostringstream settings; settings << " :" << score << " #" << threshold << " @" << label << '\n';
  return result + settings.str();
}
}  // namespace router_keyword
