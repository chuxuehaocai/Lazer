#include "../../windows/runner/desktop_lyrics_geometry.h"

#include <cassert>
#include <limits>
#include <iostream>

int main() {
  using namespace desktop_lyrics;
  const std::vector<InteractionRect> regions{{34, 18, 134, 66}};
  // Physical pixels at 100%, 150% and 200% address the same logical text.
  for (const auto dpi : {96u, 144u, 192u}) {
    const double scale = dpi / 96.0;
    assert(ContainsPhysicalPoint(regions, 34 * scale, 18 * scale, dpi));
    assert(!ContainsPhysicalPoint(regions, 134 * scale, 66 * scale, dpi));
    assert(!ContainsPhysicalPoint(regions, 20 * scale, 30 * scale, dpi));
  }
  assert(!ContainsPhysicalPoint(regions, 40, 30, 0));
  assert(!ValidInteractionRect({0, 0, std::numeric_limits<double>::infinity(), 20}));
  assert(!ValidInteractionRect({0, 0, 0, 20}));
  assert(ValidInteractionRect({0, 0, 20, 20}));
  assert(NeedsPointerTracking(true, false, 1));
  assert(!NeedsPointerTracking(true, true, 1));
  assert(!NeedsPointerTracking(false, false, 1));
  assert(!NeedsPointerTracking(true, false, 0));
  std::cout << "desktop lyric geometry and pointer lifecycle contracts passed\n";
}
