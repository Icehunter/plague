#ifndef PLAGUE_GLASS_PHOTON_SAMPLING
#define PLAGUE_GLASS_PHOTON_SAMPLING

// Halton (1960): reversing radix digits covers the unit interval without random clumps.
float plagueGlassRadicalInverse(uint index,uint radix) {
    float value=0.0,place=1.0/float(radix);
    // A uint has at most 32 digits in any radix used here.
    for(int digit=0;digit<32 && index!=0u;++digit) {
        value+=float(index%radix)*place;
        index/=radix;
        place/=float(radix);
    }
    return value;
}

vec4 plagueGlassEmissionSample(uint ordinal,uint emitter) {
    // The first four primes supply pairwise-coprime radices for face area and cosine direction.
    vec4 sequence=vec4(plagueGlassRadicalInverse(ordinal+1u,2u),
        plagueGlassRadicalInverse(ordinal+1u,3u),plagueGlassRadicalInverse(ordinal+1u,5u),
        plagueGlassRadicalInverse(ordinal+1u,7u));
    // Cranley-Patterson (1976): one fixed torus shift per world emitter retains a uniform PDF.
    // A separate shift per photon would destroy the point set's coverage.
    uint state=plagueGlassHash(emitter);
    vec4 rotation;
    rotation.x=plagueGlassRandom(state); rotation.y=plagueGlassRandom(state);
    rotation.z=plagueGlassRandom(state); rotation.w=plagueGlassRandom(state);
    return fract(sequence+rotation);
}
#endif
