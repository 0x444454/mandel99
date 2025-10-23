; Mandel99 (TMS9900 port of Mandelbr8).
; DDT's fixed-point Mandelbrot generator. Requires RAM expansion.
;
; https://github.com/0x444454/mandel99
;
; For other platforms, see also:
;    https://github.com/0x444454/mandelbr8
;
; Use xas99 Assembler.
;
; Revision history [authors in square brackets]:
;   2025-10-17: Studied TI-99/4A hardware. [DDT]
;   2025-10-18: Setup asm environment and first tests. [DDT]
;   2025-10-21: Port completed. [DDT]
;   2025-10-22: Experimental fast mode (no benchmark) and comments. [DDT]


; Build type.
; 0 = Benchmark mode. This is the slower mode but can be used as a benchmark (elapsed number of frames is printed at completion in the upper right corner of the screen).
; 1 = Fast mode. This tricky mode stores also the core calculation routine in the faster scratch SRAM memory. I haven't found a way to support benchmarking in this mode.
BUILD_TYPE  EQU     0

       IDT 'MANDEL99'
       
       DEF  ENTRY          ; <-- export ENTRY so LINK can see it

       ;REF VSBW,VMBW,VWTR
       ;REF KSCAN

ENTRY  JMP  START


    .ifeq BUILD_TYPE,0
IRQMASK EQU     2       ; IRQ mask for non critical section (i.e. LIMI value).
    .else
IRQMASK EQU     0       ; IRQ mask for non critical section (i.e. LIMI value).
    .endif

; SRAM        
WRKSP   EQU     >8300
;KMODE   EQU     >8374
;KCODE   EQU     >8375
;GPLST   EQU     >837C

; VDP interface
VDPRD   EQU     >8800   ; VDP data read
VDPST   EQU     >8802   ; VDP status read
VDPWD   EQU     >8C00   ; VDP data write
VDPWA   EQU     >8C02   ; VDP write addr / reg select

; GROM interface
GRMRD   EQU     >9800   ; GROM data read (byte, auto-increment)
GRMWA   EQU     >9C02   ; GROM address write (byte, hi then lo)


message:
        TEXT "DDT'S FIXED-POINT MANDELBROT",>0D
        TEXT "VERSION 2025-10-22",>00
        EVEN
            
START:      LIMI 0               ; Disable IRQ
            LWPI WRKSP           ; Set CPU registers workspace.

; Setup VDP for Mode 2 (3 tilesets for bitmap with 8x1 attributes).
            LI   R12,VDPWA       ; point to VDP write-address port

            ; VDP[0]: Mode Control 1
            ;   1: M2 (mode bit 2). Selects a bitmap graphics mode when set to 1. VDP[1] determines which bitmap mode is used.
            ;   0: Enable external VDP
            LI   R1,>0200      ; value = 0x02
            MOVB R1,*R12
            LI   R1,>8000      ; select VDP[0]
            MOVB R1,*R12

            ; VDP[1]: Mode Control 2
            ;   7: VRAM size select: 1 = 16KB; 0 = 4KB (set to 1).
            ;   6: Enable display. 1 = enabled; 0 = blank.
            ;   5: Enable VBlank IRQ. When this bit is 1, the VDP issues interrupt signals on the INT* pin each time it resumes refreshing the screen (vertical retrace signal).
            ;   4: M1 (mode bit 1). 1 = Text mode. VDP[0].2 can be set for bitmap text mode.
            ;   3: M3 (mode bit 3). 1 = Multicolor mode. VDP[0].2 can be set for bitmap multicolor mode.
            ;   2: Reserved. Set to 0.
            ;   1: Sprite size. 0 = 8x8 pixels; 1 = 16x16 pixels.
            ;   0: Sprite magnification. 0 = normal; 1 = doubled.
            LI   R1,>E200     ; NOTE: Enable also large sprites (16x16).
            MOVB R1,*R12
            LI   R1,>8100     ; select VDP[1]
            MOVB R1,*R12

            ; VDP[2]: Name Table Base Address. Only 4 bits [3..0] are used.
            ; Address = VDP[2] * $400
            LI   R1,>0700     ; VDP[2] = $07  (Name Table Base = 7*$400 = $1C00). [$1C00..$1EFF] for the $300 tiles on screen.
            MOVB R1,*R12
            LI   R1,>8200     ; select VDP[2]
            MOVB R1,*R12

            ; VDP[3]: Color Table Base Address.
            ; The table is not used in text mode, nor in multicolor mode.
            ; Address = VDP[3] * $40
            ; NOTE: In bitmap mode (VDP[0].2 = 1) the meaning of this register changes:
            ;   * Bit 7 determines the address: 0 = $0000; 1 = $2000.
            ;   * Bits [6..0] define the table size, forming a 13-bit address mask: [6..0]111111. The mask is AND-ed with the address of a character in the table.
            ;     In Mode 2, this gives 3×2KB color segments with 8×1 rows.
            LI   R1,>FF00     ; VDP[3] = $80 + $7F.  Color Table range [$2000..$37FF]. Mask=$1FFF.
            MOVB R1,*R12
            LI   R1,>8300     ; select VDP[3]
            MOVB R1,*R12

            ; VDP[4]: Pattern Generator Base Address. Only 3 bits [2..0] are used.
            ; Address = VDP[4] * $800
            ; NOTE: In text mode (VDP[1].4 = 1) the last two bits of each char line are ignored since characters are only 6-pixel wide.
            ; NOTE: In bitmap+text mode (VDP[0].2 = 1, VDP[1].4 = 1) the meaning of this register changes:
            ;   * Bit 2 determines the address: 0 = $0000; 1 = $2000.    
            ;   * Bits [1..0] define the table size, forming a 13-bit address mask: [1..0]11111111111. The mask is AND-ed with the address of a character in the table.            
            ; NOTE: In bitmap (non text) mode (VDP[0].2 = 1, VDP[1].4 = 1) the meaning of this register changes:
            ;   * Bit 2 determines the address: 0 = $0000; 1 = $2000.    
            ;   * Bits [1..0] define the table size, forming a 13-bit address mask: [1..0][Lower 11 bits from the Color Table Address mask].
            ; In Mode 2, the 3 screen thirds use PG at >0000, >0800, >1000.
            ;LI   R1,>0000     ; VDP[4] = $00  (Pattern Gen Base = $0000)
            LI   R1,>0300     ; VDP[4] = $03  (Pattern Gen Base = $0000). Mask=$1FFF.
            MOVB R1,*R12
            LI   R1,>8400     ; select VDP[4]
            MOVB R1,*R12

            ; VDP[5]: Sprite Attribute Base Address. Only bits [6..0] are used.
            ; Address = VDP[5] * $80
            LI   R1,>3E00     ; VDP[5] = $3E (Attribute Base = $3E*$80 = $1F00). [$1F00..$1F7F] for the 32 sprites (4 bytes each).
            MOVB R1,*R12
            LI   R1,>8500     ; select VDP[5]
            MOVB R1,*R12
            
            ; VDP[6]: Sprite Pattern Generator Base Address. Only bits [2..0] are used.
            ; Address = VDP[6] * $800
            LI   R1,>0300     ; VDP[6] = $03  (Pattern Gen Base = $3*$800 = $1800). [$1800..$1BFF] for the 32 sprites (32 bytes each).
            MOVB R1,*R12
            LI   R1,>8600     ; select VDP[6]
            MOVB R1,*R12

            ; VDP[7]: Overscan/Backdrop Color
            ;   Bits [7..4] = Foreground.
            ;   Bits [3..0] = Background.
            LI   R1,>1F00        ; VDP[7] = $F2 (F=black, B=white)
            MOVB R1,*R12         ; write value byte
            LI   R1,>8700        ; select VDP[7]
            MOVB R1,*R12

