#ifndef PLAGUE_GLASS_BEAM
#define PLAGUE_GLASS_BEAM
// Companion visibility-record ABI. Keep the allocated stride and descriptor positions stable;
// words 5..9 hold validity, last interface plane, shape bounds and source-boundary flag.
const uint PLAGUE_GLASS_BEAM_WORDS=13u;
#endif
