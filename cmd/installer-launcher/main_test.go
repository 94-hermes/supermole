package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

const quarantineAttribute = "com.apple.quarantine"

func TestCopyCommandScriptLeavesTheQuarantineFlagBehind(t *testing.T) {
	script := filepath.Join(t.TempDir(), commandScriptName)
	content := []byte("#!/bin/bash\necho installed\n")
	if err := os.WriteFile(script, content, 0o755); err != nil {
		t.Fatal(err)
	}
	// What a browser download leaves on every file of the dmg.
	if output, err := exec.Command("/usr/bin/xattr", "-w", quarantineAttribute, "0083;00000000;Safari;", script).CombinedOutput(); err != nil {
		t.Fatalf("set quarantine: %v: %s", err, output)
	}

	scriptCopy, err := copyCommandScript(script, t.TempDir())
	if err != nil {
		t.Fatalf("copyCommandScript: %v", err)
	}

	if matched, _ := filepath.Match(commandCopyPattern, filepath.Base(scriptCopy)); !matched {
		t.Errorf("copy %q does not match %q, so it would never delete itself", scriptCopy, commandCopyPattern)
	}
	got, err := os.ReadFile(scriptCopy)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, content) {
		t.Errorf("copy holds %q, want %q", got, content)
	}
	info, err := os.Stat(scriptCopy)
	if err != nil {
		t.Fatal(err)
	}
	if mode := info.Mode().Perm(); mode != commandCopyMode {
		t.Errorf("copy mode %o, want %o", mode, commandCopyMode)
	}
	if err := exec.Command("/usr/bin/xattr", "-p", quarantineAttribute, scriptCopy).Run(); err == nil {
		t.Errorf("copy kept %s, so macOS would block it again", quarantineAttribute)
	}
}

func TestCopyCommandScriptReportsAMissingScriptAndLeavesNoFile(t *testing.T) {
	dir := t.TempDir()
	if _, err := copyCommandScript(filepath.Join(t.TempDir(), commandScriptName), dir); err == nil {
		t.Fatal("copyCommandScript succeeded without a script")
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Errorf("left %d file(s) behind", len(entries))
	}
}
