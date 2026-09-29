#ifndef PLAGUE_RT_SAMPLING
#define PLAGUE_RT_SAMPLING

// Work budgets derived from the existing 512-square, one-ray grid. Each axis and sample
// count is independent; graph.toml sizes every request, answer and history from these values.
#define PLAGUE_GI_GRID 512 //[256 512 768 1024] compile "GI Grid Side"
#define PLAGUE_GI_SAMPLES 1 //[1 2 4] compile "GI Samples per Cell"
// Two interfaces per isolated slab. The default covers two slabs; larger budgets trade
// additional native queries for more boundaries, without converting unfinished paths to sky.
#define PLAGUE_GI_GLASS_INTERFACES 4 //[2 4 8 16] compile "GI Glass Interfaces"
#define PLAGUE_LOCAL_GRID 512 //[256 512 768 1024] compile "Block Light Grid Side"
#define PLAGUE_LOCAL_SAMPLES 1 //[1 2 4] compile "Block Light Samples per Cell"

// Interleaved samples keep the one-sample layout and random sequence unchanged.
uint plagueRayIndex(uint cell, uint sampleIndex, uint samples) { return cell * samples + sampleIndex; }
uint plagueRayCell(uint index, uint samples) { return index / samples; }
uint plagueRaySample(uint index, uint samples) { return index % samples; }

struct PlagueRayBatch {
    vec3 radiance;
    vec3 weightedBearing;
    float weight;
    bool complete;
};

PlagueRayBatch plagueRayBatch() {
    return PlagueRayBatch(vec3(0.0), vec3(0.0), 0.0, true);
}

void plagueRayBatchAdd(inout PlagueRayBatch batch, vec3 radiance, vec3 bearing, bool answered) {
    batch.complete = batch.complete && answered;
    // Rec.709 luminance matches the existing directional GI weight. An unavailable sample
    // invalidates the frame estimate; it must never be normalized into an apparent sky miss.
    float weight = dot(radiance, vec3(0.2126, 0.7152, 0.0722));
    batch.radiance += radiance;
    batch.weightedBearing += bearing * weight;
    batch.weight += weight;
}

vec3 plagueRayBatchMean(PlagueRayBatch batch, uint samples) {
    // Monte Carlo mean: increasing sample count reduces variance, never multiplies energy.
    return batch.radiance / float(samples);
}

vec3 plagueRayBatchBearing(PlagueRayBatch batch) {
    return batch.weight > 0.0 ? batch.weightedBearing / batch.weight : vec3(0.0);
}

#endif
