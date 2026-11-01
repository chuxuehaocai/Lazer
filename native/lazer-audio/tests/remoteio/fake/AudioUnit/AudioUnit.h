/* Fake AudioUnit umbrella header for the RemoteIO contract test.
 *
 * The production backend includes both `<AudioToolbox/AudioToolbox.h>` (where
 * iOS keeps the AudioUnit API) and `<AudioUnit/AudioUnit.h>`, so the fake tree
 * carries both names and they point at the same declarations.
 */
#ifndef LAZER_FAKE_AUDIOUNIT_UMBRELLA_H
#define LAZER_FAKE_AUDIOUNIT_UMBRELLA_H

#include <AudioToolbox/AudioToolbox.h>

#endif  // LAZER_FAKE_AUDIOUNIT_UMBRELLA_H