; -------- Set tiles for graphics mode --------
            ; Set VRAM write address to Name Table (tile indices) base = $1C00
            LI   R12,VDPWA
            LI   R1,>0000     ; low byte = $00 (in high lane)
            MOVB R1,*R12
            LI   R1,>5C00     ; high byte with write-bit: $40 | (addr>>8) = $5C
            MOVB R1,*R12
            ; Stream 32*24 = 768 bytes with incremental values (Mode 2 tiles, 3 banks).
            LI   R10,VDPWD
            LI   R1,>0000     ; Char code in high lane.
            LI   R2,>0300     ; 768 bytes
FILL:       MOVB R1,*R10
            AI   R1,>0100     ; Next tile index.
            DEC  R2
            JNE  FILL

; -------- Set color attributes --------
; Mode 2 Color Table has 3 segments of 2KB each, starting at $2000 (6144 bytes total).
            LI   R12,VDPWA       ; point to VDP write-address port
            ; Set VRAM write address to Color Table (attributes). [$2000..$37FF].
            LI   R1,>0000      ; low
            MOVB R1,*R12
            LI   R1,>6000      ; high = $40 | $20 = $60
            MOVB R1,*R12
            ; Stream attributes.
            LI   R10,VDPWD
            LI   R1,>F100      ; Color byte in high lane.
            LI   R2,>1800      ; 6144 bytes
CTLP:       MOVB R1,*R10
            ;AI   R1,>0100      ; Inc color Fg and Bg [FFFFBBBB]
            DEC  R2
            JNE  CTLP

; -------- Set bitmap --------
; Mode 2 tiles are 8 pixels (1 byte) per line, 8 lines, starting at $0000 (6144 bytes total).
            LI   R12,VDPWA       ; point to VDP write-address port
            ; Set VRAM write address to Color Table (attributes). [$0000..$1800].
            LI   R1,>0000      ; low
            MOVB R1,*R12
            LI   R1,>4000      ; high = 0x40 | 0x00 = 0x40
            MOVB R1,*R12
            ; Stream bitmap.
            LI   R10,VDPWD
            LI   R2,>1800      ; 6144 bytes
            ;LI R1,>AA00        ; Dither pattern.
            LI R1,>0000        ; Background only.
init_bmp:   ;MOV  R2,R1         ; Copy counter to R1.
            MOVB R1,*R10
            DEC  R2
            JNE  init_bmp

; -------- Set sprites attributes --------
; Set attributes for all 32 sprites (4*32 = 128 bytes total).
            LI   R12,VDPWA       ; point to VDP write-address port
            ; Set VRAM write address to Sprite Attributes Table (attributes). [$1F00..$1F7F].
            LI   R1,>0000      ; low
            MOVB R1,*R12
            LI   R1,>5F00      ; high = 0x40 | 0x1F = 0x40
            MOVB R1,*R12
            ; Stream sprite attributes.
            LI   R10,VDPWD
            LI   R4,>20        ; Counter: 32 sprites
            LI   R0,>0000      ; V-pos
            LI   R1,>0000      ; H-pos
            LI   R2,>0000      ; Name (pattern index).
            LI   R3,>0100      ; Bit 7 = Early Clock enable; Bits [3..0] = Color (black).
init_spra:  MOV  R4,R0         ; Copy counter to R0.
            SLA  R0,10         ; V-pos = n*4 << 8
            MOV  R0,R1         ; H-pos = n*4 << 8
        LI   R0,>D000      ; V-pos ($D0 terminates sprite list processing).
            MOVB R0,*R10
            MOVB R1,*R10
            MOVB R2,*R10
            MOVB R3,*R10
            AI   R2,>0100      ; Use a different pattern (bitmap) for each sprite.
            AI   R3,>0100      ; Use a different color for each sprite.
            ANDI R3,>0F00      ; Max 16 colors.
            DEC  R4
            JNE  init_spra

; -------- Set sprites bitmap --------
; We use 16x16 sprites, 2 bytes * 16 lines = 32 bytes each.
            LI   R12,VDPWA       ; point to VDP write-address port
            ; Set VRAM write address to Sprite Pattern Generator. [$1800..$1BFF].
            LI   R1,>0000       ; low
            MOVB R1,*R12
            LI   R1,>5800       ; high = 0x40 | 0x18 = 0x58
            MOVB R1,*R12
            ; Stream attributes.
            LI   R10,VDPWD
            LI   R2,>400        ; 1024 bytes
            LI R1,>FF00         ; Solid color.
init_sprb:  MOVB R1,*R10
            DEC  R2
            JNE  init_sprb

; -------- Install our VBlank IRQ --------
            LIMI 0
            LI   R0,vb_IRQ
            MOV  R0,@>83C4      ; User ISR hook
            LI   R0,>8000       ; Or mask.
            SOC  R0,@>83C2      ; Skip kernel stuff; call only our routine.
            LIMI IRQMASK

; -------- Go calculate Mandelbrot --------
            B    @Mandelbrot



;---------- Mandelbrot BEGIN
;
;BUF_ITERS_HR EQU >B000      ; Size =  128 bytes (2 * 8x8) to store a tile.
;BUF_ITERS_LR EQU >B000+128  ; Szie = 1536 bytes (2 * 32*24) to store screen "big pixels".
;BUF_COLOR   EQU  >C000  ; Colors buffer (2*8) = 16 bytes, for each pixel in the line (left to right).
;BUF_HIST    EQU  >D000  ; Hist buffer (2*16) = 32 bytes. 16 colors. Color 0 not used.
;TOP_2_COLS  EQU  >E000  ; Top 2 colors (2*2) = 4 bytes.

BUF_ITERS_HR:   BSS  128
BUF_ITERS_LR:   BSS 1536
BUF_COLOR:      BSS  2*8
BUF_HIST:       BSS 2*16
TOP_2_COLS:     BSS  2*2

; Bytes
;vars            EQU >A000          ; DRAM (slowest; only used for testing).
    .ifeq BUILD_TYPE,0
vars            EQU >8320           ; SRAM (after regs).
    .else
vars            EQU >83C8           ; SRAM (after regs and iters calc loop).
    .endif



pixelx          EQU vars + >00      ; Pixel x pos in current tile (0 = left).
pixely          EQU vars + >02      ; Pixel y pos in current tile (0 = top).
iter            EQU vars + >04
max_iter        EQU vars + >06
iters_ptr       EQU vars + >08
ax              EQU vars + >0A      ; Screen upper left corner x in complex plane.
ay              EQU vars + >0C      ; Screen upper left corner y in complex plane.
cx              EQU vars + >0E
cy              EQU vars + >10
incx            EQU vars + >12
incy            EQU vars + >14
zx              EQU vars + >16
zy              EQU vars + >18
zx2             EQU vars + >1A
zy2             EQU vars + >1C
mode            EQU vars + >1E      ; 0 = lo-res; 1 = hi-res.
tilex           EQU vars + >20      ; Current tile x pos [0..31]. Used only in high-res (32x24 tiles of 8x8 pixels).
tiley           EQU vars + >22      ; Current tile y pos [0..23]. Used only in high-res (32x24 tiles of 8x8 pixels).
tilew           EQU vars + >24      ; In lo-res, there is a single tile of 32x24 pixels. In high-res, tiles are 8x8.
tileh           EQU vars + >26      ; In lo-res, there is a single tile of 32x24 pixels. In high-res, tiles are 8x8.
tax             EQU vars + >28      ; Tile upper left corner x in complex plane.
tay             EQU vars + >2A      ; Tile upper left corner y in complex plane.
tmp_ret         EQU vars + >2C      ; Temporary return address for nested sub.
tmp0            EQU vars + >2E      ; Misc temporary storage.
tmp1            EQU vars + >30      ; Misc temporary storage.
tmp2            EQU vars + >32      ; Misc temporary storage.
frame_cnt       EQU vars + >34      ; Frame counter.
frame_cnt_start EQU vars + >36      ; Frame counter.

; $8300-$831F Registers
;;;;;;; $8320-$8356 Vars (see above) 
; $8320-839F  Iters-loop
; $83C0-$83FF System stuff.
 
