# HOW TO BUILD FROM SOURCES

## Requirements

- TI 99 Cross-Development Tools: https://github.com/endlos99/xdt99
- A bash shell to run the ```build.sh``` script.

## Select the build type (if needed)

Open the ```mandel99.asm``` file. At the beginning, you will find the following lines:

```asm
; Build type.
; 0 = Benchmark mode. This is the slower mode but can be used as a benchmark (elapsed number of frames is printed at completion in the upper right corner of the screen).
; 1 = Fast mode. This tricky mode stores also the core calculation routine in the faster scratch SRAM memory. I haven't found a way to support benchmarking in this mode.
BUILD_TYPE  EQU     0
```

## Edit the xdt99 path in the script

Open the ```build.sh``` script and edit the ```XDT99_PATH``` variable to match your installation path:

```bash
XDT99_PATH="../../xdt99"
```

## Build
Just run the script.  
This will create a ```mandel99.dsk``` disk image containing something like:
```console
MANDEL99  :     71 used  289 free   90 KB  1S/1D 40T  9 S/T
----------------------------------------------------------------------------
LOAD          2  PROGRAM        217 B             2025-10-22 18:58:18 C
MANDEL99     47  DIS/FIX 80   11760 B  138 recs   2025-10-22 18:58:18 C
MANDEL995    20  PROGRAM       4692 B             2025-10-22 18:58:18 C
```

## Run

You have different options:

- ```LOAD```: This is the BASIC program used for Extended Basic autoload. Note that standard TI Basic cannot autoload.
- ```MANDEL99```: This is the executable program.
- ```MANDEL995```: This is the binary to run using Editor/Assembler option 5. Notice the "5" at the end.

A quick way to test if you don't have a real machine:
- Install the Classic99 emulator: https://github.com/tursilion/classic99
- Run Classic99.
- Select menu "Disk" -> "Dsk 1" -> "Set DSK1". A "DSK1" window will open.
- In the "DSK1" window. Set "Disk Type" to "TI Controller (DSK)", and set "Path" to the ```mandel99.dsk``` disk image path.
- Drag an Extended Basic ROM image file into the Classic99 window. You'll be asked to reboot the machine.
- At the boot prompt, press any key, then select "2 FOR TI EXTENDED BASIC".
- The disk should autoboot and load the program (may take several seconds).
- When loading is complete, the program will finally run.

# LICENSE

Creative Commons, CC BY

https://creativecommons.org/licenses/by/4.0/deed.en

Please add a link to this github project.



