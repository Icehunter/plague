# Third-party notices

Plague is MIT-licensed (see `LICENSE`). It also contains a small amount of code written by
other people under permissive licences. Those licences require their notices to travel with
the code, so they are reproduced here in full.

Nothing may be added to this file without the licence text that goes with it. If a piece of
third-party material cannot be listed here with a real, permissive licence, it does not belong
in this repository; see `ASSETS.md` for the same rule applied to binary assets.

---

## "Hash without Sine": `hash12`

Defined in `shaders/post/ssr_trace_water.fsh` and `shaders/post/ssao.fsh` (as `hash12`) and in
`shaders/include/sky_hash.glsl` (as `plagueHash12`, shared by the sky includes), used to turn
sample-pattern banding into dither.

Source: <https://www.shadertoy.com/view/4djSRW>

```
Copyright (c) 2014 David Hoskins

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