Mandelbrot:
            ; Print welcome message.
            LI   R0,0
            LI   R1,0
            LI   R2,message
            BL   @print_str
            ; Wait 2 secs.
            LI   R0,120
            BL   @delay_frames
            
    .ifeq BUILD_TYPE,0
            ; Normal build, no relocation.
    .else
            ; Relocate iters loop in SRAM.
            LI   R0,nxt_iter
            LI   R1,>8320
relocate:   MOV  *R0+,*R1+
            CI   R0,end_reloc
            JNE  relocate
    .endif
            
            ; Init default params.
            CLR  @mode       ; Start in lo-res.

            ; Max iters
            LI   R0,>0010     ; 16 iters
            MOV  R0,@max_iter

            ; Default coordinates (fixed_point, *1024)
            LI   R0,-2*1024
            MOV  R0,@ax

            LI   R0,1500
            MOV  R0,@ay
            
            ; Uninit incx.
            CLR  @incx
            CLR  @incy

            ; Set lo-res. This will also setup resolutions specific params (if uninit).
            BL   @set_lo_res

            ; In lo-res, there is a single tile of 32x24 pixels.
            ; In hi-res, there are 32x24 tiles of 8x8 pixels.

calc_start:
            MOV  @frame_cnt,@frame_cnt_start

calc_tile:
            ; Init color pointer.
            LI   R0,BUF_ITERS_LR
            MOV  @mode,R1
            JEQ  calc_lr
            LI   R0,BUF_ITERS_HR
calc_lr:            
            MOV  R0,@iters_ptr

            CLR  @pixelx
            CLR  @pixely

            ; Start with upper left point (tax, tay).
            MOV  @tax,@cx
            MOV  @tay,@cy


; Calculate current point (cx, cy).
calc_point:
            CLR  @iter                  ; Reset iteration counter.
            CLR  @zx                    ; zx = 0
            CLR  @zy                    ; zy = 0
            LI   R8,>8000               ; Pattern for shift adjustments.

    .ifeq BUILD_TYPE,0
            ; Normal build, no relocated code.
    .else
            ; Experimental fast build. Jump to iters loop relocated to SRAM.
            B    @>8320
    .endif
            
            
            ;----------- RELOCATABLE ITERS LOOP
            ; WARN: If this is modified, make sure it still fits in SRAM if BUILD_TYPE 1 is used.
nxt_iter:
            ; z + c
            A    @cx,@zx                ; zx = zx + cx
            MOV  @zx,R0                 ; R0 = zx

            A    @cy,@zy                ; zy = zy + cy
            MOV  @zy,R2                 ; R2 = zy
    
            ; Compute zx*zx
            ABS  R0                     ; MPY only handles unsigned.
            MPY  R0,R0                  ; R0:R1 = zx*zx (*1024)
            ; Perform fixed point adjustment (divide by 1024)
            SRL  R1,1                   ; Shift LSW right.
            SRA  R0,1                   ; Arithmetic-shift MSW; C = Bit shifted out.
            JNC  srnc0x                 ; Don't set bit 15.
            SOC  R8,R1                  ; Set bit 15.
srnc0x:     ; Now R0:R1 = zx*zx (*512)
            SRL  R1,1                   ; Shift LSW right.
            SRA  R0,1                   ; Arithmetic-shift MSW; C = Bit shifted out.
            JNC  srnc1x                 ; Don't set bit 15.
            SOC  R8,R1                  ; Set bit 15.
srnc1x:     ; Now R0:R1 = zx*zx (*256)
            ; Now extract the central word (BC) from R0:R1 (AB:CD). This is faster than shifting right 8.
            SWPB R0                     ; R0=BA
            SWPB R1                     ; R1=DC
            MOVB R0,R1                  ; R1=BC. R1 = zx*zx = zx2
            MOV  R1,@zx2                ; Store zx2

            ; Compute zy*zy
            ABS  R2                     ; MPY only handles unsigned.
            MPY  R2,R2                  ; R2:R3 = zy*zy (*1024)
            ; Perform fixed point adjustment (divide by 1024).
            SRL  R3,1                   ; Shift LSW right.
            SRA  R2,1                   ; Arithmetic-shift MSW; C = Bit shifted out.
            JNC  srnc0y                 ; Don't set bit 15.
            SOC  R8,R3                  ; Set bit 15.
srnc0y:     ; Now R0:R1 = zx*zx (*512)
            SRL  R3,1                   ; Shift LSW right.
            SRA  R2,1                   ; Arithmetic-shift MSW; C = Bit shifted out.
            JNC  srnc1y                 ; Don't set bit 15.
            SOC  R8,R3                  ; Set bit 15.
srnc1y:     ; Now R2:R3 = zy*zy (*256)
            ; Now extract the central word (BC) from R2:R3 (AB:CD). This is faster than shifting right 8.
            SWPB R2                     ; R2=BA
            SWPB R3                     ; R3=DC
            MOVB R2,R3                  ; R3=BC. R3 = zy*zy = zy2
            ;MOV  R3,@zy2                ; Store zy2

            MOV  R1,R0                  ; R0 = zx2       
            A    R3,R0                  ; R0 = zx2 + zy2
            CI   R0,4*1024              ; Bailout test.
            JL   no_bail
            ;JHE  found_color            ; Early exit (not black).
            B    @found_color            ; Early exit (not black).
no_bail:        
            S    R3,R1                  ; R1 = zx2 - zy2 = new_zx
            MOV  @zx,R0                 ; R0 = zx
            MOV  R1,@zx                 ; new_zx = zx2 - zy2
            
            ; Must compute zx*zy, however MPY only handles unsigned.
            ; Check if zx and zy have opposed signs.
            MOV  R0,R2                  ; R0 = R2 = zx
            MOV  @zy,R1                 ; R1 = zy
            XOR  R1,R2                  ; R2[15] = Opposite signs (will need to NEG result).
            ABS  R0                     ; Convert to positive.
            ABS  R1                     ; Convert to positive.
            
            MPY  R1,R0                  ; R0:R1 = zx * zy
            ; Perform fixed point adjustment (divide by 512). NOTE: Only 512 because we need (2*zx*zy).
            SRL  R1,1                   ; Shift LSW right.
            SRA  R0,1                   ; Arithmetic-shift MSW; C = Bit shifted out.
            JNC  srnc0xy                ; Don't set bit 15.
            SOC  R8,R1                  ; Set bit 15.
srnc0xy:    ; Now R0:R1 = 2*zx*zy (*512)
            ; Now extract the central word (BC) from R0:R1 (AB:CD). This is faster than shifting right 8.
            SWPB R0                     ; R0=BA
            SWPB R1                     ; R1=DC
            MOVB R0,R1                  ; R1=BC. R1 = 2*zx*zy = new_zy
            ; Check if we need to NEG result (i.e. we had opposite signs).
            CI   R2,0
            JGT  no_neg
            NEG  R1
no_neg:            
            MOV  R1,@zy                 ; new_zy = 2*zx*zy
        
            ; Increment iters.
        
            INC  @iter
            C    @iter,@max_iter
            JNE  nxt_iter

    .ifeq BUILD_TYPE,0
            ; Normal build, no relocated code.
    .else
            ; Experimental fast build uses iters loop relocated to SRAM.
            B   @found_color             ; End of iters loop, resume from DRAM.
end_reloc:  NOP            
    .endif            

            ;----------- BACK FROM RELOCATABLE ITERS LOOP
found_color:
            MOV  @iter,R0
            MOV  @iters_ptr,R4
            MOV  R0,*R4                  ; Save iter.
            MOV  @mode,R1
            JNE  skp_render_pix          ; In HR, we wait for the entire 8x8 tile to be completed.
            ; Render low-res tile (single giant pixel). Setup call inputs:
            MOV  R0,R2                   ;   Iters.
            MOV  @pixelx,R0              ;   Big pixel x.
            MOV  @pixely,R1              ;   Big pixel y.
            BL   @render_big_pixel_LR    ; In LR, we render a "big" pixel (8x8 screen pixels).
