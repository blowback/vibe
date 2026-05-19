# VIBE

A vi-style modal text editor for the Feersum MicroBeast (Z80, CP/M 2.2, 80×24 terminal). Single buffer, single-level undo, ~10 KB. Not a vi clone — see [Vi deviations](#vi-deviations) for what's different.

![VIBE logo](images/vibe_logo3.png)

## Cheatsheet

```
Modes          NORMAL (default) | INSERT (i a o O) | COMMAND (: /) | VISUAL (v V Ctrl-V)
Leave any mode Esc → NORMAL

Motions        h j k l   ← ↓ ↑ →
               w b       next / prev word
               0 $       line start / line end
               gg G      first / last line of buffer
               <count>m  prefix any motion with a count (e.g. 5j, 12G, 3w)

Edits          i a       insert before / after cursor
               o O       open line below / above + insert
               x         delete char under cursor
               dd yy     delete / yank current line
               dw        delete word
               p         paste yanked or deleted text
               u         undo last edit (single level)

Composed       d<motion> y<motion> c<motion>     e.g. dw, d$, y3j, c5w
ops

Visual         v V Ctrl-V          enter character / line / block visual
               d y c               delete / yank / change selection
               > <                 shift selection right / left (one space)
               ~                   toggle case of selection

Search         /pattern Enter      forward literal search
               n                   repeat last search

Ex             :w [filename]       save (current name, or "save as")
               :e filename         open another file
               :wq                 save and quit
               :q                  quit (refuses if buffer modified)
               :q!                 quit, abandoning changes

Display        Ctrl-L              full-screen refresh
```

## Quick start

1. **Launch.** Type `vibe` to open an empty buffer with a welcome screen, or `vibe foo.fs` to open `foo.fs` from drive B:. Bare filenames default to B:; use an explicit drive letter (`vibe a:notes.txt`) for any other drive.
2. **Dismiss the welcome screen.** If you launched with no argument, the welcome banner shows on the editing area. Any keystroke dismisses it — that keystroke is then processed normally.
3. **Type something.** Press `i` to enter INSERT mode, type characters and newlines, then press `Esc` to return to NORMAL.
4. **Save.** Type `:w` (under the current name) or `:w mynote.fs` (under a new name) then press Enter.
5. **Quit.** `:wq` saves and quits in one step, `:q` quits a clean buffer, `:q!` quits and discards unsaved changes.

That's the whole loop. The rest of this README is a reference.

## Modes

Four modes. The current mode decides what each keystroke means. `Esc` from any mode returns to NORMAL.

- **NORMAL** (default) — keys are commands, not input. Motions move the cursor; operators (`d`, `y`, `c`, `<`, `>`) act on text; digits accumulate a count prefix. Status line is empty.
- **INSERT** — text entry. Every key except Backspace / Enter / Esc is inserted literally. Backspace deletes the byte before the cursor; Enter inserts a newline.
- **COMMAND** — modal entry on the status line for ex commands (`:`) or forward search (`/`). Backspace edits; Enter dispatches; Esc cancels.
- **VISUAL** — selection mode. Motions extend the selection; operators (`d`, `y`, `c`, `>`, `<`, `~`) act on it and return to NORMAL.

### Entering modes from NORMAL

| To enter | Key |
|---|---|
| INSERT (before cursor) | `i` |
| INSERT (after cursor) | `a` |
| INSERT (open line below) | `o` |
| INSERT (open line above) | `O` |
| COMMAND (ex prompt) | `:` |
| COMMAND (search prompt) | `/` |
| VISUAL character | `v` |
| VISUAL line | `V` |
| VISUAL block (rectangle) | `Ctrl-V` |

### Status-line messages

What appears on the bottom row of the screen:

| Message | Meaning |
|---|---|
| (empty) | NORMAL, ready for a command |
| `-- insert --` | INSERT mode |
| `-- visual --` / `-- visual line --` / `-- visual block -- RxC` | VISUAL submodes (R rows × C cols for block) |
| `:` or `/` followed by your typed bytes | COMMAND prompt |
| `no write since last change` | `:q` refused — use `:q!` to discard, or `:wq` to save first |
| `file too large` | Tried to load a file over 32 KB |
| `can't read file` | File not found or unreadable |
| `bdos error` | Disk error (write-protect, full disk, etc.) |
| `missing filename` | `:w` or `:e` needed a name and none was supplied |
| `not an editor command` | Unrecognized `:`-command |
| `unbound key` | Key has no meaning in the current mode |
| `pattern not found` | Search miss |
| `search wrapped` | Search reached end-of-buffer and continued from the start |
| `no previous pattern` | `n` pressed with no prior `/` |
| `nothing to undo` | `u` with no recorded edit |
| `undo not possible - too large` | Last edit exceeded the undo buffer |
| `yank too large` | Selection too big to copy |

## Commands

### Motions

| Move | Key |
|---|---|
| Left / right one character | `h` / `l` |
| Down / up one line | `j` / `k` |
| Next / previous word | `w` / `b` |
| Start / end of line | `0` / `$` |
| First / last line of buffer | `gg` / `G` |

Prefix any motion with a count: `5j`, `12G`, `3w`. A leading `0` is the line-start motion; `1`-`9` start a count. So `10w` is "ten words forward".

### Edits

| Action | Key |
|---|---|
| Delete char under cursor | `x` |
| Delete current line | `dd` |
| Delete word forward | `dw` |
| Yank (copy) current line | `yy` |
| Paste yanked or deleted text | `p` |
| Undo last edit (one level) | `u` |

### Composed operators

Operator + motion acts over whatever the motion covers. Operators are `d` (delete), `y` (yank), `c` (change). A count attaches to either side — `2dw` and `d2w` both delete two words forward.

| Example | Effect |
|---|---|
| `dw` | Delete word forward |
| `d$` | Delete to end of line |
| `dgg` | Delete to first line |
| `d5j` | Delete five lines down |
| `y3j` | Yank three lines down |
| `c5w` | Change five words forward |
| `3dd` | Delete the current line three times |

### Visual selection

`v` / `V` / `Ctrl-V` enters VISUAL char / line / block. Motions extend the selection. Then:

| Action | Key |
|---|---|
| Delete selection | `d` |
| Yank selection | `y` |
| Change selection (delete + INSERT) | `c` |
| Shift right / left by one space | `>` / `<` |
| Toggle case | `~` |
| Cancel selection | `Esc` |

Block visual selects a virtual rectangle — short lines inside the rectangle are not padded.

### Search

| Action | Key |
|---|---|
| Forward search | `/pattern` then `Enter` |
| Repeat last search | `n` |
| Cancel the search prompt | `Esc` |

Literal byte-sequence match (no regex). Search wraps from end-of-buffer to start; the wrap is reported in the status line.

### Ex commands

Type `:` then:

| Command | Action |
|---|---|
| `:w` | Save under current filename |
| `:w filename` | Save under a new filename |
| `:wq` | Save and quit |
| `:q` | Quit (refused if buffer modified) |
| `:q!` | Quit, discarding changes |
| `:e filename` | Open another file (replaces current buffer) |

Bare filenames go to drive **B:**. Use an explicit drive prefix (`a:foo.fs`, `c:notes.txt`) for any other drive. Filenames are CP/M 8.3 form.

### Screen

| Action | Key |
|---|---|
| Full-screen refresh | `Ctrl-L` |

VIBE normally redraws only the cells that changed. `Ctrl-L` forces a full repaint if the screen ever desyncs (e.g. line noise on the serial cable).

## Vi deviations

VIBE is vi-spirited but trimmed for a ~10 KB editor on a Z80. The differences worth knowing:

### Not implemented

`.` repeat, `f` / `F` / `t` / `T` char-find, `e` / `ge` word-end, `%` matching-paren, `H` / `M` / `L` viewport motions, `Ctrl-D` / `Ctrl-U` half-page scroll, `r` single-char replace, `R` overwrite mode, `s` / `S` substitute, `cc` change-line, NORMAL-mode `~` (VISUAL `~` works), `m{a-z}` marks, `"{reg}` named registers, `q{a-z}` macro recording, `?pattern` backward search, `:s` / `:g` / `:r` / `:!` and any other `:`-command beyond `:q` / `:q!` / `:w` / `:wq` / `:e`, counted `n` (e.g. `3n`), counted operators on visual selections (e.g. `3d` from VISUAL), multiple buffers, windows, or splits.

### Implemented differently

- **Empty lines past end-of-file** show as blanks, not vi's `~` column.
- **CR, NUL, and high-bit bytes** render as a space. Saves preserve the original bytes — CRLF line endings round-trip intact.
- **Welcome screen** shows on no-argument launch; any first keystroke dismisses it and is then processed normally.
- **File size cap:** 32 KB. Loads over the cap are refused with `file too large`; the current buffer is unchanged.
- **One buffer, one undo level.** No buffer list, no redo.
- **Bare filenames go to drive B:** — use an explicit drive letter for anything else.
- **`$a` on intermediate lines** appends before the line's LF, not past it. Only `a` on the last line at end-of-line appends past end-of-buffer.

## Limits

| Limit | Value |
|---|---|
| Max file size | 32 KB |
| Undo buffer | 256 bytes (single level) |
| Yank register | 1024 bytes |
| Ex command line | 64 bytes |
| Search pattern | 64 bytes |
| Filename | 16 bytes (drive + 8.3) |
| Buffers | 1 |
| Screen | 80 × 24 |

Oversize loads and yanks are refused with a status message; the buffer is left untouched. Save failures (disk full, write-protect) surface a status message and leave the buffer dirty so you can retry.

## Hacking

Building VIBE from source:

```
make            # assemble vibe.com (byte-identical rebuilds)
make test       # run the headless test harness under iz-cpm
make sizes      # print code size against the budget
make clean      # remove build artifacts
make push       # upload to MicroBeast over serial (stubbed)
```

Requires **sjasmplus 1.23.0** (exact version — earlier or later not supported), **GNU Make**, and **iz-cpm** for `make test`.
