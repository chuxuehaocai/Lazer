#ifndef RUNNER_DESKTOP_LYRICS_GEOMETRY_H_
#define RUNNER_DESKTOP_LYRICS_GEOMETRY_H_

#include <cmath>
#include <cstddef>
#include <vector>

namespace desktop_lyrics {

constexpr std::size_t kMaxInteractionRegions = 16;

struct InteractionRect {
  double left;
  double top;
  double right;
  double bottom;
};

inline bool ValidInteractionRect(const InteractionRect& rect) {
  return std::isfinite(rect.left) && std::isfinite(rect.top) &&
         std::isfinite(rect.right) && std::isfinite(rect.bottom) &&
         rect.right > rect.left && rect.bottom > rect.top;
}

inline bool ContainsPhysicalPoint(const std::vector<InteractionRect>& regions,
                                  double x, double y, unsigned int dpi) {
  if (dpi == 0 || !std::isfinite(x) || !std::isfinite(y)) return false;
  const double scale = dpi / 96.0;
  x /= scale;
  y /= scale;
  for (const auto& rect : regions) {
    if (x >= rect.left && x < rect.right &&
        y >= rect.top && y < rect.bottom) return true;
  }
  return false;
}

inline bool NeedsPointerTracking(bool visible, bool locked,
                                 std::size_t region_count) {
  return visible && !locked && region_count != 0;
}

}  // namespace desktop_lyrics

#endif  // RUNNER_DESKTOP_LYRICS_GEOMETRY_H_