skp_render_pix:
            INCT @iters_ptr

            ; Every 8 pixels check user input.
            LI   R0,>0007
            MOV @pixelx,R1
            CZC  R0,R1
            JEQ  nxt_point
            BL   @chk_input             ; Function chk_input will return here or directly branch to calc_point if needed.

; Go to nxt point.
nxt_point:
            A    @incx,@cx
            INC  @pixelx
            MOV  @pixelx,R0
            C    R0,@tilew           ; Check if reached tile width.
            JEQ  nxt_row
            B    @calc_point

nxt_row:    MOV  @mode,R0
            JEQ  .skip_render
            ; Render hi-res tile line (8x1).
            MOV  @iters_ptr,R3      ; R3 = Iter buffer end. Need to point to start.
            AI   R3,-2*8            ; R3 = Iter buffer start for line (8 words, one for each pixel).
            BL   @render_tile_line_HR
.skip_render:
            ; Increment row.
            S    @incy,@cy
            MOV  @tax,@cx
            CLR  @pixelx
            INC  @pixely
            C    @pixely,@tileh      ; Check if reached tile height.
            JEQ  end_tile
            B    @calc_point

            
end_tile:   ; End of tile.
            MOV  @mode,R0
            JNE  end_tile_hi_res
            ; In lo-res, we have just one tile.
            ; Set hi-res and recalculate.
            BL   @set_hi_res         ; Switch to hi-res.
            B    @calc_tile          ; Go calc first hi-res tile.
            

end_tile_hi_res:
            ; We are in hi-res.
            INC  @tilex
            MOV  @tilex,R0
            CI   R0,32
            JNE  prepare_nxt_tile
            ; Next tile row.
            CLR  @tilex
            INC  @tiley
            MOV  @tiley,R0
            CI   R0,24
            JEQ  end_mandel          ; All tiles done.
            
prepare_nxt_tile:
            ; Compute tax and tay for next tile.
            MOV  @incx,R0
            SLA  R0,3        ; Mul incx by 8 (tile width).
            MPY  @tilex,R0   ; Result in R0:R1
            A    @ax,R1
            MOV  R1,@tax
            
            MOV  @incy,R0
            SLA  R0,3        ; Mul incy by 8 (tile height).
            MPY  @tiley,R0   ; Result in R0:R1
            NEG  R1
            A    @ay,R1
            MOV  R1,@tay
;    ; Debug
;    LI R0,0    
;    LI R1,0
;    MOV @tilex,R2
;    BL @print_hex            
;    LI R2,','
;    BL @print_char
;    INC R0
;    MOV @tiley,R2
;    BL @print_hex
;    LI R2,'='
;    BL @print_char
;    INC R0    
;    MOV @tay,R2
;    BL @print_hex            
;    LI R2,','
;    BL @print_char
;    INC R0
;    MOV @tax,R2
;    BL @print_hex
            
            ; Check if this tile has to be skipped.
            MOV  @tilex,R0
            JEQ  no_skip
            CI   R0,31
            JEQ  no_skip
            MOV  @tiley,R1
            JEQ  no_skip
            CI   R1,23
            JEQ  no_skip
            ; Check neighbors big-pixels in LR buffer.
            MOV  R1,R2
            SLA  R2,6               ; 64 bytes per iters buffer row.
            MOV  R0,R3
            SLA  R3,1               ; 2 bytes per iter buffer element.
            A    R3,R2
            AI   R2,BUF_ITERS_LR    ; R2 = Ptr to LR tile iters ("big" pixel).
            MOV  *R2,R3             ; R3 = Tile iters.
            C    R3,@-2(R2)         ; Check W
            JNE  no_skip
            C    R3,@2(R2)          ; Check E
            JNE  no_skip
            C    R3,@-66(R2)        ; Check NW
            JNE  no_skip            
            C    R3,@-64(R2)        ; Check N
            JNE  no_skip
            C    R3,@-60(R2)        ; Check NE
            JNE  no_skip
            C    R3,@66(R2)        ; Check SE
            JNE  no_skip            
            C    R3,@64(R2)        ; Check S
            JNE  no_skip
            C    R3,@60(R2)        ; Check SW
            JNE  no_skip            
            ; Can skip tile.
            JMP  end_tile_hi_res
            
no_skip:            
            B    @calc_tile

end_mandel:
            ; End of screen.
            ; Print elapsed frames (in hex).
            LI   R0,28
            LI   R1,0
            MOV  @frame_cnt,R2
            S    @frame_cnt_start,R2
            BL   @print_hex
            
            ;LIMI 0
foreva:     
            BL   @chk_input
            JMP  foreva

          
; ------------------- SWITCH TO LOW RES -------------------
set_lo_res:
            MOV  @incx,R0
            JEQ  do_set_lo_res       ; First init. Don't check mode.
            MOV  @mode,R0
            JNE  do_set_lo_res
            B    *R11                ; Already in LR.
do_set_lo_res:
            MOV  R11,@tmp_ret        ; Save return address.
            LI   R0,>1F00
            BL   @set_screen_colors            
            MOV  @incx,R0            ; Check if incs are present.
            JNE  no_init_incs
            ; Default incs (LR).
            LI   R0,128
            MOV  R0,@incx
            MOV  R0,@incy
            JMP  cont_LR
no_init_incs:
            ; Check if we are switching back from HR.
            MOV  @mode,R0
            JEQ  cont_LR
            ; Back from HR.
            MOV  @incx,R0
            SLA  R0,2                ; Half-tile width in complex plane.
            A    R0,@ax              ; Horizontal tile centroid.
            SLA  R0,1                ; Tile width in complex plane.
            MOV  R0,@incx
            MOV  @incy,R0
            SLA  R0,2                ; Half-tile height in complex plane.
            S    R0,@ay              ; Vertical tile centroid.
            SLA  R0,1                ; Tile height in complex plane.
            MOV  R0,@incy
cont_LR:    CLR  @mode               ; Set mode to LOW RES (0).
            ; Tile size (LR).
            LI   R0,32
            MOV  R0,@tilew
            LI   R0,24
            MOV  R0,@tileh
            ; Reset tile coords.
            CLR  @tilex
            CLR  @tiley
            MOV  @ax,@tax
            MOV  @ay,@tay

            ; Clear bitmap.
            LI   R12,VDPWA       ; point to VDP write-address port
            LI   R1,>0000        ; low
            MOVB R1,*R12         
            LI   R1,>4000        ; high = 0x40 | 0x00 = 0x40
            MOVB R1,*R12         
            LI   R10,VDPWD       
            LI   R2,>1800        ; 6144 bytes
            LI   R1,>0000        ; Background only.
.cls_loop:  MOVB R1,*R10
            DEC  R2
            JNE  .cls_loop

            ; RETURN
            MOV  @tmp_ret,R11        ; Restore return address.
            B    *R11


; ------------------- SWITCH TO HIGH RES -------------------
set_hi_res:
            MOV @mode,R0
            JEQ do_set_hi_res
            B   *R11                ; Already in HR.
do_set_hi_res:            
            MOV R11,@tmp_ret        ; Save return address.
            LI R0,1
            MOV R0,@mode            ; Set mode to HIGH RES (1).
            LI  R0,>1E00
            BL  @set_screen_colors            
            ; We are switching back from LR, so undo centroids and divide incs by 8.
            MOV @incx,R0
            SRA R0,1                ; Half-tile width in complex plane.
            S   R0,@ax
            SRA R0,2                ; Tile width in complex plane.
            MOV R0,@incx
            MOV @incy,R0
            SRA R0,1                ; Half-tile height in complex plane.
            A   R0,@ay
            SRA R0,2
            MOV R0,@incy            ; Tile height in complex plane.
            ; Tile size (hi-res).
            LI  R0,8
            MOV R0,@tilew
            LI  R0,8
            MOV R0,@tileh
            ; Reset tile coords.
            CLR @tilex
            CLR @tiley
            MOV @ax,@tax
            MOV @ay,@tay
            ; RETURN
            MOV @tmp_ret,R11        ; Restore return address.
            B   *R11 

