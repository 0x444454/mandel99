# mandel99 and mandelF18A
## A fast hi-res Mandelbrot generator/benchmark for the TI-99/4A

**mandel99**  

![screenshots](media/screenshot-20251022.png)
![screenshots](media/screenshot-20251022-2.png)

**mandelF18A**  

![screenshots](media/screenshot-20260825.png)


# REQUIREMENTS

- __RAM expansion__ (at least 8 KB). I test with 32 KB.

Note: The stock TI-99/4A comes with only 256 Bytes of RAM (SRAM) that can be directly used by the CPU.  
That's Bytes, not KBytes. It also has 16 KB of Video-RAM, but these cannot be accessed directly by the CPU.
This program is quite small, but needs a little more RAM for temporary buffers used to optimize calculations and rendering.   

# OPTIONAL
- __F18A GPU__
  - If __F18A__ is detected, the CPU builds (**mandel99**) will use the GPU to partially accelerate pixel calculations and a more pleasant custom color palette is used.
  - An exclusive __F18A__ build is available (**mandelF18A**), fully accelerating all calculations, and rendering 128x192 in fat-pixel mode with 16 independent colors (no clashes).

# BUILD TYPES

There are 3 build types:
- "**mandel99 Benchmark**": This is slightly slower but can be used as a speed benchmark program for your TI-99/4A. When the calculation is completed, the number of elapsed frames is printed in the upper-right corner of the screen (hexadecimal number). The lower the number, the faster the machine.
- "**mandel99 Fast**": This is about 16% faster. The trick is relocating the core calculation loop in SRAM. Unfortunately, I have not yet found a way to count elapsed frames in this mode without the Console ROM messing with SRAM and destroying my code. So the elapsed frames number will always be 0000.
- "**mandelF18A**"" This requires a F18A and runs completely in the GPU for super-fast rendering. It renders at half-horizontal resolution (fat pixels), so benchmark numbers are not comparable to the CPU version (***mandel99**).

# CONTROLS

The app is simply controlled using the keyboard.
- Arrows (ESDX): Move around in complex plane.
- Shift + Up (E): Zoom in.
- Shift + Down (X): Zoom out.
- Shift + Left (S): Increase iterations.
- Shift + Right (D): Decrese iterations.

# SUPPORTED RESOLUTIONS
- First pass: 32x24, 16 colors.
- Second pass:  
  - **mandel99**: 256x192, 16 colors (Graphics II). Some color clashes are inevitable.
  - **mandelF18A** 128x192, 16 independent colors (fat-pixel mode). No color clashes.


# ALGORITHM

### Mandelbrot calculation
This is a fast fixed-point implementation of the Mandelbrot algorithm (see Wikipedia about the Mandelbrot set).  
The TMS9900 processor has integer 16x16-bits multiplication, but lacks support for any floating point math.
This algorithm makes the calculation much faster by using Q4.12 fixed-point math, albeit at the cost of a limited magnification (zoom-in) range. 
The slow part of the calculation consists of two squares and one multiplication per iteration.  
A Q4.12 number uses 6 bits for the signed integer part (3+sign), and 12 bits for the fractional part.  

Note that the code can be optimized further, and will be in future releases.  
Currently, a stock TI-99/4A is be able to render the full set preview (first-pass) in less than 2 seconds, and the full hi-res image in 83 seconds.

### Note about fixed-point precision

There are two different fixed-point notations using "Q" numbers. TI and ARM. I am using ARM notation. More info here:  
https://en.wikipedia.org/wiki/Q_(number_format)  

The current implementation uses Q4.12, so numbers in the range [-8, +8) can be represented.  
The Mandelbrot set is contained in a circle with radius 2. However, during calculation, numbers greater than 2 are encountered, depending on the point being calculated.  
Here is the maximum magnitude reached for each point during the calculation:  

![screenshots](media/max_values.jpg)


### Rendering

The rendering is done in two passes:
- First pass is low-res: 32x24.
- Second pass is high-res: 256x192 (**mandel99**), or 128x192 (**mandelF18A**).

The first pass is low-resolution and serves two purposes:
- Quick preview of rendered image.
- Buffer iterations for second pass optimization.

The second pass is high resolution (well, for an 8-bit machine ;-).
Each low-resolution "big" pixel calculated in the first pass is either left untouched (if all adjacent pixels have the same color) or re-calculated as a 8x8 hi-res tile.
This is particularly useful to skip calculation of parts of the Mandelbrot set (i.e. the black area).

### Hi-res (Graphics II) color clash optimization

Alas, the VDP (Video Display Processor) cannot render independent per-pixel colors in high-res.  
Each block of 8x1 pixels can only have two colors: Foreground and Background.  
This is not as bad as on other computers (e.g. the ZX Spectrum has this limitation for 8x8 pixel blocks), but we still need to optimize the rendering.  

The color clash optimization is as follows:
- Color 0 (transparent) is never used.
- Color 1 (black) is only used for the Mandelbrot set.
- The other 14 colors are re-ordered as a gradient minimizing perceptual difference between adjacent colors. This means adjacent iterations produce similar color shades.
- For each 8x1 block, we calculate the color histogram and find the 2 most used colors to assign to Foreground and Background.
- For each pixel in the 8x1 block, we use the most similar color, either Foreground or Background; i.e. the one with minimum perceptual distance from the actual calculated pixel color.

Q: Doesn't this extra step slow down calculation ?  
A: Yes. However, the result would not be acceptable without it, due to much more visible color errors in busy areas.  

### F18A Fat-Pixels mode

This is a custom 128x256 resolution, allocating 4 bits per pixel so there are no color clashes.  
On the downside, the horizontal resolution is halved (but calculation is faster ;-).


# For other platforms

## CVBasic
Ported by visrealm:  
https://github.com/visrealm/mandelcvb

## 6502 Machines
Mandelbr8:  
https://github.com/0x444454/mandelbr8


# LICENSE

Creative Commons, CC BY

https://creativecommons.org/licenses/by/4.0/deed.en

Please add a link to this github project.
