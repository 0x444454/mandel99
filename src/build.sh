#!/bin/bash
echo "Building MANDEL99"
XDT99_PATH="../../xdt99"

# Assemble to obj.
"${XDT99_PATH}"/xas99.py -R mandel99.asm -L mandel99.lst -n mandel99

if [ $? -eq 0 ]; then
    # Hexdump (debug)
    hexdump -C mandel99.obj
    
    # Create img.
    "${XDT99_PATH}"/xas99.py -R -i mandel99.asm -o mandel995.img
    if [ $? -eq 0 ]; then
        echo "Created IMG."
    else
        echo "ERROR creating IMG."
    fi

    # Create disk.
    "${XDT99_PATH}"/xdm99.py -X sssd mandel99.dsk -a mandel99.obj -f df80 # -n LOAD
    if [ $? -eq 0 ]; then
        echo "Created DSK with OBJ."
    else
        echo "ERROR creating DSK."
    fi

    # Add img file to disk.
    "${XDT99_PATH}"/xdm99.py mandel99.dsk -a mandel995.img # -n LOAD
    if [ $? -eq 0 ]; then
        echo "Added IMG to DSK."
    else
        echo "ERROR adding IMG to DSK."
    fi
    
    # Create BASIC "LOAD" autoloader.
    printf '%s\n' \
'10 CALL INIT' \
'20 PRINT "LOADING DDT'\''s MANDEL99":"please wait...":"":"COMMANDS":" Pan  : Arrows":" Zoom : Shift+Up/Down":" Iters: Shift+Left/Right"' \
'30 CALL LOAD("DSK1.MANDEL99")' \
'40 CALL LINK("ENTRY")  ::  REM ENTRY label' \
> load.bas

    "${XDT99_PATH}"/xbas99.py -c load.bas
    if [ $? -eq 0 ]; then
        echo "BASIC loader created."
        "${XDT99_PATH}"/xdm99.py mandel99.dsk -a load.prg -n LOAD
        if [ $? -eq 0 ]; then
            echo "Added loader to DSK."
            # List disk content.
           "${XDT99_PATH}"/xdm99.py mandel99.dsk
        else
            echo "ERROR adding loader to DSK."
        fi
    else
        echo "ERROR creating BASIC loader."
    fi    


fi
