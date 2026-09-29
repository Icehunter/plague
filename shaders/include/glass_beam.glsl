#ifndef PLAGUE_GLASS_BEAM
#define PLAGUE_GLASS_BEAM
// Companion visibility-record ABI. Keep the allocated stride and descriptor positions stable;
// words 5..9 hold validity, last interface plane, shape bounds and source-boundary flag;
// word 10's xyz is the bin pass's receiver index box (paired with word 9's xyz as lo/hi).
const uint PLAGUE_GLASS_BEAM_WORDS=13u;
#endif
