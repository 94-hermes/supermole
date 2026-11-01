// Command installer-launcher is the executable of "Supermole Terminal.app",
// the app inside Installer-Supermole.dmg. It opens Terminal on a copy of the
// install-supermole.command script kept in the app's resources, so the person
// installing can follow install.sh and type a password there. The install
// logic stays in install.sh (.claude/rules/install-update.md).
//
// It is a Go binary rather than an osacompile applet because the applet stub
// requires the macOS version of the Mac that built it, which made the app
// unusable on older Apple silicon Macs; Go builds keep a 12.0 minimum.
package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
)

const (
	commandScriptName = "install-supermole.command"
	// install-supermole.command deletes itself only under a name of this
	// form, so running the script from a checkout never removes it.
	commandCopyPattern = "install-supermole-*.command"
	commandCopyMode    = 0o700

	openBinary      = "/usr/bin/open"
	osascriptBinary = "/usr/bin/osascript"
	terminalApp     = "Terminal"

	failureTitle = "Supermole Terminal n'a pas pu démarrer"
)

func main() {
	if err := run(); err != nil {
		showAlert(failureTitle, err.Error())
		os.Exit(1)
	}
}

func run() error {
	executable, err := os.Executable()
	if err != nil {
		return fmt.Errorf("locate the app: %w", err)
	}
	script := filepath.Join(filepath.Dir(executable), "..", "Resources", commandScriptName)
	scriptCopy, err := copyCommandScript(script, os.TempDir())
	if err != nil {
		return err
	}
	// open, not Terminal scripting, which asks for an automation permission.
	if output, err := exec.Command(openBinary, "-a", terminalApp, scriptCopy).CombinedOutput(); err != nil {
		return errors.Join(fmt.Errorf("open Terminal: %w: %s", err, output), os.Remove(scriptCopy))
	}
	return nil
}

// copyCommandScript writes the script's bytes to a new executable file in
// dir and returns its path. Only the bytes move: a file copy would carry the
// download's quarantine flag over, and macOS would block the copy again.
func copyCommandScript(script, dir string) (string, error) {
	source, err := os.Open(script)
	if err != nil {
		return "", fmt.Errorf("read the installer script: %w", err)
	}
	defer source.Close() //nolint:errcheck // read-only; a close error cannot lose data

	target, err := os.CreateTemp(dir, commandCopyPattern)
	if err != nil {
		return "", fmt.Errorf("create the installer script copy: %w", err)
	}
	if _, err := io.Copy(target, source); err != nil {
		return "", discardCopy(target, fmt.Errorf("copy the installer script: %w", err))
	}
	if err := target.Chmod(commandCopyMode); err != nil {
		return "", discardCopy(target, fmt.Errorf("make the installer script copy executable: %w", err))
	}
	if err := target.Close(); err != nil {
		return "", errors.Join(fmt.Errorf("write the installer script copy: %w", err), os.Remove(target.Name()))
	}
	return target.Name(), nil
}

func discardCopy(target *os.File, cause error) error {
	return errors.Join(cause, target.Close(), os.Remove(target.Name()))
}

// showAlert passes the text as arguments, never as script source, so no
// message can break the AppleScript.
func showAlert(title, message string) {
	err := exec.Command(osascriptBinary,
		"-e", "on run argv",
		"-e", "display alert (item 1 of argv) message (item 2 of argv) as critical",
		"-e", "end run",
		title, message).Run()
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: %s (alert failed: %v)\n", title, message, err)
	}
}
