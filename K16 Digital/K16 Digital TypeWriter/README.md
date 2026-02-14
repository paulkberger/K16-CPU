# Digital Keyboard Sender

A small Delphi utility that sends text directly to the **Keyboard** input window of [Digital](https://github.com/hneemann/Digital), the digital circuit simulator. Useful for automating input to simulated terminals — type BASIC programs, Forth code, test scripts, or anything else without manual copy-paste.

## How It Works

1. Finds the running Digital window by its title suffix (`.dig - Digital`)
2. Locates the **Keyboard** component window by enumerating child windows of the same process
3. Brings the Keyboard window to the foreground
4. Sends the editor contents as Unicode keystrokes via `SendInput`
5. Line endings are normalised to CR to match typical terminal expectations

No manual clicking or coordinate capture required — the Keyboard window is found automatically.

## Usage

1. Open your circuit in Digital and ensure a **Keyboard** component window is visible
2. Type or paste your code into the SynEdit editor
3. Press **Ctrl+Enter** to send the text and clear the editor — or click the **Send** button
4. Focus returns to the editor automatically, ready for the next input

## Features

- **Auto-detect Keyboard window** — no manual mouse targeting needed
- **Ctrl+Enter** — send and clear in one keystroke
- **Show Special Characters** — toggle visibility of CR/LF/space markers in the editor
- **SynEdit** editor with syntax highlighting support

## Requirements

- Delphi (tested with Delphi 10.x / 11.x)
- [SynEdit](https://github.com/SynEdit/SynEdit) component package
- Windows (uses Win32 API for window enumeration and `SendInput`)

## Building

Open the project in the Delphi IDE and build. No third-party dependencies beyond SynEdit.

## License

MIT
