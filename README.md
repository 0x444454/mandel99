# mandel99
A fast hi-res Mandelbrot generator for the TI-99/4A

![screenshots](media/screenshot-20251022.png)

# REQUIREMENTS

- RAM expansion.

# BUILD TYPES

There are two build types:
- "Benchmark": This is slightly slower but can be used as a speed benchmark program for your TI-99/4A. When the calculation is completed, the number of elapsed frames is printed in the upper-right corner of the screen (hexadecimal number). The lower the number, the better.
- "Fast": This is about 16% faster. The trick is relocating the core calculation loop in SRAM. Unfortunately, I have not yet found a way to count elapsed frames in this mode without the Console ROM messing with SRAM and destroying my code. So the elapsed frames number will always be 0000.


# CONTROLS

The app is simply controlled using the keyboard.
- Arrows (ESDX): Move around in complex plane.
- Shift + Up (E): Zoom in.
- Shift + Down (X): Zoom out.
- Shift + Left (S): Increase iterations.
- Shift + Right (D): Decrese iterations.

# SUPPORTED RESOLUTIONS
- First pass: 32x24, 16 colors.
- Second pass: 256x192, 16 colors (Graphics II).

# ALGORITHM

### Mandelbrot calculation
This is a fast fixed-point implementation of the Mandelbrot algorithm (see Wikipedia about the Mandelbrot set).  
The TMS9900 processor has integer 16x16-bits multiplication, but lacks support for any floating point math.
This algorithm makes the calculation much faster by using Q6.10 fixed-point math, albeit at the cost of a limited magnification (zoom-in) range. 
The slow part of the calculation consists of two squares and one multiplication per iteration.  
A Q6.10 number uses 6 bits for the signed integer part (5+sign), and 10 bits for the fractional part.  

Note that the code can be optimized further, and will be in future releases.  
Currently, a stock TI-99/4A is be able to render the full set preview (first-pass) in less than 2 seconds, and the full hi-res image in 83 seconds.

### Note about fixed-point precision

There are two different fixed-point notations using "Q" numbers. TI and ARM. I am using ARM notation. More info here:  
https://en.wikipedia.org/wiki/Q_(number_format)  

The current implementation uses Q6.10, so numbers in the range [-32, +32) can be represented.  
The Mandelbrot set is contained in a circle with radius 2. However, during calculation, numbers greater than 2 are encountered, depending on the point being calculated.  
Here is the maximum magnitude reached for each point during the calculation:  

![screenshots](media/max_values.jpg)

While Q5.11 is arguably the best compromise between max-zoom and overflow errors during calculation, however in this version we use Q6.10 to keep the calculation routine size small enough to fit in fast SRAM. A future optimization allowing Q5.11 (hence 2x deeper zoom) is most probably possible.

### Rendering

The rendering is done in two passes:
- First pass is low-res (32x24). This serves both as a preview and and to optimize the second pass.
- Second pass is high-res (256x192).

The first pass is low-resolution and serves two purposes:
- Quick preview of rendered image.
- Buffer iterations for second pass optimization ("smart" skip).

The second pass is high resolution (well, for an 8-bit machine ;-).
Each low-resolution "big" pixel in the first pass is either skipped (if nearby pixels have the same color) or re-calculated as a 8x8 hi-res tile.

### Hi-res (Graphics II) color clash optimization

Alas, the VDP (Video Display Processor) cannot render independent per-pixel colors in high-res.
Each block of 8x1 pixels can only have two colors: Foreground and Background.
This is not as bad as on other computers (e.g. the ZX Spectrum has that limitation for 8x8 pixels), but we still need to optimize the rendering.
The color clash optimization is as follows:
- Colors are re-ordered as a gradient minimizing perceptual difference between adjacent colors. This means adjacent iterations produce similar color shades.
- For each 8x1 block, we calculate the color histogram and find the 2 most used colors to assign to Foreground and Background.
- For each pixel in the 8x1 block, we pick Foreground or Background based on perceptual distance (color similarity).
This produces a good result even if the clash is still visible in busy areas.

# LICENSE

Creative Commons, CC BY

https://creativecommons.org/licenses/by/4.0/deed.en

Please add a link to this github project.
