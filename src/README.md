# REQUIREMENTS

- TI 99 Cross-Development Tools: https://github.com/endlos99/xdt99
- A bash shell to run the ```asm.sh``` script.

# SELECT THE BUILD TYPE (if needed)

Open the ```mandel99.asm``` file. At the beginning, you will find the following lines:

```asm
; Build type.
; 0 = Benchmark mode. This is the slower mode but can be used as a benchmark (elapsed number of frames is printed at completion in the upper right corner of the screen).
; 1 = Fast mode. This tricky mode stores also the core calculation routine in the faster scratch SRAM memory. I haven't found a way to support benchmarking in this mode.
BUILD_TYPE  EQU     0
```

# EDIT xdt99 PATH

Open the ```asm.sh``` script and edit the ```XDT99_PATH``` variable to match your installation path.

```bash
XDT99_PATH="../../xdt99"
```



# BUILD THE BINARY




# LICENSE

Creative Commons, CC BY

https://creativecommons.org/licenses/by/4.0/deed.en

Please add a link to this github project.



