; mandelF18A (F18A-only TMS9900 port of Mandelbr8).
; DDT's fixed-point Mandelbrot generator. Requires RAM expansion and F18A.
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
;   2026-08-12: F18A support (colors and acceleration); algorithm optimizations. [DDT]
;   2026-08-13: Initial F18A support for 128x192 fat-pixel graphics (W.I.P). [DDT]
;   2026-08-25: Split source code for CPU builds (mandel99.asm) and F18A GPU build (mandelF18A.asm).
;               *** This is the mandelF18A build. ****
;               Removed code not related to F18A (e.g. Graphics-II rendering).
;               Now using fat pixels. Relocate sprite tables above F18A fat-pixel framebuffer to work around Classic99 bug.
;               Moved full Mandel calculation, working variables, tile-skip logic, color mapping, and framebuffer rendering to the F18A GPU. GPU image XORG at >4000 and is checked against the >4800 GRAM limit.
;               Fixed signed MPY bug handling 2*zx*zy.
;               Changed fixed point to Q6.12 for increased precision and 4x zoom-in ability.
;               Optimized iteration loop.

        IDT  'MANDF18A'
        DEF  ENTRY

        AORG >A000

ENTRY:  JMP  START

IRQMASK EQU  >0002

; CPU workspace (for TMS9900 CPU registers).
WRKSP   EQU  >8300
R0LB    EQU  WRKSP+1

; VDP interface.
VDPRD   EQU  >8800
VDPST   EQU  >8802
VDPWD   EQU  >8C00
VDPWA   EQU  >8C02

; GROM interface (console font only).
GRMRD   EQU  >9800
GRMWA   EQU  >9C02

; F18A framebuffer / shared VRAM layout.
FP_FB_BASE      EQU >0000           ; 128x192, 4-bpp fat pixels, 64 bytes/line.
FP_FB_SIZE      EQU >3000           ; 64 * 192 = 12288 bytes.
GPU_LR_BUF      EQU >3000           ; 32*24 words = >0600 bytes, through >35FF.

; CPU <-> GPU control block in ordinary VRAM.
GPU_ABORT_FLAG  EQU >3600           ; WORD: 0=run, nonzero=abort current render.
GPU_JOB         EQU >3602           ; WORD: 0=32x24 LR, 1=128x192 HR refinement.
GPU_AX          EQU >3604           ; WORD: LR upper-left X (Q4.12, *4096).
GPU_AY          EQU >3606           ; WORD: LR upper-left Y (Q4.12, *4096).
GPU_INC         EQU >3608           ; WORD: LR X/Y increment (Q4.12).
GPU_MAXITER     EQU >360A           ; WORD: Maximum iteration count.
SPR_ATTR_BASE   EQU >3680           ; Dedicated sprite attribute table; first byte is >D0 terminator.

; GPU image loader staging area in ordinary VRAM.
GPU_LOAD_SRC    EQU >3800           ; >0600-byte staging window: >3800..>3DFF.
GPU_LOADER_PC   EQU >3E00           ; Bootstrap executed directly from VRAM.
GPU_LDR_SRC     EQU >37F0           ; Loader source word address.
GPU_LDR_DST     EQU >37F2           ; Loader destination word address (GPU-local RAM).
GPU_LDR_WORDS   EQU >37F4           ; Number of words to copy.
GPU_MAIN_PC     EQU >4000           ; Beginning of GPU-local code image.
GPU_LOCAL_LIMIT EQU >4800           ; F18A private GRAM is 2K: >4000..>47FF. Just above VDP VRAM.
GPU_CHUNK       EQU >0600           ; Staging size in bytes.

message:
        TEXT "DDT'S MANDELBROT",>0D
        TEXT "F18A 2026-08-25",>0D
        TEXT "GPU RENDERING",>00
        EVEN

; ============================================================================
; CPU STARTUP / UI
; ============================================================================

START:
        LIMI 0
        LWPI WRKSP

        ; Unlock F18A enhanced registers.
        LI   R0,>391C
        BL   @VWTR
        BL   @VWTR

        ; Detect the GPU with a tiny program in ordinary VRAM.
        LI   R0,>3F00
        LI   R1,gpu_test_image
        LI   R2,GPU_TEST_SIZE
        BL   @VMBW

        LI   R0,>363F               ; VR54 = GPU PC MSB = >3F
        BL   @VWTR
        LI   R0,>3700               ; VR55 = GPU PC LSB = >00; reset/start GPU
        BL   @VWTR
        BL   @gpu_wait_idle_boot

        LI   R0,>3F00
        BL   @VRAD
        MOVB @VDPRD,R0
        JEQ  F18A_detected

F18A_missing:
        ; This program is intentionally F18A-only. Make failure visible and stop.
        LI   R0,>0160               ; VR1: display on, no VBlank IRQ.
        BL   @VWTR
        LI   R0,>0766               ; Red foreground/backdrop (using standard VDP palette).
        BL   @VWTR
        LIMI 0
        ; TODO: Print verbose error message.
        JMP  F18A_missing

