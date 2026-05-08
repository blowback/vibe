# VIBE - A minimal *VI* clone for the Micro*BE*ast 

VIBE is a pure z80 assembler for the Feersum MicroBeast, presenting 
just enough of the vi feature set to usefully get some file 
editing done on the native host.

VIBE supports:

 - z80
 - vt52 terminal only (with future vt100 option)
 - cp/m 2.2
 - gap-buffer based editing 


## Initial vi feature set 

 - modes: normal, insert, command (:), visual (line, character, block)
 - motion: h j k l w b 0 $ G gg
 - edit: i a o O x dd dw yy p u (single level undo)
 - command: :w :q :wq :w filename :e filename
 - counts: two stage operator/motion structure with command counts
 - search: /pattern and n (literal, no regex)
 - visual mode commands: d, y, c, >, <, ~ etc

## Tentative size budget

- Gap buffer + cursor logic: 400 bytes
- Screen redraw + VT52 output: 300 bytes
- Keyboard dispatch + mode handling: 250 bytes
- Motion commands: 400 bytes
- Edit commands + undo: 500 bytes
- Ex command line + file I/O via FCB: 600 bytes
- Search: 200 bytes
- Misc (status line, screen state, init): 350 bytes

That's roughly 3 KB, plus the gap buffer itself. Easily fits in a single CP/M .COM file with room to spare.

## Things to avoid

1. whole screen redraws. maintain a "what's currently on screen" buffer and only emit changed lines. 

## Non-functional requirements

- Written entirely in sjasmplus 1.23.0 
- Make-based build system 