; ------------------- CALC ZOOM VALUES -------------------
; Set computation params based on new zoom value, keeping the screen centered.
; Inputs:
;   R2: New zoom inc (for both x and y).
; Outputs:
;   R2: [no change]
; Clobbered:
;   R0,R1
calc_zoom: 
            MOV  R2,R0
            S    @incx,R0       ; R0 = inc_diff
            SLA  R0,4           ; R0 = inc_diff*16 = ax adjustment
            S    R0,@ax
            
            MOV  R2,R0
            S    @incy,R0       ; R0 = inc_diff
            SLA  R0,2           ; R0 = inc_diff*4
            MOV  R0,R1
            SLA  R1,1           ; R1 = inc_diff*8
            A    R0,R1          ; R1 = inc_diff*12 = ay adjustment.
            A    R1,@ay

            MOV  R2,@incx
            MOV  R2,@incy
            ; RETURN
            B   *R11 

; ------------------- CHECK USER INPUT -------------------
chk_input:
            ; Check keyboard input and set R3[4..0]=[xxxFLRDU], like the joystick bits (1=pressed).
            ; We use the arrow keys ("E","S","D","X") and SHIFT as Fire (modifier; actually in this case... modifire ! :-).
            LI   R3,>00                 ; Defaulty to nothing pressed.
            ; Column 0
            LI   R12,>0024              ; CRU address for column selection.
            LI   R2,>0000               ; Column 0 for: =, SPACE,ENTER,FCTN,SHIFT,CTRL
            LDCR R2,3                   ; Select column (3 bits).
            TB   -10                    ; Test CRU bit for SHIFT (1=idle, 0=pressed).
            JEQ  not_SHIFT
            ORI  R3,>10                 ; SHIFT = Fire.
not_SHIFT:  ; Column 1
            LI   R2,>0100               ; Column 1 for: L,O,9,2,D,W,X
            LDCR R2,3                   ; Select column (3 bits).
            TB   -8                     ; Test CRU bit for "X" (1=idle, 0=pressed).
            JEQ  not_X
            ORI  R3,>02                 ; "X" = Down.
not_X:      TB   -10                    ; Test CRU bit for "S" (1=idle, 0=pressed).
            JEQ  not_S
            ORI  R3,>08                 ; "S" = Left.
not_S:      ; Column 2
            LI   R2,>0200               ; Column 2 for: ",",K,I,8,3,D,E,C
            LDCR R2,3                   ; Select column (3 bits).
            TB   -9                     ; Test CRU bit for "E" (1=idle, 0=pressed).
            JEQ  not_E
            ORI  R3,>01                 ; "E" = Up.
not_E:      TB   -10                    ; Test CRU bit for "D" (1=idle, 0=pressed).
            JEQ  not_D
            ORI  R3,>04                 ; "D" = Right.
not_D:  
;        ; Debug print R3 (input bits).
;        LI   R0,0
;        LI   R1,0
;        MOV  R3,R2
;        BL   @print_hex
            
            MOV  R3,R3                  ; Check if we have any input.
            LI   R2,>0F                 ; Ignore FIRE (used only as modifier).
            CZC  R2,R3                  ; Check if any direction bit is set.
            JNE  have_input
            ; No input. RETURN
            B   *R11 

have_input:            
            ; We have some input.
            BL   @set_lo_res            ; Any input causes to restart from LO-RES. This does not clobber R3.
            LI   R2,>10                 ; Check if FIRE pressed.
            COC  R2,R3
            JEQ  fire_pressed
            ; Fire NOT pressed.
            ; Check UP
            LI   R2,>01
            COC  R2,R3
            JNE  no_UP
            ; UP
            A    @incy,@ay
            JMP  no_DOWN
no_UP:      ; Check DOWN
            LI   R2,>02
            COC  R2,R3
            JNE  no_DOWN
            ; DOWN
            S    @incy,@ay
no_DOWN:    ; Check LEFT
            LI   R2,>08
            COC  R2,R3
            JNE  no_LEFT
            ; LEFT
            S    @incx,@ax
            JMP  no_RIGHT
no_LEFT:    ; Check RIGHT
            LI   R2,>04
            COC  R2,R3
            JNE  no_RIGHT
            ; RIGHT
            A    @incx,@ax
no_RIGHT:   ; Finally recalculate lo-res mandel.
            MOV  @ax,@tax
            MOV  @ay,@tay
            LI   R0,10
            BL   @delay_frames
            B    @calc_start
            
            ; Fire pressed.
fire_pressed:
            ; Check UP (zoom in)
            LI   R2,>01
            COC  R2,R3
            JNE  no_UPf
            ; UP (zoom in)
            MOV  @incx,R2
            CI   R2,8
            JLE  zmin_skp
            SRA  R2,1
            BL   @calc_zoom
zmin_skp:   LI   R0,0
            LI   R1,0
            BL   @print_hex
            JMP  no_DOWNf
no_UPf:     ; Check DOWN (zoom out)
            LI   R2,>02
            COC  R2,R3
            JNE  no_DOWNf
            ; DOWN (zoom out)
            MOV  @incx,R2
            CI   R2,128
            JHE  zmout_skp
            SLA  R2,1
            BL   @calc_zoom
zmout_skp:  LI   R0,0
            LI   R1,0
            BL   @print_hex
            JMP  no_RIGHTf
no_DOWNf:   ; Check LEFT (iters--)
            LI   R2,>08
            COC  R2,R3
            JNE  no_LEFTf
            ; LEFT  (iters--)
            MOV  @max_iter,R2
            CI   R2,1
            JLE  itdec_skp
            DEC  R2
            MOV  R2,@max_iter
itdec_skp:  LI   R0,0
            LI   R1,0
            BL   @print_hex
            JMP  no_RIGHTf
no_LEFTf:   ; Check RIGHT (iters++)
            LI   R2,>04
            COC  R2,R3
            JNE  no_RIGHTf
            ; RIGHT (iters++)
            MOV  @max_iter,R2
            CI   R2,511
            JHE  itinc_skp
            INC  R2
            MOV  R2,@max_iter
itinc_skp:  LI   R0,0
            LI   R1,0
            BL   @print_hex
no_RIGHTf:  ; Finally recalculate lo-res mandel.
            MOV  @ax,@tax
            MOV  @ay,@tay
            LI   R0,10
            BL   @delay_frames
            
            B    @calc_start        ; Do not return. Branch directly to calc_tile.

; ------------------- RENDER PIXEL (LOW RES) -------------------
; Fill a LR pixel (8x8) with an iteration color. Low res tiles are 32x24.
; Mode 2 Color Table has 3 segments of 2KB each, starting at VRAM addr $2000 (6144 bytes total).
; NOTE: This method expects the bitmap to be all 0 (backround).
; Inputs:
;   R0: x position of big pixel (i.e. 8x8 screen pixels).
;   R1: y position of big pixel (i.e. 8x8 screen pixels).
;   R2: If <= 0: Use color = -R2 (no remapping).
;       If >  0: Iterations for this pixel (we calc remapped color based on iterations).
; Outputs:
;   [none]
; Clobbered:
;   R0,R1,R2,R3,R12
render_big_pixel_LR:
            LIMI 0
            LI   R12,VDPWA          ; point to VDP write-address port
            ;MOV  R0,R2
            ;MOV  @pixely,R0
            SWPB R1                 ; R1 = High byte of offset = y*32*8 = y*256.
            ;MOV  @pixelx,R3
            SLA  R0,3               ; R0 = Low byte of offset = x*8.
            MOVB R1,R0              ; R0 = 8x8 tile (big pixel) offset in VRAM.
            SWPB R0                 ; Put low byte of 8x8 tile address in high lane.
            MOVB R0,*R12            ; Low byte of VRAM write addr.
            SWPB R0                 ; Put high byte in high lane.
            ; Clear bitmap.
            ORI  R0,>4000           ; OR $4000 ($0000 start addr | $4000 write op).
            MOVB R0,*R12            ; High byte of VRAM write addr.
            LI   R12,VDPWD
            CLR  *R12
            CLR  *R12
            CLR  *R12
            CLR  *R12
            CLR  *R12
            CLR  *R12
            CLR  *R12
            CLR  *R12

            LI   R12,VDPWA          ; point to VDP write-address port
            ORI  R0,>6000           ; OR $6000 ($2000 start addr | $4000 write op).
            SWPB R0                 ; Put low byte of 8x8 tile address in high lane.
            MOVB R0,*R12            ; Low byte of VRAM write addr.
            SWPB R0                 ; Put high byte in high lane.
            MOVB R0,*R12            ; High byte of VRAM write addr.
            
            ; Convert iters to color.
            CI   R2,0               ; Check if forced color.
            JGT  use_iters
            NEG  R2
            JMP  fnd_col0