F18A_detected:
        BL   @setup_F18A
        CLR  @param_visible         ; No parameter indicator until a value is changed.

        ; Install VBlank IRQ (used for frame timing and UI delays only).
        LIMI 0
        LI   R0,vb_IRQ
        MOV  R0,@>83C4
        LI   R0,>8000
        SOC  R0,@>83C2
        LIMI IRQMASK

        BL   @install_gpu_image

        ; Welcome screen is already using F18A fat-pixel framebuffer.
        BL   @clear_F18A_fatpixels
        CLR  R0
        CLR  R1
        LI   R2,message
        LI   R3,>9100               ; Palette 9 = white, palette 1 = black.
        BL   @print_str
        LI   R0,120
        BL   @delay_frames

        ; Default logical low-resolution view.
        LI   R0,-2*4096
        MOV  R0,@ui_ax
        LI   R0,6000
        MOV  R0,@ui_ay
        LI   R0,512
        MOV  R0,@ui_inc
        LI   R0,16
        MOV  R0,@ui_max_iter

start_render:
        MOV  @frame_cnt,@frame_cnt_start
        CLR  @render_phase
        CLR  R0                      ; Job 0 = low-resolution pass.
        BL   @launch_gpu_job

render_wait:
        BL   @read_input
        LI   R2,>000F
        CZC  R2,R4
        JNE  handle_input

        BL   @gpu_busy
        MOV  R0,R0
        JNE  render_wait

        ; Current GPU job completed.
        MOV  @render_phase,R0
        JNE  render_complete

        ; LR is complete. Redraw any live parameter on the UI before starting HR.
        ; Since HR renders top-to-bottom, we choose the bottom-right corner to show the param as longer as possible.
        BL   @draw_param_value
        LI   R0,1
        MOV  R0,@render_phase
        BL   @launch_gpu_job
        JMP  render_wait

render_complete:
        ; Hi-res rendering completed.
        ; Print elapsed frames as four hex digits in the upper-right corner.
        LI   R0,12                   ; 16-column fat-pixel text grid: columns 12..15.
        CLR  R1                      ; first text row.
        LI   R3,>9100                ; white foreground, black background.
        MOV  @frame_cnt,R2
        S    @frame_cnt_start,R2
        BL   @print_hex

        ; Don't show the two-digit parameter on UI (we want only elapsed frames).
        CLR  @param_visible

idle_ui_loop:
        BL   @read_input
        LI   R2,>000F
        CZC  R2,R4
        JNE  handle_input
        JMP  idle_ui_loop

; R4 = User input [xxxFLRDU].
handle_input:
        ; If a render is running, ask the GPU to abort.
        BL   @abort_gpu_job

        LI   R2,>0010
        COC  R2,R4
        JEQ  input_fire

        ; No FIRE: pan one logical LR pixel.
        LI   R2,>0001               ; UP
        COC  R2,R4
        JNE  HI_NO_UP
        A    @ui_inc,@ui_ay
        JMP  HI_VERT_DONE
HI_NO_UP:
        LI   R2,>0002               ; DOWN
        COC  R2,R4
        JNE  HI_VERT_DONE
        S    @ui_inc,@ui_ay
HI_VERT_DONE:
        LI   R2,>0008               ; LEFT
        COC  R2,R4
        JNE  HI_NO_LEFT
        S    @ui_inc,@ui_ax
        JMP  HI_HORZ_DONE
HI_NO_LEFT:
        LI   R2,>0004               ; RIGHT
        COC  R2,R4
        JNE  HI_HORZ_DONE
        A    @ui_inc,@ui_ax
HI_HORZ_DONE:
        LI   R0,10
        BL   @delay_frames
        JMP  start_render

input_fire:
        ; FIRE+UP = zoom in.
        LI   R2,>0001
        COC  R2,R4
        JNE  IF_NOT_ZOOM_IN
        MOV  @ui_inc,R2
        CI   R2,8
        JLE  IF_SHOW_ZOOM_IN
        SRA  R2,1
        BL   @calc_zoom
IF_SHOW_ZOOM_IN:
        MOV  @ui_inc,R2
        SRA  R2,2                   ; Scale for 2-digit display of zoom depth.
        BL   @show_param_value
        JMP  IF_DONE

IF_NOT_ZOOM_IN:
        ; FIRE+DOWN = zoom out.
        LI   R2,>0002
        COC  R2,R4
        JNE  IF_NOT_ZOOM_OUT
        MOV  @ui_inc,R2
        CI   R2,512
        JHE  IF_SHOW_ZOOM_OUT
        SLA  R2,1
        BL   @calc_zoom
IF_SHOW_ZOOM_OUT:
        MOV  @ui_inc,R2
        SRA  R2,2                   ; Scale for 2-digit display of zoom depth.
        BL   @show_param_value
        JMP  IF_DONE

IF_NOT_ZOOM_OUT:
        ; FIRE+LEFT = max iterations--.
        LI   R2,>0008
        COC  R2,R4
        JNE  IF_NOT_ITER_DOWN
        MOV  @ui_max_iter,R2
        CI   R2,1
        JLE  IF_SHOW_ITER_DOWN
        DEC  R2
        MOV  R2,@ui_max_iter
IF_SHOW_ITER_DOWN:
        MOV  @ui_max_iter,R2
        BL   @show_param_value
        JMP  IF_DONE

IF_NOT_ITER_DOWN:
        ; FIRE+RIGHT = max iterations++.
        LI   R2,>0004
        COC  R2,R4
        JNE  IF_DONE
        MOV  @ui_max_iter,R2
        CI   R2,511
        JHE  IF_SHOW_ITER_UP
        INC  R2
        MOV  R2,@ui_max_iter
IF_SHOW_ITER_UP:
        MOV  @ui_max_iter,R2
        BL   @show_param_value

IF_DONE:
        LI   R0,6
        BL   @delay_frames
        B    @start_render


