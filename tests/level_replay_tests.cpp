// Golden replay test: the shared MSNR_BuildLevels pipeline must reproduce the
// exact level set the validated indicator rendered on HFM XAUUSDc.
//
// Inputs are the audit exports taken at the same moment:
//   tests/golden/hfm_bars_20261021.csv    (1500 rates per TF, closed flag)
//   tests/golden/hfm_objects_20261021.csv (rendered chart objects + labels)
#include <cmath>
#include <cstdio>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "../MQL5/Include/Alphatom/MSNRLevels.mqh"

static int failures = 0;

#define CHECK(condition)                                                        \
  do {                                                                          \
    if (!(condition)) {                                                         \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__,     \
                   #condition);                                                 \
      ++failures;                                                               \
    }                                                                           \
  } while (false)

static std::vector<std::string> split(const std::string &line, char sep) {
  std::vector<std::string> fields;
  std::string current;
  std::istringstream stream(line);
  while (std::getline(stream, current, sep)) fields.push_back(current);
  return fields;
}

static long long parse_epoch(const std::string &text) {
  int year = 0, month = 0, day = 0, hour = 0, minute = 0;
  if (std::sscanf(text.c_str(), "%d.%d.%d %d:%d", &year, &month, &day, &hour,
                  &minute) != 5)
    return 0;
  year -= month <= 2;
  const int era = (year >= 0 ? year : year - 399) / 400;
  const unsigned yoe = static_cast<unsigned>(year - era * 400);
  const unsigned doy =
      static_cast<unsigned>((153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 +
                            day - 1);
  const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  const long long days =
      static_cast<long long>(era) * 146097 + static_cast<long long>(doe) -
      719468;
  return days * 86400 + hour * 3600 + minute * 60;
}

static std::string state_tag(MSNRState state) {
  if (state == MSNR_STATE_FRESH) return "Fresh";
  if (state == MSNR_STATE_UNFRESH) return "Unfresh";
  if (state == MSNR_STATE_FLIPPED_FRESH) return "Flipped fresh";
  if (state == MSNR_STATE_FLIPPED_UNFRESH) return "Flipped unfresh";
  return "Broken";
}

struct GoldenLevel {
  double price = 0.0;   // swing price or gap upper
  double price2 = 0.0;  // gap lower
  std::string label;
  bool isGap = false;
};

static void test_hfm_golden_replay() {
  std::ifstream barsFile("tests/golden/hfm_bars_20261021.csv");
  CHECK(barsFile.good());
  if (!barsFile.good()) return;

  std::map<std::string, std::vector<MSNRBar>> barsByTf;
  std::string line;
  std::getline(barsFile, line);  // header
  while (std::getline(barsFile, line)) {
    if (line.empty()) continue;
    const std::vector<std::string> fields = split(line, ';');
    if (fields.size() < 9) continue;
    if (fields[4] != "1") continue;  // forming bar is not part of the map
    MSNRBar bar{};
    bar.open = std::atof(fields[5].c_str());
    bar.high = std::atof(fields[6].c_str());
    bar.low = std::atof(fields[7].c_str());
    bar.close = std::atof(fields[8].c_str());
    bar.time = parse_epoch(fields[2]);
    barsByTf[fields[1]].push_back(bar);
  }

  std::ifstream objectsFile("tests/golden/hfm_objects_20261021.csv");
  CHECK(objectsFile.good());
  if (!objectsFile.good()) return;

  std::map<std::string, GoldenLevel> expected;  // "TF|KIND_EPOCH"
  std::map<std::string, std::string> labels;    // same key -> label text
  std::getline(objectsFile, line);              // header
  while (std::getline(objectsFile, line)) {
    if (line.empty()) continue;
    const std::vector<std::string> fields = split(line, ';');
    if (fields.size() < 8) continue;
    std::vector<std::string> name = split(fields[1], '_');
    if (name.size() < 5) continue;
    const std::string tf = name[2];
    std::string kind = name[3];
    std::string epoch = name[4];
    if (kind == "TXT") {
      if (name.size() < 6) continue;
      const std::string realKind = name[4];
      labels[tf + "|" + realKind + "_" + name[5]] = fields[3];
      continue;
    }
    if (fields[2] != "1" && fields[2] != "20") continue;  // text/arrows
    GoldenLevel level;
    level.isGap = kind == "GAP";
    level.price = std::atof(fields[4].c_str());
    level.price2 = std::atof(fields[5].c_str());
    expected[tf + "|" + kind + "_" + epoch] = level;
  }

  for (const char *tf : {"M15", "M30", "H1"}) {
    const auto found = barsByTf.find(tf);
    CHECK(found != barsByTf.end());
    if (found == barsByTf.end()) continue;

    MSNRParams params;
    MSNR_InitParams(params);
    params.point = 0.01;
    params.tickSize = 0.01;

    std::vector<MSNRLevel> levels;
    int count = 0;
    CHECK(MSNR_BuildLevels(found->second, static_cast<int>(found->second.size()),
                           params, levels, count));
    CHECK(count == 8);  // newest-eight cap

    int matched = 0;
    for (int i = 0; i < count; ++i) {
      const MSNRLevel &level = levels[static_cast<size_t>(i)];
      const std::string kind =
          level.isGap ? "GAP" : (level.isSwingHigh ? "SH" : "SL");
      const std::string key =
          std::string(tf) + "|" + kind + "_" + std::to_string(level.created);
      const auto expectedLevel = expected.find(key);
      CHECK(expectedLevel != expected.end());
      if (expectedLevel == expected.end()) {
        std::fprintf(stderr, "unexpected %s\n", key.c_str());
        continue;
      }
      ++matched;
      if (level.isGap) {
        CHECK(std::fabs(level.upper - expectedLevel->second.price) < 1e-9);
        CHECK(std::fabs(level.lower - expectedLevel->second.price2) < 1e-9);
      } else {
        CHECK(std::fabs(level.price - expectedLevel->second.price) < 1e-9);
      }
      const auto label = labels.find(key);
      CHECK(label != labels.end());
      if (label == labels.end()) continue;
      const std::string roleTag =
          level.role == MSNR_ROLE_SUPPORT ? "S" : "R";
      const std::string computed =
          std::string(tf) + " " + roleTag + " " + state_tag(level.state);
      CHECK(computed == label->second);
      if (computed != label->second)
        std::fprintf(stderr, "%s: computed '%s' golden '%s'\n", key.c_str(),
                     computed.c_str(), label->second.c_str());
    }
    CHECK(matched == count);
    CHECK(matched == 8);
  }
}

int main() {
  test_hfm_golden_replay();
  if (failures > 0) {
    std::fprintf(stderr, "%d level replay check(s) failed\n", failures);
    return 1;
  }
  std::printf("1 level replay group passed\n");
  return 0;
}
