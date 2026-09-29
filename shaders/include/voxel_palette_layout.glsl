#ifndef PLAGUE_VOXEL_PALETTE_LAYOUT
#define PLAGUE_VOXEL_PALETTE_LAYOUT
// The engine stores an unsigned byte per cell. One-based capture IDs reserve 254/255
// for failure; buffer length carries the active capacity without a duplicated option.
int plagueVoxelCapacity(int words, int diameter, int entryWords) {
    if (diameter < 1 || diameter > 33 || words <= 0) return 0;
    int divisor = diameter*diameter*diameter*entryWords;
    int capacity = words/divisor;
    return words%divisor == 0 && capacity > 0 && capacity <= 253 ? capacity : 0;
}
int plagueVoxelPaletteCapacity(int words, int diameter) { return plagueVoxelCapacity(words, diameter, 16); }
int plagueVoxelFaceCapacity(int words, int diameter) { return plagueVoxelCapacity(words, diameter, 42); }
bool plagueVoxelMaterialBuffersValid(int paletteWords, int faceWords, int diameter) {
    int capacity = plagueVoxelPaletteCapacity(paletteWords, diameter);
    return capacity > 0 && plagueVoxelFaceCapacity(faceWords, diameter) == capacity;
}
#endif
