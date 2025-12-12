# ssh-user32relay

## Purpose

`ssh-user32relay` executes queued Windows command lines in an interactive
desktop session.\
It exists to bridge non-interactive contexts (for example SSH sessions or
background services) with operations that require an interactive user token and
User32, such as locking the workstation or starting GUI programs.

`ssh-user32relay` comes as two parts, `ssh-user32relay.exe` and `gstart.exe` a
small helper utility to launch applications through the relay by writing to
appropriate `run.txt` – it has a syntax similar to start.

## Functionality Overview

### `ssh-user32relay.exe`

- Monitors command queue files:
  - `%APPDATA%\ssh-user32relay\run.txt` (user queue).
  - `%PROGRAMDATA%\ssh-user32relay\run.txt` (system queue, processed only when
    relay runs elevated).
- Reads each non-empty line, parses a working directory token, and executes
  remaining text as a command line.
- Runs commands:
  - Unelevated, using the interactive user token.
  - Elevated, when processing the system queue under an elevated relay instance.
- Writes activity and errors to log files:
  - `%APPDATA%\ssh-user32relay\run.log`
  - `%PROGRAMDATA%\ssh-user32relay\run.log` (for system queue only)
- Optionally disables logging when started with `--no-log`.
- Truncates `run.txt` after reading or if larger than 1 MiB.

Commands in the user queue are never run elevated, commands in the system queue
are always run elevated.

### `gstart.exe`

- Builds a single launch record from the caller’s arguments:
  - `"<work_dir>" <program> [args...]`
- Selects the destination queue file:
  - User queue when run normally or when `-u` is specified.
  - System queue when `-s` is specified and the process is elevated.
- Appends the record to the chosen file without executing anything.
- Errors on system-mode requests when not elevated.

Why file based IPC? Other viable solutions to this problem would be named-pipes,
a TCP loopback, and Windows RPC/ALPC. File-based IPC was chosen for its
simplicity and the availability provided in various environments (_WSL_.)

## Build

Requirements:

- Zig: `>= 0.15.2`
- Target platform: Windows
- `zigwin32`
- `zig-clap`

Build steps:

```shell
# Fetch Zig package dependencies
zig build --fetch

# Debug build
zig build

# Release-safe build
zig build -Doptimize=ReleaseSafe
```

## Usage `ssh-user32relay.exe`

```
ssh-user32relay.exe [--no-log]
```

Options:

- `--no-log` disables logging to the `run.log` file(s)

## Usage `gstart.exe`

```
gstart [-u|-s] [-d <work_dir>] <program> [args...]
```

Options:

- `-d, --dir` set working directory
- `-u, --user` write to user file (default)
- `-s, --system` write to system file (requires elevation)

## Runtime Layout (Directories, Files, Logs)

- Root1: `%APPDATA%\ssh-user32relay\` (elevated and unelevated)
- Root2: `%PROGRAMDATA%\ssh-user32relay\` (elevated)
- Files:

  - `run.txt` Queue of unelevated commands.
  - `run.log` Log file for scoped events and errors.
- Behavior:

  - Commands are processed and `run.txt` is truncated after processing.
  - File size limit: 1 MiB; larger files are deleted before processing.

## Run File `run.txt`

`ssh-user32relay.exe` processes `run.txt` as a list of commands. Each non-empty
line has the form:

```text
<workdir_token> <command and arguments...>
```

Rules:

- First token is working directory. (Required)

  - Quoted or unquoted: `"C:\path\to\dir"` or `C:\path\to\dir`
  - Empty quoted token (`''` or `""`) uses relay process's current working
    directory.
- Remaining text after the first token is executed as the command line.
  (Required)

Example `run.txt` file contents:

```text
'' notepad.exe
'C:\Users\user1\AppData\Local\Programs\Microsoft VS Code' Code.exe "C:\file.txt"
```

## Example Usage

### `ssh-user32relay.exe`

Directly writing to the `run.txt` file(s) for `ssh-user32relay.exe` to process.

Unelevated behavior test (relay running unelevated):

```powershell
Add-Content "$env:APPDATA\ssh-user32relay\run.txt" "'' rundll32.exe user32.dll,LockWorkStation"
Add-Content "$env:APPDATA\ssh-user32relay\run.txt" "'' notepad.exe"
Add-Content "$env:APPDATA\ssh-user32relay\run.txt" "'' ping 127.0.0.1 -t"
```

Elevated behavior test (relay running elevated):

```powershell
# Ensure ssh-user32relay.exe is running elevated
Add-Content "$env:PROGRAMDATA\ssh-user32relay\run.txt" "'' rundll32.exe user32.dll,LockWorkStation"
Add-Content "$env:PROGRAMDATA\ssh-user32relay\run.txt" "'' notepad.exe"
# Run as user even when elevated.
Add-Content "$env:APPDATA\ssh-user32relay\run.txt" "'' ping 127.0.0.1 -t"
```

### `gstart.exe`

Using the helper utility `gstart.exe` to write to the `run.txt` file(s).

```powershell
# Run through system queue (requires elevation)
gstart -s -D "C:\" notepad.exe "file.txt"
# Run through user queue
gstart notepad.exe
```

## Recommended Setup

1. Install `ssh-user32relay.exe` and `gstart.exe` into a protected location.
2. Put `gstart.exe` on `PATH`
3. Create a task scheduler task to run `ssh-user32relay.exe` with highest
   privledges on user login.