; Remember and show the current zoom increment or max-iteration value as two hex digits.
; Position is the bottom-right two cells of the 16x24 fat-pixel text grid.
; Inputs:
;   R2=value. We use the low byte only (two-digits param display).
show_param_value:
        MOV  R2,@param_value
        SETO @param_visible


; Redraw the remembered parameter value if one has been selected by the UI.
; We draw it directly from the key handler and once after the LR pass.
draw_param_value:
        MOV  R11,@show_param_ret
        MOV  @param_visible,R2
        JEQ  DPV_DONE
        LI   R0,14
        LI   R1,23
        MOV  @param_value,R2
        LI   R3,>9100               ; White foreground, Black background.
        BL   @print_hex_byte
DPV_DONE:
        MOV  @show_param_ret,R11
        B    *R11


; Keep the screen center fixed when changing the LR increment.
; Inputs:
;   R2 = New increment.
calc_zoom:
        MOV  R2,R0
        S    @ui_inc,R0
        SLA  R0,4                   ; 32 columns / 2 = 16.
        S    R0,@ui_ax

        MOV  R2,R0
        S    @ui_inc,R0
        SLA  R0,2
        MOV  R0,R1
        SLA  R1,1
        A    R0,R1                  ; 24 rows / 2 = 12.
        A    R1,@ui_ay

        MOV  R2,@ui_inc
        B    *R11


; ------------------- READ USER INPUT -------------------
; Outputs:
;   R4 bits [xxxFLRDU], 1 = pressed.
; Clobbered: R2,R12
read_input:
        CLR  R4
        LI   R12,>0024

        ; Column 0: SHIFT is FIRE.
        CLR  R2
        LDCR R2,3
        TB   -10
        JEQ  RI_NOT_SHIFT
        ORI  R4,>0010
RI_NOT_SHIFT:
        ; Column 1: X=down, S=left.
        LI   R2,>0100
        LDCR R2,3
        TB   -8
        JEQ  RI_NOT_X
        ORI  R4,>0002
RI_NOT_X:
        TB   -10
        JEQ  RI_NOT_S
        ORI  R4,>0008
RI_NOT_S:
        ; Column 2: E=up, D=right.
        LI   R2,>0200
        LDCR R2,3
        TB   -9
        JEQ  RI_NOT_E
        ORI  R4,>0001
RI_NOT_E:
        TB   -10
        JEQ  RI_NOT_D
        ORI  R4,>0004
RI_NOT_D:
        B    *R11



; ============================================================================
; F18A SETUP / GPU CONTROL
; ============================================================================

setup_F18A:
        MOV  R11,R10

        ; Basic display on, VBlank IRQ enabled. No Graphics-II tables are used.
        LI   R0,>0000               ; VR0 = 0
        BL   @VWTR
        LI   R0,>01E0               ; VR1 = >E0: 16K, display, VBlank IRQ
        BL   @VWTR
        LI   R0,>0711               ; VR7 = black foreground/backdrop
        BL   @VWTR

        ; First 16 programmable colors.
        LI   R0,>2FC0               ; VR47: palette DPM, auto-inc, PR0.
        BL   @VWTR
        LI   R0,palette_F18A
        LI   R2,32
sf_palette_loop:
        MOVB *R0+,@VDPWD
        DEC  R2
        JNE  sf_palette_loop
        LI   R0,>2F00
        BL   @VWTR

        ; No sprites.
        ; F18A VR51=0 restores the hardware sprite-limit setting; it does not disable sprite rendering.
        ; Put the sprite attribute table outside the framebuffer and terminate the list immediately with the standard >D0 Y value.
        LI   R0,>056D               ; VR5 = >6D -> sprite attribute table at >3680.
        BL   @VWTR
        LI   R0,SPR_ATTR_BASE
        BL   @VWAD
        LI   R0,>D000
        MOVB R0,@VDPWD              ; Sprite 0 Y=>D0: end of sprite list.

        ; Bitmap layer: 128x192 logical fat pixels, 16 colors, framebuffer >0000.
        LI   R0,>1FF0               ; Bitmap layer control: enabled, fat-pixel 4-bpp.
        BL   @VWTR
        LI   R0,>2000               ; Framebuffer base = >0000.
        BL   @VWTR
        LI   R0,>2100               ; X = 0.
        BL   @VWTR
        LI   R0,>2200               ; Y = 0.
        BL   @VWTR
        LI   R0,>2300               ; Width = 256 physical = 128 fat pixels.
        BL   @VWTR
        LI   R0,>24C0               ; Height = 192.
        BL   @VWTR
        LI   R0,>3208               ; Disable tile layer while bitmap layer is active.
        BL   @VWTR

        MOV  R10,R11
        B    *R11


; Install the XORG >4000 GPU image into GPU-local RAM.
; The host VDP port addresses ordinary VRAM only, so our bootstrap at >3E00 copies chunks from staging VRAM >3800 into GPU-local memory.
install_gpu_image:
        MOV  R11,@tmp_ret

        ; Install loader bootstrap into ordinary VRAM.
        LI   R0,GPU_LOADER_PC
        LI   R1,gpu_loader_image
        LI   R2,GPU_LOADER_SIZE
        BL   @VMBW

        LI   R4,gpu_image           ; Physical CPU address of XORG image bytes.
        LI   R5,GPU_MAIN_PC         ; GPU-local destination.
        LI   R6,GPU_IMAGE_SIZE      ; Bytes remaining.

igi_next_chunk:
        MOV  R6,R7
        CI   R7,GPU_CHUNK
        JLE  igi_chunk_ready
        LI   R7,GPU_CHUNK