use_iters:            
            C    R2,@max_iter       ; If not max_iter, it's not black.
            ; Force black.
            JNE  not_blk0
            LI   R2,1               ; Black.
            JMP  fnd_col0
not_blk0:   ; Not black. Color = (iter % 14) + 1.
            LI   R0,14              ; Colors are mod 14.
            CLR  R1                 ; R1:R2 = Iters.
            DIV  R0,R1              ; R1 = R1:R2/14 (quotient); R2=R1:R2%14 (remainder).
            INCT R2                 ; Add 2 to skip transparent and black.
            SLA  R2,1
            MOV  @color_grad(R2),R2 ; Remap to color gradient.            
fnd_col0:   
            ; Stream attributes.
            LI   R12,VDPWD
            SWPB R2                 ; Put color in high lane byte.
            ORI  R2,>F000           ; Set foreground color white, backgound transparent (for debug/info text).
            MOVB R2,*R12
            MOVB R2,*R12
            MOVB R2,*R12
            MOVB R2,*R12
            MOVB R2,*R12
            MOVB R2,*R12
            MOVB R2,*R12
            MOVB R2,*R12
            LIMI IRQMASK
            ; RETURN
            B    *R11


; ------------------- RENDER TILE LINE (8x1 pixels, HI RES) -------------------
; Inputs:
;   @tilex:     x position of tile.
;   @tiley:     y position of tile.
;   R3:         ptr to iteration buffer (8 words, one for each pixel in line).
; Outputs:
;   [none]
; Clobbered:
;   R0,R1,R2,R3,R4,R5,R6,R12
render_tile_line_HR:
            ; Convert iters to colors and compute histogram.
            LI   R4,BUF_COLOR       ; R4 = Colors buffer.
            LI   R5,BUF_HIST        ; R5 = Hist buffer.
            
            ; Clear histogram.
            LI   R0,16
clr_hist:   CLR  *R5+
            DEC  R0
            JNE  clr_hist
            
            LI   R6,8               ; 8 values to parse.
parse_line: ; Convert iter to color.
            MOV  *R3+,R2            ; Fetch pixel iters, and point to next pixel iters.
            C    R2,@max_iter       ; If not max_iter, it's not black.
            JNE  not_blk1
            LI   R2,1               ; Black.
            JMP  fnd_col1
not_blk1:   ; Not black. Color = (iter % 14) + 1.
            LI   R0,14              ; Colors are mod 14.
            CLR  R1                 ; R1:R2 = Iters.
            DIV  R0,R1              ; R1 = R1:R2/14 (quotient); R2=R1:R2%14 (remainder).
            INCT R2                 ; Add 2 to skip transparent and black.
            SLA  R2,1               ; R2 = Offset in gradient table.
            MOV  @color_grad(R2),R2 ; R2 = Color remapped to gradient.
fnd_col1:   ; Store color in Colors buffer.
            MOV  R2,*R4+
            ; Inc histogram for color.
            SLA  R2,1
            INC  @BUF_HIST(R2)
            ; Parse the next pixel.
            DEC  R6
            JNE  parse_line
            
            ; Find top 2 colors in histogram.
            LI   R3,TOP_2_COLS      ; Point to TOP_2_COLS buf.
            ; ; If Black is present, it is the top one regardless of count.
            ; MOV  @BUF_HIST+2,R2     ; R2 = Count of color 1 (Black).
            ; JEQ  scan_histo
            ; ; Top color is Black, point to second top color.
            ; CLR  *R3
            ; INC  *R3+               ; Black is color 1.
scan_histo:
            ; Find most used color [1..15].
            LI   R5,BUF_HIST+2      ; R5 = Buf histogram, start from color 1.
            LI   R0,1               ; Current color number.
            CLR  R1                 ; Top color number.
            CLR  R2                 ; Top color count.
scn_h_nxt:  MOV  *R5+,R6            ; Fetch count from histogram.
            C    R6,R2              ; Compare count (R6) with top count (R2).
            JL   scn_h_skp          ; If count (R6) < top count (R2), skip.
            ; Found more used color.
            MOV  R0,R1              ; Update top color number.
            MOV  R6,R2              ; Update top color count.