igi_chunk_ready:
        ; CPU RAM -> staging VRAM.
        LI   R0,GPU_LOAD_SRC
        MOV  R4,R1
        MOV  R7,R2
        BL   @VMBW
        MOV  R1,R4                  ; VMBW leaves R1 advanced by byte count.

        ; Loader parameters.
        LI   R0,GPU_LDR_SRC
        BL   @VWAD

        LI   R0,GPU_LOAD_SRC
        MOVB R0,@VDPWD
        SWPB R0
        MOVB R0,@VDPWD

        MOV  R5,R0
        MOVB R0,@VDPWD
        SWPB R0
        MOVB R0,@VDPWD

        MOV  R7,R0
        SRL  R0,1                   ; bytes -> words.
        MOVB R0,@VDPWD
        SWPB R0
        MOVB R0,@VDPWD

        ; Run loader bootstrap at >3E00.
        LI   R0,>363E
        BL   @VWTR
        LI   R0,>3700
        BL   @VWTR
        BL   @gpu_wait_idle

        A    R7,R5
        S    R7,R6
        JNE  igi_next_chunk

        MOV  @tmp_ret,R11
        B    *R11

; Launch R0 job: 0=LR, 1=HR.
launch_gpu_job:
        MOV  R11,@tmp_ret
        MOV  R0,@tmp0

        ; Stream complete shared control block in one sequential write.
        LI   R0,GPU_ABORT_FLAG
        BL   @VWAD

        CLR  R1                      ; abort = 0
        MOVB R1,@VDPWD
        MOVB R1,@VDPWD

        MOV  @tmp0,R1                ; job
        MOVB R1,@VDPWD
        SWPB R1
        MOVB R1,@VDPWD

        MOV  @ui_ax,R1
        MOVB R1,@VDPWD
        SWPB R1
        MOVB R1,@VDPWD

        MOV  @ui_ay,R1
        MOVB R1,@VDPWD
        SWPB R1
        MOVB R1,@VDPWD

        MOV  @ui_inc,R1
        MOVB R1,@VDPWD
        SWPB R1
        MOVB R1,@VDPWD

        MOV  @ui_max_iter,R1
        MOVB R1,@VDPWD
        SWPB R1
        MOVB R1,@VDPWD

        ; Reset/load PC and start the main GPU program at >4000.
        LI   R0,>3640
        BL   @VWTR
        LI   R0,>3700
        BL   @VWTR

        ; VR55 starts the GPU, but the ST status bit need not become visible immediately.
        ; Do not let render_wait interpret that short interval as job completion (this could leave the first screen at LR resolution).
lgj_wait_started:
        BL   @gpu_busy
        MOV  R0,R0
        JEQ  lgj_wait_started

        MOV  @tmp_ret,R11
        B    *R11


; Ask GPU to stop, then wait until GPU IDLE.
abort_gpu_job:
        MOV  R11,@tmp_ret
        LI   R0,GPU_ABORT_FLAG
        BL   @VWAD
        SETO R1
        MOVB R1,@VDPWD
        SWPB R1
        MOVB R1,@VDPWD
        BL   @gpu_wait_idle
        MOV  @tmp_ret,R11
        B    *R11


; Startup-only GPU wait.
; CPU interrupts remain disabled throughout, because the custom VBlank hook is not installed yet during F18A detection.
gpu_wait_idle_boot:
        LIMI 0
gwib_wait:
        LI   R12,VDPWA
        LI   R1,>0200               ; select status register 2.
        MOVB R1,*R12
        LI   R1,>8F00
        MOVB R1,*R12
        MOVB @VDPST,R0
        ANDI R0,>8000               ; SR2 bit7 = GPU ST.

        CLR  R1                     ; restore status register 0 selection.
        MOVB R1,*R12
        LI   R1,>8F00
        MOVB R1,*R12
        MOV  R0,R0
        JNE  gwib_wait
        B    *R11

; Return:
;   R0 = 0 if GPU idle; != 0 if GPU running.
; Clobbered: R0,R1,R12.
gpu_busy:
        LIMI 0
        LI   R12,VDPWA
        LI   R1,>0200               ; Select Status Register 2.
        MOVB R1,*R12
        LI   R1,>8F00
        MOVB R1,*R12
        MOVB @VDPST,R0
        ANDI R0,>8000               ; SR2 bit7 = GPU ST.

        CLR  R1                     ; Select Status Register 0.
        MOVB R1,*R12
        LI   R1,>8F00
        MOVB R1,*R12
        LIMI IRQMASK
        B    *R11

gpu_wait_idle:
        MOV  R11,R10
gwi_wait:
        BL   @gpu_busy
        MOV  R0,R0
        JNE  gwi_wait
        MOV  R10,R11
        B    *R11


; ============================================================================
; FAT-PIXEL TEXT / DISPLAY HELPERS (CPU)
; ============================================================================

clear_F18A_fatpixels:
        MOV  R11,R10
        LIMI 0
        LI   R0,FP_FB_BASE
        BL   @VWAD
        LI   R1,FP_FB_SIZE
        LI   R0,>1100               ; two black (palette 1) pixels per byte.
cfp_clear_loop:
        MOVB R0,@VDPWD
        DEC  R1
        JNE  cfp_clear_loop
        LIMI IRQMASK
        MOV  R10,R11
        B    *R11


; Print string in fat-pixels mode.
; Each text row is exactly 8 framebuffer scanlines high.
;
; Inputs:
;   R0 = x [0..15].
;   R1 = text row [0..23].
;   R2 = 0-terminated string.
;   R3 = FB colors.
;
print_str:
        MOV  R11,@tmp_ret
        MOV  R2,R6
ps_next:
        CLR  R2
        MOVB *R6+,R2
        SWPB R2
        JEQ  ps_done
        CI   R2,>000D
        JNE  ps_char
        CLR  R0
        INC  R1                      ; next text row = +8 framebuffer scanlines.
        JMP  ps_next
ps_char:
        MOV  R0,R4
        MOV  R1,R5
        BL   @print_char
        MOV  R4,R0
        INC  R0
        MOV  R5,R1
        JMP  ps_next
ps_done:
        MOV  @tmp_ret,R11
        B    *R11


GROM_FONT_BASE EQU >06B4

; Print a char in fat-pixels mode.
; Draw one console-GROM character directly into the F18A fat-pixel framebuffer.
; The console glyph supplies 7 scanlines; scanline 8 is empty.
;
; Inputs:
;   R0 = x [0..15].
;   R1 = text row.
;   R2 = ASCII code.
;   R3 = %ffffbbbb00000000.
;
; Clobbered: none.
;
print_char:
        MOV  R11,@print_char_ret
        MOV  R0,@tmp0
        MOV  R1,@tmp1
        MOV  R2,@tmp2
        MOV  R4,@tmp3
        MOV  R5,@tmp4
        MOV  R6,@tmp5
        MOV  R7,@tmp6

        ; GROM glyph address = >06B4 + (ASCII-32)*7.
        AI   R2,-32
        MOV  R2,R1
        SLA  R2,3
        S    R1,R2
        LI   R0,GROM_FONT_BASE
        A    R2,R0
        MOVB R0,@GRMWA
        SWPB R0
        MOVB R0,@GRMWA

        ; Destination = y*8*64 + x*4.
        MOV  @tmp1,R4
        SLA  R4,9
        MOV  @tmp0,R0
        SLA  R0,2
        A    R0,R4

        MOV  R3,R5
        SRL  R5,12                  ; foreground nibble.
        MOV  R3,R6
        SRL  R6,8
        ANDI R6,>000F               ; background nibble.

        LIMI 0
        LI   R7,7
pc_row:
        MOV  R4,R0
        BL   @VWAD
        MOVB @GRMRD,R1
        LI   R0,4
pc_pair:
        CLR  R2
        SLA  R1,1
        JNC  pc_first_bg
        MOV  R5,R2
        JMP  pc_first_done
pc_first_bg:
        MOV  R6,R2
pc_first_done:
        SLA  R2,4
        SLA  R1,1
        JNC  pc_second_bg
        SOC  R5,R2
        JMP  pc_packed
pc_second_bg:
        SOC  R6,R2
pc_packed:
        SWPB R2
        MOVB R2,@VDPWD
        DEC  R0
        JNE  pc_pair
        AI   R4,64
        DEC  R7
        JNE  pc_row

        ; Explicit blank/background eighth scanline.
        MOV  R4,R0
        BL   @VWAD
        MOV  R6,R2
        SLA  R2,4
        SOC  R6,R2                   ; R2 low byte = >bb.
        SWPB R2
        MOVB R2,@VDPWD
        MOVB R2,@VDPWD
        MOVB R2,@VDPWD
        MOVB R2,@VDPWD
        LIMI IRQMASK

        MOV  @tmp3,R4
        MOV  @tmp4,R5
        MOV  @tmp5,R6
        MOV  @tmp6,R7
        MOV  @tmp0,R0
        MOV  @tmp1,R1
        MOV  @tmp2,R2
        MOV  @print_char_ret,R11
        B    *R11


; Print the low byte of a value as two hexadecimal characters.
;
; Inputs:
;   R0 = x [0..14].
;   R1 = text row.
;   R2 = value.
;   R3 = FB colors.
; Outputs:
;   R0 = x+2;
;   R1/R2 unchanged.
; Clobbered: R12.
;
print_hex_byte:
        MOV  R11,@tmp_ret
        MOV  R2,R12

        SRL  R2,4
        ANDI R2,>000F
        BL   @hex_nibble_ascii
        BL   @print_char

        INC  R0
        MOV  R12,R2
        ANDI R2,>000F
        BL   @hex_nibble_ascii
        BL   @print_char

        INC  R0
        MOV  R12,R2
        MOV  @tmp_ret,R11
        B    *R11


; Print a 16-bit value as four hexadecimal characters.
;
; Inputs:
;   R0 = x [0..15].
;   R1 = text row.
;   R2 = value.
;   R3 = FB colors.
; Outputs:
;   R0 = x+4;
;   R1/R2 unchanged.
; Clobbered: R12.
;
print_hex:
        MOV  R11,@tmp_ret
        MOV  R2,R12

        SWPB R2
        SRL  R2,4
        ANDI R2,>000F
        BL   @hex_nibble_ascii
        BL   @print_char

        INC  R0
        MOV  R12,R2
        SWPB R2
        ANDI R2,>000F
        BL   @hex_nibble_ascii
        BL   @print_char

        INC  R0
        MOV  R12,R2
        SRL  R2,4
        ANDI R2,>000F
        BL   @hex_nibble_ascii
        BL   @print_char

        INC  R0
        MOV  R12,R2
        ANDI R2,>000F
        BL   @hex_nibble_ascii
        BL   @print_char

        INC  R0
        MOV  R12,R2
        MOV  @tmp_ret,R11
        B    *R11