scn_h_skp:  INC  R0
            CI   R0,16
            JNE  scn_h_nxt
            ; Save top color number in TOP_2_COLS array.
            MOV  R1,*R3+
            SLA  R1,1               ; R2 = 2*color
            AI   R1,BUF_HIST        ; Find top color slot in histogram.
            CLR  *R1                ; Zero count of picked color (so we won't pick it again).
            ; Check if we need another top color.
            CI   R3,TOP_2_COLS+4
            JNE  scan_histo
            
            ; Remap all 8 pixels to either top0 (foreground) or top1 (background).
            LI   R1,BUF_COLOR       ; R1 = Colors buffer (colors of all 8 pixels).
            LI   R3,>80             ; R3 = Bit mask.
            LI   R2,>00             ; R2 = Bitmap byte.
nxt_lpix:   MOV  *R1+,R0            ; R0 = Color to process.
            ; Check exact matches.
            C    R0,@TOP_2_COLS     ; Compare to top0.
            JNE  no_top0
            ; Matched top0, make it foreground.
            SOC  R3,R2              ; Or mask.
            JMP  col_done
no_top0:    C    R0,@TOP_2_COLS+2   ; Compare to top1.
            JEQ  col_done           ; Matched top1. Nothing to do (bit is already 0).
            ; Best match using perceptual difference table.
            SLA  R0,5               ; R0 = Row offset in diff-table (each row is 32 bytes).
            AI   R0,color_pdiff     ; R0 = Table row ptr for comparison.
            MOV  @TOP_2_COLS,R4     ; R4 = Top0.
            SLA  R4,1               ; R4 = Top0 offset in row.
            A    R0,R4              ; R4 = Top0 diff ptr.
            MOV  *R4,R4             ; R4 = Top0 diff.
            MOV  @TOP_2_COLS+2,R5   ; R5 = Top1.
            SLA  R5,1               ; R5 = Top1 offset in row.
            A    R0,R5              ; R5 = Top1 diff ptr.
            MOV  *R5,R5             ; R5 = Top1 diff.
            C    R4,R5              ; Compare top0 diff (R4) with top1 diff (R5).
            JH   col_done           ; If top0 diff (R4) > top1 diff (R4), use top1 (nothing to do).
            ; If top1 diff (R5) >= top0 diff (R4). Use top0.
            SOC  R3,R2              ; Or mask.
col_done:   ; Move to next pixel in line.
            SRL  R3,1
            JNE  nxt_lpix
            
            ; All 8 pixels processed. R2 is our bitmap byte to write.

            ; Find tile offset in VRAM.
            MOV  @tiley,R0
            SWPB R0                 ; High byte = tiley*32*8 = tiley*256.
            MOV  @tilex,R3
            SLA  R3,3               ; Mul by 8.
            MOVB R0,R3              ; R3 = Tile offset in VRAM.
            A    @pixely,R3         ; R3 = Tile line offset in VRAM.
            
            LIMI 0
            LI   R12,VDPWA          ; point to VDP write-address port
            SWPB R3                 ; Put low byte of tile address in high lane.
            MOVB R3,*R12            ; Low byte of VRAM write addr.
            SWPB R3                 ; Put high byte in high lane.
            ORI  R3,>4000           ; OR $4000 ($0000 start addr | $4000 write op).
            MOVB R3,*R12            ; High byte of VRAM write addr.
            ; Stream bitmap.
            LI   R12,VDPWD
        ;LI R2,>00AA
            ; [...]
            SWPB R2                 ; Put bitmap byte in high lane byte.
            MOVB R2,*R12
            ; Set the top colors for this line (top0 = Foreground, top1 = Background).
            LI   R12,VDPWA          ; point to VDP write-address port
            SWPB R3                 ; Put low byte of tile address in high lane.
            MOVB R3,*R12            ; Low byte of VRAM write addr.
            SWPB R3                 ; Put high byte in high lane.
            ORI  R3,>6000           ; OR $6000 ($2000 start addr | $4000 write op).
            MOVB R3,*R12            ; High byte of VRAM write addr.
            ; Stream attributes.
            LI   R12,VDPWD
            MOV  @TOP_2_COLS,R2     ; R2 = Top0 color.
            SLA  R2,4               ; Move color to Foreground.
            SOC  @TOP_2_COLS+2,R2   ; R2 = Top0 (Foreground), Top1 (Background).
        ;MOV @TOP_2_COLS,R2
            SWPB R2                 ; Put colors in high lane byte.
            MOVB R2,*R12
            LIMI IRQMASK

;        ; Debug
;        MOV R11,R14
;        LI R0,0    
;        LI R1,0
;        ;MOV @tilex,R2
;        BL @print_hex            
;        ;LI R2,','
;        ;BL @print_char
;        ;INC R0
;        ;MOV @tiley,R2
;        ;BL @print_hex
;        MOV R14,R11
;    
;        ; Debug "zoom" tile line as big pixels at upper left corner of screen.
;        MOV  R11,@tmp_ret
;        CLR  R6             ; Pixel counter.
;        MOV  @iters_ptr,R8  ; Ptr to end of iters buf.
;        AI   R8,-16         ; Ptr to start of iters buf.
;debug_tile_line_HR:
;        MOV  R6,R0          ; Big pixel x.
;        MOV  @pixely,R1     ; Big pixel y.
;        ANDI R1,7
;        MOV  *R8+,R2        ; Iters.
;        BL   @render_big_pixel_LR
;        INC  R6
;        CI   R6,8
;        JNE  debug_tile_line_HR
;        ; Show TOP colors at x-pos 9 and 10.
;        LI   R0,9
;        MOV  @pixely,R1
;        MOV  @TOP_2_COLS,R2
;        NEG  R2              ; Force color.
;        BL   @render_big_pixel_LR
;        LI   R0,10
;        MOV  @pixely,R1
;        MOV  @TOP_2_COLS+2,R2
;        NEG  R2              ; Force color.
;        BL   @render_big_pixel_LR
;        MOV  @pixely,R1
;        CI   R1,7            ; Don't allow pause if tile is not complete.
;        JNE  no_SPACE
;        ; Check if space is pressed.
;tst_SPACE:  CLR  R1          ; Column 0 (SPACE is in column 0)
;        LI   R12,>0024
;        LDCR R1,3            ; Select column.
;        LI   R12,>0008       ; row address for SPACE (active-low)
;        TB   0               ; Test CRU bit 0 (1=idle, 0=pressed)
;        JNE  tst_SPACE       ; Wait until SPACE is kept pressed.
;no_SPACE:
;        MOV  @tmp_ret,R11    ; Restore return addr.

            ; RETURN
            B   *R11

; ------------------- TABLE OF ALL 14 COLORS SORTED TO FORM A VISUALLY PLEASING GRADIENT -------------------
color_grad:
;       +----+-----------------------+-----------+
;       |Hex | Name                  | Render    |
;       +----+-----------------------+-----------+
    DATA >0  ; Transparent           | #xxxxxx   |
    DATA >1  ; Black                 | #000000   |
    DATA >E  ; Gray                  | #C0C0C0   |
    DATA >F  ; White                 | #FFFFFF   |
    DATA >7  ; Cyan                  | #5EDCFF   |
    DATA >4  ; Dark Blue             | #5455ED   |
    DATA >5  ; Light Blue            | #7D76FC   |
    DATA >D  ; Magenta               | #C95BE7   |
    DATA >6  ; Dark Red              | #D4524D   |
    DATA >8  ; Medium Red            | #FF7978   |
    DATA >9  ; Light Red             | #FFB6B5   |
    DATA >B  ; Light Yellow          | #E6CE80   |
    DATA >A  ; Dark Yellow (Olive)   | #D4C154   |
    DATA >3  ; Light Green           | #5EDC78   |
    DATA >2  ; Medium Green          | #21C842   |
    DATA >C  ; Dark Green            | #21B03B   |
;            +-----------------------+-----------+

; ------------------- TABLE OF PERCEPTUAL DIFFERENCES BETWEEN COLORS -------------------
color_pdiff:
;            0,     1,     2,     3,     4,     5,     6,     7,     8,     9,     A,     B,     C,     D,     E,     F
    DATA 00000, 65535, 65535, 65535, 65535, 65535, 65535, 65535, 65535, 65535, 65535, 65535, 65535, 65535, 65535, 65535 ; 0
    DATA 65535, 00000, 42950, 48572, 28555, 33522, 30592, 50264, 39042, 48764, 47028, 51053, 37449, 34535, 44082, 65535 ; 1
    DATA 65535, 42950, 00000, 04857, 42000, 38907, 47837, 28877, 47491, 38812, 17096, 18702, 04287, 37764, 19452, 22882 ; 2
    DATA 65535, 48572, 04857, 00000, 41226, 37504, 46651, 25697, 45526, 36514, 16616, 17293, 08192, 36976, 17754, 19746 ; 3
    DATA 65535, 28555, 42000, 41226, 00000, 07704, 26625, 27272, 28451, 29702, 47899, 44828, 39944, 13377, 26865, 33367 ; 4
    DATA 65535, 33522, 38907, 37504, 07704, 00000, 25683, 22217, 25215, 24705, 43971, 40579, 37516, 10428, 21536, 27283 ; 5
    DATA 65535, 30592, 47837, 46651, 26625, 25683, 00000, 43248, 08427, 16541, 30316, 28291, 45675, 21726, 21719, 28119 ; 6
    DATA 65535, 50264, 28877, 25697, 27272, 22217, 43248, 00000, 41282, 33868, 29624, 27316, 29084, 30216, 14452, 16016 ; 7
    DATA 65535, 39042, 47491, 45526, 28451, 25215, 08427, 41282, 00000, 09355, 28617, 25494, 45993, 20721, 17632, 22221 ; 8
    DATA 65535, 48764, 38812, 36514, 29702, 24705, 16541, 33868, 09355, 00000, 23615, 20082, 38278, 21595, 13736, 15766 ; 9
    DATA 65535, 47028, 17096, 16616, 47899, 43971, 30316, 29624, 28617, 23615, 00000, 04107, 17782, 45910, 16289, 18725 ; A
    DATA 65535, 51053, 18702, 17293, 44828, 40579, 28291, 27316, 25494, 20082, 04107, 00000, 19686, 41853, 14338, 15673 ; B
    DATA 65535, 37449, 04287, 08192, 39944, 37516, 45675, 29084, 45993, 38278, 17782, 19686, 00000, 36457, 19892, 24752 ; C
    DATA 65535, 34535, 37764, 36976, 13377, 10428, 21726, 30216, 20721, 21595, 45910, 41853, 36457, 00000, 21618, 27119 ; D
    DATA 65535, 44082, 19452, 17754, 26865, 21536, 21719, 14452, 17632, 13736, 16289, 14338, 19892, 21618, 00000, 09254 ; E
    DATA 65535, 65535, 22882, 19746, 33367, 27283, 28119, 16016, 22221, 15766, 18725, 15673, 24752, 27119, 09254, 00000 ; F


; ------------------- SET SCREEN COLORS -------------------
; Inputs:
;   R0: $FBxx (F=Foreground, B=Background, x=Unused).
; Outputs:
;   [none]
; Clobbered:
;   R12
set_screen_colors:
            LIMI 0
            LI   R12,VDPWA       ; point to VDP write-address port
            MOVB R0,*R12         ; write value byte
            LI   R0,>8700        ; select VDP[7]
            MOVB R0,*R12
            LIMI IRQMASK
            ; RETURN
            B   *R11


; ------------------- PRINT STRING -------------------
; Inputs:
;   R0: x-pos [0..31]
;   R1: y-pos [0..24]
;   R2: Ptr to STR.
; Outputs:
;   [none]
; Clobbered:
;   R0,R1,R2,R3,R4,R5
print_str:            
            MOV     R11,@tmp_ret    ; Save return addr.
            MOV     R2,R5           ; R5 = str ptr.
.nxtchr:    CLR     R2
            MOVB    *R5+,R2         ; Fetch char to print.
            SWPB    R2
            JEQ     .done           ; End of str.
            CI      R2,>0D          ;
            JNE     .no_CR
            ; CR
            LI      R0,0            ; Newline: x=0.
            INC     R1              ; Newline: y++
            JMP     .nxtchr
.no_CR      MOV     R0,R3           ; Save x
            MOV     R1,R4           ; Save y
            BL      @print_char
            MOV     R3,R0           ; Restore x
            INC     R0              ; Inc x.
            MOV     R4,R1           ; Restore y
            JMP     .nxtchr
.done:      ; RETURN
            MOV     @tmp_ret,R11    ; Restore return addr.
            B       *R11 

; ------------------- PRINT CHAR -------------------
; Inputs:
;   R0: x-pos [0..31]
;   R1: y-pos [0..24]
;   R2: ASCII
; Outputs:
;   [none]
; Clobbered:
;   [none]
GROM_FONT_BASE  EQU  >06B4        ; printable set in GROM: ' ' .. '~' (32..126)

print_char:
            ; Save R0,R1,R2.
            MOV     R0,@tmp0
            MOV     R1,@tmp1
            MOV     R1,@tmp2

            ; Find VRAM destination address.
            SWPB    R1            ; R1 = y*256
            SLA     R0,3          ; R0 = x*8
            A       R0,R1         ; R1 = VRAM dest addr.
            
            ; Write VDP start address (attribs).
            LIMI    0
            SWPB    R1             ; Put low byte of address in high lane.
            MOVB    R1,@VDPWA      ; Low byte of VRAM write addr.
            SWPB    R1             ; Put high byte in high lane.
            ORI     R1,>6000       ; OR $4000 ($0000 start addr | $4000 write op).
            MOVB    R1,@VDPWA      ; High byte of VRAM write addr.
            ; Stream attribs (Dark Red foreground, transparent background).
            MOVB    R1,@VDPWD
            MOVB    R1,@VDPWD
            MOVB    R1,@VDPWD
            MOVB    R1,@VDPWD
            MOVB    R1,@VDPWD
            MOVB    R1,@VDPWD
            MOVB    R1,@VDPWD
            MOVB    R1,@VDPWD

            ; Write VDP start address (bitmap).
            SWPB    R1             ; Put low byte of address in high lane.
            MOVB    R1,@VDPWA      ; Low byte of VRAM write addr.
            SWPB    R1             ; Put high byte in high lane.
            ANDI    R1,>4FFF       ; Remove attribs offset.
            ;ORI     R1,>4000       ; OR $4000 ($0000 start addr | $4000 write op).
            MOVB    R1,@VDPWA      ; High byte of VRAM write addr.            
            
            ; Char glyph addr = $06B4 + (ASCII-32)*7
            AI      R2,-32
            MOV     R2,R1
            SLA     R2,3                  ; *8
            S       R1,R2                 ; *7
            LI      R0,GROM_FONT_BASE
            A       R2,R0                 ; R0 = GROM addr of glyph.

            ; Write GROM start address (high byte first) to >9C02
            MOVB    R0,@GRMWA      ; High byte of addr first.
            SWPB    R0
            MOVB    R0,@GRMWA      ; Low byte of addr next.

            ; Stream 8 bytes from GROM to VRAM.
            LI      R1,7           ; Glyph height is 7 bytes.
.cpy8       MOVB    @GRMRD,@VDPWD  ; Copy byte to RAM, R1++
            DEC     R1
            JNE     .cpy8
            MOVB    R1,@VDPWD      ; Write 0 to 8th byte.
            LIMI    IRQMASK
            
            ; Restore R0,R1,R2.
            MOV     @tmp0,R0
            MOV     @tmp1,R1
            MOV     @tmp2,R2
            ; RETURN
            B   *R11


; ------------------- PRINT HEX -------------------
; Inputs:
;   R0: x-pos [0..31]
;   R1: y-pos [0..24]
;   R2: value
; Outputs:
;   R0: x-pos + 4
;   R1: y-pos (no change).
;   R2: value (no change).
; Clobbered:
;   R12
print_hex:
            MOV     R11,@tmp_ret    ; Save return addr.
            MOV     R2,R12          ; Save value.

            SWPB    R2
            SRL     R2,4
            ANDI    R2,>0F
            CI      R2,>0A
            JHE     alpha_0
            ; Not alpha, i.e. [0..9]
            AI      R2,'0'-'A'+10
alpha_0:    AI      R2,'A'-10
            BL      @print_char

            INC     R0
            MOV     R12,R2
            SWPB    R2
            ANDI    R2,>0F
            CI      R2,>0A
            JHE     alpha_1
            ; Not alpha, i.e. [0..9]
            AI      R2,'0'-'A'+10
alpha_1:    AI      R2,'A'-10
            BL      @print_char            
            
            INC     R0
            MOV     R12,R2
            SRL     R2,4
            ANDI    R2,>0F
            CI      R2,>0A
            JHE     alpha_2
            ; Not alpha, i.e. [0..9]
            AI      R2,'0'-'A'+10
alpha_2:    AI      R2,'A'-10
            BL      @print_char

            INC     R0
            MOV     R12,R2
            ANDI    R2,>0F
            CI      R2,>0A
            JHE     alpha_3
            ; Not alpha, i.e. [0..9]
            AI      R2,'0'-'A'+10
alpha_3:    AI      R2,'A'-10
            BL      @print_char            
            
            INC     R0              ; Advance x-pos.
            ; Restore R2
            MOV     R12,R2
            ; RETURN
            MOV     @tmp_ret,R11    ; Restore return addr.
            B       *R11         
            


; ------------------- DELAY FOR THE SPECIFIED AMOUNT OF FRAMES -------------------
; Inputs:
;   R0: Number of frames. 
;       NOTE: This works on VBlank, so the first frame will delay for an unknown amount (depends on raster pos).
; Outputs:
;   [none]
; Clobbered:
;   R0
delay_frames:
    .ifeq BUILD_TYPE,0
            ; Normal build, use frame_cnt updated by VBlank IRQ.
            A       @frame_cnt,R0       ; Final frame to wait for.
delf_loop:  C       @frame_cnt,R0
            JNE     delf_loop
    .else
;            ; Experimental fast build. Busy loop.
;            SWPB    R0                  ; R0 *= 256
;delay:      DEC     R0
;            JNE     delay
            CB       @VDPST,R0        ; clear any pending F
wvblank:    CB       @VDPST,R0        ; read status again
            JGT      wvblank
            JEQ      wvblank
            DEC      R0
            JNE      wvblank
    .endif
            ; RETURN
            B       *R11


; ------------------- VBLANK IRQ ROUTINE -------------------
; NOTE: This is only used if BUILD_MODE=0
vb_IRQ:     CB      @VDPST,R0           ; Dummy read to clear VDP's Interrupt Flag.
            ; Custom code (MUST preserve registers).
            INC     @frame_cnt
            SETO    @>83D6              ; Reset the ROM’s idle counter to avoid the blanker (screensaver).
            B       *R11






; ------------------- END -------------------
            END