; Input/output R2: nibble 0..15 -> ASCII '0'..'9','A'..'F'.
hex_nibble_ascii:
        CI   R2,>000A
        JHE  hna_alpha
        AI   R2,'0'
        B    *R11
hna_alpha:
        AI   R2,'A'-10
        B    *R11


; ============================================================================
; TIMING / VDP UTILITIES
; ============================================================================

delay_frames:
        A    @frame_cnt,R0
DF_WAIT:
        C    @frame_cnt,R0
        JNE  DF_WAIT
        B    *R11

vb_IRQ:
        CB   @VDPST,R0
        INC  @frame_cnt
        SETO @>83D6
        B    *R11


; VDP multiple byte write.
; Inputs:
;   R0 = VDP destination.
;   R1 = CPU source.
;   R2 = byte count.
VMBW:
        MOVB @R0LB,@VDPWA
        ORI  R0,>4000
        MOVB R0,@VDPWA
VMBW_LOOP:
        MOVB *R1+,@VDPWD
        DEC  R2
        JNE  VMBW_LOOP
        ANDI R0,>3FFF
        B    *R11

; R0: MSB=VDP register, LSB=value.
VWTR:
        MOVB @R0LB,@VDPWA
        ORI  R0,>8000
        MOVB R0,@VDPWA
        ANDI R0,>3FFF
        B    *R11

; R0 = VDP write address.
VWAD:
        MOVB @R0LB,@VDPWA
        ORI  R0,>4000
        MOVB R0,@VDPWA
        ANDI R0,>3FFF
        B    *R11

; R0 = VDP read address.
VRAD:
        MOVB @R0LB,@VDPWA
        ANDI R0,>3FFF
        MOVB R0,@VDPWA
        B    *R11


; ============================================================================
; CPU VARIABLES in DRAM
; ============================================================================

ui_ax:          BSS 2              ; Q4.12 LR upper-left X.
ui_ay:          BSS 2              ; Q4.12 LR upper-left Y.
ui_inc:         BSS 2              ; Q4.12 LR increment [512..8].
ui_max_iter:    BSS 2
render_phase:   BSS 2
frame_cnt:      BSS 2
frame_cnt_start: BSS 2
param_value:    BSS 2
param_visible:  BSS 2

tmp_ret:        BSS 2
show_param_ret: BSS 2
print_char_ret: BSS 2
tmp0:           BSS 2
tmp1:           BSS 2
tmp2:           BSS 2
tmp3:           BSS 2
tmp4:           BSS 2
tmp5:           BSS 2
tmp6:           BSS 2


; F18A palette used by CPU during initialization.
palette_F18A:
        DATA >0000  ; 0 transparent / unused
        DATA >0000  ; 1 black
        DATA >0439  ; 2
        DATA >054B  ; 3
        DATA >056C  ; 4
        DATA >057D  ; 5
        DATA >059F  ; 6
        DATA >06AF  ; 7
        DATA >0CDF  ; 8
        DATA >0FFF  ; 9 white
        DATA >0FE9  ; A
        DATA >0FC4  ; B
        DATA >0FA0  ; C
        DATA >0F80  ; D
        DATA >0D60  ; E
        DATA >0A30  ; F


; GPU detection code (run by GPU), copied to >3F00 in VRAM.
; If it executes, it clears its first word; without a GPU the copied opcode remains nonzero.
gpu_test_image:
        CLR  @>3F00
        IDLE
GPU_TEST_SIZE EQU $-gpu_test_image


; ============================================================================
; GPU LOADER BOOTSTRAP - executes from ordinary VRAM >3E00.
; Label on XORG is the physical CPU address of these bytes; labels after XORG
; use their GPU execution addresses.
; ============================================================================

gpu_loader_image XORG >3E00

gpu_loader_entry:
        MOV  @GPU_LDR_SRC,R0
        MOV  @GPU_LDR_DST,R1
        MOV  @GPU_LDR_WORDS,R2
gpu_ldr_loop:
        MOV  *R0+,*R1+
        DEC  R2
        JNE  gpu_ldr_loop
        IDLE

GPU_LOADER_SIZE EQU $->3E00


; ============================================================================
; F18A GPU MANDELBROT IMAGE - XORG >4000, copied to GPU-local RAM.
;
; All Mandel working state is either in GPU registers, GPU-local variables, the shared job input block in VRAM, or the LR iteration buffer in VRAM.
; The CPU is not involved in Mandel calculations.
; ============================================================================

gpu_image XORG >4000
gpu_main:
        ; Snapshot shared inputs into GPU-local state.
        ; CPU/UI and GPU coordinates are all native Q4.12, so no launch-time fixed-point conversion is required.
        MOV  @GPU_AX,@g_ax
        MOV  @GPU_AY,@g_ay
        MOV  @GPU_INC,@g_inc
        MOV  @GPU_MAXITER,@g_max_iter

        MOV  @GPU_JOB,R0
        JNE  gpu_high_pass
        B    @gpu_low_pass


; ------------------- GPU LOW-RES PASS: logical 32x24 -------------------
; Every low-res point is stored as a word in >3000..>35FF and immediately rendered as one 4x8 block of F18A fat pixels.
gpu_low_pass:
        LI   R12,GPU_LR_BUF          ; Iteration output pointer.
        MOV  @g_ay,R14               ; Cur CY.
        CLR  @g_fbptr
        LI   R0,24
        MOV  R0,@g_rowcnt

glr_row:
        MOV  @g_ax,R13               ; Cur CX.
        LI   R15,32

glr_pixel:
        MOV  R13,R4
        MOV  R14,R5
        BL   @gpu_calc_color         ; R9 = iters, R2 = color; R12..R15 preserved.
        MOV  R9,*R12+

        ; One color nibble -> >CCCC, i.e. four 4-bpp fat pixels in one word.
        MOV  R2,R3
        SLA  R3,4
        SOC  R2,R3                   ; R3 low byte = >CC.
        MOV  R3,R1
        SWPB R1
        SOC  R1,R3                   ; R3 = >CCCC.

        ; Fill 4x8 destination block with eight word writes, one per scanline.
        MOV  @g_fbptr,R0
        LI   R1,8
glr_fill:
        MOV  R3,*R0
        AI   R0,64
        DEC  R1
        JNE  glr_fill

        INCT @g_fbptr                ; next 4-pixel LR cell = 2 framebuffer bytes.
        A    @g_inc,R13

        MOV  @GPU_ABORT_FLAG,R0
        JEQ  glr_not_aborted
        B    @gpu_abort_exit
glr_not_aborted:
        DEC  R15
        JNE  glr_pixel

        ; g_fbptr is now at the next scanline; move down seven more lines.
        LI   R0,448                  ; 7 * 64.
        A    R0,@g_fbptr
        S    @g_inc,R14
        DEC  @g_rowcnt
        JNE  glr_row

        IDLE



; ------------------- GPU HIGH-RES PASS: 128x192 fat pixels -------------------
; The low-res buffer is used for the same neighbor-based tile skip optimization.
; Non-skipped LR cells are refined as 4x8 independent fat pixels.
gpu_high_pass:
        ; HR X increment = LR inc / 4; HR Y increment = LR inc / 8.
        MOV  @g_inc,R0
        MOV  R0,R1
        SRA  R1,2
        MOV  R1,@g_hrincx
        MOV  R0,R1
        SRA  R1,3
        MOV  R1,@g_hrincy

        ; First HR tile is centered on LR(0,0): x starts LRinc/2 left,
        ; y starts LRinc/2 above, matching the previous renderer's grid.
        MOV  @g_inc,R1
        SRA  R1,1
        MOV  @g_ax,R0
        S    R1,R0
        MOV  R0,@g_hx0
        MOV  R0,@g_tilecx

        MOV  @g_ay,R0
        A    R1,R0
        MOV  R0,@g_tilecy

        CLR  @g_tilex
        CLR  @g_tiley
        LI   R0,GPU_LR_BUF
        MOV  R0,@g_lrptr
        CLR  @g_tilefb

GHR_TILE:
        ; Border tiles are always refined.
        MOV  @g_tilex,R0
        JEQ  ghr_render_tile
        CI   R0,31
        JEQ  ghr_render_tile
        MOV  @g_tiley,R0
        JEQ  ghr_render_tile
        CI   R0,23
        JEQ  ghr_render_tile

        ; Interior tile: skip only if all eight LR neighbors have same iters.
        MOV  @g_lrptr,R1
        MOV  *R1,R0
        C    R0,@-2(R1)              ; W
        JNE  ghr_render_tile
        C    R0,@2(R1)               ; E
        JNE  ghr_render_tile
        C    R0,@-66(R1)             ; NW
        JNE  ghr_render_tile
        C    R0,@-64(R1)             ; N
        JNE  ghr_render_tile
        C    R0,@-62(R1)             ; NE
        JNE  ghr_render_tile
        C    R0,@66(R1)              ; SE
        JNE  ghr_render_tile
        C    R0,@64(R1)              ; S
        JNE  ghr_render_tile
        C    R0,@62(R1)              ; SW
        JEQ  ghr_tile_done

ghr_render_tile:
        MOV  @g_tilefb,R12           ; framebuffer word address for first row.
        MOV  @g_tilecy,R14
        LI   R15,8

ghr_row:
        MOV  @g_tilecx,R13
        CLR  @g_pack
        LI   R0,4
        MOV  R0,@g_pxcnt

ghr_pixel:
        MOV  R13,R4
        MOV  R14,R5
        BL   @gpu_calc_color

        MOV  @GPU_ABORT_FLAG,R0
        JEQ  ghr_not_aborted
        B    @gpu_abort_exit
ghr_not_aborted:

        MOV  @g_pack,R0
        SLA  R0,4
        SOC  R2,R0
        MOV  R0,@g_pack
        A    @g_hrincx,R13
        DEC  @g_pxcnt
        JNE  ghr_pixel

        MOV  @g_pack,*R12
        AI   R12,64
        S    @g_hrincy,R14
        DEC  R15
        JNE  ghr_row

ghr_tile_done:
        INCT @g_lrptr
        INCT @g_tilefb
        INC  @g_tilex
        MOV  @g_inc,R0
        A    R0,@g_tilecx

        MOV  @g_tilex,R0
        CI   R0,32
        JNE  ghr_tile

        ; Next LR tile row.
        CLR  @g_tilex
        INC  @g_tiley
        MOV  @g_hx0,@g_tilecx
        MOV  @g_inc,R0
        S    R0,@g_tilecy
        LI   R0,448                  ; row base: +512 total, already +64 from 32 tiles.
        A    R0,@g_tilefb

        MOV  @g_tiley,R0
        CI   R0,24
        JNE  ghr_tile

        IDLE

gpu_abort_exit:
        IDLE


; ------------------- GPU MANDELBROT POINT + COLOR -------------------
; This is the optimized Q4.12 iteration core from mandel99.
; Keep both squares as full unsigned Q8.24 products until after the escape test, so the radius check is exact at the available fixed-point precision.
; The |zx|/|zy| magnitudes are then reused for the cross product, and the loop counts remaining iterations down to zero to shorten the common tail.
;
; Inputs:
;   R4 = cx (Q4.12).
;   R5 = cy (Q4.12).
; Uses: g_max_iter.
; Outputs:
;   R9 = iterations.
;   R2 = Palette index [1..15].
; Clobbered: R0..R11, preserves R12..R15.
;
gpu_calc_color:
        MOV  R11,@g_calc_ret            ; Free R11 as a temporary inside loop.
        CLR  R6                         ; stored z^2 real term (without c), Q4.12.
        CLR  R7                         ; stored z^2 imaginary term (without c), Q4.12.
        MOV  @g_max_iter,R9             ; iterations remaining.

gcc_iter:
        ; Reconstruct current z from the stored z^2 terms.
        A    R4,R6                      ; zx += cx
        A    R5,R7                      ; zy += cy

        ; Save the cross-product sign, then retain magnitudes in R6/R7 so
        ; they can be reused by the third MPY after the square test.
        MOV  R6,R8
        XOR  R7,R8                      ; bit15 set iff zx and zy signs differ.
        ABS  R6
        ABS  R7

        ; Full Q8.24 squares.  Do not reduce them before the bailout test.
        MOV  R6,R0
        MPY  R6,R0                      ; R0:R1 = zx*zx
        MOV  R7,R2
        MPY  R7,R2                      ; R2:R3 = zy*zy

        ; Exact fixed-point bailout: zx^2 + zy^2 >= 4.0.
        ; 4.0 in Q8.24 is >04000000, so comparing the summed high word
        ; against >0400 is sufficient after propagating the low-word carry.
        MOV  R0,R11
        MOV  R1,R10
        A    R3,R10
        JNC  gcc_no_sq_carry
        INC  R11
gcc_no_sq_carry:
        A    R2,R11
        CI   R11,>0400
        JHE  gcc_done

        ; Inside the radius-2 circle each square is <4 and can now be safely
        ; converted Q8.24 -> Q4.12: (HI << 4) | (LO >> 12).
        SLA  R0,4
        SRL  R1,12
        SOC  R1,R0                      ; R0 = zx^2, Q4.12

        SLA  R2,4
        SRL  R3,12
        SOC  R3,R2                      ; R2 = zy^2, Q4.12

        ; Save the next real part while the old |zx|/|zy| magnitudes are
        ; still available for the cross product.
        S    R2,R0
        MOV  R0,R10                     ; next zx = zx^2 - zy^2

        ; Q8.24 -> Q4.12 and *2 in one reduction: shift right 11.
        MOV  R6,R0
        MPY  R7,R0                      ; R0:R1 = |zx*zy|
        SLA  R0,5
        SRL  R1,11
        SOC  R1,R0                      ; |2*zx*zy|, Q4.12
        MOV  R0,R7
        MOV  R10,R6

        ; Duplicate the tiny loop tail so the usual positive-product path
        ; does not pay for an unconditional branch every iteration.
        MOV  R8,R8                      ; Re-establish flags from saved sign.
        JLT  gcc_neg_xy
        DEC  R9
        JNE  gcc_iter
        JMP  gcc_done
gcc_neg_xy:
        NEG  R7
        DEC  R9
        JNE  gcc_iter

gcc_done:
        ; Convert remaining-iteration count to completed iterations.
        MOV  @g_max_iter,R10
        S    R9,R10
        MOV  R10,R9

        ; max_iter maps to black (1).  The custom F18A palette itself is
        ; already arranged as the desired gradient in entries 2..F, so
        ; escaped values map directly to (iterations % 14) + 2.
        C    R9,@g_max_iter
        JNE  gcc_escaped
        LI   R2,1
        JMP  gcc_return

gcc_escaped:
        MOV  R9,R2
        LI   R0,14
        CLR  R1
        DIV  R0,R1                     ; remainder -> R2 [0..13].
        INCT R2                        ; palette index [2..15].

gcc_return:
        MOV  @g_calc_ret,R11
        B    *R11

; GPU-local Mandel working state. Coordinate values are Q4.12.
g_ax:       DATA 0
g_ay:       DATA 0
g_inc:      DATA 0
g_max_iter: DATA 0
g_calc_ret: DATA 0              ; Saved BL return while R11 is a calc temporary.
g_hrincx:   DATA 0
g_hrincy:   DATA 0
g_fbptr:    DATA 0
g_rowcnt:   DATA 0
g_hx0:      DATA 0
g_tilecx:   DATA 0
g_tilecy:   DATA 0
g_tilex:    DATA 0
g_tiley:    DATA 0
g_lrptr:    DATA 0
g_tilefb:   DATA 0
g_pack:     DATA 0
g_pxcnt:    DATA 0

GPU_IMAGE_SIZE EQU $->4000
GPU_IMAGE_END  EQU >4000+GPU_IMAGE_SIZE

; ERROR CHECK: The original F18A exposes 2K of private GPU GRAM at >4000..>47FF.
;              Fail the build rather than silently overflowing.
        .ifgt GPU_IMAGE_END,GPU_LOCAL_LIMIT
        .error 'F18A GPU image exceeds [>4000..>47FF] private GRAM'
        .endif

        END
